import AppKit
import UniformTypeIdentifiers
import BloomCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var canvas: CanvasView?
    private var inspector: InspectorView?
    private var timeline: TimelineView?
    private var statusLabel: NSTextField?
    private var documentURL: URL?
    private var playTimer: Timer?
    private var playFps: Double = 12

    private var bloomType: UTType { UTType(filenameExtension: "bloom") ?? .data }

    private let inspectorWidth: CGFloat = 240
    private let statusHeight: CGFloat = 24
    private let timelineHeight: CGFloat = 56

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let args = CommandLine.arguments
        let demoModes = ["--demo", "--demo-dwell", "--demo-layers", "--demo-undo", "--demo-saveload", "--demo-anim", "--demo-onion", "--demo-stabilize", "--demo-sumi"]
        if demoModes.contains(where: args.contains) {
            // 検証モードはキャンバス全面(スナップショットを汚さない)
            buildDemoWindow(small: args.contains("--demo-dwell"))
        } else {
            buildInteractiveWindow()
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        handleLaunchArguments()
    }

    /// 通常起動: 中央キャンバス + 右インスペクタ + 下タイムライン + ステータスバー
    private func buildInteractiveWindow() {
        let winSize = NSSize(width: 1024, height: 720)
        let lowerH = statusHeight + timelineHeight // キャンバス/インスペクタ下端の余白
        let upperH = winSize.height - lowerH

        let canvas = CanvasView(frame: NSRect(
            x: 0, y: lowerH, width: winSize.width - inspectorWidth, height: upperH
        ), device: nil)
        canvas.autoresizingMask = [.width, .height]
        self.canvas = canvas

        let inspector = InspectorView(frame: NSRect(
            x: winSize.width - inspectorWidth, y: lowerH, width: inspectorWidth, height: upperH
        ))
        inspector.autoresizingMask = [.minXMargin, .height]
        self.inspector = inspector

        let timeline = TimelineView(frame: NSRect(
            x: 0, y: statusHeight, width: winSize.width, height: timelineHeight
        ))
        timeline.autoresizingMask = [.width, .maxYMargin]
        self.timeline = timeline

        let statusBar = makeStatusBar(width: winSize.width)

        let container = NSView(frame: NSRect(origin: .zero, size: winSize))
        container.addSubview(canvas)
        container.addSubview(inspector)
        container.addSubview(timeline)
        container.addSubview(statusBar)

        // 配線: キャンバス ⇄ インスペクタ ⇄ ステータス
        canvas.onStatus = { [weak self] in self?.statusLabel?.stringValue = $0 }
        canvas.onBrushChanged = { [weak inspector] in inspector?.reflect(brush: $0) }
        inspector.onSelectBrush = { [weak canvas] in canvas?.selectBrush($0) }
        inspector.onSizeChange = { [weak canvas] in canvas?.setBrushRadius($0) }
        inspector.onWaterChange = { [weak canvas] in canvas?.setBrushWater($0) }
        inspector.onStabilizeChange = { [weak canvas] in canvas?.setStabilizeStrength($0) }
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

        // 配線: タイムライン
        timeline.onAddFrame = { [weak canvas] in canvas?.addFrame() }
        timeline.onDuplicateFrame = { [weak canvas] in canvas?.duplicateFrame() }
        timeline.onDeleteFrame = { [weak canvas] in canvas?.deleteFrame() }
        timeline.onSelectFrame = { [weak canvas] in canvas?.goToFrame($0) }
        timeline.onPrev = { [weak self] in self?.stepFrame(-1) }
        timeline.onNext = { [weak self] in self?.stepFrame(+1) }
        timeline.onPlayToggle = { [weak self] in self?.togglePlay() }
        timeline.onOnionToggle = { [weak canvas] in canvas?.setOnion($0) }
        timeline.onFpsChange = { [weak self] in self?.playFps = $0 }
        canvas.onTimelineChanged = { [weak self] in self?.refreshTimeline() }

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
        refreshTimeline()
    }

    // MARK: - タイムライン / 再生

    private func stepFrame(_ delta: Int) {
        guard let canvas else { return }
        canvas.goToFrame(canvas.currentFrameIndex + delta)
    }

    private func togglePlay() {
        guard let canvas else { return }
        if canvas.isPlaying {
            playTimer?.invalidate(); playTimer = nil
            canvas.isPlaying = false
        } else {
            canvas.isPlaying = true
            playTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / max(playFps, 1), repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.canvas?.stepFrameLooping() }
            }
        }
        refreshTimeline()
    }

    private func refreshTimeline() {
        guard let canvas, let timeline else { return }
        timeline.reflect(frameTotal: canvas.frameTotal, current: canvas.currentFrameIndex,
                         isPlaying: canvas.isPlaying, onion: canvas.onionEnabled)
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
        if args.contains("--demo-undo") {
            runUndoDemo(snapshotDir: snapshotDir)
            return
        }
        if args.contains("--demo-saveload") {
            runSaveLoadDemo(snapshotDir: snapshotDir)
            return
        }
        if args.contains("--demo-anim") {
            runAnimDemo(snapshotDir: snapshotDir)
            return
        }
        if args.contains("--demo-onion") {
            runOnionDemo(snapshotDir: snapshotDir)
            return
        }
        if args.contains("--demo-stabilize") {
            runStabilizeDemo(snapshotDir: snapshotDir)
            return
        }
        if args.contains("--demo-sumi") {
            runSumiDemo(snapshotDir: snapshotDir)
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

    /// undo 検証: ストロークを描いて乾かす → before 撮影 → undo → after 撮影(空に戻る)
    private func runUndoDemo(snapshotDir: URL?) {
        guard let engine = canvas?.engine else { return }
        let w = Float(engine.gridWidth), h = Float(engine.gridHeight)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            engine.brush = .watercolor
            engine.beginStroke()
            for i in 0..<90 {
                let t = Float(i) / 89
                engine.addStrokeSample(
                    at: SIMD2(0.12 * w + 0.76 * w * t, 0.5 * h + 0.15 * h * sin(t * .pi * 2.4)),
                    pressure: 0.2 + 0.7 * sin(t * .pi))
            }
            engine.endStroke()
        }
        guard let dir = snapshotDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            try? engine.savePNG(to: dir.appendingPathComponent("undo-before.png")) // 描画あり
            engine.undo()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) {
            try? engine.savePNG(to: dir.appendingPathComponent("undo-after.png")) // 空に戻る
            NSApp.terminate(nil)
        }
    }

    /// 保存/読み込み検証: 描く → 乾かす → .bloom 保存 → クリア → 読み込み → 復元を撮影
    private func runSaveLoadDemo(snapshotDir: URL?) {
        guard let engine = canvas?.engine else { return }
        let w = Float(engine.gridWidth), h = Float(engine.gridHeight)
        let docURL = FileManager.default.temporaryDirectory.appendingPathComponent("bloom-roundtrip.bloom")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            engine.brush = .watercolor
            engine.beginStroke()
            for i in 0..<90 {
                let t = Float(i) / 89
                engine.addStrokeSample(
                    at: SIMD2(0.12 * w + 0.76 * w * t, 0.5 * h + 0.15 * h * sin(t * .pi * 2.4)),
                    pressure: 0.2 + 0.7 * sin(t * .pi))
            }
            engine.endStroke()
        }
        guard let dir = snapshotDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            try? engine.saveDocument(to: docURL) // 乾いた絵を保存
            engine.clear()                       // キャンバスを消す
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.6) {
            try? engine.savePNG(to: dir.appendingPathComponent("saveload-cleared.png")) // 空
            try? engine.loadDocument(from: docURL) // 読み込みで復元
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.2) {
            try? engine.savePNG(to: dir.appendingPathComponent("saveload-loaded.png")) // 復元
            NSApp.terminate(nil)
        }
    }

    /// アニメ書き出し検証: ドットが動く数フレームを作り、GIF/スプライト/連番を書き出す。
    /// 各フレームは低水ブラシで素早く沈着させ、次フレームへ移る前に乾燥時間を取る。
    private func runAnimDemo(snapshotDir: URL?) {
        guard let engine = canvas?.engine else { return }
        let w = Float(engine.gridWidth), h = Float(engine.gridHeight)
        var dot = SimulationEngine.Brush.sumi  // 低水で速く沈着
        dot.color = SIMD3(0.20, 0.30, 0.62)
        dot.baseRadius = 26
        let frames = 6
        let step = 1.4 // 1 フレームの描画 + 乾燥に充てる秒数

        func drawDot(_ i: Int) {
            engine.brush = dot
            let x = 0.15 * w + 0.7 * w * Float(i) / Float(frames - 1)
            let y = 0.5 * h - 0.25 * h * sin(Float(i) / Float(frames - 1) * .pi)
            engine.beginStroke()
            engine.addStrokeSample(at: SIMD2(x, y), pressure: 1.0)
            engine.addStrokeSample(at: SIMD2(x + 1, y), pressure: 1.0)
            engine.endStroke()
        }

        for i in 0..<frames {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + step * Double(i)) {
                if i > 0 { engine.addFrame() }
                drawDot(i)
            }
        }
        guard let dir = snapshotDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + step * Double(frames) + 1.5) {
            try? engine.exportGIF(to: dir.appendingPathComponent("anim.gif"), fps: 8)
            try? engine.exportSpriteSheet(to: dir.appendingPathComponent("sheet.png"))
            try? engine.exportPNGSequence(to: dir.appendingPathComponent("seq"))
            NSApp.terminate(nil)
        }
    }

    /// オニオン検証: frame0 に波線 → frame1(空)で オニオン on → 前フレームが透ける
    private func runOnionDemo(snapshotDir: URL?) {
        guard let engine = canvas?.engine else { return }
        let w = Float(engine.gridWidth), h = Float(engine.gridHeight)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            engine.brush = .watercolor
            engine.beginStroke()
            for i in 0..<90 {
                let t = Float(i) / 89
                engine.addStrokeSample(
                    at: SIMD2(0.12 * w + 0.76 * w * t, 0.5 * h + 0.18 * h * sin(t * .pi * 2.4)),
                    pressure: 0.25 + 0.7 * sin(t * .pi))
            }
            engine.endStroke()
        }
        guard let dir = snapshotDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) {
            engine.addFrame()             // frame1 へ(初期は保持 = 前フレームをフル表示)
            engine.clear()                // 空のキーフレームにして保持を切る
            engine.setOnionEnabled(true)  // 前フレームを薄く表示(ゴースト)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.2) {
            try? engine.savePNG(to: dir.appendingPathComponent("onion-frame2.png"))
            engine.setOnionEnabled(false)
            try? engine.savePNG(to: dir.appendingPathComponent("onion-off.png"))
            NSApp.terminate(nil)
        }
    }

    /// 手ブレ補正検証: 同じ「揺れのある入力」を補正なし → あり で描いて比較する。
    /// なめらかな水平線に高周波・小振幅のジッタ(手ブレ相当)を法線方向に重ねた点列を、
    /// 実際の StrokeStabilizer 経路(CanvasView.drawStabilizedStroke)へ流す。
    private func runStabilizeDemo(snapshotDir: URL?) {
        guard let canvas = self.canvas, let engine = canvas.engine else { return }
        let w = Float(engine.gridWidth), h = Float(engine.gridHeight)

        func jitterLine(baselineY: Float) -> [SIMD2<Float>] {
            (0..<220).map { i in
                let t = Float(i) / 219
                let x = 0.1 * w + 0.8 * w * t
                let y = baselineY + 22 * sin(t * .pi * 34) // 手ブレ相当の細かい揺れ
                return SIMD2(x, y)
            }
        }

        var ink = SimulationEngine.Brush.sumi // 低水で細く出る墨。形(なめらかさ)が見やすい
        ink.baseRadius = 10

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            engine.brush = ink
            canvas.drawStabilizedStroke(points: jitterLine(baselineY: 0.4 * h),
                                        pressure: 0.9, strength: 0)   // 補正なし
        }
        guard let dir = snapshotDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            try? engine.savePNG(to: dir.appendingPathComponent("stabilize-off.png")) // ガタつく
            engine.clear()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
            engine.brush = ink
            canvas.drawStabilizedStroke(points: jitterLine(baselineY: 0.4 * h),
                                        pressure: 0.9, strength: 0.85) // 補正あり(flush で終点到達)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.1) {
            try? engine.savePNG(to: dir.appendingPathComponent("stabilize-on.png")) // なめらか
            NSApp.terminate(nil)
        }
    }

    /// 墨のかすれ検証(--demo-sumi): 同じ墨ブラシで筆圧の異なる 3 本を描く。
    /// 上=高圧(ほぼ繋がる)/ 中=低圧(全体にかすれる)/ 下=払い(高圧→低圧でかすれが育つ)。
    /// 低水なのですぐ沈着する。1 枚 sumi.png にまとめて目視チューニングする。
    private func runSumiDemo(snapshotDir: URL?) {
        guard let engine = canvas?.engine else { return }
        let w = Float(engine.gridWidth), h = Float(engine.gridHeight)

        /// y を基準にした水平線。pressure(t) を与えて筆圧を変える。
        func horizontal(baselineY: Float, pressure: (Float) -> Float) {
            engine.beginStroke()
            for i in 0..<160 {
                let t = Float(i) / 159
                engine.addStrokeSample(at: SIMD2(0.1 * w + 0.8 * w * t, baselineY),
                                       pressure: pressure(t))
            }
            engine.endStroke()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            engine.brush = .sumi
            horizontal(baselineY: 0.25 * h) { _ in 1.0 }            // 高圧: ほぼ繋がる
            horizontal(baselineY: 0.5 * h)  { _ in 0.35 }           // 低圧: 全体にかすれる
            horizontal(baselineY: 0.75 * h) { t in 1.0 - 0.9 * t }  // 払い: かすれが育つ
        }
        guard let dir = snapshotDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            try? engine.savePNG(to: dir.appendingPathComponent("sumi.png"))
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

        // ファイルメニュー(開く / 保存 / 書き出し)
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "ファイル")
        fileItem.submenu = fileMenu
        func add(_ menu: NSMenu, _ title: String, _ action: Selector,
                 _ key: String, _ mods: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = self
            menu.addItem(item)
        }
        add(fileMenu, "開く…", #selector(openDocument), "o")
        fileMenu.addItem(.separator())
        add(fileMenu, "保存", #selector(saveDocument), "s")
        add(fileMenu, "別名で保存…", #selector(saveDocumentAs), "s", [.command, .shift])
        fileMenu.addItem(.separator())
        add(fileMenu, "PNG を書き出す…", #selector(exportPNG), "e")
        add(fileMenu, "GIF を書き出す…", #selector(exportGIF), "g")
        add(fileMenu, "スプライトシートを書き出す…", #selector(exportSpriteSheet), "g", [.command, .shift])
        add(fileMenu, "PNG 連番を書き出す…", #selector(exportPNGSequence), "")

        // 編集メニュー(取り消す / やり直す)
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "編集")
        editItem.submenu = editMenu
        let undoItem = NSMenuItem(title: "取り消す", action: #selector(undoAction), keyEquivalent: "z")
        undoItem.target = self
        let redoItem = NSMenuItem(title: "やり直す", action: #selector(redoAction), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        redoItem.target = self
        editMenu.addItem(undoItem)
        editMenu.addItem(redoItem)

        // フレームメニュー(アニメーション)
        let frameItem = NSMenuItem()
        mainMenu.addItem(frameItem)
        let frameMenu = NSMenu(title: "フレーム")
        frameItem.submenu = frameMenu
        add(frameMenu, "新規フレーム", #selector(menuAddFrame), "n", [.command, .shift])
        add(frameMenu, "フレームを複製", #selector(menuDuplicateFrame), "d", [.command, .shift])
        add(frameMenu, "フレームを削除", #selector(menuDeleteFrame), "")
        frameMenu.addItem(.separator())
        add(frameMenu, "前のフレーム", #selector(menuPrevFrame), ",")
        add(frameMenu, "次のフレーム", #selector(menuNextFrame), ".")
        add(frameMenu, "再生 / 停止", #selector(menuTogglePlay), "p")

        NSApp.mainMenu = mainMenu
    }

    @objc private func undoAction() { canvas?.undo() }
    @objc private func redoAction() { canvas?.redo() }
    @objc private func menuAddFrame() { canvas?.addFrame() }
    @objc private func menuDuplicateFrame() { canvas?.duplicateFrame() }
    @objc private func menuDeleteFrame() { canvas?.deleteFrame() }
    @objc private func menuPrevFrame() { stepFrame(-1) }
    @objc private func menuNextFrame() { stepFrame(+1) }
    @objc private func menuTogglePlay() { togglePlay() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undoAction): return canvas?.canUndo ?? false
        case #selector(redoAction): return canvas?.canRedo ?? false
        default: return true
        }
    }

    // MARK: - ファイル操作

    @objc private func openDocument() {
        guard let engine = canvas?.engine else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [bloomType]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try engine.loadDocument(from: url)
            documentURL = url
            refreshAfterDocumentChange()
        } catch {
            presentError(error, title: "開けませんでした")
        }
    }

    @objc private func saveDocument() {
        if let url = documentURL { save(to: url) } else { saveDocumentAs() }
    }

    @objc private func saveDocumentAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [bloomType]
        panel.nameFieldStringValue = documentURL?.lastPathComponent ?? "無題.bloom"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        save(to: url)
    }

    private var exportBaseName: String { documentURL?.deletingPathExtension().lastPathComponent ?? "無題" }

    @objc private func exportPNG() {
        guard let engine = canvas?.engine else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = exportBaseName + ".png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try engine.savePNG(to: url) } catch { presentError(error, title: "書き出せませんでした") }
    }

    @objc private func exportGIF() {
        guard let engine = canvas?.engine else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = exportBaseName + ".gif"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try engine.exportGIF(to: url, fps: 12) } catch { presentError(error, title: "GIF を書き出せませんでした") }
    }

    @objc private func exportSpriteSheet() {
        guard let engine = canvas?.engine else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = exportBaseName + "_sheet.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try engine.exportSpriteSheet(to: url) } catch { presentError(error, title: "スプライトシートを書き出せませんでした") }
    }

    @objc private func exportPNGSequence() {
        guard let engine = canvas?.engine else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "ここへ書き出す"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        do {
            try engine.exportPNGSequence(to: dir.appendingPathComponent(exportBaseName + "_seq"))
        } catch { presentError(error, title: "PNG 連番を書き出せませんでした") }
    }

    private func save(to url: URL) {
        guard let engine = canvas?.engine else { return }
        do {
            try engine.saveDocument(to: url)
            documentURL = url
            updateWindowTitle()
        } catch {
            presentError(error, title: "保存できませんでした")
        }
    }

    private func refreshAfterDocumentChange() {
        guard let canvas, let inspector else { return }
        inspector.reflectLayers(canvas.layerInfos, activeRow: canvas.activeLayerRow)
        updateWindowTitle()
    }

    private func updateWindowTitle() {
        window?.title = "Bloom — " + (documentURL?.deletingPathExtension().lastPathComponent ?? "無題")
    }

    private func presentError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        if case let SimulationEngine.EngineError.documentFormat(msg) = error {
            alert.informativeText = msg
        } else {
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }
}
