import Foundation

/// MCP 接続を受ける Unix ドメインソケットの listener。
/// 受けた接続の fd を AsyncStream で渡すだけ。フレーミング(改行区切り JSON-RPC)は
/// SDK の StdioTransport をソケット fd に被せて使うので、ここでは関知しない。
final class MCPSocketListener {
    enum ListenerError: Error {
        case anotherInstance        // 別の Bloom が同じソケットで待ち受け中
        case pathTooLong(String)
        case socketFailed(String)
    }

    /// 既定パス: ~/Library/Application Support/Bloom/mcp.sock(BLOOM_MCP_SOCKET で上書き可)
    static func socketPath() -> String {
        if let override = ProcessInfo.processInfo.environment["BLOOM_MCP_SOCKET"] {
            return override
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Bloom/mcp.sock").path
    }

    let path: String
    let connections: AsyncStream<Int32>
    private let fd: Int32
    private let source: DispatchSourceRead
    private let continuation: AsyncStream<Int32>.Continuation

    init(path: String) throws {
        self.path = path

        // 残骸ソケットの処理: 接続できたら別インスタンスが生きている。
        // 拒否されたら前回の異常終了の残骸なので消して使う。
        if FileManager.default.fileExists(atPath: path) {
            if let probe = Self.connect(to: path) {
                close(probe)
                throw ListenerError.anotherInstance
            }
            unlink(path)
        }

        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ListenerError.socketFailed("socket: \(String(cString: strerror(errno)))") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let fits = path.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst -> Bool in
                guard strlen(src) < dst.count else { return false }
                strcpy(dst.baseAddress!.assumingMemoryBound(to: CChar.self), src)
                return true
            }
        }
        guard fits else {
            close(fd)
            throw ListenerError.pathTooLong(path)
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 2) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw ListenerError.socketFailed("bind/listen: \(message)")
        }
        chmod(path, 0o600) // ユーザーローカル専用

        self.fd = fd
        var continuation: AsyncStream<Int32>.Continuation!
        self.connections = AsyncStream { continuation = $0 }
        self.continuation = continuation

        // accept は readiness 通知(DispatchSource)で受ける。ブロッキング accept を作らない
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        self.source = source
        source.setEventHandler { [continuation] in
            let client = accept(fd, nil, nil)
            if client >= 0 { continuation?.yield(client) }
        }
        source.resume()
    }

    private static func connect(to path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let fits = path.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst -> Bool in
                guard strlen(src) < dst.count else { return false }
                strcpy(dst.baseAddress!.assumingMemoryBound(to: CChar.self), src)
                return true
            }
        }
        guard fits else {
            close(fd)
            return nil
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    func shutdown() {
        source.cancel()
        continuation.finish()
        close(fd)
        unlink(path)
    }
}
