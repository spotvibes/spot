import Foundation
import Firebase

enum ParticipantType: String, Codable, Equatable {
    case user
    case service
}

enum ParticipantStatus: String, Codable, Equatable {
    case accepted
    case pending
}

enum MessageContentType: String, Codable, Equatable, CaseIterable {
    case text
    case image
    case video
    case voice
    case location
    case file
    case bit
    case system
}

enum CallType: String, Codable {
    case voice
    case video
}

enum CallStatus: String, Codable {
    case ringing
    case ongoing
    case ended
    case missed
    case declined
    case busy
}

struct MessageReaction: Codable, Identifiable, Equatable {
    let id: String
    let messageId: String
    let userId: String
    let emoji: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case messageId = "message_id"
        case userId = "user_id"
        case emoji
        case createdAt = "created_at"
    }
}

struct MessageMediaMetadata: Codable, Equatable {
    var durationMs: Int64?
    var fileSizeBytes: Int64?
    var mimeType: String?
    var thumbnailUrl: String?
    var width: Int?
    var height: Int?
    var lat: Double?
    var lng: Double?
    var isLiveLocation: Bool?
    var viewDurationSeconds: Int? = nil
    var eventType: String? = nil
    var targetId: String? = nil
    var targetIds: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case durationMs = "duration_ms"
        case fileSizeBytes = "file_size_bytes"
        case mimeType = "mime_type"
        case thumbnailUrl = "thumbnail_url"
        case width, height, lat, lng
        case isLiveLocation = "is_live_location"
        case viewDurationSeconds = "view_duration_seconds"
        case eventType = "event_type"
        case targetId = "target_id"
        case targetIds = "target_ids"
    }
}

struct BackendMessage: Identifiable, Equatable {
    let id: String
    let conversationId: String
    let senderId: String
    let senderType: ParticipantType
    let contentType: MessageContentType
    let textContent: String?
    let mediaUrl: String?
    let mediaMetadata: MessageMediaMetadata?
    let replyToMessageId: String?
    let isDisappearing: Bool
    let expiresAt: Date?
    let createdAt: Date
    let deletedAt: Date?
    var reactions: [MessageReaction]
    var delivered: Bool
    var opened: Bool
    var openedAt: Date?
    var editedAt: Date? = nil
    var isEdited: Bool { editedAt != nil && deletedAt == nil }
    var e2eeEnvelope: E2EEEnvelope? = nil
    var e2eeCiphertexts: [E2EECiphertext]? = nil

    init(
        id: String, conversationId: String, senderId: String, senderType: ParticipantType,
        contentType: MessageContentType, textContent: String?, mediaUrl: String?,
        mediaMetadata: MessageMediaMetadata?, replyToMessageId: String?, isDisappearing: Bool,
        expiresAt: Date?, createdAt: Date, deletedAt: Date?, reactions: [MessageReaction] = [],
        delivered: Bool = false, opened: Bool = false, openedAt: Date? = nil,
        editedAt: Date? = nil,
        e2eeEnvelope: E2EEEnvelope? = nil, e2eeCiphertexts: [E2EECiphertext]? = nil
    ) {
        self.e2eeEnvelope = e2eeEnvelope
        self.e2eeCiphertexts = e2eeCiphertexts
        self.id = id
        self.conversationId = conversationId
        self.senderId = senderId
        self.senderType = senderType
        self.contentType = contentType
        self.textContent = textContent
        self.mediaUrl = mediaUrl
        self.mediaMetadata = mediaMetadata
        self.replyToMessageId = replyToMessageId
        self.isDisappearing = isDisappearing
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.deletedAt = deletedAt
        self.reactions = reactions
        self.delivered = delivered
        self.opened = opened
        self.openedAt = openedAt
        self.editedAt = editedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case conversationId = "conversation_id"
        case senderId = "sender_id"
        case senderType = "sender_type"
        case contentType = "content_type"
        case textContent = "text_content"
        case mediaUrl = "media_url"
        case mediaMetadata = "media_metadata"
        case replyToMessageId = "reply_to_message_id"
        case isDisappearing = "is_disappearing"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
        case deletedAt = "deleted_at"
        case reactions, delivered, opened
        case openedAt = "opened_at"
        case editedAt = "edited_at"
        case e2eeEnvelope = "e2ee_envelope"
        case e2eeCiphertexts = "e2ee_ciphertexts"
    }
}

