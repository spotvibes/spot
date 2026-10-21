import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

enum E2EEHydration { @TaskLocal static var skip = false }

@MainActor
final class E2EEStatusStore: ObservableObject {
    static let shared = E2EEStatusStore()
    @Published private(set) var enabledConversationIds: Set<String> = []
    @Published private(set) var isReady = false

    func isEnabled(_ conversationId: String) -> Bool { enabledConversationIds.contains(conversationId) }

    fileprivate func publish(enabled: Set<String>) {
        if Thread.isMainThread { enabledConversationIds = enabled } else {
            DispatchQueue.main.async { self.enabledConversationIds = enabled }
        }
    }
    fileprivate func publish(ready: Bool) {
        if Thread.isMainThread { isReady = ready } else { DispatchQueue.main.async { self.isReady = ready } }
    }
}

final class E2EEService {
    static let shared = E2EEService()
    private init() {}

    static var wipeOnSignOut = true

    private let lock = NSLock()
    private var activeUserId: String?
    private var engine: E2EEEngine?
    private var enabled: Set<String> = []
    private var deviceCache: [String: (value: E2EEConversationDevices, at: Date)] = [:]
    private var bootstrapping = false
    private var ready = false
    private static let deviceCacheTTL: TimeInterval = 60

    func activate(userId: String) {
        lock.lock(); defer { lock.unlock() }
        if activeUserId != userId {
            engine = nil; enabled = []; deviceCache = [:]; ready = false
            activeUserId = userId
            E2EEStatusStore.shared.publish(enabled: [])
            E2EEStatusStore.shared.publish(ready: false)
        }
    }

    func ensureEngine() -> E2EEEngine? {
        lock.lock(); defer { lock.unlock() }
        if let engine { return engine }
        guard let uid = activeUserId else { return nil }
        guard let e = try? E2EEEngine.open(userId: uid) else { return nil }
        engine = e
        E2EEShared.setActiveUser(uid)
        enabled = e.loadEnabledConversations()
        E2EEStatusStore.shared.publish(enabled: enabled)
        return e
    }

    var deviceId: String? { ensureEngine()?.deviceId }

    func bootstrap(userId: String) {
        activate(userId: userId)
        lock.lock()
        if bootstrapping { lock.unlock(); return }
        bootstrapping = true
        lock.unlock()
        Task.detached(priority: .utility) { [weak self] in
            await self?.runBootstrap()
            self?.lock.lock(); self?.bootstrapping = false; self?.lock.unlock()
        }
    }

