import Foundation
import Firebase
import FirebaseAuth

extension JSONEncoder {
    static let chatCompatible: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let chatCompatible: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = FastISO8601.parse(string) ?? parseFlexibleISO8601(string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected ISO8601 date string, got \(string)"
                )
            }
            return date
        }
        return decoder
    }()
}

enum NetworkError: Error {
    case invalidURL
    case noData
    case decodingError
    case serverError(statusCode: Int, message: String)
    case serverErrorWithCode(statusCode: Int, message: String, code: String?)
    case authError(code: String)
    case tokenExpired
    case unknownError(Error)
}

class NetworkService {
    static let shared = NetworkService()
   
    let baseURL = AppConfig.apiBaseURL
    
    private var cachedToken: String?
    private var tokenExpirationDate: Date?
    
    private let tokenBufferTime: TimeInterval = 300
    
     let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
    
    private init() {}
    
    private func getAuthToken() async throws -> String {
        guard let user = Auth.auth().currentUser else {
            throw NetworkError.authError(code: "auth/user-not-found")
        }
        
        if let cachedToken = cachedToken,
           let expirationDate = tokenExpirationDate,
           expirationDate.timeIntervalSinceNow > tokenBufferTime {
            return cachedToken
        }
        
        do {
            let token = try await user.getIDToken()
            
            cachedToken = token
            
            if let jwt = decodeJWT(token) {
                if let exp = jwt["exp"] as? TimeInterval {
                    tokenExpirationDate = Date(timeIntervalSince1970: exp)
                }
            }
            
            return token
        } catch {
            netLog("DEBUG: Failed to get auth token: \(error.localizedDescription)")
            throw NetworkError.authError(code: "auth/token-refresh-failed")
        }
    }
    func delete<T: Decodable>(endpoint: String) async throws -> T {
            return try await executeWithRetry { token in
                guard let url = URL(string: baseURL + endpoint) else {
                    throw NetworkError.invalidURL
                }
                
                var request = URLRequest(url: url)
                request.httpMethod = "DELETE"
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                
                let (data, response) = try await session.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NetworkError.serverError(statusCode: 0, message: "Invalid response")
                }
                
                if httpResponse.statusCode >= 400 {
                    let errorResponse = try? JSONDecoder().decode(ApiErrorResponse.self, from: data)
                    throw NetworkError.serverError(
                        statusCode: httpResponse.statusCode,
                        message: errorResponse?.error ?? "Unknown error"
                    )
                }
                
                let decoder = JSONDecoder.chatCompatible
                return try decoder.decode(T.self, from: data)
            }
        }
    private func decodeJWT(_ token: String) -> [String: Any]? {
        let segments = token.components(separatedBy: ".")
        guard segments.count > 1 else { return nil }
        
        let base64String = segments[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        
        let paddedLength = base64String.count + (4 - (base64String.count % 4)) % 4
        let padded = base64String.padding(toLength: paddedLength, withPad: "=", startingAt: 0)
        
        guard let data = Data(base64Encoded: padded) else { return nil }
        
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }
    
     func executeWithRetry<T>(retries: Int = 1, task: (String) async throws -> T) async throws -> T {
        do {
            let token = try await getAuthToken()
            return try await task(token)
        } catch let NetworkError.tokenExpired {
            if retries > 0 {
                cachedToken = nil
                tokenExpirationDate = nil
                return try await executeWithRetry(retries: retries - 1, task: task)
            } else {
                throw NetworkError.tokenExpired
            }
        } catch let NetworkError.authError(code) where code == "auth/id-token-expired" {
            if retries > 0 {
                cachedToken = nil
                tokenExpirationDate = nil
                return try await executeWithRetry(retries: retries - 1, task: task)
            } else {
                throw NetworkError.tokenExpired
            }
        } catch {
            throw error
        }
    }
    
    func get<T: Decodable>(endpoint: String, queryItems: [URLQueryItem]? = nil) async throws -> T {
        let cache = OfflineCache.shared

        if !NetworkMonitor.shared.isConnectedNow,
           let cached = cache.cachedResponse(endpoint: endpoint, queryItems: queryItems),
           let decoded = try? JSONDecoder.chatCompatible.decode(T.self, from: cached) {
            netLog("DEBUG: Offline -- serving cached \(endpoint)")
            return decoded
        }

        do {
            return try await getLive(endpoint: endpoint, queryItems: queryItems)
        } catch {
            let offlineFailure = NetworkMonitor.isOfflineError(error)
                || (!NetworkMonitor.shared.isConnectedNow && {
                    if case NetworkError.authError = error { return true }
                    return false
                }())
            if offlineFailure,
               let cached = cache.cachedResponse(endpoint: endpoint, queryItems: queryItems),
               let decoded = try? JSONDecoder.chatCompatible.decode(T.self, from: cached) {
                netLog("DEBUG: Request failed offline -- serving cached \(endpoint)")
                return decoded
            }
            throw error
        }
    }
    
    private func getLive<T: Decodable>(endpoint: String, queryItems: [URLQueryItem]? = nil) async throws -> T {
        return try await executeWithRetry { token in
            var urlComponents = URLComponents(string: baseURL + endpoint)
            urlComponents?.queryItems = queryItems
            
            guard let url = urlComponents?.url else {
                throw NetworkError.invalidURL
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            
            netLog("DEBUG: Making GET request to \(url.absoluteString)")
            
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.serverError(statusCode: 0, message: "Invalid response")
            }
            
            netLog("DEBUG: Received response with status code: \(httpResponse.statusCode)")
            
            if httpResponse.statusCode >= 400 {
#if DEBUG
                if let responseString = String(data: data, encoding: .utf8) {
                    netLog("DEBUG: Error response body: \(responseString)")
                }
#endif
                
                do {
                    let errorResponse = try JSONDecoder().decode(ApiErrorResponse.self, from: data)
                    
                    if httpResponse.statusCode == 401 && errorResponse.code == "auth/token-expired" {
                        throw NetworkError.tokenExpired
                    }
                    
                    throw NetworkError.serverError(
                        statusCode: httpResponse.statusCode,
                        message: errorResponse.error ?? "Unknown error"
                    )
                } catch NetworkError.tokenExpired {
                    throw NetworkError.tokenExpired
                } catch let error as NetworkError {
                    throw error
                } catch {
                    netLog("DEBUG: Error decoding error response: \(error)")
                    throw NetworkError.serverError(
                        statusCode: httpResponse.statusCode,
                        message: "Server error (could not parse error details)"
                    )
                }
            }
            
            do {
#if DEBUG
                if let responseString = String(data: data, encoding: .utf8) {
                    let preview = responseString.count > 2000
                        ? String(responseString.prefix(2000)) + "… (\(responseString.count) chars total)"
                        : responseString
                    netLog("DEBUG: Response body for \(url.absoluteString): \(preview)")
                }
#endif

                let decoder = JSONDecoder.chatCompatible
                let decoded = try decoder.decode(T.self, from: data)
                OfflineCache.shared.storeResponse(data, endpoint: endpoint, queryItems: queryItems)
                return decoded
            } catch {
                netLog("DEBUG: Decoding error: \(error)")
                
#if DEBUG
                if let responseString = String(data: data, encoding: .utf8) {
                    netLog("DEBUG: Response body: \(responseString)")
                }
#endif
                
                throw NetworkError.decodingError
            }
        }
    }
    
    func getWithNextCursor<T: Decodable>(endpoint: String, queryItems: [URLQueryItem]? = nil) async throws -> (T, String?) {
        return try await executeWithRetry { token in
            var urlComponents = URLComponents(string: baseURL + endpoint)
            urlComponents?.queryItems = queryItems

            guard let url = urlComponents?.url else {
                throw NetworkError.invalidURL
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            netLog("DEBUG: Making GET request to \(url.absoluteString)")

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.serverError(statusCode: 0, message: "Invalid response")
            }

            netLog("DEBUG: Received response with status code: \(httpResponse.statusCode)")

            if httpResponse.statusCode >= 400 {
#if DEBUG
                if let responseString = String(data: data, encoding: .utf8) {
                    netLog("DEBUG: Error response body: \(responseString)")
                }
#endif
                do {
                    let errorResponse = try JSONDecoder().decode(ApiErrorResponse.self, from: data)
                    if httpResponse.statusCode == 401 && errorResponse.code == "auth/token-expired" {
                        throw NetworkError.tokenExpired
                    }
                    throw NetworkError.serverError(
                        statusCode: httpResponse.statusCode,
                        message: errorResponse.error ?? "Unknown error"
                    )
                } catch NetworkError.tokenExpired {
                    throw NetworkError.tokenExpired
                } catch let error as NetworkError {
                    throw error
                } catch {
                    netLog("DEBUG: Error decoding error response: \(error)")
                    throw NetworkError.serverError(
                        statusCode: httpResponse.statusCode,
                        message: "Server error (could not parse error details)"
                    )
                }
            }

            do {
                let decoder = JSONDecoder.chatCompatible
                let decoded = try decoder.decode(T.self, from: data)
                let nextCursor = httpResponse.value(forHTTPHeaderField: "X-Next-Cursor")
                return (decoded, nextCursor)
            } catch {
                netLog("DEBUG: Decoding error: \(error)")
#if DEBUG
                if let responseString = String(data: data, encoding: .utf8) {
                    netLog("DEBUG: Response body: \(responseString)")
                }
#endif
                throw NetworkError.decodingError
            }
        }
    }

    func listConversationsCursor(
        view: ConversationListView,
        cursor: String?,
        pageSize: Int = 20
    ) async throws -> (conversations: [BackendConversationSummary], nextCursor: String?) {
        let viewValue: String
        switch view {
        case .messages: viewValue = "messages"
        case .invitations: viewValue = "invitations"
        case .archives: viewValue = "archives"
        }
        let queryItems = [
            URLQueryItem(name: "view", value: viewValue),
            URLQueryItem(name: "page_size", value: String(pageSize)),
            URLQueryItem(name: "cursor", value: cursor ?? ""),
        ]
        let (response, nextCursor): (SimpleApiResponse<[BackendConversationSummary]>, String?) = try await getWithNextCursor(
            endpoint: "/conversations",
            queryItems: queryItems
        )
        return (response.data ?? [], nextCursor)
    }

    func postPublic<T: Decodable, B: Encodable>(endpoint: String, body: B) async throws -> T {
        guard let url = URL(string: baseURL + endpoint) else {
            throw NetworkError.invalidURL
        }

        let encoder = JSONEncoder.chatCompatible
        let jsonData = try encoder.encode(body)

#if DEBUG
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            netLog("DEBUG: POST (public) Request to \(url.absoluteString)")
            netLog("DEBUG: Request body: \(jsonString)")
        }
#endif

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = jsonData

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.serverError(statusCode: 0, message: "Invalid response")
        }

        netLog("DEBUG: Received response with status code: \(httpResponse.statusCode)")

        if httpResponse.statusCode >= 400 {
#if DEBUG
            if let responseString = String(data: data, encoding: .utf8) {
                netLog("DEBUG: Error response body: \(responseString)")
            }
#endif
            let errorResponse = try? JSONDecoder().decode(ApiErrorResponse.self, from: data)
            throw NetworkError.serverErrorWithCode(
                statusCode: httpResponse.statusCode,
                message: errorResponse?.error ?? "Unknown error",
                code: errorResponse?.code
            )
        }

        do {
            let decoder = JSONDecoder.chatCompatible
            return try decoder.decode(T.self, from: data)
        } catch {
            netLog("DEBUG: Decoding error: \(error)")
#if DEBUG
            if let responseString = String(data: data, encoding: .utf8) {
                netLog("DEBUG: Response that couldn't be decoded: \(responseString)")
            }
#endif
            throw NetworkError.decodingError
        }
    }

    func getPublic<T: Decodable>(endpoint: String, queryItems: [URLQueryItem]? = nil) async throws -> T {
        var urlComponents = URLComponents(string: baseURL + endpoint)
        urlComponents?.queryItems = queryItems

        guard let url = urlComponents?.url else {
            throw NetworkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        netLog("DEBUG: GET (public) request to \(url.absoluteString)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.serverError(statusCode: 0, message: "Invalid response")
        }

        netLog("DEBUG: Received response with status code: \(httpResponse.statusCode)")

        if httpResponse.statusCode >= 400 {
#if DEBUG
            if let responseString = String(data: data, encoding: .utf8) {
                netLog("DEBUG: Error response body: \(responseString)")
            }
#endif
            let errorResponse = try? JSONDecoder().decode(ApiErrorResponse.self, from: data)
            throw NetworkError.serverErrorWithCode(
                statusCode: httpResponse.statusCode,
                message: errorResponse?.error ?? "Unknown error",
                code: errorResponse?.code
            )
        }

        do {
            let decoder = JSONDecoder.chatCompatible
            return try decoder.decode(T.self, from: data)
        } catch {
            netLog("DEBUG: Decoding error: \(error)")
#if DEBUG
            if let responseString = String(data: data, encoding: .utf8) {
                netLog("DEBUG: Response that couldn't be decoded: \(responseString)")
            }
#endif
            throw NetworkError.decodingError
        }
    }

    private struct AvailabilityResponse: Decodable {
        let available: Bool
    }

    func checkEmailAvailable(email: String) async throws -> Bool {
        let response: SimpleApiResponse<AvailabilityResponse> = try await getPublic(
            endpoint: "/users/email-available",
            queryItems: [URLQueryItem(name: "email", value: email)]
        )
        guard response.success, let available = response.data?.available else {
            throw NetworkError.serverErrorWithCode(
                statusCode: 400,
                message: response.error ?? "Failed to check email availability",
                code: response.code
            )
        }
        return available
    }

    func checkUsernameAvailable(username: String) async throws -> Bool {
        let response: SimpleApiResponse<AvailabilityResponse> = try await getPublic(
            endpoint: "/users/username-available",
            queryItems: [URLQueryItem(name: "username", value: username)]
        )
        guard response.success, let available = response.data?.available else {
            throw NetworkError.serverErrorWithCode(
                statusCode: 400,
                message: response.error ?? "Failed to check username availability",
                code: response.code
            )
        }
        return available
    }

    private struct ForgotPasswordRequest: Encodable {
        let email: String
    }

    private struct ResetPasswordRequestBody: Encodable {
        let email: String
        let code: String
        let newPassword: String

        enum CodingKeys: String, CodingKey {
            case email, code
            case newPassword = "new_password"
        }
    }

    private struct SimpleStringApiResponse: Decodable {
        let success: Bool
        let data: String?
        let error: String?
        let code: String?
    }

    func sendPasswordResetCode(email: String) async throws {
        let response: SimpleStringApiResponse = try await postPublic(
            endpoint: "/users/forgot-password",
            body: ForgotPasswordRequest(email: email)
        )
        guard response.success else {
            throw NetworkError.serverErrorWithCode(
                statusCode: 400,
                message: response.error ?? "Failed to send code",
                code: response.code
            )
        }
    }

    func resetPassword(email: String, code: String, newPassword: String) async throws {
        let response: SimpleStringApiResponse = try await postPublic(
            endpoint: "/users/reset-password",
            body: ResetPasswordRequestBody(email: email, code: code, newPassword: newPassword)
        )
        guard response.success else {
            throw NetworkError.serverErrorWithCode(
                statusCode: 400,
                message: response.error ?? "Failed to reset password",
                code: response.code
            )
        }
    }

    func clearTokenCache() {
        cachedToken = nil
        tokenExpirationDate = nil
        netLog("DEBUG: Network service token cache cleared")
    }
    struct ConflictResponse: Decodable {
        let data: ConflictData?
        struct ConflictData: Decodable {
            let id: String
            let firebase_uid: String
        }
    }
    func post<T: Decodable, B: Encodable>(endpoint: String, body: B) async throws -> T {
        return try await executeWithRetry { token in
            guard let url = URL(string: baseURL + endpoint) else {
                throw NetworkError.invalidURL
            }
            
            let encoder = JSONEncoder.chatCompatible
            let jsonData = try encoder.encode(body)
            
#if DEBUG
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                netLog("DEBUG: POST Request to \(url.absoluteString)")
                netLog("DEBUG: Request body: \(jsonString)")
            }
#endif
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = jsonData
            
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.serverError(statusCode: 0, message: "Invalid response")
            }
            
            netLog("DEBUG: Received response with status code: \(httpResponse.statusCode)")
            
#if DEBUG
            if let responseString = String(data: data, encoding: .utf8) {
                netLog("DEBUG: Response body: \(responseString)")
            }
#endif
            
            if httpResponse.statusCode >= 400 {
                do {
                    let errorResponse = try JSONDecoder().decode(ApiErrorResponse.self, from: data)
                    
                    if httpResponse.statusCode == 401 && errorResponse.code == "auth/token-expired" {
                        throw NetworkError.tokenExpired
                    }
                    
                    if httpResponse.statusCode == 409 && errorResponse.code == "user/already-exists" {
                        netLog("DEBUG: User already exists in backend - this is expected")
                        
                        if endpoint == "/users/register",
                           let bodyDict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                           let firebase_uid = bodyDict["firebase_uid"] as? String,
                           let username = bodyDict["username"] as? String {
                            
                            let conflictResponse = try? JSONDecoder().decode(ConflictResponse.self, from: data)
                            let realId = conflictResponse?.data?.id ?? firebase_uid
                            
                            let dummyResponse: [String: Any] = [
                                "success": true,
                                "data": [
                                    "id": realId,
                                    "firebase_uid": firebase_uid,
                                    "username": username
                                ],
                                "error": NSNull(),
                                "code": NSNull()
                            ]
                            
                            let dummyData = try JSONSerialization.data(withJSONObject: dummyResponse)
                            return try JSONDecoder().decode(T.self, from: dummyData)
                        }
                    }
                    
                    throw NetworkError.serverErrorWithCode(
                        statusCode: httpResponse.statusCode,
                        message: errorResponse.error ?? "Unknown error",
                        code: errorResponse.code
                    )
                } catch let error as DecodingError {
                    netLog("DEBUG: Error decoding error response: \(error)")
                    throw NetworkError.serverError(
                        statusCode: httpResponse.statusCode,
                        message: "Server error (could not parse error details)"
                    )
                } catch NetworkError.tokenExpired {
                    throw NetworkError.tokenExpired
                } catch let error as NetworkError {
                    throw error
                } catch {
                    netLog("DEBUG: Unexpected error: \(error)")
                    throw NetworkError.serverError(
                        statusCode: httpResponse.statusCode,
                        message: "Server error"
                    )
                }
            }
            
            do {
                let decoder = JSONDecoder.chatCompatible
                return try decoder.decode(T.self, from: data)
            } catch let decodingError {
                netLog("DEBUG: Decoding error: \(decodingError)")
                
#if DEBUG
                if let responseString = String(data: data, encoding: .utf8) {
                    netLog("DEBUG: Response that couldn't be decoded: \(responseString)")
                }
#endif
                
                throw NetworkError.decodingError
            }
        }
    }
    
    func put<T: Decodable, B: Encodable>(endpoint: String, body: B) async throws -> T {
        return try await executeWithRetry { token in
            guard let url = URL(string: baseURL + endpoint) else {
                throw NetworkError.invalidURL
            }
            
            let encoder = JSONEncoder.chatCompatible
            let jsonData = try encoder.encode(body)
            
#if DEBUG
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                netLog("DEBUG: PUT Request to \(url.absoluteString)")
                netLog("DEBUG: Request body: \(jsonString)")
            }
#endif
            
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = jsonData
            
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.serverError(statusCode: 0, message: "Invalid response")
            }
            
            netLog("DEBUG: Received response with status code: \(httpResponse.statusCode)")
            
