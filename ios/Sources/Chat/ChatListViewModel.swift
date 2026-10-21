import Foundation
import Combine

@MainActor
final class ChatListViewModel: ObservableObject {
    @Published var conversations: [BackendConversationSummary] = [] {
        didSet {
            resolveMissingBitDirections()
            resolveUnopenedBitBundle()
            updatePresenceWatch()
        }
    }
    @Published var selectedView: ConversationListView = .messages
    @Published var selectedKind: ConversationKindFilter = .all
    @Published var isLoading = false
    @Published var errorMessage: String?

    private static let presenceWatchRowLimit = 50

    private func updatePresenceWatch() {
        let ids = conversations
            .prefix(Self.presenceWatchRowLimit)
            .filter { !$0.isGroup }
            .map { $0.otherParticipantId }
        ChatWebSocketClient.shared.setPresenceWatch(source: "chat-list", ids: Set(ids))
    }

    @Published var searchText = ""
    @Published var searchResults: [NearbyUserResult] = []
    @Published var isSearching = false
    @Published var openingUserId: String?
    private var searchTask: Task<Void, Never>?
    private static let searchDebounceNanos: UInt64 = 250_000_000

    @Published var chatSettings: ChatSettings?
    @Published var isLoadingChatSettings = false

    private var generation = 0
    private var nextCursor: String?
    private var hasMorePages = true
    private static let pageSize = 20
    private var socketToken: ChatWebSocketClient.SubscriptionToken?

    @Published var unreadCountsByView: [ConversationListView: Int] = [.messages: 0, .invitations: 0]

    @Published private(set) var isActive = false

    private var badgeCancellables = Set<AnyCancellable>()

    @Published private(set) var sendingBitCounts: [String: Int] = [:]

    @Published private(set) var typingUserIdsByConversation: [String: Set<String>] = [:]
    private struct TypingKey: Hashable {
        let conversationId: String
        let userId: String
    }
    private var typingResetTasks: [TypingKey: Task<Void, Never>] = [:]
    private static let typingTimeoutNanos: UInt64 = 3_000_000_000

    private enum SentReceiptLevel: Int, Comparable {
        case sent, delivered, opened
        static func < (lhs: SentReceiptLevel, rhs: SentReceiptLevel) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private struct LastMessageRef {
        let messageId: String
        let isMine: Bool
        let createdAt: Date
        var receipt: SentReceiptLevel
    }
    @Published private var lastMessageRefs: [String: LastMessageRef] = [:]

    enum LastMessageDirection {
        case sent, received
        case unknown
    }

    private var directionResolutionsInFlight: Set<String> = []
    private var directionAttempts: [String: Date] = [:]
    private static let directionRetryInterval: TimeInterval = 30

    @Published private(set) var unopenedReceivedBits: [String: [BackendMessage]] = [:]

    private var bundleResolvedConversationIds: Set<String> = []
    private var bundleResolutionsInFlight: Set<String> = []
    private var bundleResolutionAttempts: [String: Date] = [:]
    private static let bundleRetryInterval: TimeInterval = 30
    private static let bundleFetchCap = 50

    private var earlyReceipts: [String: SentReceiptLevel] = [:]
    private var earlyReceiptOrder: [String] = []
    private static let earlyReceiptCapacity = 32

    private var receiptReconcilesInFlight: Set<String> = []

