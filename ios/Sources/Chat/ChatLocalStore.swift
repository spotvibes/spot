import Foundation
import GRDB

extension Notification.Name {
    static let chatLocalStoreDidCacheUnopenedBits = Notification.Name("chatLocalStoreDidCacheUnopenedBits")
}

struct LocalConversationSummary: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "cached_conversations"

    var conversationId: String
    var otherParticipantId: String
    var otherParticipantType: ParticipantType
    var displayName: String
    var profileImageUrl: String?
    var isFollowing: Bool
    var isBlocked: Bool
    var lastMessagePreview: String
    var lastMessageContentType: MessageContentType?
    var lastMessageAt: Date?
    var lastMessageSenderId: String?
    var lastMessageDelivered: Bool
    var lastMessageOpened: Bool
    var unreadCount: Int
    var status: ParticipantStatus
    var otherStatus: ParticipantStatus
    var archived: Bool
    var mutedUntil: Date?
    var presenceOnline: Bool?
    var presenceLastSeen: Date?
    var isGroup: Bool
    var groupName: String?
    var groupImageUrl: String?
    var myLastReadMessageId: String?
}

extension LocalConversationSummary {
    init(_ backend: BackendConversationSummary) {
        conversationId = backend.conversationId
        otherParticipantId = backend.otherParticipantId
        otherParticipantType = backend.otherParticipantType
        displayName = backend.displayName
        profileImageUrl = backend.profileImageUrl
        isFollowing = backend.isFollowing
        isBlocked = backend.isBlocked
        lastMessagePreview = backend.lastMessagePreview
        lastMessageContentType = backend.lastMessageContentType
        lastMessageAt = backend.lastMessageAt
        lastMessageSenderId = backend.lastMessageSenderId
        lastMessageDelivered = backend.lastMessageDelivered
        lastMessageOpened = backend.lastMessageOpened
        unreadCount = backend.unreadCount
        status = backend.status
        otherStatus = backend.otherStatus
        archived = backend.archived
        mutedUntil = backend.mutedUntil
        presenceOnline = backend.presence.online
        presenceLastSeen = backend.presence.lastSeen
        isGroup = backend.isGroup
        groupName = backend.groupName
        groupImageUrl = backend.groupImageUrl
        myLastReadMessageId = nil
    }

    var asBackend: BackendConversationSummary {
        var summary = BackendConversationSummary(
            conversationId: conversationId,
            isGroup: isGroup,
            groupName: groupName,
            groupImageUrl: groupImageUrl,
            otherParticipantId: otherParticipantId,
            otherParticipantType: otherParticipantType,
            displayName: displayName,
            profileImageUrl: profileImageUrl,
            isFollowing: isFollowing,
            lastMessagePreview: lastMessagePreview,
            lastMessageContentType: lastMessageContentType,
            lastMessageAt: lastMessageAt,
            lastMessageDelivered: lastMessageDelivered,
            lastMessageOpened: lastMessageOpened,
            unreadCount: unreadCount,
            status: status,
            otherStatus: otherStatus,
            archived: archived,
            mutedUntil: mutedUntil,
            presence: PresenceInfo(online: presenceOnline, lastSeen: presenceLastSeen)
        )
        summary.lastMessageSenderId = lastMessageSenderId
        summary.isBlocked = isBlocked
        return summary
    }
}

struct LocalMessage: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "cached_messages"

    var id: String
    var conversationId: String
    var senderId: String
    var senderType: ParticipantType
    var contentType: MessageContentType
    var textContent: String?
    var mediaUrl: String?
    var mediaMetadata: MessageMediaMetadata?
    var replyToMessageId: String?
    var isDisappearing: Bool
    var expiresAt: Date?
    var createdAt: Date
    var deletedAt: Date?
    var deliveryStatus: MessageDeliveryStatus
    var reactions: [MessageReaction]
    var delivered: Bool
    var opened: Bool
    var openedAt: Date?
    var editedAt: Date?
}

enum MessageDeliveryStatus: String, Codable {
    case sending
    case sent
    case failed
}

