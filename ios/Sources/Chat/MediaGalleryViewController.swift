import UIKit
import AVKit
import QuickLook
import Kingfisher

@MainActor
enum MediaGalleryPresenter {
    static func present(messages: [BackendMessage], startIndex: Int) {
        guard !messages.isEmpty, let presenter = topViewController() else { return }
        guard !(presenter is MediaGalleryViewController) else { return }

        let gallery = MediaGalleryViewController(messages: messages, startIndex: startIndex)
        gallery.modalPresentationStyle = .overFullScreen
        gallery.modalTransitionStyle = .crossDissolve
        presenter.present(gallery, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

final class MediaGalleryViewController: UIViewController {
    private let messages: [BackendMessage]
    private var currentIndex: Int

    private let backgroundView = UIView()
    private let pager = UIPageViewController(
        transitionStyle: .scroll,
        navigationOrientation: .horizontal,
        options: [.interPageSpacing: 16]
    )

    private lazy var closeButton = makeChromeButton(systemName: "xmark", label: "Close", action: #selector(closeTapped))
    private lazy var shareButton = makeChromeButton(systemName: "square.and.arrow.up", label: "Share", action: #selector(shareTapped))
    private let counterButton = UIButton(type: .system)
    private var chromeViews: [UIView] { [closeButton, shareButton, counterButton] }
    private var isChromeHidden = false

    private lazy var panGesture: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        gesture.delegate = self
        return gesture
    }()

    init(messages: [BackendMessage], startIndex: Int) {
        self.messages = messages
        self.currentIndex = messages.isEmpty ? 0 : min(max(startIndex, 0), messages.count - 1)
        super.init(nibName: nil, bundle: nil)
        modalPresentationCapturesStatusBarAppearance = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        backgroundView.backgroundColor = .black
        backgroundView.frame = view.bounds
        backgroundView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(backgroundView)

        addChild(pager)
        pager.view.backgroundColor = .clear
        pager.view.frame = view.bounds
        pager.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pager.view)
        pager.didMove(toParent: self)

        pager.dataSource = messages.count > 1 ? self : nil
        pager.delegate = self
        if let first = makePage(at: currentIndex) {
            pager.setViewControllers([first], direction: .forward, animated: false)
        }

        setUpChrome()
        view.addGestureRecognizer(panGesture)
    }

    private var currentPage: MediaGalleryPageViewController? {
        pager.viewControllers?.first as? MediaGalleryPageViewController
    }

    private func makePage(at index: Int) -> MediaGalleryPageViewController? {
        guard messages.indices.contains(index) else { return nil }
        let page = MediaGalleryPageViewController(message: messages[index], index: index)
        page.onSingleTap = { [weak self] in self?.toggleChrome() }
        return page
    }

    private func makeChromeButton(systemName: String, label: String, action: Selector) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: systemName)
        config.baseForegroundColor = .white
        config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.4)
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
        let button = UIButton(configuration: config)
        button.accessibilityLabel = label
        button.addTarget(self, action: action, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func setUpChrome() {
        var counterConfig = UIButton.Configuration.filled()
        counterConfig.baseForegroundColor = .white
        counterConfig.baseBackgroundColor = UIColor.black.withAlphaComponent(0.4)
        counterConfig.cornerStyle = .capsule
        counterConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        counterConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var updated = attributes
            updated.font = UIFont.preferredFont(forTextStyle: .footnote)
            return updated
        }
        counterButton.configuration = counterConfig
        counterButton.isUserInteractionEnabled = false
        counterButton.isHidden = messages.count <= 1
        counterButton.translatesAutoresizingMaskIntoConstraints = false
        updateCounter()

        chromeViews.forEach { view.addSubview($0) }

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            closeButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            shareButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            shareButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            counterButton.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            counterButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor)
        ])
    }

    private func updateCounter() {
        counterButton.configuration?.title = "\(currentIndex + 1) / \(messages.count)"
    }

    private func applyChrome(multiplier: CGFloat = 1) {
        let alpha: CGFloat = isChromeHidden ? 0 : multiplier
        chromeViews.forEach { $0.alpha = alpha }
    }

    private func toggleChrome() {
        isChromeHidden.toggle()
        chromeViews.forEach { $0.isUserInteractionEnabled = !isChromeHidden && $0 !== counterButton }
        UIView.animate(withDuration: 0.2) { self.applyChrome() }
    }

    @objc private func closeTapped() {
        currentPage?.pause()
        dismiss(animated: true)
    }

    @objc private func shareTapped() {
        guard let items = currentPage?.shareItems, !items.isEmpty else { return }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = shareButton
        sheet.popoverPresentationController?.sourceRect = shareButton.bounds
        present(sheet, animated: true)
    }

    override func accessibilityPerformEscape() -> Bool {
        closeTapped()
        return true
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)

        switch gesture.state {
        case .changed:
            let progress = min(abs(translation.y) / (view.bounds.height * 0.5), 1)
            let scale = 1 - 0.2 * progress
            pager.view.transform = CGAffineTransform(translationX: translation.x, y: translation.y)
                .scaledBy(x: scale, y: scale)
            backgroundView.alpha = 1 - progress
            applyChrome(multiplier: max(0, 1 - progress * 3))

        case .ended:
            let velocity = gesture.velocity(in: view)
            let flung = abs(velocity.y) > 800 && velocity.y * translation.y > 0
            if abs(translation.y) > 120 || flung {
                finishDismissal(translation: translation, velocity: velocity)
            } else {
                restoreAfterCancelledPan()
            }

        case .cancelled, .failed:
            restoreAfterCancelledPan()

        default:
            break
        }
    }

    private func finishDismissal(translation: CGPoint, velocity: CGPoint) {
        currentPage?.pause()
        let direction: CGFloat = (translation.y != 0 ? translation.y : velocity.y) >= 0 ? 1 : -1
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
            self.pager.view.transform = CGAffineTransform(
                translationX: translation.x,
                y: direction * self.view.bounds.height
            )
            self.backgroundView.alpha = 0
            self.chromeViews.forEach { $0.alpha = 0 }
        } completion: { _ in
            self.dismiss(animated: false)
        }
    }

    private func restoreAfterCancelledPan() {
        UIView.animate(
            withDuration: 0.35,
            delay: 0,
            usingSpringWithDamping: 0.85,
            initialSpringVelocity: 0,
            options: [.allowUserInteraction]
        ) {
            self.pager.view.transform = .identity
            self.backgroundView.alpha = 1
            self.applyChrome()
        }
    }
}