    func waitUntilReady(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            lock.lock(); let r = ready; let uid = activeUserId; let busy = bootstrapping; lock.unlock()
            if r { return true }
            if !busy, let uid { bootstrap(userId: uid) }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func runBootstrap() async {
        guard let engine = ensureEngine() else { return }
        let net = NetworkService.shared
        do {
            do {
                let counts = try await net.e2eePreKeyCounts(deviceId: engine.deviceId)
                try await replenish(engine: engine, counts: counts)
            } catch NetworkError.serverError(let status, _) where status == 404 {

                let name = await Self.deviceName()
                let body = try engine.makeRegistrationBody(name: name)
                try await net.e2eeRegisterDevice(body)
            }
            lock.lock(); ready = true; lock.unlock()
            E2EEStatusStore.shared.publish(ready: true)
        } catch {
            #if DEBUG
            print("DEBUG: E2EE bootstrap failed (non-fatal): \(error)")
            #endif
        }
    }

    private func replenish(engine: E2EEEngine, counts: E2EEPreKeyCounts) async throws {
        let net = NetworkService.shared
        if counts.oneTimePrekeys < 25 || counts.oneTimeKyberPrekeys < 10 {
            let otp = counts.oneTimePrekeys < 25 ? try engine.generateOneTimePreKeys(count: 100) : []
            let kyber = counts.oneTimeKyberPrekeys < 10 ? try engine.generateOneTimeKyberPreKeys(count: 100) : []
            _ = try await net.e2eeUploadPreKeys(deviceId: engine.deviceId,
                                                body: E2EEUploadPreKeysBody(oneTimePrekeys: otp, oneTimeKyberPrekeys: kyber))
        }
        if engine.signedPreKeyIsStale {
            let spk = try engine.rotateSignedPreKey()
            try await net.e2eeRotateSignedPreKey(deviceId: engine.deviceId, body: E2EERotateSignedPreKeyBody(signedPrekey: spk))
        }
    }

    @MainActor private static func deviceNameOnMain() -> String {
        #if canImport(UIKit)
        return UIDevice.current.model
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }
    private static func deviceName() async -> String { await deviceNameOnMain() }

    func signOut() async {
        let (uid, eng) = { () -> (String?, E2EEEngine?) in lock.lock(); defer { lock.unlock() }; return (activeUserId, engine) }()
        if Self.wipeOnSignOut, let eng {
            try? await NetworkService.shared.e2eeRevokeDevice(eng.deviceId)
        }
        lock.lock()
        engine = nil; enabled = []; deviceCache = [:]; activeUserId = nil; ready = false
        lock.unlock()
        E2EEStatusStore.shared.publish(enabled: [])
        E2EEStatusStore.shared.publish(ready: false)
        E2EEShared.setActiveUser(nil)
        if Self.wipeOnSignOut, let uid { E2EEStore.wipe(userId: uid); E2EEMedia.wipe() }
    }

    func isEnabled(_ conversationId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled.contains(conversationId)
    }

    func markEnabled(_ conversationId: String) {
        lock.lock()
        let inserted = enabled.insert(conversationId).inserted
        let snapshot = enabled
        lock.unlock()
        guard inserted else { return }
        engine?.saveEnabled(conversationId)
        E2EEStatusStore.shared.publish(enabled: snapshot)
    }

    func adopt(_ summaries: [BackendConversationSummary]) -> [BackendConversationSummary] {
        summaries.map { s in
            guard s.e2eeEnabled else { return s }
            markEnabled(s.conversationId)
            guard s.lastMessagePreview.isEmpty, s.lastMessageContentType == .text || s.lastMessageContentType == nil else { return s }
            var out = s
            out.lastMessagePreview = ensureEngine()?.previewText(conversationId: s.conversationId, near: s.lastMessageAt)
                ?? (s.lastMessageAt == nil ? "" : E2EEPlaceholder.previewFallback)
            return out
        }
    }

    func enable(conversationId: String) async throws {
        guard ensureEngine() != nil else { throw E2EEError.notReady }
        let devices = try await NetworkService.shared.e2eeConversationDevices(conversationId)
        if !devices.usersWithoutDevices.isEmpty {
            throw NetworkError.serverError(statusCode: 409,
                message: "Someone in this chat hasn't set up encryption yet. Ask them to update the app.")
        }
        _ = try await NetworkService.shared.e2eeEnable(conversationId: conversationId)
        markEnabled(conversationId)
    }

    private func devices(for conversationId: String, refresh: Bool) async throws -> E2EEConversationDevices {
        lock.lock()
        if !refresh, let c = deviceCache[conversationId], Date().timeIntervalSince(c.at) < Self.deviceCacheTTL {
            lock.unlock(); return c.value
        }
        lock.unlock()
        let fresh = try await NetworkService.shared.e2eeConversationDevices(conversationId)
        lock.lock(); deviceCache[conversationId] = (fresh, Date()); lock.unlock()
        return fresh
    }

    func invalidateDevices(_ conversationId: String) {
        lock.lock(); deviceCache[conversationId] = nil; lock.unlock()
    }

    private func buildPayload(engine: E2EEEngine, conversationId: String, text: String, att: E2EEAttachment? = nil,
                              clientMsgId: String, rev: Int, refresh: Bool) async throws -> E2EESendPayload {
        let list = try await devices(for: conversationId, refresh: refresh)
        let targets = list.devices.map { $0.deviceId.lowercased() }.filter { $0 != engine.deviceId }
        if targets.isEmpty { throw E2EEError.recipientsUnavailable }

        let framed = try engine.frame(text, att: att)
        let cts = try await ciphertexts(engine: engine, conversationId: conversationId, framed: framed, targets: targets)
        return E2EESendPayload(senderDeviceId: engine.deviceId, clientMsgId: clientMsgId, rev: rev, ciphertexts: cts)
    }

    private func ciphertexts(engine: E2EEEngine, conversationId: String, framed: Data,
                             targets: [String]) async throws -> [E2EECiphertext] {

        let missing = targets.filter { !engine.hasSession(with: $0) }
        if !missing.isEmpty {
            let bundles = try await NetworkService.shared.e2eePreKeyBundles(conversationId: conversationId, deviceIds: missing)
            for b in bundles { try engine.process(bundle: b) }
        }
        var cts: [E2EECiphertext] = []
        for t in targets {
            do { cts.append(try engine.encrypt(framed, to: t)) }
            catch E2EEError.noSession(_) {

                engine.dropSession(with: t)
                let b = try await NetworkService.shared.e2eePreKeyBundles(conversationId: conversationId, deviceIds: [t])
                for x in b { try engine.process(bundle: x) }
                cts.append(try engine.encrypt(framed, to: t))
            }
        }
        return cts
    }

    struct Ephemeral: Codable {
        var senderDeviceId: String
        var ciphertexts: [E2EECiphertext]
        enum CodingKeys: String, CodingKey { case senderDeviceId = "sender_device_id"; case ciphertexts }
    }

    var currentUserId: String? { lock.lock(); defer { lock.unlock() }; return activeUserId?.lowercased() }

    func encryptEphemeral(conversationId: String, object: [String: Any], refresh: Bool = false) async throws -> Ephemeral {
        guard let engine = ensureEngine(), await waitUntilReady(timeout: 3) else { throw E2EEError.notReady }
        let list = try await devices(for: conversationId, refresh: refresh)
        let targets = list.devices.map { $0.deviceId.lowercased() }.filter { $0 != engine.deviceId }
        if targets.isEmpty { throw E2EEError.recipientsUnavailable }
        let json = try JSONSerialization.data(withJSONObject: object)
        let cts = try await ciphertexts(engine: engine, conversationId: conversationId, framed: engine.frameRaw(json), targets: targets)
        return Ephemeral(senderDeviceId: engine.deviceId, ciphertexts: cts)
    }

    func decryptEphemeral(senderDeviceId: String, ciphertexts: [E2EECiphertext]) -> [String: Any]? {
        guard let engine = ensureEngine(),
              let mine = ciphertexts.first(where: { $0.deviceId.lowercased() == engine.deviceId }),
              let body = Data(base64Encoded: mine.body),
              let plain = engine.decryptEphemeral(type: mine.msgType, body: body, from: senderDeviceId.lowercased())
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any]
    }

