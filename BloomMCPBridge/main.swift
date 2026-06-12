import Foundation

// bloom-mcp: Claude Code が spawn する stdio ブリッジ。
// stdin/stdout と起動済み Bloom.app の Unix ソケットを素通しでつなぐだけ
// (改行区切り JSON-RPC のフレーミングも解釈しない。MCP のプロトコル処理は全てアプリ側)。
// 診断メッセージは stderr のみに書く: stdout はプロトコル専用チャネル。

private func log(_ message: String) {
    FileHandle.standardError.write(Data(("bloom-mcp: " + message + "\n").utf8))
}

private func defaultSocketPath() -> String {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return appSupport.appendingPathComponent("Bloom/mcp.sock").path
}

private func connectOnce(path: String) -> Int32? {
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
        log("ソケットパスが長すぎます: \(path)")
        return nil
    }
    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        close(fd)
        return nil
    }
    return fd
}

/// 200ms 間隔で最大 10 秒リトライ(アプリの起動直後を拾う)。自動起動はしない。
private func connectWithRetry(path: String) -> Int32? {
    for _ in 0..<50 {
        if let fd = connectOnce(path: path) { return fd }
        usleep(200_000)
    }
    return nil
}

/// src → dst へバイトを流し続け、EOF/エラーで戻る
private func pump(from src: Int32, to dst: Int32) {
    var buf = [UInt8](repeating: 0, count: 65536)
    outer: while true {
        let n = read(src, &buf, buf.count)
        if n <= 0 { break }
        var off = 0
        while off < n {
            // &buf[off] は「要素 1 個の一時コピー」へのポインタになるので不可。配列本体を指す
            let w = buf.withUnsafeBytes { raw in
                write(dst, raw.baseAddress!.advanced(by: off), n - off)
            }
            if w <= 0 { break outer }
            off += w
        }
    }
}

signal(SIGPIPE, SIG_IGN)

let socketPath = ProcessInfo.processInfo.environment["BLOOM_MCP_SOCKET"] ?? defaultSocketPath()
guard let sock = connectWithRetry(path: socketPath) else {
    log("Bloom.app に接続できませんでした(\(socketPath))。アプリを起動してください: make run")
    exit(1)
}
log("接続しました: \(socketPath)")

// half-close を正しく扱う:
// - stdin EOF(クライアント終了)では書き込み側だけ shutdown し、サーバからの
//   送信途中の応答は最後まで stdout へ流し切る(即死すると応答が欠ける)
// - socket EOF(サーバ切断)で全体を畳む
let done = DispatchSemaphore(value: 0)
Thread.detachNewThread {
    pump(from: 0, to: sock) // stdin → socket
    shutdown(sock, SHUT_WR) // サーバに EOF を伝える(読み取りは続行)
}
Thread.detachNewThread {
    pump(from: sock, to: 1) // socket → stdout
    done.signal()
}
done.wait()
close(sock)
exit(0)
