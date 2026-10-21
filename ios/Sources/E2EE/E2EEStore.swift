import Foundation
import GRDB
import LibSignalClient
import Security

enum E2EEError: Error, LocalizedError {
    case notReady
    case storage(String)
    case noSession(String)
    case untrustedIdentity
    case invalidPayload
    case replayedKyberPreKey
    case recipientsUnavailable

    var errorDescription: String? {
        switch self {
        case .notReady: return "Encryption isn't ready yet."
        case .storage(let s): return "Encryption storage error: \(s)"
        case .noSession(let d): return "No session with device \(d)."
        case .untrustedIdentity: return "A device's security key changed."
        case .invalidPayload: return "Invalid encrypted payload."
        case .replayedKyberPreKey: return "Replayed key material."
        case .recipientsUnavailable: return "Nobody in this chat can receive encrypted messages yet."
        }
    }
}

enum E2EEShared {
    static var appGroupId = "group.com.example.app"
    static var keychainAccessGroup: String? = "group.com.example.app"

    static var groupContainer: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }

    static func directory() throws -> URL {
        let base: URL
        if let g = groupContainer {
            base = g
        } else {
            base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        }
        let dir = base.appendingPathComponent("E2EE", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var activeUserFile: URL? { try? directory().appendingPathComponent("active-user") }

    static func setActiveUser(_ userId: String?) {
        guard let url = activeUserFile else { return }
        if let userId { try? Data(userId.utf8).write(to: url, options: .atomic) }
        else { try? FileManager.default.removeItem(at: url) }
    }

    static func activeUser() -> String? {
        guard let url = activeUserFile, let d = try? Data(contentsOf: url),
              let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }
}

final class E2EEMutex {
    private let inner = NSRecursiveLock()
    private var depth = 0
    private var fd: Int32 = -1
    private var holdsFileLock = false
    private let timeout: TimeInterval

    init(lockFile: URL?, timeout: TimeInterval = 10) {
        self.timeout = timeout
        if let lockFile { fd = open(lockFile.path, O_CREAT | O_RDWR, 0o600) }
    }
    deinit { if fd >= 0 { close(fd) } }

    func lock() {
        inner.lock()
        if depth == 0, fd >= 0 {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                if flock(fd, LOCK_EX | LOCK_NB) == 0 { holdsFileLock = true; break }
                if Date() >= deadline { holdsFileLock = false; break }
                usleep(5_000)
            }
        }
        depth += 1
    }

    func unlock() {
        depth -= 1
        if depth == 0, fd >= 0, holdsFileLock { flock(fd, LOCK_UN); holdsFileLock = false }
        inner.unlock()
    }
}

enum E2EEKeychain {
    private static let service = "app.e2ee"

    private static func baseQuery(_ account: String, shared: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if shared, let g = E2EEShared.keychainAccessGroup { q[kSecAttrAccessGroup as String] = g }
        #if os(macOS)
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
        return q
    }

    static func read(account: String) -> Data? {
        for shared in [true, false] {
            var q = baseQuery(account, shared: shared)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data { return d }
        }
        return nil
    }

    @discardableResult
    static func write(_ data: Data, account: String) -> Bool {
        for shared in [true, false] {
            let q = baseQuery(account, shared: shared)
            let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecSuccess { return true }
            if status == errSecItemNotFound {
                var add = q
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                if SecItemAdd(add as CFDictionary, nil) == errSecSuccess { return true }
            }
        }
        return false
    }

    static func delete(account: String) {
        for shared in [true, false] { SecItemDelete(baseQuery(account, shared: shared) as CFDictionary) }
    }
}

struct E2EEDeviceIdentity: Codable {
    var deviceId: String
    var registrationId: UInt32
    var identityKeyPair: Data
}

final class E2EEStore {
    let userId: String
    let identity: E2EEDeviceIdentity
    let identityKeyPair: IdentityKeyPair
    let dbQueue: DatabaseQueue
    private let dbURL: URL

    var lockURL: URL { dbURL.deletingLastPathComponent().appendingPathComponent("e2ee.lock") }