#if DEBUG
            if let responseString = String(data: data, encoding: .utf8) {
                netLog("DEBUG: Response body: \(responseString)")
            }
#endif
            
            if httpResponse.statusCode >= 400 {
                do {
                    let errorResponse = try JSONDecoder().decode(ApiErrorResponse.self, from: data)
                    
                    if httpResponse.statusCode == 401 && errorResponse.code == "auth/token-expired" {
                        throw NetworkError.tokenExpired
                    }
                    
                    throw NetworkError.serverErrorWithCode(
                        statusCode: httpResponse.statusCode,
                        message: errorResponse.error ?? "Unknown error",
                        code: errorResponse.code
                    )
                } catch NetworkError.tokenExpired {
                    throw NetworkError.tokenExpired
                } catch let error as NetworkError {
                    throw error
                } catch {
                    netLog("DEBUG: Error decoding error response: \(error)")
                    throw NetworkError.serverError(
                        statusCode: httpResponse.statusCode,
                        message: "Server error (could not parse error details)"
                    )
                }
            }
            
            do {
                let decoder = JSONDecoder.chatCompatible
                return try decoder.decode(T.self, from: data)
            } catch {
                netLog("DEBUG: Decoding error: \(error)")
                
#if DEBUG
                if let responseString = String(data: data, encoding: .utf8) {
                    netLog("DEBUG: Response that couldn't be decoded: \(responseString)")
                }
#endif
                
                throw NetworkError.decodingError
            }
        }
    }
    
    @discardableResult
    func updateUsername(_ username: String) async throws -> BackendUserProfile {
        struct UpdateUsernameRequest: Encodable {
            let username: String
        }
        
        let response: ProfileApiResponse = try await put(
            endpoint: "/users/me/username",
            body: UpdateUsernameRequest(username: username)
        )
        
        guard response.success, let profile = response.data else {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Failed to update username")
        }
        
        return profile
    }
    
    @discardableResult
    func updateProfile<B: Encodable>(_ body: B) async throws -> BackendUserProfile {
        let response: ProfileApiResponse = try await put(endpoint: "/users/me", body: body)
        
        guard response.success, let profile = response.data else {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Failed to update profile")
        }
        
        return profile
    }
    
    func fetchCurrentUserProfile() async throws -> BackendUserProfile {
        let response: ProfileApiResponse = try await get(endpoint: "/users/me")
        
        guard response.success, let profile = response.data else {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Failed to fetch profile")
        }
        
        return profile
    }
    
    func updateLocation(latitude: Double, longitude: Double) async throws {
        struct LocationRequest: Encodable {
            let lat: Double
            let lng: Double
        }
        
        struct ApiResponse: Decodable {
            let success: Bool
            let data: String?
            let error: String?
            let code: String?
        }
        
        let request = LocationRequest(lat: latitude, lng: longitude)
        let response: ApiResponse = try await put(endpoint: "/users/location", body: request)
        
        if !response.success {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Unknown error")
        }
    }
    
    func getNearbyUsers(latitude: Double, longitude: Double, radius: Double? = nil) async throws -> [BackendUser] {
        struct ApiResponse: Decodable {
            let success: Bool
            let data: [BackendUser]?
            let error: String?
            let code: String?
        }
        
        var queryItems = [
            URLQueryItem(name: "lat", value: String(latitude)),
            URLQueryItem(name: "lng", value: String(longitude))
        ]
        
        if let radius = radius {
            queryItems.append(URLQueryItem(name: "radius", value: String(radius)))
        }
        
        let response: ApiResponse = try await get(endpoint: "/users/nearby", queryItems: queryItems)
        
        if !response.success {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Unknown error")
        }
        
        return response.data ?? []
    }
    
    func getChatSettings() async throws -> ChatSettings {
        let response: SimpleApiResponse<ChatSettings> = try await get(endpoint: "/users/me/chat-settings")
        guard response.success, let settings = response.data else {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Failed to fetch chat settings")
        }
        return settings
    }
 
    @discardableResult
    func updateChatSettings(_ body: UpdateChatSettingsRequestBody) async throws -> ChatSettings {
        netLog("DEBUG: Settings body \(body)")
        let response: SimpleApiResponse<ChatSettings> = try await patch(endpoint: "/users/me/chat-settings", body: body)
        
        guard response.success, let settings = response.data else {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Failed to update chat settings")
        }
        return settings
    }
 
    func getPresence(conversationId: String) async throws -> PresenceInfo {
        let response: SimpleApiResponse<PresenceInfo> = try await get(endpoint: "/conversations/\(conversationId)/presence")
        guard response.success, let presence = response.data else {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Failed to fetch presence")
        }
        return presence
    }
 
    func deleteConversationHistory(_ conversationId: String) async throws {
        let response: SimpleApiResponse<String> = try await delete(endpoint: "/conversations/\(conversationId)/history")
        guard response.success else {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Failed to delete chat history")
        }
    }
 
    func searchChatUsers(query: String, page: Int = 0) async throws -> [ChatUserSearchResult] {
        let response: SimpleApiResponse<[ChatUserSearchResult]> = try await get(
            endpoint: "/search/chat-users",
            queryItems: [URLQueryItem(name: "q", value: query), URLQueryItem(name: "page", value: "\(page)")]
        )
        guard response.success else {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Search failed")
        }
        return response.data ?? []
    }
    
    func getConversationDetails(_ conversationId: String) async throws -> BackendConversationSummary {
        let response: SimpleApiResponse<BackendConversationSummary> = try await get(
            endpoint: "/conversations/\(conversationId)"
        )
        guard response.success, let summary = response.data else {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Failed to load conversation")
        }
        return E2EEService.shared.adopt([summary]).first ?? summary
    }

    func getReadReceipts(_ conversationId: String) async throws -> [ParticipantReadReceipt] {
        let response: ReadReceiptsApiResponse = try await get(
            endpoint: "/conversations/\(conversationId)/read-receipts"
        )
        return response.data ?? []
    }
    private struct SendVerificationCodeRequest: Encodable {
        let email: String
        let purpose: String
        let userName: String
    }
 
    private struct VerifyCodeRequest: Encodable {
        let email: String
        let code: String
        let purpose: String
    }
 
    private struct VerificationApiResponse: Decodable {
        let success: Bool
        let data: VerificationData?
        let error: String?
        let code: String?
    }
 
    private struct VerificationData: Decodable {
        let success: Bool
    }
 
    func sendVerificationCode(email: String, purpose: String, userName: String) async throws -> Bool {
        let body = SendVerificationCodeRequest(email: email, purpose: purpose, userName: userName)
        let response: VerificationApiResponse = try await post(endpoint: "/zones/send-verification-code", body: body)
 
        guard response.success else {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Failed to send verification code")
        }
        return response.data?.success ?? false
    }
 
    func verifyCode(email: String, code: String, purpose: String) async throws -> Bool {
        let body = VerifyCodeRequest(email: email, code: code, purpose: purpose)
        let response: VerificationApiResponse = try await post(endpoint: "/zones/verify-code", body: body)
 
        guard response.success else {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Failed to verify code")
        }
        return response.data?.success ?? false
    }
    
}
private struct ReadReceiptsApiResponse: Decodable {
    let success: Bool
    let data: [ParticipantReadReceipt]?
    let error: String?
    let code: String?
}
 
