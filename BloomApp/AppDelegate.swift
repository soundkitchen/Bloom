import AppKit
import BloomCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var canvas: CanvasView?
    private var inspector: InspectorView?
    private var statusLabel: NSTextField?

    private let inspectorWidth: CGFloat = 240
    private let statusHeight: CGFloat = 24

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let args = CommandLine.arguments
        if args.contains("--demo") || args.contains("--demo-dwell") || args.contains("--demo-layers") {
            // 検証モードはキャンバス全面(スナップショットを汚さない)
            buildDemoWindow(small: args.contains("--demo-dwell"))
        } else {
            buildInteractiveWindow()
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        handleLaunchArguments()
    }

    /// 通常起動: 中央キャンバス + 右インスペクタ + 下ステータスバー
    private func buildInteractiveWindow() {
        let winSize = NSSize(width: 1024, height: 720)
        let canvasRect = NSRect(
            x: 0, y: statusHeight,
            width: winSize.width - inspectorWidth, height: winSize.height - statusHeight
        )
        let canvas = CanvasView(frame: canvasRect, device: nil)
        canvas.autoresizingMask = [.width, .height]
        self.canvas = canvas

        let inspector = InspectorView(frame: NSRect(
            x: winSize.width - inspectorWidth, y: statusHeight,
            width: inspectorWidth, height: winSize.height - statusHeight
        ))
        inspector.autoresizingMask = [.minXMargin, .height]
        self.inspector = inspector

        let statusBar = makeStatusBar(width: winSize.width)

        let container = NSView(frame: NSRect(origin: .zero, size: winSize))
        container.addSubview(canvas)
        container.addSubview(inspector)
        container.addSubview(statusBar)

        // 配線: キャンバス ⇄ インスペクタ ⇄ ステータス
        canvas.onStatus = { [weak self] in self?.statusLabel?.stringValue = $0 }
        canvas.onBrushChanged = { [weak inspector] in inspector?.reflect(brush: $0) }
        inspector.onSelectBrush = { [weak canvas] in canvas?.selectBrush($0) }
        inspector.onSizeChange = { [weak canvas] in canvas?.setBrushRadius($0) }
        inspector.onWaterChange = { [weak canvas] in canvas?.setBrushWater($0) }
        inspector.onColorChange = { [weak canvas] in canvas?.setBrushColor($0) }
        inspector.onClear = { [weak canvas] in canvas?.engine?.clear() }

        inspector.onAddLayer = { [weak canvas] in canvas?.addLayer() }
        inspector.onDeleteLayer = { [weak canvas] in canvas?.deleteLayer(row: $0) }
        inspector.onSelectLayer = { [weak canvas] in canvas?.setActiveLayer(row: $0) }
        inspector.onToggleLayer = { [weak canvas] in canvas?.toggleLayer(row: $0) }
        inspector.onMoveLayer = { [weak canvas] in canvas?.moveLayer(from: $0, to: $1) }
        inspector.onSetLayerOpacity = { [weak canvas] in canvas?.setLayerOpacity(row: $0, opacity: $1) }
        canvas.onLayersChanged = { [weak canvas, weak inspector] in
            guard let canvas, let inspector else { return }
            inspector.reflectLayers(canvas.layerInfos, activeRow: canvas.activeLayerRow)
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: winSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Bloom — 無題"
        window.contentView = container
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        self.window = window

        if let brush = canvas.currentBrush { canvas.selectBrush(brush) } // 初期状態を UI に反映
        inspector.reflectLayers(canvas.layerInfos, activeRow: canvas.activeLayerRow)
    }

    /// 検証モード: キャンバスのみのウィンドウ
    private func buildDemoWindow(small: Bool) {
        let size: NSSize = small ? NSSize(width: 320, height: 320) : NSSize(width: 1024, height: 720)
        let canvas = CanvasView(frame: NSRect(origin: .zero, size: size), device: nil)
        self.canvas = canvas

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Bloom — demo"
        window.contentView = canvas
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        self.window = window
    }

    private func makeStatusBar(width: CGFloat) -> NSView {
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: width, height: statusHeight))
        bar.autoresizingMask = [.width]
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let separator = NSBox(frame: NSRect(x: 0, y: statusHeight - 1, width: width, height: 1))
        separator.boxType = .separator
        separator.autoresizingMask = [.width]
        bar.addSubview(separator)

        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 10, y: 4, width: width - 20, height: 16)
        label.autoresizingMask = [.width]
        bar.addSubview(label)
        self.statusLabel = label
        return bar
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// 自動検証モード:
    ///   --demo               デモストロークを自動実行
    ///   --snapshot-dir <dir> wet.png(直後)と dry.png(乾燥後)を書き出して終了
    private func handleLaunchArguments() {
        let args = CommandLine.arguments
        var snapshotDir: URL?
        if let i = args.firstIndex(of: "--snapshot-dir"), i + 1 < args.count {
            snapshotDir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        }

        if args.contains("--demo-dwell") {
            runDwellDemo(snapshotDir: snapshotDir)
            return
        }
        if args.contains("--demo-layers") {
            runLayersDemo(snapshotDir: snapshotDir)
            return
        }

        if args.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.canvas?.runDemoStrokes()
            }
        }
        if let dir = snapshotDir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                try? self?.canvas?.engine?.savePNG(to: dir.appendingPathComponent("wet.png"))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                try? self?.canvas?.engine?.savePNG(to: dir.appendingPathComponent("dry.png"))
                NSApp.terminate(nil)
            }
        }
    }

    /// ドウェル(筆を下ろしたまま動かさない)挙動の検証。
    /// 一点に筆を置いて 2.2 秒溜める → 持ち上げる → 乾かす、を pooled/dried で撮る。
    private func runDwellDemo(snapshotDir: URL?) {
        guard let engine = canvas?.engine else { return }
        let center = SIMD2<Float>(Float(engine.gridWidth) / 2, Float(engine.gridHeight) / 2)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            engine.brush = .watercolor
            engine.beginStroke()
            engine.addStrokeSample(at: center, pressure: 1.0) // 置いたまま動かさない
        }
        guard let dir = snapshotDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            try? engine.savePNG(to: dir.appendingPathComponent("pooled.png")) // 溜まった状態
            engine.endStroke() // 筆を持ち上げる
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) {
            try? engine.savePNG(to: dir.appendingPathComponent("dried.png")) // 乾いた状態
            NSApp.terminate(nil)
        }
    }

    /// レイヤー検証: 層1に青の波線、層2に赤の払い → 合成 → 表示切替を撮る
    private func runLayersDemo(snapshotDir: URL?) {
        guard let engine = canvas?.engine else { return }
        let w = Float(engine.gridWidth), h = Float(engine.gridHeight)

        func wave(_ brush: SimulationEngine.Brush) {
            engine.brush = brush
            engine.beginStroke()
            for i in 0..<90 {
                let t = Float(i) / 89
                engine.addStrokeSample(
                    at: SIMD2(0.12 * w + 0.76 * w * t, 0.45 * h + 0.14 * h * sin(t * .pi * 2.4)),
                    pressure: 0.2 + 0.7 * sin(t * .pi))
            }
            engine.endStroke()
        }
        func diagonal(_ brush: SimulationEngine.Brush) {
            engine.brush = brush
            engine.beginStroke()
            for i in 0..<70 {
                let t = Float(i) / 69
                engine.addStrokeSample(
                    at: SIMD2(0.2 * w + 0.6 * w * t, 0.2 * h + 0.55 * h * t),
                    pressure: 0.75 - 0.3 * t)
            }
            engine.endStroke()
        }
        // 順序の効果がはっきり見えるよう濃いめの不透明寄りに(薄いウォッシュだと順序差は微小)
        var blue = SimulationEngine.Brush.watercolor
        blue.pigment = 0.5
        var red = SimulationEngine.Brush.watercolor
        red.color = SIMD3(0.62, 0.14, 0.16)
        red.pigment = 0.5

        // 注意: ウェット顔料は「乾いた時点でアクティブな層」に沈着する。
        // 層1の青が乾いてから層2へ移る必要があるので十分待つ。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            wave(blue)                 // 層1(下): 青(濃いめ)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) {
            engine.addLayer()          // 青が乾いてから層2(上)を追加してアクティブに
            diagonal(red)              // 層2: 赤
        }
        guard let dir = snapshotDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 11.0) {
            try? engine.savePNG(to: dir.appendingPathComponent("layers-both.png"))
            engine.toggleLayerVisible(row: 1) // 下(青)を非表示
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 11.6) {
            try? engine.savePNG(to: dir.appendingPathComponent("layers-top-only.png")) // 赤だけ
            engine.toggleLayerVisible(row: 1) // 下を戻す
            engine.toggleLayerVisible(row: 0) // 上(赤)を非表示
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12.2) {
            try? engine.savePNG(to: dir.appendingPathComponent("layers-bottom-only.png")) // 青だけ
            engine.toggleLayerVisible(row: 0)            // 赤を戻す(両方表示)
            engine.moveLayer(fromRow: 1, toRow: 0)       // 下の青を最前面へ
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12.8) {
            try? engine.savePNG(to: dir.appendingPathComponent("layers-reordered.png")) // 青が手前
            NSApp.terminate(nil)
        }
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "Quit Bloom", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        )
        NSApp.mainMenu = mainMenu
    }
}
