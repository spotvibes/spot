import CallKit
import WebRTC
import Foundation
import AVFoundation
import Combine
import UIKit

@MainActor
final class CallManager: NSObject, ObservableObject {
    static let shared = CallManager()

    enum CallDirection: Equatable { case outgoing, incoming }

    enum CallState: Equatable {
        case idle
        case ringing(direction: CallDirection)
        case connecting
        case connected(since: Date)
        case ended(reason: String)
    }

    @Published private(set) var callState: CallState = .idle
    @Published private(set) var callType: CallType = .voice
    @Published private(set) var isMuted = false
    @Published private(set) var isSpeakerOn = false
    @Published private(set) var micPermissionDenied = false
    @Published private(set) var isReconnecting = false
    private var isRecovering = false
    private var reconnectBannerTask: Task<Void, Never>?
    private let reconnectBannerDelayNanos: UInt64 = 2_500_000_000

    private func beginRecovery(showBannerImmediately: Bool = false) {
        isRecovering = true
        reconnectBannerTask?.cancel()
        if showBannerImmediately {
            isReconnecting = true
            return
        }
        reconnectBannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.reconnectBannerDelayNanos ?? 2_500_000_000)
            guard let self, !Task.isCancelled, self.isRecovering else { return }
            self.isReconnecting = true
        }
    }

    private func endRecovery() {
        isRecovering = false
        reconnectBannerTask?.cancel()
        reconnectBannerTask = nil
        isReconnecting = false
    }
    @Published private(set) var isVideoStalled = false
    @Published private(set) var outgoingCallConfirmedReaching = false
    @Published var localVideoTrack: RTCVideoTrack?
    @Published var remoteVideoTrack: RTCVideoTrack?
    @Published private(set) var networkQuality: CallNetworkQuality = .good
    @Published private(set) var otherPartyId: String?
    @Published private(set) var otherPartyName: String?
    @Published private(set) var isFrontCamera = true
    @Published private(set) var isVideoEnabled = true
    @Published private(set) var isRemoteVideoEnabled = true
    private var activeBackendCallId: String?
    private var activeCXCallUUID: UUID?
    private var activeConversationId: String?
    private var hasActiveCall = false {
        didSet { ChatWebSocketClient.shared.callPriorityMode = hasActiveCall }
    }
    private(set) var isHandlingBackgroundIncomingCallLaunch = false
    private var presenceCorrectionTask: Task<Void, Never>?
    private var callDirection: CallDirection?
    private var remoteHasAnswered = false
    private var mediaConnectedPendingAnswer = false
    private var ringbackPlayer: AVAudioPlayer?
    private var incomingRingtonePlayer: AVAudioPlayer?

    private var pendingOutgoingTurnCredentials: TurnCredentials?

    private var prefetchedTurnCredentials: [String: TurnCredentials] = [:]
    private var turnPrefetchTasks: [String: Task<Void, Never>] = [:]

    private var isObservingSignaling = false
    private var pendingRemoteOfferSDP: String?
    private var pendingRemoteIceCandidates: [(sdpMid: String?, sdpMLineIndex: Int32, candidate: String, enqueuedAt: Date)] = []
    private var isFlushingRemoteCandidates = false

    private var pendingCriticalSignal: (callId: String, text: String)?
    private var e2eeSignalTail: Task<Void, Never>?

    private struct PendingTerminalStatus: Codable, Equatable {
        let callId: String
        let statusRaw: String
    }
    private static let pendingTerminalStatusDefaultsKey = "pendingTerminalCallStatus"
    private var pendingTerminalStatus: PendingTerminalStatus?
    private var sentIceCandidateSignals: [String] = []
    private var lastAppliedRemoteOfferSDP: String?
    private var appliedRemoteOfferSDPs = Set<String>()
    private var wsReconnectObservation: Task<Void, Never>?
    private var wsReadySignalObservation: Task<Void, Never>?

    private let ringTimeoutSeconds: UInt64 = 50
    private var ringTimeoutTask: Task<Void, Never>?

    private let connectTimeoutSeconds: UInt64 = 20
    private var connectTimeoutTask: Task<Void, Never>?
    private var connectRelayFallbackAttempted = false
    private var reconnectRelayFallbackAttempted = false

    private let reconnectGraceSeconds: UInt64 = 15
    private var reconnectGraceTask: Task<Void, Never>?

    private let heartbeatIntervalSeconds: UInt64 = 20
    private var heartbeatTask: Task<Void, Never>?

    private let reconnectRestartDebounceSeconds: UInt64 = 2
    private var reconnectRestartDebounceTask: Task<Void, Never>?

    private let proactiveRestartDebounceSeconds: UInt64 = 6
    private var proactiveRestartDebounceTask: Task<Void, Never>?
    private var proactiveRestartAttempted = false

    private let webRTC = WebRTCClient()
    private lazy var networkPathChangeGuard = NetworkPathChangeGuard(
        isCallConnected: { [weak self] in
            guard case .connected = self?.callState else { return false }
            return true
        },
        receivedAudioPackets: { [weak self] in
            await self?.webRTC.audioFlow()?.received
        },
        iceIsConnected: { [weak self] in
            self?.webRTC.currentIceConnectionState == .connected
        },
        onConfirmedDrop: { [weak self] in
            self?.handleConnectionStateChange(.reconnecting)
        }
    )
    private var provider: CXProvider { CallKitProviderHolder.shared.provider }
    private let callController = CXCallController()

    private override init() {
        super.init()

        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.useManualAudio = true
        rtcSession.isAudioEnabled = false

        wireWebRTCCallbacks()
        observeWebSocketReconnects()
        restorePendingTerminalStatusFromDisk()
        observePendingTerminalStatusRetries()
        startObservingSignaling()
        if CallKitPolicy.isAvailable {
            provider.setDelegate(self, queue: nil)
        }
        WebRTCClient.warmUpNetworkMonitor()
        observeAudioRouteChanges()
    }

    func startObservingSignaling() {
        guard !isObservingSignaling else { return }
        isObservingSignaling = true
        ChatWebSocketClient.shared.onEvent.append { [weak self] event in
            guard let self else { return }
            Task { @MainActor in
                switch event {
                case .incomingCall(let callId, let conversationId, let callerId, let callerName, let type):
                    self.reportIncomingCall(callId: callId, conversationId: conversationId, callerId: callerId, callerName: callerName, type: type)
                case .callStatusChanged(let callId, let conversationId, let status):
                    self.handleCallStatusChanged(callId: callId, conversationId: conversationId, status: status)
                case .callSignal(let callId, var payload):
                    if payload["e2ee"] != nil {
                        guard var plain = E2EEService.shared.decryptEphemeral(frameField: payload["e2ee"]) else { return }
                        if plain["type"] == nil { plain["type"] = payload["type"] }
                        payload = plain
                    }
                    self.handleSignal(callId: callId, payload: payload)
                case .callRinging(let callId, _):
                    guard self.callDirection == .outgoing, callId == self.activeBackendCallId else { return }
                    self.outgoingCallConfirmedReaching = true
                default:
                    break
                }
            }
        }
    }

    private func startTurnPrefetch(callId: String) {
        turnPrefetchTasks[callId]?.cancel()
        turnPrefetchTasks[callId] = Task { [weak self] in
            guard let creds = try? await self?.fetchTurnCredentialsResilient(callId: callId) else { return }
            guard let self, !Task.isCancelled else { return }
            self.prefetchedTurnCredentials[callId] = creds
        }
    }

    private func fetchTurnCredentialsResilient(callId: String, attempts: Int = 3) async throws -> TurnCredentials {
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                return try await NetworkService.shared.fetchTurnCredentials(callId: callId)
            } catch {
                lastError = error
                guard attempt < attempts - 1 else { break }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        throw lastError ?? NetworkError.serverError(statusCode: 0, message: "TURN credential fetch failed")
    }

    private func createCallResilient(conversationId: String, callType: CallType, attempts: Int = 3) async throws -> CallCreated {
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                return try await NetworkService.shared.createCall(conversationId: conversationId, callType: callType)
            } catch {
                lastError = error
                guard attempt < attempts - 1 else { break }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        throw lastError ?? NetworkError.serverError(statusCode: 0, message: "Failed to start call")
    }

    private func wireWebRTCCallbacks() {
        webRTC.onRemoteVideoTrack = { [weak self] track in self?.remoteVideoTrack = track }
        webRTC.onRemoteVideoTrackRemoved = { [weak self] in self?.remoteVideoTrack = nil }
        webRTC.onLocalVideoTrack = { [weak self] track in self?.localVideoTrack = track }
        webRTC.onRemoteVideoStalled = { [weak self] in
            Task { @MainActor in self?.handleRemoteVideoStalled() }
        }
        webRTC.onRemoteVideoRecovered = { [weak self] in
            Task { @MainActor in self?.isVideoStalled = false }
        }
        webRTC.onRemoteParticipantDisconnected = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.endCall(reportToCallKit: true, cxReason: .remoteEnded, displayReason: "Call ended")
            }
        }
        webRTC.onResolutionRungChanged = { label in
            print("DEBUG: CallManager video resolution rung -> \(label)")
        }
        webRTC.onConnectionStateChange = { [weak self] state in
            Task { @MainActor in self?.handleConnectionStateChange(state) }
        }
        webRTC.onNetworkQualityChanged = { [weak self] quality in
            self?.networkQuality = quality
            self?.handleNetworkQualityChanged(quality)
        }
        webRTC.onLocalIceCandidate = { [weak self] candidate in
            guard let self, let callId = self.activeBackendCallId else { return }
            self.sendSignal(
                callId: callId,
                type: "ice-candidate",
                candidate: candidate.sdp,
                sdpMid: candidate.sdpMid,
                sdpMLineIndex: candidate.sdpMLineIndex
            )
        }
        webRTC.onIceOutcome = { [weak self] outcome in
            self?.logIceOutcome(outcome)
        }
        webRTC.onLocalIceCandidatesRemoved = { candidates in
            print("DEBUG: CallManager WebRTC removed \(candidates.count) local ICE candidate(s)")
        }
        webRTC.onNetworkPathChanged = { [weak self] in
            self?.networkPathChangeGuard.pathChanged()
        }
    }

    private func logIceOutcome(_ outcome: IceOutcome) {
        let callId = activeBackendCallId ?? "unknown"
        let direction = callDirection.map(String.init(describing:)) ?? "unknown"
        if outcome.succeeded {
            let candidateType = outcome.candidateType?.rawValue ?? "unknown"
            let transport = outcome.relayTransport.map { " transport=\($0)" } ?? ""
            print("ICE_OUTCOME call=\(callId) direction=\(direction) succeeded=true candidateType=\(candidateType)\(transport) durationMs=\(Int(outcome.duration * 1000))")
        } else {
            print("ICE_OUTCOME call=\(callId) direction=\(direction) succeeded=false durationMs=\(Int(outcome.duration * 1000))")
        }
    }

    private func observeWebSocketReconnects() {
        wsReconnectObservation?.cancel()
        wsReconnectObservation = Task { [weak self] in
            var wasConnected = ChatWebSocketClient.shared.isConnected
            for await isConnected in ChatWebSocketClient.shared.$isConnected.values {
                defer { wasConnected = isConnected }
                guard let self, isConnected, !wasConnected else { continue }
                guard let pending = self.pendingCriticalSignal else { continue }

                guard pending.callId == self.activeBackendCallId else {
                    self.pendingCriticalSignal = nil
                    continue
                }
                ChatWebSocketClient.shared.sendRaw(pending.text)
            }
        }
        wsReadySignal()
    }

    private func beginPresenceCorrectionWatch() {
        isHandlingBackgroundIncomingCallLaunch = true

        ChatWebSocketClient.shared.demoteToCallOnlyIfPresenceWasWronglyEnabled()

        presenceCorrectionTask?.cancel()
        presenceCorrectionTask = Task { [weak self] in
            for await presenceEnabled in ChatWebSocketClient.shared.$presenceEnabledForCurrentConnection.values {
                guard let self, self.isHandlingBackgroundIncomingCallLaunch else { return }
                guard presenceEnabled else { continue }
                ChatWebSocketClient.shared.demoteToCallOnlyIfPresenceWasWronglyEnabled()
                return
            }
        }
    }

    func markGenuineForegroundOpen() {
        guard isHandlingBackgroundIncomingCallLaunch else { return }
        isHandlingBackgroundIncomingCallLaunch = false
        presenceCorrectionTask?.cancel()
        presenceCorrectionTask = nil
    }

    private func wsReadySignal() {
        wsReadySignalObservation?.cancel()
        wsReadySignalObservation = Task { [weak self] in
            var wasConnected = ChatWebSocketClient.shared.isConnected
            for await isConnected in ChatWebSocketClient.shared.$isConnected.values {
                defer { wasConnected = isConnected }
                guard let self, isConnected, !wasConnected else { continue }
                guard let callId = self.activeBackendCallId else { continue }
                self.sendSignal(callId: callId, type: "resync")
            }
        }
    }

    private func handleConnectionStateChange(_ state: PeerConnectionState) {
        print("DEBUG: CallManager WebRTC PeerConnectionState -> \(state), current callState=\(callState)")
        switch state {
        case .connected:
            cancelReconnectGraceTimer()
            cancelReconnectRestartDebounce()
            networkPathChangeGuard.cancel()
            cancelConnectTimeout()
            cancelRingTimeout()
            endRecovery()
            reconnectRelayFallbackAttempted = false
            proactiveRestartAttempted = false
            cancelProactiveRestartDebounce()
            if case .connected = callState {
            } else if callDirection == .outgoing && !remoteHasAnswered {
                mediaConnectedPendingAnswer = true
            } else {
                promoteToConnected()
            }

        case .reconnecting:
            guard case .connected = callState else { return }
            guard !isRecovering else { return }
            beginRecovery()
            scheduleReconnectGraceTimer()
            scheduleReconnectRestartDebounce()

        case .failed:
            if case .connected = callState {
                guard !isRecovering else { return }
                beginRecovery(showBannerImmediately: true)
                reconnectRelayFallbackAttempted = true
                scheduleReconnectGraceTimer()
                attemptIceRestart(forceRelay: true)
            } else {
                print("DEBUG: CallManager WebRTC .failed before ever reaching .connected")
                if case .connecting = callState, !connectRelayFallbackAttempted {
                    connectRelayFallbackAttempted = true
                    attemptConnectTimeoutRelayFallback()
                    scheduleFollowUpConnectTimeout()
                }
            }

        case .disconnected:
            if case .connected = callState, !isRecovering {
                beginRecovery()
                scheduleReconnectGraceTimer()
                attemptIceRestart()
            }

        default:
            break
        }
    }

    private func handleRemoteVideoStalled() {
        guard case .connected = callState else { return }
        guard !isVideoStalled else { return }
        isVideoStalled = true
        attemptIceRestart()
    }

    private func handleNetworkQualityChanged(_ quality: CallNetworkQuality) {
        guard case .connected = callState, !isRecovering else {
            cancelProactiveRestartDebounce()
            return
        }
        guard quality == .critical else {
            cancelProactiveRestartDebounce()
            return
        }
        guard !proactiveRestartAttempted, proactiveRestartDebounceTask == nil else { return }

        let uuidAtSchedule = activeCXCallUUID
        proactiveRestartDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: (self?.proactiveRestartDebounceSeconds ?? 6) * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.proactiveRestartDebounceTask = nil
            guard self.activeCXCallUUID == uuidAtSchedule else { return }
            guard case .connected = self.callState, !self.isRecovering else { return }
            guard self.networkQuality == .critical, !self.proactiveRestartAttempted else { return }

            print("DEBUG: CallManager network quality held critical for \(self.proactiveRestartDebounceSeconds)s while still nominally connected -- proactively restarting ICE")
            self.proactiveRestartAttempted = true
            self.attemptIceRestart()
        }
    }

    private func cancelProactiveRestartDebounce() {
        proactiveRestartDebounceTask?.cancel()
        proactiveRestartDebounceTask = nil
    }

    private var iceRestartInFlight = false

    private func attemptIceRestart(forceRelay: Bool = false) {
        Task { await performIceRestart(forceRelay: forceRelay) }
    }

    @discardableResult
    private func performIceRestart(forceRelay: Bool = false) async -> Bool {
        guard let callId = activeBackendCallId else { return false }
        guard !iceRestartInFlight else {
            print("DEBUG: CallManager skipping ICE restart -- one is already in flight for call=\(callId)")
            return false
        }
        iceRestartInFlight = true
        defer { iceRestartInFlight = false }
        do {
                if callDirection == .incoming {
                    try? await Task.sleep(nanoseconds: UInt64.random(in: 0...300_000_000))
                    guard callId == activeBackendCallId else { return false }
                }
                if forceRelay {
                    try await performRelayFallback(callId: callId)
                    return true
                }
                let creds = try await fetchTurnCredentialsResilient(callId: callId)
                scheduleTurnCredentialRefresh(ttlSeconds: creds.expiresInSeconds)
                sentIceCandidateSignals.removeAll()
                let offerSDP = try await webRTC.restartIce(iceServers: creds, forceRelay: forceRelay)
                sendSignal(callId: callId, type: "offer", sdp: offerSDP, isCritical: true)
                return true
            } catch {
                print("DEBUG: CallManager ICE restart attempt failed: \(error)")
                return false
            }
    }

    private func sendSignal(
        callId: String, type: String, sdp: String? = nil, candidate: String? = nil,
        sdpMid: String? = nil, sdpMLineIndex: Int32? = nil,
        videoEnabled: Bool? = nil, isCritical: Bool = false
    )  {
        var payload: [String: Any] = ["type": type]
        if let sdp { payload["sdp"] = sdp }
        if let candidate { payload["candidate"] = candidate }
        if let sdpMid { payload["sdp_mid"] = sdpMid }
        if let sdpMLineIndex { payload["sdp_mline_index"] = sdpMLineIndex }
        if let videoEnabled { payload["video_enabled"] = videoEnabled }
        let frame: [String: Any] = ["type": "call_signal", "call_id": callId, "payload": payload]

        if let conversationId = activeConversationId, type != "end", E2EEService.shared.isEnabled(conversationId) {
            let previous = e2eeSignalTail
            let plainPayload = payload
            e2eeSignalTail = Task { [weak self] in
                await previous?.value
                var eph: E2EEService.Ephemeral?
                for attempt in 0..<2 {
                    eph = try? await E2EEService.shared.encryptEphemeral(conversationId: conversationId, object: plainPayload, refresh: attempt > 0)
                    if eph != nil { break }
                }
                guard let eph, let ct = try? JSONEncoder().encode(eph),
                      let obj = try? JSONSerialization.jsonObject(with: ct) else {
                    print("DEBUG: CallManager couldn't encrypt \(type) for call=\(callId); dropping (never sent in the clear)")
                    return
                }
                let wire: [String: Any] = ["type": "call_signal", "call_id": callId, "payload": ["type": type, "e2ee": obj]]
                await MainActor.run { self?.deliverSignal(frame: wire, callId: callId, type: type, isCritical: isCritical) }
            }
            return
        }
        deliverSignal(frame: frame, callId: callId, type: type, isCritical: isCritical)
    }

    private func deliverSignal(frame: [String: Any], callId: String, type: String, isCritical: Bool) {
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8) else {
            print("DEBUG: CallManager failed to serialize call_signal payload")
            return
        }

        if isCritical {
            pendingCriticalSignal = (callId: callId, text: text)
        }
        if type == "ice-candidate" {
            sentIceCandidateSignals.append(text)
        }

        guard isCritical else {
            ChatWebSocketClient.shared.sendRaw(text)
            return
        }

        ChatWebSocketClient.shared.sendRaw(text) { [weak self] delivered in
            guard let self, !delivered else { return }
            print("DEBUG: CallManager critical signal (\(type)) for call=\(callId) failed to send — socket was stale, forcing reconnect and retrying once")
            Task { @MainActor in
                guard self.pendingCriticalSignal?.callId == callId, self.pendingCriticalSignal?.text == text else { return }
                ChatWebSocketClient.shared.forceReconnectAndRetry(text)
            }
        }
    }

    private func sendCallRingingAckResilient(callId: String) {
        let frame: [String: Any] = ["type": "call_ringing_ack", "call_id": callId]
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8) else {
            print("DEBUG: CallManager failed to serialize call_ringing_ack payload")
            return
        }

        pendingCriticalSignal = (callId: callId, text: text)

        ChatWebSocketClient.shared.sendRaw(text) { [weak self] delivered in
            guard let self, !delivered else { return }
            print("DEBUG: CallManager call_ringing_ack for call=\(callId) failed to send — socket not up yet, forcing reconnect and retrying")
            Task { @MainActor in
                guard self.pendingCriticalSignal?.callId == callId, self.pendingCriticalSignal?.text == text else { return }
                ChatWebSocketClient.shared.forceReconnectAndRetry(text)
            }
        }
    }

    private func handleSignal(callId: String, payload: [String: Any]) {
        guard callId == activeBackendCallId else { return }
        guard let type = payload["type"] as? String else { return }

        switch type {
        case "offer":
            guard let sdp = payload["sdp"] as? String else { return }
            guard !appliedRemoteOfferSDPs.contains(sdp) else {
                print("DEBUG: CallManager ignoring duplicate/replayed offer for call=\(callId)")
                return
            }
            if appliedRemoteOfferSDPs.count >= 32 { appliedRemoteOfferSDPs.removeAll() }
            appliedRemoteOfferSDPs.insert(sdp)
            if webRTC.hasPeerConnection {
                guard sdp != lastAppliedRemoteOfferSDP else {
                    print("DEBUG: CallManager ignoring duplicate/replayed offer for call=\(callId)")
                    return
                }
                lastAppliedRemoteOfferSDP = sdp
                let isPolite = (callDirection == .incoming)
                Task {
                    do {
                        let answerSDP = try await webRTC.handleRenegotiationOffer(sdp: sdp, isPolite: isPolite)
                        sendSignal(callId: callId, type: "answer", sdp: answerSDP, isCritical: true)
                        await flushPendingRemoteIceCandidates()
                    } catch is WebRTCClient.RenegotiationGlareIgnored {
                        print("DEBUG: CallManager ignored colliding renegotiation offer for call=\(callId), keeping our own outstanding offer")
                    } catch {
                        print("DEBUG: CallManager failed to answer renegotiation offer: \(error)")
                    }
                }
            } else {
                pendingRemoteOfferSDP = sdp
                lastAppliedRemoteOfferSDP = sdp
            }

        case "answer":
            guard let sdp = payload["sdp"] as? String else { return }
            pendingCriticalSignal = nil
            if case .ringing(.outgoing) = callState {
                cancelRingTimeout()
                callState = .connecting
                scheduleConnectTimeout()
            }
            outgoingCallConfirmedReaching = true
            Task {
                do {
                    try await webRTC.setRemoteAnswer(sdp: sdp)
                    await flushPendingRemoteIceCandidates()
                    sendSignal(callId: callId, type: "renegotiation-ack")
                } catch {
                    print("DEBUG: CallManager failed to apply remote answer: \(error)")
                }
            }
        case "video-toggled":
            guard let enabled = payload["video_enabled"] as? Bool else { return }
            isRemoteVideoEnabled = enabled
            webRTC.suppressVideoStallDetection = !enabled
            if enabled { isVideoStalled = false }

        case "ice-candidate":
            guard let candidate = payload["candidate"] as? String else { return }
            let sdpMid = payload["sdp_mid"] as? String
            let sdpMLineIndex = (payload["sdp_mline_index"] as? NSNumber)?.int32Value ?? 0
            pendingRemoteIceCandidates.append((sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex, candidate: candidate, enqueuedAt: Date()))
            Task { await flushPendingRemoteIceCandidates() }

        case "end":
            endCall(reportToCallKit: true, cxReason: .remoteEnded, displayReason: "Call ended")

        case "renegotiation-ack":
            pendingCriticalSignal = nil

        case "resync":
            if let pending = pendingCriticalSignal, pending.callId == callId {
                ChatWebSocketClient.shared.sendRaw(pending.text) { delivered in
                    guard !delivered else { return }
                    print("DEBUG: CallManager resync replay of critical signal failed to send for call=\(callId), forcing reconnect and retrying once")
                    ChatWebSocketClient.shared.forceReconnectAndRetry(pending.text)
                }
            }
            for text in sentIceCandidateSignals {
                ChatWebSocketClient.shared.sendRaw(text)
            }

        default:
            break
        }
    }

    private func flushPendingRemoteIceCandidates() async {
        guard !isFlushingRemoteCandidates, !pendingRemoteIceCandidates.isEmpty else { return }
        guard webRTC.hasRemoteDescription else { return }
        isFlushingRemoteCandidates = true
        let uuid = activeCXCallUUID
        var deferred: [(sdpMid: String?, sdpMLineIndex: Int32, candidate: String, enqueuedAt: Date)] = []
        defer { isFlushingRemoteCandidates = false }

        while !pendingRemoteIceCandidates.isEmpty {
            guard webRTC.hasRemoteDescription else { break }
            let c = pendingRemoteIceCandidates.removeFirst()
            do {
                try await webRTC.addRemoteIceCandidate(sdpMid: c.sdpMid, sdpMLineIndex: c.sdpMLineIndex, candidate: c.candidate)
            } catch is WebRTCClient.CandidateNotReady {
                pendingRemoteIceCandidates.insert(c, at: 0)
                break
            } catch {
                if Date().timeIntervalSince(c.enqueuedAt) < 10 {
                    deferred.append(c)
                } else {
                    print("DEBUG: CallManager dropping remote ICE candidate that never applied: \(error)")
                }
            }
        }
        if hasActiveCall, activeCXCallUUID == uuid {
            pendingRemoteIceCandidates.insert(contentsOf: deferred, at: 0)
        }
    }

    func startCall(conversationId: String, calleeId: String, calleeName: String, type: CallType) {
        guard case .idle = callState else { return }
        ChatWebSocketClient.shared.callPriorityMode = true
        callState = .ringing(direction: .outgoing)
        otherPartyName = calleeName
        outgoingCallConfirmedReaching = false
        Task {
            do {
                let created = try await createCallResilient(conversationId: conversationId, callType: type)
                let call = created.call

                if call.status.rawValue == "busy" {
                    callState = .idle
                    ChatWebSocketClient.shared.callPriorityMode = false
                    flashFailure("Busy")
                    return
                }

                if !created.calleeReachableNow {
                    print("DEBUG: CallManager create_call reported calleeReachableNow=false for call \(call.id) -- waiting on real CallRinging confirmation before showing \"Ringing…\"")
                }
                otherPartyName = created.calleeName

                let cxUUID = UUID()
                activeBackendCallId = call.id
                activeCXCallUUID = cxUUID
                activeConversationId = conversationId
                hasActiveCall = true
                otherPartyId = calleeId
                callType = type
                pendingOutgoingTurnCredentials = created.turn
                callDirection = .outgoing
                remoteHasAnswered = false
                mediaConnectedPendingAnswer = false
                connectRelayFallbackAttempted = false
                proactiveRestartAttempted = false
                sentIceCandidateSignals.removeAll()
                lastAppliedRemoteOfferSDP = nil
                appliedRemoteOfferSDPs.removeAll()
                scheduleRingTimeout()

                if CallKitPolicy.isAvailable {
                    let handle = CXHandle(type: .generic, value: created.calleeName)
                    let startAction = CXStartCallAction(call: cxUUID, handle: handle)
                    startAction.isVideo = (type == .video)
                    callController.request(CXTransaction(action: startAction)) { error in
                        if let error {
                            print("DEBUG: CXStartCallAction failed: \(error)")
                            Task { @MainActor in
                                self.endCall(reportToCallKit: false, displayReason: "Couldn't start call")
                            }
                        }
                    }
                } else {
                    activateAudioSessionManually()
                    performStartCallWork(cxUUID: cxUUID, isVideo: type == .video)
                }
            } catch {
                print("DEBUG: CallManager failed to create call row: \(error)")
                callState = .idle
                ChatWebSocketClient.shared.callPriorityMode = false
                self.flashFailure("Couldn't start call")
            }
        }
    }

    func reportIncomingCall(callId: String, conversationId: String, callerId: String, callerName: String, type: CallType, alreadyReportedToCallKit: Bool = false) {
        if callId == activeBackendCallId {
            if otherPartyId == nil, !callerId.isEmpty { otherPartyId = callerId }
            if activeConversationId == nil, !conversationId.isEmpty { activeConversationId = conversationId }
            if otherPartyName == CallKitProviderHolder.placeholderCallerName,
               callerName != CallKitProviderHolder.placeholderCallerName {
                otherPartyName = callerName
                if CallKitPolicy.isAvailable, let uuid = activeCXCallUUID {
                    let refreshed = CXCallUpdate()
                    refreshed.remoteHandle = CXHandle(type: .generic, value: callerName)
                    refreshed.localizedCallerName = callerName
                    provider.reportCall(with: uuid, updated: refreshed)
                }
            }
            return
        }

        if !hasActiveCall { ChatWebSocketClient.shared.callPriorityMode = true }

        let isBackgroundOrColdLaunch = UIApplication.shared.applicationState == .background
        if isBackgroundOrColdLaunch {
            ChatWebSocketClient.shared.connect(updatesPresence: false)
            beginPresenceCorrectionWatch()
        } else {
            ChatWebSocketClient.shared.connect()
        }

        let cxUUID = CallKitProviderHolder.cxUUID(for: callId)

        guard !hasActiveCall else {
            if CallKitPolicy.isAvailable {
                if alreadyReportedToCallKit {
                    provider.reportCall(with: cxUUID, endedAt: Date(), reason: .declinedElsewhere)
                } else {
                    let update = CXCallUpdate()
                    update.remoteHandle = CXHandle(type: .generic, value: callerName)
                    update.localizedCallerName = callerName
                    let uuid = UUID()
                    provider.reportNewIncomingCall(with: uuid, update: update) { _ in
                        self.provider.reportCall(with: uuid, endedAt: Date(), reason: .declinedElsewhere)
                    }
                }
            }
            return
        }

        activeBackendCallId = callId
        activeCXCallUUID = cxUUID
        activeConversationId = conversationId.isEmpty ? nil : conversationId
        hasActiveCall = true
        otherPartyId = callerId.isEmpty ? nil : callerId
        otherPartyName = callerName
        callType = type
        callDirection = .incoming
        callState = .ringing(direction: .incoming)
        scheduleRingTimeout()
        connectRelayFallbackAttempted = false
        proactiveRestartAttempted = false
        sentIceCandidateSignals.removeAll()
        lastAppliedRemoteOfferSDP = nil
        appliedRemoteOfferSDPs.removeAll()
        startTurnPrefetch(callId: callId)
        startOfferFallbackFetch(callId: callId)

        guard CallKitPolicy.isAvailable else {
            sendCallRingingAckResilient(callId: callId)
            startIncomingRingtoneIfNeeded()
            Task { @MainActor in WebRTCClient.prewarm() }
            return
        }

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.hasVideo = (type == .video)
        update.localizedCallerName = callerName

        if alreadyReportedToCallKit {
            sendCallRingingAckResilient(callId: callId)
        } else {
            provider.reportNewIncomingCall(with: cxUUID, update: update) { error in
                if let error, !CallKitProviderHolder.isCallUUIDAlreadyExists(error) {
                    print("DEBUG: reportNewIncomingCall failed: \(error)")
                    Task { @MainActor in
                        self.endCall(reportToCallKit: false, displayReason: "Couldn't receive call")
                    }
                    return
                }
                Task { @MainActor in
                    self.sendCallRingingAckResilient(callId: callId)
                }
            }
        }

        Task { @MainActor in WebRTCClient.prewarm() }
    }

    func toggleMute() {
        isMuted.toggle()
        webRTC.setMuted(isMuted)
        if CallKitPolicy.isAvailable, let uuid = activeCXCallUUID {
            let action = CXSetMutedCallAction(call: uuid, muted: isMuted)
            callController.request(CXTransaction(action: action), completion: { _ in })
        }
    }

    func toggleSpeaker() {
        isSpeakerOn.toggle()
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(isSpeakerOn ? .speaker : .none)
        } catch {
            print("DEBUG: failed to toggle speaker: \(error)")
            isSpeakerOn.toggle()
        }
    }

    func switchCamera() {
        guard callType == .video else { return }
        Task {
            do {
                let position = try await webRTC.switchCamera()
                isFrontCamera = (position == .front)
            } catch {
                print("DEBUG: CallManager failed to switch camera: \(error)")
            }
        }
    }

    func toggleVideo() {
        guard callType == .video else { return }
        let newValue = !isVideoEnabled
        Task {
            do {
                try await webRTC.setCameraEnabled(newValue)
                isVideoEnabled = newValue
                if let callId = activeBackendCallId {
                    sendSignal(callId: callId, type: "video-toggled", videoEnabled: newValue)
                }
            } catch {
                print("DEBUG: CallManager failed to toggle video: \(error)")
            }
        }
    }

    func declineCall() {
        guard case .ringing(.incoming) = callState, activeCXCallUUID != nil else { return }
        guard CallKitPolicy.isAvailable, let uuid = activeCXCallUUID else {
            let callId = activeBackendCallId
            endCall(reportToCallKit: false, displayReason: "Declined")
            if let callId {
                Task { await self.updateCallStatusResilient(callId: callId, status: .declined) }
            }
            return
        }
        let action = CXEndCallAction(call: uuid)
        callController.request(CXTransaction(action: action)) { error in
            if let error {
                print("DEBUG: CXEndCallAction (decline) failed: \(error)")
                Task { @MainActor in
                    let callId = self.activeBackendCallId
                    self.endCall(reportToCallKit: false, displayReason: "Declined")
                    if let callId {
                        await self.updateCallStatusResilient(callId: callId, status: .declined)
                    }
                }
            }
        }
    }

    func answerCall() {
        guard case .ringing(.incoming) = callState, activeCXCallUUID != nil else { return }
        guard CallKitPolicy.isAvailable else {
            stopIncomingRingtone()
            cancelRingTimeout()
            callState = .connecting
            WebRTCClient.prewarm()
            activateAudioSessionManually()
            scheduleConnectTimeout()
            performAnswerCallWork()
            return
        }
        let uuid = activeCXCallUUID!
        let action = CXAnswerCallAction(call: uuid)
        callController.request(CXTransaction(action: action)) { error in
            if let error {
                print("DEBUG: CXAnswerCallAction failed: \(error)")
                Task { @MainActor in
                    self.endCall(reportToCallKit: false, displayReason: "Couldn't answer")
                }
            }
        }
    }

    func hangUp() {
        guard activeCXCallUUID != nil else { return }
        guard CallKitPolicy.isAvailable, let uuid = activeCXCallUUID else {
            let callId = activeBackendCallId
            endCall(reportToCallKit: false, displayReason: "Call ended")
            if let callId {
                Task { await self.updateCallStatusResilient(callId: callId, status: .ended) }
            }
            return
        }
        let action = CXEndCallAction(call: uuid)
        callController.request(CXTransaction(action: action)) { error in
            if let error {
                print("DEBUG: CXEndCallAction (hang up) failed: \(error)")
                Task { @MainActor in
                    let callId = self.activeBackendCallId
                    self.endCall(reportToCallKit: false, displayReason: "Call ended")
                    if let callId {
                        await self.updateCallStatusResilient(callId: callId, status: .ended)
                    }
                }
            }
        }
    }

    private func handleCallStatusChanged(callId: String, conversationId: String, status: String) {
        guard callId == activeBackendCallId else { return }
        switch status {
        case "missed":
            endCall(reportToCallKit: true, cxReason: .unanswered, displayReason: "No Answer")
        case "declined":
            endCall(reportToCallKit: true, cxReason: .declinedElsewhere, displayReason: "Declined")
        case "ended":
            endCall(reportToCallKit: true, cxReason: .remoteEnded, displayReason: "Call ended")
        case "busy":
            endCall(reportToCallKit: true, cxReason: .declinedElsewhere, displayReason: "Busy")
        case "ongoing":
            remoteHasAnswered = true
            stopRingback()
            if mediaConnectedPendingAnswer {
                promoteToConnected()
            }
        default:
            break
        }
    }

    private func scheduleRingTimeout() {
        cancelRingTimeout()
        let uuidAtSchedule = activeCXCallUUID
        ringTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: (self?.ringTimeoutSeconds ?? 50) * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.activeCXCallUUID == uuidAtSchedule, case .ringing = self.callState else { return }
            self.endCall(reportToCallKit: true, cxReason: .unanswered, displayReason: "No Answer")
        }
    }

    private func cancelRingTimeout() {
        ringTimeoutTask?.cancel()
        ringTimeoutTask = nil
    }

    private func scheduleConnectTimeout() {
        cancelConnectTimeout()
        let uuidAtSchedule = activeCXCallUUID
        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: (self?.connectTimeoutSeconds ?? 20) * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.activeCXCallUUID == uuidAtSchedule else { return }
            guard case .connecting = self.callState else { return }

            guard self.connectRelayFallbackAttempted else {
                self.connectRelayFallbackAttempted = true
                print("DEBUG: CallManager connect timeout with no pair yet -- retrying relay-only")
                self.attemptConnectTimeoutRelayFallback()
                self.scheduleFollowUpConnectTimeout()
                return
            }

            self.endCall(reportToCallKit: true, cxReason: .failed, displayReason: "Couldn't connect")
        }
    }

    private func attemptConnectTimeoutRelayFallback() {
        guard let callId = activeBackendCallId else { return }
        Task {
            do {
                try await performRelayFallback(callId: callId)
            } catch {
                print("DEBUG: CallManager connect-timeout relay fallback failed: \(error)")
            }
        }
    }

    private func performRelayFallback(callId: String, attempts: Int = 2) async throws {
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                let creds = try await fetchTurnCredentialsResilient(callId: callId)
                scheduleTurnCredentialRefresh(ttlSeconds: creds.expiresInSeconds)
                sentIceCandidateSignals.removeAll()
                let offerSDP = try await webRTC.restartIce(iceServers: creds, forceRelay: true)
                sendSignal(callId: callId, type: "offer", sdp: offerSDP, isCritical: true)
                return
            } catch {
                lastError = error
                guard attempt < attempts - 1 else { break }
                guard callId == activeBackendCallId else { break }
                print("DEBUG: CallManager relay fallback attempt \(attempt + 1)/\(attempts) failed, retrying once: \(error)")
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw lastError ?? NetworkError.serverError(statusCode: 0, message: "Relay fallback failed")
    }

    private func scheduleFollowUpConnectTimeout(seconds: UInt64 = 12) {
        connectTimeoutTask?.cancel()
        let uuidAtSchedule = activeCXCallUUID
        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.activeCXCallUUID == uuidAtSchedule else { return }
            if case .connecting = self.callState {
                self.endCall(reportToCallKit: true, cxReason: .failed, displayReason: "Couldn't connect")
            }
        }
    }

    private func cancelConnectTimeout() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
    }

    private func scheduleReconnectGraceTimer() {
        reconnectGraceTask?.cancel()
        reconnectRelayFallbackAttempted = false
        let uuidAtSchedule = activeCXCallUUID
        let graceSeconds = reconnectGraceSeconds
        reconnectGraceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: (graceSeconds / 2) * 1_000_000_000)
            if let self, !Task.isCancelled, self.activeCXCallUUID == uuidAtSchedule,
               self.isRecovering, !self.reconnectRelayFallbackAttempted {
                self.reconnectRelayFallbackAttempted = true
                print("DEBUG: CallManager still reconnecting at grace-window midpoint -- retrying relay-only")
                self.attemptIceRestart(forceRelay: true)
            }

            try? await Task.sleep(nanoseconds: (graceSeconds - graceSeconds / 2) * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.activeCXCallUUID == uuidAtSchedule else { return }
            guard self.isRecovering else { return }
            self.endCall(reportToCallKit: true, cxReason: .failed, displayReason: "Connection lost")
        }
    }

    private func cancelReconnectGraceTimer() {
        reconnectGraceTask?.cancel()
        reconnectGraceTask = nil
    }

    private func scheduleReconnectRestartDebounce() {
        reconnectRestartDebounceTask?.cancel()
        let uuidAtSchedule = activeCXCallUUID
        let debounceSeconds = reconnectRestartDebounceSeconds
        reconnectRestartDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: debounceSeconds * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.activeCXCallUUID == uuidAtSchedule else { return }
            guard self.isRecovering else { return }
            self.attemptIceRestart()
        }
    }

    private func cancelReconnectRestartDebounce() {
        reconnectRestartDebounceTask?.cancel()
        reconnectRestartDebounceTask = nil
    }

    private func promoteToConnected() {
        mediaConnectedPendingAnswer = false
        stopRingback()
        callState = .connected(since: Date())
        if callDirection == .outgoing, let uuid = activeCXCallUUID {
            provider.reportOutgoingCall(with: uuid, connectedAt: Date())
        }
        startHeartbeat()
        startAudioWatchdog()
        if routeChangedDuringSetup {
            routeChangedDuringSetup = false
            scheduleRouteRestart(delay: 1.0)
        }
    }

    private var offerFallbackTask: Task<Void, Never>?

    private func startOfferFallbackFetch(callId: String) {
        offerFallbackTask?.cancel()
        let uuid = activeCXCallUUID
        offerFallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            while let self, !Task.isCancelled, self.hasActiveCall,
                  self.activeBackendCallId == callId, self.activeCXCallUUID == uuid,
                  self.pendingRemoteOfferSDP == nil, !self.webRTC.hasPeerConnection {
                do {
                    if let frame = try await NetworkService.shared.fetchPendingCallSignal(callId: callId) {
                        print("DEBUG: CallManager got pending signal over REST for call=\(callId)")
                        ChatWebSocketClient.shared.ingestFrame(frame)
                    }
                } catch {
                    if case NetworkError.serverError(let code, _) = error, code == 410 {
                        print("DEBUG: CallManager pending-signal says call=\(callId) is already over, ending")
                        self.endCall(reportToCallKit: true, cxReason: .remoteEnded, displayReason: "Call ended")
                        return
                    }
                    print("DEBUG: CallManager pending-signal fetch failed for call=\(callId): \(error)")
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private var audioWatchdogTask: Task<Void, Never>?

    private func startAudioWatchdog() {
        audioWatchdogTask?.cancel()
        let uuid = activeCXCallUUID
        audioWatchdogTask = Task { [weak self] in
            var last: (sent: Double, received: Double, played: Double?)?
            var strikes = 0
            var attempts = 0
            var deviceKicks = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled, self.hasActiveCall, self.activeCXCallUUID == uuid else { return }
                guard case .connected = self.callState else { continue }
                if self.isRecovering { strikes = 0; last = nil; continue }
                guard let flow = await self.webRTC.audioFlow() else { continue }
                let previous = last
                last = flow
                guard let previous else { continue }

                let sendStuck = flow.sent <= previous.sent
                let recvStuck = flow.received <= previous.received
                var playoutStuck = false
                if !recvStuck, let played = flow.played, let prevPlayed = previous.played {
                    playoutStuck = played <= prevPlayed
                }
                if !sendStuck && !recvStuck && !playoutStuck { strikes = 0; attempts = 0; deviceKicks = 0; continue }
                strikes += 1
                guard strikes >= 2 else { continue }
                strikes = 0

                if playoutStuck || (sendStuck && !recvStuck) {
                    if !playoutStuck && self.micPermissionDenied {
                        print("AUDIO_WATCHDOG not sending, microphone permission denied -- no remedy")
                        continue
                    }
                    deviceKicks += 1
                    print("AUDIO_WATCHDOG call=\(self.activeBackendCallId ?? "?") deviceKick=\(deviceKicks) sendStuck=\(sendStuck) playoutStuck=\(playoutStuck)")
                    await self.kickAudioEngine(reapplyConfiguration: deviceKicks >= 2)
                    try? await Task.sleep(nanoseconds: UInt64(min(deviceKicks, 4)) * 2_000_000_000)
                    last = nil
                    continue
                }

                attempts += 1
                print("AUDIO_WATCHDOG call=\(self.activeBackendCallId ?? "?") attempt=\(attempts) sendStuck=\(sendStuck) recvStuck=\(recvStuck)")
                switch attempts {
                case 1, 2:
                    let sent = await self.performIceRestart()
                    if sent { try? await Task.sleep(nanoseconds: 6_000_000_000) }
                case 3:
                    let sent = await self.performIceRestart(forceRelay: true)
                    if sent { try? await Task.sleep(nanoseconds: 6_000_000_000) }
                default:
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                }
            }
        }
    }

    private func kickAudioEngine(reapplyConfiguration: Bool) async {
        audioKickInFlight = true
        pendingRouteResync = false
        defer { audioKickInFlight = false; lastAudioKickAt = Date() }
        let rtcSession = RTCAudioSession.sharedInstance()
        let route = AVAudioSession.sharedInstance().currentRoute
        print("DEBUG: CallManager kicking audio engine (isAudioEnabled=\(rtcSession.isAudioEnabled) isActive=\(rtcSession.isActive) reapply=\(reapplyConfiguration) in=\(route.inputs.map { $0.portType.rawValue }) out=\(route.outputs.map { $0.portType.rawValue }))")
        rtcSession.isAudioEnabled = false
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard hasActiveCall, case .connected = callState else { return }
        await waitForSessionRateToSettle()
        guard hasActiveCall, case .connected = callState else { return }
        if reapplyConfiguration {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                Self.audioSetupQueue.async {
                    let s = RTCAudioSession.sharedInstance()
                    s.lockForConfiguration()
                    do { try s.setConfiguration(RTCAudioSessionConfiguration.webRTC()) }
                    catch { print("DEBUG: CallManager kick failed to re-apply audio configuration: \(error)") }
                    s.unlockForConfiguration()
                    cont.resume()
                }
            }
        }
        lastKickedRouteSignature = currentRouteSignature()
        rtcSession.isAudioEnabled = true
        if pendingRouteResync {
            pendingRouteResync = false
            if currentRouteSignature() != lastKickedRouteSignature { scheduleRouteRestart(delay: 0.7) }
        }
    }

    private var lastKickedRouteSignature: String?
    private var pendingRouteResync = false
    private var recentKickTimes: [Date] = []

    private func currentRouteSignature() -> String {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let ports = (route.inputs + route.outputs).map { $0.uid }.joined(separator: "|")
        return "\(ports)@\(Int(session.sampleRate))"
    }

    private func routeKickBudgetAllows() -> Bool {
        let now = Date()
        recentKickTimes.removeAll { now.timeIntervalSince($0) > 10 }
        guard recentKickTimes.count < 4 else { return false }
        recentKickTimes.append(now)
        return true
    }

    private func waitForSessionRateToSettle(maxWait: TimeInterval = 1.2) async {
        let session = AVAudioSession.sharedInstance()
        var last = session.sampleRate
        var stable = 0
        let deadline = Date().addingTimeInterval(maxWait)
        while stable < 2, Date() < deadline, hasActiveCall {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let now = session.sampleRate
            if now == last { stable += 1 } else { stable = 0; last = now }
        }
    }

    private var audioKickInFlight = false
    private var lastAudioKickAt = Date.distantPast
    private var routeRestartTask: Task<Void, Never>?
    private var routeChangedDuringSetup = false

    private func observeAudioRouteChanges() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in self?.handleAudioRouteChange(reasonRaw: reasonRaw) }
        }
    }

    private func handleAudioRouteChange(reasonRaw: UInt?) {
        let reason = reasonRaw.flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
        let route = AVAudioSession.sharedInstance().currentRoute
        print("DEBUG: CallManager audio route changed reason=\(reasonRaw.map(String.init) ?? "?") in=\(route.inputs.map { $0.portType.rawValue }) out=\(route.outputs.map { $0.portType.rawValue }) callState=\(callState)")
        guard hasActiveCall else { return }
        switch reason {
        case .newDeviceAvailable?, .oldDeviceUnavailable?, .override?: break
        default: return
        }
        if audioKickInFlight { pendingRouteResync = true; return }
        if reason != .override, currentRouteSignature() == lastKickedRouteSignature { return }
        guard routeKickBudgetAllows() else {
            print("DEBUG: CallManager route-kick budget exhausted, ignoring route change")
            return
        }
        switch callState {
        case .connected: scheduleRouteRestart(delay: 0.7)
        case .connecting: routeChangedDuringSetup = true
        default: break
        }
    }

    private func scheduleRouteRestart(delay: Double) {
        routeRestartTask?.cancel()
        let uuid = activeCXCallUUID
        routeRestartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.hasActiveCall, self.activeCXCallUUID == uuid else { return }
            guard case .connected = self.callState, !self.audioKickInFlight else { return }
            print("DEBUG: CallManager restarting audio engine after audio route change")
            await self.kickAudioEngine(reapplyConfiguration: false)
        }
    }

    private func waitForAudioSessionReady(timeout: TimeInterval = 3) async {
        let rtcSession = RTCAudioSession.sharedInstance()
        let deadline = Date().addingTimeInterval(timeout)
        while !rtcSession.isAudioEnabled, hasActiveCall, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        print("DEBUG: CallManager audio session ready=\(rtcSession.isAudioEnabled) before makeAnswer")
    }

    private var turnRefreshTask: Task<Void, Never>?

    private func scheduleTurnCredentialRefresh(ttlSeconds: Int) {
        turnRefreshTask?.cancel()
        turnRefreshTask = nil
        guard ttlSeconds >= 120 else { return }
        let uuid = activeCXCallUUID
        let delaySeconds = UInt64(Double(ttlSeconds) * 0.8)
        turnRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            while let self, !Task.isCancelled, self.hasActiveCall, self.activeCXCallUUID == uuid {
                if case .connected = self.callState, !self.isRecovering {
                    print("DEBUG: CallManager TURN credentials near expiry -- quiet ICE restart with fresh credentials")
                    self.attemptIceRestart()
                    return
                }
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        guard let callId = activeBackendCallId else { return }
        let interval = heartbeatIntervalSeconds
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sendHeartbeat(callId: callId)
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
            }
        }
    }

    private func cancelHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func sendHeartbeat(callId: String) async {
        do {
            try await NetworkService.shared.sendCallHeartbeat(callId: callId)
        } catch {
            print("DEBUG: CallManager heartbeat failed for call \(callId): \(error)")
        }
    }

    private func startRingbackIfNeeded() {
        guard callDirection == .outgoing, !remoteHasAnswered, ringbackPlayer == nil else { return }
        guard let url = Bundle.main.url(forResource: "ringback", withExtension: "caf") else {
            print("DEBUG: CallManager missing bundled ringback.caf")
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 1.0
            player.prepareToPlay()
            player.play()
            ringbackPlayer = player
        } catch {
            print("DEBUG: CallManager failed to start ringback tone: \(error)")
        }
    }

    private func startIncomingRingtoneIfNeeded() {
        guard !CallKitPolicy.isAvailable, callDirection == .incoming, incomingRingtonePlayer == nil else { return }
        guard let url = Bundle.main.url(forResource: "ringtone", withExtension: "caf") else {
            print("DEBUG: CallManager missing bundled ringtone.caf -- incoming calls will ring silently on this build")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers, .duckOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 1.0
            player.prepareToPlay()
            player.play()
            incomingRingtonePlayer = player
        } catch {
            print("DEBUG: CallManager failed to start incoming ringtone: \(error)")
        }
    }

    private func stopIncomingRingtone() {
        guard incomingRingtonePlayer != nil else { return }
        incomingRingtonePlayer?.stop()
        incomingRingtonePlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func updateCallStatusResilient(callId: String, status: CallStatus) async {
        let backoffNanos: [UInt64] = [
            500_000_000, 1_000_000_000, 2_000_000_000, 4_000_000_000, 8_000_000_000, 16_000_000_000,
        ]

        if let existing = pendingTerminalStatus, existing.callId != callId {
            persistPendingTerminalStatus(nil)
        }

        for (attempt, delay) in backoffNanos.enumerated() {
            do {
                try await NetworkService.shared.updateCallStatus(callId: callId, status: status)
                clearPendingTerminalStatusIfMatching(callId: callId, status: status)
                return
            } catch {
                print("DEBUG: CallManager updateCallStatus(\(status)) attempt \(attempt + 1)/\(backoffNanos.count + 1) failed: \(error)")
                try? await Task.sleep(nanoseconds: delay)
            }
        }

        do {
            try await NetworkService.shared.updateCallStatus(callId: callId, status: status)
            clearPendingTerminalStatusIfMatching(callId: callId, status: status)
        } catch {
            print("DEBUG: CallManager updateCallStatus(\(status)) exhausted \(backoffNanos.count + 1) attempts for call \(callId), persisting for retry-on-reconnect: \(error)")
            persistPendingTerminalStatus(PendingTerminalStatus(callId: callId, statusRaw: status.rawValue))
        }
    }

    private func clearPendingTerminalStatusIfMatching(callId: String, status: CallStatus) {
        guard let pending = pendingTerminalStatus, pending.callId == callId, pending.statusRaw == status.rawValue else { return }
        persistPendingTerminalStatus(nil)
    }

    private func persistPendingTerminalStatus(_ pending: PendingTerminalStatus?) {
        pendingTerminalStatus = pending
        guard let pending else {
            UserDefaults.standard.removeObject(forKey: Self.pendingTerminalStatusDefaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(pending) else { return }
        UserDefaults.standard.set(data, forKey: Self.pendingTerminalStatusDefaultsKey)
    }

    private func restorePendingTerminalStatusFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: Self.pendingTerminalStatusDefaultsKey),
              let pending = try? JSONDecoder().decode(PendingTerminalStatus.self, from: data) else { return }
        pendingTerminalStatus = pending
    }

    private func observePendingTerminalStatusRetries() {
        Task { [weak self] in
            guard let self else { return }
            await self.retryPendingTerminalStatusIfNeeded()

            var wasConnected = ChatWebSocketClient.shared.isConnected
            for await isConnected in ChatWebSocketClient.shared.$isConnected.values {
                defer { wasConnected = isConnected }
                guard isConnected, !wasConnected else { continue }
                await self.retryPendingTerminalStatusIfNeeded()
            }
        }
    }

    private func retryPendingTerminalStatusIfNeeded() async {
        guard let pending = pendingTerminalStatus, let status = CallStatus(rawValue: pending.statusRaw) else { return }
        do {
            try await NetworkService.shared.updateCallStatus(callId: pending.callId, status: status)
            clearPendingTerminalStatusIfMatching(callId: pending.callId, status: status)
        } catch {
            print("DEBUG: CallManager retry-on-reconnect of pending terminal status (\(status)) for call \(pending.callId) failed, will retry on next reconnect: \(error)")
        }
    }

    private func stopRingback() {
        ringbackPlayer?.stop()
        ringbackPlayer = nil
    }

    private func flashFailure(_ reason: String) {
        callState = .ended(reason: reason)
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard case .ended = callState else { return }
            callState = .idle
        }
    }

    private func endCall(reportToCallKit: Bool, cxReason: CXCallEndedReason = .failed, displayReason: String = "Call ended") {
        hasActiveCall = false
        isHandlingBackgroundIncomingCallLaunch = false
        presenceCorrectionTask?.cancel()
        presenceCorrectionTask = nil
        cancelRingTimeout()
        cancelReconnectGraceTimer()
        cancelReconnectRestartDebounce()
        networkPathChangeGuard.cancel()
        cancelConnectTimeout()
        cancelHeartbeat()
        connectRelayFallbackAttempted = false
        reconnectRelayFallbackAttempted = false
        proactiveRestartAttempted = false
        cancelProactiveRestartDebounce()
        pendingOutgoingTurnCredentials = nil
        if let callId = activeBackendCallId {
            turnPrefetchTasks[callId]?.cancel()
            turnPrefetchTasks.removeValue(forKey: callId)
            prefetchedTurnCredentials.removeValue(forKey: callId)
            CallKitProviderHolder.shared.markEnded(callId: callId)
        }
        audioWatchdogTask?.cancel()
        audioWatchdogTask = nil
        routeRestartTask?.cancel()
        routeRestartTask = nil
        routeChangedDuringSetup = false
        lastKickedRouteSignature = nil
        pendingRouteResync = false
        recentKickTimes.removeAll()
        turnRefreshTask?.cancel()
        turnRefreshTask = nil
        offerFallbackTask?.cancel()
        offerFallbackTask = nil
        pendingRemoteOfferSDP = nil
        pendingRemoteIceCandidates.removeAll()
        pendingCriticalSignal = nil
        sentIceCandidateSignals.removeAll()
        lastAppliedRemoteOfferSDP = nil
        appliedRemoteOfferSDPs.removeAll()
        endRecovery()
        outgoingCallConfirmedReaching = false
        networkQuality = .good
        stopRingback()
        callDirection = nil
        remoteHasAnswered = false
        mediaConnectedPendingAnswer = false
        isFrontCamera = true
        isVideoEnabled = true
        if CallKitPolicy.isAvailable, reportToCallKit, let uuid = activeCXCallUUID {
            provider.reportCall(with: uuid, endedAt: Date(), reason: cxReason)
        }
        if !CallKitPolicy.isAvailable {
            stopIncomingRingtone()
            deactivateAudioSessionManually()
        }
        let endCallToken = BackgroundTaskCoordinator.shared.begin(name: "call-end-teardown")

        if let callId = activeBackendCallId {
            sendSignal(callId: callId, type: "end", isCritical: true)
            Task { await self.updateCallStatusResilient(callId: callId, status: .ended) }
        }
        webRTC.close()
        callState = .ended(reason: displayReason)
        localVideoTrack = nil
        remoteVideoTrack = nil
        isVideoStalled = false
        isMuted = false
        isSpeakerOn = false

        Task {
            defer { BackgroundTaskCoordinator.shared.end(endCallToken) }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard case .ended = callState else { return }
            callState = .idle
            activeBackendCallId = nil
            activeCXCallUUID = nil
            activeConversationId = nil
            otherPartyId = nil
            otherPartyName = nil
               if UIApplication.shared.applicationState == .background {
                   ChatWebSocketClient.shared.disconnect()
               }
        }
    }
}