private struct SimpleApiResponse<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let error: String?
    let code: String?
}
struct ApiErrorResponse: Decodable {
    let success: Bool
    let error: String?
    let code: String?
}

struct ProfileApiResponse: Decodable {
    let success: Bool
    let data: BackendUserProfile?
    let error: String?
    let code: String?
}

struct BackendUser: Identifiable, Codable {
    let id: UUID
    let username: String
    let firebase_uid: String
    let distance_meters: Double?
    
    var distanceText: String {
        guard let distance = distance_meters else { return "Unknown distance" }
        
        if distance < 1000 {
            return "\(Int(distance))m away"
        } else {
            let kilometers = distance / 1000
            return String(format: "%.1f km away", kilometers)
        }
    }
}

struct SearchUserResult: Decodable, Identifiable, Hashable {
    let id: String
    let username: String
    let fullname: String?
    let profileImageUrl: String?
    let bio: String?
    let zoneId: String?
    let isVerified: Bool?
    let distanceMeters: Double?

    enum CodingKeys: String, CodingKey {
        case id, username, fullname, bio
        case profileImageUrl = "profile_image_url"
        case zoneId = "zone_id"
        case isVerified = "is_verified"
        case distanceMeters = "distance_meters"
    }
}

struct SearchInterestResult: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String?
    let imageUrl: String?
    let modelYear: Int?
    let tagsCount: Int
    let followersCount: Int
    let publicId: String?

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case imageUrl = "image_url"
        case modelYear = "model_year"
        case tagsCount = "tags_count"
        case followersCount = "followers_count"
        case publicId = "public_id"
    }
}