extension LocalMessage {
    init(_ backend: BackendMessage, status: MessageDeliveryStatus = .sent) {
        id = backend.id
        conversationId = backend.conversationId
        senderId = backend.senderId
        senderType = backend.senderType
        contentType = backend.contentType
        textContent = backend.textContent
        mediaUrl = backend.mediaUrl
        mediaMetadata = backend.mediaMetadata
        replyToMessageId = backend.replyToMessageId
        isDisappearing = backend.isDisappearing
        expiresAt = backend.expiresAt
        createdAt = backend.createdAt
        deletedAt = backend.deletedAt
        deliveryStatus = status
        reactions = backend.reactions
        delivered = backend.delivered
        opened = backend.opened
        openedAt = backend.openedAt
        editedAt = backend.editedAt
    }

    var asBackend: BackendMessage {
        BackendMessage(
            id: id,
            conversationId: conversationId,
            senderId: senderId,
            senderType: senderType,
            contentType: contentType,
            textContent: textContent,
            mediaUrl: E2EEMedia.rebase(mediaUrl),
            mediaMetadata: E2EEMedia.rebase(mediaMetadata),
            replyToMessageId: replyToMessageId,
            isDisappearing: isDisappearing,
            expiresAt: expiresAt,
            createdAt: createdAt,
            deletedAt: deletedAt,
            reactions: reactions,
            delivered: delivered,
            opened: opened,
            openedAt: openedAt,
            editedAt: editedAt
        )
    }
}

struct ConversationSyncCursor: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sync_cursors"
    var conversationId: String
    var reachedBeginning: Bool
}

struct LocalGroupParticipant: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "cached_group_participants"
    var conversationId: String
    var userId: String
    var displayName: String
    var profileImageUrl: String?
    var hasLeft: Bool
}

struct LocalParticipantColor: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "cached_participant_colors"
    var userId: String
    var displayName: String
    var colorName: String
}

struct LocalGroupAvatar: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "cached_group_avatars"
    var conversationId: String
    var avatarSeed: String
}

struct LocalMessageReceipt: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "cached_message_receipts"
    var messageId: String
    var userId: String
    var deliveredAt: Date?
    var openedAt: Date?
}

extension LocalMessageReceipt {
    var asDetail: MessageReceiptDetail {
        MessageReceiptDetail(userId: userId, deliveredAt: deliveredAt, openedAt: openedAt)
    }
}

final class ChatLocalStore {
    static let shared = ChatLocalStore()

    private let dbQueue: DatabaseQueue

