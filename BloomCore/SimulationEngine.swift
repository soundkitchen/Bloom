import Foundation
import simd
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 滲みシミュレーションのコア。AppKit 非依存(ヘッドレスで動く)。
///
/// グリッド上に 4 つの場を持つ:
/// - W: 水量 / P: 浮遊顔料 / D: 沈着済み顔料(乾いた絵) / H: 紙の凹凸(静的)
/// 毎フレーム stamp → (flow → dry) × substeps → render の順で回す。
@MainActor
public final class SimulationEngine {

    // Simulation.metal の MSL 側とレイアウトを一致させること
    private struct SimParams {
        var width: UInt32
        var height: UInt32
        var flowRate: Float = 0.18 // 2D 拡散の安定限界 0.25 未満に保つ(超えるとチェッカーボード)
        var evapRate: Float = 0.0010
        var depositRate: Float = 0.62
        var paperInfluence: Float = 0.35
        var wetThreshold: Float = 0.02
        var edgeEvapBoost: Float = 3.0
        var granulation: Float = 0.8
        var stampCount: UInt32 = 0
        var activeFactor: Float = 1.0  // render でアクティブ層を合成する係数(非表示なら 0)
        var coverageK: Float = 0.9     // 顔料量 → 被覆(不透明度)への変換係数
        var activeOpacity: Float = 1.0 // アクティブ層の不透明度
    }

    /// レイヤー: 乾いた顔料(deposit)を持つ。ウェットシミュレーション(W/P)は共有で、
    /// 乾燥沈着はアクティブ層の deposit に積まれる。
    private struct Layer {
        var deposit: MTLBuffer // float3 RGB 吸光度
        var visible: Bool
        var opacity: Float
        var name: String
    }

    /// UI 向けのレイヤー情報(読み取り専用)
    public struct LayerInfo: Sendable {
        public let name: String
        public let visible: Bool
        public let opacity: Float
    }

    private struct Stamp {
        var pos: SIMD2<Float>
        var radius: Float
        var water: Float
        var pigment: SIMD3<Float> // RGB 吸光度の増分(色 × 量)
        var dryness: Float
    }

    /// ブラシ特性
    public struct Brush: Sendable {
        public var name: String
        public var baseRadius: Float
        public var minRadiusFactor: Float
        public var water: Float
        public var pigment: Float          // 顔料の量(濃さ)
        public var color: SIMD3<Float>     // 顔料の色(sRGB 0...1)
        public var dryness: Float          // 0: ウェット / 1: ドライ(かすれ)

        /// 色 → Beer-Lambert 吸光度 K = -ln(color)。これに量を掛けて積む。
        var absorbance: SIMD3<Float> {
            let c = simd_clamp(color, SIMD3(repeating: 0.04), SIMD3(repeating: 0.99))
            return SIMD3(-log(c.x), -log(c.y), -log(c.z))
        }

        /// たっぷりの水で滲む藍の水彩筆
        public static let watercolor = Brush(
            name: "水彩(藍)", baseRadius: 22, minRadiusFactor: 0.25,
            water: 0.9, pigment: 0.16, color: SIMD3(0.22, 0.34, 0.60), dryness: 0
        )
        /// 水の少ない墨の筆。紙の凸部にだけ顔料が乗ってかすれる
        public static let sumi = Brush(
            name: "墨(かすれ)", baseRadius: 14, minRadiusFactor: 0.15,
            water: 0.10, pigment: 0.55, color: SIMD3(0.10, 0.10, 0.11), dryness: 0.85
        )
    }

    public let gridWidth: Int
    public let gridHeight: Int
    public var brush = Brush.watercolor

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let stampPipeline: MTLComputePipelineState
    private let flowPipeline: MTLComputePipelineState
    private let dryPipeline: MTLComputePipelineState
    private let renderPipeline: MTLComputePipelineState
    private let compositePipeline: MTLComputePipelineState

    // flow はセル間相互作用があるので W/P をピンポン。stamp/dry はセル内完結なので in-place
    private var waterA: MTLBuffer
    private var waterB: MTLBuffer
    private var pigmentA: MTLBuffer
    private var pigmentB: MTLBuffer
    private let paper: MTLBuffer
    private let stampBuffer: MTLBuffer

