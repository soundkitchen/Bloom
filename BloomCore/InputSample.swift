import Foundation
import simd

/// デバイス非依存の入力サンプル。タブレット・マウス・MCP どこから来ても同じ形にする。
public struct InputSample: Sendable {
    public var position: SIMD2<Float> // グリッド座標(y は下向き)
    public var pressure: Float        // 0...1
    public init(position: SIMD2<Float>, pressure: Float) {
        self.position = position
        self.pressure = pressure
    }
}

/// マウス等の筆圧なし入力から、カーソル速度で擬似筆圧を作る。
/// 速く動かすほど軽く(細く・かすれ)、ゆっくりだと重く(太く・濡れる)。
public struct PseudoPressureEstimator {
    private var lastPoint: SIMD2<Float>?
    private var lastTime: TimeInterval?
    private var smoothed: Float

    /// speed [pt/s] がこの値でほぼ最小筆圧になる
    private let fullSpeed: Float = 1600
    private let minPressure: Float = 0.12
    private let smoothing: Float = 0.18

    public init(initial: Float = 0.55) {
        smoothed = initial
    }

    public mutating func reset(initial: Float = 0.55) {
        lastPoint = nil
        lastTime = nil
        smoothed = initial
    }

    public mutating func estimate(point: SIMD2<Float>, time: TimeInterval) -> Float {
        defer {
            lastPoint = point
            lastTime = time
        }
        guard let lp = lastPoint, let lt = lastTime, time > lt else { return smoothed }
        let dt = Float(time - lt)
        let speed = simd_distance(point, lp) / max(dt, 1e-4)
        let target = max(1.0 - speed / fullSpeed, minPressure)
        smoothed += (target - smoothed) * smoothing // ローパスで急変を防ぐ
        return smoothed
    }
}
