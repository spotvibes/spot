import Foundation

extension NetworkService {
    private func e2eeUnwrap<T>(_ r: ChatApiResponse<T>, _ fallback: String) throws -> T {
        guard r.success, let d = r.data else {
            throw NetworkError.serverError(statusCode: 400, message: r.error ?? fallback)
        }
        return d
    }

    func e2eeRegisterDevice(_ body: E2EERegisterDeviceBody) async throws {
        let r: ChatApiResponse<String> = try await put(endpoint: "/e2ee/devices", body: body)
        guard r.success else { throw NetworkError.serverError(statusCode: 400, message: r.error ?? "Couldn't register device") }
    }

    func e2eePreKeyCounts(deviceId: String) async throws -> E2EEPreKeyCounts {
        let r: ChatApiResponse<E2EEPreKeyCounts> = try await get(endpoint: "/e2ee/devices/\(deviceId)/prekeys")
        return try e2eeUnwrap(r, "Couldn't read prekey counts")
    }

    func e2eeUploadPreKeys(deviceId: String, body: E2EEUploadPreKeysBody) async throws -> E2EEPreKeyCounts {
        let r: ChatApiResponse<E2EEPreKeyCounts> = try await post(endpoint: "/e2ee/devices/\(deviceId)/prekeys", body: body)
        return try e2eeUnwrap(r, "Couldn't upload prekeys")
    }

    func e2eeRotateSignedPreKey(deviceId: String, body: E2EERotateSignedPreKeyBody) async throws {
        let r: ChatApiResponse<String> = try await put(endpoint: "/e2ee/devices/\(deviceId)/signed-prekey", body: body)
        guard r.success else { throw NetworkError.serverError(statusCode: 400, message: r.error ?? "Couldn't rotate key") }
    }

    func e2eeListMyDevices() async throws -> [E2EEDeviceSummary] {
        let r: ChatApiResponse<[E2EEDeviceSummary]> = try await get(endpoint: "/e2ee/devices")
        return try e2eeUnwrap(r, "Couldn't list devices")
    }

    func e2eeRevokeDevice(_ deviceId: String) async throws {
        let r: ChatApiResponse<String> = try await delete(endpoint: "/e2ee/devices/\(deviceId)")
        guard r.success else { throw NetworkError.serverError(statusCode: 400, message: r.error ?? "Couldn't remove device") }
    }

    func e2eeConversationDevices(_ conversationId: String) async throws -> E2EEConversationDevices {
        let r: ChatApiResponse<E2EEConversationDevices> = try await get(endpoint: "/conversations/\(conversationId)/e2ee/devices")
        return try e2eeUnwrap(r, "Couldn't load devices")
    }

    func e2eePreKeyBundles(conversationId: String, deviceIds: [String]) async throws -> [E2EEPreKeyBundle] {
        let r: ChatApiResponse<[E2EEPreKeyBundle]> = try await post(
            endpoint: "/e2ee/prekey-bundles",
            body: E2EEPreKeyBundlesBody(conversationId: conversationId, deviceIds: deviceIds))
        return try e2eeUnwrap(r, "Couldn't load keys")
    }

    func e2eeEnable(conversationId: String) async throws -> E2EEConversationState {
        let r: ChatApiResponse<E2EEConversationState> = try await post(
            endpoint: "/conversations/\(conversationId)/e2ee/enable", body: EmptyBody())
        return try e2eeUnwrap(r, "Couldn't turn on encryption")
    }

    func e2eePostMessage(conversationId: String, body: SendMessageRequestBody) async throws -> BackendMessage {
        let r: ChatApiResponse<BackendMessage> = try await post(endpoint: "/conversations/\(conversationId)/messages", body: body)
        return try e2eeUnwrap(r, "Failed to send message")
    }

    func e2eePatchMessage(messageId: String, body: EditMessageRequestBody) async throws -> BackendMessage {
        let r: ChatApiResponse<BackendMessage> = try await patch(endpoint: "/messages/\(messageId)", body: body)
        return try e2eeUnwrap(r, "Failed to edit message")
    }
}