    func decryptEphemeral(frameField any: Any?) -> [String: Any]? {
        guard let dict = any as? [String: Any], let sender = dict["sender_device_id"] as? String,
              let raw = dict["ciphertexts"], let data = try? JSONSerialization.data(withJSONObject: raw),
              let cts = try? JSONDecoder().decode([E2EECiphertext].self, from: data) else { return nil }
        return decryptEphemeral(senderDeviceId: sender, ciphertexts: cts)
    }

    static func isEncryptable(_ body: SendMessageRequestBody) -> Bool {
        if body.e2eeAttachment != nil { return true }
        if body.contentType == .location { return E2EEMedia.locationAttachment(from: body) != nil }
        return body.contentType == .text && !(body.textContent ?? "").isEmpty
            && body.mediaUrl == nil && body.mediaMetadata == nil && !(body.isDisappearing ?? false)
    }

    func shouldEncrypt(conversationId: String) async -> Bool {
        let known = isEnabled(conversationId)
        guard ensureEngine() != nil, await waitUntilReady(timeout: known ? 8 : 3) else { return known }
        if known { return true }
        guard let list = try? await devices(for: conversationId, refresh: false) else { return false }
        return list.usersWithoutDevices.isEmpty && !list.devices.isEmpty
    }

    func sendEncryptedIfPossible(
        conversationId: String,
        body: SendMessageRequestBody,
        transport: @escaping (SendMessageRequestBody) async throws -> BackendMessage
    ) async throws -> BackendMessage? {
        guard Self.isEncryptable(body) else { return nil }
        let text = body.textContent ?? ""
        let att = body.e2eeAttachment ?? E2EEMedia.locationAttachment(from: body)

        let mustEncrypt = body.e2eeAttachment != nil
        let wasKnown = isEnabled(conversationId)
        guard let engine = ensureEngine() else { if wasKnown || mustEncrypt { throw E2EEError.notReady }; return nil }
        guard await waitUntilReady(timeout: wasKnown ? 8 : 3) else { if wasKnown || mustEncrypt { throw E2EEError.notReady }; return nil }

        let cmid = UUID().uuidString.lowercased()
        var lastError: Error = E2EEError.notReady
        for attempt in 0..<3 {

            let wire: SendMessageRequestBody
            do {
                let list = try await devices(for: conversationId, refresh: attempt > 0)
                if !isEnabled(conversationId), !list.usersWithoutDevices.isEmpty {
                    if mustEncrypt { throw E2EEError.recipientsUnavailable }
                    return nil
                }
                let payload = try await buildPayload(engine: engine, conversationId: conversationId, text: text, att: att,
                                                     clientMsgId: cmid, rev: 0, refresh: false)

                let cached = E2EEPlainPayload(body: text, att: att)
                engine.cacheText(clientMsgId: cmid, rev: 0, messageId: nil, conversationId: conversationId,
                                 senderDeviceId: engine.deviceId, createdAt: Date(), text: cached.displayText, att: att)
                var w = body
                w.textContent = nil; w.mediaUrl = nil; w.e2eeAttachment = nil
                w.mediaMetadata = E2EEMedia.publicMetadata(of: body.mediaMetadata)
                w.e2ee = payload
                wire = w
            } catch NetworkError.serverError(let status, _) where status == 409 {
                invalidateDevices(conversationId); lastError = NetworkError.serverError(statusCode: 409, message: "Devices changed")
                continue
            } catch {
                if !isEnabled(conversationId), !mustEncrypt { return nil }
                throw error
            }

            do {
                let sent = try await transport(wire)
                markEnabled(conversationId)
                return await decryptAsync(sent)
            } catch NetworkError.serverError(let status, let message) where status == 409 || status == 428 {
                invalidateDevices(conversationId)
                if status == 428 { markEnabled(conversationId) }
                lastError = NetworkError.serverError(statusCode: status, message: message)
            }
        }
        if !isEnabled(conversationId), !mustEncrypt { return nil }
        throw lastError
    }

