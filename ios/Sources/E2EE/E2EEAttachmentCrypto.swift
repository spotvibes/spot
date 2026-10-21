import Foundation
import CryptoKit

enum E2EEAttachmentCrypto {
    static let chunkSize = 256 * 1024
    private static let magic: [UInt8] = [0x53, 0x50, 0x45, 0x31]
    private static let tagSize = 16
    private static let headerSize = 16

    enum CryptoError: Error { case badHeader, authFailed, digestMismatch, io }

    struct Result { let key: Data; let digest: Data; let plainSize: Int64 }

    private static func nonce(prefix: Data, index: UInt32) throws -> AES.GCM.Nonce {
        var d = prefix
        var be = index.bigEndian
        withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
        return try AES.GCM.Nonce(data: d)
    }

    private static func aad(header: Data, final: Bool) -> Data {
        var d = header; d.append(final ? 1 : 0); return d
    }

    static func encryptFile(at src: URL, to dst: URL) throws -> Result {
        let key = SymmetricKey(size: .bits256)
        var prefix = Data(count: 8)
        let rc = prefix.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!) }
        guard rc == errSecSuccess else { throw CryptoError.io }

        var header = Data(magic)
        var cs = UInt32(chunkSize).bigEndian
        withUnsafeBytes(of: &cs) { header.append(contentsOf: $0) }
        header.append(prefix)

        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let input = try FileHandle(forReadingFrom: src)
        let output = try FileHandle(forWritingTo: dst)
        defer { try? input.close(); try? output.close() }

        var hasher = SHA256()
        try output.write(contentsOf: header); hasher.update(data: header)

        var plainSize: Int64 = 0
        var index: UInt32 = 0
        var current = try input.read(upToCount: chunkSize) ?? Data()
        while true {
            let next = try input.read(upToCount: chunkSize) ?? Data()
            let isFinal = next.isEmpty
            let box = try AES.GCM.seal(current, using: key, nonce: nonce(prefix: prefix, index: index),
                                       authenticating: aad(header: header, final: isFinal))
            let blob = box.ciphertext + box.tag
            try output.write(contentsOf: blob); hasher.update(data: blob)
            plainSize += Int64(current.count)
            if isFinal { break }
            current = next
            index += 1
        }
        return Result(key: key.withUnsafeBytes { Data($0) }, digest: Data(hasher.finalize()), plainSize: plainSize)
    }

    static func decryptFile(at src: URL, to dst: URL, key keyData: Data, expectedDigest: Data?) throws {
        do {
            if let expectedDigest {
                var h = SHA256()
                let f = try FileHandle(forReadingFrom: src)
                defer { try? f.close() }
                while let d = try f.read(upToCount: 1 << 20), !d.isEmpty { h.update(data: d) }
                guard Data(h.finalize()) == expectedDigest else { throw CryptoError.digestMismatch }
            }
            let key = SymmetricKey(data: keyData)
            let input = try FileHandle(forReadingFrom: src)
            defer { try? input.close() }
            guard let header = try input.read(upToCount: headerSize), header.count == headerSize,
                  [UInt8](header.prefix(4)) == magic else { throw CryptoError.badHeader }
            let cs = Int(header.subdata(in: 4..<8).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            guard cs > 0, cs <= 4 * 1024 * 1024 else { throw CryptoError.badHeader }
            let prefix = header.subdata(in: 8..<16)

            FileManager.default.createFile(atPath: dst.path, contents: nil)
            let output = try FileHandle(forWritingTo: dst)
            defer { try? output.close() }

            let block = cs + tagSize
            var index: UInt32 = 0
            var current = try input.read(upToCount: block) ?? Data()
            guard current.count >= tagSize else { throw CryptoError.authFailed }
            while true {
                let next = try input.read(upToCount: block) ?? Data()
                let isFinal = next.isEmpty
                let ct = current.prefix(current.count - tagSize)
                let tag = current.suffix(tagSize)
                let sealed = try AES.GCM.SealedBox(nonce: nonce(prefix: prefix, index: index), ciphertext: ct, tag: tag)
                let plain: Data
                do { plain = try AES.GCM.open(sealed, using: key, authenticating: aad(header: header, final: isFinal)) }
                catch { throw CryptoError.authFailed }
                try output.write(contentsOf: plain)
                if isFinal { break }
                guard next.count >= tagSize else { throw CryptoError.authFailed }
                current = next
                index += 1
            }
        } catch {
            try? FileManager.default.removeItem(at: dst)
            throw error
        }
    }

    static func decryptData(_ blob: Data, key keyData: Data, expectedDigest: Data?) throws -> Data {
        if let expectedDigest, Data(SHA256.hash(data: blob)) != expectedDigest { throw CryptoError.digestMismatch }
        let key = SymmetricKey(data: keyData)
        guard blob.count >= headerSize + tagSize, [UInt8](blob.prefix(4)) == magic else { throw CryptoError.badHeader }
        let header = blob.prefix(headerSize)
        let cs = Int(header.subdata(in: 4..<8).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard cs > 0, cs <= 4 * 1024 * 1024 else { throw CryptoError.badHeader }
        let prefix = header.subdata(in: 8..<16)
        let block = cs + tagSize
        var out = Data(); out.reserveCapacity(blob.count)
        var offset = headerSize
        var index: UInt32 = 0
        while offset < blob.count {
            let end = min(offset + block, blob.count)
            let chunk = blob.subdata(in: offset..<end)
            guard chunk.count >= tagSize else { throw CryptoError.authFailed }
            let isFinal = end == blob.count
            let sealed = try AES.GCM.SealedBox(nonce: nonce(prefix: prefix, index: index),
                                               ciphertext: chunk.prefix(chunk.count - tagSize), tag: chunk.suffix(tagSize))
            do { out.append(try AES.GCM.open(sealed, using: key, authenticating: aad(header: Data(header), final: isFinal))) }
            catch { throw CryptoError.authFailed }
            offset = end; index += 1
        }
        return out
    }
}