    // レイヤー。乾燥沈着はアクティブ層に積み、render は可視層を順序合成する。
    private var layers: [Layer] = []
    private var activeLayerIndex = 0
    private var layerCounter = 0
    // アクティブ層より下/上の可視層を畳み込んだアフィン変換 (A, B)。レイヤー操作時に再構築。
    // 色 r に対し r → A·r + B。A は単位元 1、B は 0 で初期化。
    private let belowA: MTLBuffer
    private let belowB: MTLBuffer
    private let aboveA: MTLBuffer
    private let aboveB: MTLBuffer

    private var params: SimParams
    private var pendingStamps: [Stamp] = []
    private var lastStrokeSample: InputSample?   // 筆跡(トレイル)用のアンカー
    private var activeDab: InputSample?           // 今ペンが下りている位置(ドウェル供給用)

    private let substepsPerFrame = 3
    private let maxStampsPerFrame = 1024

    /// 筆を下ろし続けている間の単位フレームあたりの供給量(止めていても滲みが育つ)。
    /// 120fps を前提にした控えめな値。フレームレート非依存化は将来課題。
    /// 広がりは水が駆動するので water を厚めに、顔料は前線まで運ばれて溜まる程度に。
    private let dwellWaterRate: Float = 0.08
    private let dwellPigmentRate: Float = 0.018

    public enum EngineError: Error { case noDevice, pipelineFailed(String) }

