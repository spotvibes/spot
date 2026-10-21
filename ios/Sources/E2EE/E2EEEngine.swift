import Foundation
import GRDB
import LibSignalClient

final class E2EEEngine {
    let userId: String
    let deviceId: String
    let registrationId: UInt32

    private let store: E2EEStore
    private let proto: E2EEProtocolStore
    private let lock: E2EEMutex

    static let paddingBlock = 160
    static let signedPreKeyRotation: TimeInterval = 14 * 24 * 3600
    static let signedPreKeyRetention: TimeInterval = 60 * 24 * 3600

    static func open(userId: String, createIfMissing: Bool = true) throws -> E2EEEngine {
        try E2EEEngine(store: E2EEStore.open(userId: userId, createIfMissing: createIfMissing))
    }

    private init(store: E2EEStore) {
        self.store = store
        self.lock = E2EEMutex(lockFile: store.lockURL)
        self.proto = E2EEProtocolStore(store)
        self.userId = store.userId
        self.deviceId = store.identity.deviceId
        self.registrationId = store.identity.registrationId
    }

    private func address(_ device: String) throws -> ProtocolAddress {
        try ProtocolAddress(name: device.lowercased(), deviceId: 1)
    }

    private func b64(_ bytes: [UInt8]) -> String { Data(bytes).base64EncodedString() }

    private func makeSignedPreKey(id: UInt32) throws -> (E2EESignedPreKeyDTO, SignedPreKeyRecord) {
        let priv = PrivateKey.generate()
        let pub = priv.publicKey
        let sig = store.identityKeyPair.privateKey.generateSignature(message: pub.serialize())
        let rec = try SignedPreKeyRecord(id: id, timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                                         privateKey: priv, signature: sig)
        return (E2EESignedPreKeyDTO(id: Int(id), publicKey: b64(pub.serialize()), signature: b64(sig)), rec)
    }

    private func makeKyberPreKey(id: UInt32) throws -> (E2EESignedPreKeyDTO, KyberPreKeyRecord) {
        let pair = KEMKeyPair.generate()
        let pubBytes = pair.publicKey.serialize()
        let sig = store.identityKeyPair.privateKey.generateSignature(message: pubBytes)
        let rec = try KyberPreKeyRecord(id: id, timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                                        keyPair: pair, signature: sig)
        return (E2EESignedPreKeyDTO(id: Int(id), publicKey: b64(pubBytes), signature: b64(sig)), rec)
    }

    func generateOneTimePreKeys(count: Int) throws -> [E2EEPreKeyDTO] {
        lock.lock(); defer { lock.unlock() }
        let ids = try store.reserveIds("next_prekey_id", count: count)
        var out: [E2EEPreKeyDTO] = []
        for id in ids {
            let priv = PrivateKey.generate()
            let rec = PreKeyRecord(id: id, privateKey: priv)
            try proto.storePreKey(rec, id: id, context: NullContext())
            out.append(E2EEPreKeyDTO(id: Int(id), publicKey: b64(priv.publicKey.serialize())))
        }
        return out
    }

    func generateOneTimeKyberPreKeys(count: Int) throws -> [E2EESignedPreKeyDTO] {
        lock.lock(); defer { lock.unlock() }
        let ids = try store.reserveIds("next_kyber_id", count: count)
        var out: [E2EESignedPreKeyDTO] = []
        for id in ids {
            let (dto, rec) = try makeKyberPreKey(id: id)
            try proto.storeKyber(rec, id: id, lastResort: false)
            out.append(dto)
        }
        return out
    }

    func rotateSignedPreKey() throws -> E2EESignedPreKeyDTO {
        lock.lock(); defer { lock.unlock() }
        let id = try store.reserveIds("next_signed_id", count: 1)[0]
        let (dto, rec) = try makeSignedPreKey(id: id)
        try proto.storeSignedPreKey(rec, id: id, context: NullContext())
        store.setMeta("signed_prekey_at", String(Date().timeIntervalSince1970))
        pruneOldSignedPreKeys(keeping: id)
        return dto
    }

    var signedPreKeyIsStale: Bool {
        guard let s = store.meta("signed_prekey_at"), let t = TimeInterval(s) else { return true }
        return Date().timeIntervalSince1970 - t > Self.signedPreKeyRotation
    }

