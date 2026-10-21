import Foundation
import UIKit

enum ParticipantsMode: Equatable {
    case group
    case direct(otherParticipantId: String, otherParticipantType: ParticipantType)

    var isGroup: Bool { if case .group = self { return true } else { return false } }
}

enum MuteDuration: CaseIterable, Identifiable {
    case twoHours, fourHours, eightHours, oneWeek, always, off

    var id: Self { self }

    var label: String {
        switch self {
        case .twoHours: return "For 2 Hours"
        case .fourHours: return "For 4 Hours"
        case .eightHours: return "For 8 Hours"
        case .oneWeek: return "For 1 Week"
        case .always: return "Until I Turn It Back On"
        case .off: return "Unmute"
        }
    }

    func until(from now: Date = Date()) -> Date? {
        switch self {
        case .twoHours: return Calendar.current.date(byAdding: .hour, value: 2, to: now)
        case .fourHours: return Calendar.current.date(byAdding: .hour, value: 4, to: now)
        case .eightHours: return Calendar.current.date(byAdding: .hour, value: 8, to: now)
        case .oneWeek: return Calendar.current.date(byAdding: .day, value: 7, to: now)
        case .always: return .distantFuture
        case .off: return nil
        }
    }
}

@MainActor
final class ParticipantsViewModel: ObservableObject {
    let conversationId: String
    let mode: ParticipantsMode
    private let networkService: NetworkService

    var isGroup: Bool { mode.isGroup }

    @Published private(set) var details: GroupDetails?

    @Published private(set) var inviteLink: GroupInviteLink?
    @Published private(set) var isUpdatingInviteLink = false

    @Published private var groupMutedUntil: Date?
    @Published private var groupArchived: Bool = false

    var mutedUntil: Date? { isGroup ? groupMutedUntil : directInfo?.mutedUntil }
    var isMuted: Bool { mutedUntil.map { $0 > Date() } ?? false }
    var archived: Bool { isGroup ? groupArchived : (directInfo?.archived ?? false) }

    private var settingsChangeObserver: NSObjectProtocol?

    @Published private(set) var directInfo: BackendConversationSummary?

    @Published private(set) var isLoading = true
    @Published var errorMessage: String?

    @Published private(set) var sharedMedia: [BackendMessage] = []
    @Published private(set) var cacheSizeBytes: Int64 = 0
    @Published private(set) var isLoadingStorage = false

    @Published private(set) var membersWithoutEncryption: Int?
    @Published private(set) var isClearingCache = false

    private var mediaCacheKeys: Set<String> { Set(sharedMedia.map(\.id)) }

    @Published private(set) var didLeaveOrDeleteGroup = false
    @Published private(set) var didLeaveGroup = false

    init(
        conversationId: String,
        mode: ParticipantsMode,
        networkService: NetworkService = .shared,
        initialMutedUntil: Date? = nil,
        initialArchived: Bool = false
    ) {
        self.conversationId = conversationId
        self.mode = mode
        self.networkService = networkService
        self.groupMutedUntil = initialMutedUntil
        self.groupArchived = initialArchived
        subscribeToSettingsChangeNotifications()
    }

    deinit {
        if let settingsChangeObserver {
            NotificationCenter.default.removeObserver(settingsChangeObserver)
        }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        switch mode {
        case .group:
            do {
                details = try await networkService.getGroupDetails(conversationId)
                inviteLink = details?.myInviteLink
            } catch {
                errorMessage = "Couldn't load group details."
            }
        case .direct:
            do {
                directInfo = try await networkService.getConversationDetails(conversationId)
            } catch {
                errorMessage = "Couldn't load this conversation."
            }
        }
    }

    func loadStorageInfo() async {
        isLoadingStorage = true
        defer { isLoadingStorage = false }
        sharedMedia = (try? await ChatLocalStore.shared.fetchMediaMessages(conversationId: conversationId)) ?? []
        cacheSizeBytes = await MediaFileCache.shared.diskUsage(forCacheKeys: mediaCacheKeys)
    }

    func loadEncryption() async {
        guard !E2EEService.shared.isEnabled(conversationId) else { return }
        if let devices = try? await networkService.e2eeConversationDevices(conversationId) {
            membersWithoutEncryption = devices.usersWithoutDevices.count
        }
    }

