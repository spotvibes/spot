import Foundation
import UIKit
import UserNotifications
import Firebase
import FirebaseAuth
import Network
enum ChatClientMessage: Encodable {
    case sendMessage(conversationId: String, request: SendMessageRequestBody, clientTempId: String?)
    case typing(conversationId: String)
    case delivered(messageId: String)
    case callSignal(callId: String, payload: [String: AnyEncodable])
    case locationUpdate(conversationId: String, lat: Double, lng: Double)
    case stopLocationShare(conversationId: String, messageId: String)
    case disconnecting
    case ping
    case appDidBecomeActive
    case callRingingAck(callId: String)
    case appDidBecomeBackgroundOnly

    private enum CodingKeys: String, CodingKey { case type }
    private enum Kind: String, Encodable {
        case sendMessage = "send_message", typing, delivered, callSignal = "call_signal"
        case locationUpdate = "location_update", stopLocationShare = "stop_location_share"
        case disconnecting, ping
        case callRingingAck = "call_ringing_ack"
        case appDidBecomeActive = "app_did_become_active"
        case appDidBecomeBackgroundOnly = "app_did_become_background_only"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        switch self {
        case .sendMessage(let conversationId, let request, let clientTempId):
            try container.encode(Kind.sendMessage.rawValue, forKey: DynamicKey(stringValue: "type")!)
            try container.encode(conversationId, forKey: DynamicKey(stringValue: "conversation_id")!)
            try container.encode(request, forKey: DynamicKey(stringValue: "request")!)
            try container.encodeIfPresent(clientTempId, forKey: DynamicKey(stringValue: "client_temp_id")!)
        case .typing(let conversationId):
            try container.encode(Kind.typing.rawValue, forKey: DynamicKey(stringValue: "type")!)
            try container.encode(conversationId, forKey: DynamicKey(stringValue: "conversation_id")!)
        case .delivered(let messageId):
            try container.encode(Kind.delivered.rawValue, forKey: DynamicKey(stringValue: "type")!)
            try container.encode(messageId, forKey: DynamicKey(stringValue: "message_id")!)
        case .callSignal(let callId, let payload):
            try container.encode(Kind.callSignal.rawValue, forKey: DynamicKey(stringValue: "type")!)
            try container.encode(callId, forKey: DynamicKey(stringValue: "call_id")!)
            try container.encode(payload, forKey: DynamicKey(stringValue: "payload")!)
        case .locationUpdate(let conversationId, let lat, let lng):
            try container.encode(Kind.locationUpdate.rawValue, forKey: DynamicKey(stringValue: "type")!)
            try container.encode(conversationId, forKey: DynamicKey(stringValue: "conversation_id")!)
            try container.encode(lat, forKey: DynamicKey(stringValue: "lat")!)
            try container.encode(lng, forKey: DynamicKey(stringValue: "lng")!)
        case .stopLocationShare(let conversationId, let messageId):
            try container.encode(Kind.stopLocationShare.rawValue, forKey: DynamicKey(stringValue: "type")!)
            try container.encode(conversationId, forKey: DynamicKey(stringValue: "conversation_id")!)
            try container.encode(messageId, forKey: DynamicKey(stringValue: "message_id")!)
        case .disconnecting:
            try container.encode(Kind.disconnecting.rawValue, forKey: DynamicKey(stringValue: "type")!)
        case .ping:
            try container.encode(Kind.ping.rawValue, forKey: DynamicKey(stringValue: "type")!)
        case .callRingingAck(let callId):
            try container.encode(Kind.callRingingAck.rawValue, forKey: DynamicKey(stringValue: "type")!)
            try container.encode(callId, forKey: DynamicKey(stringValue: "call_id")!)
        case .appDidBecomeActive:
            try container.encode(Kind.appDidBecomeActive.rawValue, forKey: DynamicKey(stringValue: "type")!)
        case .appDidBecomeBackgroundOnly:
            try container.encode(Kind.appDidBecomeBackgroundOnly.rawValue, forKey: DynamicKey(stringValue: "type")!)
        }
    }
}

private struct DynamicKey: CodingKey {
    var stringValue: String
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}

private let fractionalISO8601Formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let plainISO8601Formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()
func parseFlexibleISO8601(_ string: String) -> Date? {
    if let date = plainISO8601Formatter.date(from: string) { return date }
    if let date = fractionalISO8601Formatter.date(from: string) { return date }
    guard let dotRange = string.range(of: "."),
          let fracEnd = string[dotRange.upperBound...].firstIndex(where: { !$0.isNumber })
    else { return nil }
    let fracDigits = string[dotRange.upperBound..<fracEnd]
    guard fracDigits.count > 3 else { return nil }
    let truncated = string.replacingCharacters(
        in: dotRange.upperBound..<fracEnd,
        with: fracDigits.prefix(3)
    )
    return fractionalISO8601Formatter.date(from: truncated)
}

