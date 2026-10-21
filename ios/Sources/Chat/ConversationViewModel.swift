import Foundation
import Combine

enum MessageReceiptState {
    case sending, sent, delivered, opened
    case failed
}

@MainActor
final class ConversationViewModel: ObservableObject {
    let conversationId: String
    let otherParticipantId: String
    let otherParticipantType: ParticipantType

    @Published var messages: [BackendMessage] = []
    @Published var isLoadingOlder = false
    @Published var hasMoreOlderMessages = true
    @Published var typingUserIds: Set<String> = []
    var isOtherTyping: Bool { !typingUserIds.isEmpty }
    @Published var groupParticipantDisplayNames: [String: String] = [:]
    @Published var groupParticipantProfileImageUrls: [String: String] = [:]
    @Published var groupParticipants: [GroupParticipant] = []
    var typingIndicatorText: String? {
        guard isGroup, !typingUserIds.isEmpty else { return nil }
        let names = typingUserIds.map { groupParticipantDisplayNames[$0] ?? "Someone" }
        switch names.count {
        case 1: return "\(names[0]) is typing"
        case 2: return "\(names[0]) and \(names[1]) are typing"
        default: return "\(names.count) people are typing"
        }
    }
    @Published var incomingLiveLocation: (lat: Double, lng: Double)?
    var isSharingLiveLocation: Bool {
        LiveLocationShareManager.shared.isSharing(conversationId)
    }
    private var liveShareCancellables = Set<AnyCancellable>()
    @Published var errorMessage: String?
    @Published var followRequiredMessage: String?
    @Published var otherPresence: PresenceInfo = .hidden
    @Published var messageReceipts: [String: MessageReceiptState] = [:]

    struct GroupReadCursor: Equatable {
        let messageId: String
        let readAt: Date?
    }

    @Published var groupReadCursors: [String: GroupReadCursor] = [:]

    @Published var groupDeliveredUserIds: [String: Set<String>] = [:]

    @Published var reconciledMessageIds: [String: String] = [:]

    private var pendingSendIds: Set<String> = []
    private var pendingBodies: [String: SendMessageRequestBody] = [:]
    private var typingResetTasks: [String: Task<Void, Never>] = [:]
    private var socketToken: ChatWebSocketClient.SubscriptionToken?
    private var settingsChangeObserver: NSObjectProtocol?
    private var presenceWatchSource: String { "conversation-\(conversationId)" }

    deinit {
        if let settingsChangeObserver {
            NotificationCenter.default.removeObserver(settingsChangeObserver)
        }
        let token = socketToken
        let watchSource = "conversation-\(conversationId)"
        Task { @MainActor in
            ChatWebSocketClient.shared.setPresenceWatch(source: watchSource, ids: [])
            ChatWebSocketClient.shared.unsubscribe(token)
        }
    }

    @Published var otherDisplayName: String?

    let isGroup: Bool
    @Published var groupName: String?
    @Published var groupImageUrl: String?
    var groupAvatarSeed: String { GroupAvatarStore.shared.avatarSeed(forConversationId: conversationId) }
    @Published var groupDeletedAt: Date?
    var isGroupDeleted: Bool { groupDeletedAt != nil }

    @Published var selfHasLeftGroup = false

    @Published var otherProfileImageUrl: String?
    @Published var myStatus: ParticipantStatus

    @Published var otherStatus: ParticipantStatus
    @Published var mutedUntil: Date?
    var isMuted: Bool { mutedUntil.map { $0 > Date() } ?? false }
    @Published var archived: Bool

    @Published var isBlocked: Bool

    init(
        conversationId: String,
        otherParticipantId: String,
        otherParticipantType: ParticipantType,
        initialDisplayName: String? = nil,
        initialProfileImageUrl: String? = nil,
        isGroup: Bool = false,
        initialStatus: ParticipantStatus = .accepted,
        initialOtherStatus: ParticipantStatus = .accepted,
        initialGroupName: String? = nil,
        initialGroupImageUrl: String? = nil,
        initialMutedUntil: Date? = nil,
        initialArchived: Bool = false,
        initialIsBlocked: Bool = false
    ) {
        self.conversationId = conversationId
        self.otherParticipantId = otherParticipantId
        self.otherParticipantType = otherParticipantType
        self.otherDisplayName = initialDisplayName
        self.otherProfileImageUrl = initialProfileImageUrl
        self.isGroup = isGroup
        self.myStatus = initialStatus
        self.otherStatus = initialOtherStatus
        self.groupName = initialGroupName
        self.groupImageUrl = initialGroupImageUrl
        self.mutedUntil = initialMutedUntil
        self.archived = initialArchived
        self.isBlocked = initialIsBlocked
        subscribeToSettingsChangeNotifications()
        observeLiveLocationShare()
        subscribeToSocketEvents()
        Task { await loadInitial() }
        Task { await refreshReadReceipts() }
        Task { await seedIsBlockedFromCache() }
        if isGroup {
            Task {
                await seedGroupParticipantNamesFromCache()
                await seedSelfHasLeftGroupFromCache()
                await refreshGroupDetails()
            }
        }
    }

    private func seedGroupParticipantNamesFromCache() async {
        guard isGroup else { return }
        do {
            let cached = try await ChatLocalStore.shared.fetchGroupParticipantNames(conversationId: conversationId)
            guard !cached.names.isEmpty else { return }
            groupParticipantDisplayNames = cached.names
            groupParticipantProfileImageUrls = cached.avatars
            await cacheParticipantsInSharedDirectory(names: cached.names, avatars: cached.avatars)
        } catch {
            print("DEBUG: ConversationViewModel failed to seed cached group participant names: \(error)")
        }
    }

    private func cacheParticipantsInSharedDirectory(names: [String: String], avatars: [String: String]) async {
        for (userId, name) in names {
            ChatParticipantDirectory.shared.cache(userId: userId, displayName: name, profileImageUrl: avatars[userId])
            await ParticipantColorStore.shared.assignColorIfNeeded(userId: userId, displayName: name)
        }
    }

    private func seedSelfHasLeftGroupFromCache() async {
        guard isGroup, let myId = currentUserId else { return }
        do {
            if let cachedHasLeft = try await ChatLocalStore.shared.fetchSelfHasLeftGroup(conversationId: conversationId, userId: myId), cachedHasLeft {
                selfHasLeftGroup = true
            }
        } catch {
            print("DEBUG: ConversationViewModel failed to seed cached selfHasLeftGroup: \(error)")
        }
    }

    private func seedIsBlockedFromCache() async {
        do {
            if let cachedIsBlocked = try await ChatLocalStore.shared.fetchIsBlocked(conversationId: conversationId), cachedIsBlocked {
                isBlocked = true
            }
        } catch {
            print("DEBUG: ConversationViewModel failed to seed cached isBlocked: \(error)")
        }
    }

