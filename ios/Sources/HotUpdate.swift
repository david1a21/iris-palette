import Foundation
import CryptoKit

/// 页面热更新：包内的 index.html 只当“出厂版本”。
/// current/ = 用户点头过的页面，启动就加载它；pending/ = 下载好但没确认的页面，只询问，绝不擅自替换。
enum HotUpdate {

    static let manifestURL = URL(string: "https://raw.githubusercontent.com/david1a21/iris-palette/main/web/hot-update.json")!
    static let fallbackPageURL = URL(string: "https://raw.githubusercontent.com/david1a21/iris-palette/main/web/index.html")!

    private static var rootDir: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("IrisPage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var approvedDir: URL? { rootDir?.appendingPathComponent("current", isDirectory: true) }
    private static var pendingDir: URL? { rootDir?.appendingPathComponent("pending", isDirectory: true) }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return sha256(data)
    }

    private static func readSlot(_ dir: URL?) -> URL? {
        guard let dir = dir else { return nil }
        let page = dir.appendingPathComponent("index.html")
        let meta = dir.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: page),
              let metaData = try? Data(contentsOf: meta),
              let dict = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
              let expected = dict["sha256"] as? String,
              expected == sha256(data) else { return nil }
        return page
    }

    static func version(of page: URL) -> String {
        let dir = page.deletingLastPathComponent()
        guard let metaData = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              let dict = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
              let v = dict["version"] as? String else { return "" }
        return v
    }

    /// 启动时加载：只认已接受的页面；没有就回落到包内。
    static func pageForLaunch() -> URL? {
        if let page = readSlot(approvedDir) { return page }
        // 兼容旧版单槽缓存
        if let root = rootDir {
            let legacyPage = root.appendingPathComponent("index.html")
            let legacyMeta = root.appendingPathComponent("meta.json")
            if let data = try? Data(contentsOf: legacyPage),
               let metaData = try? Data(contentsOf: legacyMeta),
               let dict = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
               let expected = dict["sha256"] as? String, expected == sha256(data) {
                return legacyPage
            }
        }
        return nil
    }

    /// 待确认的新页面（下载好了但用户还没点“立即加载”）
    static func pendingPage() -> URL? {
        readSlot(pendingDir)
    }

    /// 用户点了“立即加载”后，把 pending 转正
    @discardableResult
    static func promotePending() -> URL? {
        guard let pending = pendingPage(),
              let dir = approvedDir,
              let pdir = pendingDir,
              let data = try? Data(contentsOf: pending) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("index.html")
        let tmp = dir.appendingPathComponent("index.html.tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: target)
            }
            let meta = pdir.appendingPathComponent("meta.json")
            if let metaData = try? Data(contentsOf: meta) {
                try metaData.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
            }
            try? FileManager.default.removeItem(at: pdir)
            return target
        } catch {
            NSLog("[hot-update] 转正失败：%@", error.localizedDescription)
            return nil
        }
    }

    static func bundledSHA() -> String? {
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html") else { return nil }
        return sha256(of: url)
    }

    /// 后台检查：只负责把新版下到 pending，换不换由用户决定；
    /// 下载成功后回调（主线程），交给外壳弹窗。
    static func checkInBackground(completion: ((String) -> Void)? = nil) {
        var request = URLRequest(url: manifestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let expected = dict["sha256"] as? String else { return }
            let version = dict["version"] as? String ?? ""

            let bundled = bundledSHA()
            let active = pageForLaunch().flatMap { sha256(of: $0) }
            if expected == bundled || expected == active {
                // 远端就是当前在用的版本，顺手清掉多余 pending
                if let pdir = pendingDir { try? FileManager.default.removeItem(at: pdir) }
                return
            }
            if let pending = pendingPage(), sha256(of: pending) == expected {
                DispatchQueue.main.async { completion?(version) }
                return
            }

            let pageURL = (dict["url"] as? String).flatMap(URL.init(string:)) ?? fallbackPageURL
            var pageRequest = URLRequest(url: pageURL)
            pageRequest.cachePolicy = .reloadIgnoringLocalCacheData
            URLSession.shared.dataTask(with: pageRequest) { data, _, _ in
                guard let pageData = data, sha256(pageData) == expected,
                      let dir = pendingDir else { return }
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try pageData.write(to: dir.appendingPathComponent("index.html"), options: .atomic)
                    let meta: [String: Any] = ["version": version, "sha256": expected, "size": pageData.count]
                    if let metaData = try? JSONSerialization.data(withJSONObject: meta) {
                        try metaData.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
                    }
                    NSLog("[hot-update] 已下载 %@，等待用户确认", version)
                    DispatchQueue.main.async { completion?(version) }
                } catch {
                    NSLog("[hot-update] 落盘失败：%@", error.localizedDescription)
                }
            }.resume()
        }.resume()
    }
}
