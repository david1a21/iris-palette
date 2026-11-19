import UIKit
import WebKit
import Photos

/// 只做一件事：把页面装进一个像样的容器。
/// 页面本身一份不改（Resources/index.html 与用户给的 HTML 逐字节一致），
/// 系统侧缺的东西在外壳补：保存到相册 / 分享 / 安全区 / 系统选择器放宽。
final class ShellViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate {

    private let ink = UIColor(red: 8.0 / 255.0, green: 8.0 / 255.0, blue: 10.0 / 255.0, alpha: 1.0)
    private var web: WKWebView!
    private var session: SaveSession?
    private weak var edgePan: UIScreenEdgePanGestureRecognizer?
    private var liveBridge: LivePhotoBridge?

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersHomeIndicatorAutoHidden: Bool { false }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ink

        let conf = WKWebViewConfiguration()
        conf.websiteDataStore = .default()                       // localStorage / 设置要能留住
        conf.allowsInlineMediaPlayback = true
        conf.mediaTypesRequiringUserActionForPlayback = []
        conf.defaultWebpagePreferences.allowsContentJavaScript = true
        conf.allowsAirPlayForMediaPlayback = false

        let ucc = WKUserContentController()
        ucc.add(self, name: "iris")
        if let shim = Self.resourceText("iris-ios-shim", "js") {
            ucc.addUserScript(WKUserScript(source: shim,
                                           injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true))
        }
        conf.userContentController = ucc

        web = WKWebView(frame: .zero, configuration: conf)
        web.translatesAutoresizingMaskIntoConstraints = false
        web.isOpaque = false
        web.backgroundColor = ink
        web.scrollView.backgroundColor = ink
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never  // 安全区由外壳让位，页面 CSS 不再二次留白
        web.allowsLinkPreview = false
        web.navigationDelegate = self
        view.addSubview(web)

        // 顶边绑到安全区下沿，交给 Auto Layout 跟随状态栏/灵动岛高度自动更新。
        // 之前用手动 frame，首次布局时 safeAreaInsets 还是 0，之后没有再次纠正，
        // 于是每次装新包顶栏都会被状态栏压住。约束没有这个问题。
        // 底边仍然通栏，下沿交给页面自己处理。
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        installEdgeSwipe()
        liveBridge = LivePhotoBridge()

        guard let page = Bundle.main.url(forResource: "index", withExtension: "html") else { return }
        web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    }

    /// 安全区变化（旋转、状态栏出现/消失、灵动岛机型切换）时，约束会自己重算；
    /// 这里只补一次布局，确保页面在第一帧就拿到正确的高度。
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }

    // MARK: - 侧滑返回

    /// 这个外壳只有一个 WebView，页面自己是「一层主界面 + 若干全屏二级页」的结构，
    /// 所以系统默认的左缘返回手势在这里根本不存在。做法是自己挂一个屏幕边缘手势，
    /// 从左边往右划时先问页面：有二级页就先关它；没有就走 WebView 自己的历史。
    private func installEdgeSwipe() {
        let g = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
        g.edges = .left
        g.maximumNumberOfTouches = 1
        g.delaysTouchesBegan = false
        g.cancelsTouchesInView = false
        web.addGestureRecognizer(g)
        edgePan = g
    }

    @objc private func handleEdgePan(_ g: UIScreenEdgePanGestureRecognizer) {
        guard g.state == .ended else { return }
        let moved = g.translation(in: web)
        let speed = g.velocity(in: web)
        // 往右划一段、并且确实是往右甩，才认作返回，避免误触
        guard moved.x > 55, moved.y < 120, speed.x > 220 else { return }
        popOneLevel()
    }

    private func popOneLevel() {
        // 页面里的二级页（说明书 / 快捷键 / 导出 / 关于…）优先关掉
        web.evaluateJavaScript(
            "(function(){try{return !!(window.__irisNativeBack && window.__irisNativeBack());}catch(e){return false;}})()"
        ) { [weak self] result, _ in
            guard let self = self else { return }
            if let handled = result as? Bool, handled { return }
            if self.web.canGoBack {
                self.web.goBack()
            } else {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }

    private static func resourceText(_ name: String, _ ext: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - 页面 → 原生

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "iris",
              let body = message.body as? [String: Any],
              let op = body["op"] as? String else { return }

        switch op {
        case "begin":
            let name = (body["name"] as? String) ?? "Iris_\(Int(Date().timeIntervalSince1970))"
            let mime = (body["mime"] as? String) ?? "application/octet-stream"
            session = SaveSession(name: name, mime: mime)
        case "chunk":
            if let b64 = body["b64"] as? String { session?.append(base64: b64) }
        case "end":
            finish()
        case "pickPhotos":
            liveBridge?.present(from: self, webView: web)
        default:
            break
        }
    }

    private func finish() {
        guard let s = session else { return }
        session = nil
        s.close()
        let url = s.fileURL

        // 页面导出的「实况配对素材」是 ZIP：封面 + 视频，直接写成原生 Live Photo。
        // 不靠 mime 判断——页面造包时可能不带类型，按文件头 PK\x03\x04 才稳。
        if isZipFile(url), LivePhotoExport.saveIfPair(zipURL: url, completion: { [weak self] ok in
            if !ok { self?.alert("实况保存失败", "相册可能拒绝了这条写入，试试重新导出一次。") }
        }) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            return
        }

        let isImage = s.mime.hasPrefix("image/")
        let isVideo = s.mime.hasPrefix("video/")
        if isImage || isVideo { saveToPhotos(url, isVideo: isVideo) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        share(url)
    }

    private func isZipFile(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        return (fh.readData(ofLength: 4) == Data([0x50, 0x4b, 0x03, 0x04]))
    }

    private func alert(_ title: String, _ body: String) {
        let ac = UIAlertController(title: title, message: body, preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "好", style: .default))
        present(ac, animated: true)
    }

    private func saveToPhotos(_ url: URL, isVideo: Bool) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                if isVideo {
                    _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } else {
                    _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
            } completionHandler: { _, _ in }
        }
    }

    private func share(_ url: URL) {
        if presentedViewController != nil { return }   // 连导多张时不叠弹面板
        let ac = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = ac.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        present(ac, animated: true)
    }

    // MARK: - 链接

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url,
           navigationAction.navigationType == .linkActivated,
           let scheme = url.scheme, scheme == "http" || scheme == "https" {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