    private func pruneOldSignedPreKeys(keeping id: UInt32) {
        let cutoff = Date().timeIntervalSince1970 - Self.signedPreKeyRetention
        try? store.dbQueue.write {
            try $0.execute(sql: "DELETE FROM e2ee_signed_prekeys WHERE id != ? AND createdAt < ?", arguments: [Int(id), cutoff])
        }
    }

    func makeRegistrationBody(name: String) throws -> E2EERegisterDeviceBody {
        lock.lock(); defer { lock.unlock() }
        let spkId = try store.reserveIds("next_signed_id", count: 1)[0]
        let (spkDTO, spkRec) = try makeSignedPreKey(id: spkId)
        try proto.storeSignedPreKey(spkRec, id: spkId, context: NullContext())
        store.setMeta("signed_prekey_at", String(Date().timeIntervalSince1970))

        let lrId = try store.reserveIds("next_kyber_id", count: 1)[0]
        let (lrDTO, lrRec) = try makeKyberPreKey(id: lrId)
        try proto.storeKyber(lrRec, id: lrId, lastResort: true)

        let otp = try generateOneTimePreKeys(count: 100)
        let kyber = try generateOneTimeKyberPreKeys(count: 100)
        return E2EERegisterDeviceBody(
            deviceId: deviceId, name: name, registrationId: Int(registrationId),
            identityKey: b64(store.identityKeyPair.publicKey.serialize()),
            signedPrekey: spkDTO, kyberLastResort: lrDTO,
            oneTimePrekeys: otp, oneTimeKyberPrekeys: kyber
        )
    }

    func hasSession(with device: String) -> Bool { proto.hasSession(for: device) }
    func dropSession(with device: String) { lock.lock(); defer { lock.unlock() }; try? proto.deleteSession(for: device) }

    func process(bundle b: E2EEPreKeyBundle) throws {
        lock.lock(); defer { lock.unlock() }
        func raw(_ s: String) throws -> [UInt8] {
            guard let d = Data(base64Encoded: s) else { throw E2EEError.invalidPayload }
            return [UInt8](d)
        }
        let identity = IdentityKey(publicKey: try PublicKey(try raw(b.identityKey)))
        let spk = try PublicKey(try raw(b.signedPrekey.publicKey))
        let kyber = try KEMPublicKey(try raw(b.kyberPrekey.publicKey))
        let bundle: PreKeyBundle
        if let p = b.prekey {
            bundle = try PreKeyBundle(
                registrationId: UInt32(b.registrationId), deviceId: 1,
                prekeyId: UInt32(p.id), prekey: try PublicKey(try raw(p.publicKey)),
                signedPrekeyId: UInt32(b.signedPrekey.id), signedPrekey: spk,
                signedPrekeySignature: try raw(b.signedPrekey.signature),
                identity: identity,
                kyberPrekeyId: UInt32(b.kyberPrekey.id), kyberPrekey: kyber,
                kyberPrekeySignature: try raw(b.kyberPrekey.signature))
        } else {
            bundle = try PreKeyBundle(
                registrationId: UInt32(b.registrationId), deviceId: 1,
                signedPrekeyId: UInt32(b.signedPrekey.id), signedPrekey: spk,
                signedPrekeySignature: try raw(b.signedPrekey.signature),
                identity: identity,
                kyberPrekeyId: UInt32(b.kyberPrekey.id), kyberPrekey: kyber,
                kyberPrekeySignature: try raw(b.kyberPrekey.signature))
        }
        try processPreKeyBundle(bundle, for: try address(b.deviceId),
                                sessionStore: proto, identityStore: proto, context: NullContext())
    }

    func encrypt(_ plaintext: Data, to device: String) throws -> E2EECiphertext {
        lock.lock(); defer { lock.unlock() }
        guard proto.hasSession(for: device) else { throw E2EEError.noSession(device) }
        let msg = try signalEncrypt(message: [UInt8](plaintext), for: try address(device),
                                    sessionStore: proto, identityStore: proto, context: NullContext())
        let type = msg.messageType == .preKey ? 3 : 2
        return E2EECiphertext(deviceId: device, msgType: type, body: Data(msg.serialize()).base64EncodedString())
    }