    func edit(messageId: String, text: String) async throws -> BackendMessage? {
        guard let engine = ensureEngine(), let ctx = engine.editContext(messageId: messageId) else { return nil }
        let rev = ctx.rev + 1
        var lastError: Error = E2EEError.notReady
        for attempt in 0..<3 {
            do {
                let payload = try await buildPayload(engine: engine, conversationId: ctx.conversationId, text: text,
                                                     clientMsgId: ctx.clientMsgId, rev: rev, refresh: attempt > 0)
                engine.cacheText(clientMsgId: ctx.clientMsgId, rev: rev, messageId: messageId,
                                 conversationId: ctx.conversationId, senderDeviceId: engine.deviceId,
                                 createdAt: Date(), text: text)
                let real = try await NetworkService.shared.e2eePatchMessage(
                    messageId: messageId, body: EditMessageRequestBody(text: "", e2ee: payload))
                return await decryptAsync(real)
            } catch NetworkError.serverError(let status, _) where status == 409 {
                invalidateDevices(ctx.conversationId); lastError = NetworkError.serverError(statusCode: 409, message: "Devices changed")
            }
        }
        throw lastError
    }

    struct SafetyInfo {
        var userId: String
        var number: String
        var qrPayload: String
        var deviceCount: Int
        var isVerified: Bool
        var changedSinceVerified: Bool