extension MediaGalleryViewController: UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let current = viewController as? MediaGalleryPageViewController else { return nil }
        return makePage(at: current.index - 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let current = viewController as? MediaGalleryPageViewController else { return nil }
        return makePage(at: current.index + 1)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool
    ) {
        guard completed, let page = currentPage else { return }
        currentIndex = page.index
        updateCounter()
    }
}

extension MediaGalleryViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panGesture else { return true }
        let velocity = panGesture.velocity(in: view)
        guard abs(velocity.y) > abs(velocity.x) else { return false }
        return currentPage?.canDismissWithPan ?? true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === panGesture
    }
}

final class MediaGalleryPageViewController: UIViewController {
    let message: BackendMessage
    let index: Int
    var onSingleTap: (() -> Void)?

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var failureView: UIView?
    private var playerController: AVPlayerViewController?
    private var qlController: QLPreviewController?
    private var localFileURL: URL?
    private var fullImage: UIImage?
    private var isVisible = false

    init(message: BackendMessage, index: Int) {
        self.message = message
        self.index = index
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var canDismissWithPan: Bool {
        guard message.contentType == .image else { return true }
        return scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01
    }

    var shareItems: [Any] {
        switch message.contentType {
        case .image:
            if let fullImage { return [fullImage] }
        case .video, .file:
            if let localFileURL { return [localFileURL] }
        default:
            break
        }
        if let string = message.mediaUrl, let url = URL(string: string) { return [url] }
        return []
    }

    func pause() { playerController?.player?.pause() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        switch message.contentType {
        case .image: setUpImage()
        case .video: setUpVideo()
        case .file: setUpFile()
        default: break
        }

        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        spinner.startAnimating()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        playerController?.player?.play()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isVisible = false
        playerController?.player?.pause()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard message.contentType == .image, scrollView.zoomScale == 1 else { return }
        if imageView.frame.size != scrollView.bounds.size {
            imageView.frame = scrollView.bounds
        }
        scrollView.contentSize = scrollView.bounds.size
    }

    deinit {
        playerController?.player?.pause()
    }

    private func setUpImage() {
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = self
        view.addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        showCachedThumbnail()

        guard let remoteURL = message.mediaUrl.flatMap({ URL(string: $0) }) else {
            showFailure()
            return
        }
        let source: Source = remoteURL.isFileURL
            ? .provider(LocalFileImageDataProvider(fileURL: remoteURL, cacheKey: message.id))
            : remoteURL.convertToSource(overrideCacheKey: message.id)
        imageView.kf.setImage(with: source, options: [.keepCurrentImageWhileLoading]) { [weak self] result in
            guard let self else { return }
            self.spinner.stopAnimating()
            switch result {
            case .success(let value):
                self.fullImage = value.image
            case .failure(let error):
                if !error.isTaskCancelled, self.imageView.image == nil { self.showFailure() }
            }
        }
    }

    @objc private func handleSingleTap() { onSingleTap?() }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            return
        }
        let zoom: CGFloat = 2.5
        let point = gesture.location(in: imageView)
        let size = CGSize(width: scrollView.bounds.width / zoom, height: scrollView.bounds.height / zoom)
        let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
        scrollView.zoom(to: rect, animated: true)
    }

    private func showCachedThumbnail() {
        ImageCache.default.retrieveImage(forKey: message.id + "_thumb") { [weak self] result in
            guard let self, self.fullImage == nil, self.imageView.image == nil else { return }
            if case .success(let cached) = result, let thumbnail = cached.image {
                self.imageView.image = thumbnail
            }
        }
    }

    private func setUpVideo() {
        imageView.contentMode = .scaleAspectFit
        imageView.frame = view.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(imageView)
        showCachedThumbnail()

        loadLocalFile { [weak self] url in self?.presentPlayer(for: url) }
    }

    private func presentPlayer(for url: URL) {
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(url: url)
        embed(controller)
        playerController = controller
        if isVisible { controller.player?.play() }
    }

    private func setUpFile() {
        loadLocalFile { [weak self] url in
            guard let self else { return }
            self.localFileURL = url
            let controller = QLPreviewController()
            controller.dataSource = self
            self.embed(controller)
            self.qlController = controller
        }
    }

    private func loadLocalFile(then present: @escaping (URL) -> Void) {
        guard let remoteURL = message.mediaUrl.flatMap({ URL(string: $0) }) else {
            showFailure()
            return
        }
        if remoteURL.isFileURL {
            localFileURL = remoteURL
            spinner.stopAnimating()
            present(remoteURL)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await MediaFileCache.shared.localURL(for: remoteURL, cacheKey: self.message.id)
                self.localFileURL = url
                self.spinner.stopAnimating()
                present(url)
            } catch {
                self.showFailure()
            }
        }
    }

    private func embed(_ controller: UIViewController) {
        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controller.view)
        controller.didMove(toParent: self)
    }

    private func showFailure() {
        spinner.stopAnimating()
        guard failureView == nil else { return }

        let icon = UIImageView(image: UIImage(systemName: "exclamationmark.triangle"))
        icon.tintColor = .white
        let label = UILabel()
        label.text = "Couldn't load media"
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .footnote)

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        failureView = stack
    }
}

extension MediaGalleryPageViewController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
}

extension MediaGalleryPageViewController: QLPreviewControllerDataSource {
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { localFileURL == nil ? 0 : 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        (localFileURL ?? URL(fileURLWithPath: "/dev/null")) as NSURL
    }
}