extension BackendMessage: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        conversationId = try c.decode(String.self, forKey: .conversationId)
        senderId = try c.decode(String.self, forKey: .senderId)
        senderType = try c.decode(ParticipantType.self, forKey: .senderType)
        contentType = try c.decode(MessageContentType.self, forKey: .contentType)
        textContent = try c.decodeIfPresent(String.self, forKey: .textContent)
        mediaUrl = try c.decodeIfPresent(String.self, forKey: .mediaUrl)
        mediaMetadata = try c.decodeIfPresent(MessageMediaMetadata.self, forKey: .mediaMetadata)
        replyToMessageId = try c.decodeIfPresent(String.self, forKey: .replyToMessageId)
        isDisappearing = try c.decode(Bool.self, forKey: .isDisappearing)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        reactions = try c.decodeIfPresent([MessageReaction].self, forKey: .reactions) ?? []
        delivered = try c.decodeIfPresent(Bool.self, forKey: .delivered) ?? false
        opened = try c.decodeIfPresent(Bool.self, forKey: .opened) ?? false
        openedAt = try c.decodeIfPresent(Date.self, forKey: .openedAt)
        editedAt = try c.decodeIfPresent(Date.self, forKey: .editedAt)
        e2eeEnvelope = try? c.decodeIfPresent(E2EEEnvelope.self, forKey: .e2eeEnvelope)
        e2eeCiphertexts = try? c.decodeIfPresent([E2EECiphertext].self, forKey: .e2eeCiphertexts)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(conversationId, forKey: .conversationId)
        try c.encode(senderId, forKey: .senderId)
        try c.encode(senderType, forKey: .senderType)
        try c.encode(contentType, forKey: .contentType)
        try c.encodeIfPresent(textContent, forKey: .textContent)
        try c.encodeIfPresent(mediaUrl, forKey: .mediaUrl)
        try c.encodeIfPresent(mediaMetadata, forKey: .mediaMetadata)
        try c.encodeIfPresent(replyToMessageId, forKey: .replyToMessageId)
        try c.encode(isDisappearing, forKey: .isDisappearing)
        try c.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try c.encode(reactions, forKey: .reactions)
        try c.encode(delivered, forKey: .delivered)
        try c.encode(opened, forKey: .opened)
        try c.encodeIfPresent(openedAt, forKey: .openedAt)
        try c.encodeIfPresent(editedAt, forKey: .editedAt)
    }
}

struct BackendConversationSummary: Identifiable, Equatable {
    let conversationId: String
    var isGroup: Bool = false
    var e2eeEnabled: Bool = false
    var groupName: String? = nil
    var groupImageUrl: String? = nil
    let otherParticipantId: String
    let otherParticipantType: ParticipantType
    let displayName: String
    var username: String? = nil
    var isBlocked: Bool = false
    let profileImageUrl: String?
    let isFollowing: Bool
    var lastMessagePreview: String
    let lastMessageContentType: MessageContentType?
    let lastMessageAt: Date?
    var lastMessageSenderId: String? = nil
    let lastMessageDelivered: Bool
    let lastMessageOpened: Bool
    var unreadCount: Int
    let status: ParticipantStatus
    let otherStatus: ParticipantStatus
    var archived: Bool
    var mutedUntil: Date?
    var presence: PresenceInfo