    func recordSelfLeftGroupLocally() async {
        guard isGroup else { return }
        selfHasLeftGroup = true
        guard let myId = currentUserId else { return }
        try? await ChatLocalStore.shared.markSelfLeftGroup(conversationId: conversationId, userId: myId)
    }

    func refreshGroupDetails() async {
        guard isGroup else { return }
        do {
            let details = try await NetworkService.shared.getGroupDetails(conversationId)
            groupName = details.name
            let hasPhoto = !(details.imageUrl ?? "").isEmpty
            groupImageUrl = hasPhoto ? details.imageUrl : nil
            groupDeletedAt = details.groupDeletedAt
            if !hasPhoto {
                await GroupAvatarStore.shared.assignAvatarIfNeeded(conversationId: conversationId)
            } else {
                await GroupAvatarStore.shared.clearAvatar(conversationId: conversationId)
            }
            var names: [String: String] = [:]
            var avatars: [String: String] = [:]
            for participant in details.participants {
                names[participant.userId] = participant.displayName
                avatars[participant.userId] = participant.profileImageUrl
            }
            groupParticipantDisplayNames = names
            groupParticipantProfileImageUrls = avatars
            groupParticipants = details.participants
            await cacheParticipantsInSharedDirectory(names: names, avatars: avatars)
            if let myId = currentUserId {
                selfHasLeftGroup = details.participants.first(where: { $0.userId == myId })?.hasLeft ?? false
            }
            try? await ChatLocalStore.shared.upsertGroupParticipantNames(
                conversationId: conversationId,
                participants: details.participants
            )
        } catch {
            print("DEBUG: ConversationViewModel failed to refresh group details: \(error)")
        }
    }

    func updateCachedOtherDisplayNameIfChanged(_ freshDisplayName: String) async {
        guard !isGroup, !freshDisplayName.isEmpty, freshDisplayName != otherDisplayName else { return }
        otherDisplayName = freshDisplayName
        do {
            try await ChatLocalStore.shared.patchOtherParticipantDisplayName(
                conversationId: conversationId,
                displayName: freshDisplayName
            )
        } catch {
            print("DEBUG: ConversationViewModel failed to persist updated display name: \(error)")
        }
    }

    func updateCachedGroupParticipantDisplayNameIfChanged(userId: String, freshDisplayName: String) async {
        guard isGroup, !freshDisplayName.isEmpty, groupParticipantDisplayNames[userId] != freshDisplayName else { return }
        groupParticipantDisplayNames[userId] = freshDisplayName
        ChatParticipantDirectory.shared.cache(
            userId: userId,
            displayName: freshDisplayName,
            profileImageUrl: groupParticipantProfileImageUrls[userId]
        )
        do {
            try await ChatLocalStore.shared.patchGroupParticipantDisplayName(
                conversationId: conversationId,
                userId: userId,
                displayName: freshDisplayName
            )
        } catch {
            print("DEBUG: ConversationViewModel failed to persist updated group participant name: \(error)")
        }
    }

    func refreshReadReceipts() async {
        do {
            let receipts = try await NetworkService.shared.getReadReceipts(conversationId)
            for receipt in receipts {
                guard let lastReadMessageId = receipt.lastReadMessageId else { continue }
                groupReadCursors[receipt.userId] = GroupReadCursor(messageId: lastReadMessageId, readAt: receipt.lastReadAt)
            }
        } catch {
            print("DEBUG: ConversationViewModel failed to refresh read receipts: \(error)")
        }
    }

    @Published var messageReceiptDetails: [String: [String: MessageReceiptDetail]] = [:]

    private var receiptsReconciledThisSession: Set<String> = []

    func fetchMessageReceipts(messageId: String) async {
        let cached = (try? await ChatLocalStore.shared.messageReceipts(messageId: messageId)) ?? [:]
        if !cached.isEmpty {
            messageReceiptDetails[messageId] = cached
        }

        guard let message = messages.first(where: { $0.id == messageId }) else {
            await reconcileMessageReceipts(messageId: messageId)
            return
        }

        let expectedRecipientIds = expectedReceiptRecipientIds(for: message)
        if isReceiptCacheComplete(cached: cached, expectedRecipientIds: expectedRecipientIds) {
            return
        }
        await reconcileMessageReceipts(messageId: messageId)
    }

    private func reconcileMessageReceipts(messageId: String) async {
        do {
            let details = try await NetworkService.shared.getMessageReceipts(messageId)
            try? await ChatLocalStore.shared.upsertMessageReceipts(messageId: messageId, details)
            messageReceiptDetails[messageId] = Dictionary(uniqueKeysWithValues: details.map { ($0.userId, $0) })
        } catch {
            print("DEBUG: ConversationViewModel failed to fetch message receipts for \(messageId): \(error)")
        }
    }

    private func expectedReceiptRecipientIds(for message: BackendMessage) -> [String] {
        guard isGroup else { return [otherParticipantId] }
        return groupParticipants.compactMap { participant in
            guard participant.userId != currentUserId else { return nil }
            let joinedInTime = participant.joinedAt.map { $0 <= message.createdAt } ?? true
            let stillThereAtSendTime = participant.leftAt.map { $0 > message.createdAt } ?? true
            return (joinedInTime && stillThereAtSendTime) ? participant.userId : nil
        }
    }

    private func isReceiptCacheComplete(cached: [String: MessageReceiptDetail], expectedRecipientIds: [String]) -> Bool {
        guard !expectedRecipientIds.isEmpty || !isGroup else { return false }
        let filledFieldCount = expectedRecipientIds.reduce(0) { total, userId in
            guard let detail = cached[userId] else { return total }
            return total + (detail.deliveredAt != nil ? 1 : 0) + (detail.openedAt != nil ? 1 : 0)
        }
        return filledFieldCount >= expectedRecipientIds.count * 2
    }

    func deliveryDetails(for messageId: String) -> [(userId: String, displayName: String, profileImageUrl: String?, deliveredAt: Date?, readAt: Date?)] {
        guard let messageIdx = messages.firstIndex(where: { $0.id == messageId }) else { return [] }
        let message = messages[messageIdx]
        guard message.senderId == currentUserId else { return [] }

        let recipientIds = expectedReceiptRecipientIds(for: message)
        let exactReceipts = messageReceiptDetails[messageId]
        let deliveredIds = groupDeliveredUserIds[messageId] ?? []

        return recipientIds.map { userId in
            let displayName = isGroup
                ? (groupParticipantDisplayNames[userId] ?? "Someone")
                : (otherDisplayName ?? "Someone")
            let profileImageUrl = isGroup
                ? groupParticipantProfileImageUrls[userId]
                : otherProfileImageUrl

            if let exact = exactReceipts?[userId] {
                return (userId, displayName, profileImageUrl, exact.deliveredAt, exact.openedAt)
            }

            let cursor = groupReadCursors[userId]
            var delivered = deliveredIds.contains(userId)
            if !delivered, let cursorId = cursor?.messageId,
               let cursorIdx = messages.firstIndex(where: { $0.id == cursorId }),
               cursorIdx >= messageIdx {
                delivered = true
            }
            let readAt: Date? = (cursor?.messageId == messageId) ? cursor?.readAt : nil
            let deliveredAt: Date? = delivered ? readAt : nil
            return (userId, displayName, profileImageUrl, deliveredAt, readAt)
        }
    }

