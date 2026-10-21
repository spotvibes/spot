import Foundation

enum E2EENotificationDecryptor {

    private struct Envelope<T: Decodable>: Decodable { let data: T? }
    private struct PushPayload: Decodable {
        let envelope: E2EEEnvelope
        let ciphertext: E2EECiphertext
        let createdAt: String
        enum CodingKeys: String, CodingKey { case envelope, ciphertext; case createdAt = "created_at" }
    }

    static func decrypt(userInfo: [AnyHashable: Any], token: String, apiBaseURL: String,
                        completion: @escaping (String?) -> Void) {
        guard let conversationId = userInfo["conversation_id"] as? String,
              let messageId = userInfo["message_id"] as? String,
              UUID(uuidString: conversationId) != nil, UUID(uuidString: messageId) != nil,
              let userId = E2EEShared.activeUser(),
              let engine = try? E2EEEngine.open(userId: userId, createIfMissing: false),
              let url = URL(string: "\(apiBaseURL)/conversations/\(conversationId)/messages/\(messageId)/e2ee-push?device_id=\(engine.deviceId)")
        else { completion(nil); return }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 6

        URLSession.shared.dataTask(with: req) { data, response, _ in
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200,
                  let payload = (try? JSONDecoder().decode(Envelope<PushPayload>.self, from: data))?.data
            else { completion(nil); return }

            let created = parseDate(payload.createdAt) ?? Date()
            let text = engine.decryptOnce(envelope: payload.envelope, ciphertext: payload.ciphertext,
                                          messageId: messageId, conversationId: conversationId, createdAt: created)
            completion(text.map { String($0.prefix(1000)) })
        }.resume()
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