struct SearchServiceResult: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let serviceType: String?
    let profileImageUrl: String?
    let username: String?
    let address: String?
    let isServiceLive: Bool?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case id, name, username, address, status
        case serviceType = "service_type"
        case profileImageUrl = "profile_image_url"
        case isServiceLive = "is_service_live"
    }
}

extension NetworkService {

    func searchInFollowers(userId: String, query: String, page: Int = 0) async throws -> [SearchUserResult] {
        let response: SimpleApiResponse<[SearchUserResult]> = try await get(
            endpoint: "/search/followers/\(userId)",
            queryItems: [URLQueryItem(name: "q", value: query), URLQueryItem(name: "page", value: "\(page)")]
        )
        guard response.success else {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Search failed")
        }
        return response.data ?? []
    }

    func searchInFollowing(userId: String, query: String, page: Int = 0) async throws -> [SearchUserResult] {
        let response: SimpleApiResponse<[SearchUserResult]> = try await get(
            endpoint: "/search/following/\(userId)",
            queryItems: [URLQueryItem(name: "q", value: query), URLQueryItem(name: "page", value: "\(page)")]
        )
        guard response.success else {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Search failed")
        }
        return response.data ?? []
    }

    func searchInPostLikes(postId: String, query: String, page: Int = 0) async throws -> [SearchUserResult] {
        let response: SimpleApiResponse<[SearchUserResult]> = try await get(
            endpoint: "/search/post-likes/\(postId)",
            queryItems: [URLQueryItem(name: "q", value: query), URLQueryItem(name: "page", value: "\(page)")]
        )
        guard response.success else {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Search failed")
        }
        return response.data ?? []
    }