struct AnyEncodable: Encodable {
    private let encodeFn: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T) { encodeFn = value.encode }
    func encode(to encoder: Encoder) throws { try encodeFn(encoder) }
}

extension Notification.Name {
    static let chatConversationDidMarkRead = Notification.Name("chatConversationDidMarkRead")
}

enum ChatServerEvent {
    case connected(participantId: String)
    case newMessage(conversationId: String, message: BackendMessage)
    case messageAck(clientTempId: String, message: BackendMessage)
    case delivered(messageId: String, userId: String)
    case opened(conversationId: String, upToMessageId: String, userId: String, readAt: Date?, opensBit: Bool)
    case typing(conversationId: String, userId: String)
    case locationUpdate(conversationId: String, userId: String, lat: Double, lng: Double)
    case locationShareStopped(conversationId: String, messageId: String, userId: String)
    case presenceChanged(userId: String, online: Bool, lastSeen: Date?)
    case reactionUpdated(messageId: String, reactions: [MessageReaction])
    case messageDeleted(conversationId: String, messageId: String, deletedAt: Date?)
    case messageEdited(conversationId: String, messageId: String, text: String, editedAt: Date?)
    case incomingCall(callId: String, conversationId: String, callerId: String,callerName: String, callType: CallType)
    case callSignal(callId: String, payload: [String: Any])
    case callStatusChanged(callId: String, conversationId: String, status: String)
    case callRinging(callId: String, conversationId: String)
        case error(message: String)
}

@MainActor
final class ChatWebSocketClient: ObservableObject {
    static let shared = ChatWebSocketClient()

    private let gatewayURL = AppConfig.gatewayURL

    @Published private(set) var isConnected = false

    @Published var currentlyOpenConversationId: String?

    private var ackedDeliveryIds: Set<String> = []

    private static func resumeCursorKey(_ uid: String) -> String { "chat.resumeCursor.\(uid)" }

    private static func loadResumeCursor(uid: String) -> String? {
        UserDefaults.standard.string(forKey: resumeCursorKey(uid))
    }

