import Foundation
import CryptoKit

enum E2EESafetyNumber {
    static let version: UInt8 = 1
    static let iterations = 5200

    static func halfNumber(userId: String, identityKeys: [Data]) -> String {
        let sorted = identityKeys.sorted { $0.lexicographicallyPrecedes($1) }
        let material = sorted.reduce(Data(), +)
        var hash = Data([0, version]) + material + Data(userId.lowercased().utf8)
        for _ in 0..<iterations { hash = Data(SHA512.hash(data: hash + material)) }
        var out = ""
        for i in 0..<6 {
            let chunk = hash[(hash.startIndex + i * 5)..<(hash.startIndex + i * 5 + 5)]
            let value = chunk.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            out += String(format: "%05llu", value % 100_000)
        }
        return out
    }

    static func number(mine: String, theirs: String) -> String {
        [mine, theirs].sorted().joined()
    }

    static func grouped(_ digits: String) -> [[String]] {
        let groups = stride(from: 0, to: digits.count, by: 5).map { i -> String in
            let s = digits.index(digits.startIndex, offsetBy: i)
            return String(digits[s..<digits.index(s, offsetBy: 5)])
        }
        return stride(from: 0, to: groups.count, by: 4).map { Array(groups[$0..<min($0 + 4, groups.count)]) }
    }

    static func qrPayload(_ digits: String) -> String { "e2ee-sn\(version):\(digits)" }
}
