import Foundation
import CryptoKit

/// 页面热更新：包内的 index.html 只当“出厂版本”。
/// 启动时优先用 Application Support 里校验通过的新页面，并在后台按内容哈希静默检查更新。
/// 页面本身是纯数据（HTML/CSS/JS 资源），壳层逻辑没有任何硬编码依赖。
enum HotUpdate {

    static let manifestURL = URL(string: "https://raw.githubusercontent.com/david1a21/iris-palette/main/web/hot-update.json")!
    static let fallbackPageURL = URL(string: "https://raw.githubusercontent.com/david1a21/iris-palette/main/web/index.html")!

    private static var cacheDir: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("IrisPage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return sha256(data)
    }

    /// 启动时要加载的页面：缓存有效就用缓存，否则回落到包内。
    static func pageForLaunch() -> URL? {
        guard let dir = cacheDir else { return nil }
        let page = dir.appendingPathComponent("index.html")
        let meta = dir.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: page),
              let metaData = try? Data(contentsOf: meta),
              let dict = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
              let expected = dict["sha256"] as? String,
              expected == sha256(data) else { return nil }
        return page
    }

    static func bundledSHA() -> String? {
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html"),
              let data = try? Data(contentsOf: url) else { return nil }
        return sha256(data)
    }

    /// 后台静默检查：下载 → 校验 → 原子替换，下次启动生效。失败一律忽略。
    static func checkInBackground(completion: ((String) -> Void)? = nil) {
        var request = URLRequest(url: manifestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let expected = dict["sha256"] as? String else { return }
            let bundled = bundledSHA()
            if expected == bundled { return }
            if let page = pageForLaunch() {
                if (try? Data(contentsOf: page)).map(sha256) == expected { return }
            }
            let pageURL = (dict["url"] as? String).flatMap(URL.init(string:)) ?? fallbackPageURL
            var pageRequest = URLRequest(url: pageURL)
            pageRequest.cachePolicy = .reloadIgnoringLocalCacheData
            URLSession.shared.dataTask(with: pageRequest) { data, _, _ in
                guard let pageData = data, sha256(pageData) == expected,
                      let dir = cacheDir else { return }
                let tmp = dir.appendingPathComponent("index.html.tmp")
                let target = dir.appendingPathComponent("index.html")
                do {
                    try pageData.write(to: tmp, options: .atomic)
                    if FileManager.default.fileExists(atPath: target.path) {
                        _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
                    } else {
                        try FileManager.default.moveItem(at: tmp, to: target)
                    }
                    let meta: [String: Any] = [
                        "version": dict["version"] as? String ?? "",
                        "sha256": expected,
                        "size": pageData.count,
                    ]
                    if let metaData = try? JSONSerialization.data(withJSONObject: meta) {
                        try metaData.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
                    }
                    NSLog("[hot-update] 已缓存新页面")
                    if let completion = completion {
                        let version = dict["version"] as? String ?? ""
                        DispatchQueue.main.async { completion(version) }
                    }
                } catch {
                    NSLog("[hot-update] 落盘失败：%@", error.localizedDescription)
                }
            }.resume()
        }.resume()
    }
}