    public init(width: Int, height: Int) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw EngineError.noDevice
        }
        self.device = device
        self.queue = queue
        gridWidth = max(width, 8)
        gridHeight = max(height, 8)
        params = SimParams(width: UInt32(gridWidth), height: UInt32(gridHeight))

        // Simulation.metal は Xcode ビルドで framework の default.metallib にコンパイルされる
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: SimulationEngine.self))
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let fn = library.makeFunction(name: name) else {
                throw EngineError.pipelineFailed(name)
            }
            return try device.makeComputePipelineState(function: fn)
        }
        stampPipeline = try pipeline("stampKernel")
        flowPipeline = try pipeline("flowKernel")
        dryPipeline = try pipeline("dryKernel")
        renderPipeline = try pipeline("renderKernel")
        compositePipeline = try pipeline("compositeLayerKernel")

        let cellCount = gridWidth * gridHeight
        func makeBuffer(_ byteCount: Int) throws -> MTLBuffer {
            guard let b = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
                throw EngineError.pipelineFailed("buffer allocation")
            }
            return b
        }
        let scalarBytes = cellCount * MemoryLayout<Float>.stride
        let vector3Bytes = cellCount * MemoryLayout<SIMD3<Float>>.stride // 顔料は RGB 吸光度(stride 16)
        waterA = try makeBuffer(scalarBytes)
        waterB = try makeBuffer(scalarBytes)
        pigmentA = try makeBuffer(vector3Bytes)
        pigmentB = try makeBuffer(vector3Bytes)
        paper = try makeBuffer(scalarBytes)
        belowA = try makeBuffer(vector3Bytes)
        belowB = try makeBuffer(vector3Bytes)
        aboveA = try makeBuffer(vector3Bytes)
        aboveB = try makeBuffer(vector3Bytes)
        guard let sb = device.makeBuffer(
            length: maxStampsPerFrame * MemoryLayout<Stamp>.stride,
            options: .storageModeShared
        ) else { throw EngineError.pipelineFailed("stamp buffer") }
        stampBuffer = sb

        // 最初のレイヤーを 1 枚用意
        layerCounter = 1
        layers = [Layer(deposit: try makeBuffer(vector3Bytes), visible: true,
                        opacity: 1.0, name: "レイヤー 1")]
        activeLayerIndex = 0

        zeroWetAndActiveDeposit() // ウェット + アクティブ層 deposit を 0 に(init は履歴に積まない)
        rebuildComposites()       // below/above を 0 に(初期は他層なし)
        generatePaperTexture()
    }

    private var depositByteCount: Int { gridWidth * gridHeight * MemoryLayout<SIMD3<Float>>.stride }

    /// 0 初期化済みの deposit バッファを作る(未初期化メモリが描画に出ないように)
    private func makeDepositBuffer() -> MTLBuffer? {
        guard let b = device.makeBuffer(length: depositByteCount, options: .storageModeShared) else {
            return nil
        }
        memset(b.contents(), 0, b.length)
        return b
    }

    // MARK: - 公開 API(コアへの「コマンド」。将来 MCP からも同じ口を叩く)

    public func beginStroke() {
        checkpoint() // ストロークを 1 つの取り消し単位にする
        lastStrokeSample = nil
        activeDab = nil
    }

    /// ストロークに 1 サンプル追加。前サンプルとの間をスタンプ間隔で補間する。
    public func addStrokeSample(at position: SIMD2<Float>, pressure: Float) {
        let sample = InputSample(position: position, pressure: max(0, min(pressure, 1)))
        activeDab = sample // ドウェル供給は常に最新のペン位置で行う(止めていても継ぎ足す)
        guard let last = lastStrokeSample else {
            appendStamp(for: sample)
            lastStrokeSample = sample
            return
        }
        let dist = simd_distance(last.position, sample.position)
        let spacing = max(stampRadius(pressure: sample.pressure) * 0.3, 1.5)
        let steps = min(Int(dist / spacing), 200)
        // 間隔未満の移動ではスタンプを打たず、アンカーも進めない。
        // こうしないと距離が毎イベントでリセットされ、ゆっくり描くと永遠に閾値を超えない。
        guard steps > 0 else { return }
        for i in 1...steps {
            let t = Float(i) / Float(steps)
            appendStamp(for: InputSample(
                position: simd_mix(last.position, sample.position, SIMD2(repeating: t)),
                pressure: last.pressure + (sample.pressure - last.pressure) * t
            ))
        }
        // 最後のスタンプはちょうど sample 位置(t=1)に乗るので、ここをアンカーにする
        lastStrokeSample = sample
    }

    public func endStroke() {
        lastStrokeSample = nil
        activeDab = nil // ペンを上げたらドウェル供給を止める(あとは広がって乾くだけ)
    }

    /// 筆を下ろし続けている間、動かさなくても水・顔料を継ぎ足す(滲み・溜まりが育つ)。
    /// renderFrame から毎フレーム呼ばれる。穂の芯から染み出すイメージで細め・少量。
    internal func emitDwellStamp() {
        guard let dab = activeDab, pendingStamps.count < maxStampsPerFrame else { return }
        pendingStamps.append(Stamp(
            pos: dab.position,
            radius: stampRadius(pressure: dab.pressure) * 1.1,
            water: brush.water * dab.pressure * dwellWaterRate,
            pigment: brush.absorbance * (brush.pigment * dab.pressure * dwellPigmentRate),
            dryness: brush.dryness
        ))
    }

    /// テスト用: 次フレームで描画待ちのスタンプ数
    internal var pendingStampCount: Int { pendingStamps.count }

    private var activeDeposit: MTLBuffer { layers[activeLayerIndex].deposit }

    private func zeroWetAndActiveDeposit() {
        pendingStamps.removeAll()
        for buf in [waterA, waterB, pigmentA, pigmentB, activeDeposit] {
            memset(buf.contents(), 0, buf.length)
        }
    }

    /// アクティブ層と乾き途中のウェットをクリア(他の層は残す)。取り消し可能。
    public func clear() {
        checkpoint()
        zeroWetAndActiveDeposit()
    }

    // MARK: - レイヤー操作(コアへのコマンド。将来 MCP からも叩く)

    /// UI 向け: 上が手前(末尾が最前面)になるよう逆順で返す
    public var layerInfos: [LayerInfo] {
        layers.reversed().map { LayerInfo(name: $0.name, visible: $0.visible, opacity: $0.opacity) }
    }

    /// layerInfos と同じ並び(逆順)でのアクティブ位置
    public var activeLayerRow: Int { layers.count - 1 - activeLayerIndex }

    public var layerCount: Int { layers.count }

    public func addLayer() {
        guard let buf = makeDepositBuffer() else { return }
        checkpoint()
        layerCounter += 1
        // アクティブ層の 1 つ上(手前)に挿入してそこをアクティブに
        layers.insert(Layer(deposit: buf, visible: true, opacity: 1.0,
                            name: "レイヤー \(layerCounter)"), at: activeLayerIndex + 1)
        activeLayerIndex += 1
        endStroke()
        rebuildComposites()
    }

    /// layerInfos の行番号(逆順)で削除。最低 1 枚は残す。
    public func deleteLayer(row: Int) {
        guard layers.count > 1 else { return }
        let index = layers.count - 1 - row
        guard layers.indices.contains(index) else { return }
        checkpoint()
        layers.remove(at: index)
        if index < activeLayerIndex {
            activeLayerIndex -= 1                                   // 下の層が詰めた
        } else if index == activeLayerIndex {
            activeLayerIndex = min(activeLayerIndex, layers.count - 1) // 削除した位置に来た層へ
        }
        endStroke()
        rebuildComposites()
    }

    public func setActiveLayer(row: Int) {
        let index = layers.count - 1 - row
        guard layers.indices.contains(index), index != activeLayerIndex else { return }
        activeLayerIndex = index
        endStroke()
        rebuildComposites()
    }

    public func toggleLayerVisible(row: Int) {
        let index = layers.count - 1 - row
        guard layers.indices.contains(index) else { return }
        layers[index].visible.toggle()
        rebuildComposites()
    }

    public func setLayerOpacity(row: Int, opacity: Float) {
        let index = layers.count - 1 - row
        guard layers.indices.contains(index) else { return }
        layers[index].opacity = min(max(opacity, 0), 1)
        rebuildComposites()
    }

    /// 行(上=手前)を fromRow から toRow へ移動。toRow は NSTableView の挿入位置の意味。
    public func moveLayer(fromRow: Int, toRow: Int) {
        var rows = Array(layers.reversed()) // rows[0] = 手前
        guard rows.indices.contains(fromRow) else { return }
        checkpoint()
        let activeBuf = layers[activeLayerIndex].deposit // 同一性でアクティブを追従
        let moved = rows.remove(at: fromRow)
        var dest = toRow
        if toRow > fromRow { dest -= 1 } // 削除で 1 つ詰まる分を補正
        dest = max(0, min(dest, rows.count))
        rows.insert(moved, at: dest)
        layers = Array(rows.reversed())
        activeLayerIndex = layers.firstIndex { $0.deposit === activeBuf } ?? activeLayerIndex
        endStroke()
        rebuildComposites()
    }

    // MARK: - Undo / Redo(スナップショット方式)
    //
    // 流体シミュレーションは連続的でコマンド再生が難しいため、取り消し可能な操作の
    // 直前に全レイヤーの deposit(乾いた絵)+ メタデータをコピーして保存する。
    // ウェット(W/P)は復元時に破棄する(取り消し中の中途半端な濡れを残さない)。

    private struct LayerState {
        let deposit: Data
        let visible: Bool
        let opacity: Float
        let name: String
    }
    private struct DocSnapshot {
        let layers: [LayerState]
        let activeLayerIndex: Int
        let layerCounter: Int
    }
    private var undoStack: [DocSnapshot] = []
    private var redoStack: [DocSnapshot] = []
    private let maxUndoDepth = 30

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    private func makeSnapshot() -> DocSnapshot {
        let states = layers.map {
            LayerState(deposit: Data(bytes: $0.deposit.contents(), count: $0.deposit.length),
                       visible: $0.visible, opacity: $0.opacity, name: $0.name)
        }
        return DocSnapshot(layers: states, activeLayerIndex: activeLayerIndex, layerCounter: layerCounter)
    }

    /// 取り消し可能な操作の直前に呼ぶ。現在状態を undo スタックへ積み、redo を破棄。
    private func checkpoint() {
        undoStack.append(makeSnapshot())
        if undoStack.count > maxUndoDepth {
            undoStack.removeFirst(undoStack.count - maxUndoDepth)
        }
        redoStack.removeAll()
    }

    private func restore(_ snap: DocSnapshot) {
        layers = snap.layers.map { st in
            let buf = makeDepositBuffer()! // 0 初期化されるが直後に上書き
            st.deposit.withUnsafeBytes { raw in
                memcpy(buf.contents(), raw.baseAddress!, min(buf.length, st.deposit.count))
            }
            return Layer(deposit: buf, visible: st.visible, opacity: st.opacity, name: st.name)
        }
        activeLayerIndex = min(max(snap.activeLayerIndex, 0), layers.count - 1)
        layerCounter = snap.layerCounter
        // ウェットは破棄
        pendingStamps.removeAll()
        lastStrokeSample = nil
        activeDab = nil
        for buf in [waterA, waterB, pigmentA, pigmentB] { memset(buf.contents(), 0, buf.length) }
        rebuildComposites()
    }

    public func undo() {
        guard canUndo else { return }
        redoStack.append(makeSnapshot())
        restore(undoStack.removeLast())
    }

    public func redo() {
        guard canRedo else { return }
        undoStack.append(makeSnapshot())
        restore(redoStack.removeLast())
    }

    /// 可視レイヤーを下/上のアフィン変換 (A,B) へ畳み込む(レイヤー操作時のみ・低頻度)。
    /// アクティブ層は毎フレーム変わるので render 時に別途合成する。
    private func rebuildComposites() {
        // A は単位元 1、B は 0 で初期化
        let n = gridWidth * gridHeight
        for buf in [belowA, aboveA] {
            let p = buf.contents().bindMemory(to: SIMD3<Float>.self, capacity: n)
            for i in 0..<n { p[i] = SIMD3(repeating: 1) }
        }
        memset(belowB.contents(), 0, belowB.length)
        memset(aboveB.contents(), 0, aboveB.length)

        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return }
        let grid = MTLSize(width: gridWidth, height: gridHeight, depth: 1)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        enc.setComputePipelineState(compositePipeline)

        func fold(accA: MTLBuffer, accB: MTLBuffer, indices: Range<Int>) {
            for idx in indices where layers[idx].visible {
                var op = layers[idx].opacity
                enc.setBuffer(accA, offset: 0, index: 0)
                enc.setBuffer(accB, offset: 0, index: 1)
                enc.setBuffer(layers[idx].deposit, offset: 0, index: 2)
                enc.setBytes(&op, length: MemoryLayout<Float>.stride, index: 3)
                enc.setBytes(&params, length: MemoryLayout<SimParams>.stride, index: 4)
                enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
                enc.memoryBarrier(scope: .buffers) // 同一バッファへの逐次合成を順序保証
            }
        }
        fold(accA: belowA, accB: belowB, indices: 0..<activeLayerIndex)              // 下層(bottom→top)
        fold(accA: aboveA, accB: aboveB, indices: (activeLayerIndex + 1)..<layers.count) // 上層
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
    }

    /// 1 フレーム進めて結果テクスチャに描く。texture は .bgra8Unorm / shaderWrite 可であること。
    public func renderFrame(into texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: gridWidth, height: gridHeight, depth: 1)

        emitDwellStamp() // 筆を下ろしている間は止めていても継ぎ足す

        // 1. スタンプ
        if !pendingStamps.isEmpty {
            let count = min(pendingStamps.count, maxStampsPerFrame)
            pendingStamps.withUnsafeBytes { raw in
                stampBuffer.contents().copyMemory(
                    from: raw.baseAddress!,
                    byteCount: count * MemoryLayout<Stamp>.stride
                )
            }
            params.stampCount = UInt32(count)
            enc.setComputePipelineState(stampPipeline)
            enc.setBuffer(waterA, offset: 0, index: 0)
            enc.setBuffer(pigmentA, offset: 0, index: 1)
            enc.setBuffer(stampBuffer, offset: 0, index: 2)
            enc.setBytes(&params, length: MemoryLayout<SimParams>.stride, index: 3)
            enc.setBuffer(paper, offset: 0, index: 4) // ドライブラシのかすれマスク用
            enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
            pendingStamps.removeFirst(count)
        }
        params.stampCount = 0

        // 2. 水流 + 乾燥(substep)
        for _ in 0..<substepsPerFrame {
            enc.setComputePipelineState(flowPipeline)
            enc.setBuffer(waterA, offset: 0, index: 0)
            enc.setBuffer(pigmentA, offset: 0, index: 1)
            enc.setBuffer(waterB, offset: 0, index: 2)
            enc.setBuffer(pigmentB, offset: 0, index: 3)
            enc.setBuffer(paper, offset: 0, index: 4)
            enc.setBytes(&params, length: MemoryLayout<SimParams>.stride, index: 5)
            enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
            swap(&waterA, &waterB)
            swap(&pigmentA, &pigmentB)

            enc.setComputePipelineState(dryPipeline)
            enc.setBuffer(waterA, offset: 0, index: 0)
            enc.setBuffer(pigmentA, offset: 0, index: 1)
            enc.setBuffer(activeDeposit, offset: 0, index: 2) // 乾燥沈着はアクティブ層へ
            enc.setBuffer(paper, offset: 0, index: 3)
            enc.setBytes(&params, length: MemoryLayout<SimParams>.stride, index: 4)
            enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
        }

        // 3. 表示(下 → アクティブ → 上 の順で over 合成)
        params.activeFactor = layers[activeLayerIndex].visible ? 1.0 : 0.0
        params.activeOpacity = layers[activeLayerIndex].opacity
        enc.setComputePipelineState(renderPipeline)
        enc.setTexture(texture, index: 0)
        enc.setBuffer(waterA, offset: 0, index: 0)
        enc.setBuffer(pigmentA, offset: 0, index: 1)
        enc.setBuffer(belowA, offset: 0, index: 2)
        enc.setBuffer(belowB, offset: 0, index: 3)
        enc.setBuffer(aboveA, offset: 0, index: 4)
        enc.setBuffer(aboveB, offset: 0, index: 5)
        enc.setBuffer(activeDeposit, offset: 0, index: 6)
        enc.setBuffer(paper, offset: 0, index: 7)
        enc.setBytes(&params, length: MemoryLayout<SimParams>.stride, index: 8)
        enc.dispatchThreads(
            MTLSize(width: texture.width, height: texture.height, depth: 1),
            threadsPerThreadgroup: tg
        )
        enc.endEncoding()
    }

    public func makeCommandBuffer() -> MTLCommandBuffer? {
        queue.makeCommandBuffer()
    }

    public var metalDevice: MTLDevice { device }

    // MARK: - スナップショット(自動検証用)

    /// 現在のキャンバスをグリッド等倍で PNG に書き出す。
    public func savePNG(to url: URL) throws {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: gridWidth, height: gridHeight, mipmapped: false
        )
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc),
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else {
            throw EngineError.pipelineFailed("snapshot texture")
        }
        enc.setComputePipelineState(renderPipeline)
        enc.setTexture(tex, index: 0)
        enc.setBuffer(waterA, offset: 0, index: 0)
        enc.setBuffer(pigmentA, offset: 0, index: 1)
        enc.setBuffer(belowA, offset: 0, index: 2)
        enc.setBuffer(belowB, offset: 0, index: 3)
        enc.setBuffer(aboveA, offset: 0, index: 4)
        enc.setBuffer(aboveB, offset: 0, index: 5)
        enc.setBuffer(activeDeposit, offset: 0, index: 6)
        enc.setBuffer(paper, offset: 0, index: 7)
        var prm = params
        prm.stampCount = 0
        prm.activeFactor = layers[activeLayerIndex].visible ? 1.0 : 0.0
        prm.activeOpacity = layers[activeLayerIndex].opacity
        enc.setBytes(&prm, length: MemoryLayout<SimParams>.stride, index: 8)
        enc.dispatchThreads(
            MTLSize(width: gridWidth, height: gridHeight, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
        )
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        let bytesPerRow = gridWidth * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * gridHeight)
        bytes.withUnsafeMutableBytes { raw in
            tex.getBytes(
                raw.baseAddress!, bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, gridWidth, gridHeight), mipmapLevel: 0
            )
        }
        let cgImage: CGImage? = bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: gridWidth, height: gridHeight,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return nil }
            return ctx.makeImage()
        }
        guard let cgImage,
              let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil
              ) else {
            throw EngineError.pipelineFailed("png export")
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
    }

    // MARK: - 内部

    private func stampRadius(pressure: Float) -> Float {
        brush.baseRadius * (brush.minRadiusFactor + (1 - brush.minRadiusFactor) * pressure)
    }

    private func appendStamp(for sample: InputSample) {
        guard pendingStamps.count < maxStampsPerFrame else { return }
        pendingStamps.append(Stamp(
            pos: sample.position,
            radius: stampRadius(pressure: sample.pressure),
            water: brush.water * (0.4 + 0.6 * sample.pressure),
            pigment: brush.absorbance * (brush.pigment * (0.3 + 0.7 * sample.pressure)),
            dryness: brush.dryness
        ))
    }

    /// 紙の凹凸: 2 オクターブの値ノイズ(決定的)
    private func generatePaperTexture() {
        func hash(_ x: Int, _ y: Int) -> Float {
            var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263)
            h = (h ^ (h >> 13)) &* 1_274_126_177
            h = h ^ (h >> 16)
            return Float(h & 0xFFFF) / 65535.0
        }
        func valueNoise(_ fx: Float, _ fy: Float) -> Float {
            let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
            let tx = fx - Float(x0), ty = fy - Float(y0)
            let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
            let a = hash(x0, y0), b = hash(x0 + 1, y0)
            let c = hash(x0, y0 + 1), d = hash(x0 + 1, y0 + 1)
            return (a + (b - a) * sx) + ((c + (d - c) * sx) - (a + (b - a) * sx)) * sy
        }
        let ptr = paper.contents().bindMemory(to: Float.self, capacity: gridWidth * gridHeight)
        for y in 0..<gridHeight {
            for x in 0..<gridWidth {
                let fine = valueNoise(Float(x) / 3.5, Float(y) / 3.5)
                let coarse = valueNoise(Float(x) / 17.0 + 100, Float(y) / 17.0 + 100)
                ptr[y * gridWidth + x] = 0.62 * fine + 0.38 * coarse
            }
        }
    }
}
