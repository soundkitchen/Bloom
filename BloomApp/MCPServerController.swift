import Foundation
import System
import MCP

/// アプリ内蔵の MCP サーバ。起動済みアプリの Unix ソケットに bloom-mcp(stdio ブリッジ)が
/// 接続し、エージェントはユーザーが見ているキャンバスをライブに操作する。
///
/// - フレーミングは SDK の StdioTransport を接続済みソケット fd に被せて流用する
///   (StdioTransport は任意の fd ペアで動く改行区切り JSON-RPC。カスタム Transport 不要)
/// - 接続ごとに新しい Server を作り、切断(waitUntilCompleted)後に次を受ける
/// - ツールの実体はすべて @MainActor(MCPTools.swift)。SDK のハンドラから await で hop する
@MainActor
final class MCPServerController {
    private weak var canvas: CanvasView?
    private var listener: MCPSocketListener?
    private var acceptTask: Task<Void, Never>?
    private var isServing = false

    /// ステータスバー表示用("待機中" / "接続中" / 無効理由)
    var onStatusChanged: ((String) -> Void)?

    init(canvas: CanvasView) {
        self.canvas = canvas
    }

    func start() {
        do {
            let listener = try MCPSocketListener(path: MCPSocketListener.socketPath())
            self.listener = listener
            onStatusChanged?("MCP: 待機中")
            acceptTask = Task { [weak self] in
                for await fd in listener.connections {
                    guard let self else {
                        close(fd)
                        return
                    }
                    // 同時 1 クライアント。2 本目は即 close(ブリッジ側は EOF で終了する)
                    if self.isServing {
                        close(fd)
                        continue
                    }
                    self.isServing = true
                    Task { [weak self] in
                        await self?.serve(fd: fd)
                        self?.isServing = false
                        self?.onStatusChanged?("MCP: 待機中")
                    }
                }
            }
        } catch MCPSocketListener.ListenerError.anotherInstance {
            onStatusChanged?("MCP: 無効(別の Bloom が待機中)")
        } catch {
            onStatusChanged?("MCP: 無効(\(error.localizedDescription))")
        }
    }

    func stop() {
        acceptTask?.cancel()
        listener?.shutdown()
        listener = nil
    }

    /// 1 接続 = 1 セッション。切断まで面倒を見る
    private func serve(fd: Int32) async {
        onStatusChanged?("MCP: 接続中")
        let transport = StdioTransport(
            input: FileDescriptor(rawValue: fd),
            output: FileDescriptor(rawValue: fd)
        )
        let server = Server(
            name: "Bloom",
            version: "0.1.0",
            instructions: """
            Bloom は水彩・水墨の滲みシミュレーションで絵を描く macOS アプリ。\
            このサーバはユーザーがいま開いているキャンバスをそのまま操作する(描く様子はライブで見える)。\
            座標は原点左上・y 下向き・単位 pt。キャンバス寸法は get_canvas_info で確認すること。\
            ウェットな絵の具は時間とともに流れ・乾く。描いた直後の見た目は変わり続けるので、\
            仕上がりを確認するときは wait_for_dry → snapshot の順で呼ぶとよい。
            """,
            capabilities: .init(tools: .init(listChanged: false))
        )
        _ = await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: BloomMCPTools.all)
        }
        _ = await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self else { throw MCPError.internalError("アプリが終了中です") }
            return try await self.callTool(name: params.name, arguments: params.arguments ?? [:])
        }
        do {
            try await server.start(transport: transport)
            await server.waitUntilCompleted()
        } catch {
            // 接続確立に失敗しただけなので待機に戻る
        }
        await server.stop()
        close(fd)
    }

    private func callTool(name: String, arguments: [String: Value]) async throws -> CallTool.Result {
        guard let canvas, let engine = canvas.engine else {
            throw MCPError.internalError("キャンバスが初期化されていません")
        }
        guard let tool = BloomMCPTools.Name(rawValue: name) else {
            throw MCPError.invalidParams("不明なツール: \(name)")
        }
        return try await BloomMCPTools.handle(tool: tool, arguments: arguments, canvas: canvas, engine: engine)
    }
}
