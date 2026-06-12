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
///
/// アニメーション(セル方式): レイヤー = トラックがフレームをまたいで存在し、
/// 各トラックがフレームごとに「セル(deposit バッファ)」を持つ。セルが無いフレームは
/// 直前のセルを保持(hold)する。表示・描画はすべて currentFrame の解決後セルに対して行う。
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
        var onionFactor: Float = 0     // オニオンスキン(前フレーム)の表示強度
    }

    /// レイヤー(トラック): フレームごとのセル(乾いた顔料 deposit)を持つ。
    /// cels[f] == nil は「保持(直前のセルを表示)」。cels.count == frameCount。
    private struct LayerTrack {
        var cels: [MTLBuffer?]
        var visible: Bool
        var opacity: Float
        var name: String
        let id: Int // 並べ替え時にアクティブを追従させるための安定 ID
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
        var dir: SIMD2<Float>     // ストローク進行方向(単位ベクトル)。毛筋の向き。静止時は 0
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
    private let emptyDeposit: MTLBuffer   // 常に 0。解決後セルが無い表示の合成で使う
    private let scratchDeposit: MTLBuffer // 描画ターゲットが無いときの乾燥出力ダンプ(表示しない)

    // タイムライン。各トラックが currentFrame のセルに解決され、可視層を順序合成する。
    private var tracks: [LayerTrack] = []
    private var frameCount = 1
    private var currentFrame = 0
    private var activeTrackIndex = 0
    private var trackCounter = 0   // 既定名 "レイヤー N" 用
    private var trackIdSeq = 0     // 安定 ID 採番

    // アクティブ層より下/上の可視層を畳み込んだアフィン変換 (A, B)。レイヤー/フレーム操作時に再構築。
    // 色 r に対し r → A·r + B。A は単位元 1、B は 0 で初期化。
    private let belowA: MTLBuffer
    private let belowB: MTLBuffer
    private let aboveA: MTLBuffer
    private let aboveB: MTLBuffer
    // オニオンスキン: 前フレームの全可視トラックを畳み込んだアフィン (A,B)。フレーム移動時に再構築。
    private let onionA: MTLBuffer
    private let onionB: MTLBuffer
    public private(set) var onionEnabled = false
    private let onionStrength: Float = 0.4

    private var params: SimParams
    private var pendingStamps: [Stamp] = []
    private var lastStrokeSample: InputSample?   // 筆跡(トレイル)用のアンカー
    private var activeDab: InputSample?           // 今ペンが下りている位置(ドウェル供給用)

    private let substepsPerFrame = 3
    private let maxStampsPerFrame = 1024

    /// 筆を下ろし続けている間の単位フレームあたりの供給量(止めていても滲みが育つ)。
    private let dwellWaterRate: Float = 0.08
    private let dwellPigmentRate: Float = 0.018

    public enum EngineError: Error { case noDevice, pipelineFailed(String), documentFormat(String) }

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
        emptyDeposit = try makeBuffer(vector3Bytes)
        scratchDeposit = try makeBuffer(vector3Bytes)
        onionA = try makeBuffer(vector3Bytes)
        onionB = try makeBuffer(vector3Bytes)
        memset(emptyDeposit.contents(), 0, emptyDeposit.length)
        guard let sb = device.makeBuffer(
            length: maxStampsPerFrame * MemoryLayout<Stamp>.stride,
            options: .storageModeShared
        ) else { throw EngineError.pipelineFailed("stamp buffer") }
        stampBuffer = sb

        // 最初のトラックを 1 枚、フレーム 0 にセルを 1 枚持たせる
        frameCount = 1
        currentFrame = 0
        trackCounter = 1
        trackIdSeq = 1
        let firstCel = try makeBuffer(vector3Bytes)
        memset(firstCel.contents(), 0, firstCel.length)
        tracks = [LayerTrack(cels: [firstCel], visible: true, opacity: 1.0, name: "レイヤー 1", id: 1)]
        activeTrackIndex = 0

        zeroWet()
        rebuildComposites()
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

    // MARK: - セル解決

    /// トラック t・フレーム f の表示セル(hold: f 以下で最後に非 nil のセル)
    private func resolvedCel(_ t: Int, _ f: Int) -> MTLBuffer? {
        var i = min(f, frameCount - 1)
        while i >= 0 {
            if let c = tracks[t].cels[i] { return c }
            i -= 1
        }
        return nil
    }

    /// アクティブトラックの現フレーム表示セル(無ければ emptyDeposit)
    private var activeDisplayCel: MTLBuffer { resolvedCel(activeTrackIndex, currentFrame) ?? emptyDeposit }
    private var activeHasVisibleCel: Bool {
        tracks[activeTrackIndex].visible && resolvedCel(activeTrackIndex, currentFrame) != nil
    }
    /// 乾燥沈着の出力先。描画中はアクティブセル、無ければ scratch(表示されない)
    private var dryTarget: MTLBuffer { tracks[activeTrackIndex].cels[currentFrame] ?? scratchDeposit }

    /// 現フレームのアクティブトラックに描けるセルを保証(hold を切って新原画を作る)
    @discardableResult
    private func ensureActiveDrawCel() -> MTLBuffer {
        if let c = tracks[activeTrackIndex].cels[currentFrame] { return c }
        guard let buf = makeDepositBuffer() else { return scratchDeposit }
        tracks[activeTrackIndex].cels[currentFrame] = buf
        return buf
    }

    // MARK: - 公開 API(コアへの「コマンド」。将来 MCP からも同じ口を叩く)

    public func beginStroke() {
        checkpoint()              // ストロークを 1 つの取り消し単位にする
        ensureActiveDrawCel()     // 現フレームに描けるセルを用意(保持を切る)
        lastStrokeSample = nil
        activeDab = nil
    }

    /// ストロークに 1 サンプル追加。前サンプルとの間をスタンプ間隔で補間する。
    public func addStrokeSample(at position: SIMD2<Float>, pressure: Float) {
        let sample = InputSample(position: position, pressure: max(0, min(pressure, 1)))
        activeDab = sample // ドウェル供給は常に最新のペン位置で行う(止めていても継ぎ足す)
        guard let last = lastStrokeSample else {
            appendStamp(for: sample, dir: SIMD2(0, 0)) // 始点(入り)はまだ方向が無い
            lastStrokeSample = sample
            return
        }
        let dist = simd_distance(last.position, sample.position)
        let spacing = max(stampRadius(pressure: sample.pressure) * 0.3, 1.5)
        let steps = min(Int(dist / spacing), 200)
        // 間隔未満の移動ではスタンプを打たず、アンカーも進めない。
        guard steps > 0 else { return }
        let dir = dist > 1e-4 ? (sample.position - last.position) / dist : SIMD2<Float>(0, 0)
        for i in 1...steps {
            let t = Float(i) / Float(steps)
            appendStamp(for: InputSample(
                position: simd_mix(last.position, sample.position, SIMD2(repeating: t)),
                pressure: last.pressure + (sample.pressure - last.pressure) * t
            ), dir: dir)
        }
        lastStrokeSample = sample
    }

    public func endStroke() {
        lastStrokeSample = nil
        activeDab = nil
    }

    /// 筆を下ろし続けている間、動かさなくても水・顔料を継ぎ足す(滲み・溜まりが育つ)。
    internal func emitDwellStamp() {
        guard let dab = activeDab, pendingStamps.count < maxStampsPerFrame else { return }
        pendingStamps.append(Stamp(
            pos: dab.position,
            radius: stampRadius(pressure: dab.pressure) * 1.1,
            water: brush.water * dab.pressure * dwellWaterRate,
            pigment: brush.absorbance * (brush.pigment * dab.pressure * dwellPigmentRate),
            dryness: effectiveDryness(pressure: dab.pressure),
            dir: SIMD2(0, 0) // 据え置きの供給は方向なし(毛筋を作らない)
        ))
    }

    /// テスト用: 次フレームで描画待ちのスタンプ数
    internal var pendingStampCount: Int { pendingStamps.count }

    /// テスト用: 指定行(上=手前)のトラックがそのフレームに実セルを持つか(hold 検証用)
    internal func celExists(trackRow: Int, frame: Int) -> Bool {
        let t = tracks.count - 1 - trackRow
        guard tracks.indices.contains(t), tracks[t].cels.indices.contains(frame) else { return false }
        return tracks[t].cels[frame] != nil
    }

    private func zeroWet() {
        pendingStamps.removeAll()
        for buf in [waterA, waterB, pigmentA, pigmentB] { memset(buf.contents(), 0, buf.length) }
    }

    /// アクティブトラックの現フレームのセルとウェットをクリア(他は残す)。取り消し可能。
    public func clear() {
        checkpoint()
        let cel = ensureActiveDrawCel() // 保持フレームなら空セルを作って上書き
        memset(cel.contents(), 0, cel.length)
        zeroWet()
        rebuildComposites()
    }

    // MARK: - レイヤー(トラック)操作

    /// UI 向け: 上が手前(末尾が最前面)になるよう逆順で返す
    public var layerInfos: [LayerInfo] {
        tracks.reversed().map { LayerInfo(name: $0.name, visible: $0.visible, opacity: $0.opacity) }
    }
    public var activeLayerRow: Int { tracks.count - 1 - activeTrackIndex }
    public var layerCount: Int { tracks.count }

    private func newTrack(name: String) -> LayerTrack {
        trackIdSeq += 1
        return LayerTrack(cels: Array(repeating: nil, count: frameCount),
                          visible: true, opacity: 1.0, name: name, id: trackIdSeq)
    }

    public func addLayer() {
        checkpoint()
        trackCounter += 1
        tracks.insert(newTrack(name: "レイヤー \(trackCounter)"), at: activeTrackIndex + 1)
        activeTrackIndex += 1
        endStroke()
        rebuildComposites()
    }

    public func deleteLayer(row: Int) {
        guard tracks.count > 1 else { return }
        let index = tracks.count - 1 - row
        guard tracks.indices.contains(index) else { return }
        checkpoint()
        tracks.remove(at: index)
        if index < activeTrackIndex {
            activeTrackIndex -= 1
        } else if index == activeTrackIndex {
            activeTrackIndex = min(activeTrackIndex, tracks.count - 1)
        }
        endStroke()
        rebuildComposites()
    }

    public func setActiveLayer(row: Int) {
        let index = tracks.count - 1 - row
        guard tracks.indices.contains(index), index != activeTrackIndex else { return }
        activeTrackIndex = index
        endStroke()
        rebuildComposites()
    }

    public func toggleLayerVisible(row: Int) {
        let index = tracks.count - 1 - row
        guard tracks.indices.contains(index) else { return }
        tracks[index].visible.toggle()
        rebuildComposites()
    }

    public func setLayerOpacity(row: Int, opacity: Float) {
        let index = tracks.count - 1 - row
        guard tracks.indices.contains(index) else { return }
        tracks[index].opacity = min(max(opacity, 0), 1)
        rebuildComposites()
    }

    /// 行(上=手前)を fromRow から toRow へ移動。toRow は NSTableView の挿入位置の意味。
    public func moveLayer(fromRow: Int, toRow: Int) {
        var rows = Array(tracks.reversed()) // rows[0] = 手前
        guard rows.indices.contains(fromRow) else { return }
        checkpoint()
        let activeId = tracks[activeTrackIndex].id
        let moved = rows.remove(at: fromRow)
        var dest = toRow
        if toRow > fromRow { dest -= 1 }
        dest = max(0, min(dest, rows.count))
        rows.insert(moved, at: dest)
        tracks = Array(rows.reversed())
        activeTrackIndex = tracks.firstIndex { $0.id == activeId } ?? activeTrackIndex
        endStroke()
        rebuildComposites()
    }

    // MARK: - フレーム操作

    public var frameTotal: Int { frameCount }
    public var currentFrameIndex: Int { currentFrame }

    /// 現フレームの後ろに空(保持)フレームを挿入してそこへ移動
    public func addFrame() {
        checkpoint()
        for t in tracks.indices { tracks[t].cels.insert(nil, at: currentFrame + 1) }
        frameCount += 1
        currentFrame += 1
        endStroke()
        rebuildComposites()
    }

    /// 現フレームの内容を複製した独立フレームを後ろに挿入してそこへ移動
    public func duplicateFrame() {
        checkpoint()
        for t in tracks.indices {
            let copy: MTLBuffer?
            if let src = resolvedCel(t, currentFrame), let dst = makeDepositBuffer() {
                memcpy(dst.contents(), src.contents(), dst.length)
                copy = dst
            } else {
                copy = nil
            }
            tracks[t].cels.insert(copy, at: currentFrame + 1)
        }
        frameCount += 1
        currentFrame += 1
        endStroke()
        rebuildComposites()
    }

    /// 現フレームを削除(最低 1 フレームは残す)
    public func deleteFrame() {
        guard frameCount > 1 else { return }
        checkpoint()
        for t in tracks.indices { tracks[t].cels.remove(at: currentFrame) }
        frameCount -= 1
        currentFrame = min(currentFrame, frameCount - 1)
        endStroke()
        rebuildComposites()
    }

    /// フレーム移動(履歴には積まない。ウェットは破棄)
    public func goToFrame(_ f: Int) {
        let target = min(max(f, 0), frameCount - 1)
        guard target != currentFrame else { return }
        endStroke()
        zeroWet()
        currentFrame = target
        rebuildComposites()
    }

    public func setOnionEnabled(_ on: Bool) {
        onionEnabled = on
        rebuildOnion()
    }

    // MARK: - Undo / Redo(スナップショット方式・タイムライン全体)

    private struct TrackState {
        let cels: [Data?]
        let visible: Bool
        let opacity: Float
        let name: String
        let id: Int
    }
    private struct DocSnapshot {
        let tracks: [TrackState]
        let frameCount: Int
        let currentFrame: Int
        let activeTrackIndex: Int
        let trackCounter: Int
        let trackIdSeq: Int
    }
    private var undoStack: [DocSnapshot] = []
    private var redoStack: [DocSnapshot] = []
    private let maxUndoDepth = 15 // タイムライン全体を持つのでやや浅め

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    private func makeSnapshot() -> DocSnapshot {
        let ts = tracks.map { track in
            TrackState(
                cels: track.cels.map { cel in
                    cel.map { Data(bytes: $0.contents(), count: $0.length) }
                },
                visible: track.visible, opacity: track.opacity, name: track.name, id: track.id)
        }
        return DocSnapshot(tracks: ts, frameCount: frameCount, currentFrame: currentFrame,
                           activeTrackIndex: activeTrackIndex, trackCounter: trackCounter,
                           trackIdSeq: trackIdSeq)
    }

    private func checkpoint() {
        undoStack.append(makeSnapshot())
        if undoStack.count > maxUndoDepth { undoStack.removeFirst(undoStack.count - maxUndoDepth) }
        redoStack.removeAll()
    }

    private func celFromData(_ data: Data?) -> MTLBuffer? {
        guard let data, let buf = makeDepositBuffer() else { return nil }
        data.withUnsafeBytes { raw in
            memcpy(buf.contents(), raw.baseAddress!, min(buf.length, data.count))
        }
        return buf
    }

    private func restore(_ snap: DocSnapshot) {
        tracks = snap.tracks.map { st in
            LayerTrack(cels: st.cels.map { celFromData($0) },
                       visible: st.visible, opacity: st.opacity, name: st.name, id: st.id)
        }
        frameCount = snap.frameCount
        currentFrame = min(max(snap.currentFrame, 0), frameCount - 1)
        activeTrackIndex = min(max(snap.activeTrackIndex, 0), tracks.count - 1)
        trackCounter = snap.trackCounter
        trackIdSeq = snap.trackIdSeq
        zeroWet()
        lastStrokeSample = nil
        activeDab = nil
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

    // MARK: - ドキュメント保存/読み込み(.bloom バイナリ)
    //
    // v2 書式(リトルエンディアン): magic "BLM1" / version(2) / width / height /
    //   frameCount / trackCount / activeTrack / currentFrame / trackCounter /
    //   各トラック { nameLen, name, visible u8, opacity f32,
    //     各フレーム { hasCel u8, [deposit raw(w*h*16) if hasCel] } }
    // v1(version 1)は単一フレーム・各レイヤー1セルとして後方互換で読む。

    private static let docMagic: [UInt8] = [0x42, 0x4C, 0x4D, 0x31] // "BLM1"

    public func saveDocument(to url: URL) throws {
        var data = Data()
        data.append(contentsOf: Self.docMagic)
        appendU32(2, &data) // version
        appendU32(UInt32(gridWidth), &data)
        appendU32(UInt32(gridHeight), &data)
        appendU32(UInt32(frameCount), &data)
        appendU32(UInt32(tracks.count), &data)
        appendU32(UInt32(activeTrackIndex), &data)
        appendU32(UInt32(currentFrame), &data)
        appendU32(UInt32(trackCounter), &data)
        for track in tracks {
            let nameBytes = Array(track.name.utf8)
            appendU32(UInt32(nameBytes.count), &data)
            data.append(contentsOf: nameBytes)
            data.append(track.visible ? 1 : 0)
            appendU32(track.opacity.bitPattern, &data)
            for cel in track.cels {
                if let cel {
                    data.append(1)
                    data.append(Data(bytes: cel.contents(), count: cel.length))
                } else {
                    data.append(0)
                }
            }
        }
        try data.write(to: url, options: .atomic)
    }

    public func loadDocument(from url: URL) throws {
        let bytes = [UInt8](try Data(contentsOf: url))
        var c = 0
        func fail(_ m: String) -> EngineError { .documentFormat(m) }
        func readU32() throws -> UInt32 {
            guard c + 4 <= bytes.count else { throw fail("ファイルが途中で切れています") }
            defer { c += 4 }
            return UInt32(bytes[c]) | UInt32(bytes[c+1]) << 8
                 | UInt32(bytes[c+2]) << 16 | UInt32(bytes[c+3]) << 24
        }
        func readU8() throws -> UInt8 {
            guard c + 1 <= bytes.count else { throw fail("ファイルが途中で切れています") }
            defer { c += 1 }
            return bytes[c]
        }
        let depositBytes = gridWidth * gridHeight * MemoryLayout<SIMD3<Float>>.stride
        func readCel(present: Bool) throws -> MTLBuffer? {
            guard present else { return nil }
            guard c + depositBytes <= bytes.count else { throw fail("レイヤーデータが不足しています") }
            guard let buf = makeDepositBuffer() else { throw fail("バッファ確保に失敗") }
            bytes.withUnsafeBytes { raw in
                memcpy(buf.contents(), raw.baseAddress!.advanced(by: c), depositBytes)
            }
            c += depositBytes
            return buf
        }

        guard bytes.count >= 4, Array(bytes[0..<4]) == Self.docMagic else {
            throw fail("Bloom ドキュメントではありません")
        }
        c = 4
        let version = try readU32()
        guard version == 1 || version == 2 else { throw fail("対応していないバージョンです") }
        let w = Int(try readU32()), h = Int(try readU32())
        guard w == gridWidth, h == gridHeight else {
            throw fail("キャンバスサイズが一致しません(\(w)x\(h) vs \(gridWidth)x\(gridHeight))")
        }

        var newTracks: [LayerTrack] = []
        var newFrameCount = 1
        var newActiveTrack = 0
        var newCurrentFrame = 0
        var newTrackCounter = 0
        var idSeq = 0

        if version == 1 {
            // v1: layerCount / activeIndex / layerCounter / 各層 { name, visible, opacity, deposit }
            let count = Int(try readU32())
            newActiveTrack = Int(try readU32())
            newTrackCounter = Int(try readU32())
            for _ in 0..<count {
                let nameLen = Int(try readU32())
                guard c + nameLen <= bytes.count else { throw fail("ファイルが途中で切れています") }
                let name = String(decoding: bytes[c..<c+nameLen], as: UTF8.self); c += nameLen
                let visible = try readU8() != 0
                let opacity = Float(bitPattern: try readU32())
                let cel = try readCel(present: true)
                idSeq += 1
                newTracks.append(LayerTrack(cels: [cel], visible: visible, opacity: opacity,
                                            name: name, id: idSeq))
            }
        } else {
            // v2
            newFrameCount = Int(try readU32())
            let trackCount = Int(try readU32())
            newActiveTrack = Int(try readU32())
            newCurrentFrame = Int(try readU32())
            newTrackCounter = Int(try readU32())
            guard newFrameCount >= 1 else { throw fail("フレーム数が不正です") }
            for _ in 0..<trackCount {
                let nameLen = Int(try readU32())
                guard c + nameLen <= bytes.count else { throw fail("ファイルが途中で切れています") }
                let name = String(decoding: bytes[c..<c+nameLen], as: UTF8.self); c += nameLen
                let visible = try readU8() != 0
                let opacity = Float(bitPattern: try readU32())
                var cels: [MTLBuffer?] = []
                for _ in 0..<newFrameCount {
                    let present = try readU8() != 0
                    cels.append(try readCel(present: present))
                }
                idSeq += 1
                newTracks.append(LayerTrack(cels: cels, visible: visible, opacity: opacity,
                                            name: name, id: idSeq))
            }
        }
        guard !newTracks.isEmpty else { throw fail("レイヤーがありません") }

        tracks = newTracks
        frameCount = newFrameCount
        currentFrame = min(max(newCurrentFrame, 0), frameCount - 1)
        activeTrackIndex = min(max(newActiveTrack, 0), tracks.count - 1)
        trackCounter = max(newTrackCounter, tracks.count)
        trackIdSeq = idSeq
        // 新しいドキュメント: 履歴とウェットをリセット
        undoStack.removeAll(); redoStack.removeAll()
        zeroWet(); lastStrokeSample = nil; activeDab = nil
        rebuildComposites()
    }

    private func appendU32(_ v: UInt32, _ data: inout Data) {
        data.append(UInt8(v & 0xff)); data.append(UInt8((v >> 8) & 0xff))
        data.append(UInt8((v >> 16) & 0xff)); data.append(UInt8((v >> 24) & 0xff))
    }

    // MARK: - 合成・描画

    /// 可視トラックを現フレームの解決後セルに直し、下/上のアフィン変換 (A,B) へ畳み込む。
    /// アクティブ層は毎フレーム変わるので render 時に別途合成する。
    private func rebuildComposites() {
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
            for idx in indices where tracks[idx].visible {
                guard let cel = resolvedCel(idx, currentFrame) else { continue }
                var op = tracks[idx].opacity
                enc.setBuffer(accA, offset: 0, index: 0)
                enc.setBuffer(accB, offset: 0, index: 1)
                enc.setBuffer(cel, offset: 0, index: 2)
                enc.setBytes(&op, length: MemoryLayout<Float>.stride, index: 3)
                enc.setBytes(&params, length: MemoryLayout<SimParams>.stride, index: 4)
                enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
                enc.memoryBarrier(scope: .buffers)
            }
        }
        fold(accA: belowA, accB: belowB, indices: 0..<activeTrackIndex)
        fold(accA: aboveA, accB: aboveB, indices: (activeTrackIndex + 1)..<tracks.count)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        rebuildOnion()
    }

    /// オニオン: 前フレームの全可視トラックを畳み込む(無効/先頭フレームは identity=白)
    private func rebuildOnion() {
        let n = gridWidth * gridHeight
        let pa = onionA.contents().bindMemory(to: SIMD3<Float>.self, capacity: n)
        for i in 0..<n { pa[i] = SIMD3(repeating: 1) }
        memset(onionB.contents(), 0, onionB.length)
        guard onionEnabled, currentFrame > 0 else { return }
        let prev = currentFrame - 1
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return }
        let grid = MTLSize(width: gridWidth, height: gridHeight, depth: 1)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        enc.setComputePipelineState(compositePipeline)
        for idx in tracks.indices where tracks[idx].visible {
            guard let cel = resolvedCel(idx, prev) else { continue }
            var op = tracks[idx].opacity
            enc.setBuffer(onionA, offset: 0, index: 0)
            enc.setBuffer(onionB, offset: 0, index: 1)
            enc.setBuffer(cel, offset: 0, index: 2)
            enc.setBytes(&op, length: MemoryLayout<Float>.stride, index: 3)
            enc.setBytes(&params, length: MemoryLayout<SimParams>.stride, index: 4)
            enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
            enc.memoryBarrier(scope: .buffers)
        }
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
    }

    /// 1 フレーム進めて結果テクスチャに描く。texture は .bgra8Unorm / shaderWrite 可であること。
    public func renderFrame(into texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: gridWidth, height: gridHeight, depth: 1)

        emitDwellStamp()

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
            enc.setBuffer(paper, offset: 0, index: 4)
            enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
            pendingStamps.removeFirst(count)
        }
        params.stampCount = 0

        // 2. 水流 + 乾燥(substep)。乾燥沈着はアクティブセル(描画ターゲット)へ。
        let target = dryTarget
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
            enc.setBuffer(target, offset: 0, index: 2)
            enc.setBuffer(paper, offset: 0, index: 3)
            enc.setBytes(&params, length: MemoryLayout<SimParams>.stride, index: 4)
            enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
        }

        encodeRender(into: texture, encoder: enc, tg: tg)
        enc.endEncoding()
    }

    /// 現フレームの合成を texture に描く(render パイプラインのバインドを共通化)
    private func encodeRender(into texture: MTLTexture, encoder enc: MTLComputeCommandEncoder, tg: MTLSize) {
        params.activeFactor = activeHasVisibleCel ? 1.0 : 0.0
        params.activeOpacity = tracks[activeTrackIndex].opacity
        params.onionFactor = (onionEnabled && currentFrame > 0) ? onionStrength : 0
        enc.setComputePipelineState(renderPipeline)
        enc.setTexture(texture, index: 0)
        enc.setBuffer(waterA, offset: 0, index: 0)
        enc.setBuffer(pigmentA, offset: 0, index: 1)
        enc.setBuffer(belowA, offset: 0, index: 2)
        enc.setBuffer(belowB, offset: 0, index: 3)
        enc.setBuffer(aboveA, offset: 0, index: 4)
        enc.setBuffer(aboveB, offset: 0, index: 5)
        enc.setBuffer(activeDisplayCel, offset: 0, index: 6)
        enc.setBuffer(paper, offset: 0, index: 7)
        enc.setBytes(&params, length: MemoryLayout<SimParams>.stride, index: 8)
        enc.setBuffer(onionA, offset: 0, index: 9)
        enc.setBuffer(onionB, offset: 0, index: 10)
        enc.dispatchThreads(
            MTLSize(width: texture.width, height: texture.height, depth: 1),
            threadsPerThreadgroup: tg
        )
    }

    public func makeCommandBuffer() -> MTLCommandBuffer? {
        queue.makeCommandBuffer()
    }

    public var metalDevice: MTLDevice { device }

    // MARK: - 画像化

    /// 現フレームの合成をグリッド等倍の CGImage にする(PNG/GIF/スプライト書き出しで再利用)
    internal func renderFrameCGImage() throws -> CGImage {
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
        encodeRender(into: tex, encoder: enc, tg: MTLSize(width: 16, height: 16, depth: 1))
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
        guard let cgImage else { throw EngineError.pipelineFailed("cgimage") }
        return cgImage
    }

    /// 現フレームを PNG データにする(ファイル書き出し・スナップショット返却で共用)。
    /// maxDimension を指定すると長辺がその値になるよう縮小する(プレビュー用)。
    public func makePNGData(maxDimension: Int? = nil) throws -> Data {
        var cgImage = try renderFrameCGImage()
        if let maxDim = maxDimension, maxDim >= 8, max(gridWidth, gridHeight) > maxDim {
            let scale = Float(maxDim) / Float(max(gridWidth, gridHeight))
            let w = max(Int(Float(gridWidth) * scale), 1)
            let h = max(Int(Float(gridHeight) * scale), 1)
            if let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ) {
                ctx.interpolationQuality = .high
                ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
                if let scaled = ctx.makeImage() { cgImage = scaled }
            }
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else { throw EngineError.pipelineFailed("png export") }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { throw EngineError.pipelineFailed("png finalize") }
        return data as Data
    }

    /// 現フレームをグリッド等倍で PNG に書き出す。
    public func savePNG(to url: URL) throws {
        try makePNGData().write(to: url)
    }

    // MARK: - 状態クエリ

    /// 濡れているセル(W > wetThreshold)の割合 0...1。「乾くまで待つ」用のヒューリスティック。
    /// waterA は storageModeShared なので CPU から直接読む。GPU が書き込み中の値を読む
    /// 可能性はあるが、乾燥の進み具合の目安としては十分。
    public var wetFraction: Float {
        let cellCount = gridWidth * gridHeight
        let ptr = waterA.contents().bindMemory(to: Float.self, capacity: cellCount)
        var wet = 0
        for i in 0..<cellCount where ptr[i] > params.wetThreshold { wet += 1 }
        return Float(wet) / Float(cellCount)
    }

    // MARK: - 内部

    private func stampRadius(pressure: Float) -> Float {
        brush.baseRadius * (brush.minRadiusFactor + (1 - brush.minRadiusFactor) * pressure)
    }

    /// 墨のかすれは「軽いタッチ・速い筆・乾いた筆ほど強い」。乾いた筆(dryness>0)にだけ効かせ、
    /// 水彩(dryness 0)はウェットのまま触らない。筆圧が抜けるほど実効 dryness を 1 へ寄せる
    /// (入り・抜き・速いマウス払いでかすれる。マウスは擬似筆圧が速度→筆圧に変換済み)。
    /// 水量スライダを上げると水で埋まってかすれが減る。
    /// 加算幅は dryness 非依存の一定幅(0.30)にして clamp で抑える。`(1-dryness)` で
    /// 重み付けすると既に乾いた筆(.sumi=0.85)で頭打ちになり、筆圧のレバーがほぼ効かないため。
    private func effectiveDryness(pressure: Float) -> Float {
        let d = brush.dryness
        guard d > 0 else { return 0 }
        let lighten = (1 - pressure) * 0.30              // 軽いタッチでかすれを足す(一定幅)
        let wetFill = max(0, brush.water - 0.15) * 0.6   // 水を増やすと埋まる
        return simd_clamp(d + lighten - wetFill, 0, 1)
    }

    private func appendStamp(for sample: InputSample, dir: SIMD2<Float>) {
        guard pendingStamps.count < maxStampsPerFrame else { return }
        pendingStamps.append(Stamp(
            pos: sample.position,
            radius: stampRadius(pressure: sample.pressure),
            water: brush.water * (0.4 + 0.6 * sample.pressure),
            pigment: brush.absorbance * (brush.pigment * (0.3 + 0.7 * sample.pressure)),
            dryness: effectiveDryness(pressure: sample.pressure),
            dir: dir
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
