import UIKit
import UIKit.UIGestureRecognizerSubclass
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct BitPlayerView: UIViewControllerRepresentable {
    let message: BackendMessage
    let isMine: Bool
    let onReveal: (String) -> Void
    let onExpire: () -> Void

    func makeUIViewController(context: Context) -> BitPlayerViewController {
        let controller = BitPlayerViewController(message: message, isMine: isMine)
        controller.onReveal = onReveal
        controller.onExpire = onExpire
        return controller
    }

    func updateUIViewController(_ uiViewController: BitPlayerViewController, context: Context) {
        uiViewController.onReveal = onReveal
        uiViewController.onExpire = onExpire
    }
}

final class PaddedLabel: UILabel {
    var contentInsets = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10) {
        didSet { invalidateIntrinsicContentSize() }
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: contentInsets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + contentInsets.left + contentInsets.right,
            height: size.height + contentInsets.top + contentInsets.bottom
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}

final class BitPlayerViewController: UIViewController {
    private let message: BackendMessage
    private let isMine: Bool
    var onReveal: ((String) -> Void)?
    var onExpire: (() -> Void)?

    private let secureCanvas = SecureCanvasView()
    private let imageView = UIImageView()
    private let timerLabel = PaddedLabel()
    private let recordingBanner = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)

    private var isVideo = false
    private var player: AVPlayer?
    private var videoRenderer: VideoFrameRenderer?
    private var videoLoader: InMemoryVideoLoader?

    private var hasRevealed = false
    private var hasBegunPlayback = false
    private var remainingSeconds: Double
    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval?

    private static let defaultViewDuration: Double = 10

    private var isExpired: Bool {
        message.deletedAt != nil || (message.expiresAt.map { $0 <= Date() } ?? false) || message.mediaUrl == nil
    }

    init(message: BackendMessage, isMine: Bool) {
        self.message = message
        self.isMine = isMine
        self.remainingSeconds = message.mediaMetadata?.viewDurationSeconds.map(Double.init) ?? Self.defaultViewDuration
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        layoutViews()

        NotificationCenter.default.addObserver(self, selector: #selector(captureStateChanged),
                                                 name: UIScreen.capturedDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenshotTaken),
                                                 name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        captureStateChanged()

        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive),
                                                 name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                                 name: UIApplication.didBecomeActiveNotification, object: nil)

        guard !isExpired, let remoteURL = message.mediaUrl.flatMap(URL.init) else {
            showFailure("This bit has expired.")
            return
        }
        isVideo = ["mov", "mp4", "m4v"].contains(remoteURL.pathExtension.lowercased())
        load(remoteURL)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        beginPlayback()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopDisplayLink()
        videoRenderer?.stop()
        player?.pause()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private var pausedForInactivity = false

    @objc private func appWillResignActive() {
        guard hasBegunPlayback, displayLink != nil else { return }
        pausedForInactivity = true
        stopDisplayLink()
        videoRenderer?.stop()
        player?.pause()
    }

    @objc private func appDidBecomeActive() {
        guard pausedForInactivity else { return }
        pausedForInactivity = false
        guard view.window != nil, remainingSeconds > 0 else { return }
        startDisplayLink()
        if isVideo {
            videoRenderer?.start()
            player?.play()
        }
    }

    private func layoutViews() {
        secureCanvas.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(secureCanvas)
        NSLayoutConstraint.activate([
            secureCanvas.topAnchor.constraint(equalTo: view.topAnchor),
            secureCanvas.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            secureCanvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            secureCanvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        secureCanvas.contentView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: secureCanvas.contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: secureCanvas.contentView.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: secureCanvas.contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: secureCanvas.contentView.trailingAnchor),
        ])

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = .white
        view.addSubview(spinner)
        spinner.startAnimating()
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        timerLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        timerLabel.textColor = .white
        timerLabel.textAlignment = .right
        timerLabel.translatesAutoresizingMaskIntoConstraints = false
        timerLabel.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        timerLabel.layer.cornerRadius = 10
        timerLabel.layer.masksToBounds = true
        view.addSubview(timerLabel)
        NSLayoutConstraint.activate([
            timerLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            timerLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            timerLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        updateTimerLabel()

    }

    private var e2eeData: Data?

    private var prefetchedData: Data? {
        if let e2eeData { return e2eeData }
        guard !isMine else { return nil }
        return BitPrefetchCache.shared.data(for: message.id)
    }

    private func load(_ remoteURL: URL) {
        if remoteURL.scheme == "e2eebit", prefetchedData == nil {
            Task { [weak self] in
                guard let self else { return }
                do {
                    let data = try await E2EEBitLoader.data(messageId: self.message.id)
                    await MainActor.run { self.e2eeData = data; self.load(remoteURL) }
                } catch {
                    await MainActor.run { self.showFailure("Couldn't load this bit — try again.") }
                }
            }
            return
        }
        if isVideo {
            let player: AVPlayer
            if let cached = prefetchedData {
                var components = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false)
                components?.scheme = "bitmem"
                let asset = AVURLAsset(url: components?.url ?? remoteURL)
                let loader = InMemoryVideoLoader(data: cached, contentType: Self.utiContentType(for: remoteURL))
                videoLoader = loader
                asset.resourceLoader.setDelegate(loader, queue: .main)
                player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            } else {
                player = AVPlayer(url: remoteURL)
            }
            self.player = player
            let renderer = VideoFrameRenderer(player: player) { [weak self] cgImage in
                guard let self else { return }
                self.imageView.image = UIImage(cgImage: cgImage)
                if !self.spinner.isHidden {
                    self.spinner.stopAnimating()
                    self.spinner.isHidden = true
                }
                guard self.displayLink == nil, self.remainingSeconds > 0 else { return }
                self.startDisplayLink()
            }
            self.videoRenderer = renderer
            NotificationCenter.default.addObserver(
                self, selector: #selector(videoDidReachEnd), name: .AVPlayerItemDidPlayToEndTime, object: player.currentItem
            )
            if isViewLoaded, view.window != nil { beginPlayback() }
        } else if let cached = prefetchedData {
            guard let image = UIImage(data: cached) else {
                showFailure("Couldn't load this bit — try again.")
                return
            }
            imageView.image = image
            spinner.stopAnimating()
            spinner.isHidden = true
            if isViewLoaded, view.window != nil { beginPlayback() }
        } else {
            Task { [weak self] in
                guard let self else { return }
                do {
                    let (data, response) = try await URLSession.shared.data(from: remoteURL)
                    guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
                          let image = UIImage(data: data)
                    else { throw URLError(.badServerResponse) }
                    await MainActor.run {
                        self.imageView.image = image
                        self.spinner.stopAnimating()
                        self.spinner.isHidden = true
                        if self.isViewLoaded, self.view.window != nil { self.beginPlayback() }
                    }
                } catch {
                    await MainActor.run { self.showFailure("Couldn't load this bit — try again.") }
                }
            }
        }
    }

    private static func utiContentType(for remoteURL: URL) -> String {
        UTType(filenameExtension: remoteURL.pathExtension.lowercased())?.identifier ?? UTType.mpeg4Movie.identifier
    }

    private func showFailure(_ text: String) {
        spinner.stopAnimating()
        spinner.isHidden = true
        timerLabel.isHidden = true
        let fallback = UILabel()
        fallback.text = text
        fallback.textColor = .white
        fallback.font = .systemFont(ofSize: 15, weight: .medium)
        fallback.textAlignment = .center
        fallback.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fallback)
        NSLayoutConstraint.activate([
            fallback.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            fallback.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func beginPlayback() {
        guard imageView.image != nil || isVideo, remainingSeconds > 0, !hasBegunPlayback else { return }
        hasBegunPlayback = true

        if !hasRevealed {
            hasRevealed = true
            onReveal?(message.id)
        }

        if isVideo {
            player?.seek(to: .zero)
            player?.play()
            videoRenderer?.start()
        } else {
            startDisplayLink()
        }
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        lastTick = nil
        let link = CADisplayLink(target: self, selector: #selector(displayLinkTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        lastTick = nil
    }

    @objc private func displayLinkTick(_ link: CADisplayLink) {
        defer { lastTick = link.timestamp }
        guard let last = lastTick else { return }

        remainingSeconds = max(0, remainingSeconds - (link.timestamp - last))
        updateTimerLabel()

        if remainingSeconds <= 0 {
            stopDisplayLink()
            videoRenderer?.stop()
            player?.pause()
            onExpire?()
        }
    }

    @objc private func videoDidReachEnd() {
        guard remainingSeconds > 0 else { return }
        player?.seek(to: .zero)
        player?.play()
    }

    private func updateTimerLabel() {
        timerLabel.text = "\(Int(remainingSeconds.rounded(.up)))s"
    }

    @objc private func captureStateChanged() {
        recordingBanner.isHidden = !UIScreen.main.isCaptured
    }

    @objc private func screenshotTaken() {
        print("DEBUG: screenshot detected while viewing bit \(message.id) — wire up notify-sender call here")
    }
}

final class BitPlayerPresenter {
    static let shared = BitPlayerPresenter()

    private weak var controller: BitPlayerViewController?
    private let liftWatcher = TouchLiftWatcher()
    private weak var watchedWindow: UIWindow?

    private init() {
        liftWatcher.onAllTouchesLifted = { [weak self] in
            DispatchQueue.main.async { self?.dismiss() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isPresenting, !self.liftWatcher.hasActiveTouches else { return }
            self.dismiss()
        }
    }

    var isPresenting: Bool { controller?.presentingViewController != nil }

    func watch(_ window: UIWindow) {
        guard watchedWindow !== window else { return }
        watchedWindow?.removeGestureRecognizer(liftWatcher)
        window.addGestureRecognizer(liftWatcher)
        watchedWindow = window
    }

    func present(message: BackendMessage, isMine: Bool, onReveal: @escaping (String) -> Void) {
        guard !isPresenting, let host = Self.topViewController() else { return }
        if watchedWindow != nil, !liftWatcher.hasActiveTouches { return }
        let player = BitPlayerViewController(message: message, isMine: isMine)
        player.onReveal = onReveal
        player.onExpire = { [weak self] in self?.dismiss() }
        player.modalPresentationStyle = .overFullScreen
        controller = player
        host.present(player, animated: false)
    }

    func dismiss() {
        guard let controller, controller.presentingViewController != nil else { return }
        controller.dismiss(animated: false)
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

final class TouchLiftWatcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onAllTouchesLifted: (() -> Void)?
    private var activeTouches = Set<UITouch>()
    var hasActiveTouches: Bool { !activeTouches.isEmpty }

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        activeTouches.formUnion(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        touchesFinished(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        touchesFinished(touches)
    }

    private func touchesFinished(_ touches: Set<UITouch>) {
        activeTouches.subtract(touches)
        guard activeTouches.isEmpty, UIApplication.shared.applicationState == .active else { return }
        onAllTouchesLifted?()
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool { true }
}

final class SecureCanvasView: UIView {
    let contentView = UIView()

    private let secureField = UITextField()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        
        backgroundColor = .clear
        
        secureField.isSecureTextEntry = true
        secureField.isUserInteractionEnabled = false
        secureField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(secureField)
        NSLayoutConstraint.activate([
            secureField.topAnchor.constraint(equalTo: topAnchor),
            secureField.bottomAnchor.constraint(equalTo: bottomAnchor),
            secureField.leadingAnchor.constraint(equalTo: leadingAnchor),
            secureField.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        guard let canvas = secureField.subviews.first else {
            
            addSubview(contentView)
            contentView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                contentView.topAnchor.constraint(equalTo: topAnchor),
                contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
                contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
                
            ])
            return
        }
        canvas.subviews.forEach { $0.removeFromSuperview() }
        contentView.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: canvas.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
        ])
    }
}

final class InMemoryVideoLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let data: Data
    private let contentType: String

    init(data: Data, contentType: String) {
        self.data = data
        self.contentType = contentType
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = true
        }
        if let dataRequest = loadingRequest.dataRequest {
            let start = Int(dataRequest.requestedOffset)
            guard start < data.count else {
                loadingRequest.finishLoading()
                return true
            }
            let requestedLength = dataRequest.requestedLength
            let end = min(start + requestedLength, data.count)
            dataRequest.respond(with: data.subdata(in: start..<end))
        }
        loadingRequest.finishLoading()
        return true
    }
}

final class VideoFrameRenderer {
    private let player: AVPlayer
    private let onFrame: (CGImage) -> Void
    private var output: AVPlayerItemVideoOutput?
    private var displayLink: CADisplayLink?
    private let ciContext = CIContext()

    init(player: AVPlayer, onFrame: @escaping (CGImage) -> Void) {
        self.player = player
        self.onFrame = onFrame
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        ])
        player.currentItem?.add(output)
        self.output = output
    }

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let output else { return }
        let time = player.currentItem?.currentTime() ?? .zero
        guard output.hasNewPixelBuffer(forItemTime: time),
              let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        onFrame(cgImage)
    }

    deinit {
        stop()
    }
}
