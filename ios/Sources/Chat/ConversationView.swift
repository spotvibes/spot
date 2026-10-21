import SwiftUI
import MapKit
import UIKit
import AVKit
import AVFoundation
import Photos

struct ConversationView: View {
    @StateObject private var viewModel: ConversationViewModel
    @StateObject private var inputBarViewModel = InputBarViewModel()
    @State private var replyingTo: BackendMessage?
    @State private var reactingToMessage: BackendMessage?
    @State private var reactingToMessageFrame: CGRect = .zero
    @State private var reactionSummaryMessage: BackendMessage?
    @State private var messageInfoMessage: BackendMessage?
    @State private var showingMessageInfo = false
    @State private var reactionInfoMessage: BackendMessage?
    @State private var showingReactionInfo = false
    @State private var reactionSummaryIncludesDelivery = true
    @State private var reactionSummaryIncludesReactions = true
    @State private var messagePendingDeletion: BackendMessage?
    @State private var showCamera = false
    @State private var showLocationShare = false
 
    @State private var isSavingMedia = false
    @State private var saveMediaResultMessage: String?
    @State private var exportingFileURL: URL?
    @State private var highlightedMessageId: String?
    @State private var scrollToMessageId: String?
    @State private var hasScrolledOnLoad = false
    @State private var isNearBottom = true
    @State private var showingParticipants = false
    @State private var uploadInProgress = false
    @State private var uploadProgress: Double = 0
    @State private var uploadFileIndex = 0
    @State private var uploadFileTotal = 0
    private var currentUserId: String? { AuthService.shared.user?.backendId }
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var callManager = CallManager.shared

    @Environment(\.dismiss) private var dismiss
    @State private var isResolvingRequest = false
    @State private var showPendingCallAlert = false
    @ObservedObject private var pinManager = ChatPinManager.shared

    private var isChatLocked: Bool { pinManager.isPinEnabled && pinManager.isLocked }