extension CallManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in self.endCall(reportToCallKit: false, displayReason: "Call ended") }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in
            print("DEBUG: CallManager perform(CXStartCallAction) uuid=\(action.callUUID) activeBackendCallId=\(self.activeBackendCallId ?? "nil") hasPendingTurnCreds=\(self.pendingOutgoingTurnCredentials != nil)")
            provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
            guard pendingOutgoingTurnCredentials != nil, activeBackendCallId != nil else {
                print("DEBUG: CallManager CXStartCallAction guard failed — pendingOutgoingTurnCredentials or activeBackendCallId was nil, failing action")
                action.fail()
                endCall(reportToCallKit: false, displayReason: "Couldn't start call")
                return
            }
            WebRTCClient.prewarm()
            action.fulfill()
            performStartCallWork(cxUUID: action.callUUID, isVideo: action.isVideo)
        }
    }

    private func performStartCallWork(cxUUID: UUID, isVideo: Bool) {
        guard let pending = pendingOutgoingTurnCredentials, let callId = activeBackendCallId else {
            print("DEBUG: CallManager performStartCallWork guard failed — pendingOutgoingTurnCredentials or activeBackendCallId was nil")
            endCall(reportToCallKit: false, displayReason: "Couldn't start call")
            return
        }
        WebRTCClient.prewarm()
        let micPermissionTask = Task { await self.ensureMicPermissionRequested() }
        let cameraPermissionTask = Task { if isVideo { await self.ensureCameraPermissionRequested() } }
        Task {
            do {
                await micPermissionTask.value
                await cameraPermissionTask.value
                print("DEBUG: CallManager calling webRTC.makeOffer for call=\(callId)")
                let offerSDP = try await webRTC.makeOffer(iceServers: pending, isVideo: isVideo)
                print("DEBUG: CallManager makeOffer succeeded for call=\(callId), sending offer signal")
                sendSignal(callId: callId, type: "offer", sdp: offerSDP, isCritical: true)
                scheduleTurnCredentialRefresh(ttlSeconds: pending.expiresInSeconds)
            } catch {
                print("DEBUG: CallManager failed to create WebRTC offer: \(error)")
                endCall(reportToCallKit: true, cxReason: .failed, displayReason: "Couldn't connect")
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            print("DEBUG: CallManager perform(CXAnswerCallAction) uuid=\(action.callUUID) activeBackendCallId=\(self.activeBackendCallId ?? "nil") hasPendingOffer=\(self.pendingRemoteOfferSDP != nil)")
            cancelRingTimeout()
            callState = .connecting
            WebRTCClient.prewarm()
            action.fulfill()
            scheduleConnectTimeout()
            performAnswerCallWork()
        }
    }

    private func performAnswerCallWork() {
        let micPermissionTask = Task { await self.ensureMicPermissionRequested() }
        let cameraPermissionTask = Task { if self.callType == .video { await self.ensureCameraPermissionRequested() } }

        guard let callId = activeBackendCallId else {
            print("DEBUG: CallManager performAnswerCallWork fired with no activeBackendCallId — bailing")
            return
        }

        Task {
            let offerWaitSeconds = connectTimeoutSeconds > 8 ? connectTimeoutSeconds - 8 : connectTimeoutSeconds
            var offerSDP = pendingRemoteOfferSDP
            if offerSDP == nil {
                let pollIntervalNanos: UInt64 = 100_000_000
                let iterations = (offerWaitSeconds * 1_000_000_000) / pollIntervalNanos
                for _ in 0..<iterations {
                    try? await Task.sleep(nanoseconds: pollIntervalNanos)
                    if let sdp = pendingRemoteOfferSDP { offerSDP = sdp; break }
                }
            }
            guard let offerSDP else {
                print("DEBUG: CallManager answered call but no offer ever arrived")
                endCall(reportToCallKit: true, cxReason: .failed, displayReason: "Couldn't connect")
                return
            }

            do {
                let turnCreds: TurnCredentials
                if let prefetched = prefetchedTurnCredentials.removeValue(forKey: callId) {
                    print("DEBUG: CallManager using prefetched TURN credentials for call=\(callId)")
                    turnCreds = prefetched
                } else {
                    print("DEBUG: CallManager prefetch not ready, fetching TURN credentials for call=\(callId)")
                    turnCreds = try await fetchTurnCredentialsResilient(callId: callId)
                }
                await micPermissionTask.value
                await cameraPermissionTask.value
                await waitForAudioSessionReady()
                print("DEBUG: CallManager got TURN credentials for call=\(callId), calling webRTC.makeAnswer")
                let answerSDP = try await webRTC.makeAnswer(iceServers: turnCreds, isVideo: callType == .video, remoteOfferSDP: offerSDP)
                print("DEBUG: CallManager makeAnswer succeeded for call=\(callId), sending answer signal")
                sendSignal(callId: callId, type: "answer", sdp: answerSDP, isCritical: true)
                scheduleTurnCredentialRefresh(ttlSeconds: turnCreds.expiresInSeconds)
                await flushPendingRemoteIceCandidates()
            } catch {
                print("DEBUG: CallManager failed to answer WebRTC offer: \(error)")
                endCall(reportToCallKit: true, cxReason: .failed, displayReason: "Couldn't connect")
                return
            }

            do {
                try await NetworkService.shared.updateCallStatus(callId: callId, status: .ongoing)
            } catch {
                print("DEBUG: CallManager failed to mark call \(callId) ongoing, retrying once: \(error)")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                try? await NetworkService.shared.updateCallStatus(callId: callId, status: .ongoing)
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            let wasIncomingRinging: Bool
            if case .ringing(.incoming) = callState { wasIncomingRinging = true } else { wasIncomingRinging = false }
            let callId = activeBackendCallId

            endCall(reportToCallKit: false, displayReason: wasIncomingRinging ? "Declined" : "Call ended")
            action.fulfill()

            if let callId {
                let status: CallStatus = wasIncomingRinging ? .declined : .ended
                await updateCallStatusResilient(callId: callId, status: status)
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor in
            webRTC.setMuted(action.isMuted)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        print("DEBUG: CallManager didActivate audioSession, category=\(audioSession.category.rawValue) mode=\(audioSession.mode.rawValue) sampleRate=\(audioSession.sampleRate) inputAvailable=\(audioSession.isInputAvailable)")
        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.audioSessionDidActivate(audioSession)
        finishAudioSessionActivation(rtcSession: rtcSession)
    }

    private func activateAudioSessionManually() {
        let rtcSession = RTCAudioSession.sharedInstance()
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
            try audioSession.setActive(true)
        } catch {
            print("DEBUG: CallManager manual audio session activation failed: \(error)")
        }
        rtcSession.audioSessionDidActivate(audioSession)
        finishAudioSessionActivation(rtcSession: rtcSession)
    }

    nonisolated private func finishAudioSessionActivation(rtcSession: RTCAudioSession) {
        Self.audioSetupQueue.async { [weak self] in
            self?.performAudioSessionActivation(rtcSession: RTCAudioSession.sharedInstance())
        }
    }

    nonisolated private static let audioSetupQueue = DispatchQueue(label: "call.audio-setup", qos: .userInteractive)

    nonisolated private func performAudioSessionActivation(rtcSession: RTCAudioSession) {
        rtcSession.lockForConfiguration()
        do {
            try rtcSession.setConfiguration(RTCAudioSessionConfiguration.webRTC())
            print("DEBUG: CallManager RTCAudioSessionConfiguration applied OK")
        } catch {
            print("DEBUG: CallManager failed to apply RTCAudioSessionConfiguration: \(error)")
        }
        rtcSession.unlockForConfiguration()

        rtcSession.isAudioEnabled = true
        print("DEBUG: CallManager rtcSession.isAudioEnabled=\(rtcSession.isAudioEnabled) category=\(rtcSession.category) mode=\(rtcSession.mode)")
        let activeRoute = AVAudioSession.sharedInstance().currentRoute
        print("DEBUG: CallManager audio route in=\(activeRoute.inputs.map { $0.portType.rawValue }) out=\(activeRoute.outputs.map { $0.portType.rawValue })")

        let permission = AVAudioSession.sharedInstance().recordPermission
        let permissionDescription: String
        switch permission {
        case .granted: permissionDescription = "granted"
        case .denied: permissionDescription = "denied"
        case .undetermined: permissionDescription = "undetermined"
        @unknown default: permissionDescription = "unknown(\(permission.rawValue))"
        }
        print("DEBUG: CallManager mic recordPermission=\(permissionDescription) (raw=\(permission.rawValue))")

        Task { @MainActor in
            self.refreshMicPermissionState()
            self.startRingbackIfNeeded()
        }
    }

    private func ensureMicPermissionRequested(timeoutSeconds: Double = 3) async {
        let session = AVAudioSession.sharedInstance()
        guard session.recordPermission == .undetermined else {
            print("DEBUG: CallManager mic permission already resolved (\(session.recordPermission.rawValue)) before connecting, no request needed")
            refreshMicPermissionState()
            return
        }
        print("DEBUG: CallManager mic permission undetermined, requesting before connecting")
        let granted: Bool? = await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            let gate = OneShotGate()
            session.requestRecordPermission { granted in
                if gate.claim() { continuation.resume(returning: granted) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
                if gate.claim() { continuation.resume(returning: nil) }
            }
        }
        if let granted {
            print("DEBUG: CallManager mic permission request resolved granted=\(granted)")
        } else {
            print("DEBUG: CallManager mic permission prompt still pending after \(timeoutSeconds)s -- continuing without waiting")
        }
        refreshMicPermissionState()
    }

    private func refreshMicPermissionState() {
        micPermissionDenied = (AVAudioSession.sharedInstance().recordPermission == .denied)
    }

    private func ensureCameraPermissionRequested() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        guard status == .notDetermined else {
            print("DEBUG: CallManager camera permission already resolved (\(status.rawValue)) before connecting, no request needed")
            return
        }
        print("DEBUG: CallManager camera permission undetermined, requesting before connecting")
        let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                continuation.resume(returning: granted)
            }
        }
        print("DEBUG: CallManager camera permission request resolved granted=\(granted)")
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        print("DEBUG: CallManager didDeactivate audioSession")
        finishAudioSessionDeactivation(audioSession)
    }

    nonisolated private func deactivateAudioSessionManually() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("DEBUG: CallManager manual audio session deactivation failed: \(error)")
        }
        finishAudioSessionDeactivation(audioSession)
    }

    nonisolated private func finishAudioSessionDeactivation(_ audioSession: AVAudioSession) {
        Self.audioSetupQueue.async { [weak self] in
            let rtcSession = RTCAudioSession.sharedInstance()
            rtcSession.isAudioEnabled = false
            rtcSession.audioSessionDidDeactivate(AVAudioSession.sharedInstance())
            Task { @MainActor in
                self?.stopRingback()
            }
        }
    }
}

private final class OneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