    init() {
        subscribeToBadgeEvents()
        subscribeToReadNotifications()
        subscribeToRequestResolutions()
        subscribeToSettingsChangeNotifications()
        subscribeToLocallyCachedUnopenedBits()
        ChatWebSocketClient.shared.conversationDisplayNameLookup = { [weak self] id in
            self?.cachedDisplayName(for: id)
        }
        ChatWebSocketClient.shared.conversationIsGroupLookup = { [weak self] id in
            self?.cachedIsGroup(for: id) ?? false
        }
        NotificationCenterManager.shared.$unreadMessagesCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in self?.unreadCountsByView[.messages] = count }
            .store(in: &badgeCancellables)
        NotificationCenterManager.shared.$unreadMessageRequestsCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in self?.unreadCountsByView[.invitations] = count }
            .store(in: &badgeCancellables)
        Task { await loadView(.messages) }
        Task { await NotificationCenterManager.shared.refreshMessageBadges() }
    }

    func setActive(_ active: Bool) async {
        guard active != isActive else { return }
        isActive = active
        if active {
            subscribeToSocketEvents()
            await refresh()
        } else {
            ChatWebSocketClient.shared.unsubscribe(socketToken)
            socketToken = nil
            clearAllTyping()
        }
    }

    func selectView(_ view: ConversationListView) async {
        guard view != selectedView else { return }
        selectedView = view
        nextCursor = nil
        hasMorePages = true
        await loadView(view)
    }

    func selectKind(_ kind: ConversationKindFilter) async {
        guard kind != selectedKind else { return }
        selectedKind = kind
        nextCursor = nil
        hasMorePages = true
        await loadView(selectedView)
    }

    private func loadView(_ view: ConversationListView) async {
        generation += 1
        let myGeneration = generation
        isLoading = true
        defer { isLoading = false }
        loadPinnedConversationIds()

        if let cached = try? await ChatLocalStore.shared.fetchConversations(view: view, kind: selectedKind), myGeneration == generation {
            await ParticipantColorStore.shared.assignColorsIfNeeded(for: cached)
            await GroupAvatarStore.shared.assignAvatarsIfNeeded(for: cached)
            conversations = cached
        }

        do {
            let (rawFresh, cursor) = try await NetworkService.shared.listConversationsCursor(view: view, cursor: nil, pageSize: Self.pageSize, kind: selectedKind)
            var fresh = rawFresh
            guard myGeneration == generation else { return }
            nextCursor = cursor
            hasMorePages = cursor != nil
            let pending = NotificationCenterManager.shared.pendingReadConversationIds
            if !pending.isEmpty {
                for idx in fresh.indices where pending.contains(fresh[idx].conversationId) {
                    fresh[idx].unreadCount = 0
                }
            }
            try? await ChatLocalStore.shared.upsertConversations(fresh)
            await ParticipantColorStore.shared.assignColorsIfNeeded(for: fresh)
            await GroupAvatarStore.shared.assignAvatarsIfNeeded(for: fresh)
            conversations = fresh
            reconcileLastMessageRefsWithRows()
            Task { await self.hydrateEncryptedPreviews() }
            if view == .messages || view == .invitations {
                await NotificationCenterManager.shared.refreshMessageBadges()
            }
        } catch {
            print("DEBUG: ChatListViewModel failed to reconcile \(view): \(error)")
            if NetworkMonitor.shared.isConnectedNow {
                errorMessage = "Couldn't refresh conversations"
            }
        }
    }

    func refresh() async {
        nextCursor = nil
        hasMorePages = true
        await loadView(selectedView)
    }

    func loadMore() async {
        guard !isLoading, hasMorePages else { return }
        let cursorToUse = nextCursor
        let myGeneration = generation
        let requestedView = selectedView
        let requestedKind = selectedKind
        do {
            let (more, cursor) = try await NetworkService.shared.listConversationsCursor(view: requestedView, cursor: cursorToUse, pageSize: Self.pageSize, kind: requestedKind)
            guard myGeneration == generation,
                  requestedView == selectedView,
                  requestedKind == selectedKind else { return }
            nextCursor = cursor
            hasMorePages = cursor != nil
            let existingIds = Set(conversations.map(\.conversationId))
            let deduped = more.filter { !existingIds.contains($0.conversationId) }
            try? await ChatLocalStore.shared.upsertConversations(deduped)
            await ParticipantColorStore.shared.assignColorsIfNeeded(for: deduped)
            await GroupAvatarStore.shared.assignAvatarsIfNeeded(for: deduped)
            guard myGeneration == generation,
                  requestedView == selectedView,
                  requestedKind == selectedKind else { return }
            let latestIds = Set(conversations.map(\.conversationId))
            conversations.append(contentsOf: deduped.filter { !latestIds.contains($0.conversationId) })
            Task { await self.hydrateEncryptedPreviews() }
        } catch {
            print("DEBUG: ChatListViewModel loadMore failed: \(error)")
        }
    }

    private func hydrateEncryptedPreviews() async {
        let targets = conversations
            .filter { E2EEService.shared.needsPreviewHydration($0) }
            .prefix(8)
            .map(\.conversationId)
        for id in targets {
            guard let text = await E2EEService.shared.latestPreview(conversationId: id),
                  let idx = conversations.firstIndex(where: { $0.conversationId == id }),
                  conversations[idx].lastMessagePreview == E2EEPlaceholder.previewFallback
            else { continue }
            var row = conversations[idx]
            row.lastMessagePreview = text
            conversations[idx] = row
            Task { try? await ChatLocalStore.shared.upsertConversation(row) }
        }
    }

    @Published var isRestoring = false
    @Published var restoreResultMessage: String?

    private static let restorePageSize = 50
    private static let restoreMaxPages = 40

    func restoreConversations() async {
        guard !isRestoring else { return }
        isRestoring = true
        restoreResultMessage = nil
        defer { isRestoring = false }

        var restoredCount = 0
        var encounteredError = false

        for view in ConversationListView.allCases {
            var page = 0
            while page < Self.restoreMaxPages {
                do {
                    let batch = try await NetworkService.shared.listConversations(view: view, page: page, pageSize: Self.restorePageSize, excludeLeftGroups: true)
                    if batch.isEmpty { break }
                    try? await ChatLocalStore.shared.upsertConversations(batch)
                    await ParticipantColorStore.shared.assignColorsIfNeeded(for: batch)
                    await GroupAvatarStore.shared.assignAvatarsIfNeeded(for: batch)
                    restoredCount += batch.count
                    if batch.count < Self.restorePageSize { break }
                    page += 1
                } catch {
                    print("DEBUG: ChatListViewModel restore failed for \(view) page \(page): \(error)")
                    encounteredError = true
                    break
                }
            }
        }

        if let cached = try? await ChatLocalStore.shared.fetchConversations(view: selectedView, kind: selectedKind) {
            await ParticipantColorStore.shared.assignColorsIfNeeded(for: cached)
            await GroupAvatarStore.shared.assignAvatarsIfNeeded(for: cached)
            conversations = cached
        }

        restoreResultMessage = encounteredError
            ? "Restored what we could — some conversations may be missing. Pull to refresh to try again."
            : (restoredCount > 0
                ? "Restored \(restoredCount) conversation\(restoredCount == 1 ? "" : "s")."
                : "No conversations found for this account.")
    }

    func onSearchTextChanged() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            searchResults = []
            isSearching = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: Self.searchDebounceNanos)
            guard !Task.isCancelled else { return }
            isSearching = true
            defer { isSearching = false }
            do {
                let response: ApiResponse<[NearbyUserResult]> = try await NetworkService.shared.get(
                    endpoint: "/search/users",
                    queryItems: [
                        URLQueryItem(name: "q", value: query),
                        URLQueryItem(name: "page", value: "0"),
                    ]
                )
                guard !Task.isCancelled, searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                let currentUserId = AuthService.shared.user?.id
                searchResults = (response.data ?? []).filter { $0.id != currentUserId }
            } catch {
                guard !Task.isCancelled else { return }
                print("DEBUG: ChatListViewModel search failed: \(error)")
            }
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        searchText = ""
        searchResults = []
        isSearching = false
    }

    func openConversation(with user: NearbyUserResult) async -> BackendConversation? {
        openingUserId = user.id
        defer { openingUserId = nil }
        do {
            let conversation = try await openOrCreateConversation(otherId: user.id, otherType: .user)
            clearSearch()
            await refresh()
            return conversation
        } catch {
            errorMessage = "Couldn't open conversation. Try again."
            return nil
        }
    }

    private static let chatSettingsCacheKey = "me:chat-settings"

    private func cacheChatSettings(_ settings: ChatSettings) {
        OfflineCache.shared.saveCodable(settings, key: Self.chatSettingsCacheKey)
    }

    func loadChatSettings() async {
        isLoadingChatSettings = true
        defer { isLoadingChatSettings = false }

        if chatSettings == nil {
            chatSettings = OfflineCache.shared.loadCodable(ChatSettings.self, key: Self.chatSettingsCacheKey)
        }
        guard NetworkMonitor.shared.isConnectedNow else { return }

        do {
            let fresh = try await NetworkService.shared.getChatSettings()
            chatSettings = fresh
            cacheChatSettings(fresh)
        } catch {
            if NetworkMonitor.shared.isConnectedNow {
                errorMessage = "Couldn't load chat settings"
            }
        }
    }

    func updateChatName(_ name: String?) async {
        await patchChatSettings(UpdateChatSettingsRequestBody(chatName: name ?? "", onlineStatusVisibility: nil, lastSeenVisibility: nil, readReceiptsEnabled: nil))
    }

    func updateOnlineStatusVisibility(_ visibility: ChatVisibilityLevel) async {
        await patchChatSettings(UpdateChatSettingsRequestBody(chatName: nil, onlineStatusVisibility: visibility, lastSeenVisibility: nil, readReceiptsEnabled: nil))
    }

    func updateLastSeenVisibility(_ visibility: ChatVisibilityLevel) async {
        await patchChatSettings(UpdateChatSettingsRequestBody(chatName: nil, onlineStatusVisibility: nil, lastSeenVisibility: visibility, readReceiptsEnabled: nil))
    }

    func updateReadReceiptsEnabled(_ enabled: Bool) async {
        await patchChatSettings(UpdateChatSettingsRequestBody(chatName: nil, onlineStatusVisibility: nil, lastSeenVisibility: nil, readReceiptsEnabled: enabled))
    }

    func saveChatSettings(chatName: String, onlineStatusVisibility: ChatVisibilityLevel, lastSeenVisibility: ChatVisibilityLevel, readReceiptsEnabled: Bool) async {
        await patchChatSettings(UpdateChatSettingsRequestBody(
            chatName: chatName,
            onlineStatusVisibility: onlineStatusVisibility,
            lastSeenVisibility: lastSeenVisibility,
            readReceiptsEnabled: readReceiptsEnabled
        ))
    }

    private func patchChatSettings(_ body: UpdateChatSettingsRequestBody) async {
        guard NetworkMonitor.shared.isConnectedNow else {
            errorMessage = "You're offline. Chat settings can't be changed right now."
            return
        }
        let previous = chatSettings
        if var updated = chatSettings {
            if let name = body.chatName { updated.chatName = name.isEmpty ? nil : name }
            if let vis = body.onlineStatusVisibility { updated.onlineStatusVisibility = vis }
            if let vis = body.lastSeenVisibility { updated.lastSeenVisibility = vis }
            if let enabled = body.readReceiptsEnabled { updated.readReceiptsEnabled = enabled }
            chatSettings = updated
        }
        do {
            let saved = try await NetworkService.shared.updateChatSettings(body)
            chatSettings = saved
            cacheChatSettings(saved)
        } catch {
            chatSettings = previous
            errorMessage = "Couldn't update chat settings"
        }
    }

    func deleteConversationHistory(_ conversationId: String) async {
        do {
            try await NetworkService.shared.deleteConversationHistory(conversationId)
            try? await ChatLocalStore.shared.deleteConversation(conversationId: conversationId)
            conversations.removeAll { $0.conversationId == conversationId }
            setPinned(conversationId, false)
        } catch {
            errorMessage = "Couldn't delete chat history"
        }
    }

    func clearAllLocalCache() async {
        do {
            try await ChatLocalStore.shared.clearAll()
            await refresh()
        } catch {
            errorMessage = "Couldn't clear cache"
        }
    }

    @Published private(set) var pinnedConversationIds: Set<String> = []

    private var pinnedDefaultsKey: String {
        "chat.pinnedConversationIds.\(AuthService.shared.user?.backendId ?? "anonymous")"
    }

    private func loadPinnedConversationIds() {
        let stored = Set(UserDefaults.standard.stringArray(forKey: pinnedDefaultsKey) ?? [])
        if stored != pinnedConversationIds { pinnedConversationIds = stored }
    }

    func isPinned(_ conversationId: String) -> Bool {
        pinnedConversationIds.contains(conversationId)
    }

    func togglePinned(_ conversationId: String) {
        setPinned(conversationId, !isPinned(conversationId))
    }

    func setPinned(_ conversationId: String, _ pinned: Bool) {
        var ids = pinnedConversationIds
        if pinned { ids.insert(conversationId) } else { ids.remove(conversationId) }
        guard ids != pinnedConversationIds else { return }
        pinnedConversationIds = ids
        UserDefaults.standard.set(ids.sorted(), forKey: pinnedDefaultsKey)
    }

    var displayedConversations: [BackendConversationSummary] {
        let base = selectedKind == .all ? conversations : conversations.filter { selectedKind.includes($0) }
        guard selectedView == .messages, !pinnedConversationIds.isEmpty else { return base }
        let pinned = base.filter { pinnedConversationIds.contains($0.conversationId) }
        guard !pinned.isEmpty else { return base }
        let rest = base.filter { !pinnedConversationIds.contains($0.conversationId) }
        return pinned + rest
    }

    func resolveConversation(id: String) async -> BackendConversationSummary? {
        if let hit = conversations.first(where: { $0.conversationId == id }) { return hit }

        let allViews: [ConversationListView] = [.messages, .invitations, .archives]

        for view in allViews {
            if let cached = try? await ChatLocalStore.shared.fetchConversations(view: view),
               let hit = cached.first(where: { $0.conversationId == id }) {
                return hit
            }
        }

        for view in allViews {
            var cursor: String? = nil
            for _ in 0..<5 {
                guard let (rows, next) = try? await NetworkService.shared
                    .listConversationsCursor(view: view, cursor: cursor, pageSize: Self.pageSize)
                else { break }
                if let hit = rows.first(where: { $0.conversationId == id }) {
                    await ParticipantColorStore.shared.assignColorsIfNeeded(for: [hit])
                    await GroupAvatarStore.shared.assignAvatarsIfNeeded(for: [hit])
                    try? await ChatLocalStore.shared.upsertConversation(hit)
                    return hit
                }
                guard let next else { break }
                cursor = next
            }
        }
        return nil
    }

    func openOrCreateConversation(otherId: String, otherType: ParticipantType) async throws -> BackendConversation {
        try await NetworkService.shared.startDirectConversation(otherId: otherId, otherType: otherType)
    }

    func acceptRequest(_ conversationId: String) async {
        do {
            try await NetworkService.shared.acceptConversationRequest(conversationId)
            conversations.removeAll { $0.conversationId == conversationId }
        } catch {
            errorMessage = "Couldn't accept request"
        }
    }

    func removeConversation(_ conversationId: String) async {
        let removed = conversations.first { $0.conversationId == conversationId }
        conversations.removeAll { $0.conversationId == conversationId }
        do {
            try await NetworkService.shared.hideConversation(conversationId)
            try? await ChatLocalStore.shared.deleteConversation(conversationId: conversationId)
            setPinned(conversationId, false)
        } catch {
            if let removed { conversations.append(removed) }
            errorMessage = "Couldn't remove conversation"
        }
    }

    func setMuted(_ conversationId: String, until: Date?) async {
        await patchOptimistically(conversationId) { $0.mutedUntil = until }
        do {
            try await NetworkService.shared.updateConversationSettings(
                conversationId,
                body: UpdateConversationSettingsRequestBody(mutedUntil: .some(until), archived: nil, notificationsEnabled: nil)
            )
        } catch {
            errorMessage = "Couldn't update mute setting"
        }
        NotificationCenter.default.post(
            name: .chatConversationSettingsDidChange,
            object: nil,
            userInfo: ["conversationId": conversationId, "mutedUntil": until ?? NSNull()]
        )
    }

    func setArchived(_ conversationId: String, archived: Bool) async {
        await patchOptimistically(conversationId) {
            $0.archived = archived
            $0.mutedUntil = archived ? .distantFuture : nil
        }
        do {
            try await NetworkService.shared.updateConversationSettings(
                conversationId,
                body: UpdateConversationSettingsRequestBody(mutedUntil: nil, archived: archived, notificationsEnabled: nil)
            )
        } catch {
            errorMessage = "Couldn't update archive setting"
        }
        if (selectedView == .archives) != archived {
            conversations.removeAll { $0.conversationId == conversationId }
        }
        NotificationCenter.default.post(
            name: .chatConversationSettingsDidChange,
            object: nil,
            userInfo: [
                "conversationId": conversationId,
                "mutedUntil": (archived ? Date.distantFuture : nil) ?? NSNull(),
                "archived": archived,
            ]
        )
    }

    func setNotificationsEnabled(_ conversationId: String, enabled: Bool) async {
        await patchOptimistically(conversationId) { _ in }
        do {
            try await NetworkService.shared.updateConversationSettings(
                conversationId,
                body: UpdateConversationSettingsRequestBody(mutedUntil: nil, archived: nil, notificationsEnabled: enabled)
            )
        } catch {
            errorMessage = "Couldn't update notification setting"
        }
    }

    func chatBlock(_ conversationId: String) async {
        do {
            try await NetworkService.shared.chatBlock(conversationId)
            conversations.removeAll { $0.conversationId == conversationId }
            setPinned(conversationId, false)
        } catch {
            errorMessage = "Couldn't block"
        }
    }

    private func patchOptimistically(_ conversationId: String, _ mutate: (inout BackendConversationSummary) -> Void) async {
        guard let idx = conversations.firstIndex(where: { $0.conversationId == conversationId }) else { return }
        var updated = conversations[idx]
        mutate(&updated)
        conversations[idx] = updated
        try? await ChatLocalStore.shared.upsertConversation(updated)
    }

    private func subscribeToSocketEvents() {
        guard socketToken == nil else { return }
        socketToken = ChatWebSocketClient.shared.subscribe { [weak self] event in
            guard let self else { return }
            Task { @MainActor in
                switch event {
                case .presenceChanged(let userId, let online, let lastSeen):
                    self.updatePresenceDot(for: userId, online: online, lastSeen: lastSeen)
                case .typing(let conversationId, let userId):
                    self.registerTyping(conversationId: conversationId, userId: userId)
                default:
                    break
                }
            }
        }
    }

    private var badgeSocketToken: ChatWebSocketClient.SubscriptionToken?

    private func subscribeToBadgeEvents() {
        guard badgeSocketToken == nil else { return }
        badgeSocketToken = ChatWebSocketClient.shared.subscribe { [weak self] event in
            guard let self else { return }
            Task { @MainActor in
                switch event {
                case .newMessage(let conversationId, let message):
                    self.registerIncomingMessageForBadge(conversationId: conversationId, message: message)
                    self.bumpConversationForNewMessage(conversationId: conversationId, message: message)
                case .messageAck(_, let message):
                    self.bumpConversationForNewMessage(conversationId: message.conversationId, message: message)
                case .delivered(let messageId, let userId):
                    self.applyDelivered(messageId: messageId, userId: userId)
                case .opened(let conversationId, let upToMessageId, let userId, _, let opensBit):
                    self.applyOpened(conversationId: conversationId, upToMessageId: upToMessageId, userId: userId, opensBit: opensBit)
                default:
                    break
                }
            }
        }
    }

    private func registerIncomingMessageForBadge(conversationId: String, message: BackendMessage) {
        guard message.senderId != AuthService.shared.user?.backendId,
              conversationId != ChatWebSocketClient.shared.currentlyOpenConversationId
        else { return }

        if let known = conversations.first(where: { $0.conversationId == conversationId }) {
            let isInvitation = known.status == .pending
            NotificationCenterManager.shared.registerIncomingMessage(id: message.id, isRequest: isInvitation)
            return
        }

        NotificationCenterManager.shared.registerIncomingMessage(id: message.id, isRequest: false)
        Task { await NotificationCenterManager.shared.refreshMessageBadges() }
    }

    private var readObserver: NSObjectProtocol?
    private var settingsChangeObserver: NSObjectProtocol?
    private var unopenedBitsCachedObserver: NSObjectProtocol?

    private func subscribeToReadNotifications() {
        guard readObserver == nil else { return }
        readObserver = NotificationCenter.default.addObserver(
            forName: .chatConversationDidMarkRead,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let conversationId = notification.userInfo?["conversationId"] as? String else { return }
            self.clearUnread(for: conversationId)
        }
    }

    private var requestResolutionObserver: NSObjectProtocol?

    private func subscribeToRequestResolutions() {
        guard requestResolutionObserver == nil else { return }
        requestResolutionObserver = NotificationCenter.default.addObserver(
            forName: .chatConversationRequestDidResolve,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let conversationId = notification.userInfo?["conversationId"] as? String else { return }
            self.conversations.removeAll { $0.conversationId == conversationId }
        }
    }

    private func subscribeToLocallyCachedUnopenedBits() {
        guard unopenedBitsCachedObserver == nil else { return }
        unopenedBitsCachedObserver = NotificationCenter.default.addObserver(
            forName: .chatLocalStoreDidCacheUnopenedBits,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let conversationId = notification.userInfo?["conversationId"] as? String,
                  let bits = notification.userInfo?["messages"] as? [BackendMessage] else { return }
            var bundle = self.unopenedReceivedBits[conversationId] ?? []
            for bit in bits where !bundle.contains(where: { $0.id == bit.id }) {
                bundle.append(bit)
            }
            bundle.sort { $0.createdAt < $1.createdAt }
            self.unopenedReceivedBits[conversationId] = bundle
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
                  let conversationId = notification.userInfo?["conversationId"] as? String else { return }
            let mutedUntilProvided = notification.userInfo?["mutedUntil"] != nil
            let mutedUntil = (notification.userInfo?["mutedUntil"]).flatMap { $0 as? Date }
            let archived = notification.userInfo?["archived"] as? Bool
            let isBlocked = notification.userInfo?["isBlocked"] as? Bool
            let groupImageProvided = notification.userInfo?["groupImageUrl"] != nil
            let groupImageUrl = notification.userInfo?["groupImageUrl"] as? String
            Task {
                await self.patchOptimistically(conversationId) {
                    if groupImageProvided { $0.groupImageUrl = groupImageUrl }
                    if mutedUntilProvided { $0.mutedUntil = mutedUntil }
                    if let archived { $0.archived = archived }
                    if let isBlocked { $0.isBlocked = isBlocked }
                }
                if archived == true { await self.setPinned(conversationId, false) }
            }
        }
    }

    private func cachedDisplayName(for conversationId: String) -> String? {
        guard let summary = conversations.first(where: { $0.conversationId == conversationId }) else { return nil }
        if summary.isGroup {
            return summary.groupName
        }
        return summary.displayName
    }

    private func cachedIsGroup(for conversationId: String) -> Bool {
        conversations.first(where: { $0.conversationId == conversationId })?.isGroup ?? false
    }

    private func clearUnread(for conversationId: String) {
        unopenedReceivedBits[conversationId] = nil
        bundleResolvedConversationIds.remove(conversationId)

        guard let idx = conversations.firstIndex(where: { $0.conversationId == conversationId }),
              conversations[idx].unreadCount > 0 else { return }

        let hadUnread = conversations[idx].unreadCount
        conversations[idx].unreadCount = 0
        let view: ConversationListView = conversations[idx].status == .pending ? .invitations : .messages
        Task { try? await ChatLocalStore.shared.upsertConversation(conversations[idx]) }

        if view == .invitations {
            NotificationCenterManager.shared.decrementUnreadMessageRequests(by: hadUnread)
        } else {
            NotificationCenterManager.shared.decrementUnreadMessages(by: hadUnread)
        }
    }

    private var pendingConversationFetches: Set<String> = []

    private func fetchAndInsertIfMissing(conversationId: String) async {
        guard !pendingConversationFetches.contains(conversationId) else { return }
        pendingConversationFetches.insert(conversationId)
        defer { pendingConversationFetches.remove(conversationId) }
        do {
            let fresh = try await NetworkService.shared.listConversations(view: selectedView, page: 0, pageSize: 20)
            guard let match = fresh.first(where: { $0.conversationId == conversationId }) else { return }
            guard !conversations.contains(where: { $0.conversationId == conversationId }) else { return }
            await ParticipantColorStore.shared.assignColorsIfNeeded(for: [match])
            await GroupAvatarStore.shared.assignAvatarsIfNeeded(for: [match])
            let newIndex = conversations.firstIndex {
                (match.lastMessageAt ?? .distantPast) > ($0.lastMessageAt ?? .distantPast)
            } ?? conversations.count
            conversations.insert(match, at: newIndex)
            try? await ChatLocalStore.shared.upsertConversation(match)
        } catch {
            print("DEBUG: ChatListViewModel failed to fetch missing conversation \(conversationId): \(error)")
        }
    }

    private func bumpConversationForNewMessage(conversationId: String, message: BackendMessage) {
        clearTyping(userId: message.senderId, in: conversationId)

        let isMine = message.senderId == AuthService.shared.user?.backendId
        if lastMessageRefs[conversationId]?.messageId != message.id {
            var initialReceipt: SentReceiptLevel = .sent
            if isMine, let early = earlyReceipts.removeValue(forKey: message.id) {
                initialReceipt = early
            }
            lastMessageRefs[conversationId] = LastMessageRef(
                messageId: message.id,
                isMine: isMine,
                createdAt: message.createdAt,
                receipt: initialReceipt
            )
            if !isMine, message.contentType == .bit, message.deletedAt == nil,
               message.expiresAt.map({ $0 > Date() }) ?? true,
               let urlString = message.mediaUrl, let url = URL(string: urlString) {
                BitPrefetchCache.shared.prefetch(messageId: message.id, remoteURL: url)
            }
        }

        if !isMine, message.contentType == .bit, message.deletedAt == nil,
           message.expiresAt.map({ $0 > Date() }) ?? true {
            var bundle = unopenedReceivedBits[conversationId] ?? []
            if !bundle.contains(where: { $0.id == message.id }) {
                bundle.append(message)
                bundle.sort { $0.createdAt < $1.createdAt }
                unopenedReceivedBits[conversationId] = bundle
            }
        }
        let receipt = lastMessageRefs[conversationId]?.receipt ?? .sent

        guard let idx = conversations.firstIndex(where: { $0.conversationId == conversationId }) else {
            Task { await self.fetchAndInsertIfMissing(conversationId: conversationId) }
            return
        }
        var updated = conversations[idx]
        let preview: String
        switch message.contentType {
        case .bit: preview = "sent a bit"
        case .image: preview = "sent a photo"
        case .video: preview = "sent a video"
        case .voice: preview = "sent a voice message"
        case .location: preview = "shared a location"
        case .file: preview = "sent a file"
        case .text: preview = message.textContent ?? ""
        case .system: preview = message.textContent ?? "Group updated"
        }
        let isFromSomeoneElse = message.senderId != AuthService.shared.user?.backendId
        let countsAsUnread = isFromSomeoneElse && message.contentType != .system
        let wasBlocked = updated.isBlocked
        let wasUsername = updated.username
        updated = BackendConversationSummary(
            conversationId: updated.conversationId,
            isGroup: updated.isGroup,
            groupName: updated.groupName,
            groupImageUrl: updated.groupImageUrl,
            otherParticipantId: updated.otherParticipantId,
            otherParticipantType: updated.otherParticipantType,
            displayName: updated.displayName,
            profileImageUrl: updated.profileImageUrl,
            isFollowing: updated.isFollowing,
            lastMessagePreview: preview,
            lastMessageContentType: message.contentType,
            lastMessageAt: message.createdAt,
            lastMessageDelivered: receipt >= .delivered,
            lastMessageOpened: receipt == .opened,
            unreadCount: countsAsUnread ? updated.unreadCount + 1 : updated.unreadCount,
            status: updated.status,
            otherStatus: updated.otherStatus,
            archived: updated.archived,
            mutedUntil: updated.mutedUntil,
            presence: updated.presence
        )
        updated.isBlocked = wasBlocked
        updated.username = wasUsername
        updated.lastMessageSenderId = message.senderId
        conversations.remove(at: idx)
        let newIndex = conversations.firstIndex {
            (updated.lastMessageAt ?? .distantPast) > ($0.lastMessageAt ?? .distantPast)
        } ?? conversations.count
        conversations.insert(updated, at: newIndex)
        Task { try? await ChatLocalStore.shared.upsertConversation(updated) }
    }

    private var myUserId: String? { AuthService.shared.user?.backendId }

    func beginSendingBit(in conversationId: String) {
        sendingBitCounts[conversationId, default: 0] += 1
    }

    func endSendingBit(in conversationId: String) {
        guard let count = sendingBitCounts[conversationId] else { return }
        sendingBitCounts[conversationId] = count > 1 ? count - 1 : nil
    }

    func isSendingBit(in conversationId: String) -> Bool {
        sendingBitCounts[conversationId] != nil
    }

    func registerSentMessage(_ message: BackendMessage) {
        bumpConversationForNewMessage(conversationId: message.conversationId, message: message)
    }

    private func applyDelivered(messageId: String, userId: String) {
        guard userId != myUserId else { return }

        if let conversationId = lastMessageRefs.first(where: { $0.value.isMine && $0.value.messageId == messageId })?.key {
            raiseReceipt(.delivered, in: conversationId)
            return
        }

        stashEarlyReceipt(.delivered, for: messageId)
        let isUndeliveredBitRowForSender: (BackendConversationSummary) -> Bool = { [self] row in
            guard !row.isGroup, row.otherParticipantId == userId else { return false }
            guard self.lastMessageDirection(for: row) != .received else { return false }
            return row.lastMessageContentType == .bit && !row.lastMessageDelivered
        }
        if let row = conversations.first(where: isUndeliveredBitRowForSender),
           lastMessageRefs[row.conversationId] == nil {
            Task { await reconcileReceiptState(for: row.conversationId) }
        }
    }

    private func applyOpened(conversationId: String, upToMessageId: String, userId: String, opensBit: Bool) {
        guard userId != myUserId,
              let idx = conversations.firstIndex(where: { $0.conversationId == conversationId })
        else { return }
        guard !conversations[idx].isGroup else { return }

        guard let ref = lastMessageRefs[conversationId], ref.isMine, ref.messageId == upToMessageId else {
            guard opensBit else { return }
            stashEarlyReceipt(.opened, for: upToMessageId)
            if lastMessageRefs[conversationId] == nil,
               conversations[idx].lastMessageContentType == .bit,
               !conversations[idx].lastMessageOpened {
                Task { await reconcileReceiptState(for: conversationId) }
            }
            return
        }
        if conversations[idx].lastMessageContentType == .bit && !opensBit { return }
        raiseReceipt(.opened, in: conversationId)
    }

    private func raiseReceipt(_ level: SentReceiptLevel, in conversationId: String) {
        guard var ref = lastMessageRefs[conversationId], level > ref.receipt else { return }
        ref.receipt = level
        lastMessageRefs[conversationId] = ref
        applyReceiptFlags(in: conversationId, delivered: level >= .delivered, opened: level == .opened)
    }

    private func applyReceiptFlags(in conversationId: String, delivered: Bool, opened: Bool) {
        guard let idx = conversations.firstIndex(where: { $0.conversationId == conversationId }) else { return }
        let old = conversations[idx]
        guard old.lastMessageDelivered != delivered || old.lastMessageOpened != opened else { return }
        let updated = rebuilt(old, delivered: delivered, opened: opened)
        conversations[idx] = updated
        Task { try? await ChatLocalStore.shared.upsertConversation(updated) }
    }

    private func rebuilt(_ row: BackendConversationSummary, delivered: Bool, opened: Bool) -> BackendConversationSummary {
        var copy = BackendConversationSummary(
            conversationId: row.conversationId,
            isGroup: row.isGroup,
            groupName: row.groupName,
            groupImageUrl: row.groupImageUrl,
            otherParticipantId: row.otherParticipantId,
            otherParticipantType: row.otherParticipantType,
            displayName: row.displayName,
            profileImageUrl: row.profileImageUrl,
            isFollowing: row.isFollowing,
            lastMessagePreview: row.lastMessagePreview,
            lastMessageContentType: row.lastMessageContentType,
            lastMessageAt: row.lastMessageAt,
            lastMessageDelivered: delivered,
            lastMessageOpened: opened,
            unreadCount: row.unreadCount,
            status: row.status,
            otherStatus: row.otherStatus,
            archived: row.archived,
            mutedUntil: row.mutedUntil,
            presence: row.presence
        )
        copy.isBlocked = row.isBlocked
        copy.username = row.username
        copy.lastMessageSenderId = row.lastMessageSenderId
        return copy
    }

    private func stashEarlyReceipt(_ level: SentReceiptLevel, for messageId: String) {
        if let existing = earlyReceipts[messageId] {
            if level > existing { earlyReceipts[messageId] = level }
            return
        }
        earlyReceipts[messageId] = level
        earlyReceiptOrder.append(messageId)
        if earlyReceiptOrder.count > Self.earlyReceiptCapacity {
            earlyReceipts[earlyReceiptOrder.removeFirst()] = nil
        }
    }

    private func reconcileReceiptState(for conversationId: String) async {
        guard receiptReconcilesInFlight.insert(conversationId).inserted else { return }
        defer { receiptReconcilesInFlight.remove(conversationId) }
        do {
            let fresh = try await NetworkService.shared.listConversations(view: selectedView, page: 0, pageSize: Self.pageSize)
            guard let match = fresh.first(where: { $0.conversationId == conversationId }),
                  let idx = conversations.firstIndex(where: { $0.conversationId == conversationId })
            else { return }
            let current = conversations[idx]
            guard Self.sameInstant(match.lastMessageAt, current.lastMessageAt) else { return }
            let delivered = current.lastMessageDelivered || match.lastMessageDelivered
            let opened = current.lastMessageOpened || match.lastMessageOpened
            applyReceiptFlags(in: conversationId, delivered: delivered, opened: opened)
        } catch {
            print("DEBUG: ChatListViewModel failed to reconcile receipts for \(conversationId): \(error)")
        }
    }

    private static func sameInstant(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return abs(a.timeIntervalSince(b)) < 1
    }

    private func reconcileLastMessageRefsWithRows() {
        for (conversationId, ref) in lastMessageRefs {
            guard let row = conversations.first(where: { $0.conversationId == conversationId }),
                  let rowDate = row.lastMessageAt
            else { continue }
            let delta = rowDate.timeIntervalSince(ref.createdAt)
            if delta > 1 {
                lastMessageRefs[conversationId] = nil
            } else if abs(delta) <= 1, ref.isMine {
                var serverLevel: SentReceiptLevel = .sent
                if row.lastMessageOpened {
                    serverLevel = .opened
                } else if row.lastMessageDelivered {
                    serverLevel = .delivered
                }
                if serverLevel > ref.receipt {
                    var advanced = ref
                    advanced.receipt = serverLevel
                    lastMessageRefs[conversationId] = advanced
                }
            }
        }
    }

    func lastMessageDirection(for summary: BackendConversationSummary) -> LastMessageDirection {
        if let senderId = summary.lastMessageSenderId, let me = myUserId {
            return senderId == me ? .sent : .received
        }
        guard let ref = lastMessageRefs[summary.conversationId],
              Self.sameInstant(ref.createdAt, summary.lastMessageAt)
        else { return .unknown }
        return ref.isMine ? .sent : .received
    }

    func unopenedBitCount(in summary: BackendConversationSummary) -> Int {
        guard !summary.isGroup, summary.status == .accepted else { return 0 }
        return unopenedReceivedBits[summary.conversationId]?.count ?? 0
    }

    func hasUnopenedReceivedBit(in summary: BackendConversationSummary) -> Bool {
        unopenedBitCount(in: summary) > 0
    }

    func unopenedBitBundle(for summary: BackendConversationSummary) -> [BackendMessage] {
        unopenedReceivedBits[summary.conversationId] ?? []
    }

    func markBundleBitPlayed(_ message: BackendMessage, in conversationId: String) {
        var bundle = unopenedReceivedBits[conversationId] ?? []
        guard let idx = bundle.firstIndex(where: { $0.id == message.id }) else { return }
        let played = bundle[0...idx]
        bundle.removeSubrange(0...idx)
        unopenedReceivedBits[conversationId] = bundle.isEmpty ? nil : bundle

        if let idx = conversations.firstIndex(where: { $0.conversationId == conversationId }) {
            let drop = min(played.count, conversations[idx].unreadCount)
            if drop > 0 {
                conversations[idx].unreadCount -= drop
                Task { try? await ChatLocalStore.shared.upsertConversation(conversations[idx]) }
            }
        }

        BitPrefetchCache.shared.discard(message.id)
        let openedAt = Date()
        Task {
            try? await ChatLocalStore.shared.markBitOpened(messageId: message.id, openedAt: openedAt)
            try? await NetworkService.shared.markRead(conversationId: conversationId, upToMessageId: message.id, opensBit: true)
        }
    }

    private func resolveUnopenedBitBundle() {
        for row in conversations {
            guard !row.isGroup, row.status == .accepted, row.unreadCount > 0,
                  !bundleResolvedConversationIds.contains(row.conversationId)
            else { continue }
            let conversationId = row.conversationId
            if let last = bundleResolutionAttempts[conversationId],
               Date().timeIntervalSince(last) < Self.bundleRetryInterval { continue }
            guard bundleResolutionsInFlight.insert(conversationId).inserted else { continue }
            bundleResolutionAttempts[conversationId] = Date()
            let limit = min(row.unreadCount, Self.bundleFetchCap)
            let otherId = row.otherParticipantId
            Task { await fetchUnopenedBitBundle(conversationId: conversationId, otherParticipantId: otherId, limit: limit) }
        }
    }

    private func fetchUnopenedBitBundle(conversationId: String, otherParticipantId: String, limit: Int) async {
        defer { bundleResolutionsInFlight.remove(conversationId) }
        do {
            let recent = try await NetworkService.shared.getMessages(conversationId: conversationId, before: nil, limit: limit)
            let bits = recent.filter {
                $0.contentType == .bit
                    && $0.senderId == otherParticipantId
                    && $0.deletedAt == nil
                    && ($0.expiresAt.map { $0 > Date() } ?? true)
            }.sorted { $0.createdAt < $1.createdAt }

            var merged = unopenedReceivedBits[conversationId] ?? []
            for bit in bits where !merged.contains(where: { $0.id == bit.id }) {
                merged.append(bit)
            }
            merged.sort { $0.createdAt < $1.createdAt }
            unopenedReceivedBits[conversationId] = merged.isEmpty ? nil : merged
            bundleResolvedConversationIds.insert(conversationId)

            for bit in bits {
                if let urlString = bit.mediaUrl, let url = URL(string: urlString) {
                    BitPrefetchCache.shared.prefetch(messageId: bit.id, remoteURL: url)
                }
            }
        } catch {
            print("DEBUG: ChatListViewModel failed to resolve bit bundle for \(conversationId): \(error)")
        }
    }

    private func resolveMissingBitDirections() {
        for row in conversations {
            guard row.lastMessageContentType == .bit,
                  row.status != .pending,
                  row.lastMessageSenderId == nil,
                  let lastAt = row.lastMessageAt
            else { continue }
            if let ref = lastMessageRefs[row.conversationId], Self.sameInstant(ref.createdAt, lastAt) { continue }

            let conversationId = row.conversationId
            let attemptKey = "\(conversationId)|\(Int(lastAt.timeIntervalSince1970))"
            if let last = directionAttempts[attemptKey], Date().timeIntervalSince(last) < Self.directionRetryInterval { continue }
            guard directionResolutionsInFlight.insert(conversationId).inserted else { continue }
            directionAttempts[attemptKey] = Date()
            Task { await resolveLastMessage(conversationId: conversationId) }
        }
    }

    private func resolveLastMessage(conversationId: String) async {
        defer { directionResolutionsInFlight.remove(conversationId) }
        guard let page = try? await NetworkService.shared.getMessages(conversationId: conversationId, before: nil, limit: 1),
              let message = page.max(by: { $0.createdAt < $1.createdAt }),
              let row = conversations.first(where: { $0.conversationId == conversationId })
        else { return }
        guard Self.sameInstant(message.createdAt, row.lastMessageAt) else { return }
        if let existing = lastMessageRefs[conversationId], Self.sameInstant(existing.createdAt, row.lastMessageAt) { return }

        let isMine = message.senderId == myUserId
        var receipt: SentReceiptLevel = .sent
        if isMine {
            if message.opened {
                receipt = .opened
            } else if message.delivered {
                receipt = .delivered
            }
        }
        lastMessageRefs[conversationId] = LastMessageRef(
            messageId: message.id,
            isMine: isMine,
            createdAt: message.createdAt,
            receipt: receipt
        )
    }

    private func registerTyping(conversationId: String, userId: String) {
        guard GlobalTypingIndicatorPreference.shared.sendTypingIndicatorsEnabled else { return }
        guard userId != myUserId else { return }
        if typingUserIdsByConversation[conversationId]?.contains(userId) != true {
            typingUserIdsByConversation[conversationId, default: []].insert(userId)
        }
        let key = TypingKey(conversationId: conversationId, userId: userId)
        typingResetTasks[key]?.cancel()
        typingResetTasks[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.typingTimeoutNanos)
            guard !Task.isCancelled else { return }
            self?.clearTyping(userId: userId, in: conversationId)
        }
    }

    private func clearTyping(userId: String, in conversationId: String) {
        let key = TypingKey(conversationId: conversationId, userId: userId)
        typingResetTasks[key]?.cancel()
        typingResetTasks[key] = nil
        guard var ids = typingUserIdsByConversation[conversationId], ids.contains(userId) else { return }
        ids.remove(userId)
        typingUserIdsByConversation[conversationId] = ids.isEmpty ? nil : ids
    }

    private func clearAllTyping() {
        for task in typingResetTasks.values { task.cancel() }
        typingResetTasks.removeAll()
        if !typingUserIdsByConversation.isEmpty { typingUserIdsByConversation = [:] }
    }

    func typingText(for summary: BackendConversationSummary) -> String? {
        guard summary.status != .pending,
              let ids = typingUserIdsByConversation[summary.conversationId],
              !ids.isEmpty
        else { return nil }
        guard summary.isGroup else { return "typing" }
        let names = ids.sorted().map { ChatParticipantDirectory.shared.displayName(for: $0) ?? "Someone" }
        switch names.count {
        case 1: return "\(names[0]) is typing"
        case 2: return "\(names[0]) and \(names[1]) are typing"
        default: return "\(names.count) people are typing"
        }
    }

    private func updatePresenceDot(for userId: String, online: Bool, lastSeen: Date?) {
        guard let idx = conversations.firstIndex(where: { $0.otherParticipantId == userId }) else {
            return
        }
        conversations[idx].presence = PresenceInfo(
            online: online,
            lastSeen: lastSeen ?? conversations[idx].presence.lastSeen
        )
    }
    @discardableResult
    func updateChatPrivacy(
        chatsFromFollowersOnly: Bool? = nil,
        groupInvitesFromFollowersOnly: Bool? = nil
    ) async -> Bool {
        guard NetworkMonitor.shared.isConnectedNow else { return false }
        let previous = chatSettings
        if var optimistic = chatSettings {
            if let v = chatsFromFollowersOnly { optimistic.chatsFromFollowersOnly = v }
            if let v = groupInvitesFromFollowersOnly { optimistic.groupInvitesFromFollowersOnly = v }
            chatSettings = optimistic
        }
 
        do {
            let response: ChatApiResponse<ChatSettings> = try await NetworkService.shared.patch(
                endpoint: "/users/me/chat-settings",
                body: UpdateChatSettingsRequestBody(
                    chatsFromFollowersOnly: chatsFromFollowersOnly,
                    groupInvitesFromFollowersOnly: groupInvitesFromFollowersOnly
                )
            )
            guard response.success, let saved = response.data else {
                chatSettings = previous
                return false
            }
            chatSettings = saved
            cacheChatSettings(saved)
            return true
        } catch {
            chatSettings = previous
            return false
        }
    }
}
