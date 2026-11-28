import Foundation
import Darwin

/// 把包内页面（或热更新页面）用 http://127.0.0.1:<端口> 提供给 WKWebView。
///
/// 为什么要这么绕：`getUserMedia` 只在安全上下文里可用，而 `file://` 在 WKWebView 里
/// 不算安全上下文，相机请求会被直接拒绝，连系统权限框都不会出现。
/// 换成本机回环地址后，页面来源变成 http://127.0.0.1，camera 才能走通。
///
/// 端口固定（默认 18471）而不是随机：origin 一旦每次启动都变，
/// 页面的 localStorage 就等于每次都被清空，用户的设置会反复丢。
/// 固定端口被占用时才退回随机，宁可这一轮丢设置也要保证页面能开。
/// 只服务 index.html 一个文件，端口仅监听回环地址，外部访问不到。
final class LocalPageServer {

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "iris.page.server", attributes: .concurrent)
    private var _page: URL?
    private var listener: Int32 = -1
    private(set) var port: Int32 = 0

    /// 当前要对外提供的页面文件；切换热更新页时直接改这个值即可。
    var pageURL: URL? {
        get { lock.lock(); defer { lock.unlock() }; return _page }
        set { lock.lock(); _page = newValue; lock.unlock() }
    }

    /// WebView 应该加载的入口地址。
    var entryURL: URL? {
        guard port > 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/index.html")
    }

    @discardableResult
    func start(preferredPort: UInt16 = 18471) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard listener < 0 else { return true }

        if let made = makeListener(preferredPort) {
            listener = made.0
            port = made.1
        } else if let made = makeListener(0) {
            listener = made.0
            port = made.1
        } else {
            return false
        }

        let lfd = listener
        queue.async { [weak self] in self?.acceptLoop(lfd) }
        return true
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        if listener >= 0 { close(listener); listener = -1 }
    }

    /// 建一个监听 127.0.0.1 的 socket，返回 (句柄, 实际端口)。
    private func makeListener(_ wanted: UInt16) -> (Int32, Int32)? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(wanted).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(fd); return nil }

        var got = sockaddr_in()
        var glen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &glen)
            }
        }
        guard listen(fd, 32) == 0 else { close(fd); return nil }

        return (fd, Int32(UInt16(bigEndian: got.sin_port)))
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            var caddr = sockaddr()
            var clen = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(fd, &caddr, &clen)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            queue.async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }

        var chunk = [UInt8](repeating: 0, count: 2048)
        var head = [UInt8]()
        while head.count < 8192 {
            let n = chunk.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(client, raw.baseAddress, raw.count)
            }
            if n <= 0 { break }
            head.append(contentsOf: chunk[0..<n])
            if head.contains(0x0A) { break }
        }
        guard !head.isEmpty else { return }

        let full = String(decoding: head, as: UTF8.self)
        let requestLine = full.components(separatedBy: "\r\n").first ?? full
        let parts = requestLine.split(separator: " ")
        let path = parts.count > 1 ? String(parts[1]) : "/"
        let isIndex = path == "/" || path.hasPrefix("/index.html")

        guard isIndex, let page = pageURL, let data = try? Data(contentsOf: page) else {
            respond(client, status: "404 Not Found", type: "text/plain; charset=utf-8",
                    body: Data("not found".utf8))
            return
        }
        respond(client, status: "200 OK", type: "text/html; charset=utf-8", body: data)
    }

    private func respond(_ client: Int32, status: String, type: String, body: Data) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(type)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n\r\n"

        var out = Data(header.utf8)
        out.append(body)
        out.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(client, base.advanced(by: offset), raw.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }
}
