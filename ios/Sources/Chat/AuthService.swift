import Foundation
import Firebase
import FirebaseMessaging
import Combine
import FirebaseAuth
enum AuthServiceError: Error {
    case userAlreadyExistsInBackend(backendId: String)
}

class AuthService {
    @Published var user: User?
    @Published var userSession: FirebaseAuth.User?

    static let shared = AuthService()

    init() {
        Task {
            do { try await loadUserData() }
            catch { print("DEBUG: AuthService init loadUserData failed: \(error.localizedDescription)") }
            if NetworkMonitor.shared.isConnectedNow {
                try? await UserService.shared.fetchCurrentUserService()
            }
        }
        NotificationCenter.default.addObserver(forName: .networkDidReconnect, object: nil, queue: nil) { [weak self] _ in
            guard let self, Auth.auth().currentUser != nil else { return }
            Task {
                try? await self.loadUserData()
                try? await UserService.shared.fetchCurrentUserService()
            }
        }
    }

    @MainActor
    func login(withEmail email: String, password: String) async throws -> Bool {
        do {
            let result = try await Auth.auth().signIn(withEmail: email, password: password)
            self.userSession = result.user

            do {
                try await ensureUserExistsInBackend(user: result.user)
                _ = try await result.user.getIDToken(forcingRefresh: true)
            } catch {
                print("DEBUG: Backend sync after login failed (will retry next login): \(error.localizedDescription)")
            }

            try await refreshMergedCurrentUser(uid: result.user.uid)

            if let fcmToken = Messaging.messaging().fcmToken {
                do {
                    #if targetEnvironment(simulator)
                    let isSandbox = true
                    #else
                    let isSandbox = false
                    #endif
                    try await NetworkService.shared.registerDeviceToken(fcmToken, platform: "ios", sandbox: isSandbox)
                } catch {
                    print("DEBUG: Failed to register device token after login: \(error.localizedDescription)")
                }
            }
            ChatWebSocketClient.shared.connect()
            await PushAckTokenRefresher.refreshIfNeeded()
            await SubscriptionsManager.current?.refreshStatus()

            return true
        } catch {
            print("DEBUG: Login failed \(error.localizedDescription)")
            throw error
        }
    }

    @MainActor
    private func mergeBackendProfile(into user: inout User) async {
        if let backendProfile = try? await NetworkService.shared.fetchCurrentUserProfile() {
            user.mergeEditableProfileFields(from: backendProfile)
        }
    }

    @MainActor
    private func refreshMergedCurrentUser(uid: String) async throws {
        var fetchedUser = try await UserService.fetchUser(withUid: uid)
        await mergeBackendProfile(into: &fetchedUser)
        fetchedUser.uid = uid
        if let backendId = fetchedUser.backendId {
            fetchedUser.id = backendId
        }
        self.user = fetchedUser
        UserService.shared.currentUser = fetchedUser
        OfflineCache.shared.saveCurrentUser(fetchedUser, firebaseUid: uid)
        startE2EE(uid: uid)
    }

    @MainActor
    private func restoreOfflineUser(uid: String) -> Bool {
        guard let cached = OfflineCache.shared.loadCurrentUser(firebaseUid: uid) else { return false }
        self.user = cached
        UserService.shared.currentUser = cached
        print("DEBUG: Restored signed-in user from offline snapshot")
        return true
    }

    @MainActor
    func createUser(email rawEmail: String, password: String, username: String, birthday: Date) async throws {
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        do {
            let age = Calendar.current.dateComponents([.year], from: birthday, to: Date()).year ?? 0
            guard age >= RegistrationViewModel.minimumAge else {
                throw RegistrationError.underMinimumAge
            }

            let result = try await Auth.auth().createUser(withEmail: email, password: password)
            self.userSession = result.user

            let data: [String: Any] = [
                "email": email,
                "username": username,
                "id": result.user.uid,
                "spotPlus": false,
                "zoneID": "0",
                "serviceProfile": false,
                "birthday": Timestamp(date: birthday),
                "timestamp": Timestamp(date: Date())
            ]

            try await FirestoreConstants.UserCollection.document(result.user.uid).setData(data)

            try await registerUserInBackend(user: result.user, username: username, email: email, birthday: birthday)

            _ = try await result.user.getIDToken(forcingRefresh: true)

            if let fcmToken = Messaging.messaging().fcmToken {
                do {
                    #if targetEnvironment(simulator)
                    let isSandbox = true
                    #else
                    let isSandbox = false
                    #endif
                    try await NetworkService.shared.registerDeviceToken(fcmToken, platform: "ios", sandbox: isSandbox)
                } catch {
                    print("DEBUG: Failed to register device token after account creation: \(error.localizedDescription)")
                }
            }

            try await refreshMergedCurrentUser(uid: result.user.uid)

        } catch {
            print("DEBUG: Failed to create user with error: \(error.localizedDescription)")
            throw error
        }
    }

    @MainActor
    func loadUserData() async throws {
        userSession = Auth.auth().currentUser

        if let session = userSession {
            if !NetworkMonitor.shared.isConnectedNow, restoreOfflineUser(uid: session.uid) {
                return
            }
            do {
                try await refreshMergedCurrentUser(uid: session.uid)
            } catch {
                if restoreOfflineUser(uid: session.uid) { return }
                throw error
            }

            await SubscriptionsManager.current?.refreshStatus()
        }
    }

    private func startE2EE(uid: String) {
        guard let backendId = user?.backendId, !backendId.isEmpty else { return }
        E2EEService.shared.bootstrap(userId: backendId)
    }

    func sendPasswordResetCode(toEmail email: String) async throws {
        try await NetworkService.shared.sendPasswordResetCode(email: email)
    }

