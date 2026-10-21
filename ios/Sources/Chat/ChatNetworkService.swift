import Foundation

extension NetworkService {

    func patch<T: Decodable, B: Encodable>(endpoint: String, body: B) async throws -> T {
        return try await executeWithRetry { token in
            guard let url = URL(string: baseURL + endpoint) else {
                throw NetworkError.invalidURL
            }

            var request = URLRequest(url: url)
            request.httpMethod = "PATCH"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder.chatCompatible.encode(body)

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.serverError(statusCode: 0, message: "Invalid response")
            }

            if httpResponse.statusCode >= 400 {
                let errorResponse = try? JSONDecoder().decode(ApiErrorResponse.self, from: data)
                if httpResponse.statusCode == 401 && errorResponse?.code == "auth/token-expired" {
                    throw NetworkError.tokenExpired
                }
                throw NetworkError.serverError(
                    statusCode: httpResponse.statusCode,
                    message: errorResponse?.error ?? "Unknown error"
                )
            }

            return try JSONDecoder.chatCompatible.decode(T.self, from: data)
        }
    }

    func listConversations(view: ConversationListView, page: Int = 0, pageSize: Int = 20, excludeLeftGroups: Bool = false, kind: ConversationKindFilter = .all) async throws -> [BackendConversationSummary] {
        let response: ChatApiResponse<[BackendConversationSummary]> = try await get(
            endpoint: "/conversations",
            queryItems: [
                URLQueryItem(name: "view", value: view.rawValue),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "page_size", value: String(pageSize)),
                URLQueryItem(name: "exclude_left_groups", value: String(excludeLeftGroups)),
                URLQueryItem(name: "kind", value: kind.rawValue),
            ]
        )
        guard response.success else {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Failed to list conversations")
        }
        return E2EEService.shared.adopt(response.data ?? [])
    }

    func listConversationsCursor(view: ConversationListView, cursor: String?, pageSize: Int = 20, excludeLeftGroups: Bool = false, kind: ConversationKindFilter = .all) async throws -> ([BackendConversationSummary], String?) {
        return try await executeWithRetry { token in
            var components = URLComponents(string: baseURL + "/conversations")
            components?.queryItems = [
                URLQueryItem(name: "view", value: view.rawValue),
                URLQueryItem(name: "page_size", value: String(pageSize)),
                URLQueryItem(name: "exclude_left_groups", value: String(excludeLeftGroups)),
                URLQueryItem(name: "kind", value: kind.rawValue),
                URLQueryItem(name: "cursor", value: cursor ?? ""),
            ]

            guard let url = components?.url else {
                throw NetworkError.invalidURL
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.serverError(statusCode: 0, message: "Invalid response")
            }

            if httpResponse.statusCode >= 400 {
                let errorResponse = try? JSONDecoder().decode(ApiErrorResponse.self, from: data)
                if httpResponse.statusCode == 401 && errorResponse?.code == "auth/token-expired" {
                    throw NetworkError.tokenExpired
                }
                throw NetworkError.serverError(
                    statusCode: httpResponse.statusCode,
                    message: errorResponse?.error ?? "Unknown error"
                )
            }

            let decoded = try JSONDecoder.chatCompatible.decode(ChatApiResponse<[BackendConversationSummary]>.self, from: data)
            guard decoded.success else {
                throw NetworkError.serverError(statusCode: 400, message: decoded.error ?? "Failed to list conversations")
            }

            let nextCursor = httpResponse.value(forHTTPHeaderField: "X-Next-Cursor")
            return (E2EEService.shared.adopt(decoded.data ?? []), nextCursor)
        }
    }

    func startDirectConversation(otherId: String, otherType: ParticipantType) async throws -> BackendConversation {
        let response: ChatApiResponse<BackendConversation> = try await post(
            endpoint: "/conversations/direct",
            body: StartDirectConversationRequestBody(otherId: otherId, otherType: otherType)
        )
        guard response.success, let conversation = response.data else {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Failed to start conversation")
        }
        return conversation
    }

    func hideConversation(_ conversationId: String) async throws {
        let _: ChatApiResponse<String> = try await delete(endpoint: "/conversations/\(conversationId)")
    }

    func acceptConversationRequest(_ conversationId: String) async throws {
        let _: ChatApiResponse<String> = try await post(endpoint: "/conversations/\(conversationId)/accept", body: EmptyBody())
    }

    func declineConversationRequest(_ conversationId: String) async throws {
        let _: ChatApiResponse<String> = try await post(endpoint: "/conversations/\(conversationId)/decline", body: EmptyBody())
    }

    @discardableResult
    func updateConversationSettings(_ conversationId: String, body: UpdateConversationSettingsRequestBody) async throws -> BackendConversationSummary? {
        struct Ignored: Decodable {}
        let _: ChatApiResponse<Ignored> = try await patch(endpoint: "/conversations/\(conversationId)/settings", body: body)
        return nil
    }

    func chatBlock(_ conversationId: String) async throws {
        let _: ChatApiResponse<String> = try await post(endpoint: "/conversations/\(conversationId)/block", body: EmptyBody())
    }

    func chatUnblock(_ conversationId: String) async throws {
        let _: ChatApiResponse<String> = try await post(endpoint: "/conversations/\(conversationId)/unblock", body: EmptyBody())
    }

    func getMessages(conversationId: String, before: String? = nil, limit: Int = 50) async throws -> [BackendMessage] {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: before)) }

        let response: ChatApiResponse<[BackendMessage]> = try await get(
            endpoint: "/conversations/\(conversationId)/messages",
            queryItems: query
        )
        guard response.success else {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Failed to fetch messages")
        }
        return await E2EEService.shared.decryptAsync(response.data ?? [])
    }

    func sendMessage(conversationId: String, body: SendMessageRequestBody) async throws -> BackendMessage {
        if let sent = try await E2EEService.shared.sendEncryptedIfPossible(
            conversationId: conversationId, body: body,
            transport: { wire in try await NetworkService.shared.e2eePostMessage(conversationId: conversationId, body: wire) }
        ) {
            return sent
        }
        do {
            return try await postPlainMessage(conversationId: conversationId, body: body)
        } catch NetworkError.serverError(let status, _) where status == 428 && E2EEService.isEncryptable(body) {
            E2EEService.shared.markEnabled(conversationId)
            if let sent = try await E2EEService.shared.sendEncryptedIfPossible(
                conversationId: conversationId, body: body,
                transport: { wire in try await NetworkService.shared.e2eePostMessage(conversationId: conversationId, body: wire) }
            ) { return sent }
            throw NetworkError.serverError(statusCode: 428, message: "This conversation is end-to-end encrypted")
        }
    }

    func postPlainMessage(conversationId: String, body: SendMessageRequestBody) async throws -> BackendMessage {
        let response: ChatApiResponse<BackendMessage> = try await post(
            endpoint: "/conversations/\(conversationId)/messages",
            body: body
        )
        guard response.success, let message = response.data else {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Failed to send message")
        }
        return message
    }

    func deleteMessage(_ messageId: String) async throws -> BackendMessage {
        let response: ChatApiResponse<BackendMessage> = try await delete(endpoint: "/messages/\(messageId)")
        guard response.success, let message = response.data else {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Failed to delete message")
        }
        return message
    }

    func editMessage(_ messageId: String, text: String) async throws -> BackendMessage {
        if let encrypted = try await E2EEService.shared.edit(messageId: messageId, text: text) {
            return encrypted
        }
        let response: ChatApiResponse<BackendMessage> = try await patch(
            endpoint: "/messages/\(messageId)", body: EditMessageRequestBody(text: text))
        guard response.success, let message = response.data else {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Failed to edit message")
        }
        return message
    }

    func markRead(conversationId: String, upToMessageId: String, opensBit: Bool = false) async throws {
        let _: ChatApiResponse<String> = try await post(
            endpoint: "/conversations/\(conversationId)/read",
            body: MarkReadRequestBody(upToMessageId: upToMessageId, opensBit: opensBit)
        )
    }

    func getMessageReceipts(_ messageId: String) async throws -> [MessageReceiptDetail] {
        let response: ChatApiResponse<[MessageReceiptDetail]> = try await get(
            endpoint: "/messages/\(messageId)/receipts",
            queryItems: []
        )
        guard response.success else {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Failed to fetch message receipts")
        }
        return response.data ?? []
    }

    func createCall(conversationId: String, callType: CallType) async throws -> CallCreated {
        let response: ChatApiResponse<CallCreated> = try await post(
            endpoint: "/conversations/\(conversationId)/calls",
            body: CreateCallRequestBody(callType: callType)
        )
        guard response.success, let created = response.data else {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Failed to start call")
        }
        return created
    }

    func updateCallStatus(callId: String, status: CallStatus) async throws {
        let _: ChatApiResponse<BackendCall> = try await patch(
            endpoint: "/calls/\(callId)",
            body: UpdateCallStatusRequestBody(status: status)
        )
    }

    func sendCallHeartbeat(callId: String) async throws {
        let _: ChatApiResponse<String> = try await post(
            endpoint: "/calls/\(callId)/heartbeat",
            body: EmptyBody()
        )
    }

        func createGroup(
            name: String,
            participantIds: [String],
            imageUrl: String? = nil,
            inviteLinkEnabled: Bool? = nil,
            inviteToken: String? = nil
        ) async throws -> BackendConversation {
            let response: ChatApiResponse<BackendConversation> = try await post(
                endpoint: "/conversations/group",
                body: CreateGroupRequestBody(
                    name: name,
                    participantIds: participantIds,
                    imageUrl: imageUrl,
                    inviteLinkEnabled: inviteLinkEnabled,
                    inviteToken: inviteToken
                )
            )
            guard response.success, let conversation = response.data else {
                throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Failed to create group")
            }
            return conversation
        }
     
        func getGroupDetails(_ conversationId: String) async throws -> GroupDetails {
            let response: ChatApiResponse<GroupDetails> = try await get(
                endpoint: "/conversations/\(conversationId)/group",
                queryItems: []
            )
            guard response.success, let details = response.data else {
                throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Failed to fetch group")
            }
            return details
        }
     
        @discardableResult
        func updateGroup(_ conversationId: String, name: String? = nil, imageUrl: String? = nil) async throws -> BackendConversation {
            let response: ChatApiResponse<BackendConversation> = try await patch(
                endpoint: "/conversations/\(conversationId)/group",
                body: UpdateGroupRequestBody(name: name, imageUrl: imageUrl)
            )
            guard response.success, let conversation = response.data else {
                throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Failed to update group")
            }
            return conversation
        }
     
        func addGroupMembers(_ conversationId: String, participantIds: [String]) async throws {
            let _: ChatApiResponse<String> = try await post(
                endpoint: "/conversations/\(conversationId)/group/members",
                body: AddGroupMembersRequestBody(participantIds: participantIds)
            )
        }
     
        func removeGroupMember(_ conversationId: String, userId: String) async throws {
            let _: ChatApiResponse<String> = try await delete(
                endpoint: "/conversations/\(conversationId)/group/members/\(userId)"
            )
        }
     
        func leaveGroup(_ conversationId: String) async throws {
            let _: ChatApiResponse<String> = try await post(
                endpoint: "/conversations/\(conversationId)/group/leave",
                body: EmptyBody()
            )
        }
     
        func promoteGroupCreator(_ conversationId: String, userId: String) async throws {
            let _: ChatApiResponse<String> = try await post(
                endpoint: "/conversations/\(conversationId)/group/creators",
                body: PromoteGroupCreatorRequestBody(userId: userId)
            )
        }
     
        func deleteGroup(_ conversationId: String) async throws {
            let _: ChatApiResponse<String> = try await delete(
                endpoint: "/conversations/\(conversationId)/group"
            )
        }
}

