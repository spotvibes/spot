import SwiftUI
import PhotosUI
import Kingfisher

struct ParticipantsView: View {
    @StateObject private var viewModel: ParticipantsViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.edgeToEdgeSheetCoordinator) private var sheetCoordinator
    @ObservedObject private var e2eeStatus = E2EEStatusStore.shared
    @State private var showingSafetyNumbers = false
    @State private var showingAddPeople = false
    @State private var showingLeaveConfirm = false
    @State private var showingDeleteConfirm = false
    @State private var showingClearChatConfirm = false
    @State private var showingBlockConfirm = false
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showingGroupPhotoOptions = false
    @State private var showingGroupPhotoPicker = false
    @State private var showingClearCacheConfirm = false
    @State private var showingRenameAlert = false
    @State private var renameDraft = ""
    @State private var inviteLinkCopied = false

    let onLeftOrDeleted: (_ didLeave: Bool) -> Void
    let onViewProfile: ((_ userId: String) -> Void)?
    let initialProfileImageUrl: String?
    let onDismiss: (() -> Void)?

    private func closeSheet() {
        if let onDismiss { onDismiss() } else { dismiss() }
    }

    private var canOpenProfile: Bool { sheetCoordinator?.presentPushStyle != nil }

    init(
        conversationId: String,
        mode: ParticipantsMode,
        networkService: NetworkService = .shared,
        initialMutedUntil: Date? = nil,
        initialArchived: Bool = false,
        initialProfileImageUrl: String? = nil,
        onDismiss: (() -> Void)? = nil,
        onLeftOrDeleted: @escaping (_ didLeave: Bool) -> Void = { _ in },
        onViewProfile: ((_ userId: String) -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: ParticipantsViewModel(
            conversationId: conversationId,
            mode: mode,
            networkService: networkService,
            initialMutedUntil: initialMutedUntil,
            initialArchived: initialArchived
        ))
        self.onLeftOrDeleted = onLeftOrDeleted
        self.onViewProfile = onViewProfile
        self.initialProfileImageUrl = initialProfileImageUrl
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            content
        }
                .task { await viewModel.load() }
                .task { await viewModel.loadStorageInfo() }
                .task { await viewModel.loadEncryption() }
                .onChange(of: viewModel.didLeaveOrDeleteGroup) { left in
                    if left { onLeftOrDeleted(viewModel.didLeaveGroup); closeSheet() }
                }
                .alert("Error", isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.errorMessage = nil } }
                ), actions: {
                    Button("OK") { viewModel.errorMessage = nil }
                }, message: { Text(viewModel.errorMessage ?? "") })
                .alert("Rename Group", isPresented: $showingRenameAlert) {
                    TextField("Group name", text: $renameDraft)
                    Button("Cancel", role: .cancel) { }
                    Button("Save") {
                        let newName = renameDraft
                        Task { await viewModel.rename(to: newName) }
                    }
                } message: {
                    Text("Everyone in the group will see the new name.")
                }
                .sheet(isPresented: $showingAddPeople) {
                    ParticipantsMembersPicker(embedded: false, close: { showingAddPeople = false }) { selected in
                        Task { await viewModel.addMembers(selected) }
                    }
                }
        .background(Color.edgeToEdgeSheetBackground.ignoresSafeArea())
    }

    private var topBar: some View {
        HStack {
            Text(viewModel.isGroup ? "MEMBERS" : "DETAILS")
                .font(.appFont(fontStyle: .subheadline, fontWeight: .semibold))
                .foregroundColor(.gray)
                .accessibilityAddTraits(.isHeader)

            Spacer()

            if viewModel.isGroup && viewModel.details?.callerIsCreator == true {
                Button {
                    presentAddPeople()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Add people")
                            .font(.appFont(fontStyle: .subheadline, fontWeight: .semibold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Color(.systemGray5), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add people")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func presentAddPeople() {
        let vm = viewModel
        if let coordinator = sheetCoordinator, let present = coordinator.presentPushContent {
            present(AnyView(
                ParticipantsMembersPicker(embedded: true, close: { coordinator.dismissPushContent?() }) { selected in
                    Task { await vm.addMembers(selected) }
                }
            ))
        } else {
            showingAddPeople = true
        }
    }

    private func openProfile(userId: String, username: String?, displayName: String, profileImageUrl: String?, isFollowed: Bool? = nil) {
        guard let present = sheetCoordinator?.presentPushStyle else { return }
        present(User.chatParticipant(
            id: userId,
            username: username,
            displayName: displayName,
            profileImageUrl: profileImageUrl,
            isFollowed: isFollowed
        ))
    }

    private func openDirectProfile(_ info: BackendConversationSummary) {
        openProfile(
            userId: info.otherParticipantId,
            username: info.username,
            displayName: info.displayName,
            profileImageUrl: info.profileImageUrl ?? initialProfileImageUrl,
            isFollowed: info.isFollowing
        )
    }

    private var navigationTitle: String {
        if viewModel.isGroup {
            return viewModel.details?.name ?? "Group"
        } else {
            return viewModel.directInfo?.displayName ?? "Details"
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isGroup {
            groupContent
        } else {
            directContent
        }
    }

    private var muteMenuRow: some View {
        Menu {
            ForEach(MuteDuration.allCases.filter { $0 != .off || viewModel.isMuted }) { duration in
                Button(duration.label) {
                    Task { await viewModel.setMuted(until: duration.until()) }
                }
            }
        } label: {
            SettingsRowLabel(
                icon: viewModel.isMuted ? "bell.slash" : "bell",
                title: viewModel.isMuted ? "Muted" : "Mute Notifications"
            )
        }
        .buttonStyle(SettingsPressStyle())
    }

    private var archiveRow: some View {
        SettingsToggleRow(
            icon: "archivebox",
            title: "Archive Chat",
            isOn: Binding(
                get: { viewModel.archived },
                set: { newValue in Task { await viewModel.setArchived(newValue) } }
            )
        )
    }

    private func screen<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        SettingsScreen(
            reservesTabBarSpace: false,
            background: Color.edgeToEdgeSheetBackground,
            content: content
        )
    }

    @ViewBuilder
    private var groupContent: some View {
        if let details = viewModel.details {
            screen {
                if details.isDeleted {
                    SettingsSection(showsBand: false) {
                        SettingsRowLabel(icon: "exclamationmark.circle", title: "This group was deleted")
                    }
                }

                SettingsSection(showsBand: details.isDeleted) {
                    groupHeader(details)
                }

                encryptionSection()

                SettingsSection("Participants (\(details.activeParticipants.count))") {
                    ForEach(details.activeParticipants) { participant in
                        participantRow(participant, callerIsCreator: details.callerIsCreator)
                    }
                }

                if details.callerIsCreator && !details.isDeleted {
                    inviteLinkSection
                }

                sharedMediaSection()
                storageSection()

                SettingsSection {
                    muteMenuRow
                    archiveRow
                }

                SettingsSection {
                    SettingsButtonRow(
                        icon: "rectangle.portrait.and.arrow.right",
                        title: "Leave Group",
                        isDestructive: true
                    ) {
                        showingLeaveConfirm = true
                    }

                    if details.callerIsCreator && !details.isDeleted {
                        SettingsButtonRow(
                            icon: "trash",
                            title: "Delete Group",
                            isDestructive: true
                        ) {
                            showingDeleteConfirm = true
                        }
                    }
                }
            }
            .confirmationDialog("Leave this group?", isPresented: $showingLeaveConfirm, titleVisibility: .visible) {
                Button("Leave Group", role: .destructive) { Task { await viewModel.leaveGroup() } }
                Button("Cancel", role: .cancel) { }
            }
            .confirmationDialog(
                "Delete this group for everyone?",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete Group", role: .destructive) { Task { await viewModel.deleteGroup() } }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Everyone will see that you deleted the group, and no one will be able to send messages here anymore.")
                    .font(.appFont(fontStyle: .footnote, fontWeight: .regular))
            }
        } else if viewModel.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Couldn't load this group.")
                .font(.appFont(fontStyle: .body, fontWeight: .regular))
                .foregroundColor(.secondary)
        }
    }

    private var inviteLinkSection: some View {
        SettingsSection(
            footer: "Only group creators can use invite links. Anyone with your link can join, and the chat will show they joined through you. Other creators have their own links."
        ) {
            SettingsToggleRow(
                icon: "link",
                title: "Invite Link",
                isOn: Binding(
                    get: { viewModel.inviteLink?.enabled ?? false },
                    set: { newValue in Task { await viewModel.setInviteLinkEnabled(newValue) } }
                )
            )
            .disabled(viewModel.isUpdatingInviteLink)

            if let link = viewModel.inviteLink, link.enabled {
                SettingsRowLabel(
                    icon: "globe",
                    title: "Your Link",
                    value: link.url.replacingOccurrences(of: "https://", with: "")
                )

                SettingsButtonRow(
                    icon: inviteLinkCopied ? "checkmark" : "doc.on.doc",
                    title: inviteLinkCopied ? "Copied" : "Copy Link"
                ) {
                    UIPasteboard.general.string = link.url
                    inviteLinkCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { inviteLinkCopied = false }
                }

                if let url = URL(string: link.url) {
                    ShareLink(item: url) {
                        SettingsRowLabel(icon: "square.and.arrow.up", title: "Share Link")
                    }
                    .buttonStyle(SettingsPressStyle())
                }
            }
        }
    }

    private func groupHeader(_ details: GroupDetails) -> some View {
        let hasCustomImage = !(details.imageUrl ?? "").isEmpty
        return HStack(spacing: 16) {
            ZStack(alignment: .bottomTrailing) {
                ChatAvatarView(
                    imageURLString: hasCustomImage ? details.imageUrl : nil,
                    seed: GroupAvatarStore.shared.avatarSeed(forConversationId: viewModel.conversationId),
                    displayName: details.name ?? "Group",
                    size: 64
                )

                if details.callerIsCreator {
                    Button {
                        if hasCustomImage {
                            showingGroupPhotoOptions = true
                        } else {
                            showingGroupPhotoPicker = true
                        }
                    } label: {
                        Image(systemName: "camera.circle.fill")
                            .font(.title3)
                            .foregroundColor(.accentColor)
                            .background(Circle().fill(Color(.colorGrayLight)))
                    }
                    .buttonStyle(.plain)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                groupNameLabel(details)
                Text("\(details.activeParticipants.count) people")
                    .font(.appFont(fontStyle: .subheadline, fontWeight: .regular))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog("Group Photo", isPresented: $showingGroupPhotoOptions, titleVisibility: .visible) {
            Button("Choose from Library") { showingGroupPhotoPicker = true }
            Button("Remove Current Photo", role: .destructive) {
                Task { await viewModel.removeGroupImage() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .photosPicker(isPresented: $showingGroupPhotoPicker, selection: $photoPickerItem, matching: .images)
        .onChange(of: photoPickerItem) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await viewModel.changeGroupImage(image)
                }
                photoPickerItem = nil
            }
        }
    }

    @ViewBuilder
    private func groupNameLabel(_ details: GroupDetails) -> some View {
        let name = details.name ?? "Group"
        if details.callerIsCreator && !details.isDeleted {
            Button {
                renameDraft = details.name ?? ""
                showingRenameAlert = true
            } label: {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.appFont(fontStyle: .headline, fontWeight: .semibold))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Renames the group")
        } else {
            Text(name).font(.appFont(fontStyle: .headline, fontWeight: .semibold))
        }
    }

    private func participantRow(_ participant: GroupParticipant, callerIsCreator: Bool) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                ChatAvatarView(
                    imageURLString: participant.profileImageUrl,
                    seed: participant.userId,
                    displayName: participant.displayName,
                    size: 40
                )
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(participant.displayName)
                            .font(.appFont(fontStyle: .body, fontWeight: .regular))
                        if participant.isCreator {
                            Text("Creator")
                                .font(.appFont(fontStyle: .caption2, fontWeight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundColor(.accentColor)
                                .clipShape(Capsule())
                        }
                    }
                    if let username = participant.username, username != participant.displayName {
                        Text("@\(username)")
                            .font(.appFont(fontStyle: .subheadline, fontWeight: .regular))
                            .foregroundColor(.secondary)
                    }
                    if participant.status == .pending {
                        Text("Invited — hasn't accepted yet")
                            .font(.appFont(fontStyle: .subheadline, fontWeight: .regular))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                openProfile(
                    userId: participant.userId,
                    username: participant.username,
                    displayName: participant.displayName,
                    profileImageUrl: participant.profileImageUrl
                )
            }
            .accessibilityAddTraits(canOpenProfile ? .isButton : [])
            .accessibilityHint(canOpenProfile ? "Opens profile" : "")

            if callerIsCreator && !participant.isCreator {
                Menu {
                    Button("Make Creator") { Task { await viewModel.promote(participant) } }
                    Button("Remove from Group", role: .destructive) { Task { await viewModel.remove(participant) } }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundColor(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var directContent: some View {
        if let info = viewModel.directInfo {
            screen {
                SettingsSection(showsBand: false) {
                    directHeader(info)
                }

                encryptionSection()

                sharedMediaSection()
                storageSection()

                SettingsSection {
                    if onViewProfile != nil || canOpenProfile {
                        SettingsButtonRow(
                            icon: "person.circle",
                            title: "View Profile",
                            accessory: .chevron
                        ) {
                            if let onViewProfile {
                                onViewProfile(info.otherParticipantId)
                                closeSheet()
                            } else {
                                openDirectProfile(info)
                            }
                        }
                    }

                    muteMenuRow
                    archiveRow
                }

                SettingsSection {
                    SettingsButtonRow(icon: "trash", title: "Clear Chat") {
                        showingClearChatConfirm = true
                    }
                }

                SettingsSection {
                    SettingsButtonRow(
                        icon: "hand.raised",
                        title: info.isBlocked ? "Unblock \(info.displayName)" : "Block \(info.displayName)",
                        isDestructive: true
                    ) {
                        if info.isBlocked {
                            Task { await viewModel.toggleBlock() }
                        } else {
                            showingBlockConfirm = true
                        }
                    }
                }
            }
            .confirmationDialog(
                "Clear this chat?",
                isPresented: $showingClearChatConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear Chat", role: .destructive) {
                    Task {
                        if await viewModel.clearChat() { closeSheet() }
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This deletes your message history in this chat. This can't be undone.")
                    .font(.appFont(fontStyle: .footnote, fontWeight: .regular))
            }
            .confirmationDialog(
                "Block \(info.displayName)?",
                isPresented: $showingBlockConfirm,
                titleVisibility: .visible
            ) {
                Button("Block", role: .destructive) { Task { await viewModel.toggleBlock() } }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("They won't be able to message or call you, and won't be notified that you blocked them.")
                    .font(.appFont(fontStyle: .footnote, fontWeight: .regular))
            }
        } else if viewModel.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Couldn't load this conversation.")
                .font(.appFont(fontStyle: .body, fontWeight: .regular))
                .foregroundColor(.secondary)
        }
    }

    private func directHeader(_ info: BackendConversationSummary) -> some View {
        HStack(spacing: 16) {
            ChatAvatarView(
                imageURLString: info.profileImageUrl ?? initialProfileImageUrl,
                seed: info.otherParticipantId,
                displayName: info.displayName,
                size: 64
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(info.displayName).font(.appFont(fontStyle: .headline, fontWeight: .semibold))
                if let username = info.username, username != info.displayName {
                    Text("@\(username)")
                        .font(.appFont(fontStyle: .subheadline, fontWeight: .regular))
                        .foregroundColor(.secondary)
                }
                if !info.isFollowing {
                    Text("You don't follow this account")
                        .font(.appFont(fontStyle: .caption, fontWeight: .regular))
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
            if canOpenProfile {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(.systemGray2))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { openDirectProfile(info) }
        .accessibilityAddTraits(canOpenProfile ? .isButton : [])
    }

    @ViewBuilder
    private func encryptionSection() -> some View {
        let on = e2eeStatus.isEnabled(viewModel.conversationId)
        let missing = viewModel.membersWithoutEncryption ?? 0
        if on {
            SettingsSection(footer: "Messages, photos, videos, files, voice notes, locations and calls in this chat are encrypted on your devices and can only be read by the people in it. Compare safety numbers to be sure nobody is intercepting.") {
                SettingsRowLabel(icon: "lock.fill", title: "End-to-end encrypted")
                SettingsButtonRow(icon: "checkmark.shield", title: "Verify safety number", accessory: .chevron) {
                    showingSafetyNumbers = true
                }
            }
            .sheet(isPresented: $showingSafetyNumbers) {
                E2EESafetyNumberView(conversationId: viewModel.conversationId)
            }
        } else if missing > 0 {
            SettingsSection(footer: "\(missing) \(missing == 1 ? "person hasn't" : "people haven't") set up encryption yet. Until they update the app, messages in this chat aren't end-to-end encrypted. It turns on automatically once they have.") {
                SettingsRowLabel(icon: "lock.open", title: "Not encrypted yet")
            }
        } else {
            SettingsSection(footer: "Messages are end-to-end encrypted. It switches on automatically with the next message you send.") {
                SettingsRowLabel(icon: "lock", title: "End-to-end encryption")
            }
        }
    }

    private var viewerMediaMessages: [BackendMessage] {
        viewModel.sharedMedia.filter { [.image, .video, .file].contains($0.contentType) }
    }

    @ViewBuilder
    private func sharedMediaSection() -> some View {
        SettingsSection("Shared Media (\(viewerMediaMessages.count))") {
            if viewModel.isLoadingStorage && viewModel.sharedMedia.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .padding(.vertical, 16)
            } else if viewerMediaMessages.isEmpty {
                Text("No photos, videos, or files shared yet")
                    .font(.appFont(fontStyle: .subheadline, fontWeight: .regular))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(viewerMediaMessages.enumerated()), id: \.element.id) { index, message in
                            sharedMediaTile(message)
                                .onTapGesture {
                                    MediaGalleryPresenter.present(messages: viewerMediaMessages, startIndex: index)
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    @ViewBuilder
    private func sharedMediaTile(_ message: BackendMessage) -> some View {
        switch message.contentType {
        case .image, .video:
            ZStack {
                CachedThumbnailImage(
                    cacheKey: message.id + "_thumb",
                    remoteURL: (message.mediaMetadata?.thumbnailUrl ?? message.mediaUrl).flatMap(URL.init),
                    contentMode: .fill,
                    cornerRadius: 8
                )
                if message.contentType == .video {
                    Image(systemName: "play.circle.fill")
                        .foregroundColor(.white)
                        .shadow(radius: 2)
                }
            }
            .frame(width: 72, height: 72)
        default:
            VStack(spacing: 4) {
                Image(systemName: "doc.fill")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text(fileDisplayName(for: message))
                    .font(.appFont(fontStyle: .caption2, fontWeight: .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(6)
            .frame(width: 72, height: 72)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func fileDisplayName(for message: BackendMessage) -> String {
        if let name = message.mediaUrl.flatMap(URL.init)?.lastPathComponent, !name.isEmpty {
            return name
        }
        return message.mediaMetadata?.mimeType ?? "File"
    }

    @ViewBuilder
    private func storageSection() -> some View {
        let isLoadingSize = viewModel.isLoadingStorage && viewModel.cacheSizeBytes == 0

        SettingsSection(
            footer: "Frees up space by removing this chat's downloaded photos, videos, files, and voice notes from this device. Nothing is deleted from the server — reopening an item downloads it again."
        ) {
            SettingsRowLabel(
                icon: "internaldrive",
                title: "Cache Used",
                value: isLoadingSize ? nil : formattedCacheSize,
                isLoading: isLoadingSize
            )

            SettingsButtonRow(
                icon: "trash",
                title: "Delete Cache",
                isDestructive: true,
                isLoading: viewModel.isClearingCache
            ) {
                showingClearCacheConfirm = true
            }
            .disabled(viewModel.cacheSizeBytes == 0 || viewModel.isClearingCache)
        }
        .confirmationDialog(
            "Delete this chat's cached media?",
            isPresented: $showingClearCacheConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Cache", role: .destructive) { Task { await viewModel.clearConversationCache() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This only frees up space on this device. Nothing is deleted from the server or for anyone else in this chat.")
                .font(.appFont(fontStyle: .footnote, fontWeight: .regular))
        }
    }

    private var formattedCacheSize: String {
        ByteCountFormatter.string(fromByteCount: viewModel.cacheSizeBytes, countStyle: .file)
    }
}

private struct ParticipantsMembersPicker: View {
    @StateObject private var viewModel = CreateGroupViewModel()
    let embedded: Bool
    let close: () -> Void
    let onDone: ([GroupPickerPerson]) -> Void

    var body: some View {
        if embedded {
            content
        } else {
            NavigationView {
                content
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Cancel") { close() }
                        }
                    }
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            SettingsTextFieldRow(
                icon: "magnifyingglass",
                placeholder: "Search people",
                text: $viewModel.searchQuery,
                capitalization: .never,
                disablesAutocorrection: true,
                showsClearButton: true
            )
            .padding(.top, 8)

            SettingsScreen(reservesTabBarSpace: false) {
                ForEach(viewModel.searchResults) { user in
                    Button {
                        viewModel.toggleSelection(user)
                    } label: {
                        HStack(spacing: 12) {
                            CircularProfileImageView(user: user.resolvedUser, size: .xSmall, type: .circle)
                            Text(user.fullname ?? user.username)
                                .font(.appFont(fontStyle: .body, fontWeight: .regular))
                            Spacer(minLength: 8)
                            Image(systemName: viewModel.isSelected(user) ? "checkmark.circle.fill" : "plus.circle")
                                .font(.system(size: 22, weight: .regular))
                                .foregroundStyle(viewModel.isSelected(user) ? Color.accentColor : Color(.systemGray2))
                        }
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SettingsPressStyle())
                }
            }
        }
        .navigationTitle("Add People")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Add") {
                    onDone(viewModel.selectedPeople)
                    close()
                }
                .disabled(viewModel.selectedPeople.isEmpty)
            }
        }
    }
}

extension User {
    static func chatParticipant(
        id: String,
        username: String?,
        displayName: String,
        profileImageUrl: String?,
        isFollowed: Bool? = nil
    ) -> User {
        User(
            uid: id,
            username: username ?? displayName,
            email: "",
            profile_image_url: profileImageUrl,
            isFollowed: isFollowed ?? false,
            id: id,
            backendId: id
        )
    }
}