    func searchInInterestFollowers(interestId: String, query: String, page: Int = 0) async throws -> [SearchUserResult] {
        let response: SimpleApiResponse<[SearchUserResult]> = try await get(
            endpoint: "/search/interest-followers/\(interestId)",
            queryItems: [URLQueryItem(name: "q", value: query), URLQueryItem(name: "page", value: "\(page)")]
        )
        guard response.success else {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Search failed")
        }
        return response.data ?? []
    }

    func searchInterestsFollowing(userId: String, query: String, page: Int = 0) async throws -> [SearchInterestResult] {
        let response: SimpleApiResponse<[SearchInterestResult]> = try await get(
            endpoint: "/search/interests-following/\(userId)",
            queryItems: [URLQueryItem(name: "q", value: query), URLQueryItem(name: "page", value: "\(page)")]
        )
        guard response.success else {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Search failed")
        }
        return response.data ?? []
    }

    func searchInServiceFollowers(serviceId: String, query: String, page: Int = 0) async throws -> [SearchUserResult] {
        let response: SimpleApiResponse<[SearchUserResult]> = try await get(
            endpoint: "/search/service-followers/\(serviceId)",
            queryItems: [URLQueryItem(name: "q", value: query), URLQueryItem(name: "page", value: "\(page)")]
        )
        guard response.success else {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Search failed")
        }
        return response.data ?? []
    }

    func searchServicesFollowing(userId: String, query: String, page: Int = 0) async throws -> [SearchServiceResult] {
        let response: SimpleApiResponse<[SearchServiceResult]> = try await get(
            endpoint: "/search/services-following/\(userId)",
            queryItems: [URLQueryItem(name: "q", value: query), URLQueryItem(name: "page", value: "\(page)")]
        )
        guard response.success else {
            throw NetworkError.serverError(statusCode: 400, message: response.error ?? "Search failed")
        }
        return response.data ?? []
    }
}

@inline(__always)
private func netLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}