    static func open(userId: String, createIfMissing: Bool = true) throws -> E2EEStore {
        let account = "device.\(userId)"
        let dbURL = try databaseURL(userId: userId)
        let fm = FileManager.default
        let dbExists = fm.fileExists(atPath: dbURL.path)

        var identity: E2EEDeviceIdentity?
        if let data = E2EEKeychain.read(account: account) {
            identity = try? JSONDecoder().decode(E2EEDeviceIdentity.self, from: data)
        }

        if !createIfMissing {
            guard identity != nil, dbExists else { throw E2EEError.notReady }
        }
        if identity != nil && !dbExists {
            E2EEKeychain.delete(account: account)
            identity = nil
        }
        if identity == nil && dbExists {
            try? fm.removeItem(at: dbURL)
        }

        let resolved: E2EEDeviceIdentity
        if let identity { resolved = identity } else {
            let pair = IdentityKeyPair.generate()
            resolved = E2EEDeviceIdentity(
                deviceId: UUID().uuidString.lowercased(),
                registrationId: UInt32.random(in: 1...16380),
                identityKeyPair: Data(pair.serialize())
            )
            guard let enc = try? JSONEncoder().encode(resolved), E2EEKeychain.write(enc, account: account) else {
                throw E2EEError.storage("keychain write failed")
            }
        }
        let pair = try IdentityKeyPair(bytes: [UInt8](resolved.identityKeyPair))

        var config = Configuration()
        config.busyMode = .timeout(5)
        let queue = try DatabaseQueue(path: dbURL.path, configuration: config)
        try migrator.migrate(queue)
        harden(dbURL)
        return E2EEStore(userId: userId, identity: resolved, keyPair: pair, queue: queue, url: dbURL)
    }

    private init(userId: String, identity: E2EEDeviceIdentity, keyPair: IdentityKeyPair, queue: DatabaseQueue, url: URL) {
        self.userId = userId
        self.identity = identity
        self.identityKeyPair = keyPair
        self.dbQueue = queue
        self.dbURL = url
    }

