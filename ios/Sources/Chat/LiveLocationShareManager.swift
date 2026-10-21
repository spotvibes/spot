import Foundation
import Combine
import CoreLocation
import UIKit

@MainActor
final class LiveLocationShareManager: ObservableObject {
    static let shared = LiveLocationShareManager()

    static let didEndNotification = Notification.Name("LiveLocationShareDidEnd")

    struct Share: Codable, Equatable {
        let conversationId: String
        var messageId: String?
        let endsAt: Date
    }

    private struct PendingStop: Codable, Hashable {
        let conversationId: String
        let messageId: String
    }

    @Published private(set) var shares: [String: Share] = [:]

    let controller = LocationShareController()

    private var expiryTasks: [String: Task<Void, Never>] = [:]
    private let defaultsKey = "liveLocationShares.v1"
    private let pendingStopsKey = "liveLocationShares.pendingStops.v1"

    private var pendingStops: [PendingStop] = []
    private var stopsInFlight: Set<PendingStop> = []
    private var unsentPing: (lat: Double, lng: Double)?
    private var lastForcedConnectAt: Date?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        load()
        loadPendingStops()
        ChatWebSocketClient.shared.$isConnected
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.flushAfterConnect() }
            }
            .store(in: &cancellables)
    }

    func isSharing(_ conversationId: String) -> Bool {
        guard let share = shares[conversationId] else { return false }
        return share.endsAt > Date()
    }

    func endsAt(_ conversationId: String) -> Date? { shares[conversationId]?.endsAt }

    var keepsSocketAliveInBackground: Bool {
        guard !shares.isEmpty else { return false }
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        return CLLocationManager().authorizationStatus == .authorizedAlways && modes.contains("location")
    }

    func begin(conversationId: String, endsAt: Date, start: LiveCoordinate? = nil) {
        guard shares[conversationId] == nil else { return }
        if let myId = AuthService.shared.user?.backendId {
            LiveLocationPositions.shared.clear(conversationId: conversationId, userId: myId)
            if let start {
                LiveLocationPositions.shared.update(conversationId: conversationId, userId: myId, lat: start.lat, lng: start.lng)
            }
        }
        shares[conversationId] = Share(conversationId: conversationId, messageId: nil, endsAt: endsAt)
        persist()
        scheduleExpiry(for: conversationId)
        startUpdatingIfNeeded()
    }

    func attachMessageId(_ messageId: String, to conversationId: String) {
        guard var share = shares[conversationId] else {
            pendingStops.append(PendingStop(conversationId: conversationId, messageId: messageId))
            persistPendingStops()
            flushPendingStops()
            NotificationCenter.default.post(
                name: Self.didEndNotification, object: nil,
                userInfo: ["conversationId": conversationId, "messageId": messageId]
            )
            return
        }
        share.messageId = messageId
        shares[conversationId] = share
        persist()
    }

    func cancelFailedStart(conversationId: String) {
        guard let share = shares[conversationId], share.messageId == nil else { return }
        stop(conversationId: conversationId)
    }

    func stop(conversationId: String) {
        guard let share = shares.removeValue(forKey: conversationId) else { return }
        expiryTasks[conversationId]?.cancel()
        expiryTasks[conversationId] = nil
        persist()
        if let myId = AuthService.shared.user?.backendId {
            LiveLocationPositions.shared.clear(conversationId: conversationId, userId: myId)
        }

        if let messageId = share.messageId {
            pendingStops.append(PendingStop(conversationId: conversationId, messageId: messageId))
            persistPendingStops()
            flushPendingStops()
        }
        var info: [String: Any] = ["conversationId": conversationId]
        if let messageId = share.messageId { info["messageId"] = messageId }
        NotificationCenter.default.post(name: Self.didEndNotification, object: nil, userInfo: info)

        stopUpdatingIfIdle()
        releaseSocketIfBackgroundedAndIdle()
    }

    func reconcile() {
        let now = Date()
        for (id, share) in shares where share.endsAt <= now { stop(conversationId: id) }
        for id in shares.keys where expiryTasks[id] == nil { scheduleExpiry(for: id) }
        startUpdatingIfNeeded()
        if isUpdating {
            controller.startUpdating()
            controller.beginBackgroundSharing()
        }
        flushPendingStops()
    }

    private var isUpdating = false

    private func startUpdatingIfNeeded() {
        guard !shares.isEmpty, !isUpdating else { return }
        isUpdating = true
        controller.onLocationUpdate = { [weak self] lat, lng in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let myId = AuthService.shared.user?.backendId
                for id in self.shares.keys {
                    if let myId {
                        LiveLocationPositions.shared.update(conversationId: id, userId: myId, lat: lat, lng: lng)
                    }
                }
                self.sendPing(lat: lat, lng: lng)
            }
        }
        controller.startUpdating()
        controller.beginBackgroundSharing()
    }

    private func stopUpdatingIfIdle() {
        guard shares.isEmpty, isUpdating else { return }
        isUpdating = false
        controller.onLocationUpdate = nil
        controller.stopUpdating()
        controller.endBackgroundSharing()
    }

    private func sendPing(lat: Double, lng: Double) {
        let client = ChatWebSocketClient.shared
        guard client.isConnected else {
            unsentPing = (lat, lng)
            reconnectInBackgroundIfNeeded()
            return
        }
        for id in shares.keys {
            client.sendLocationPing(conversationId: id, lat: lat, lng: lng)
        }
    }

    private func reconnectInBackgroundIfNeeded() {
        guard UIApplication.shared.applicationState == .background,
              AuthService.shared.user != nil else { return }
        if let last = lastForcedConnectAt, Date().timeIntervalSince(last) < 15 { return }
        lastForcedConnectAt = Date()
        ChatWebSocketClient.shared.connect()
    }

    private func flushAfterConnect() {
        flushPendingStops()
        if let ping = unsentPing, !shares.isEmpty {
            unsentPing = nil
            for id in shares.keys {
                ChatWebSocketClient.shared.sendLocationPing(conversationId: id, lat: ping.lat, lng: ping.lng)
            }
        }
    }

    private func flushPendingStops() {
        let client = ChatWebSocketClient.shared
        guard client.isConnected else { return }
        for stop in pendingStops where !stopsInFlight.contains(stop) {
            stopsInFlight.insert(stop)
            client.send(.stopLocationShare(conversationId: stop.conversationId, messageId: stop.messageId)) { [weak self] ok in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.stopsInFlight.remove(stop)
                    guard ok else { return }
                    self.pendingStops.removeAll { $0 == stop }
                    self.persistPendingStops()
                    self.releaseSocketIfBackgroundedAndIdle()
                }
            }
        }
    }

    private func releaseSocketIfBackgroundedAndIdle() {
        guard shares.isEmpty, pendingStops.isEmpty,
              UIApplication.shared.applicationState == .background,
              CallManager.shared.callState == .idle else { return }
        let token = BackgroundTaskCoordinator.shared.begin(name: "chat-socket-live-share-release")
        ChatWebSocketClient.shared.disconnect {
            BackgroundTaskCoordinator.shared.end(token)
        }
    }

    private func scheduleExpiry(for conversationId: String) {
        expiryTasks[conversationId]?.cancel()
        guard let endsAt = shares[conversationId]?.endsAt else { return }
        expiryTasks[conversationId] = Task { [weak self] in
            let delay = endsAt.timeIntervalSinceNow
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            self?.stop(conversationId: conversationId)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Array(shares.values)) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode([Share].self, from: data) else { return }
        shares = Dictionary(uniqueKeysWithValues: saved.map { ($0.conversationId, $0) })
    }

    private func persistPendingStops() {
        if let data = try? JSONEncoder().encode(pendingStops) {
            UserDefaults.standard.set(data, forKey: pendingStopsKey)
        }
    }

    private func loadPendingStops() {
        guard let data = UserDefaults.standard.data(forKey: pendingStopsKey),
              let saved = try? JSONDecoder().decode([PendingStop].self, from: data) else { return }
        pendingStops = saved
    }
}