    private func decryptRaw(type: Int, body: Data, from device: String) throws -> Data {
        let addr = try address(device)
        let out: [UInt8]
        if type == 3 {
            let m = try PreKeySignalMessage(bytes: [UInt8](body))
            out = try signalDecryptPreKey(message: m, from: addr, sessionStore: proto, identityStore: proto,
                                          preKeyStore: proto, signedPreKeyStore: proto,
                                          kyberPreKeyStore: proto, context: NullContext())
        } else {
            let m = try SignalMessage(bytes: [UInt8](body))
            out = try signalDecrypt(message: m, from: addr, sessionStore: proto, identityStore: proto,
                                    context: NullContext())
        }
        return Data(out)
    }

    func frame(_ text: String, att: E2EEAttachment? = nil) throws -> Data {
        var data = try JSONEncoder().encode(E2EEPlainPayload(t: att?.kind ?? "text", body: text, att: att))
        let rem = data.count % Self.paddingBlock
        if rem != 0 { data.append(Data(repeating: 0x20, count: Self.paddingBlock - rem)) }
        return data
    }

    private func unframe(_ data: Data) throws -> E2EEPlainPayload {
        guard let p = try? JSONDecoder().decode(E2EEPlainPayload.self, from: data) else { throw E2EEError.invalidPayload }
        return p
    }

    func frameRaw(_ json: Data) -> Data {
        var data = json
        let rem = data.count % Self.paddingBlock
        if rem != 0 { data.append(Data(repeating: 0x20, count: Self.paddingBlock - rem)) }
        return data
    }

    func decryptEphemeral(type: Int, body: Data, from device: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return try? decryptRaw(type: type, body: body, from: device)
    }

    func cachedPayload(clientMsgId: String, rev: Int) -> E2EEPlainPayload? {
        let row: Row? = try? store.dbQueue.read {
            try Row.fetchOne($0, sql: "SELECT text, att FROM e2ee_plaintext WHERE clientMsgId = ? AND rev = ?",
                             arguments: [clientMsgId, rev])
        }
        guard let row, let text: String = row["text"] else { return nil }
        var p = E2EEPlainPayload(body: text)
        if let json: String = row["att"], let d = json.data(using: .utf8),
           let a = try? JSONDecoder().decode(E2EEAttachment.self, from: d) {
            p.att = a; p.t = a.kind
            if text == p.displayText { p.body = "" }
        }
        return p
    }

    func cachedText(clientMsgId: String, rev: Int) -> String? {
        cachedPayload(clientMsgId: clientMsgId, rev: rev)?.displayText
    }