    init(
        conversationId: String,
        otherParticipantId: String,
        otherParticipantType: ParticipantType,
        initialDisplayName: String? = nil,
        initialProfileImageUrl: String? = nil,
        isGroup: Bool? = false,
        initialStatus: ParticipantStatus = .accepted,
        initialOtherStatus: ParticipantStatus = .accepted,
        initialGroupName: String? = nil,
        initialGroupImageUrl: String? = nil,
        initialMutedUntil: Date? = nil,
        initialArchived: Bool = false
    ) {
        _viewModel = StateObject(wrappedValue: ConversationViewModel(
            conversationId: conversationId,
            otherParticipantId: otherParticipantId,
            otherParticipantType: otherParticipantType,
            initialDisplayName: initialDisplayName,
            initialProfileImageUrl: initialProfileImageUrl,
            isGroup: isGroup ?? false,
            initialStatus: initialStatus,
            initialOtherStatus: initialOtherStatus,
            initialGroupName: initialGroupName,
            initialGroupImageUrl: initialGroupImageUrl,
            initialMutedUntil: initialMutedUntil,
            initialArchived: initialArchived
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            customTopBar

            if showSendRequestBanner {
                sendRequestBanner
            }

            messageList

            if viewModel.isOtherTyping {
                typingIndicator
            }

            if uploadInProgress {
                uploadStatusBar
            }

            if viewModel.isGroupDeleted {
                groupDeletedBanner
            } else if (viewModel.isGroup ?? false) && viewModel.selfHasLeftGroup {
                leftGroupBanner
            } else if viewModel.isBlocked {
                blockedBanner
            } else if canReply {
                InputBarView(
                    viewModel: inputBarViewModel,
                    replyingTo: $replyingTo,
                    onCameraTap: { showCamera = true },
                    onLocationTap: { showLocationShare = true },
                    onAttachmentsPicked: { attachments in
                        Task { await sendAttachments(attachments) }
                    },
                    isSharingLiveLocation: viewModel.isSharingLiveLocation,
                    onTypingChanged: { viewModel.notifyTyping() },
                    isGroupConversation: viewModel.isGroup ?? false
                )
            } else {
                pendingRequestBanner
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(isPresented: $showCamera) {
            BitCaptureView { captured in
                Task { await sendBit(captured) }
            }
        }
 
        .fullScreenCover(isPresented: Binding(
            get: { callManager.callState != .idle },
            set: { _ in }
        )) {
            CallView(otherParticipantId: viewModel.otherParticipantId)
        }
        .edgeToEdgeSheet(isPresented: $showLocationShare, detent: .fraction(0.6)) {
            LocationShareView(
                viewModel: viewModel,
                onDismiss: { showLocationShare = false }
            )
        }
        .edgeToEdgeSheet(
            isPresented: $showingParticipants,
            detent: .fraction(0.9),
            profilePushStyle: .fullScreen
        ) {
            ParticipantsView(
                conversationId: viewModel.conversationId,
                mode: (viewModel.isGroup ?? false)
                    ? .group
                    : .direct(otherParticipantId: viewModel.otherParticipantId, otherParticipantType: viewModel.otherParticipantType),
                initialMutedUntil: viewModel.mutedUntil,
                initialArchived: viewModel.archived,
                initialProfileImageUrl: (viewModel.isGroup ?? false) ? nil : viewModel.otherProfileImageUrl,
                onDismiss: { showingParticipants = false },
                onLeftOrDeleted: { didLeave in
                Task {
                    if didLeave {
                        await viewModel.recordSelfLeftGroupLocally()
                    }
                    dismiss()
                }
                }
            )
            .onDisappear {
                guard viewModel.isGroup ?? false else { return }
                Task {
                    await viewModel.refreshGroupDetails()
                }
            }
        }
        .onAppear {
                    
                    MediaViewerCoordinator.shared.conversationDidAppear()
                    ChatWebSocketClient.shared.currentlyOpenConversationId = viewModel.conversationId
                    Task { await viewModel.handleAppDidBecomeActive() }
                    inputBarViewModel.onSendText = { text in
                        let replyToId = replyingTo?.id
                        viewModel.sendText(text, replyToMessageId: replyToId)
                        replyingTo = nil
                        scrollToLatestMessage()
                    }
                    inputBarViewModel.onSendVoice = { url, durationMs in
                        Task { await sendVoiceMessage(url: url, durationMs: durationMs) }
                    }
                    viewModel.markVisibleMessagesRead()
                    scrollToLatestMessage()
                }
        .onChange(of: viewModel.messages.count) {
            viewModel.markVisibleMessagesRead()
            guard !hasScrolledOnLoad, !viewModel.messages.isEmpty else { return }
            scrollToLatestMessage()
        }
        .onChange(of: viewModel.reconciledMessageIds) { _, mapping in
            if let staleId = reactingToMessage?.id, let newId = mapping[staleId],
               let real = viewModel.messages.first(where: { $0.id == newId }) {
                reactingToMessage = real
            }
            if let staleId = reactionSummaryMessage?.id, let newId = mapping[staleId],
               let real = viewModel.messages.first(where: { $0.id == newId }) {
                reactionSummaryMessage = real
            }
            if let staleId = reactionInfoMessage?.id, let newId = mapping[staleId],
               let real = viewModel.messages.first(where: { $0.id == newId }) {
                reactionInfoMessage = real
            }
            if let staleId = highlightedMessageId, let newId = mapping[staleId] {
                highlightedMessageId = newId
            }
        }
        .onDisappear {
            viewModel.markVisibleMessagesRead(immediate: true)
            
            MediaViewerCoordinator.shared.conversationDidDisappear()
            if ChatWebSocketClient.shared.currentlyOpenConversationId == viewModel.conversationId {
                ChatWebSocketClient.shared.currentlyOpenConversationId = nil
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await viewModel.handleAppDidBecomeActive()
                }
            }
        }
        .alert("Message Request Pending", isPresented: $showPendingCallAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your message request is still pending.")
        }
        .overlay {
            if let message = reactingToMessage {
                MessageContextOverlay(
                    message: message,
                    isMine: message.senderId == currentUserId,
                    currentUserId: currentUserId,
                    showDeliveryInfoAction: true,
                    saveActionItemCount: saveActionGroup(for: message)?.count ?? 0,
                    canDeleteAction: message.canUnsend(currentUserId: currentUserId),
                    canEditAction: message.canEdit(currentUserId: currentUserId)
                        && !(viewModel.isGroupDeleted || ((viewModel.isGroup ?? false) && viewModel.selfHasLeftGroup) || viewModel.isBlocked),
                    canReact: reactionsEnabled,
                    canReplyAction: !(viewModel.isGroupDeleted || ((viewModel.isGroup ?? false) && viewModel.selfHasLeftGroup) || viewModel.isBlocked),
                    anchorFrame: reactingToMessageFrame,
                    onSelectEmoji: { emoji in viewModel.toggleReaction(on: message.id, emoji: emoji) },
                    onAction: { action in handleMessageAction(action, for: message) },
                    onDismiss: { reactingToMessage = nil }
                )
            }
        }
        .animation(.easeOut(duration: 0.15), value: reactingToMessage?.id)
        .overlay {
            if let message = reactionSummaryMessage {
                ReactionSummaryOverlay(
                    reactions: reactionSummaryIncludesReactions ? message.reactions : [],
                    deliveryDetails: reactionSummaryIncludesDelivery ? deliveryDetails(for: message) : [],
                    onDismiss: { dismissReactionSummary() }
                )
            }
        }
        .animation(.easeOut(duration: 0.15), value: reactionSummaryMessage?.id)
        .edgeToEdgeSheet(isPresented: $showingMessageInfo, detent: .fraction(0.7)) {
            if let message = messageInfoMessage {
                MessageInfoView(
                    message: message,
                    viewModel: viewModel,
                    replyPreview: replyPreviewInfo(for: message),
                    onDismiss: { showingMessageInfo = false }
                )
            }
        }
        .edgeToEdgeSheet(isPresented: $showingReactionInfo, detent: .fraction(0.7)) {
            if let message = reactionInfoMessage {
                MessageReactionInfoView(
                    message: message,
                    viewModel: viewModel,
                    currentUserId: currentUserId,
                    replyPreview: replyPreviewInfo(for: message),
                    onDismiss: { showingReactionInfo = false }
                )
            }
        }
        .alert(
            "Delete Message?",
            isPresented: Binding(
                get: { messagePendingDeletion != nil },
                set: { if !$0 { messagePendingDeletion = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let id = messagePendingDeletion?.id {
                    viewModel.deleteMessage(id)
                }
                messagePendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { messagePendingDeletion = nil }
        } message: {
            Text("This message will be deleted for everyone in this conversation.")
        }
        .alert(
            "Can't Send Message",
            isPresented: Binding(
                get: { viewModel.followRequiredMessage != nil },
                set: { if !$0 { viewModel.followRequiredMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { viewModel.followRequiredMessage = nil }
        } message: {
            Text(viewModel.followRequiredMessage ?? "")
        }
        .alert(
            "Save",
            isPresented: Binding(
                get: { saveMediaResultMessage != nil },
                set: { if !$0 { saveMediaResultMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { saveMediaResultMessage = nil }
        } message: {
            Text(saveMediaResultMessage ?? "")
        }
        .fileMover(
            isPresented: Binding(
                get: { exportingFileURL != nil },
                set: { if !$0 { exportingFileURL = nil } }
            ),
            file: exportingFileURL
        ) { result in
            switch result {
            case .success:
                saveMediaResultMessage = "Saved to Files."
            case .failure:
                saveMediaResultMessage = "Couldn't save this file."
            }
            exportingFileURL = nil
        }
        .overlay(alignment: .top) {
            if isSavingMedia {
                Text("Saving…")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 64)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isSavingMedia)
        .overlay {
            if isChatLocked {
                ChatPinLockView(pinManager: pinManager)
                    .transition(.opacity)
            }
        }
        .animation(.default, value: pinManager.isLocked)
    }

    private var customTopBar: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Back")

            if !isChatLocked {
                Button {
                    showingParticipants = true
                } label: {
                    Group {
                        if viewModel.isGroup ?? false {
                            GroupConversationHeaderView(
                                groupName: viewModel.groupName,
                                groupImageUrl: viewModel.groupImageUrl,
                                avatarSeed: viewModel.groupAvatarSeed,
                                isDeleted: viewModel.isGroupDeleted,
                                hasLeft: viewModel.selfHasLeftGroup,
                                typingIndicatorText: viewModel.typingIndicatorText
                            )
                        } else {
                            ConversationHeaderView(
                                otherParticipantId: viewModel.otherParticipantId,
                                displayName: viewModel.otherDisplayName,
                                profileImageUrl: viewModel.otherProfileImageUrl,
                                presence: viewModel.otherPresence,
                                isOtherTyping: viewModel.isOtherTyping
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if !(viewModel.isGroup ?? false) {
                    callButtonsPill
                }
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.6)
        }
    }

    private var callButtonsPill: some View {
        HStack(spacing: 0) {
            Button { tapCall(.voice) } label: {
                Image(systemName: "phone.fill")
                    .frame(width: 46, height: 38)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Voice call")
            Button { tapCall(.video) } label: {
                Image(systemName: "video.fill")
                    .frame(width: 46, height: 38)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Video call")
        }
        .font(.system(size: 17, weight: .semibold))
        .foregroundColor(.primary)
        .background(Color(.systemGray5), in: Capsule())
        .opacity(callsEnabled ? 1 : 0.4)
        .disabled(viewModel.isBlocked)
    }

    private func handleMessageAction(_ action: ConversationMessageMenuAction, for message: BackendMessage) {
        switch action {
        case .copy:
            if let text = message.textContent { UIPasteboard.general.string = text }
        case .reply:
            replyingTo = message
        case .info:
            if isLargeGroup && message.senderId == currentUserId {
                messageInfoMessage = message
                showingMessageInfo = true
            } else {
                presentReactionSummary(for: message, includeReactions: false)
            }
        case .saveAll, .save:
            guard let group = saveActionGroup(for: message) else { return }
            if let only = group.first, group.count == 1, only.contentType == .file {
                exportFile(only)
            } else {
                saveAllMedia(in: group)
            }
        case .edit:
            viewModel.beginEditing(messageId: message.id)
        case .delete:
            messagePendingDeletion = message
        }
    }

    private func mediaGroup(for message: BackendMessage) -> [BackendMessage]? {
        guard message.contentType == .image || message.contentType == .video else { return nil }
        let orderedIds = viewModel.messages.map(\.id)
        let messagesById = Dictionary(uniqueKeysWithValues: viewModel.messages.map { ($0.id, $0) })
        return MediaAlbumGrouping.albumMessages(for: message.id, orderedIds: orderedIds, messagesById: messagesById)
    }

    private func saveActionGroup(for message: BackendMessage) -> [BackendMessage]? {
        if let group = mediaGroup(for: message) { return group }
        guard message.senderId != currentUserId,
              message.contentType == .image || message.contentType == .video || message.contentType == .file
        else { return nil }
        return [message]
    }

    private func saveAllMedia(in group: [BackendMessage]) {
        Task {
            guard await requestPhotoLibraryAddPermission() else {
                saveMediaResultMessage = "Allow access to Photos in Settings to save media."
                return
            }

            isSavingMedia = true
            var savedCount = 0
            for message in group {
                guard let urlString = message.mediaUrl, let remoteURL = URL(string: urlString) else { continue }
                do {
                    let localURL = try await MediaFileCache.shared.localURL(for: remoteURL, cacheKey: message.id)
                    try await writeToPhotoLibrary(localURL: localURL, isVideo: message.contentType == .video)
                    savedCount += 1
                } catch {
                    continue
                }
            }
            isSavingMedia = false

            saveMediaResultMessage = savedCount == group.count
                ? "Saved to Photos."
                : savedCount == 0
                    ? "Couldn't save — check your connection and try again."
                    : "Saved \(savedCount) of \(group.count) items. The rest couldn't be downloaded."
        }
    }

    private func requestPhotoLibraryAddPermission() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return status == .authorized || status == .limited
        default:
            return false
        }
    }

    private func writeToPhotoLibrary(localURL: URL, isVideo: Bool) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            if isVideo {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: localURL)
            } else {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: localURL)
            }
        }
    }

    private func exportFile(_ message: BackendMessage) {
        Task {
            guard let urlString = message.mediaUrl, let remoteURL = URL(string: urlString) else {
                saveMediaResultMessage = "Couldn't find this file to save."
                return
            }
            isSavingMedia = true
            defer { isSavingMedia = false }
            do {
                let cachedURL = try await MediaFileCache.shared.localURL(for: remoteURL, cacheKey: message.id)
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(cachedURL.lastPathComponent)
                try? FileManager.default.removeItem(at: tempURL)
                try FileManager.default.copyItem(at: cachedURL, to: tempURL)
                exportingFileURL = tempURL
            } catch {
                saveMediaResultMessage = "Couldn't download this file to save."
            }
        }
    }

    private func presentReactionSummary(for message: BackendMessage, includeReactions: Bool = true, includeDeliveryInfo: Bool = true) {
        reactionSummaryMessage = message
        reactionSummaryIncludesReactions = includeReactions
        reactionSummaryIncludesDelivery = includeDeliveryInfo
        highlightedMessageId = message.id
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if includeDeliveryInfo && message.senderId == currentUserId {
            Task { await viewModel.fetchMessageReceipts(messageId: message.id) }
        }
    }

    private var isLargeGroup: Bool {
        guard viewModel.isGroup ?? false else { return false }
        let current = viewModel.groupParticipants.filter { $0.leftAt == nil }.count
        return current > MessageInfoView.largeGroupThreshold
    }

    private func dismissReactionSummary() {
        reactionSummaryMessage = nil
        highlightedMessageId = nil
    }

    private func scrollToLatestMessage() {
        guard let lastId = viewModel.messages.last?.id else { return }
        hasScrolledOnLoad = true
        scrollToMessageId = lastId
    }

    private var messageList: some View {
        ConversationMessageList(
            conversationId: viewModel.conversationId,
            messages: viewModel.messages,
            currentUserId: currentUserId,
            isLoadingOlder: viewModel.isLoadingOlder,
            hasMoreOlderMessages: viewModel.hasMoreOlderMessages,
            highlightedMessageId: highlightedMessageId,
            otherDisplayName: viewModel.otherDisplayName,
            senderDisplayName: viewModel.isGroup ?? false ? { viewModel.groupParticipantDisplayNames[$0] ?? $0 } : nil,
            replyPreview: replyPreviewInfo(for:),
            liveOverride: liveOverride(for:),
            receiptState: receiptState(for:),
            readByAvatars: readReceiptAvatars(for:),
            onOpenBit: { viewModel.openBit(messageId: $0) },
            onTapMedia: { id in
                guard let message = viewModel.messages.first(where: { $0.id == id }) else { return }
                MediaGalleryPresenter.present(messages: [message], startIndex: 0)
            },
            onTapMediaGroup: { group, startIndex in
                MediaGalleryPresenter.present(messages: group, startIndex: startIndex)
            },
            onLoadOlder: { Task { await viewModel.loadOlderMessages() } },
            onReplyTap: { scrollToReply($0) },
            onSwipeToReply: { replyingTo = $0 },
            onResendGroup: { viewModel.resendGroup($0) },
            onLongPressMessage: { message, frame in
                guard message.contentType != .bit else { return }
                reactingToMessage = message
                reactingToMessageFrame = frame
            },
            onShowReactionSummary: { message in
                if MessageReactionInfoView.shouldPresent(for: message) {
                    reactionInfoMessage = message
                    showingReactionInfo = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } else {
                    presentReactionSummary(for: message, includeDeliveryInfo: false)
                }
            },
            onToggleReaction: { message, emoji in viewModel.toggleReaction(on: message.id, emoji: emoji) },
            canReact: reactionsEnabled,
            scrollToMessageId: $scrollToMessageId,
            isNearBottom: $isNearBottom
        )
        .overlay(alignment: .bottomTrailing) {
            if !isNearBottom {
                scrollToBottomButton
            }
        }
        .animation(.easeOut(duration: 0.18), value: isNearBottom)
        .modifier(LiveMapCover(conversationId: viewModel.conversationId, viewModel: viewModel))
    }

    private var scrollToBottomButton: some View {
        Button(action: scrollToLatestMessage) {
            Image(systemName: "chevron.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.primary)
                .frame(width: 36, height: 36)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.black.opacity(0.06)))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .padding(.trailing, 14)
        .padding(.bottom, 10)
        .transition(.opacity.combined(with: .scale(scale: 0.85)))
    }

    private func liveOverride(for message: BackendMessage) -> (lat: Double, lng: Double)? {
        guard message.contentType == .location,
              message.mediaMetadata?.isLiveLocation == true,
              viewModel.isGroup
                  ? message.senderId != AuthService.shared.user?.id
                  : message.senderId == viewModel.otherParticipantId,
              (message.expiresAt.map { $0 > Date() } ?? true)
        else { return nil }
        if viewModel.isGroup {
            return LiveLocationPositions.shared
                .latest[LiveLocationPositions.key(message.conversationId, message.senderId)]
                .map { ($0.lat, $0.lng) }
        }
        return viewModel.incomingLiveLocation
    }

    private func receiptState(for message: BackendMessage) -> MessageReceiptState {
        if let live = viewModel.messageReceipts[message.id] {
            return live
        }
        if !(viewModel.isGroup ?? false), message.opened { return .opened }
        if message.delivered { return .delivered }
        return .sent
    }

    private func readReceiptAvatars(for message: BackendMessage) -> [ReadReceiptAvatarsView.Reader] {
        guard message.senderId == currentUserId else { return [] }
        if viewModel.isGroup ?? false {
            return viewModel.groupReadCursors
                .filter { userId, cursor in
                    userId != currentUserId && cursor.messageId == message.id
                }
                .map { userId, cursor in
                    ReadReceiptAvatarsView.Reader(
                        id: userId,
                        displayName: viewModel.groupParticipantDisplayNames[userId] ?? userId,
                        profileImageUrl: viewModel.groupParticipantProfileImageUrls[userId],
                        readAt: cursor.readAt
                    )
                }
                .sorted { $0.displayName < $1.displayName }
        } else {
            guard message.id == lastReadMessageId else { return [] }
            return [
                ReadReceiptAvatarsView.Reader(
                    id: viewModel.otherParticipantId,
                    displayName: viewModel.otherDisplayName ?? viewModel.otherParticipantId,
                    profileImageUrl: viewModel.otherProfileImageUrl,
                    readAt: message.openedAt
                )
            ]
        }
    }

    private var lastReadMessageId: String? {
        viewModel.messages.last(where: { $0.senderId == currentUserId && $0.opened })?.id
    }

    private func deliveryDetails(for message: BackendMessage) -> [(reader: ReadReceiptAvatarsView.Reader, deliveredAt: Date?, readAt: Date?)] {
        viewModel.deliveryDetails(for: message.id)
            .map { entry in
                let reader = ReadReceiptAvatarsView.Reader(
                    id: entry.userId,
                    displayName: entry.displayName,
                    profileImageUrl: entry.profileImageUrl
                )
                return (reader, entry.deliveredAt, entry.readAt)
            }
            .sorted { $0.reader.displayName < $1.reader.displayName }
    }

    private func replyPreviewInfo(for message: BackendMessage) -> ReplyPreviewInfo? {
        guard let replyId = message.replyToMessageId,
              let original = viewModel.messages.first(where: { $0.id == replyId }) else { return nil }
        let originalIsMine = original.senderId == currentUserId
        let name: String
        if originalIsMine {
            name = "Me"
        } else if viewModel.isGroup ?? false {
            name = viewModel.groupParticipantDisplayNames[original.senderId] ?? original.senderId
        } else {
            name = viewModel.otherDisplayName ?? original.senderId
        }
        return ReplyPreviewInfo(
            senderId: original.senderId,
            senderName: name,
            isMine: originalIsMine,
            text: original.deletedAt != nil
                ? "This message was deleted"
                : (original.textContent ?? original.contentType.rawValue.capitalized),
            sentAt: original.createdAt
        )
    }

    private func scrollToReply(_ message: BackendMessage) {
        guard let replyId = message.replyToMessageId else { return }
        scrollToMessageId = replyId
        highlightedMessageId = replyId
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            highlightedMessageId = nil
        }
    }

    private var typingIndicator: some View {
        HStack(spacing: 6) {
            if viewModel.isGroup ?? false, let text = viewModel.typingIndicatorText {
                HStack(spacing: 6) {
                    Text(text)
                        .font(.appFont(fontStyle: .caption2, fontWeight: .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    TypingDotsView()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.gray.opacity(0.15), in: Capsule())
            } else {
                TypingDotsView()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.gray.opacity(0.15), in: Capsule())
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private var uploadStatusBar: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if uploadFileTotal > 1 {
                Text("\(uploadFileIndex)/\(uploadFileTotal)")
                    .font(.appFont(fontStyle: .caption2, fontWeight: .medium))
                    .foregroundColor(.secondary)
            }
            ProgressView(value: uploadProgress)
                .progressViewStyle(.linear)
        }
        .padding(.horizontal, 12)
    }

    private var canReply: Bool {
        viewModel.myStatus == .accepted
    }

    private var showSendRequestBanner: Bool {
        viewModel.myStatus == .accepted && viewModel.otherStatus == .pending
    }

    private var hasSentRequestMessage: Bool {
        viewModel.messages.contains { $0.contentType != .system }
    }

    private var sendRequestBanner: some View {
        Text(hasSentRequestMessage ? "Message Request Pending" : "Send Message Request")
            .font(.appFont(fontStyle: .caption, fontWeight: .semibold))
            .foregroundColor(.orange)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.12))
    }

    private var pendingRequestBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(viewModel.otherDisplayName ?? "This person") isn't in your connections yet. Accept to reply, or decline to remove this conversation.")
                .font(.appFont(fontStyle: .footnote))
                .foregroundColor(.gray)
            HStack(spacing: 12) {
                Button {
                    isResolvingRequest = true
                    Task {
                        defer { isResolvingRequest = false }
                        if await viewModel.declineRequest() {
                            dismiss()
                        }
                    }
                } label: {
                    Text("Decline")
                        .font(.appFont(fontStyle: .footnote, fontWeight: .semibold))
                        .foregroundColor(.red)
                }
                Spacer()
                Button {
                    viewModel.acceptRequest()
                } label: {
                    Text("Accept")
                        .font(.appFont(fontStyle: .footnote, fontWeight: .semibold))
                        .foregroundColor(.blue)
                }
            }
        }
        .disabled(isResolvingRequest)
        .padding()
        .background(.thinMaterial)
    }

    private var groupDeletedBanner: some View {
        Text("This group was deleted. No new messages can be sent.")
            .font(.appFont(fontStyle: .footnote))
            .foregroundColor(.gray)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding()
            .background(.thinMaterial)
    }

    private var leftGroupBanner: some View {
        Text("Only participants can send messages in this group.")
            .font(.appFont(fontStyle: .footnote))
            .foregroundColor(.gray)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding()
            .background(.thinMaterial)
    }

    private var blockedBanner: some View {
        Text("You've blocked \(viewModel.otherDisplayName ?? "this person"). Unblock to send messages.")
            .font(.appFont(fontStyle: .footnote))
            .foregroundColor(.gray)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding()
            .background(.thinMaterial)
    }

    private func sendVoiceMessage(url: URL, durationMs: Int64) async {
        uploadInProgress = true
        defer {
            uploadInProgress = false
            try? FileManager.default.removeItem(at: url)
        }
        do {
            let body = try await ChatMediaUploader.shared.uploadForConversation(viewModel.conversationId) {
                try await ChatMediaUploader.shared.uploadVoiceMessage(fileURL: url, durationMs: durationMs) { progress in
                    Task { @MainActor in uploadProgress = progress }
                }
            }
            viewModel.sendMedia(body)
            scrollToLatestMessage()
        } catch {
            print("DEBUG: failed to upload/send voice message: \(error)")
            viewModel.errorMessage = "Couldn't send voice message"
        }
    }

    private func sendAttachments(_ attachments: [PendingAttachment]) async {
        guard !attachments.isEmpty else { return }
        uploadInProgress = true
        uploadFileTotal = attachments.count
        defer {
            uploadInProgress = false
            uploadFileIndex = 0
            uploadFileTotal = 0
        }

        for (offset, attachment) in attachments.enumerated() {
            uploadFileIndex = offset + 1
            uploadProgress = 0
            do {
                let body: SendMessageRequestBody
                switch attachment {
                case .image(let image):
                    body = try await ChatMediaUploader.shared.uploadForConversation(viewModel.conversationId) {
                        try await ChatMediaUploader.shared.uploadImage(image) { progress in
                            Task { @MainActor in uploadProgress = progress }
                        }
                    }
                case .video(let url):
                    defer { try? FileManager.default.removeItem(at: url) }
                    body = try await ChatMediaUploader.shared.uploadForConversation(viewModel.conversationId) {
                        try await ChatMediaUploader.shared.uploadVideo(fileURL: url) { progress in
                            Task { @MainActor in uploadProgress = progress }
                        }
                    }
                case .file(let url, let mimeType, _):
                    defer { try? FileManager.default.removeItem(at: url) }
                    body = try await ChatMediaUploader.shared.uploadForConversation(viewModel.conversationId) {
                        try await ChatMediaUploader.shared.uploadFile(fileURL: url, mimeType: mimeType) { progress in
                            Task { @MainActor in uploadProgress = progress }
                        }
                    }
                }
                viewModel.sendMedia(body)
            } catch {
                print("DEBUG: failed to upload/send attachment: \(error)")
                if case let NetworkError.serverError(_, message) = error {
                    viewModel.errorMessage = message
                } else if let uploadError = error as? ChatMediaUploadError {
                    viewModel.errorMessage = uploadError.errorDescription ?? "Couldn't send attachment"
                } else {
                    viewModel.errorMessage = "Couldn't send attachment"
                }
            }
        }
        scrollToLatestMessage()
    }

    private func sendBit(_ captured: CapturedBit) async {
        uploadInProgress = true
        defer { uploadInProgress = false }
        do {
            let body = try await ChatMediaUploader.shared.uploadForConversation(viewModel.conversationId) {
                try await ChatMediaUploader.shared.uploadBit(captured) { progress in
                    Task { @MainActor in uploadProgress = progress }
                }
            }
            viewModel.sendMedia(body)
            scrollToLatestMessage()
        } catch {
            print("DEBUG: failed to upload/send bit: \(error)")
            viewModel.errorMessage = "Couldn't send — try again"
        }
    }

    private var callsEnabled: Bool {
        !(viewModel.isGroup ?? false) && viewModel.myStatus == .accepted && viewModel.otherStatus == .accepted
    }

    private var reactionsEnabled: Bool {
        !((viewModel.isGroup ?? false) && viewModel.selfHasLeftGroup) && !viewModel.isBlocked
    }

    private func tapCall(_ type: CallType) {
        guard !viewModel.isBlocked else { return }
        guard callsEnabled else {
            showPendingCallAlert = true
            return
        }
        startCall(type)
    }

    private func startCall(_ type: CallType) {
        CallManager.shared.startCall(conversationId: viewModel.conversationId, calleeId: viewModel.otherParticipantId, calleeName: viewModel.otherDisplayName!, type: type)
    }

}

private struct ConversationHeaderView: View {
    let otherParticipantId: String
    let displayName: String?
    let profileImageUrl: String?
    let presence: PresenceInfo
    let isOtherTyping: Bool
    @StateObject private var directory = ChatParticipantDirectory.shared

    private var resolvedDisplayName: String {
        displayName ?? directory.displayName(for: otherParticipantId) ?? otherParticipantId
    }

    var body: some View {
        HStack(spacing: 8) {
            avatarWithPresenceDot

            VStack(alignment: .leading, spacing: 1) {
                Text(resolvedDisplayName)
                    .font(.appFont(fontStyle: .title3, fontWeight: .bold))
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .font(.appFont(fontStyle: .caption2, fontWeight: .regular))
                        .foregroundColor(isOtherTyping ? .accentColor : .secondary)
                }
            }
        }
    }

    private var avatarWithPresenceDot: some View {
        ChatAvatarView(
            imageURLString: profileImageUrl ?? directory.avatarURL(for: otherParticipantId)?.absoluteString,
            seed: otherParticipantId,
            displayName: resolvedDisplayName,
            size: 40
        )
        
    }

    private var subtitle: String? {
        if isOtherTyping { return "typing…" }
        if presence.online == true { return "Online" }
        if let lastSeen = presence.lastSeen {
            return "Last seen \(Self.relativeFormatter.localizedString(for: lastSeen, relativeTo: Date()))"
        }
        return nil
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.dateTimeStyle = .named
        return f
    }()
}

private struct GroupConversationHeaderView: View {
    let groupName: String?
    let groupImageUrl: String?
    let avatarSeed: String
    let isDeleted: Bool
    var hasLeft: Bool = false
    var typingIndicatorText: String? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            ChatAvatarView(
                imageURLString: groupImageUrl,
                seed: avatarSeed,
                displayName: groupName ?? "Group",
                size: 40
            )
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 18, height: 18)
                    .overlay(
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(scheme == .dark ? .black : .white)
                    )
                    .overlay(Circle().strokeBorder(Color.theme.primaryBackground, lineWidth: 2))
                    .offset(x: 3, y: 3)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(groupName ?? "Group")
                    .font(.appFont(fontStyle: .title3, fontWeight: .bold))
                    .lineLimit(1)
                if isDeleted {
                    Text("Group deleted")
                        .font(.appFont(fontStyle: .caption2, fontWeight: .regular))
                        .foregroundColor(.secondary)
                } else if hasLeft {
                    Text("You left this group")
                        .font(.appFont(fontStyle: .caption2, fontWeight: .regular))
                        .foregroundColor(.secondary)
                } else if let typingIndicatorText {
                    HStack(spacing: 4) {
                        Text(typingIndicatorText)
                            .font(.appFont(fontStyle: .caption2, fontWeight: .regular))
                            .foregroundColor(.accentColor)
                            .lineLimit(1)
                        TypingDotsView()
                    }
                }
            }
        }
    }
}

struct LiveMapCover: ViewModifier {
    let conversationId: String
    let viewModel: ConversationViewModel
    @ObservedObject private var presenter = LiveMapPresenter.shared

