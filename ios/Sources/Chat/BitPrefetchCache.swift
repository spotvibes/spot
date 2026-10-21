import Foundation

@MainActor
final class BitPrefetchCache: ObservableObject {
    static let shared = BitPrefetchCache()

    @Published private(set) var progress: [String: Double] = [:]

    private var completed: [String: Data] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    private init() {}

    func prefetch(messageId: String, remoteURL: URL) {
        guard completed[messageId] == nil, tasks[messageId] == nil else { return }
        progress[messageId] = 0

        tasks[messageId] = Task { [weak self] in
            guard let self else { return }
            do {
                if remoteURL.scheme == "e2eebit" {
                    let data = try await E2EEBitLoader.data(messageId: messageId)
                    try Task.checkCancellation()
                    self.completed[messageId] = data
                    self.progress[messageId] = 1.0
                    self.tasks[messageId] = nil
                    return
                }
                let (bytes, response) = try await URLSession.shared.bytes(from: remoteURL)
                guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                    throw URLError(.badServerResponse)
                }
                let expected = response.expectedContentLength
                var buffer = Data()
                if expected > 0 { buffer.reserveCapacity(Int(expected)) }
                var received: Int64 = 0
                var lastPublishedPct: Double = 0
                for try await byte in bytes {
                    buffer.append(byte)
                    received += 1
                    guard expected > 0 else { continue }
                    let pct = min(Double(received) / Double(expected), 1.0)
                    if pct - lastPublishedPct >= 0.01 || received == expected {
                        lastPublishedPct = pct
                        self.progress[messageId] = pct
                    }
                }
                self.completed[messageId] = buffer
                self.progress[messageId] = 1.0
            } catch {
                self.completed[messageId] = nil
                self.progress[messageId] = nil
            }
            self.tasks[messageId] = nil
        }
    }

    func isReady(_ messageId: String) -> Bool {
        completed[messageId] != nil
    }

    func data(for messageId: String) -> Data? {
        completed[messageId]
    }

    func discard(_ messageId: String) {
        E2EEService.shared.forgetBit(messageId: messageId)
        tasks[messageId]?.cancel()
        tasks[messageId] = nil
        completed[messageId] = nil
        progress[messageId] = nil
    }
}