    func cacheText(clientMsgId: String, rev: Int, messageId: String?, conversationId: String,
                   senderDeviceId: String, createdAt: Date, text: String, att: E2EEAttachment? = nil) {
        let attJSON = att.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        try? store.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO e2ee_plaintext (clientMsgId, rev, messageId, conversationId, senderDeviceId, createdAt, text, att)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(clientMsgId, rev) DO UPDATE SET messageId = COALESCE(excluded.messageId, messageId),
                    createdAt = CASE WHEN excluded.messageId IS NOT NULL THEN excluded.createdAt ELSE createdAt END
                """, arguments: [clientMsgId, rev, messageId, conversationId, senderDeviceId, createdAt.timeIntervalSince1970, text, attJSON])
        }
    }

    func decryptPayloadOnce(envelope e: E2EEEnvelope, ciphertext c: E2EECiphertext?, messageId: String,
                            conversationId: String, createdAt: Date) -> E2EEPlainPayload? {
        lock.lock(); defer { lock.unlock() }
        if let p = cachedPayload(clientMsgId: e.clientMsgId, rev: e.rev) {
            cacheText(clientMsgId: e.clientMsgId, rev: e.rev, messageId: messageId, conversationId: conversationId,
                      senderDeviceId: e.senderDeviceId, createdAt: createdAt, text: p.displayText, att: p.att)
            return p
        }
        guard let c, let body = Data(base64Encoded: c.body) else { return nil }
        do {
            let p = try unframe(try decryptRaw(type: c.msgType, body: body, from: e.senderDeviceId))
            cacheText(clientMsgId: e.clientMsgId, rev: e.rev, messageId: messageId, conversationId: conversationId,
                      senderDeviceId: e.senderDeviceId, createdAt: createdAt, text: p.displayText, att: p.att)
            return p
        } catch {
            #if DEBUG
            print("DEBUG: E2EE decrypt failed for \(messageId): \(error)")
            #endif
            return nil
        }
    }

    func decryptOnce(envelope e: E2EEEnvelope, ciphertext c: E2EECiphertext?, messageId: String,
                     conversationId: String, createdAt: Date) -> String? {
        decryptPayloadOnce(envelope: e, ciphertext: c, messageId: messageId, conversationId: conversationId,
                           createdAt: createdAt)?.displayText
    }

    func attachment(messageId: String) -> E2EEAttachment? {
        let json: String? = try? store.dbQueue.read {
            try String.fetchOne($0, sql: "SELECT att FROM e2ee_plaintext WHERE messageId = ? AND att IS NOT NULL ORDER BY rev DESC LIMIT 1",
                                arguments: [messageId])
        }
        return json.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(E2EEAttachment.self, from: $0) }
    }

    var ownIdentityKey: Data { Data(store.identityKeyPair.publicKey.serialize()) }

    func pinnedIdentityKey(of device: String) -> Data? {
        guard let a = try? address(device), let k = try? proto.identity(for: a, context: NullContext()) else { return nil }
        return Data(k.serialize())
    }

    func verifiedNumber(userId: String) -> String? {
        try? store.dbQueue.read { try String.fetchOne($0, sql: "SELECT number FROM e2ee_verified WHERE userId = ?", arguments: [userId.lowercased()]) }
    }
    func setVerified(userId: String, number: String?) {
        try? store.dbQueue.write { db in
            if let number {
                try db.execute(sql: "INSERT OR REPLACE INTO e2ee_verified (userId, number, verifiedAt) VALUES (?, ?, ?)",
                               arguments: [userId.lowercased(), number, Date().timeIntervalSince1970])
            } else {
                try db.execute(sql: "DELETE FROM e2ee_verified WHERE userId = ?", arguments: [userId.lowercased()])
            }
        }
    }

    func forgetBit(messageId: String) {
        try? store.dbQueue.write {
            try $0.execute(sql: "UPDATE e2ee_plaintext SET att = NULL WHERE messageId = ? AND att LIKE '%\"kind\":\"bit\"%'",
                           arguments: [messageId])
        }
    }

    func editContext(messageId: String) -> (conversationId: String, clientMsgId: String, rev: Int)? {
        let row: Row? = try? store.dbQueue.read {
            try Row.fetchOne($0, sql: """
                SELECT conversationId, clientMsgId, MAX(rev) AS rev FROM e2ee_plaintext WHERE messageId = ?
                """, arguments: [messageId])
        }
        guard let row, let conv: String = row["conversationId"], let cmid: String = row["clientMsgId"],
              let rev: Int = row["rev"] else { return nil }
        return (conv, cmid, rev)
    }

    func previewText(conversationId: String, near date: Date?) -> String? {
        let rows: [Row] = (try? store.dbQueue.read {
            try Row.fetchAll($0, sql: """
                SELECT text, createdAt FROM e2ee_plaintext WHERE conversationId = ?
                ORDER BY createdAt DESC LIMIT 3
                """, arguments: [conversationId])
        }) ?? []
        guard let first = rows.first else { return nil }
        guard let date else { return first["text"] }
        for r in rows {
            let t: Double = r["createdAt"]
            if abs(t - date.timeIntervalSince1970) < 2 { return r["text"] }
        }
        return nil
    }

    func loadEnabledConversations() -> Set<String> {
        Set((try? store.dbQueue.read { try String.fetchAll($0, sql: "SELECT conversationId FROM e2ee_conversations") }) ?? [])
    }
    func saveEnabled(_ conversationId: String) {
        try? store.dbQueue.write {
            try $0.execute(sql: "INSERT OR IGNORE INTO e2ee_conversations (conversationId) VALUES (?)", arguments: [conversationId])
        }
    }
}