        var keyMismatch: Bool
    }

    func safetyMembers(conversationId: String) async -> [String] {
        guard let list = try? await devices(for: conversationId, refresh: true), let me = currentUserId else { return [] }
        return Array(Set(list.devices.map { $0.userId.lowercased() })).filter { $0 != me }.sorted()
    }

    func safetyInfo(conversationId: String, otherUserId: String) async throws -> SafetyInfo {
        guard let engine = ensureEngine(), let me = currentUserId else { throw E2EEError.notReady }
        let list = try await devices(for: conversationId, refresh: true)
        let other = otherUserId.lowercased()
        var mismatch = false
        func keys(for user: String) -> [Data] {
            list.devices.filter { $0.userId.lowercased() == user }.compactMap { d -> Data? in
                let id = d.deviceId.lowercased()
                if id == engine.deviceId { return engine.ownIdentityKey }
                guard let reported = Data(base64Encoded: d.identityKey) else { return nil }

                if let pinned = engine.pinnedIdentityKey(of: id) {
                    if pinned != reported { mismatch = true }
                    return pinned
                }
                return reported
            }
        }
        let mine = keys(for: me), theirs = keys(for: other)
        guard !theirs.isEmpty else { throw E2EEError.recipientsUnavailable }
        let digits = E2EESafetyNumber.number(
            mine: E2EESafetyNumber.halfNumber(userId: me, identityKeys: mine),
            theirs: E2EESafetyNumber.halfNumber(userId: other, identityKeys: theirs))
        let verified = engine.verifiedNumber(userId: other)
        return SafetyInfo(userId: other, number: digits, qrPayload: E2EESafetyNumber.qrPayload(digits),
                          deviceCount: theirs.count, isVerified: verified == digits,
                          changedSinceVerified: verified != nil && verified != digits, keyMismatch: mismatch)
    }

    func setVerified(userId: String, number: String?) { ensureEngine()?.setVerified(userId: userId, number: number) }

    func needsPreviewHydration(_ s: BackendConversationSummary) -> Bool {
        s.e2eeEnabled && s.lastMessageAt != nil && s.lastMessagePreview == E2EEPlaceholder.previewFallback
    }

    func latestPreview(conversationId: String) async -> String? {

        guard let page = try? await E2EEHydration.$skip.withValue(true, operation: {
                  try await NetworkService.shared.getMessages(conversationId: conversationId, limit: 5)
              }),
              let newest = page.filter({ $0.deletedAt == nil }).max(by: { $0.createdAt < $1.createdAt }),
              let text = ensureEngine()?.previewText(conversationId: conversationId, near: newest.createdAt),
              !text.isEmpty, text != E2EEPlaceholder.notForThisDevice, text != E2EEPlaceholder.undecryptable
        else { return nil }
        return text
    }

    func decrypt(_ m: BackendMessage) -> BackendMessage { decryptSplit(m).message }

    func decryptSplit(_ m: BackendMessage) -> (message: BackendMessage, att: E2EEAttachment?) {
        guard let env = m.e2eeEnvelope else { return (m, nil) }
        guard m.deletedAt == nil else { return (m, nil) }
        guard let engine = ensureEngine() else { return (m.withDecrypted(text: E2EEPlaceholder.undecryptable), nil) }
        let mine = m.e2eeCiphertexts?.first { $0.deviceId.lowercased() == engine.deviceId }
        guard let p = engine.decryptPayloadOnce(envelope: env, ciphertext: mine, messageId: m.id,
                                                conversationId: m.conversationId, createdAt: m.createdAt) else {
            return (m.withDecrypted(text: mine == nil ? E2EEPlaceholder.notForThisDevice : E2EEPlaceholder.undecryptable), nil)
        }
        markEnabled(m.conversationId)
        guard let att = p.att else { return (m.withDecrypted(text: p.body), nil) }
        var out = m.withDecrypted(text: p.body.isEmpty ? "" : p.body).withAttachment(att, mediaURL: nil, thumbURL: nil)
        if p.body.isEmpty { out = out.withText(nil) }
        return (out, att)
    }

