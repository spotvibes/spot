import Foundation
import UserNotifications

class NotificationService: UNNotificationServiceExtension {
    private let apiBaseURL = AppConfig.apiBaseURL
    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        let userInfo = request.content.userInfo

        if userInfo["action"] as? String == "retract",
           let messageId = userInfo["message_id"] as? String {
            UNUserNotificationCenter.current().getDeliveredNotifications { [weak self] delivered in
                let matchingIdentifiers = delivered
                    .filter { ($0.request.content.userInfo["message_id"] as? String) == messageId }
                    .map { $0.request.identifier }
                if !matchingIdentifiers.isEmpty {
                    UNUserNotificationCenter.current()
                        .removeDeliveredNotifications(withIdentifiers: matchingIdentifiers)
                }
                self?.bestAttemptContent?.title = ""
                self?.bestAttemptContent?.subtitle = ""
                self?.bestAttemptContent?.body = ""
                self?.bestAttemptContent?.sound = nil
                self?.deliver()
            }
            return
        }

        if let dupMessageId = userInfo["message_id"] as? String {
            let emoji = userInfo["reaction_emoji"] as? String
            let actorId = userInfo["actor_id"] as? String
            UNUserNotificationCenter.current().getDeliveredNotifications { [weak self] delivered in
                let isDuplicate = delivered.contains {
                    $0.request.identifier != request.identifier
                        && ($0.request.content.userInfo["message_id"] as? String) == dupMessageId
                        && ($0.request.content.userInfo["reaction_emoji"] as? String) == emoji
                        && ($0.request.content.userInfo["actor_id"] as? String) == actorId
                }
                if isDuplicate {
                    self?.bestAttemptContent?.title = ""
                    self?.bestAttemptContent?.subtitle = ""
                    self?.bestAttemptContent?.body = ""
                    self?.bestAttemptContent?.sound = nil
                }
                self?.ackDeliveredAndShow(userInfo: userInfo)
            }
            return
        }

        ackDeliveredAndShow(userInfo: userInfo)
    }

    private func ackDeliveredAndShow(userInfo: [AnyHashable: Any]) {
        if userInfo["reaction_emoji"] != nil {
            deliver()
            return
        }
        let blanked = (bestAttemptContent?.title.isEmpty ?? true) && (bestAttemptContent?.body.isEmpty ?? true)

        guard let conversationId = userInfo["conversation_id"] as? String,
              let messageId = userInfo["message_id"] as? String,
              let token = PushAckTokenStore.read(),
              let url = URL(string: "\(apiBaseURL)/conversations/\(conversationId)/messages/\(messageId)/push-ack-delivered")
        else {
            deliver()
            return
        }

        let group = DispatchGroup()

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 5
        group.enter()
        URLSession.shared.dataTask(with: req) { _, response, error in
            if let error {
                print("DEBUG: NotificationService delivered-ack failed: \(error)")
            } else if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                print("DEBUG: NotificationService delivered-ack got 401 (stale cached token)")
            }
            group.leave()
        }.resume()

        if !blanked {
            group.enter()
            E2EENotificationDecryptor.decrypt(userInfo: userInfo, token: token, apiBaseURL: apiBaseURL) { [weak self] text in
                if let text, !text.isEmpty { self?.bestAttemptContent?.body = text }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in self?.deliver() }
    }

    override func serviceExtensionTimeWillExpire() {
        deliver()
    }

    private func deliver() {
        guard let contentHandler, let bestAttemptContent else { return }
        self.contentHandler = nil
        contentHandler(bestAttemptContent)
    }
}
enum PushAckTokenStore {
    private static let keychainAccessGroup = AppConfig.keychainAccessGroup
    private static let account = "push_ack_id_token"
    private static let service = "pushAck"

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: keychainAccessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ token: String) -> OSStatus {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: keychainAccessGroup,
        ]
        SecItemDelete(query as CFDictionary)
        var newItem = query
        newItem[kSecValueData as String] = data
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(newItem as CFDictionary, nil)
        if status != errSecSuccess {
            print("DEBUG: [PushAckTokenStore] write FAILED, OSStatus \(status)")
        }
        return status
    }

    @discardableResult
    static func clear() -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: keychainAccessGroup,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            print("DEBUG: [PushAckTokenStore] clear FAILED, OSStatus \(status)")
        }
        return status
    }
}