    static func wipe(userId: String) {
        E2EEKeychain.delete(account: "device.\(userId)")
        if E2EEShared.activeUser() == userId { E2EEShared.setActiveUser(nil) }
        if let url = try? databaseURL(userId: userId) {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
    }

    private static func databaseURL(userId: String) throws -> URL {
        let base = try E2EEShared.directory()
        let safe = userId.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return base.appendingPathComponent("e2ee-\(safe).sqlite")
    }

    private static func harden(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("e2ee_v1") { db in
            try db.create(table: "e2ee_sessions") { t in
                t.primaryKey("address", .text); t.column("record", .blob).notNull()
            }
            try db.create(table: "e2ee_prekeys") { t in
                t.primaryKey("id", .integer); t.column("record", .blob).notNull()
            }
            try db.create(table: "e2ee_signed_prekeys") { t in
                t.primaryKey("id", .integer); t.column("record", .blob).notNull()
                t.column("createdAt", .double).notNull()
            }
            try db.create(table: "e2ee_kyber_prekeys") { t in
                t.primaryKey("id", .integer); t.column("record", .blob).notNull()
                t.column("isLastResort", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "e2ee_kyber_used") { t in
                t.column("kyberId", .integer).notNull(); t.column("baseKey", .blob).notNull()
                t.primaryKey(["kyberId", "baseKey"])
            }
            try db.create(table: "e2ee_identities") { t in
                t.primaryKey("address", .text); t.column("identityKey", .blob).notNull()
            }
            try db.create(table: "e2ee_meta") { t in
                t.primaryKey("key", .text); t.column("value", .text).notNull()
            }
            try db.create(table: "e2ee_conversations") { t in
                t.primaryKey("conversationId", .text)
            }

            try db.create(table: "e2ee_plaintext") { t in
                t.column("clientMsgId", .text).notNull()
                t.column("rev", .integer).notNull()
                t.column("messageId", .text)
                t.column("conversationId", .text).notNull()
                t.column("senderDeviceId", .text).notNull()
                t.column("createdAt", .double).notNull()
                t.column("text", .text).notNull()
                t.primaryKey(["clientMsgId", "rev"])
            }
            try db.create(index: "e2ee_plaintext_msg", on: "e2ee_plaintext", columns: ["messageId"])
            try db.create(index: "e2ee_plaintext_conv", on: "e2ee_plaintext", columns: ["conversationId", "createdAt"])
        }
        m.registerMigration("e2ee_v2_attachments") { db in

            try db.alter(table: "e2ee_plaintext") { t in t.add(column: "att", .text) }
        }
        m.registerMigration("e2ee_v3_verified") { db in

            try db.create(table: "e2ee_verified") { t in
                t.column("userId", .text).notNull().primaryKey()
                t.column("number", .text).notNull()
                t.column("verifiedAt", .double).notNull()
            }
        }
        return m
    }

    func meta(_ key: String) -> String? {
        try? dbQueue.read { try String.fetchOne($0, sql: "SELECT value FROM e2ee_meta WHERE key = ?", arguments: [key]) }
    }
    func setMeta(_ key: String, _ value: String) {
        try? dbQueue.write { try $0.execute(sql: "INSERT OR REPLACE INTO e2ee_meta (key, value) VALUES (?, ?)", arguments: [key, value]) }
    }

    func reserveIds(_ counter: String, count: Int) throws -> [UInt32] {
        try dbQueue.write { db in
            let cur = try String.fetchOne(db, sql: "SELECT value FROM e2ee_meta WHERE key = ?", arguments: [counter]).flatMap(UInt32.init) ?? 1
            var ids: [UInt32] = []
            var next = cur
            for _ in 0..<count {
                ids.append(next)
                next = next >= 0xFFFFFE ? 1 : next + 1
            }
            try db.execute(sql: "INSERT OR REPLACE INTO e2ee_meta (key, value) VALUES (?, ?)", arguments: [counter, String(next)])
            return ids
        }
    }
}

final class E2EEProtocolStore: IdentityKeyStore, PreKeyStore, SignedPreKeyStore, KyberPreKeyStore, SessionStore {
    private let s: E2EEStore
    init(_ store: E2EEStore) { self.s = store }

    private func key(_ a: ProtocolAddress) -> String { "\(a.name):\(a.deviceId)" }

    func identityKeyPair(context: StoreContext) throws -> IdentityKeyPair { s.identityKeyPair }
    func localRegistrationId(context: StoreContext) throws -> UInt32 { s.identity.registrationId }

    func saveIdentity(_ identity: IdentityKey, for address: ProtocolAddress, context: StoreContext) throws -> IdentityChange {
        let k = key(address)
        let new = Data(identity.serialize())
        let old: Data? = try s.dbQueue.read { try Data.fetchOne($0, sql: "SELECT identityKey FROM e2ee_identities WHERE address = ?", arguments: [k]) }
        try s.dbQueue.write {
            try $0.execute(sql: "INSERT OR REPLACE INTO e2ee_identities (address, identityKey) VALUES (?, ?)", arguments: [k, new])
        }
        if let old, old != new { return .replacedExisting }
        return .newOrUnchanged
    }

    func isTrustedIdentity(_ identity: IdentityKey, for address: ProtocolAddress, direction: Direction, context: StoreContext) throws -> Bool {
        let k = key(address)
        guard let old: Data = try s.dbQueue.read({ try Data.fetchOne($0, sql: "SELECT identityKey FROM e2ee_identities WHERE address = ?", arguments: [k]) }) else {
            return true
        }
        return old == Data(identity.serialize())
    }

    func identity(for address: ProtocolAddress, context: StoreContext) throws -> IdentityKey? {
        let k = key(address)
        guard let d: Data = try s.dbQueue.read({ try Data.fetchOne($0, sql: "SELECT identityKey FROM e2ee_identities WHERE address = ?", arguments: [k]) }) else { return nil }
        return IdentityKey(publicKey: try PublicKey([UInt8](d)))
    }

    func loadSession(for address: ProtocolAddress, context: StoreContext) throws -> SessionRecord? {
        let k = key(address)
        guard let d: Data = try s.dbQueue.read({ try Data.fetchOne($0, sql: "SELECT record FROM e2ee_sessions WHERE address = ?", arguments: [k]) }) else { return nil }
        return try SessionRecord(bytes: [UInt8](d))
    }
    func storeSession(_ record: SessionRecord, for address: ProtocolAddress, context: StoreContext) throws {
        let k = key(address), d = Data(record.serialize())
        try s.dbQueue.write { try $0.execute(sql: "INSERT OR REPLACE INTO e2ee_sessions (address, record) VALUES (?, ?)", arguments: [k, d]) }
    }
    func deleteSession(for deviceId: String) throws {
        let k = "\(deviceId.lowercased()):1"
        try s.dbQueue.write { try $0.execute(sql: "DELETE FROM e2ee_sessions WHERE address = ?", arguments: [k]) }
    }
    func hasSession(for deviceId: String) -> Bool {
        let k = "\(deviceId.lowercased()):1"
        return ((try? s.dbQueue.read { try Int.fetchOne($0, sql: "SELECT 1 FROM e2ee_sessions WHERE address = ?", arguments: [k]) }) ?? nil) != nil
    }

    func loadPreKey(id: UInt32, context: StoreContext) throws -> PreKeyRecord {
        guard let d: Data = try s.dbQueue.read({ try Data.fetchOne($0, sql: "SELECT record FROM e2ee_prekeys WHERE id = ?", arguments: [Int(id)]) }) else {
            throw E2EEError.storage("missing prekey \(id)")
        }
        return try PreKeyRecord(bytes: [UInt8](d))
    }
    func storePreKey(_ record: PreKeyRecord, id: UInt32, context: StoreContext) throws {
        let d = Data(record.serialize())
        try s.dbQueue.write { try $0.execute(sql: "INSERT OR REPLACE INTO e2ee_prekeys (id, record) VALUES (?, ?)", arguments: [Int(id), d]) }
    }
    func removePreKey(id: UInt32, context: StoreContext) throws {
        try s.dbQueue.write { try $0.execute(sql: "DELETE FROM e2ee_prekeys WHERE id = ?", arguments: [Int(id)]) }
    }

    func loadSignedPreKey(id: UInt32, context: StoreContext) throws -> SignedPreKeyRecord {
        guard let d: Data = try s.dbQueue.read({ try Data.fetchOne($0, sql: "SELECT record FROM e2ee_signed_prekeys WHERE id = ?", arguments: [Int(id)]) }) else {
            throw E2EEError.storage("missing signed prekey \(id)")
        }
        return try SignedPreKeyRecord(bytes: [UInt8](d))
    }
    func storeSignedPreKey(_ record: SignedPreKeyRecord, id: UInt32, context: StoreContext) throws {
        let d = Data(record.serialize())
        try s.dbQueue.write {
            try $0.execute(sql: "INSERT OR REPLACE INTO e2ee_signed_prekeys (id, record, createdAt) VALUES (?, ?, ?)",
                           arguments: [Int(id), d, Date().timeIntervalSince1970])
        }
    }

    func loadKyberPreKey(id: UInt32, context: StoreContext) throws -> KyberPreKeyRecord {
        guard let d: Data = try s.dbQueue.read({ try Data.fetchOne($0, sql: "SELECT record FROM e2ee_kyber_prekeys WHERE id = ?", arguments: [Int(id)]) }) else {
            throw E2EEError.storage("missing kyber prekey \(id)")
        }
        return try KyberPreKeyRecord(bytes: [UInt8](d))
    }
    func storeKyberPreKey(_ record: KyberPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try storeKyber(record, id: id, lastResort: false)
    }
    func storeKyber(_ record: KyberPreKeyRecord, id: UInt32, lastResort: Bool) throws {
        let d = Data(record.serialize())
        try s.dbQueue.write {
            try $0.execute(sql: "INSERT OR REPLACE INTO e2ee_kyber_prekeys (id, record, isLastResort) VALUES (?, ?, ?)",
                           arguments: [Int(id), d, lastResort])
        }
    }

    func markKyberPreKeyUsed(id: UInt32, signedPreKeyId: UInt32, baseKey: PublicKey, context: StoreContext) throws {
        let base = Data(baseKey.serialize())
        try s.dbQueue.write { db in
            let last = try Bool.fetchOne(db, sql: "SELECT isLastResort FROM e2ee_kyber_prekeys WHERE id = ?", arguments: [Int(id)]) ?? false
            if last {
                let seen = try Int.fetchOne(db, sql: "SELECT 1 FROM e2ee_kyber_used WHERE kyberId = ? AND baseKey = ?", arguments: [Int(id), base])
                if seen != nil { throw E2EEError.replayedKyberPreKey }
                try db.execute(sql: "INSERT INTO e2ee_kyber_used (kyberId, baseKey) VALUES (?, ?)", arguments: [Int(id), base])
            } else {
                try db.execute(sql: "DELETE FROM e2ee_kyber_prekeys WHERE id = ?", arguments: [Int(id)])
            }
        }
    }
}