    private enum Destination: Identifiable {
        case single(LiveMapRequest)
        case group(GroupLiveMapRequest)
        var id: UUID {
            switch self {
            case .single(let r): return r.id
            case .group(let r): return r.id
            }
        }
    }

    private var destination: Binding<Destination?> {
        Binding<Destination?>(
            get: {
                if let g = presenter.groupRequest, g.conversationId == conversationId { return .group(g) }
                if let r = presenter.request, r.conversationId == conversationId { return .single(r) }
                return nil
            },
            set: { newValue in
                guard newValue == nil else { return }
                if presenter.groupRequest?.conversationId == conversationId { presenter.groupRequest = nil }
                if presenter.request?.conversationId == conversationId { presenter.request = nil }
            }
        )
    }

    func body(content: Content) -> some View {
        content.fullScreenCover(item: destination) { dest in
            switch dest {
            case .single(let request):
                LiveLocationMapView(request: request)
            case .group(let request):
                LiveLocationGroupMapView(
                    conversationId: request.conversationId,
                    title: viewModel.groupName ?? "Live Locations",
                    sharers: groupSharers(),
                    focusUserId: request.focusUserId
                )
            }
        }
    }

    private func groupSharers() -> [GroupLiveSharer] {
        let me = AuthService.shared.user?.backendId
        var order: [String] = []
        var latest: [String: BackendMessage] = [:]
        for m in viewModel.messages
        where m.contentType == .location
            && m.mediaMetadata?.isLiveLocation == true
            && (m.expiresAt.map { $0 > Date() } ?? true)
            && !m.id.hasPrefix("pending-") {
            if latest[m.senderId] == nil { order.append(m.senderId) }
            latest[m.senderId] = m
        }
        return order.compactMap { id in
            guard let m = latest[id] else { return nil }
            let mine = id == me
            let initial = m.mediaMetadata.flatMap { md -> LiveCoordinate? in
                guard let lat = md.lat, let lng = md.lng else { return nil }
                return LiveCoordinate(lat: lat, lng: lng)
            }
            return GroupLiveSharer(
                userId: id,
                name: mine ? "You" : (viewModel.groupParticipantDisplayNames[id] ?? "Member"),
                isMine: mine,
                endsAt: m.expiresAt,
                initial: initial
            )
        }
    }
}

struct LocationBubbleContent: View {
    let message: BackendMessage
    let isMine: Bool
    let liveOverride: (lat: Double, lng: Double)?
    var senderName: String? = nil

