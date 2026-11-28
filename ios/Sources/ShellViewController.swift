import UIKit
import WebKit
import Photos
import AVFoundation

/// 只做一件事：把页面装进一个像样的容器。
/// 页面本身一份不改（Resources/index.html 与用户给的 HTML 逐字节一致），
/// 系统侧缺的东西在外壳补：保存到相册 / 分享 / 安全区 / 系统选择器放宽。
final class ShellViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {

    private let ink = UIColor(red: 8.0 / 255.0, green: 8.0 / 255.0, blue: 10.0 / 255.0, alpha: 1.0)
    private var web: WKWebView!
    private var session: SaveSession?
    private weak var edgePan: UIScreenEdgePanGestureRecognizer?
    private var liveBridge: LivePhotoBridge?
    private let liveExporter = LiveExportCoordinator()
    private let pageServer = LocalPageServer()   /* 页面走 http://127.0.0.1，相机才被认作安全上下文 */
    private var loadedPageSHA: String?          /* 当前正在显示的页面哈希，用于判断热更新是否真的换了内容 */

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersHomeIndicatorAutoHidden: Bool { false }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ink

        // 首次启动就让系统把相机授权框弹出来（Info.plist 里已声明用途）。
        // 必须在建 WKWebView 之前问，WebKit 只有在原生侧已获授权时才放行 getUserMedia。
        prepareCameraAccess()

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
        web.uiDelegate = self
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
        liveExporter.webView = web
        liveExporter.onAlert = { [weak self] title, body in self?.alert(title, body) }

        // 有校验通过的热更新页面就先用它，没有就回落到包内出厂版本。
        let launchPage = HotUpdate.pageForLaunch()
            ?? Bundle.main.url(forResource: "index", withExtension: "html")
        if let page = launchPage {
            loadedPageSHA = HotUpdate.sha256(of: page)
            loadPage(page)
        }
        // 上次没确认的 pending：这次启动再问一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.offerHotUpdate()
        }
        // 后台发现新版页面时同样只询问，不偷偷换页
        HotUpdate.checkInBackground { [weak self] _ in
            self?.offerHotUpdate()
        }
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

    // MARK: - 页面加载（回环 HTTP，保证安全上下文）

    /// 优先走本机回环服务：http://127.0.0.1 属于可信来源，
    /// file:// 则不是，getUserMedia 会被 WebKit 直接拒掉。
    /// 服务起不来时退回原来的文件加载，至少页面还能用。
    private func loadPage(_ page: URL) {
        pageServer.pageURL = page
        if pageServer.start(), let entry = pageServer.entryURL {
            web.load(URLRequest(url: entry))
        } else {
            web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
    }

    // MARK: - 相机权限

    /// 没问过就弹系统框；已经拒绝过则给出一个能直达设置的提示。
    private func prepareCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if !granted { NSLog("[iris] camera access denied by user") }
            }
        case .denied, .restricted:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.offerCameraSettings()
            }
        default:
            break
        }
    }

    private func offerCameraSettings() {
        guard presentedViewController == nil else { return }
        let ac = UIAlertController(
            title: "相机权限没有打开",
            message: "实时相机模式需要相机权限。\n到「设置 → Iris 调色盘 → 相机」打开即可，下次进相机模式会直接可用。",
            preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "去设置", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        })
        ac.addAction(UIAlertAction(title: "暂不", style: .cancel))
        present(ac, animated: true)
    }

    /// 页面调 getUserMedia 时 WebKit 会来问这一句。我们已经在 Info.plist 里声明了用途，
    /// 用户也在系统层授过权，这里直接放行；用户的拒绝仍由系统开关控制。
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
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
        case "exportLive":
            liveExporter.start()
        case "liveBegin":
            liveExporter.begin(body)
        case "liveChunk":
            liveExporter.append(body)
        case "liveEnd":
            liveExporter.end(body)
        case "liveFramesBegin":
            liveExporter.beginFrames(body)
        case "liveFrame":
            liveExporter.appendFrame(body)
        case "liveFramesCancel":
            liveExporter.cancelFrames()
        case "liveFail":
            alert("实况导出失败", (body["msg"] as? String) ?? "未知错误")
        case "cloud":
            CloudSync.shared.handle(body, web: web)
        case "liveNote":
            alert("导出提示", (body["msg"] as? String) ?? "")
        case "segmentPerson":
            let mid = (body["id"] as? String) ?? "0"
            guard let b64 = body["b64"] as? String else {
                // 没拿到图也要回一句，否则页面的 busy 会一直挂着
                web.evaluateJavaScript("window.__irisMaskResult && window.__irisMaskResult('\(mid)',0,'',0,0)",
                                       completionHandler: nil)
                return
            }
            PersonMask.generate(jpegBase64: b64) { [weak self] png, w, h, note in
                guard let self = self else { return }
                if let png = png {
                    self.web.evaluateJavaScript(
                        "window.__irisMaskResult && window.__irisMaskResult('\(mid)',1,'\(png)',\(w),\(h))",
                        completionHandler: nil)
                } else {
                    self.web.evaluateJavaScript(
                        "window.__irisMaskResult && window.__irisMaskResult('\(mid)',0,'',0,0)",
                        completionHandler: nil)
                    NSLog("[iris] person mask failed: %@", note)
                }
            }
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

    /// 热更新确认：只有 pending 与当前已加载页确实不同才问。
    /// 选“稍后提醒”什么都不做——旧页面继续用，下次启动还会再问一次。
    private func offerHotUpdate() {
        guard let pending = HotUpdate.pendingPage(),
              HotUpdate.sha256(of: pending) != loadedPageSHA,
              presentedViewController == nil else { return }
        let version = HotUpdate.version(of: pending)
        let sheet = UIAlertController(
            title: "发现新版本页面",
            message: "已下载 \(version.isEmpty ? "新页面" : version)，是否立即加载？\n现在加载会重开当前页面；选“稍后提醒”则保持现状，下次启动再问你。",
            preferredStyle: .alert)
        sheet.addAction(UIAlertAction(title: "立即加载", style: .default) { [weak self] _ in
            guard let self = self, let page = HotUpdate.promotePending() else { return }
            self.loadedPageSHA = HotUpdate.sha256(of: page)
            self.loadPage(page)
        })
        sheet.addAction(UIAlertAction(title: "稍后提醒", style: .cancel))
        present(sheet, animated: true)
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

    /// 回环服务万一被系统拦下（ATS 或端口异常），别留一屏白：
    /// 退回原来的文件加载，页面至少能用，只是这一轮没有相机。
    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        guard let page = pageServer.pageURL,
              let scheme = webView.url?.scheme, scheme == "http" else { return }
        NSLog("[iris] loopback load failed: %@", error.localizedDescription)
        web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    }

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
