import AppKit
import MetalKit
import simd
import BloomCore

/// 描画キャンバス。入力イベントを InputSample に変換してコアに渡し、
/// 毎フレームコアにシミュレーション + 描画させる。
final class CanvasView: MTKView {
    private(set) var engine: SimulationEngine?
    private var pressureEstimator = PseudoPressureEstimator()

    /// ステータスバー更新用(ウィンドウタイトルではなく下部バーに出す)
    var onStatus: ((String) -> Void)?
    /// ブラシがキー操作等で変わったときにインスペクタを追従させる
    var onBrushChanged: ((SimulationEngine.Brush) -> Void)?
    /// レイヤーが変化したときにインスペクタのリストを更新させる
    var onLayersChanged: (() -> Void)?

    // レイヤー操作の受け渡し(インスペクタ → エンジン → UI 更新)
    var layerInfos: [SimulationEngine.LayerInfo] { engine?.layerInfos ?? [] }
    var activeLayerRow: Int { engine?.activeLayerRow ?? 0 }

    func addLayer() { engine?.addLayer(); onLayersChanged?() }
    func deleteLayer(row: Int) { engine?.deleteLayer(row: row); onLayersChanged?() }
    func setActiveLayer(row: Int) { engine?.setActiveLayer(row: row); onLayersChanged?() }
    func toggleLayer(row: Int) { engine?.toggleLayerVisible(row: row); onLayersChanged?() }
    func moveLayer(from: Int, to: Int) { engine?.moveLayer(fromRow: from, toRow: to); onLayersChanged?() }
    func setLayerOpacity(row: Int, opacity: Float) { engine?.setLayerOpacity(row: row, opacity: opacity) }

    // Undo / Redo（レイヤー数が変わりうるのでインスペクタも更新）
    var canUndo: Bool { engine?.canUndo ?? false }
    var canRedo: Bool { engine?.canRedo ?? false }
    func undo() { engine?.undo(); onLayersChanged?() }
    func redo() { engine?.redo(); onLayersChanged?() }

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        do {
            let engine = try SimulationEngine(
                width: Int(frame.width), height: Int(frame.height)
            )
            self.engine = engine
            self.device = engine.metalDevice
        } catch {
            fatalError("SimulationEngine init failed: \(error)")
        }
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false // compute シェーダで drawable に直接書くため
        preferredFramesPerSecond = 120
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - 描画ループ

    override func draw(_ dirtyRect: NSRect) {
        guard let engine,
              let drawable = currentDrawable,
              let cb = engine.makeCommandBuffer() else { return }
        engine.renderFrame(into: drawable.texture, commandBuffer: cb)
        cb.present(drawable)
        cb.commit()
    }

    // MARK: - 入力

    override func mouseDown(with event: NSEvent) {
        pressureEstimator.reset()
        engine?.beginStroke()
        addSample(from: event)
    }

    override func mouseDragged(with event: NSEvent) {
        addSample(from: event)
    }

    override func mouseUp(with event: NSEvent) {
        engine?.endStroke()
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "c": engine?.clear()
        case "d": runDemoStrokes()
        case "1": selectBrush(.watercolor)
        case "2": selectBrush(.sumi)
        case "[": adjustBrushRadius(by: -3)
        case "]": adjustBrushRadius(by: +3)
        default: super.keyDown(with: event)
        }
    }

    var currentBrush: SimulationEngine.Brush? { engine?.brush }

    /// ブラシ全体を差し替える(プリセット選択)。インスペクタにも追従させる。
    func selectBrush(_ brush: SimulationEngine.Brush) {
        engine?.brush = brush
        onBrushChanged?(brush)
        updateStatus()
    }

    /// サイズだけ変更(インスペクタのスライダ / キー操作から)
    func setBrushRadius(_ radius: Float) {
        guard let engine else { return }
        engine.brush.baseRadius = min(max(radius, 4), 80)
        updateStatus()
    }

    /// 水量だけ変更(インスペクタのスライダから)
    func setBrushWater(_ water: Float) {
        guard let engine else { return }
        engine.brush.water = min(max(water, 0), 1)
        updateStatus()
    }

    /// 色だけ変更(インスペクタのカラーウェルから)
    func setBrushColor(_ color: SIMD3<Float>) {
        guard let engine else { return }
        engine.brush.color = simd_clamp(color, SIMD3(repeating: 0), SIMD3(repeating: 1))
        updateStatus()
    }

    private func adjustBrushRadius(by delta: Float) {
        guard let engine else { return }
        setBrushRadius(engine.brush.baseRadius + delta)
        onBrushChanged?(engine.brush) // キー操作でもスライダを追従させる
    }

    private func updateStatus(pressureInfo: String = "") {
        guard let engine else { return }
        onStatus?("\(engine.brush.name)  r\(Int(engine.brush.baseRadius))" + pressureInfo)
    }

    private func addSample(from event: NSEvent) {
        guard let engine else { return }
        let loc = convert(event.locationInWindow, from: nil)
        // ビュー座標(y 上向き)→ グリッド座標(y 下向き)
        let point = SIMD2<Float>(Float(loc.x), Float(bounds.height - loc.y))

        // タブレット(XPPEN/Wacom 等)はドライバが NSEvent に実筆圧を載せてくる。
        // マウスは速度からの擬似筆圧にフォールバック。
        let isTablet = event.subtype == .tabletPoint
        let pressure: Float = isTablet
            ? event.pressure
            : pressureEstimator.estimate(point: point, time: event.timestamp)

        engine.addStrokeSample(at: point, pressure: pressure)
        updateStatus(pressureInfo: String(
            format: "   筆圧 %.2f (%@)", pressure, isTablet ? "tablet" : "pseudo"
        ))
    }

    // MARK: - デモストローク(d キー / --demo)

    /// 入力デバイスなしで滲み挙動を確認するための決め打ちストローク
    func runDemoStrokes() {
        guard let engine else { return }
        let w = Float(bounds.width), h = Float(bounds.height)
        let original = engine.brush

        // 1: 水彩 — 筆圧が膨らんで抜ける横の波線(穂先→腹→穂先)
        engine.brush = .watercolor
        engine.beginStroke()
        let n = 90
        for i in 0..<n {
            let t = Float(i) / Float(n - 1)
            engine.addStrokeSample(
                at: SIMD2(0.12 * w + 0.76 * w * t, 0.55 * h + 0.16 * h * sin(t * .pi * 2.4)),
                pressure: 0.15 + 0.75 * sin(t * .pi)
            )
        }
        engine.endStroke()

        // 2: 墨 — 速い払い(筆圧が抜けてかすれていく斜めの線)
        engine.brush = .sumi
        engine.beginStroke()
        for i in 0..<40 {
            let t = Float(i) / 39
            engine.addStrokeSample(
                at: SIMD2(0.30 * w + 0.45 * w * t, 0.25 * h + 0.50 * h * t),
                pressure: 0.80 - 0.55 * t
            )
        }
        engine.endStroke()

        engine.brush = original
    }
}