    func clearConversationCache() async {
        isClearingCache = true
        defer { isClearingCache = false }
        await MediaFileCache.shared.remove(cacheKeys: mediaCacheKeys)
        cacheSizeBytes = 0
    }

    func leaveGroup() async {
        guard isGroup else { return }
        do {
            try await networkService.leaveGroup(conversationId)
            didLeaveGroup = true
            didLeaveOrDeleteGroup = true
        } catch {
            errorMessage = "Couldn't leave the group."
        }
    }

    func deleteGroup() async {
        guard isGroup else { return }
        do {
            try await networkService.deleteGroup(conversationId)
            didLeaveOrDeleteGroup = true
        } catch {
            errorMessage = "Couldn't delete the group."
        }
    }

    func promote(_ participant: GroupParticipant) async {
        do {
            try await networkService.promoteGroupCreator(conversationId, userId: participant.userId)
            await load()
        } catch {
            errorMessage = "Couldn't make \(participant.displayName) a creator."
        }
    }

    func remove(_ participant: GroupParticipant) async {
        do {
            try await networkService.removeGroupMember(conversationId, userId: participant.userId)
            await load()
        } catch {
            errorMessage = "Couldn't remove \(participant.displayName)."
        }
    }

    func addMembers<P: Identifiable>(_ users: [P]) async where P.ID == String {
        do {
            try await networkService.addGroupMembers(conversationId, participantIds: users.map(\.id))
            await load()
        } catch {
            errorMessage = error.followRequiredMessage ?? "Couldn't add those people."
        }
    }

    func setInviteLinkEnabled(_ enabled: Bool) async {
        guard isGroup, !isUpdatingInviteLink else { return }
        let previous = inviteLink
        if var current = inviteLink {
            current.enabled = enabled
            inviteLink = current
        }
        isUpdatingInviteLink = true
        defer { isUpdatingInviteLink = false }
        do {
            inviteLink = try await networkService.setGroupInviteLink(conversationId, enabled: enabled)
        } catch {
            inviteLink = previous
            errorMessage = "Couldn't update the invite link."
        }
    }