    @ObservedObject private var positions = LiveLocationPositions.shared
    @State private var camera: MapCameraPosition

    init(message: BackendMessage, isMine: Bool, liveOverride: (lat: Double, lng: Double)?, senderName: String? = nil) {
        self.message = message
        self.isMine = isMine
        self.liveOverride = liveOverride
        self.senderName = senderName
        if let lat = message.mediaMetadata?.lat, let lng = message.mediaMetadata?.lng {
            _camera = State(initialValue: Self.region(LiveCoordinate(lat: lat, lng: lng)))
        } else {
            _camera = State(initialValue: .automatic)
        }
    }

    private static func region(_ c: LiveCoordinate) -> MapCameraPosition {
        .region(MKCoordinateRegion(
            center: c.clCoordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        ))
    }

    private var staticCoordinate: LiveCoordinate? {
        guard let lat = message.mediaMetadata?.lat, let lng = message.mediaMetadata?.lng else { return nil }
        return LiveCoordinate(lat: lat, lng: lng)
    }

    private var livePosition: LiveCoordinate? {
        guard isLive else { return nil }
        return positions.latest[LiveLocationPositions.key(message.conversationId, message.senderId)]
    }

    private var coordinate: LiveCoordinate? {
        if let livePosition { return livePosition }
        if let liveOverride { return LiveCoordinate(lat: liveOverride.lat, lng: liveOverride.lng) }
        return staticCoordinate
    }

