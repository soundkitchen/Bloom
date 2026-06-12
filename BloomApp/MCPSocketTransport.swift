import Foundation
import Logging
import MCP

/// 接続済み Unix ソケット 1 本を包む Transport 実装(改行区切り JSON-RPC)。
///
/// SDK の StdioTransport を流用しない理由(重要): StdioTransport.send は送信バッファが
/// 満杯(EAGAIN)になると `await Task.sleep` で待つが、actor は suspension 中に再入可能な
/// ため、巨大応答(snapshot は 1 行 ~840KB)の書き込み途中に別ハンドラの send が割り込んで
/// **メッセージのバイト列が混線**する。並列ツール呼び出しで実際に発生し、クライアントが
/// 壊れた JSON 行を読み捨てて応答が永遠に届かなくなった(devlog 2026-06-12 追記 3)。
///
/// ここでは send はキューに積むだけにし、**単一のドレインループ**だけが fd へ書く。
/// suspension 中に send が再入してもキューが伸びるだけで、書き込みは混ざらない。
actor MCPSocketTransport: Transport {
    nonisolated let logger: Logger

    private let fd: Int32
    private var isConnected = false
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    private var sendQueue: [Data] = []
    private var isDraining = false
    private var sendError: Swift.Error?

    init(fd: Int32) {
        self.fd = fd
        self.logger = Logger(label: "bloom.mcp.socket") { _ in SwiftLogNoOpLogHandler() }
        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.messageStream = AsyncThrowingStream { continuation = $0 }
        self.messageContinuation = continuation
    }

    func connect() async throws {
        guard !isConnected else { return }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw MCPError.transportError(POSIXError(.EBADF))
        }
        isConnected = true
        Task { await readLoop() }
    }

    func disconnect() async {
        guard isConnected else { return }
        isConnected = false
        messageContinuation.finish()
    }

    func send(_ message: Data) async throws {
        if let sendError { throw sendError }
        guard isConnected else { throw MCPError.transportError(POSIXError(.ENOTCONN)) }
        var data = message
        data.append(UInt8(ascii: "\n"))
        sendQueue.append(data)
        try await drainQueue()
    }

    /// 単一ライター。進行中のドレインがあれば任せる(キューに積んだ時点で送信は保証される)
    private func drainQueue() async throws {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        while !sendQueue.isEmpty, isConnected {
            var remaining = sendQueue.removeFirst()
            while !remaining.isEmpty {
                let written = remaining.withUnsafeBytes { raw in
                    write(fd, raw.baseAddress, raw.count)
                }
                if written > 0 {
                    remaining = remaining.dropFirst(written)
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    // 受け手(ブリッジ)が詰まっている。suspension 中の send 再入は
                    // キューに積まれるだけなので混線しない
                    try await Task.sleep(for: .milliseconds(5))
                } else {
                    let error = MCPError.transportError(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                    sendError = error
                    isConnected = false
                    messageContinuation.finish()
                    throw error
                }
            }
        }
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        messageStream
    }

    private func readLoop() async {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var pending = Data()
        while isConnected, !Task.isCancelled {
            let n = buffer.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress, raw.count)
            }
            if n > 0 {
                pending.append(contentsOf: buffer[0..<n])
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let message = Data(pending[..<newline])
                    pending = Data(pending[(newline + 1)...]) // スライスを複製してインデックスを0起点に戻す
                    if !message.isEmpty { messageContinuation.yield(message) }
                }
            } else if n == 0 {
                break // EOF(クライアント切断 / takeover の shutdown)
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                try? await Task.sleep(for: .milliseconds(10))
            } else {
                break // 予期しないエラー(EBADF 等)
            }
        }
        isConnected = false
        messageContinuation.finish()
    }
}
