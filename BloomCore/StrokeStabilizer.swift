import Foundation
import simd

/// 手ブレ補正(入力点列のスムージング)。プルストリング(ラバーバンド)方式。
///
/// 出力点(anchor)が実カーソルへ向かい、両者の距離が「紐長 L」を超えた分だけ追従する。
/// 手の微小なジッタ(< L)は吸収され、意図した移動だけが線になる。幾何ベースなので
/// 時間刻み(サンプルレート)に依存せず、NSEvent のドラッグ頻度が揺れても挙動が安定する。
///
/// これは「人間の手の揺れ」を補正する入力層の機能。MCP 等が `addStrokeSample` に渡す
/// 意図された座標は補正しないため、コア(SimulationEngine)には埋め込まず UI 入力経路で適用する。
/// 位置のみ平滑化し、筆圧はいじらない(擬似筆圧は PseudoPressureEstimator で既にローパス済み)。
public struct StrokeStabilizer: Sendable {

    /// strength=1 のときの紐の長さ[pt]。この距離までの揺れを吸収する。
    private let maxLength: Float = 48
    private let epsilon: Float = 1e-4

    private var _strength: Float
    private var anchor: SIMD2<Float>?  // 現在の出力位置(= 仮想カーソル)
    private var needsFirstEmit = false // reset 直後の最初の点は遅延ゼロで素通しする

    /// 補正の強さ。0 = 完全パススルー(オフ)、1 = 最大。実行中に変えても安全。
    public var strength: Float {
        get { _strength }
        set { _strength = min(max(newValue, 0), 1) }
    }

    /// 現在の紐の長さ[pt](= 出力が実カーソルから遅れる上限)。
    public var leashLength: Float { _strength * maxLength }

    /// 現在の出力位置(平滑化後)。ストローク開始前は nil。
    public var outputPoint: SIMD2<Float>? { anchor }

    public init(strength: Float = 0) {
        _strength = min(max(strength, 0), 1)
    }

    /// ストローク開始時に呼ぶ。前ストロークの状態を捨て、最初の点を素通しできるようにする。
    public mutating func reset(at point: SIMD2<Float>) {
        anchor = point
        needsFirstEmit = true
    }

    /// 入力点を 1 つ処理する。描くべき点を返す。揺れの範囲内で据え置く場合は nil。
    public mutating func process(_ point: SIMD2<Float>) -> SIMD2<Float>? {
        // 最初の点(またはオフ)は遅延ゼロで素通し。
        if needsFirstEmit || leashLength <= epsilon {
            needsFirstEmit = false
            anchor = point
            return point
        }
        guard let a = anchor else { // reset を経ていない場合のフォールバック
            anchor = point
            return point
        }
        let delta = point - a
        let d = simd_length(delta)
        let L = leashLength
        if d <= L { return nil } // 紐の内側 = 手ブレとみなして据え置く
        let advance = (d - L) / d // 紐の外へ出た分だけ追従
        let next = a + delta * advance
        anchor = next
        return next
    }

    /// ストローク終了時に呼ぶ。anchor から実終点までを中間点列で埋め、線を終点へ届かせる。
    /// プル方式は出力が実カーソルより遅れるため、これをやらないと線が目標まで届かない。
    public mutating func flush(to finalPoint: SIMD2<Float>) -> [SIMD2<Float>] {
        defer {
            anchor = finalPoint
            needsFirstEmit = false
        }
        guard let a = anchor else { return [] }
        let delta = finalPoint - a
        let dist = simd_length(delta)
        guard dist > epsilon else { return [] }
        // コアのスタンプ間隔で繋がるよう細かく刻む(点線化を避ける)。
        let stepLen: Float = 6
        let steps = max(1, Int((dist / stepLen).rounded(.up)))
        var points: [SIMD2<Float>] = []
        points.reserveCapacity(steps)
        for i in 1...steps {
            let t = Float(i) / Float(steps)
            points.append(a + delta * t)
        }
        return points
    }
}