    private var isLive: Bool {
        message.mediaMetadata?.isLiveLocation == true
            && (message.expiresAt.map { $0 > Date() } ?? true)
    }

    var body: some View {
        Button {
            handleTap()
        } label: {
            ZStack(alignment: .topLeading) {
                if let coordinate {
                    Map(position: $camera) {
                        Marker("", coordinate: coordinate.clCoordinate)
                    }
                    .allowsHitTesting(false)
                } else {
                    Color.gray.opacity(0.2)
                }

                if isLive {
                    Label("Live", systemImage: "location.fill")
                        .font(.appFont(fontStyle: .caption2, fontWeight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.red, in: Capsule())
                        .padding(6)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: 220, height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            if let coordinate { camera = Self.region(coordinate) }
        }
        .onChange(of: coordinate) { _, new in
            guard let new else { return }
            withAnimation(.easeInOut(duration: 1.0)) { camera = Self.region(new) }
        }
    }

    private func handleTap() {
        guard let coordinate else { return }
        if isLive, senderName != nil {
            LiveMapPresenter.shared.groupRequest = GroupLiveMapRequest(
                conversationId: message.conversationId,
                focusUserId: message.senderId
            )
        } else if isLive {
            LiveMapPresenter.shared.request = LiveMapRequest(
                conversationId: message.conversationId,
                userId: message.senderId,
                title: isMine ? "Your Live Location"
                    : (senderName.map { "\($0)'s Live Location" } ?? "Live Location"),
                isMine: isMine,
                initial: coordinate,
                endsAt: message.expiresAt
            )
        } else {
            openInMaps(coordinate)
        }
    }

    private func openInMaps(_ coordinate: LiveCoordinate) {
        let url = URL(string: "maps://?ll=\(coordinate.lat),\(coordinate.lng)")
        if let url, UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }
}
private enum BitPalette {
    static let lavender = Color(red: 0.80, green: 0.73, blue: 0.97)
    static let skyBlue  = Color(red: 0.68, green: 0.84, blue: 0.98)
    static let ink      = Color(red: 0.24, green: 0.22, blue: 0.42)
}

struct BitBubbleContent: View {
    let message: BackendMessage
    var isMine: Bool { return AuthService.shared.user?.id == message.senderId }
    let receiptState: MessageReceiptState
    let onOpenBit: (String) -> Void
    @ObservedObject private var prefetchCache = BitPrefetchCache.shared
 
    private var isReadyToView: Bool {
        isMine || prefetchCache.isReady(message.id)
    }
 
    private var loadingProgress: Double? {
        guard !isMine, !isReadyToView else { return nil }
        return prefetchCache.progress[message.id]
    }
 
    private var isExpired: Bool {
        if isMine {
            return hasBeenOpenedByReceiver
                || message.deletedAt != nil
                || message.mediaUrl == nil
        }
        return message.deletedAt != nil
            || (message.expiresAt.map { $0 <= Date() } ?? false)
            || message.mediaUrl == nil
    }

    private var hasBeenOpenedByReceiver: Bool {
        message.opened || receiptState == .opened
    }
 
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Group {
                    if let loadingProgress, !isExpired {
                        ProgressView(value: loadingProgress)
                            .progressViewStyle(.circular)
                            .tint(BitPalette.ink)
                    } else {
                        Image(systemName: isExpired ? "bolt.slash.circle" : "bolt.circle.fill")
                    }
                }
                .frame(width: 18, height: 18)
 
                Text(labelText)
            }
            .font(.appFont(fontStyle: .subheadline, fontWeight: .medium))
            .foregroundColor(BitPalette.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                LinearGradient(
                    colors: [BitPalette.lavender, BitPalette.skyBlue],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 18)
            )
        }
        .contentShape(Rectangle())
        .overlay(
            HoldToViewGesture(
                onBegan: {
                    guard !isExpired, isReadyToView, !BitPlayerPresenter.shared.isPresenting else { return }
                    BitPlayerPresenter.shared.present(message: message, isMine: isMine, onReveal: onOpenBit)
                },
                onEnded: {
                    BitPlayerPresenter.shared.dismiss()
                }
            )
        )
    }
 