    private static func cursorIsNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> (UInt64, UInt64)? {
            let p = s.split(separator: "-", maxSplits: 1).map(String.init)
            guard p.count == 2, let ms = UInt64(p[0]), let n = UInt64(p[1]) else { return nil }
            return (ms, n)
        }
        guard let x = parts(a) else { return false }
        guard let y = parts(b) else { return true }
        return x > y
    }

    private func advanceResumeCursor(_ eventId: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        if let current = Self.loadResumeCursor(uid: uid), !Self.cursorIsNewer(eventId, than: current) { return }
        UserDefaults.standard.set(eventId, forKey: Self.resumeCursorKey(uid))
    }

    var conversationDisplayNameLookup: ((String) -> String?)?

    var conversationIsGroupLookup: ((String) -> Bool)?

    var onEvent: [(ChatServerEvent) -> Void] = []

    typealias SubscriptionToken = UUID
    private var subscribers: [SubscriptionToken: (ChatServerEvent) -> Void] = [:]

    @discardableResult
    func subscribe(_ handler: @escaping (ChatServerEvent) -> Void) -> SubscriptionToken {
        let token = SubscriptionToken()
        subscribers[token] = handler
        return token
    }

    func unsubscribe(_ token: SubscriptionToken?) {
        guard let token else { return }
        subscribers.removeValue(forKey: token)
    }

    private var task: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectAttempt = 0

    var callPriorityMode = false
    private var intentionalDisconnect = false

    private var inFlightSendCount = 0
    private var allSendsCompleteContinuations: [() -> Void] = []

    private static let sendDrainTimeoutSeconds: TimeInterval = 0.3

    private static let closeFlushDelaySeconds: TimeInterval = 0.05

    private func notifyAllSendsComplete() {
        guard inFlightSendCount == 0, !allSendsCompleteContinuations.isEmpty else { return }
        let continuations = allSendsCompleteContinuations
        allSendsCompleteContinuations = []
        continuations.forEach { $0() }
    }
    private var connectGeneration = 0
    private var connectionAckTask: Task<Void, Never>?

    private var stabilityResetTask: Task<Void, Never>?
    private let stabilityWindowSeconds: UInt64 = 5

    private var isConnecting = false

    private var pendingConnectUpdatesPresence = true

    @Published private(set) var presenceEnabledForCurrentConnection = false

    private let interfacePathMonitor = NWPathMonitor()
    private var lastPathKey: String?
    private var wsSession: URLSession?
    private var interfacePathMonitorStarted = false
    private var interfaceChangeDebounceTask: Task<Void, Never>?
    private let interfaceChangeDebounceNanos: UInt64 = 750_000_000
    private var lastForcedReconnectAt: Date?
    private let forcedReconnectCooldownSeconds: TimeInterval = 5

    private var lastFrameReceivedAt = Date()
    private let heartbeatStaleThresholdSeconds: TimeInterval = 60

    private init() {}

    private func startInterfacePathMonitoring() {
        guard !interfacePathMonitorStarted else { return }
        interfacePathMonitorStarted = true
        interfacePathMonitor.pathUpdateHandler = { [weak self] path in
            let key = networkPathKey(path)
            Task { @MainActor in
                guard let self else { return }
                defer { self.lastPathKey = key }
                guard let lastKey = self.lastPathKey, lastKey != key, key != "unsatisfied" else { return }
                print("DEBUG: ChatWebSocketClient interface path update \(lastKey) -> \(key), debouncing reconnect")
                self.interfaceChangeDebounceTask?.cancel()
                self.interfaceChangeDebounceTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: self?.interfaceChangeDebounceNanos ?? 750_000_000)
                    guard let self, !Task.isCancelled else { return }
                    if let last = self.lastForcedReconnectAt, Date().timeIntervalSince(last) < self.forcedReconnectCooldownSeconds {
                        print("DEBUG: ChatWebSocketClient interface still settling within cooldown, skipping forced reconnect")
                        return
                    }
                    self.lastForcedReconnectAt = Date()
                    self.forceReconnectAfterInterfaceChange()
                }
            }
        }
        interfacePathMonitor.start(queue: DispatchQueue(label: "ws-path-monitor"))
    }

    private func forceReconnectAfterInterfaceChange() {
        guard !intentionalDisconnect else { return }
        connectionAckTask?.cancel()
        stabilityResetTask?.cancel()
        heartbeatTask?.cancel()
        receiveLoopTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
        isConnecting = true
        connectGeneration += 1
        let generation = connectGeneration
        Task { await connectInternal(generation: generation) }
    }

    func connect(updatesPresence requestedPresence: Bool = true) {
        let appState = UIApplication.shared.applicationState
        let inBackgroundWake = appState == .background
            || (NotificationReplyHandler.isHandlingBackgroundReply && appState != .active)
        let updatesPresence = requestedPresence && !inBackgroundWake
        #if DEBUG
        print("DEBUG: [WS] connect(requested: \(requestedPresence)) appState=\(appState.rawValue) replyInFlight=\(NotificationReplyHandler.isHandlingBackgroundReply) -> updatesPresence=\(updatesPresence) via \(Thread.callStackSymbols.dropFirst().prefix(4).joined(separator: " | "))")
        #endif

        startInterfacePathMonitoring()

        if isConnected {
            probeIfPossiblyStale()
            if updatesPresence && !presenceEnabledForCurrentConnection {
                send(.appDidBecomeActive) { [weak self] success in
                    guard let self, success else { return }
                    self.presenceEnabledForCurrentConnection = true
                    self.lastSentPresenceWatch = nil
                    self.syncPresenceWatch(force: true)
                }
            }
            return
        }

        if isConnecting {
            pendingConnectUpdatesPresence = pendingConnectUpdatesPresence || updatesPresence
            return
        }

        intentionalDisconnect = false
        isConnecting = true
        pendingConnectUpdatesPresence = updatesPresence
        connectGeneration += 1
        let generation = connectGeneration
        Task { await connectInternal(generation: generation) }
    }

    private var stalenessProbeTask: Task<Void, Never>?

    private func probeIfPossiblyStale() {
        guard stalenessProbeTask == nil,
              Date().timeIntervalSince(lastFrameReceivedAt) > 25 else { return }
        let probeStart = Date()
        let probedTask = task
        send(.ping)
        stalenessProbeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self else { return }
            self.stalenessProbeTask = nil
            guard !Task.isCancelled, self.task === probedTask, self.isConnected else { return }
            if self.lastFrameReceivedAt < probeStart {
                print("DEBUG: ChatWebSocketClient stale-socket probe got no reply, forcing reconnect")
                self.forceReconnectAfterInterfaceChange()
            }
        }
    }

    func demoteToCallOnlyIfPresenceWasWronglyEnabled() {
        demoteToCallOnlyIfPresenceWasWronglyEnabled(isRetry: false)
    }

    private func demoteToCallOnlyIfPresenceWasWronglyEnabled(isRetry: Bool) {
        guard isConnected, presenceEnabledForCurrentConnection else { return }
        send(.appDidBecomeBackgroundOnly) { [weak self] success in
            guard let self else { return }
            if success {
                self.presenceEnabledForCurrentConnection = false
            } else if !isRetry {
                print("DEBUG: appDidBecomeBackgroundOnly send failed, retrying once")
                self.demoteToCallOnlyIfPresenceWasWronglyEnabled(isRetry: true)
            } else {
                print("DEBUG: appDidBecomeBackgroundOnly send failed twice, presence left wrongly enabled")
            }
        }
    }

    func forceReconnectAndRetry(_ text: String) {
        let awaitingText = text
        var cancellable: Task<Void, Never>?
        cancellable = Task { [weak self] in
            guard let self else { return }
            for await isConnected in self.$isConnected.values {
                guard isConnected else { continue }
                self.sendRaw(awaitingText)
                cancellable?.cancel()
                return
            }
        }
        forceReconnectAfterInterfaceChange()
    }
    private static let backgroundCloseReason = "background".data(using: .utf8)

    func disconnect(completion: (() -> Void)? = nil) {
        intentionalDisconnect = true
        isConnecting = false
        connectGeneration += 1
        connectionAckTask?.cancel()
        stabilityResetTask?.cancel()
        heartbeatTask?.cancel()
        receiveLoopTask?.cancel()
        interfaceChangeDebounceTask?.cancel()

        guard let taskToClose = task else {
            completion?()
            return
        }
        task = nil
        isConnected = false

        func closeNow() {
            taskToClose.cancel(with: .normalClosure, reason: Self.backgroundCloseReason)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeFlushDelaySeconds) {
                completion?()
            }
        }

        if inFlightSendCount == 0 {
            closeNow()
        } else {
            print("DEBUG: ChatWebSocketClient disconnect() draining \(inFlightSendCount) in-flight send(s) before closing")
            var didFire = false
            allSendsCompleteContinuations.append {
                guard !didFire else { return }
                didFire = true
                closeNow()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.sendDrainTimeoutSeconds) {
                guard !didFire else { return }
                didFire = true
                print("DEBUG: ChatWebSocketClient disconnect() drain timed out, closing anyway")
                closeNow()
            }
        }
    }

    private func connectInternal(generation: Int) async {
        guard let user = Auth.auth().currentUser else {
            isConnecting = false
            scheduleReconnect()
            return
        }

        connectionAckTask?.cancel()
        stabilityResetTask?.cancel()
        heartbeatTask?.cancel()
        receiveLoopTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)

        let token: String
        do {
            token = try await user.getIDToken()
        } catch {
            print("DEBUG: ChatWebSocketClient failed to get auth token: \(error)")
            guard generation == connectGeneration else { return }
            isConnecting = false
            scheduleReconnect()
            return
        }

        guard generation == connectGeneration else { return }

        guard var components = URLComponents(string: gatewayURL) else { isConnecting = false; return }
        var queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "presence", value: pendingConnectUpdatesPresence ? "true" : "false"),
        ]
        if pendingConnectUpdatesPresence, let cursor = Self.loadResumeCursor(uid: user.uid) {
            queryItems.append(URLQueryItem(name: "resume", value: cursor))
        }
        components.queryItems = queryItems
        guard let url = components.url else { isConnecting = false; return }

        guard generation == connectGeneration else { return }

        let configuration = URLSessionConfiguration.default
        configuration.networkServiceType = .callSignaling
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 15
        wsSession?.invalidateAndCancel()
        let session = URLSession(configuration: configuration)
        wsSession = session
        let newTask = session.webSocketTask(with: url)
        task = newTask
        newTask.resume()

        startHeartbeat()
        receiveLoopTask = Task { await receiveLoop() }
        armConnectionAckTimeout()
    }

    private func armConnectionAckTimeout() {
        connectionAckTask?.cancel()
        let awaitedTask = task
        let ackSeconds: UInt64 = callPriorityMode ? 2 : 5
        connectionAckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ackSeconds * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.task === awaitedTask, !self.isConnected else { return }
            print("DEBUG: ChatWebSocketClient no 'connected' ack within \(ackSeconds)s, retrying")
            self.stabilityResetTask?.cancel()
            self.heartbeatTask?.cancel()
            self.receiveLoopTask?.cancel()
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.isConnecting = false
            self.isConnected = false
            if !self.intentionalDisconnect {
                self.scheduleReconnect()
            }
        }
    }

    private var presenceWatchSources: [String: Set<String>] = [:]
    private var lastSentPresenceWatch: Set<String>?

    func setPresenceWatch(source: String, ids: Set<String>) {
        if ids.isEmpty {
            presenceWatchSources.removeValue(forKey: source)
        } else {
            presenceWatchSources[source] = ids
        }
        syncPresenceWatch()
    }

    private func syncPresenceWatch(force: Bool = false) {
        guard isConnected, presenceEnabledForCurrentConnection else { return }
        let union = presenceWatchSources.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        if !force, union == lastSentPresenceWatch { return }
        if union.isEmpty, lastSentPresenceWatch == nil { lastSentPresenceWatch = union; return }
        let payload: [String: Any] = ["type": "set_presence_watch", "user_ids": Array(union).sorted()]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        sendRaw(text) { [weak self] success in
            guard let self, success else { return }
            self.lastSentPresenceWatch = union
        }
    }

    func send(_ message: ChatClientMessage) {
        send(message, completion: nil)
    }

    func send(_ message: ChatClientMessage, completion: ((Bool) -> Void)?) {
        guard let task else {
            completion?(false)
            return
        }
        do {
            let data = try JSONEncoder().encode(message)
            guard let text = String(data: data, encoding: .utf8) else {
                completion?(false)
                return
            }
            inFlightSendCount += 1
            task.send(.string(text)) { [weak self] error in
                if let error {
                    print("DEBUG: ChatWebSocketClient send failed: \(error)")
                    completion?(false)
                } else {
                    completion?(true)
                }
                guard let self else { return }
                self.inFlightSendCount -= 1
                self.notifyAllSendsComplete()
            }
        } catch {
            print("DEBUG: ChatWebSocketClient encode failed: \(error)")
            completion?(false)
        }
    }
    func sendRaw(_ text: String) {
        sendRaw(text, completion: nil)
    }

    func sendLocationPing(conversationId: String, lat: Double, lng: Double) {
        guard E2EEService.shared.isEnabled(conversationId) else {
            send(.locationUpdate(conversationId: conversationId, lat: lat, lng: lng))
            return
        }
        Task { [weak self] in
            for attempt in 0..<2 {
                guard let eph = try? await E2EEService.shared.encryptEphemeral(
                    conversationId: conversationId, object: ["lat": lat, "lng": lng], refresh: attempt > 0),
                      let ct = try? JSONEncoder().encode(eph),
                      let ctObj = try? JSONSerialization.jsonObject(with: ct) else { continue }
                let frame: [String: Any] = ["type": "location_update_e2ee", "conversation_id": conversationId, "e2ee": ctObj]
                if let data = try? JSONSerialization.data(withJSONObject: frame), let text = String(data: data, encoding: .utf8) {
                    self?.sendRaw(text)
                }
                return
            }
        }
    }

    func sendRaw(_ text: String, completion: ((Bool) -> Void)?) {
        guard let task else {
            completion?(false)
            return
        }
        inFlightSendCount += 1
        task.send(.string(text)) { [weak self] error in
            if let error {
                print("DEBUG: ChatWebSocketClient sendRaw failed: \(error)")
                completion?(false)
            } else {
                completion?(true)
            }
            guard let self else { return }
            self.inFlightSendCount -= 1
            self.notifyAllSendsComplete()
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        lastFrameReceivedAt = Date()
        heartbeatTask = Task { [weak self] in
            let interval: UInt64 = 20
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
                guard !Task.isCancelled else { break }
                self.send(.ping)
                if Date().timeIntervalSince(self.lastFrameReceivedAt) > self.heartbeatStaleThresholdSeconds {
                    print("DEBUG: ChatWebSocketClient no inbound frame in \(self.heartbeatStaleThresholdSeconds)s despite heartbeat — treating socket as half-open, forcing reconnect")
                    self.forceReconnectAfterInterfaceChange()
                    break
                }
            }
        }
    }

    private func receiveLoop() async {
        guard let task else { return }
        let watchedTask = task
        do {
            while true {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    handleIncoming(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { handleIncoming(text) }
                @unknown default:
                    break
                }
            }
        } catch {
            guard self.task === watchedTask else {
                print("DEBUG: ChatWebSocketClient stale receive loop ended (already superseded): \(error)")
                return
            }
            print("DEBUG: ChatWebSocketClient receive loop ended: \(error)")
            connectionAckTask?.cancel()
            stabilityResetTask?.cancel()
            isConnected = false
            isConnecting = false
            if !intentionalDisconnect {
                scheduleReconnect()
            }
        }
    }

    private func armStabilityReset() {
        stabilityResetTask?.cancel()
        let awaitedTask = task
        stabilityResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: (self?.stabilityWindowSeconds ?? 5) * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.task === awaitedTask, self.isConnected else { return }
            self.reconnectAttempt = 0
        }
    }

    private func scheduleReconnect() {
        guard !intentionalDisconnect else { return }

        if !callPriorityMode, !NetworkMonitor.shared.isConnectedNow {
            let generationAtSchedule = connectGeneration
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard self.connectGeneration == generationAtSchedule,
                      !self.intentionalDisconnect, !self.isConnected else { return }
                self.scheduleReconnect()
            }
            return
        }

        reconnectAttempt += 1
        let baseDelaySeconds = callPriorityMode
            ? min(1.0, 0.25 * Double(reconnectAttempt))
            : min(30.0, pow(1.6, Double(reconnectAttempt)))
        let jitterFactor = Double.random(in: 0.8...1.2)
        let delaySeconds = min(30.0, baseDelaySeconds * jitterFactor)
        let generationAtSchedule = connectGeneration
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard self.connectGeneration == generationAtSchedule else { return }
            self.connectGeneration += 1
            let generation = self.connectGeneration
            self.isConnecting = true
            await self.connectInternal(generation: generation)
        }
    }

    private func ackAfterPresenting(message: BackendMessage, conversationId: String) {
        let token = BackgroundTaskCoordinator.shared.begin(name: "present-\(message.id)")
        Task { @MainActor [weak self] in
            defer { BackgroundTaskCoordinator.shared.end(token) }
            guard let self else { return }
            let muted = await ChatLocalStore.shared.isMutedNow(conversationId: conversationId)
            let ok: Bool
            if muted {
                ok = true
            } else {
                ok = await self.presentLocalNotification(for: message, conversationId: conversationId)
            }
            if ok {
                self.send(.delivered(messageId: message.id))
            } else {
                self.ackedDeliveryIds.remove(message.id)
                print("DEBUG: [WS] local notification failed for \(message.id) -- ack withheld, guard push will cover")
            }
        }
    }

    private func presentLocalNotification(for message: BackendMessage, conversationId: String) async -> Bool {
        let isViewingThisConversation = UIApplication.shared.applicationState == .active
            && conversationId == currentlyOpenConversationId
        guard !isViewingThisConversation else { return true }

        let content = UNMutableNotificationContent()
        let senderName = ChatParticipantDirectory.shared.displayName(for: message.senderId)
        let conversationName = conversationDisplayNameLookup?(conversationId)
        let isGroupConversation = conversationIsGroupLookup?(conversationId) ?? false
        let title: String
        if isGroupConversation, let senderName, let conversationName {
            title = "\(senderName) in \(conversationName)"
        } else {
            title = senderName ?? conversationName ?? "New message"
        }

        if UIApplication.shared.applicationState == .active {
            let bannerSenderName: String
            let bannerGroupName: String?
            if isGroupConversation, let senderName, let conversationName {
                bannerSenderName = senderName
                bannerGroupName = conversationName
            } else {
                bannerSenderName = senderName ?? conversationName ?? "New message"
                bannerGroupName = nil
            }
            InAppMessageBannerPresenter.shared.present(
                InAppMessageBannerPayload(
                    conversationId: conversationId,
                    message: message,
                    senderName: bannerSenderName,
                    groupName: bannerGroupName,
                    bodyText: previewText(for: message),
                    isGroup: isGroupConversation
                )
            )
            return true
        }

        content.title = title
        content.body = previewText(for: message)
        content.sound = .default
        content.userInfo = [
            "kind": String(NotificationKind.newMessage.rawValue),
            "conversation_id": conversationId,
            "message_id": message.id,
        ]
        let request = UNNotificationRequest(
            identifier: "local-\(message.id)",
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            print("DEBUG: [WS] local notification added for \(message.id)")
            return true
        } catch {
            print("DEBUG: ChatWebSocketClient local notification failed: \(error)")
            return false
        }
    }

    private func previewText(for message: BackendMessage) -> String {
        switch message.contentType {
        case .text: return message.textContent ?? "Sent a message"
        case .image: return "📷 Photo"
        case .video: return "🎥 Video"
        case .voice: return "🎤 Voice message"
        case .location: return "📍 Location"
        case .file: return "📎 File"
        case .bit: return "Sent a Bit"
        case .system: return message.textContent ?? "System message"
        }
    }

    func ingestFrame(_ text: String) {
        handleIncoming(text)
    }

    private func handleIncoming(_ text: String) {
        #if DEBUG
        print("DEBUG: ChatWebSocketClient received raw frame: \(text)")
        #endif
        lastFrameReceivedAt = Date()
        guard let data = text.data(using: .utf8) else { return }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = parseFlexibleISO8601(string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected ISO8601 date string, got \(string)"
                )
            }
            return date
        }

        let event: ChatServerEvent?
        switch type {
        case "connected":
            connectionAckTask?.cancel()
            if !isConnected {
                isConnected = true
            }
            isConnecting = false
            presenceEnabledForCurrentConnection = pendingConnectUpdatesPresence
            lastSentPresenceWatch = nil
            syncPresenceWatch(force: true)
            armStabilityReset()
            event = (json["participant_id"] as? String).map { .connected(participantId: $0) }

        case "new_message":
            guard let conversationId = json["conversation_id"] as? String,
                  let messageDict = json["message"],
                  let messageData = try? JSONSerialization.data(withJSONObject: messageDict),
                  let wireMessage = try? decoder.decode(BackendMessage.self, from: messageData)
            else { event = nil; break }
            let (message, pendingAtt) = E2EEService.shared.decryptSplit(wireMessage)
            if let eventId = json["event_id"] as? String {
                advanceResumeCursor(eventId)
            }
            if !ackedDeliveryIds.contains(message.id) {
                ackedDeliveryIds.insert(message.id)
                ackAfterPresenting(message: message, conversationId: conversationId)
            }
            if let att = pendingAtt, att.blob != nil {
                Task { [weak self] in
                    let hydrated = await E2EEService.shared.hydrate(message, att)
                    DispatchQueue.main.async { self?.dispatch(.newMessage(conversationId: conversationId, message: hydrated)) }
                }
                event = nil
            } else {
                event = .newMessage(conversationId: conversationId, message: message)
            }

        case "message_ack":
            guard let clientTempId = json["client_temp_id"] as? String,
                  let messageDict = json["message"],
                  let messageData = try? JSONSerialization.data(withJSONObject: messageDict),
                  let wireMessage = try? decoder.decode(BackendMessage.self, from: messageData)
            else { event = nil; break }
            let (message, pendingAtt) = E2EEService.shared.decryptSplit(wireMessage)
            if let att = pendingAtt, att.blob != nil {
                Task { [weak self] in
                    let hydrated = await E2EEService.shared.hydrate(message, att)
                    DispatchQueue.main.async { self?.dispatch(.messageAck(clientTempId: clientTempId, message: hydrated)) }
                }
                event = nil
            } else {
                event = .messageAck(clientTempId: clientTempId, message: message)
            }

        case "location_update":
            guard let conversationId = json["conversation_id"] as? String,
                  let userId = json["user_id"] as? String,
                  let lat = json["lat"] as? Double,
                  let lng = json["lng"] as? Double
            else { event = nil; break }
            event = .locationUpdate(conversationId: conversationId, userId: userId, lat: lat, lng: lng)

        case "location_update_e2ee":
            guard let conversationId = json["conversation_id"] as? String,
                  let userId = json["user_id"] as? String,
                  userId.lowercased() != E2EEService.shared.currentUserId,
                  let plain = E2EEService.shared.decryptEphemeral(frameField: json["e2ee"]),
                  let lat = plain["lat"] as? Double, let lng = plain["lng"] as? Double
            else { event = nil; break }
            event = .locationUpdate(conversationId: conversationId, userId: userId, lat: lat, lng: lng)

        case "location_share_stopped":
            guard let conversationId = json["conversation_id"] as? String,
                  let messageId = json["message_id"] as? String,
                  let userId = json["user_id"] as? String
            else { event = nil; break }
            event = .locationShareStopped(conversationId: conversationId, messageId: messageId, userId: userId)

        case "delivered":
            guard let messageId = json["message_id"] as? String, let userId = json["user_id"] as? String else { event = nil; break }
            event = .delivered(messageId: messageId, userId: userId)

        case "opened":
            guard let conversationId = json["conversation_id"] as? String,
                  let upTo = json["up_to_message_id"] as? String,
                  let userId = json["user_id"] as? String
            else { event = nil; break }
            let readAt = (json["read_at"] as? String).flatMap { parseFlexibleISO8601($0) }
            let opensBit = json["opens_bit"] as? Bool ?? false
            event = .opened(conversationId: conversationId, upToMessageId: upTo, userId: userId, readAt: readAt, opensBit: opensBit)

        case "typing":
            guard let conversationId = json["conversation_id"] as? String, let userId = json["user_id"] as? String else { event = nil; break }
            event = .typing(conversationId: conversationId, userId: userId)

        case "presence_changed":
            guard let userId = json["user_id"] as? String, let online = json["online"] as? Bool else { event = nil; break }
            let lastSeen = (json["last_seen"] as? String).flatMap { parseFlexibleISO8601($0) }
            event = .presenceChanged(userId: userId, online: online, lastSeen: lastSeen)

        case "reaction_updated":
            guard let messageId = json["message_id"] as? String,
                  let reactionsArray = json["reactions"],
                  let reactionsData = try? JSONSerialization.data(withJSONObject: reactionsArray),
                  let reactions = try? decoder.decode([MessageReaction].self, from: reactionsData)
            else { event = nil; break }
            event = .reactionUpdated(messageId: messageId, reactions: reactions)

        case "message_deleted":
            guard let conversationId = json["conversation_id"] as? String,
                  let messageId = json["message_id"] as? String
            else { event = nil; break }
            let deletedAt = (json["deleted_at"] as? String).flatMap { parseFlexibleISO8601($0) }
            event = .messageDeleted(conversationId: conversationId, messageId: messageId, deletedAt: deletedAt)

        case "message_edited":
            guard let conversationId = json["conversation_id"] as? String,
                  let messageId = json["message_id"] as? String
            else { event = nil; break }
            let editedAt = (json["edited_at"] as? String).flatMap { parseFlexibleISO8601($0) }
            let text: String
            if let envObj = json["e2ee_envelope"], !(envObj is NSNull),
               let envData = try? JSONSerialization.data(withJSONObject: envObj),
               let envelope = try? decoder.decode(E2EEEnvelope.self, from: envData) {
                let cts: [E2EECiphertext] = (json["e2ee_ciphertexts"]).flatMap {
                    try? JSONSerialization.data(withJSONObject: $0)
                }.flatMap { try? decoder.decode([E2EECiphertext].self, from: $0) } ?? []
                guard let plain = E2EEService.shared.decryptEdit(
                    messageId: messageId, conversationId: conversationId,
                    envelope: envelope, ciphertexts: cts, editedAt: editedAt
                ) else { event = nil; break }
                text = plain
            } else if let t = json["text_content"] as? String {
                text = t
            } else { event = nil; break }
            event = .messageEdited(conversationId: conversationId, messageId: messageId, text: text, editedAt: editedAt)

        case "incoming_call":
            guard let callId = json["call_id"] as? String,
                  let conversationId = json["conversation_id"] as? String,
                  let callerId = json["caller_id"] as? String,
                  let callTypeRaw = json["call_type"] as? String,
                  let callerName = json["caller_name"] as? String,
                  let callType = CallType(rawValue: callTypeRaw)
            else { event = nil; break }
            event = .incomingCall(callId: callId, conversationId: conversationId, callerId: callerId, callerName: callerName, callType: callType)

        case "call_signal":
            guard let callId = json["call_id"] as? String, let payload = json["payload"] as? [String: Any] else { event = nil; break }
            event = .callSignal(callId: callId, payload: payload)
        case "call_status_changed":
            guard let callId = json["call_id"] as? String,
                  let conversationId = json["conversation_id"] as? String,
                  let status = json["status"] as? String
            else { event = nil; break }
            event = .callStatusChanged(callId: callId, conversationId: conversationId, status: status)
        case "call_ringing":
            guard let callId = json["call_id"] as? String,
                  let conversationId = json["conversation_id"] as? String
            else { event = nil; break }
            event = .callRinging(callId: callId, conversationId: conversationId)
        case "e2ee_enabled":
            if let conversationId = json["conversation_id"] as? String {
                E2EEService.shared.markEnabled(conversationId)
            }
            event = nil
        case "send_failed":
            if (json["code"] as? String) == "e2ee/devices-changed", let cid = json["conversation_id"] as? String {
                E2EEService.shared.invalidateDevices(cid)
            }
            if (json["code"] as? String) == "e2ee/encryption-required", let cid = json["conversation_id"] as? String {
                E2EEService.shared.markEnabled(cid)
            }
            if let tempId = json["client_temp_id"] as? String {
                NotificationCenter.default.post(name: .chatSocketSendFailed, object: nil, userInfo: [
                    "clientTempId": tempId,
                    "status": json["status"] as? Int ?? 500,
                    "code": json["code"] as? String ?? "",
                    "message": json["message"] as? String ?? "",
                ])
            }
            event = nil
        case "error":
            event = .error(message: json["message"] as? String ?? "Unknown error")

        default:
            event = nil
        }

        guard let event else { return }
        dispatch(event)
    }

    private func dispatch(_ event: ChatServerEvent) {
        if case .messageDeleted(_, let messageId, _) = event {
            InAppMessageBannerPresenter.shared.messageWasDeleted(id: messageId)
            UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: ["local-\(messageId)"])
            UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
                let matchingIdentifiers = delivered
                    .filter { ($0.request.content.userInfo["message_id"] as? String) == messageId }
                    .map { $0.request.identifier }
                if !matchingIdentifiers.isEmpty {
                    UNUserNotificationCenter.current()
                        .removeDeliveredNotifications(withIdentifiers: matchingIdentifiers)
                }
            }
        }
        for callback in onEvent { callback(event) }
        for (_, callback) in subscribers { callback(event) }
    }
}

extension Notification.Name {
    static let chatSocketSendFailed = Notification.Name("chatSocketSendFailed")
}