    func handleAppDidBecomeActive() async {
        await reconcileForeground()
    }

    private var foregroundReconcileTask: Task<Void, Never>?

    private func reconcileForeground() async {
        if let existing = foregroundReconcileTask {
            await existing.value
            return
        }
        let task = Task {
            await reconcileNewest()
            await refreshPresence()
        }
        foregroundReconcileTask = task
        await task.value
        foregroundReconcileTask = nil
    }

    private func refreshPresence() async {
        do {
            otherPresence = try await NetworkService.shared.getPresence(conversationId: conversationId)
        } catch {
            print("DEBUG: ConversationViewModel refreshPresence failed: \(error)")
        }
    }

    private func loadInitial() async {
        if let cached = try? await ChatLocalStore.shared.fetchMessages(conversationId: conversationId, before: nil, limit: 50) {
            messages = cached
            for message in cached where message.contentType == .bit
                && (message.deletedAt != nil || (message.expiresAt.map { $0 <= Date() } ?? false)) {
                BitPrefetchCache.shared.discard(message.id)
            }
            prefetchBits(in: cached)
            prefetchMedia(in: cached)
        }

        try? await ChatLocalStore.shared.purgeExpiredBits()

        await reconcileForeground()
    }

    private func reconcileNewest() async {
        do {
            let previousNewestId = messages.last(where: { !$0.id.hasPrefix("pending-") })?.id

            let fresh = try await NetworkService.shared.getMessages(conversationId: conversationId, before: nil, limit: 50)
            try? await ChatLocalStore.shared.upsertMessages(fresh)
            mergeIncoming(fresh)
            prefetchBits(in: fresh)
            prefetchMedia(in: fresh)
            ackDelivery(for: fresh)

            if let previousNewestId {
                await backfillGapIfNeeded(previousNewestId: previousNewestId, freshBatch: fresh)
            }
        } catch {
            print("DEBUG: ConversationViewModel reconcileNewest failed: \(error)")
        }
    }

    private static let maxGapBackfillPages = 10

    private func backfillGapIfNeeded(previousNewestId: String, freshBatch: [BackendMessage]) async {
        guard !freshBatch.isEmpty, !freshBatch.contains(where: { $0.id == previousNewestId }) else {
            return
        }
        guard var cursorId = freshBatch.first?.id else { return }
        print("DEBUG: ConversationViewModel detected a history gap after reconnect, backfilling from \(cursorId)")

        for _ in 0..<Self.maxGapBackfillPages {
            guard let page = try? await NetworkService.shared.getMessages(conversationId: conversationId, before: cursorId, limit: 50),
                  !page.isEmpty
            else {
                break
            }
            try? await ChatLocalStore.shared.upsertMessages(page)
            mergeIncoming(page)
            prefetchBits(in: page)
            prefetchMedia(in: page)
            ackDelivery(for: page)

            if page.contains(where: { $0.id == previousNewestId }) {
                print("DEBUG: ConversationViewModel history gap closed")
                return
            }
            guard let oldest = page.first?.id else { break }
            cursorId = oldest
        }
    }

    func loadOlderMessages() async {
        guard !isLoadingOlder, hasMoreOlderMessages,
              let oldest = messages.first(where: { !$0.id.hasPrefix("pending-") })
        else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }

        let existingIds = Set(messages.map(\.id))

        if let localOlder = try? await ChatLocalStore.shared.fetchMessages(conversationId: conversationId, before: oldest.id, limit: 30),
           !localOlder.isEmpty {
            let deduped = localOlder.filter { !existingIds.contains($0.id) }
            if !deduped.isEmpty {
                messages.insert(contentsOf: deduped, at: 0)
            }
            return
        }

        if (try? await ChatLocalStore.shared.hasReachedBeginning(conversationId: conversationId)) == true {
            hasMoreOlderMessages = false
            return
        }