    private var labelText: String {
        if isMine { return statusText }
        if let loadingProgress, !isExpired {
            return "Loading… \(Int((loadingProgress * 100).rounded()))%"
        }
        return isExpired ? "Bit expired" : "Hold to view"
    }
 
    private var statusText: String {
        switch receiptState {
        case .sending: return "Sending bit…"
        case .sent: return "Bit sent"
        case .delivered: return "Bit delivered"
        case .opened: return "Bit opened"
        case .failed: return "Bit not sent"
        }
    }
}

private struct HoldToViewGesture: UIViewRepresentable {
    var minimumDuration: TimeInterval = 0.12
    var allowableMovement: CGFloat = 10
    let onBegan: () -> Void
    let onEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onBegan: onBegan, onEnded: onEnded)
    }

    private final class HostView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { BitPlayerPresenter.shared.watch(window) }
        }
    }

    func makeUIView(context: Context) -> UIView {
        let view = HostView()
        view.backgroundColor = .clear
        let press = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:))
        )
        press.minimumPressDuration = minimumDuration
        press.allowableMovement = allowableMovement
        press.delegate = context.coordinator
        view.addGestureRecognizer(press)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onBegan = onBegan
        context.coordinator.onEnded = onEnded
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onBegan: () -> Void
        var onEnded: () -> Void

        init(onBegan: @escaping () -> Void, onEnded: @escaping () -> Void) {
            self.onBegan = onBegan
            self.onEnded = onEnded
        }

        @objc func handle(_ press: UILongPressGestureRecognizer) {
            switch press.state {
            case .began: onBegan()
            case .ended: onEnded()
            default: break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            !(other.view is UIScrollView)
        }
    }
}