    var id: String { conversationId }

    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case isGroup = "is_group"
        case e2eeEnabled = "e2ee_enabled"
        case groupName = "group_name"
        case groupImageUrl = "group_image_url"
        case otherParticipantId = "other_participant_id"
        case otherParticipantType = "other_participant_type"
        case displayName = "display_name"
        case username
        case isBlocked = "is_blocked"
        case profileImageUrl = "profile_image_url"
        case isFollowing = "is_following"
        case lastMessagePreview = "last_message_preview"
        case lastMessageContentType = "last_message_content_type"
        case lastMessageAt = "last_message_at"
        case lastMessageSenderId = "last_message_sender_id"
        case lastMessageDelivered = "last_message_delivered"
        case lastMessageOpened = "last_message_opened"
        case unreadCount = "unread_count"
        case status, archived
        case otherStatus = "other_status"
        case mutedUntil = "muted_until"
        case presence
    }
}

extension BackendConversationSummary: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversationId = try c.decode(String.self, forKey: .conversationId)
        isGroup = try c.decodeIfPresent(Bool.self, forKey: .isGroup) ?? false
        e2eeEnabled = try c.decodeIfPresent(Bool.self, forKey: .e2eeEnabled) ?? false
        groupName = try c.decodeIfPresent(String.self, forKey: .groupName)
        groupImageUrl = try c.decodeIfPresent(String.self, forKey: .groupImageUrl)
        otherParticipantId = try c.decode(String.self, forKey: .otherParticipantId)
        otherParticipantType = try c.decode(ParticipantType.self, forKey: .otherParticipantType)
        displayName = try c.decode(String.self, forKey: .displayName)
        username = try c.decodeIfPresent(String.self, forKey: .username)
        isBlocked = try c.decodeIfPresent(Bool.self, forKey: .isBlocked) ?? false
        profileImageUrl = try c.decodeIfPresent(String.self, forKey: .profileImageUrl)
        isFollowing = try c.decode(Bool.self, forKey: .isFollowing)
        lastMessagePreview = try c.decode(String.self, forKey: .lastMessagePreview)
        lastMessageContentType = try c.decodeIfPresent(MessageContentType.self, forKey: .lastMessageContentType)
        lastMessageAt = try c.decodeIfPresent(Date.self, forKey: .lastMessageAt)
        lastMessageSenderId = try c.decodeIfPresent(String.self, forKey: .lastMessageSenderId)
        lastMessageDelivered = try c.decode(Bool.self, forKey: .lastMessageDelivered)
        lastMessageOpened = try c.decode(Bool.self, forKey: .lastMessageOpened)
        unreadCount = try c.decode(Int.self, forKey: .unreadCount)
        status = try c.decode(ParticipantStatus.self, forKey: .status)
        otherStatus = try c.decode(ParticipantStatus.self, forKey: .otherStatus)
        archived = try c.decode(Bool.self, forKey: .archived)
        mutedUntil = try c.decodeIfPresent(Date.self, forKey: .mutedUntil)
        presence = try c.decode(PresenceInfo.self, forKey: .presence)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(conversationId, forKey: .conversationId)
        try c.encode(isGroup, forKey: .isGroup)
        try c.encode(e2eeEnabled, forKey: .e2eeEnabled)
        try c.encodeIfPresent(groupName, forKey: .groupName)
        try c.encodeIfPresent(groupImageUrl, forKey: .groupImageUrl)
        try c.encode(otherParticipantId, forKey: .otherParticipantId)
        try c.encode(otherParticipantType, forKey: .otherParticipantType)
        try c.encode(displayName, forKey: .displayName)
        try c.encodeIfPresent(username, forKey: .username)
        try c.encode(isBlocked, forKey: .isBlocked)
        try c.encodeIfPresent(profileImageUrl, forKey: .profileImageUrl)
        try c.encode(isFollowing, forKey: .isFollowing)
        try c.encode(lastMessagePreview, forKey: .lastMessagePreview)
        try c.encodeIfPresent(lastMessageContentType, forKey: .lastMessageContentType)
        try c.encodeIfPresent(lastMessageAt, forKey: .lastMessageAt)
        try c.encodeIfPresent(lastMessageSenderId, forKey: .lastMessageSenderId)
        try c.encode(lastMessageDelivered, forKey: .lastMessageDelivered)
        try c.encode(lastMessageOpened, forKey: .lastMessageOpened)
        try c.encode(unreadCount, forKey: .unreadCount)
        try c.encode(status, forKey: .status)
        try c.encode(otherStatus, forKey: .otherStatus)
        try c.encode(archived, forKey: .archived)
        try c.encodeIfPresent(mutedUntil, forKey: .mutedUntil)
        try c.encode(presence, forKey: .presence)
    }
}
struct Message: Codable, Identifiable {
    let id: String
    let fromId: String
    let toId: String
    let timestamp: Timestamp
    let text: String
    let isRead: Bool
    let readAt: Timestamp?
}
struct BackendConversation: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let isGroup: Bool
    let lastMessageId: String?
    let lastMessageAt: Date?
    let createdAt: Date
    let groupName: String?
    let groupImageUrl: String?
    let otherStatus: ParticipantStatus?
    var myStatus: ParticipantStatus? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case isGroup = "is_group"
        case lastMessageId = "last_message_id"
        case lastMessageAt = "last_message_at"
        case createdAt = "created_at"
        case groupName = "group_name"
        case groupImageUrl = "group_image_url"
        case otherStatus = "other_status"
        case myStatus = "my_status"
    }
}