    func rename(to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await networkService.updateGroup(conversationId, name: trimmed)
            await load()
        } catch {
            errorMessage = "Couldn't rename the group."
        }
    }

    func changeGroupImage(_ image: UIImage) async {
        let resized = GroupImageResizing.resizedForUpload(image)
        do {
            guard let url = try await ImageUploader.uploadImage(image: resized, type: .thumbnail) else {
                errorMessage = "Couldn't upload the group photo."
                return
            }
            _ = try await networkService.updateGroup(conversationId, imageUrl: url)
            await load()
        } catch {
            errorMessage = "Couldn't update the group photo."
        }
    }

    func removeGroupImage() async {
        guard isGroup else { return }
        do {
            _ = try await networkService.updateGroup(conversationId, imageUrl: "")

            try? await ChatLocalStore.shared.patchGroupImageUrl(conversationId: conversationId, imageUrl: nil)

            await GroupAvatarStore.shared.clearAvatar(conversationId: conversationId)
            await GroupAvatarStore.shared.assignAvatarIfNeeded(conversationId: conversationId)

            NotificationCenter.default.post(
                name: .chatConversationSettingsDidChange,
                object: nil,
                userInfo: ["conversationId": conversationId, "groupImageUrl": NSNull()]
            )
            await load()
        } catch {
            errorMessage = "Couldn't remove the group photo."
        }
    }

    func setMuted(until: Date?) async {
        let previous = mutedUntil
        if isGroup {
            groupMutedUntil = until
        } else {
            patchDirect { $0.mutedUntil = until }
        }
        do {
            try await networkService.updateConversationSettings(
                conversationId,
                body: UpdateConversationSettingsRequestBody(mutedUntil: .some(until), archived: nil, notificationsEnabled: nil)
            )
            try? await ChatLocalStore.shared.patchConversationSettings(conversationId: conversationId, mutedUntil: until, archived: nil)
            broadcastSettingsChange(mutedUntil: until)
        } catch {
            if isGroup {
                groupMutedUntil = previous
            } else {
                patchDirect { $0.mutedUntil = previous }
            }
            errorMessage = "Couldn't update mute setting."
        }
    }

    func setArchived(_ isArchived: Bool) async {
        let previousArchived = archived
        let previousMuted = mutedUntil
        let impliedMutedUntil: Date? = isArchived ? .distantFuture : nil
        if isGroup {
            groupArchived = isArchived
            groupMutedUntil = impliedMutedUntil
        } else {
            patchDirect {
                $0.archived = isArchived
                $0.mutedUntil = impliedMutedUntil
            }
        }
        do {
            try await networkService.updateConversationSettings(
                conversationId,
                body: UpdateConversationSettingsRequestBody(mutedUntil: nil, archived: isArchived, notificationsEnabled: nil)
            )
            try? await ChatLocalStore.shared.patchConversationSettings(
                conversationId: conversationId,
                mutedUntil: impliedMutedUntil,
                archived: isArchived
            )
            broadcastSettingsChange(mutedUntil: impliedMutedUntil, archived: isArchived)
        } catch {
            if isGroup {
                groupArchived = previousArchived
                groupMutedUntil = previousMuted
            } else {
                patchDirect {
                    $0.archived = previousArchived
                    $0.mutedUntil = previousMuted
                }
            }
            errorMessage = "Couldn't update archive setting."
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        guard case .direct = mode else { return }
        do {
            try await networkService.updateConversationSettings(
                conversationId,
                body: UpdateConversationSettingsRequestBody(mutedUntil: nil, archived: nil, notificationsEnabled: enabled)
            )
        } catch {
            errorMessage = "Couldn't update notification setting."
        }
    }

    func clearChat() async -> Bool {
        do {
            try await networkService.deleteConversationHistory(conversationId)
            try? await ChatLocalStore.shared.deleteConversation(conversationId: conversationId)
            return true
        } catch {
            errorMessage = "Couldn't clear this chat."
            return false
        }
    }

    func toggleBlock() async {
        guard case .direct = mode, let wasBlocked = directInfo?.isBlocked else { return }
        let nowBlocked = !wasBlocked
        patchDirect { $0.isBlocked = nowBlocked }
        do {
            if wasBlocked {
                try await networkService.chatUnblock(conversationId)
            } else {
                try await networkService.chatBlock(conversationId)
            }
            NotificationCenter.default.post(
                name: .chatConversationSettingsDidChange,
                object: nil,
                userInfo: ["conversationId": conversationId, "isBlocked": nowBlocked]
            )
        } catch {
            patchDirect { $0.isBlocked = wasBlocked }
            errorMessage = wasBlocked ? "Couldn't unblock." : "Couldn't block."
        }
    }

    private func broadcastSettingsChange(mutedUntil: Date?, archived: Bool? = nil) {
        var userInfo: [String: Any] = ["conversationId": conversationId, "mutedUntil": mutedUntil ?? NSNull()]
        if let archived { userInfo["archived"] = archived }
        NotificationCenter.default.post(name: .chatConversationSettingsDidChange, object: nil, userInfo: userInfo)
    }

    private func subscribeToSettingsChangeNotifications() {
        guard settingsChangeObserver == nil else { return }
        settingsChangeObserver = NotificationCenter.default.addObserver(
            forName: .chatConversationSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let conversationId = notification.userInfo?["conversationId"] as? String,
                  conversationId == self.conversationId else { return }
            let mutedUntilProvided = notification.userInfo?["mutedUntil"] != nil
            let mutedUntil = (notification.userInfo?["mutedUntil"]).flatMap { $0 as? Date }
            let archived = notification.userInfo?["archived"] as? Bool
            let isBlocked = notification.userInfo?["isBlocked"] as? Bool
            if self.isGroup {
                if mutedUntilProvided { self.groupMutedUntil = mutedUntil }
                if let archived { self.groupArchived = archived }
            } else {
                self.patchDirect {
                    if mutedUntilProvided { $0.mutedUntil = mutedUntil }
                    if let archived { $0.archived = archived }
                    if let isBlocked { $0.isBlocked = isBlocked }
                }
            }
        }
    }

    private func patchDirect(_ mutate: (inout BackendConversationSummary) -> Void) {
        guard var updated = directInfo else { return }
        mutate(&updated)
        directInfo = updated
        Task { try? await ChatLocalStore.shared.upsertConversation(updated) }
    }
}