    private init() {
        let folderURL = try! FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dbURL = folderURL.appendingPathComponent("chat.sqlite")

        dbQueue = try! DatabaseQueue(path: dbURL.path)
        try! Self.migrator.migrate(dbQueue)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_chat_tables") { db in
            try db.create(table: "cached_conversations") { t in
                t.primaryKey("conversationId", .text)
                t.column("otherParticipantId", .text).notNull()
                t.column("otherParticipantType", .text).notNull()
                t.column("lastMessagePreview", .text).notNull()
                t.column("lastMessageContentType", .text)
                t.column("lastMessageAt", .datetime)
                t.column("lastMessageDelivered", .boolean).notNull()
                t.column("lastMessageOpened", .boolean).notNull()
                t.column("unreadCount", .integer).notNull()
                t.column("status", .text).notNull()
                t.column("archived", .boolean).notNull()
                t.column("mutedUntil", .datetime)
            }

            try db.create(table: "cached_messages") { t in
                t.primaryKey("id", .text)
                t.column("conversationId", .text).notNull().indexed()
                t.column("senderId", .text).notNull()
                t.column("senderType", .text).notNull()
                t.column("contentType", .text).notNull()
                t.column("textContent", .text)
                t.column("mediaUrl", .text)
                t.column("mediaMetadata", .text)
                t.column("replyToMessageId", .text)
                t.column("isDisappearing", .boolean).notNull()
                t.column("expiresAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
                t.column("deliveryStatus", .text).notNull()
            }
            try db.create(index: "idx_messages_conversation_created",
                           on: "cached_messages", columns: ["conversationId", "createdAt"])

            try db.create(table: "sync_cursors") { t in
                t.primaryKey("conversationId", .text)
                t.column("reachedBeginning", .boolean).notNull()
            }
        }

        migrator.registerMigration("v2_add_message_reactions") { db in
            try db.alter(table: "cached_messages") { t in
                t.add(column: "reactions", .text).notNull().defaults(to: "[]")
            }
        }

        migrator.registerMigration("v3_add_chat_name_and_presence") { db in
            try db.alter(table: "cached_conversations") { t in
                t.add(column: "displayName", .text).notNull().defaults(to: "")
                t.add(column: "isFollowing", .boolean).notNull().defaults(to: true)
                t.add(column: "presenceOnline", .boolean)
                t.add(column: "presenceLastSeen", .datetime)
            }
            try db.execute(sql: "UPDATE cached_conversations SET displayName = otherParticipantId WHERE displayName = ''")
        }

        migrator.registerMigration("v4_add_message_receipt_flags") { db in
            try db.alter(table: "cached_messages") { t in
                t.add(column: "delivered", .boolean).notNull().defaults(to: false)
                t.add(column: "opened", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v5_add_other_status") { db in
            try db.alter(table: "cached_conversations") { t in
                t.add(column: "otherStatus", .text).notNull().defaults(to: ParticipantStatus.accepted.rawValue)
            }
        }

        migrator.registerMigration("v6_add_profile_image_url") { db in
            try db.alter(table: "cached_conversations") { t in
                t.add(column: "profileImageUrl", .text)
            }
        }

        migrator.registerMigration("v7_add_group_participant_names") { db in
            try db.create(table: "cached_group_participants") { t in
                t.column("conversationId", .text).notNull()
                t.column("userId", .text).notNull()
                t.column("displayName", .text).notNull()
                t.column("profileImageUrl", .text)
                t.primaryKey(["conversationId", "userId"])
            }
            try db.create(index: "idx_group_participants_conversation",
                           on: "cached_group_participants", columns: ["conversationId"])
        }

        migrator.registerMigration("v8_add_group_participant_has_left") { db in
            try db.alter(table: "cached_group_participants") { t in
                t.add(column: "hasLeft", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v9_add_participant_colors") { db in
            try db.create(table: "cached_participant_colors") { t in
                t.primaryKey("userId", .text)
                t.column("displayName", .text).notNull()
                t.column("colorName", .text).notNull()
            }
        }

        migrator.registerMigration("v10_add_group_avatars") { db in
            try db.create(table: "cached_group_avatars") { t in
                t.primaryKey("conversationId", .text)
                t.column("avatarSeed", .text).notNull()
            }
        }

        migrator.registerMigration("v11_add_group_fields_to_conversations") { db in
            try db.alter(table: "cached_conversations") { t in
                t.add(column: "isGroup", .boolean).notNull().defaults(to: false)
                t.add(column: "groupName", .text)
                t.add(column: "groupImageUrl", .text)
            }
        }

        migrator.registerMigration("v12_add_message_opened_at") { db in
            try db.alter(table: "cached_messages") { t in
                t.add(column: "openedAt", .datetime)
            }
        }

        migrator.registerMigration("v13_add_message_receipts") { db in
            try db.create(table: "cached_message_receipts") { t in
                t.column("messageId", .text).notNull()
                t.column("userId", .text).notNull()
                t.column("deliveredAt", .datetime)
                t.column("openedAt", .datetime)
                t.primaryKey(["messageId", "userId"])
            }
            try db.create(index: "idx_message_receipts_messageId", on: "cached_message_receipts", columns: ["messageId"])
        }

        migrator.registerMigration("v14_add_my_last_read_message_id") { db in
            try db.alter(table: "cached_conversations") { t in
                t.add(column: "myLastReadMessageId", .text)
            }
        }

        migrator.registerMigration("v15_add_last_message_sender_id") { db in
            try db.alter(table: "cached_conversations") { t in
                t.add(column: "lastMessageSenderId", .text)
            }
        }

        migrator.registerMigration("v16_add_is_blocked") { db in
            try db.alter(table: "cached_conversations") { t in
                t.add(column: "isBlocked", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v17_add_message_edited_at") { db in
            try db.alter(table: "cached_messages") { t in
                t.add(column: "editedAt", .datetime)
            }
        }

        return migrator
    }

    func fetchAllKnownParticipantNames() async throws -> [(userId: String, displayName: String, profileImageUrl: String?)] {
        try await dbQueue.read { db -> [(String, String, String?)] in
            let colorRows = try LocalParticipantColor.fetchAll(db)
                .filter { $0.userId != ParticipantColorStore.selfKey }
                .map { ($0.userId, $0.displayName, nil as String?) }
            let groupRows = try LocalGroupParticipant.fetchAll(db)
                .map { ($0.userId, $0.displayName, $0.profileImageUrl) }
            let oneToOneRows = try LocalConversationSummary
                .filter(Column("isGroup") == false)
                .fetchAll(db)
                .map { ($0.otherParticipantId, $0.displayName, $0.profileImageUrl) }
            return colorRows + groupRows + oneToOneRows
        }
    }

    func upsertConversations(_ conversations: [BackendConversationSummary]) async throws {
        try await dbQueue.write { db in
            for c in conversations {
                var row = LocalConversationSummary(c)
                if let existing = try LocalConversationSummary.fetchOne(db, key: c.conversationId) {
                    row.myLastReadMessageId = existing.myLastReadMessageId
                    if row.lastMessageSenderId == nil,
                       let cachedAt = existing.lastMessageAt,
                       let incomingAt = row.lastMessageAt,
                       abs(cachedAt.timeIntervalSince(incomingAt)) < 1 {
                        row.lastMessageSenderId = existing.lastMessageSenderId
                    }
                }
                try row.save(db)
            }
        }
    }

    func getLastReadMessageId(conversationId: String) async -> String? {
        (try? await dbQueue.read { db in
            try LocalConversationSummary.fetchOne(db, key: conversationId)?.myLastReadMessageId
        }) ?? nil
    }

    func setLastReadMessageId(_ messageId: String, conversationId: String) async {
        try? await dbQueue.write { db in
            guard var row = try LocalConversationSummary.fetchOne(db, key: conversationId) else { return }
            row.myLastReadMessageId = messageId
            try row.save(db)
        }
    }

    func upsertConversation(_ conversation: BackendConversationSummary) async throws {
        try await upsertConversations([conversation])
    }

    func patchConversationSettings(
        conversationId: String,
        mutedUntil: Date?,
        touchMuted: Bool = true,
        archived: Bool? = nil
    ) async throws {
        try await dbQueue.write { db in
            guard var row = try LocalConversationSummary.fetchOne(db, key: conversationId) else { return }
            if touchMuted { row.mutedUntil = mutedUntil }
            if let archived { row.archived = archived }
            try row.save(db)
        }
    }

    func isMutedNow(conversationId: String) async -> Bool {
        let muted: Bool? = try? await dbQueue.read { db in
            guard let row = try LocalConversationSummary.fetchOne(db, key: conversationId) else { return false }
            if row.archived { return true }
            return row.mutedUntil.map { $0 > Date() } ?? false
        }
        return muted ?? false
    }

    func patchOtherParticipantDisplayName(conversationId: String, displayName: String) async throws {
        try await dbQueue.write { db in
            guard var row = try LocalConversationSummary.fetchOne(db, key: conversationId) else { return }
            row.displayName = displayName
            try row.save(db)
        }
    }

    func patchGroupImageUrl(conversationId: String, imageUrl: String?) async throws {
        try await dbQueue.write { db in
            guard var row = try LocalConversationSummary.fetchOne(db, key: conversationId) else { return }
            row.groupImageUrl = (imageUrl?.isEmpty == false) ? imageUrl : nil
            try row.save(db)
        }
    }

    func patchIsBlocked(conversationId: String, isBlocked: Bool) async throws {
        try await dbQueue.write { db in
            guard var row = try LocalConversationSummary.fetchOne(db, key: conversationId) else { return }
            row.isBlocked = isBlocked
            try row.save(db)
        }
    }

    func fetchIsBlocked(conversationId: String) async throws -> Bool? {
        try await dbQueue.read { db in
            try LocalConversationSummary.fetchOne(db, key: conversationId)?.isBlocked
        }
    }

    func fetchConversations(view: ConversationListView, kind: ConversationKindFilter = .all) async throws -> [BackendConversationSummary] {
        try await dbQueue.read { db in
            var request = LocalConversationSummary.all()
            switch kind {
            case .all: break
            case .direct: request = request.filter(Column("isGroup") == false)
            case .group: request = request.filter(Column("isGroup") == true)
            }
            switch view {
            case .messages:
                request = request
                    .filter(Column("status") == ParticipantStatus.accepted.rawValue)
                    .filter(Column("archived") == false)
            case .invitations:
                request = request.filter(Column("status") == ParticipantStatus.pending.rawValue)
            case .archives:
                request = request.filter(Column("archived") == true)
            }
            let rows = try request
                .order(Column("lastMessageAt").desc)
                .fetchAll(db)
            return rows.map { $0.asBackend }
        }
    }

    func upsertGroupParticipantNames(conversationId: String, participants: [GroupParticipant]) async throws {
        try await dbQueue.write { db in
            _ = try LocalGroupParticipant
                .filter(Column("conversationId") == conversationId)
                .deleteAll(db)
            for p in participants {
                try LocalGroupParticipant(
                    conversationId: conversationId,
                    userId: p.userId,
                    displayName: p.displayName,
                    profileImageUrl: p.profileImageUrl,
                    hasLeft: p.hasLeft
                ).save(db)
            }
        }
    }

    func patchGroupParticipantDisplayName(conversationId: String, userId: String, displayName: String) async throws {
        try await dbQueue.write { db in
            guard var row = try LocalGroupParticipant.fetchOne(db, key: ["conversationId": conversationId, "userId": userId]) else { return }
            row.displayName = displayName
            try row.save(db)
        }
    }

    func fetchGroupParticipantNames(conversationId: String) async throws -> (names: [String: String], avatars: [String: String]) {
        try await dbQueue.read { db in
            let rows = try LocalGroupParticipant
                .filter(Column("conversationId") == conversationId)
                .fetchAll(db)
            var names: [String: String] = [:]
            var avatars: [String: String] = [:]
            for row in rows {
                names[row.userId] = row.displayName
                avatars[row.userId] = row.profileImageUrl
            }
            return (names, avatars)
        }
    }

    func fetchSelfHasLeftGroup(conversationId: String, userId: String) async throws -> Bool? {
        try await dbQueue.read { db in
            try LocalGroupParticipant
                .filter(Column("conversationId") == conversationId)
                .filter(Column("userId") == userId)
                .fetchOne(db)?.hasLeft
        }
    }

    func markSelfLeftGroup(conversationId: String, userId: String) async throws {
        try await dbQueue.write { db in
            guard var row = try LocalGroupParticipant
                .filter(Column("conversationId") == conversationId)
                .filter(Column("userId") == userId)
                .fetchOne(db)
            else { return }
            row.hasLeft = true
            try row.save(db)
        }
    }

    func fetchAllParticipantColors() async throws -> [LocalParticipantColor] {
        try await dbQueue.read { db in
            try LocalParticipantColor.fetchAll(db)
        }
    }

    func upsertParticipantColor(userId: String, displayName: String, colorName: String) async throws {
        try await dbQueue.write { db in
            try LocalParticipantColor(userId: userId, displayName: displayName, colorName: colorName).save(db)
        }
    }

    func fetchAllGroupAvatars() async throws -> [LocalGroupAvatar] {
        try await dbQueue.read { db in
            try LocalGroupAvatar.fetchAll(db)
        }
    }

    func upsertGroupAvatar(conversationId: String, avatarSeed: String) async throws {
        try await dbQueue.write { db in
            try LocalGroupAvatar(conversationId: conversationId, avatarSeed: avatarSeed).save(db)
        }
    }

    func deleteGroupAvatar(conversationId: String) async throws {
        _ = try await dbQueue.write { db in
            try LocalGroupAvatar.filter(Column("conversationId") == conversationId).deleteAll(db)
        }
    }

    func upsertMessages(_ messages: [BackendMessage]) async throws {
        try await dbQueue.write { db in
            for m in messages {
                try LocalMessage(m).save(db)
            }
        }

        let myId = AuthService.shared.user?.backendId
        let unopenedBits = messages.filter {
            $0.senderId != myId
                && $0.contentType == .bit
                && $0.deletedAt == nil
                && $0.mediaUrl != nil
                && ($0.expiresAt.map { $0 > Date() } ?? true)
        }
        guard !unopenedBits.isEmpty else { return }

        for bit in unopenedBits {
            if let urlString = bit.mediaUrl, let url = URL(string: urlString) {
                await BitPrefetchCache.shared.prefetch(messageId: bit.id, remoteURL: url)
            }
        }

        let byConversation = Dictionary(grouping: unopenedBits, by: \.conversationId)
        for (conversationId, bits) in byConversation {
            NotificationCenter.default.post(
                name: .chatLocalStoreDidCacheUnopenedBits,
                object: nil,
                userInfo: ["conversationId": conversationId, "messages": bits]
            )
        }
    }

    func replaceOptimisticMessage(tempId: String, with backend: BackendMessage) async throws {
        try await dbQueue.write { db in
            _ = try LocalMessage.deleteOne(db, key: tempId)
            try LocalMessage(backend).save(db)
        }
    }

    func markMessageFailed(tempId: String) async throws {
        try await dbQueue.write { db in
            if var row = try LocalMessage.fetchOne(db, key: tempId) {
                row.deliveryStatus = .failed
                try row.save(db)
            }
        }
    }

    func markMessageSending(tempId: String) async throws {
        try await dbQueue.write { db in
            if var row = try LocalMessage.fetchOne(db, key: tempId) {
                row.deliveryStatus = .sending
                try row.save(db)
            }
        }
    }

    func updateReactions(messageId: String, reactions: [MessageReaction]) async throws {
        try await dbQueue.write { db in
            guard var row = try LocalMessage.fetchOne(db, key: messageId) else { return }
            row.reactions = reactions
            try row.save(db)
        }
    }

    func fetchMessages(conversationId: String, before: String?, limit: Int) async throws -> [BackendMessage] {
        try await dbQueue.read { db in
            var request = LocalMessage
                .filter(Column("conversationId") == conversationId)
                .filter(Column("deliveryStatus") != MessageDeliveryStatus.failed.rawValue)

            if let beforeId = before {
                guard let cursorRow = try LocalMessage.fetchOne(db, key: beforeId) else {
                    return []
                }
                request = request.filter(Column("createdAt") < cursorRow.createdAt)
            }

            let rows = try request
                .order(Column("createdAt").desc)
                .limit(limit)
                .fetchAll(db)
            return rows.reversed().map { $0.asBackend }
        }
    }

    func fetchMediaMessages(conversationId: String) async throws -> [BackendMessage] {
        try await dbQueue.read { db in
            try LocalMessage
                .filter(Column("conversationId") == conversationId)
                .filter([
                    MessageContentType.image.rawValue,
                    MessageContentType.video.rawValue,
                    MessageContentType.file.rawValue,
                    MessageContentType.voice.rawValue
                ].contains(Column("contentType")))
                .order(Column("createdAt").desc)
                .fetchAll(db)
                .map { $0.asBackend }
        }
    }

    func upsertMessageReceipt(messageId: String, userId: String, deliveredAt: Date?, openedAt: Date?) async throws {
        try await dbQueue.write { db in
            var row = try LocalMessageReceipt.fetchOne(
                db, key: ["messageId": messageId, "userId": userId]
            ) ?? LocalMessageReceipt(messageId: messageId, userId: userId, deliveredAt: nil, openedAt: nil)
            if let deliveredAt, row.deliveredAt == nil || deliveredAt < row.deliveredAt! {
                row.deliveredAt = deliveredAt
            }
            if let openedAt, row.openedAt == nil || openedAt < row.openedAt! {
                row.openedAt = openedAt
            }
            try row.save(db)
        }
    }

    func upsertMessageReceipts(messageId: String, _ receipts: [MessageReceiptDetail]) async throws {
        for r in receipts {
            try await upsertMessageReceipt(messageId: messageId, userId: r.userId, deliveredAt: r.deliveredAt, openedAt: r.openedAt)
        }
    }

    func messageReceipts(messageId: String) async throws -> [String: MessageReceiptDetail] {
        try await dbQueue.read { db in
            let rows = try LocalMessageReceipt.filter(Column("messageId") == messageId).fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.userId, $0.asDetail) })
        }
    }

    func oldestCachedMessage(conversationId: String) async throws -> BackendMessage? {
        try await dbQueue.read { db in
            try LocalMessage
                .filter(Column("conversationId") == conversationId)
                .order(Column("createdAt").asc)
                .fetchOne(db)?.asBackend
        }
    }

    func hasReachedBeginning(conversationId: String) async throws -> Bool {
        try await dbQueue.read { db in
            try ConversationSyncCursor.fetchOne(db, key: conversationId)?.reachedBeginning ?? false
        }
    }

    func markReachedBeginning(conversationId: String) async throws {
        try await dbQueue.write { db in
            try ConversationSyncCursor(conversationId: conversationId, reachedBeginning: true).save(db)
        }
    }

    func markBitOpened(messageId: String, openedAt: Date) async throws {
        try await dbQueue.write { db in
            guard var row = try LocalMessage.fetchOne(db, key: messageId) else { return }
            row.deletedAt = openedAt
            row.mediaUrl = nil
            try row.save(db)
        }
    }

    func purgeExpiredBits() async throws {
        try await dbQueue.write { db in
            try LocalMessage
                .filter(Column("contentType") == MessageContentType.bit.rawValue)
                .filter(Column("expiresAt") != nil)
                .filter(Column("expiresAt") < Date())
                .deleteAll(db)
        }
    }

    func clearConversation(conversationId: String) async throws {
        try await dbQueue.write { db in
            let messageIds = try LocalMessage
                .filter(Column("conversationId") == conversationId)
                .select(Column("id"), as: String.self)
                .fetchAll(db)
            _ = try LocalMessageReceipt
                .filter(messageIds.contains(Column("messageId")))
                .deleteAll(db)
            _ = try LocalMessage
                .filter(Column("conversationId") == conversationId)
                .deleteAll(db)
            _ = try ConversationSyncCursor.deleteOne(db, key: conversationId)
        }
    }

    func deleteConversation(conversationId: String) async throws {
        try await dbQueue.write { db in
            let messageIds = try LocalMessage
                .filter(Column("conversationId") == conversationId)
                .select(Column("id"), as: String.self)
                .fetchAll(db)
            _ = try LocalMessageReceipt
                .filter(messageIds.contains(Column("messageId")))
                .deleteAll(db)
            _ = try LocalMessage
                .filter(Column("conversationId") == conversationId)
                .deleteAll(db)
            _ = try ConversationSyncCursor.deleteOne(db, key: conversationId)
            _ = try LocalConversationSummary.deleteOne(db, key: conversationId)
            _ = try LocalGroupParticipant
                .filter(Column("conversationId") == conversationId)
                .deleteAll(db)
        }
    }

    func clearAll() async throws {
        try await dbQueue.write { db in
            _ = try LocalConversationSummary.deleteAll(db)
            _ = try LocalMessage.deleteAll(db)
            _ = try ConversationSyncCursor.deleteAll(db)
            _ = try LocalGroupParticipant.deleteAll(db)
            _ = try LocalMessageReceipt.deleteAll(db)
            _ = try LocalParticipantColor.deleteAll(db)
        }
    }
}

enum ConversationListView: String {
    case messages
    case invitations
    case archives
}