struct BackendCall: Codable, Identifiable, Equatable {
    let id: String
    let conversationId: String
    let callerId: String
    let calleeId: String
    let callType: CallType
    let status: CallStatus
    let startedAt: Date?
    let endedAt: Date?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case conversationId = "conversation_id"
        case callerId = "caller_id"
        case calleeId = "callee_id"
        case callType = "call_type"
        case status
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case createdAt = "created_at"
    }
}

struct SendMessageRequestBody: Encodable {
    var contentType: MessageContentType
    var textContent: String?
    var mediaUrl: String?
    var mediaMetadata: MessageMediaMetadata?
    var replyToMessageId: String?
    var isDisappearing: Bool?
    var e2ee: E2EESendPayload? = nil
    var e2eeAttachment: E2EEAttachment? = nil

    enum CodingKeys: String, CodingKey {
        case e2ee
        case contentType = "content_type"
        case textContent = "text_content"
        case mediaUrl = "media_url"
        case mediaMetadata = "media_metadata"
        case replyToMessageId = "reply_to_message_id"
        case isDisappearing = "is_disappearing"
    }
}

struct StartDirectConversationRequestBody: Encodable {
    var otherId: String
    var otherType: ParticipantType

    enum CodingKeys: String, CodingKey {
        case otherId = "other_id"
        case otherType = "other_type"
    }
}

struct MarkReadRequestBody: Encodable {
    var upToMessageId: String
    var opensBit: Bool = false
    enum CodingKeys: String, CodingKey {
        case upToMessageId = "up_to_message_id"
        case opensBit = "opens_bit"
    }
}

struct AddReactionRequestBody: Encodable {
    var emoji: String
}

struct EditMessageRequestBody: Encodable {
    var text: String
    var e2ee: E2EESendPayload? = nil
}

struct UpdateConversationSettingsRequestBody: Encodable {
    var mutedUntil: Date??
    var archived: Bool?
    var notificationsEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case mutedUntil = "muted_until"
        case archived
        case notificationsEnabled = "notifications_enabled"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let outer = mutedUntil {
            try container.encode(outer, forKey: .mutedUntil)
        }
        try container.encodeIfPresent(archived, forKey: .archived)
        try container.encodeIfPresent(notificationsEnabled, forKey: .notificationsEnabled)
    }
}

