import Foundation
import CryptoKit

enum E2EEMedia {
    enum MediaError: Error { case badURL, http(Int), badKey }

    static var directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("e2ee-media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()

    private static let mimeExt: [String: String] = [
        "image/jpeg": "jpg", "image/jpg": "jpg", "image/png": "png", "image/heic": "heic", "image/gif": "gif",
        "video/mp4": "mp4", "video/quicktime": "mov", "audio/m4a": "m4a", "audio/mp4": "m4a", "audio/x-caf": "caf",
        "application/pdf": "pdf", "text/plain": "txt", "text/csv": "csv", "application/zip": "zip",
        "application/msword": "doc",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
    ]

    static func localURL(for ref: E2EEBlobRef, name: String? = nil) -> URL {
        let hash = String(SHA256.hash(data: Data(ref.url.utf8)).map { String(format: "%02x", $0) }.joined().prefix(40))
        if let name {
            let clean = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
            if !clean.isEmpty, clean != ".", clean != ".." {
                let folder = directory.appendingPathComponent(hash, isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                return folder.appendingPathComponent(clean)
            }
        }
        let ext = ref.mime.flatMap { mimeExt[$0.lowercased()] } ?? "dat"
        return directory.appendingPathComponent("\(hash).\(ext)")
    }

    static func bitURL(messageId: String, mime: String?) -> URL {
        let ext = (mime.flatMap { mimeExt[$0.lowercased()] }) ?? "jpg"
        return URL(string: "e2eebit://\(messageId).\(ext)")!
    }

    static func rebase(_ urlString: String?) -> String? {
        guard let urlString, urlString.hasPrefix("file://"),
              let r = urlString.range(of: "/e2ee-media/") else { return urlString }
        return directory.absoluteString.appending(String(urlString[r.upperBound...]))
    }

    static func rebase(_ m: MessageMediaMetadata?) -> MessageMediaMetadata? {
        guard var m, m.thumbnailUrl?.hasPrefix("file://") == true else { return m }
        m.thumbnailUrl = rebase(m.thumbnailUrl)
        return m
    }

    static func wipe() { try? FileManager.default.removeItem(at: directory); try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }

    static func fetch(_ ref: E2EEBlobRef, name: String? = nil) async throws -> URL {
        let dest = localURL(for: ref, name: name)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        guard let url = URL(string: ref.url), url.scheme == "https" else { throw MediaError.badURL }
        guard let key = Data(base64Encoded: ref.key), key.count == 32 else { throw MediaError.badKey }
        let digest = Data(base64Encoded: ref.digest)

        let (tmp, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: tmp) }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { throw MediaError.http(http.statusCode) }
        try await Task.detached(priority: .utility) {
            try E2EEAttachmentCrypto.decryptFile(at: tmp, to: dest, key: key, expectedDigest: digest)
        }.value
        return dest
    }

    static func makeAttachment(from body: SendMessageRequestBody, blobs: [(ref: E2EEBlobRef, name: String?)]) -> E2EEAttachment? {
        guard let first = blobs.first else { return nil }
        let kind: String
        switch body.contentType {
        case .image: kind = "image"
        case .video: kind = "video"
        case .voice: kind = "voice"
        case .file: kind = "file"
        case .bit: kind = "bit"
        default: return nil
        }
        let m = body.mediaMetadata
        return E2EEAttachment(
            kind: kind, blob: first.ref, thumb: blobs.count > 1 ? blobs[1].ref : nil,
            name: kind == "file" ? first.name : nil, w: m?.width, h: m?.height, durationMs: m?.durationMs,
            viewDurationSeconds: m?.viewDurationSeconds, lat: nil, lng: nil, live: nil)
    }

    static func locationAttachment(from body: SendMessageRequestBody) -> E2EEAttachment? {
        guard body.contentType == .location, let m = body.mediaMetadata, let lat = m.lat, let lng = m.lng else { return nil }
        return E2EEAttachment(kind: "location", blob: nil, thumb: nil, name: nil, w: nil, h: nil, durationMs: nil,
                              viewDurationSeconds: nil, lat: lat, lng: lng, live: m.isLiveLocation)
    }

    static func publicMetadata(of m: MessageMediaMetadata?) -> MessageMediaMetadata? {
        guard let m, m.viewDurationSeconds != nil || m.isLiveLocation == true else { return nil }
        var out = MessageMediaMetadata(durationMs: nil, fileSizeBytes: nil, mimeType: nil, thumbnailUrl: nil,
                                       width: nil, height: nil, lat: nil, lng: nil, isLiveLocation: m.isLiveLocation)
        out.viewDurationSeconds = m.viewDurationSeconds
        return out
    }
}

final class E2EEUploadCapture {
    private let lock = NSLock()
    private var items: [(ref: E2EEBlobRef, name: String?)] = []
    func append(_ ref: E2EEBlobRef, name: String?) { lock.lock(); items.append((ref, name)); lock.unlock() }
    var blobs: [(ref: E2EEBlobRef, name: String?)] { lock.lock(); defer { lock.unlock() }; return items }
}

enum E2EEBitLoader {
    static func data(messageId: String) async throws -> Data {
        guard let att = E2EEService.shared.attachment(forMessageId: messageId), let blob = att.blob,
              let url = URL(string: blob.url), url.scheme == "https",
              let key = Data(base64Encoded: blob.key) else { throw E2EEMedia.MediaError.badKey }
        let (bytes, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { throw E2EEMedia.MediaError.http(http.statusCode) }
        let digest = Data(base64Encoded: blob.digest)
        return try await Task.detached(priority: .userInitiated) {
            try E2EEAttachmentCrypto.decryptData(bytes, key: key, expectedDigest: digest)
        }.value
    }
}

enum E2EEUploadContext {
    @TaskLocal static var capture: E2EEUploadCapture?
}

extension BackendMessage {

    func withAttachment(_ a: E2EEAttachment, mediaURL: URL?, thumbURL: URL?) -> BackendMessage {
        let meta = MessageMediaMetadata(
            durationMs: a.durationMs, fileSizeBytes: a.blob?.size, mimeType: a.blob?.mime,
            thumbnailUrl: thumbURL?.absoluteString, width: a.w, height: a.h, lat: a.lat, lng: a.lng,
            isLiveLocation: a.live ?? mediaMetadata?.isLiveLocation,
            viewDurationSeconds: a.viewDurationSeconds ?? mediaMetadata?.viewDurationSeconds)
        return BackendMessage(
            id: id, conversationId: conversationId, senderId: senderId, senderType: senderType,
            contentType: contentType, textContent: textContent, mediaUrl: mediaURL?.absoluteString,
            mediaMetadata: meta, replyToMessageId: replyToMessageId, isDisappearing: isDisappearing,
            expiresAt: expiresAt, createdAt: createdAt, deletedAt: deletedAt, reactions: reactions,
            delivered: delivered, opened: opened, openedAt: openedAt, editedAt: editedAt)
    }
}