    func resetPassword(email: String, code: String, newPassword: String) async throws {
        try await NetworkService.shared.resetPassword(email: email, code: code, newPassword: newPassword)
    }

    private static let birthdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private func registerUserInBackend(
        user: FirebaseAuth.User,
        username: String,
        email: String,
        birthday: Date? = nil,
        fullname: String? = nil,
        profile_image_url: String? = nil,
        bio: String? = nil,
        occupation: String? = nil,
        workPlace: String? = nil,
        countryCode: String? = nil,
        pronouns: String? = nil,
        relationshipStatus: String? = nil,
        url: String? = nil,
        zoneId: String = "0",
        isPrivateProfile: Bool = false,
        lat: Double? = nil,
        lng: Double? = nil
    ) async throws {
        struct RegisterRequest: Encodable {
            let firebase_uid: String
            let username: String
            let email: String
            let date_of_birth: String?
            let fullname: String?
            let profile_image_url: String?
            let bio: String?
            let occupation: String?
            let work_place: String?
            let country_code: String?
            let pronouns: String?
            let relationship_status: String?
            let url: String?
            let zone_id: String
            let is_private_profile: Bool
            let lat: Double?
            let lng: Double?
        }

        struct ApiResponse: Decodable {
            let success: Bool
            let data: UserData?
            let error: String?
            let code: String?

            struct UserData: Decodable {
                let id: String
                let firebase_uid: String
            }
        }

        let request = RegisterRequest(
            firebase_uid: user.uid,
            username: username,
            email: email,
            date_of_birth: birthday.map { Self.birthdayFormatter.string(from: $0) },
            fullname: fullname,
            profile_image_url: profile_image_url,
            bio: bio,
            occupation: occupation,
            work_place: workPlace,
            country_code: countryCode,
            pronouns: pronouns,
            relationship_status: relationshipStatus,
            url: url,
            zone_id: zoneId,
            is_private_profile: isPrivateProfile,
            lat: lat,
            lng: lng
        )

        do {
            let response: ApiResponse = try await NetworkService.shared.post(
                endpoint: "/users/register",
                body: request
            )

            if !response.success {
                if let existingId = response.data?.id {
                    throw AuthServiceError.userAlreadyExistsInBackend(backendId: existingId)
                }
                throw NSError(
                    domain: "AuthService",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: response.error ?? "Failed to register user in backend"]
                )
            }

            if let backendId = response.data?.id {
                try await FirestoreConstants.UserCollection
                    .document(user.uid)
                    .updateData(["backendId": backendId])
                await MainActor.run { UserService.shared.currentUser?.backendId = backendId }
                print("DEBUG: Firebase document updated with backendId: \(backendId)")
            }

            print("DEBUG: User successfully registered in backend with ID: \(response.data?.id ?? "unknown")")
        } catch {
            print("DEBUG: Backend registration failed: \(error.localizedDescription)")
            throw error
        }
    }

    private func ensureUserExistsInBackend(user: FirebaseAuth.User) async throws {
        guard let firestoreUser = try? await UserService.fetchUser(withUid: user.uid) else {
            print("DEBUG: Could not fetch user from Firestore")
            return
        }

        if firestoreUser.backendId != nil {
            print("DEBUG: User already has backendId, skipping migration")
            return
        }

        do {
            try await registerUserInBackend(
                user: user,
                username: firestoreUser.username,
                email: firestoreUser.email,
                birthday: nil,
                fullname: firestoreUser.fullname,
                profile_image_url: firestoreUser.profile_image_url,
                bio: firestoreUser.bio,
                occupation: firestoreUser.occupation,
                workPlace: firestoreUser.workPlace,
                countryCode: firestoreUser.countryCode,
                pronouns: firestoreUser.pronouns,
                relationshipStatus: firestoreUser.relashionshipStatus,
                url: firestoreUser.url,
                zoneId: firestoreUser.zoneID ?? "0",
                isPrivateProfile: firestoreUser.isPrivateProfile ?? false,
                lat: nil,
                lng: nil
            )
        } catch let error as AuthServiceError {
            if case .userAlreadyExistsInBackend(let backendId) = error {
                try await FirestoreConstants.UserCollection
                    .document(user.uid)
                    .updateData(["backendId": backendId])
                    await MainActor.run { UserService.shared.currentUser?.backendId = backendId }
                print("DEBUG: Migration complete — backendId synced from 409 response: \(backendId)")
                return
            }
            throw error
        }
    }

    func signout() {
        Task {
            await signoutAsync()
        }
    }

    @MainActor
    private func signoutAsync() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ChatWebSocketClient.shared.disconnect {
                continuation.resume()
            }
        }
        do {
            try await NetworkService.shared.exitAllZones()
        } catch {
            print("DEBUG: signout exitAllZones error: \(error.localizedDescription)")
        }
        NotificationCenter.default.post(
            name: .zoneEntryDidChange,
            object: nil,
            userInfo: ["zoneId": "0", "eavesdropping": false]
        )
        await LocationManager.shared.setSharingEnabled(false)
        await NotificationServiceApi.removeFCMToken()
        await VoipPushManager.shared.invalidateCurrentTokenOnSignOut()

        await E2EEService.shared.signOut()

        NetworkService.shared.clearTokenCache()

        PushAckTokenStore.clear()

        try? await ChatLocalStore.shared.clearAll()
        OfflineCache.shared.clearAll()

        self.userSession = nil
        self.user = nil
        UserService.shared.currentUser = nil
        UserService.shared.currentUserService = nil

        SubscriptionsManager.current?.clearStatus()

        try? Auth.auth().signOut()

        print("DEBUG: User signed out and cache cleared")
    }
}
