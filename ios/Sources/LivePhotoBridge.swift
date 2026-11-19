import UIKit
import Photos
import PhotosUI
import UniformTypeIdentifiers
import WebKit

/// 相册里的实况照片 → 页面能吃的「同名 HEIC + MOV」。
///
/// 页面本身的识别规则是：两个文件主文件名相同就当成一组实况。
/// 这里做的事就是把 PHAsset 的两段资源（photo / pairedVideo）写成临时文件，
/// 再用分块 Base64 把字节送进页面，由页面脚本拼成 File 塞进 #file，
/// 于是「点一下就选完」而不需要用户去文件 App 里手动凑一对。
final class LivePhotoBridge: NSObject, PHPickerViewControllerDelegate {

    weak var webView: WKWebView?
    weak var presenter: UIViewController?
    private var fallbackPicker: UIDocumentPickerDelegate?

    func present(from vc: UIViewController, webView: WKWebView) {
        self.presenter = vc
        self.webView = webView

        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                guard status == .authorized || status == .limited else {
                    self.presentDocumentPicker(from: vc)
                    return
                }
                var cfg = PHPickerConfiguration(photoLibrary: PHPhotoLibrary.shared())
                cfg.filter = .any(of: [.images, .livePhotos, .videos])
                cfg.selectionLimit = 0
                cfg.preferredAssetRepresentationMode = .current
                let picker = PHPickerViewController(configuration: cfg)
                picker.delegate = self
                vc.present(picker, animated: true)
            }
        }
    }

    // MARK: - PHPicker

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }

        let group = DispatchGroup()
        var items: [(name: String, mime: String, url: URL)] = []
        let lock = NSLock()

        for r in results {
            guard let id = r.assetIdentifier else { continue }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
            guard let asset = assets.firstObject else { continue }

            let resources = PHAssetResource.assetResources(for: asset)
            let isLive = asset.mediaSubtypes.contains(.photoLive)
            let base = Self.baseName(for: asset, resources: resources)

            if isLive,
               let photo = resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto }),
               let paired = resources.first(where: { $0.type == .pairedVideo }) {
                let photoName = Self.fileName(base: base, ext: Self.ext(of: photo.originalFilename, fallback: "HEIC"))
                let videoName = Self.fileName(base: base, ext: Self.ext(of: paired.originalFilename, fallback: "MOV"))
                group.enter()
                Self.write(photo, name: photoName) { url in
                    if let url = url { lock.lock(); items.append((photoName, Self.mime(photoName), url)); lock.unlock() }
                    group.leave()
                }
                group.enter()
                Self.write(paired, name: videoName) { url in
                    if let url = url { lock.lock(); items.append((videoName, Self.mime(videoName), url)); lock.unlock() }
                    group.leave()
                }
            } else if let one = resources.first(where: {
                $0.type == .photo || $0.type == .fullSizePhoto || $0.type == .video
            }) {
                let name = Self.fileName(base: base, ext: Self.ext(of: one.originalFilename, fallback: one.type == .video ? "MOV" : "JPG"))
                group.enter()
                Self.write(one, name: name) { url in
                    if let url = url { lock.lock(); items.append((name, Self.mime(name), url)); lock.unlock() }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            guard !items.isEmpty else {
                self.alert("没有读到可用的照片", "这张照片可能只在 iCloud 上，先下载到本机再试。")
                return
            }
            self.deliver(items)
        }
    }

    // MARK: - 送进页面

    private func deliver(_ items: [(name: String, mime: String, url: URL)]) {
        guard let web = webView else { return }
        var payloads: [(name: String, mime: String, b64: String)] = []
        for it in items {
            guard let data = try? Data(contentsOf: it.url) else { continue }
            payloads.append((it.name, it.mime, data.base64EncodedString()))
        }
        guard !payloads.isEmpty else { return }

        for p in payloads {
            let total = max(1, Int(ceil(Double(p.b64.count) / 180000.0)))
            web.evaluateJavaScript("window.__irisLiveFile(\(Self.js(p.name)), \(Self.js(p.mime)), \(total));",
                                   completionHandler: nil)
            var i = 0
            while i < total {
                let start = p.b64.index(p.b64.startIndex, offsetBy: i * 180000)
                let end = p.b64.index(start, offsetBy: min(180000, p.b64.count - i * 180000))
                let chunk = String(p.b64[start..<end])
                web.evaluateJavaScript("window.__irisLiveChunk(\(Self.js(p.name)), \(i), \(Self.js(chunk)));",
                                       completionHandler: nil)
                i += 1
            }
            web.evaluateJavaScript("window.__irisLiveFileEnd(\(Self.js(p.name)));", completionHandler: nil)
        }
    }

    private static func js(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
              let raw = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(raw.dropFirst().dropLast())
    }

    // MARK: - 资源落盘

    private static func write(_ resource: PHAssetResource, name: String, done: @escaping (URL?) -> Void) {
        let url = tempURL(name)
        try? FileManager.default.removeItem(at: url)
        let opts = PHAssetResourceCreationOptions()
        opts.originalFilename = name
        PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: opts) { err in
            DispatchQueue.main.async { done(err == nil ? url : nil) }
        }
    }

    private static func tempURL(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-live", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var target = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) {
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let ns = name as NSString
            target = dir.appendingPathComponent("\(ns.deletingPathExtension)_\(stamp).\(ns.pathExtension)")
        }
        return target
    }

    private static func baseName(for asset: PHAsset, resources: [PHAssetResource]) -> String {
        if let n = resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto })?.originalFilename {
            let base = (n as NSString).deletingPathExtension
            if !base.isEmpty { return base }
        }
        return "IMG_\(Int(Date().timeIntervalSince1970))"
    }

    private static func ext(of name: String, fallback: String) -> String {
        let e = (name as NSString).pathExtension
        return e.isEmpty ? fallback : e.uppercased()
    }

    private static func fileName(base: String, ext: String) -> String { "\(base).\(ext.lowercased())" }

    private static func mime(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "heic", "heif": return "image/heic"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "mov": return "video/quicktime"
        case "mp4", "m4v": return "video/mp4"
        default: return "application/octet-stream"
        }
    }

    // MARK: - 兜底：文件选择器

    private func presentDocumentPicker(from vc: UIViewController) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image, .movie, .data], asCopy: true)
        picker.allowsMultipleSelection = true
        let delegate = DocumentFallback()
        delegate.onPick = { [weak self] urls in
            guard let self = self, !urls.isEmpty else { return }
            self.deliver(urls.map { ($0.lastPathComponent, Self.mime($0.lastPathComponent), $0) })
            self.fallbackPicker = nil
        }
        picker.delegate = delegate
        fallbackPicker = delegate
        vc.present(picker, animated: true)
    }

    private func alert(_ title: String, _ body: String) {
        let ac = UIAlertController(title: title, message: body, preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "好", style: .default))
        presenter?.present(ac, animated: true)
    }
}

/// UIDocumentPicker 的轻量代理，选完把 URL 交回去。
final class DocumentFallback: NSObject, UIDocumentPickerDelegate {
    var onPick: (([URL]) -> Void)?
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        onPick?(urls)
    }
}
