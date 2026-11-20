import Foundation
import WebKit

/// 坚果云 / WebDAV 的最小代理。
///
/// 为什么不在页面里直接 fetch：`dav.jianguoyun.com` 不返回
/// `Access-Control-Allow-Origin`，WKWebView 会当成跨域请求直接掐断。
/// 所以 HTTP 全部交给这里代发，页面只收一段 base64：
///   页面 → {op:"cloud", id, method, url, authorization, body}
///   这里 → window.__irisCloudResult(id, ok, status, b64)
final class CloudSync {

    static let shared = CloudSync()

    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 45
        cfg.httpAdditionalHeaders = ["User-Agent": "Iris/1.0 (iOS)"]
        session = URLSession(configuration: cfg)
    }

    func handle(_ body: [String: Any], web: WKWebView) {
        guard let id = body["id"] as? String,
              let method = (body["method"] as? String)?.uppercased(),
              let urlText = body["url"] as? String,
              let url = URL(string: urlText) else { return }

        var req = URLRequest(url: url)
        req.httpMethod = method
        if let auth = body["authorization"] as? String, !auth.isEmpty {
            req.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        }
        if let b64 = body["body"] as? String, !b64.isEmpty, let data = Data(base64Encoded: b64) {
            req.httpBody = data
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }

        let task = session.dataTask(with: req) { [weak web] data, resp, err in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let ok = err == nil && status > 0
            let b64 = data?.base64EncodedString() ?? ""
            DispatchQueue.main.async {
                guard let web = web else { return }
                let js = "window.__irisCloudResult&&window.__irisCloudResult("
                    + Self.js(id) + "," + (ok ? "true" : "false") + "," + "\(status)" + "," + Self.js(b64) + ")"
                web.evaluateJavaScript(js, completionHandler: nil)
            }
        }
        task.resume()
    }

    /// 把任意字符串安全地塞进 JS 字面量（含中文 / 换行 / 引号）
    private static func js(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s], options: []),
              let arr = String(data: d, encoding: .utf8) else { return "\"\"" }
        return String(arr.dropFirst().dropLast())
    }
}