struct CreateCallRequestBody: Encodable {
    var callType: CallType
    enum CodingKeys: String, CodingKey { case callType = "call_type" }
}

struct UpdateCallStatusRequestBody: Encodable {
    var status: CallStatus
}

extension BackendMessage {
    func withBitOpened(at openedAt: Date) -> BackendMessage {
        BackendMessage(
            id: id, conversationId: conversationId, senderId: senderId, senderType: senderType,
            contentType: contentType, textContent: textContent, mediaUrl: nil,
            mediaMetadata: mediaMetadata, replyToMessageId: replyToMessageId, isDisappearing: isDisappearing,
            expiresAt: expiresAt, createdAt: createdAt, deletedAt: openedAt, reactions: reactions,
            delivered: delivered, opened: opened, openedAt: self.openedAt,
            editedAt: editedAt
        )
    }

    func withExpiresAt(_ date: Date?) -> BackendMessage {
        BackendMessage(
            id: id, conversationId: conversationId, senderId: senderId, senderType: senderType,
            contentType: contentType, textContent: textContent, mediaUrl: mediaUrl,
            mediaMetadata: mediaMetadata, replyToMessageId: replyToMessageId, isDisappearing: isDisappearing,
            expiresAt: date, createdAt: createdAt, deletedAt: deletedAt, reactions: reactions,
            delivered: delivered, opened: opened, openedAt: openedAt,
            editedAt: editedAt
        )
    }

    func withOpened(at date: Date) -> BackendMessage {
        BackendMessage(
            id: id, conversationId: conversationId, senderId: senderId, senderType: senderType,
            contentType: contentType, textContent: textContent, mediaUrl: mediaUrl,
            mediaMetadata: mediaMetadata, replyToMessageId: replyToMessageId, isDisappearing: isDisappearing,
            expiresAt: expiresAt, createdAt: createdAt, deletedAt: deletedAt, reactions: reactions,
            delivered: true, opened: true, openedAt: date,
            editedAt: editedAt
        )
    }

    func withDeleted(at date: Date) -> BackendMessage {
        BackendMessage(
            id: id, conversationId: conversationId, senderId: senderId, senderType: senderType,
            contentType: contentType, textContent: nil, mediaUrl: nil,
            mediaMetadata: nil, replyToMessageId: replyToMessageId, isDisappearing: isDisappearing,
            expiresAt: expiresAt, createdAt: createdAt, deletedAt: date, reactions: reactions,
            delivered: delivered, opened: opened, openedAt: openedAt,
            editedAt: nil
        )
    }

    static let deleteWindow: TimeInterval = 10 * 60

    func canUnsend(currentUserId: String?, now: Date = Date()) -> Bool {
        guard let currentUserId, senderId == currentUserId, deletedAt == nil, contentType != .system else {
            return false
        }
        return now.timeIntervalSince(createdAt) <= BackendMessage.deleteWindow
    }

    static let editWindow: TimeInterval = 15 * 60

    func canEdit(currentUserId: String?, now: Date = Date()) -> Bool {
        guard let currentUserId, senderId == currentUserId, deletedAt == nil,
              contentType == .text, !isDisappearing, !id.hasPrefix("pending-")
        else { return false }
        return now.timeIntervalSince(createdAt) <= BackendMessage.editWindow
    }

    func withEdited(text: String, at date: Date) -> BackendMessage {
        BackendMessage(
            id: id, conversationId: conversationId, senderId: senderId, senderType: senderType,
            contentType: contentType, textContent: text, mediaUrl: mediaUrl,
            mediaMetadata: mediaMetadata, replyToMessageId: replyToMessageId, isDisappearing: isDisappearing,
            expiresAt: expiresAt, createdAt: createdAt, deletedAt: deletedAt, reactions: reactions,
            delivered: delivered, opened: opened, openedAt: openedAt,
            editedAt: date
        )
    }
}

struct ChatApiResponse<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let error: String?
    let code: String?
}