    func decrypt(_ messages: [BackendMessage]) -> [BackendMessage] { messages.map { decrypt($0) } }

    func forgetBit(messageId: String) { ensureEngine()?.forgetBit(messageId: messageId) }

    func attachment(forMessageId id: String) -> E2EEAttachment? { ensureEngine()?.attachment(messageId: id) }

    func hydrate(_ m: BackendMessage, _ att: E2EEAttachment) async -> BackendMessage {
        guard let blob = att.blob else { return m }

        let fromOther = m.senderId.lowercased() != currentUserId
        if att.kind == "bit", fromOther {
            let thumbURL = try? await att.thumb.map { try await E2EEMedia.fetch($0) }
            return m.withAttachment(att, mediaURL: E2EEMedia.bitURL(messageId: m.id, mime: blob.mime), thumbURL: thumbURL)
        }
        async let main = try? E2EEMedia.fetch(blob, name: att.name)
        async let thumb: URL? = {
            guard let t = att.thumb else { return nil }
            return try? await E2EEMedia.fetch(t)
        }()
        let (mainURL, thumbURL) = await (main, thumb)
        return m.withAttachment(att, mediaURL: mainURL, thumbURL: thumbURL)
    }

    func decryptAsync(_ messages: [BackendMessage]) async -> [BackendMessage] {
        let split = messages.map { decryptSplit($0) }
        var out = split.map { $0.message }
        if E2EEHydration.skip { return out }
        await withTaskGroup(of: (Int, BackendMessage).self) { group in
            for (i, s) in split.enumerated() {
                guard let att = s.att, att.blob != nil else { continue }
                group.addTask { (i, await self.hydrate(s.message, att)) }
            }
            for await (i, m) in group { out[i] = m }
        }
        return out
    }

    func decryptAsync(_ m: BackendMessage) async -> BackendMessage {
        let s = decryptSplit(m)
        guard let att = s.att, att.blob != nil else { return s.message }
        return await hydrate(s.message, att)
    }

    func decryptEdit(messageId: String, conversationId: String, envelope: E2EEEnvelope,
                     ciphertexts: [E2EECiphertext], editedAt: Date?) -> String? {
        guard let engine = ensureEngine() else { return nil }
        let mine = ciphertexts.first { $0.deviceId.lowercased() == engine.deviceId }
        return engine.decryptOnce(envelope: envelope, ciphertext: mine, messageId: messageId,
                                  conversationId: conversationId, createdAt: editedAt ?? Date())
    }
}

extension BackendMessage {
    func withText(_ text: String?) -> BackendMessage {
        BackendMessage(
            id: id, conversationId: conversationId, senderId: senderId, senderType: senderType,
            contentType: contentType, textContent: text, mediaUrl: mediaUrl,
            mediaMetadata: mediaMetadata, replyToMessageId: replyToMessageId, isDisappearing: isDisappearing,
            expiresAt: expiresAt, createdAt: createdAt, deletedAt: deletedAt, reactions: reactions,
            delivered: delivered, opened: opened, openedAt: openedAt, editedAt: editedAt
        )
    }

    func withDecrypted(text: String) -> BackendMessage {
        BackendMessage(
            id: id, conversationId: conversationId, senderId: senderId, senderType: senderType,
            contentType: contentType, textContent: text, mediaUrl: mediaUrl,
            mediaMetadata: mediaMetadata, replyToMessageId: replyToMessageId, isDisappearing: isDisappearing,
            expiresAt: expiresAt, createdAt: createdAt, deletedAt: deletedAt, reactions: reactions,
            delivered: delivered, opened: opened, openedAt: openedAt, editedAt: editedAt
        )
    }
}