extension NetworkService {
    func getGroupSuggestions() async throws -> GroupSuggestionsResponse {
        let response: ChatApiResponse<GroupSuggestionsResponse> = try await get(
            endpoint: "/conversations/group/suggestions",
            queryItems: []
        )
        guard response.success, let suggestions = response.data else {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Failed to load suggestions")
        }
        return suggestions
    }

    func setGroupInviteLink(_ conversationId: String, enabled: Bool) async throws -> GroupInviteLink {
        let response: ChatApiResponse<GroupInviteLink> = try await patch(
            endpoint: "/conversations/\(conversationId)/group/invite-link",
            body: SetInviteLinkRequestBody(enabled: enabled)
        )
        guard response.success, let link = response.data else {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Failed to update invite link")
        }
        return link
    }

    func getGroupInvitePreview(token: String) async throws -> GroupInvitePreview {
        let response: ChatApiResponse<GroupInvitePreview> = try await get(
            endpoint: "/conversations/group/invite/\(token)",
            queryItems: []
        )
        guard response.success, let preview = response.data else {
            throw NetworkError.serverError(statusCode: 404, message: response.error ?? "This invite link isn't valid anymore")
        }
        return preview
    }

    func joinGroup(token: String) async throws -> BackendConversation {
        let response: ChatApiResponse<BackendConversation> = try await post(
            endpoint: "/conversations/group/join",
            body: JoinGroupViaLinkRequestBody(token: token)
        )
        guard response.success, let conversation = response.data else {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Couldn't join the group")
        }
        return conversation
    }
}