struct PulsingRecordDot: View {
    @State private var visible = true
    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 10, height: 10)
            .opacity(visible ? 1 : 0.3)
            .onAppear {
                Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
                    withAnimation { visible.toggle() }
                }
            }
    }
}

struct VoiceLevelMeterView: View {
    let level: CGFloat
    private let barMultipliers: [CGFloat] = [0.4, 0.7, 1.0, 0.6, 0.3]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barMultipliers.count, id: \.self) { i in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: max(3, 18 * level * barMultipliers[i]))
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.1), value: level)
    }
}

struct ReplyComposerBar: View {
    let message: BackendMessage
    let onCancel: () -> Void
    var body: some View {
        HStack {
            Rectangle().fill(Color.accentColor).frame(width: 3)
            VStack(alignment: .leading) {
                Text("Replying to")
                    .font(.appFont(fontStyle: .caption2))
                    .foregroundColor(.gray)
                    .lineLimit(1)
                Text(message.textContent ?? message.contentType.rawValue.capitalized)
                    .font(.appFont(fontStyle: .caption))
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill").foregroundColor(.gray)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxHeight: 44)
        .clipped()
        .background(Color.gray.opacity(0.08))
    }
}

final class FullWidthPopPanGestureRecognizer: UIPanGestureRecognizer {}

extension UINavigationController: UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
        installFullWidthPopGesture()
    }

    private func installFullWidthPopGesture() {
        guard let edgePop = interactivePopGestureRecognizer,
              let container = edgePop.view,
              !(container.gestureRecognizers ?? []).contains(where: { $0 is FullWidthPopPanGestureRecognizer })
        else { return }

        guard let targets = edgePop.value(forKey: "targets") as? [AnyObject],
              let wrapper = targets.first,
              let target = wrapper.value(forKey: "target"),
              case let action = NSSelectorFromString("handleNavigationTransition:"),
              (target as AnyObject).responds(to: action)
        else { return }

        let pan = FullWidthPopPanGestureRecognizer(target: target, action: action)
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        container.addGestureRecognizer(pan)
        edgePop.isEnabled = false
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard viewControllers.count > 1, transitionCoordinator == nil else { return false }
        if let pan = gestureRecognizer as? FullWidthPopPanGestureRecognizer {
            let v = pan.velocity(in: pan.view)
            let isRTL = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
            let horizontal = abs(v.x) > abs(v.y)
            return horizontal && (isRTL ? v.x < 0 : v.x > 0)
        }
        return true
    }
}