        do {
            let older = try await NetworkService.shared.getMessages(conversationId: conversationId, before: oldest.id, limit: 30)
            if older.isEmpty {
                hasMoreOlderMessages = false
                try? await ChatLocalStore.shared.markReachedBeginning(conversationId: conversationId)
            } else {
                let deduped = older.filter { !existingIds.contains($0.id) }
                if !deduped.isEmpty {
                    messages.insert(contentsOf: deduped, at: 0)
                }
                try? await ChatLocalStore.shared.upsertMessages(older)
                ackDelivery(for: older)
            }
        } catch {
            print("DEBUG: ConversationViewModel loadOlderMessages network fallback failed: \(error)")
            errorMessage = "Couldn't load older messages"
        }
    }

    func clearCache() async {
        isLoadingOlder = false
        messages = []
        hasMoreOlderMessages = true
        try? await ChatLocalStore.shared.clearConversation(conversationId: conversationId)
        try? await MediaFileCache.shared.clearAll()
        await loadInitial()
    }

    private static let socketAckTimeout: UInt64 = 4_000_000_000

    private var pendingAcks: [String: CheckedContinuation<BackendMessage, Error>] = [:]

    private var pendingPostAckActions: [String: [(BackendMessage) -> Void]] = [:]

    func sendText(
        _ text: String,
        replyToMessageId: String? = nil,
        onSent: ((BackendMessage) -> Void)? = nil,
        onFailed: (() -> Void)? = nil
    ) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { onFailed?(); return }
        let body = SendMessageRequestBody(contentType: .text, textContent: text, mediaUrl: nil, mediaMetadata: nil, replyToMessageId: replyToMessageId, isDisappearing: nil)
        performSend(body: body, optimisticTextContent: text, onSent: onSent, onFailed: onFailed)
    }

    func sendMedia(
        _ body: SendMessageRequestBody,
        onSent: ((BackendMessage) -> Void)? = nil,
        onFailed: (() -> Void)? = nil
    ) {
        performSend(body: body, optimisticTextContent: body.textContent, onSent: onSent, onFailed: onFailed)
    }

    private func performSend(
        body: SendMessageRequestBody,
        optimisticTextContent: String?,
        onSent: ((BackendMessage) -> Void)? = nil,
        onFailed: (() -> Void)? = nil
    ) {
        guard let myId = currentUserId else { onFailed?(); return }
        guard !(isGroup && selfHasLeftGroup) else { onFailed?(); return }
        guard !isBlocked else { onFailed?(); return }

        let tempId = "pending-\(UUID().uuidString)"
        pendingSendIds.insert(tempId)
        pendingBodies[tempId] = body
        let optimistic = BackendMessage(
            id: tempId,
            conversationId: conversationId,
            senderId: myId,
            senderType: .user,
            contentType: body.contentType,
            textContent: optimisticTextContent,
            mediaUrl: body.mediaUrl,
            mediaMetadata: body.mediaMetadata,
            replyToMessageId: body.replyToMessageId,
            isDisappearing: body.isDisappearing ?? false,
            expiresAt: nil,
            createdAt: Date(),
            deletedAt: nil
        )
        messages.append(optimistic)
        messageReceipts[tempId] = .sending
        Task {
            try? await ChatLocalStore.shared.upsertMessages([optimistic])
            try? await ChatLocalStore.shared.markMessageSending(tempId: tempId)
        }

        let sendsAsPendingRequest = !isGroup && otherStatus == .pending

        Task {
            let useSocket = ChatWebSocketClient.shared.isConnected && !sendsAsPendingRequest
            do {
                let sent: BackendMessage
                if let encrypted = try await E2EEService.shared.sendEncryptedIfPossible(
                    conversationId: conversationId, body: body,
                    transport: { [self] wire in
                        try await transportSend(tempId: tempId, conversationId: conversationId, body: wire,
                                                useSocket: useSocket, encrypted: true)
                    }
                ) {
                    sent = encrypted
                } else {
                    sent = try await transportSend(tempId: tempId, conversationId: conversationId, body: body,
                                                   useSocket: useSocket, encrypted: false)
                }
                replaceOptimistic(tempId: tempId, with: sent)
                onSent?(sent)
            } catch {
                markFailed(tempId: tempId)
                onFailed?()
                if let message = error.followRequiredMessage { followRequiredMessage = message }
            }
        }
    }

    private func transportSend(tempId: String, conversationId: String, body: SendMessageRequestBody,
                               useSocket: Bool, encrypted: Bool) async throws -> BackendMessage {
        if useSocket {
            do {
                return try await sendOverSocket(tempId: tempId, conversationId: conversationId, body: body)
            } catch SocketSendRejected.rejected(let status, let code, let message) {
                if encrypted && (code == "e2ee/devices-changed" || status == 428) {
                    throw NetworkError.serverError(statusCode: status, message: message)
                }
                print("DEBUG: socket send rejected (\(code)), falling back to REST")
            } catch {
                print("DEBUG: socket send failed/timed out (\(error)), falling back to REST")
            }
        }
        if encrypted {
            return try await NetworkService.shared.e2eePostMessage(conversationId: conversationId, body: body)
        }
        return try await NetworkService.shared.postPlainMessage(conversationId: conversationId, body: body)
    }

    private enum SocketSendRejected: Error { case rejected(status: Int, code: String, message: String) }

    private func sendOverSocket(tempId: String, conversationId: String, body: SendMessageRequestBody) async throws -> BackendMessage {
        let rejectionObserver = NotificationCenter.default.addObserver(
            forName: .chatSocketSendFailed, object: nil, queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo, info["clientTempId"] as? String == tempId else { return }
            let status = info["status"] as? Int ?? 500
            let code = info["code"] as? String ?? ""
            let message = info["message"] as? String ?? ""
            Task { @MainActor in
                self?.pendingAcks.removeValue(forKey: tempId)?
                    .resume(throwing: SocketSendRejected.rejected(status: status, code: code, message: message))
            }
        }
        defer { NotificationCenter.default.removeObserver(rejectionObserver) }
        return try await withThrowingTaskGroup(of: BackendMessage.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    Task { @MainActor in
                        self.pendingAcks[tempId] = continuation
                        ChatWebSocketClient.shared.send(.sendMessage(conversationId: conversationId, request: body, clientTempId: tempId))
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: Self.socketAckTimeout)
                await MainActor.run {
                    self.pendingAcks.removeValue(forKey: tempId)?.resume(throwing: SendTimeoutError.timedOut)
                }
                throw SendTimeoutError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw SendTimeoutError.timedOut }
            return result
        }
    }

    private enum SendTimeoutError: Error { case timedOut }

    private var currentUserId: String? {
        AuthService.shared.user?.backendId
    }

    private func replaceOptimistic(tempId: String, with real: BackendMessage) {
        pendingSendIds.remove(tempId)
        pendingBodies.removeValue(forKey: tempId)
           messages.removeAll { $0.id == real.id }
           if let idx = messages.firstIndex(where: { $0.id == tempId }) {
               var resolved = real
               resolved.reactions = messages[idx].reactions
               messages[idx] = resolved
           } else {
               let index = sortedInsertionIndex(for: real.createdAt)
               messages.insert(real, at: index)
           }
        reconciledMessageIds[tempId] = real.id
        messageReceipts.removeValue(forKey: tempId)
        messageReceipts[real.id] = .sent
        Task { try? await ChatLocalStore.shared.replaceOptimisticMessage(tempId: tempId, with: real) }

        if let actions = pendingPostAckActions.removeValue(forKey: tempId) {
            for action in actions { action(real) }
        }
    }

    private func markFailed(tempId: String) {
        messageReceipts[tempId] = .failed
        pendingPostAckActions.removeValue(forKey: tempId)
        Task { try? await ChatLocalStore.shared.markMessageFailed(tempId: tempId) }
    }

    func resend(tempId: String) {
        guard var body = pendingBodies[tempId] else { return }
        if body.contentType == .location, body.mediaMetadata?.isLiveLocation == true {
            let m = body.mediaMetadata
            body = SendMessageRequestBody(
                contentType: .location, textContent: nil, mediaUrl: nil,
                mediaMetadata: MessageMediaMetadata(durationMs: nil, fileSizeBytes: nil, mimeType: nil, thumbnailUrl: nil, width: nil, height: nil, lat: m?.lat, lng: m?.lng, isLiveLocation: false),
                replyToMessageId: nil, isDisappearing: nil
            )
        }
        messageReceipts[tempId] = .sending
        Task { try? await ChatLocalStore.shared.markMessageSending(tempId: tempId) }
        Task {
            do {
                let sent = try await NetworkService.shared.sendMessage(conversationId: conversationId, body: body)
                replaceOptimistic(tempId: tempId, with: sent)
            } catch {
                markFailed(tempId: tempId)
                if let message = error.followRequiredMessage { followRequiredMessage = message }
            }
        }
    }

    func resendGroup(_ tempIds: [String]) {
        for id in tempIds { resend(tempId: id) }
    }

    private var markReadDebounceTask: Task<Void, Never>?

    private var markReadInFlight: Task<Void, Never>?

    func sendOneShotLocation(lat: Double, lng: Double) {
        let metadata = MessageMediaMetadata(durationMs: nil, fileSizeBytes: nil, mimeType: nil, thumbnailUrl: nil, width: nil, height: nil, lat: lat, lng: lng, isLiveLocation: false)
        let body = SendMessageRequestBody(contentType: .location, textContent: nil, mediaUrl: nil, mediaMetadata: metadata, replyToMessageId: nil, isDisappearing: nil)
        performSend(body: body, optimisticTextContent: nil)
    }

    private func observeLiveLocationShare() {
        LiveLocationShareManager.shared.$shares
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &liveShareCancellables)

        NotificationCenter.default
            .publisher(for: LiveLocationShareManager.didEndNotification)
            .sink { [weak self] note in
                Task { @MainActor [weak self] in
                    guard let self,
                          note.userInfo?["conversationId"] as? String == self.conversationId,
                          let messageId = note.userInfo?["messageId"] as? String else { return }
                    self.markLocationShareExpiredLocally(messageId: messageId)
                }
            }
            .store(in: &liveShareCancellables)
    }

    func startLiveLocationShare(durationMinutes: Int) {
        let manager = LiveLocationShareManager.shared
        let conversationId = self.conversationId
        guard !manager.isSharing(conversationId) else { return }
        guard !(isGroup && (selfHasLeftGroup || isGroupDeleted)) else { return }

        Task {
            await manager.controller.requestAlwaysAuthorizationIfNeeded()
            guard let start = await manager.controller.currentLocationOnce() else { return }

            manager.begin(
                conversationId: conversationId,
                endsAt: Date().addingTimeInterval(TimeInterval(durationMinutes * 60)),
                start: LiveCoordinate(lat: start.lat, lng: start.lng)
            )

            let metadata = MessageMediaMetadata(durationMs: nil, fileSizeBytes: nil, mimeType: nil, thumbnailUrl: nil, width: nil, height: nil, lat: start.lat, lng: start.lng, isLiveLocation: true)
            let body = SendMessageRequestBody(contentType: .location, textContent: nil, mediaUrl: nil, mediaMetadata: metadata, replyToMessageId: nil, isDisappearing: nil)
            performSend(body: body, optimisticTextContent: nil, onSent: { sent in
                Task { @MainActor in
                    manager.attachMessageId(sent.id, to: conversationId)
                }
            }, onFailed: { [weak self] in
                Task { @MainActor in
                    manager.cancelFailedStart(conversationId: conversationId)
                    self?.neutralizeFailedLiveShareRow()
                    self?.errorMessage = "Couldn't start sharing your live location. Try again."
                }
            })
        }
    }

    private func neutralizeFailedLiveShareRow() {
        guard let myId = currentUserId,
              let idx = messages.lastIndex(where: {
                  $0.id.hasPrefix("pending-") && $0.senderId == myId
                      && $0.contentType == .location && $0.mediaMetadata?.isLiveLocation == true
              }) else { return }
        messages[idx] = messages[idx].withExpiresAt(Date())
    }

    func stopLiveLocationShare() {
        LiveLocationShareManager.shared.stop(conversationId: conversationId)
    }

    private func markLocationShareExpiredLocally(messageId: String) {
        guard let idx = messages.firstIndex(where: { $0.id == messageId }) else { return }
        messages[idx] = messages[idx].withExpiresAt(Date())
        Task { try? await ChatLocalStore.shared.upsertMessages([LocalMessage(messages[idx], status: .sent).asBackend]) }
    }

    func toggleReaction(on messageId: String, emoji: String) {
        guard let myId = currentUserId, let message = messages.first(where: { $0.id == messageId }) else { return }
        guard !(isGroup && selfHasLeftGroup) else { return }
        guard !isBlocked else { return }
        if let existing = message.reactions.first(where: { $0.userId == myId && $0.emoji == emoji }) {
            removeReaction(messageId: messageId, reaction: existing)
        } else {
            addReaction(messageId: messageId, emoji: emoji)
        }
    }

    private func addReaction(messageId: String, emoji: String) {
        guard let myId = currentUserId, let idx = messages.firstIndex(where: { $0.id == messageId }) else { return }
        let optimistic = MessageReaction(id: "pending-reaction-\(UUID().uuidString)", messageId: messageId, userId: myId, emoji: emoji, createdAt: Date())
        messages[idx].reactions.append(optimistic)
        persistReactions(messageId: messageId)

        if messageId.hasPrefix("pending-") {
            pendingPostAckActions[messageId, default: []].append { [weak self] real in
                self?.sendAddReaction(messageId: real.id, emoji: emoji, optimisticId: optimistic.id)
            }
            return
        }

        sendAddReaction(messageId: messageId, emoji: emoji, optimisticId: optimistic.id)
    }

    private func sendAddReaction(messageId: String, emoji: String, optimisticId: String) {
        Task {
            do {
                let response: ChatApiResponse<MessageReaction> = try await NetworkService.shared.post(
                    endpoint: "/messages/\(messageId)/reactions",
                    body: AddReactionRequestBody(emoji: emoji)
                )
                guard response.success, let real = response.data else {
                    throw NetworkError.serverError(statusCode: 0, message: response.error ?? "empty reaction response")
                }
                guard let idx = self.messages.firstIndex(where: { $0.id == messageId }) else { return }
                if let rIdx = self.messages[idx].reactions.firstIndex(where: { $0.id == optimisticId }) {
                    self.messages[idx].reactions[rIdx] = real
                }
                self.persistReactions(messageId: messageId)
            } catch {
                print("DEBUG: ConversationViewModel failed to add reaction: \(error)")
                guard let idx = self.messages.firstIndex(where: { $0.id == messageId }) else { return }
                self.messages[idx].reactions.removeAll { $0.id == optimisticId }
                self.persistReactions(messageId: messageId)
                self.errorMessage = "Couldn't add reaction"
            }
        }
    }

    private func removeReaction(messageId: String, reaction: MessageReaction) {
        guard let idx = messages.firstIndex(where: { $0.id == messageId }) else { return }
        messages[idx].reactions.removeAll { $0.id == reaction.id }
        persistReactions(messageId: messageId)

        if messageId.hasPrefix("pending-") {
            pendingPostAckActions[messageId, default: []].append { [weak self] real in
                self?.sendRemoveReaction(messageId: real.id, reaction: reaction)
            }
            return
        }

        sendRemoveReaction(messageId: messageId, reaction: reaction)
    }

    private func sendRemoveReaction(messageId: String, reaction: MessageReaction) {
        Task {
            do {
                let _: ChatApiResponse<String> = try await NetworkService.shared.delete(
                    endpoint: "/messages/\(messageId)/reactions/\(reaction.emoji)"
                )
            } catch {
                print("DEBUG: ConversationViewModel failed to remove reaction: \(error)")
                guard let idx = self.messages.firstIndex(where: { $0.id == messageId }),
                      !self.messages[idx].reactions.contains(where: { $0.id == reaction.id }) else { return }
                self.messages[idx].reactions.append(reaction)
                self.persistReactions(messageId: messageId)
                self.errorMessage = "Couldn't remove reaction"
            }
        }
    }

    private func persistReactions(messageId: String) {
        guard let message = messages.first(where: { $0.id == messageId }) else { return }
        Task { try? await ChatLocalStore.shared.updateReactions(messageId: messageId, reactions: message.reactions) }
    }

    func deleteMessage(_ messageId: String) {
        guard let idx = messages.firstIndex(where: { $0.id == messageId }),
              messages[idx].canUnsend(currentUserId: currentUserId)
        else { return }

        let original = messages[idx]
        messages[idx] = original.withDeleted(at: Date())
        persistDeletion(messageId: messageId)

        if messageId.hasPrefix("pending-") {
            pendingPostAckActions[messageId, default: []].append { [weak self] real in
                self?.sendDeleteMessage(messageId: real.id, original: real)
            }
            return
        }

        sendDeleteMessage(messageId: messageId, original: original)
    }

    private func sendDeleteMessage(messageId: String, original: BackendMessage) {
        Task {
            do {
                let real = try await NetworkService.shared.deleteMessage(messageId)
                guard let idx = self.messages.firstIndex(where: { $0.id == messageId }) else { return }
                self.messages[idx] = real
                self.persistDeletion(messageId: messageId)
            } catch {
                print("DEBUG: ConversationViewModel failed to delete message: \(error)")
                guard let idx = self.messages.firstIndex(where: { $0.id == messageId }) else { return }
                self.messages[idx] = original
                self.persistDeletion(messageId: messageId)
                self.errorMessage = "Couldn't delete message"
            }
        }
    }

    func beginEditing(messageId: String) {
        guard let message = messages.first(where: { $0.id == messageId }),
              message.canEdit(currentUserId: currentUserId) else {
            errorMessage = "This message can no longer be edited"
            return
        }
        MessageEditState.shared.begin(messageId: messageId, text: message.textContent ?? "") { [weak self] id, text in
            self?.commitEdit(messageId: id, newText: text)
        }
    }

    func commitEdit(messageId: String, newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { MessageEditState.shared.end() }
        guard let idx = messages.firstIndex(where: { $0.id == messageId }) else { return }
        let original = messages[idx]
        guard !trimmed.isEmpty, trimmed != (original.textContent ?? "") else { return }
        guard original.canEdit(currentUserId: currentUserId) else {
            errorMessage = "Too much time has passed to edit this message"
            return
        }

        messages[idx] = original.withEdited(text: trimmed, at: Date())
        persistEdit(messageId: messageId)

        Task {
            do {
                let real = try await NetworkService.shared.editMessage(messageId, text: trimmed)
                guard let i = self.messages.firstIndex(where: { $0.id == messageId }) else { return }
                self.messages[i] = self.messages[i].withEdited(
                    text: real.textContent ?? trimmed, at: real.editedAt ?? Date())
                self.persistEdit(messageId: messageId)
            } catch {
                print("DEBUG: ConversationViewModel failed to edit message: \(error)")
                guard let i = self.messages.firstIndex(where: { $0.id == messageId }) else { return }
                self.messages[i] = original
                self.persistEdit(messageId: messageId)
                if case NetworkError.serverError(let code, _) = error, code == 410 {
                    self.errorMessage = "Too much time has passed to edit this message"
                } else {
                    self.errorMessage = "Couldn't edit message"
                }
            }
        }
    }

    private func persistEdit(messageId: String) {
        guard let message = messages.first(where: { $0.id == messageId }) else { return }
        Task { try? await ChatLocalStore.shared.upsertMessages([LocalMessage(message, status: .sent).asBackend]) }
    }

    private func persistDeletion(messageId: String) {
        guard let message = messages.first(where: { $0.id == messageId }) else { return }
        Task { try? await ChatLocalStore.shared.upsertMessages([LocalMessage(message, status: .sent).asBackend]) }
    }

    func openBit(messageId: String) {
        guard let myId = currentUserId,
              let idx = messages.firstIndex(where: { $0.id == messageId }),
              messages[idx].senderId != myId
        else { return }

        let openedAt = Date()
        messages[idx] = messages[idx].withBitOpened(at: openedAt)
        messageReceipts[messageId] = .opened
        BitPrefetchCache.shared.discard(messageId)

        Task {
            try? await ChatLocalStore.shared.markBitOpened(messageId: messageId, openedAt: openedAt)
            try? await NetworkService.shared.markRead(conversationId: conversationId, upToMessageId: messageId, opensBit: true)
        }

        markVisibleMessagesRead()
    }

    func markVisibleMessagesRead(immediate: Bool = false) {
        guard let cursor = safeReadCursorId() else { return }
        NotificationCenter.default.post(
            name: .chatConversationDidMarkRead,
            object: nil,
            userInfo: ["conversationId": conversationId]
        )

        guard myStatus == .accepted else { return }

        markReadDebounceTask?.cancel()

        guard !immediate else {
            markReadDebounceTask = nil
            Task { await self.performMarkRead(upTo: cursor) }
            return
        }

        markReadDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            guard let latestCursor = self.safeReadCursorId() else { return }
            Task { await self.performMarkRead(upTo: latestCursor) }
        }
    }

    private func performMarkRead(upTo cursor: String) async {
        let conversationId = self.conversationId
        let previous = markReadInFlight
        let task = Task {
            await previous?.value
            NotificationCenterManager.shared.beginPendingRead(conversationId)
            do {
                try await NetworkService.shared.markRead(conversationId: conversationId, upToMessageId: cursor)
            } catch {
                print("DEBUG: ConversationViewModel markRead failed for cursor \(cursor): \(error)")
            }
            NotificationCenterManager.shared.endPendingRead(conversationId)
        }
        markReadInFlight = task
        await task.value
    }

    private func safeReadCursorId() -> String? {
        return messages.last(where: { !$0.id.hasPrefix("pending-") })?.id
    }

    func notifyTyping() {
        guard GlobalTypingIndicatorPreference.shared.sendTypingIndicatorsEnabled else { return }
        ChatWebSocketClient.shared.send(.typing(conversationId: conversationId))
    }

    func acceptRequest() {
        guard myStatus == .pending else { return }
        Task {
            do {
                try await NetworkService.shared.acceptConversationRequest(conversationId)
                myStatus = .accepted
                NotificationCenter.default.post(
                    name: .chatConversationRequestDidResolve,
                    object: nil,
                    userInfo: ["conversationId": conversationId, "accepted": true]
                )
            } catch {
                print("DEBUG: ConversationViewModel acceptRequest failed: \(error)")
                errorMessage = "Couldn't accept request"
            }
        }
    }

    func declineRequest() async -> Bool {
        guard myStatus == .pending else { return false }
        do {
            try await NetworkService.shared.hideConversation(conversationId)
            try? await ChatLocalStore.shared.deleteConversation(conversationId: conversationId)
            NotificationCenter.default.post(
                name: .chatConversationRequestDidResolve,
                object: nil,
                userInfo: ["conversationId": conversationId, "accepted": false]
            )
            return true
        } catch {
            print("DEBUG: ConversationViewModel declineRequest failed: \(error)")
            errorMessage = "Couldn't decline request"
            return false
        }
    }

    func setMuted(_ until: Date?) async {
        let previous = mutedUntil
        mutedUntil = until
        do {
            try await NetworkService.shared.updateConversationSettings(
                conversationId,
                body: UpdateConversationSettingsRequestBody(mutedUntil: .some(until), archived: nil, notificationsEnabled: nil)
            )
            try? await ChatLocalStore.shared.patchConversationSettings(conversationId: conversationId, mutedUntil: until, archived: nil)
            NotificationCenter.default.post(
                name: .chatConversationSettingsDidChange,
                object: nil,
                userInfo: ["conversationId": conversationId, "mutedUntil": until ?? NSNull()]
            )
        } catch {
            mutedUntil = previous
            errorMessage = "Couldn't update mute setting"
        }
    }

    func toggleMuted() async {
        await setMuted(isMuted ? nil : Date.distantFuture)
    }

    func setArchived(_ isArchived: Bool) async {
        let previousArchived = archived
        let previousMuted = mutedUntil
        archived = isArchived
        mutedUntil = isArchived ? .distantFuture : nil
        do {
            try await NetworkService.shared.updateConversationSettings(
                conversationId,
                body: UpdateConversationSettingsRequestBody(mutedUntil: nil, archived: isArchived, notificationsEnabled: nil)
            )
            try? await ChatLocalStore.shared.patchConversationSettings(
                conversationId: conversationId,
                mutedUntil: mutedUntil,
                archived: isArchived
            )
            NotificationCenter.default.post(
                name: .chatConversationSettingsDidChange,
                object: nil,
                userInfo: [
                    "conversationId": conversationId,
                    "mutedUntil": mutedUntil ?? NSNull(),
                    "archived": isArchived,
                ]
            )
        } catch {
            archived = previousArchived
            mutedUntil = previousMuted
            errorMessage = "Couldn't update archive setting"
        }
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
            if let rawMutedUntil = notification.userInfo?["mutedUntil"] {
                self.mutedUntil = rawMutedUntil as? Date
            }
            if let archived = notification.userInfo?["archived"] as? Bool {
                self.archived = archived
            }
            if let isBlocked = notification.userInfo?["isBlocked"] as? Bool {
                self.isBlocked = isBlocked
            }
            if let rawImage = notification.userInfo?["groupImageUrl"] {
                self.groupImageUrl = rawImage as? String
            }
        }
    }

    private func subscribeToSocketEvents() {
        guard socketToken == nil else { return }
        if !isGroup {
            ChatWebSocketClient.shared.setPresenceWatch(source: presenceWatchSource, ids: [otherParticipantId])
        }
        socketToken = ChatWebSocketClient.shared.subscribe { [weak self] event in
            guard let self else { return }
            Task { @MainActor in
                switch event {
                case .connected:
                    await self.reconcileForeground()

                case .newMessage(let conversationId, let message):
                    guard conversationId == self.conversationId else { return }
                    self.mergeIncoming([message])
                    self.prefetchBits(in: [message])
                    self.prefetchMedia(in: [message])
                    try? await ChatLocalStore.shared.upsertMessages([message])
                    if message.senderId == self.otherParticipantId, self.otherStatus != .accepted {
                        self.otherStatus = .accepted
                    }
                    if self.isGroup, message.contentType == .system {
                        Task { await self.refreshGroupDetails() }
                    }

                case .messageAck(let clientTempId, let message):
                    if let continuation = self.pendingAcks.removeValue(forKey: clientTempId) {
                        continuation.resume(returning: message)
                    }

                case .delivered(let messageId, let userId):
                    guard let myId = self.currentUserId, userId != myId,
                          self.messages.contains(where: { $0.id == messageId })
                    else { return }
                    if self.messageReceipts[messageId] != .opened {
                        self.messageReceipts[messageId] = .delivered
                    }
                    self.groupDeliveredUserIds[messageId, default: []].insert(userId)

                    let deliveredAt = Date()
                    Task { try? await ChatLocalStore.shared.upsertMessageReceipt(messageId: messageId, userId: userId, deliveredAt: deliveredAt, openedAt: nil) }
                    if self.messageReceiptDetails[messageId] != nil {
                        let existingOpenedAt = self.messageReceiptDetails[messageId]?[userId]?.openedAt
                        self.messageReceiptDetails[messageId]?[userId] = MessageReceiptDetail(userId: userId, deliveredAt: deliveredAt, openedAt: existingOpenedAt)
                    }

                case .opened(let conversationId, let upToMessageId, let userId, let readAt, let opensBit):
                    guard conversationId == self.conversationId,
                          let myId = self.currentUserId, userId != myId
                    else { return }

                    self.groupReadCursors[userId] = GroupReadCursor(messageId: upToMessageId, readAt: readAt ?? Date())

                    guard let upToIdx = self.messages.firstIndex(where: { $0.id == upToMessageId }) else {
                        Task { await self.reconcileNewest() }
                        return
                    }

                    var newlyOpenedBitIds: [String] = []
                    let effectiveReadAt = readAt ?? Date()
                    var messagesToPersist: [BackendMessage] = []
                    for idx in 0...upToIdx where self.messages[idx].senderId == myId {
                        var message = self.messages[idx]

                        let existingDetail = self.messageReceiptDetails[message.id]?[userId]
                        let existingDeliveredAt = existingDetail?.deliveredAt
                        let existingOpenedAt = existingDetail?.openedAt ?? (self.isGroup ? nil : message.openedAt)
                        let resolvedDeliveredAt = existingDeliveredAt ?? effectiveReadAt
                        let resolvedOpenedAt = existingOpenedAt ?? effectiveReadAt
                        Task { try? await ChatLocalStore.shared.upsertMessageReceipt(messageId: message.id, userId: userId, deliveredAt: resolvedDeliveredAt, openedAt: resolvedOpenedAt) }
                        self.messageReceiptDetails[message.id, default: [:]][userId] = MessageReceiptDetail(
                            userId: userId,
                            deliveredAt: resolvedDeliveredAt,
                            openedAt: resolvedOpenedAt
                        )

                        let isLiveBit = message.contentType == .bit && message.deletedAt == nil
                        if isLiveBit && !(opensBit && message.id == upToMessageId) {
                            continue
                        }
                        if isLiveBit {
                            message = message.withBitOpened(at: Date())
                            newlyOpenedBitIds.append(message.id)
                        }
                        if !self.isGroup {
                            self.messageReceipts[message.id] = .opened
                            if !(message.opened && message.openedAt != nil) {
                                message = message.withOpened(at: effectiveReadAt)
                                messagesToPersist.append(message)
                            }
                        }
                        self.messages[idx] = message
                    }
                    if !messagesToPersist.isEmpty {
                        Task { try? await ChatLocalStore.shared.upsertMessages(messagesToPersist) }
                    }
                    if !newlyOpenedBitIds.isEmpty {
                        let openedAt = Date()
                        Task {
                            for id in newlyOpenedBitIds {
                                try? await ChatLocalStore.shared.markBitOpened(messageId: id, openedAt: openedAt)
                            }
                        }
                    }

                case .typing(let conversationId, let userId):
                    guard GlobalTypingIndicatorPreference.shared.sendTypingIndicatorsEnabled else { return }
                    guard conversationId == self.conversationId, userId != self.currentUserId else { return }
                    self.typingUserIds.insert(userId)
                    self.typingResetTasks[userId]?.cancel()
                    self.typingResetTasks[userId] = Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        guard !Task.isCancelled else { return }
                        self.typingUserIds.remove(userId)
                        self.typingResetTasks[userId] = nil
                    }

                case .locationUpdate(let conversationId, let userId, let lat, let lng):
                    guard conversationId == self.conversationId, userId != self.currentUserId else { return }
                    LiveLocationPositions.shared.update(conversationId: conversationId, userId: userId, lat: lat, lng: lng)
                    if userId == self.otherParticipantId { self.incomingLiveLocation = (lat, lng) }

                case .locationShareStopped(let conversationId, let messageId, let userId):
                    guard conversationId == self.conversationId, userId != self.currentUserId else { return }
                    LiveLocationPositions.shared.clear(conversationId: conversationId, userId: userId)
                    if userId == self.otherParticipantId { self.incomingLiveLocation = nil }
                    if let idx = self.messages.firstIndex(where: { $0.id == messageId }) {
                        self.messages[idx] = self.messages[idx].withExpiresAt(Date())
                        try? await ChatLocalStore.shared.upsertMessages([LocalMessage(self.messages[idx], status: .sent).asBackend])
                    }

                case .presenceChanged(let userId, let online, let lastSeen):
                    guard userId == self.otherParticipantId else { return }
                    self.otherPresence = PresenceInfo(online: online, lastSeen: lastSeen ?? self.otherPresence.lastSeen)

                case .reactionUpdated(let messageId, let reactions):
                    guard let idx = self.messages.firstIndex(where: { $0.id == messageId }) else { return }
                    self.messages[idx].reactions = reactions
                    try? await ChatLocalStore.shared.updateReactions(messageId: messageId, reactions: reactions)

                case .messageDeleted(_, let messageId, let deletedAt):
                    guard let idx = self.messages.firstIndex(where: { $0.id == messageId }) else { return }
                    self.messages[idx] = self.messages[idx].withDeleted(at: deletedAt ?? Date())
                    try? await ChatLocalStore.shared.upsertMessages([LocalMessage(self.messages[idx], status: .sent).asBackend])
                    self.markVisibleMessagesRead()

                case .messageEdited(_, let messageId, let text, let editedAt):
                    guard let idx = self.messages.firstIndex(where: { $0.id == messageId }),
                          self.messages[idx].deletedAt == nil else { return }
                    if MessageEditState.shared.messageId == messageId { return }
                    self.messages[idx] = self.messages[idx].withEdited(text: text, at: editedAt ?? Date())
                    try? await ChatLocalStore.shared.upsertMessages([LocalMessage(self.messages[idx], status: .sent).asBackend])

                default:
                    break
                }
            }
        }
    }

    private var ackedDeliveryIds: Set<String> = []

    private func ackDelivery(for batch: [BackendMessage]) {
        guard let myId = currentUserId else { return }
        for message in batch {
            guard message.senderId != myId, message.senderId == otherParticipantId else { continue }
            guard !message.delivered, !ackedDeliveryIds.contains(message.id) else { continue }
            ackedDeliveryIds.insert(message.id)
            ChatWebSocketClient.shared.send(.delivered(messageId: message.id))
        }
    }

    private func mergeIncoming(_ incoming: [BackendMessage]) {
        guard !incoming.isEmpty else { return }

        var idToIndex: [String: Int] = Dictionary(uniqueKeysWithValues: messages.enumerated().map { ($1.id, $0) })
        var toInsert: [BackendMessage] = []
        for m in incoming {
            if let idx = idToIndex[m.id] {
                messages[idx] = m
            } else {
                toInsert.append(m)
            }
        }
        guard !toInsert.isEmpty else { return }

        for m in toInsert.sorted(by: { $0.createdAt < $1.createdAt }) {
            let index = sortedInsertionIndex(for: m.createdAt)
            messages.insert(m, at: index)
            idToIndex[m.id] = index
        }
    }

    private func prefetchBits(in batch: [BackendMessage]) {
        guard let myId = currentUserId else { return }
        for message in batch {
            guard message.contentType == .bit,
                  message.senderId != myId,
                  message.deletedAt == nil,
                  (message.expiresAt.map { $0 > Date() } ?? true),
                  messageReceipts[message.id] != .opened,
                  let urlString = message.mediaUrl,
                  let url = URL(string: urlString)
            else { continue }
            BitPrefetchCache.shared.prefetch(messageId: message.id, remoteURL: url)
        }
    }

    private func prefetchMedia(in batch: [BackendMessage]) {
        guard let myId = currentUserId else { return }
        let eligibleTypes: Set<MessageContentType> = [.image, .video, .file]
        for message in batch {
            guard eligibleTypes.contains(message.contentType),
                  message.senderId != myId,
                  message.deletedAt == nil,
                  let urlString = message.mediaUrl,
                  let url = URL(string: urlString)
            else { continue }
            Task {
                _ = try? await MediaFileCache.shared.localURL(for: url, cacheKey: message.id)
            }
        }
    }

    private func sortedInsertionIndex(for date: Date) -> Int {
        var low = 0
        var high = messages.count
        while low < high {
            let mid = (low + high) / 2
            if messages[mid].createdAt <= date {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}

extension Notification.Name {
    static let chatConversationRequestDidResolve = Notification.Name("chatConversationRequestDidResolve")
    static let chatConversationSettingsDidChange = Notification.Name("chatConversationSettingsDidChange")
}
