import Foundation

struct E2EESignedPreKeyDTO: Codable, Equatable {
    var id: Int
    var publicKey: String
    var signature: String

    enum CodingKeys: String, CodingKey { case id, publicKey = "public_key", signature }
}

struct E2EEPreKeyDTO: Codable, Equatable {
    var id: Int
    var publicKey: String

    enum CodingKeys: String, CodingKey { case id, publicKey = "public_key" }
}

struct E2EERegisterDeviceBody: Encodable {
    var deviceId: String
    var name: String
    var registrationId: Int
    var identityKey: String
    var signedPrekey: E2EESignedPreKeyDTO
    var kyberLastResort: E2EESignedPreKeyDTO
    var oneTimePrekeys: [E2EEPreKeyDTO]
    var oneTimeKyberPrekeys: [E2EESignedPreKeyDTO]

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id", name
        case registrationId = "registration_id"
        case identityKey = "identity_key"
        case signedPrekey = "signed_prekey"
        case kyberLastResort = "kyber_last_resort"
        case oneTimePrekeys = "one_time_prekeys"
        case oneTimeKyberPrekeys = "one_time_kyber_prekeys"
    }
}

struct E2EEUploadPreKeysBody: Encodable {
    var oneTimePrekeys: [E2EEPreKeyDTO]
    var oneTimeKyberPrekeys: [E2EESignedPreKeyDTO]

    enum CodingKeys: String, CodingKey {
        case oneTimePrekeys = "one_time_prekeys"
        case oneTimeKyberPrekeys = "one_time_kyber_prekeys"
    }
}

struct E2EERotateSignedPreKeyBody: Encodable {
    var signedPrekey: E2EESignedPreKeyDTO
    enum CodingKeys: String, CodingKey { case signedPrekey = "signed_prekey" }
}

struct E2EEPreKeyCounts: Decodable {
    var oneTimePrekeys: Int
    var oneTimeKyberPrekeys: Int

    enum CodingKeys: String, CodingKey {
        case oneTimePrekeys = "one_time_prekeys"
        case oneTimeKyberPrekeys = "one_time_kyber_prekeys"
    }
}

struct E2EEDeviceSummary: Decodable, Identifiable, Equatable {
    var deviceId: String
    var name: String
    var createdAt: Date
    var lastSeenAt: Date?

    var id: String { deviceId }

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id", name
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
    }
}

struct E2EEConversationDevice: Decodable, Equatable {
    var userId: String
    var deviceId: String
    var registrationId: Int
    var identityKey: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id", deviceId = "device_id"
        case registrationId = "registration_id"
        case identityKey = "identity_key"
    }
}

struct E2EEConversationDevices: Decodable {
    var devices: [E2EEConversationDevice]
    var usersWithoutDevices: [String]

    enum CodingKeys: String, CodingKey {
        case devices
        case usersWithoutDevices = "users_without_devices"
    }
}

struct E2EEConversationState: Decodable {
    var enabled: Bool
    var enabledAt: Date?
    var enabledBy: String?

    enum CodingKeys: String, CodingKey {
        case enabled
        case enabledAt = "enabled_at"
        case enabledBy = "enabled_by"
    }
}

struct E2EEPreKeyBundlesBody: Encodable {
    var conversationId: String
    var deviceIds: [String]

    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case deviceIds = "device_ids"
    }
}

struct E2EEPreKeyBundle: Decodable {
    struct Signed: Decodable {
        var id: Int
        var publicKey: String
        var signature: String
        enum CodingKeys: String, CodingKey { case id, publicKey = "public_key", signature }
    }
    struct Plain: Decodable {
        var id: Int
        var publicKey: String
        enum CodingKeys: String, CodingKey { case id, publicKey = "public_key" }
    }

    var userId: String
    var deviceId: String
    var registrationId: Int
    var identityKey: String
    var signedPrekey: Signed
    var prekey: Plain?
    var kyberPrekey: Signed

    enum CodingKeys: String, CodingKey {
        case userId = "user_id", deviceId = "device_id"
        case registrationId = "registration_id"
        case identityKey = "identity_key"
        case signedPrekey = "signed_prekey"
        case prekey
        case kyberPrekey = "kyber_prekey"
    }
}

struct E2EEEnvelope: Codable, Equatable {
    var v: Int
    var senderDeviceId: String
    var clientMsgId: String
    var rev: Int

    enum CodingKeys: String, CodingKey {
        case v
        case senderDeviceId = "sender_device_id"
        case clientMsgId = "client_msg_id"
        case rev
    }
}

struct E2EECiphertext: Codable, Equatable {
    var deviceId: String
    var msgType: Int
    var body: String

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case msgType = "msg_type"
        case body
    }
}

struct E2EESendPayload: Codable, Equatable {
    var senderDeviceId: String
    var clientMsgId: String
    var rev: Int
    var ciphertexts: [E2EECiphertext]

    enum CodingKeys: String, CodingKey {
        case senderDeviceId = "sender_device_id"
        case clientMsgId = "client_msg_id"
        case rev, ciphertexts
    }
}

struct E2EEPlainPayload: Codable {
    var v: Int = 1
    var t: String = "text"
    var body: String = ""

    var att: E2EEAttachment?

    var displayText: String {
        if !body.isEmpty { return body }
        guard let a = att else { return "" }
        switch a.kind {
        case "image": return "📷 Photo"
        case "video": return "🎥 Video"
        case "voice": return "🎤 Voice message"
        case "bit": return "👻 Bit"
        case "location": return a.live == true ? "📍 Live location" : "📍 Location"
        case "file": return "📎 " + (a.name ?? "File")
        default: return "🔒 Encrypted message"
        }
    }
}

struct E2EEBlobRef: Codable, Equatable {
    var url: String
    var key: String
    var digest: String
    var size: Int64
    var mime: String?
}

struct E2EEAttachment: Codable, Equatable {
    var kind: String
    var blob: E2EEBlobRef?
    var thumb: E2EEBlobRef?
    var name: String?
    var w: Int?
    var h: Int?
    var durationMs: Int64?
    var viewDurationSeconds: Int?
    var lat: Double?
    var lng: Double?
    var live: Bool?
}

enum E2EEPlaceholder {

    static let notForThisDevice = "🔒 Encrypted message — not available on this device"

    static let undecryptable = "🔒 This message couldn't be decrypted"
    static let previewFallback = "🔒 Encrypted message"
}
