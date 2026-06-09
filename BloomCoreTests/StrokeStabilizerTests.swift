import XCTest
import simd
@testable import BloomCore

final class StrokeStabilizerTests: XCTestCase {

    private func variance(_ xs: [Float]) -> Float {
        guard !xs.isEmpty else { return 0 }
        let mean = xs.reduce(0, +) / Float(xs.count)
        return xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(xs.count)
    }

    /// 強度 0 では入力をそのまま素通しし、flush も空になること(完全オフ)
    func testZeroStrengthPassesThrough() {
        var s = StrokeStabilizer(strength: 0)
        let inputs = (0..<50).map { SIMD2<Float>(Float($0) * 3, sin(Float($0)) * 10) }
        s.reset(at: inputs[0])
        var outputs: [SIMD2<Float>] = []
        for p in inputs { if let o = s.process(p) { outputs.append(o) } }
        XCTAssertEqual(outputs.count, inputs.count, "据え置きが起きず全点が出る")
        for (a, b) in zip(inputs, outputs) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-5)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-5)
        }
        XCTAssertTrue(s.flush(to: inputs.last!).isEmpty, "強度 0 なら flush は空")
    }

    /// 直線+ジッタ入力で、縦方向のばらつきが補正後に大きく減ること
    func testReducesJitter() {
        var s = StrokeStabilizer(strength: 0.7) // L = 33.6 > ジッタ振幅 20
        let baseline: Float = 100
        let inputs = (0..<200).map { i -> SIMD2<Float> in
            SIMD2(Float(i) * 4, baseline + 20 * sin(Float(i) * 1.3))
        }
        s.reset(at: inputs[0])
        var outY: [Float] = []
        for p in inputs { if let o = s.process(p) { outY.append(o.y) } }
        let inVar = variance(inputs.map { $0.y })
        let outVar = variance(outY)
        XCTAssertLessThan(outVar, inVar * 0.5, "補正で縦方向のばらつきが半分以下に減る")
    }

    /// flush 後に出力が実終点へ到達すること(プル方式のキャッチアップ)
    func testFlushReachesFinalPoint() {
        var s = StrokeStabilizer(strength: 0.8)
        let inputs = (0..<30).map { SIMD2<Float>(Float($0) * 10, Float($0) * 2) }
        s.reset(at: inputs[0])
        for p in inputs { _ = s.process(p) }
        let end = inputs.last!
        let flushed = s.flush(to: end)
        XCTAssertFalse(flushed.isEmpty, "anchor は終点より手前なので補完点が出る")
        XCTAssertEqual(flushed.last!.x, end.x, accuracy: 1e-3)
        XCTAssertEqual(flushed.last!.y, end.y, accuracy: 1e-3)
        XCTAssertEqual(s.outputPoint!.x, end.x, accuracy: 1e-3, "flush 後 anchor は終点に一致")
        XCTAssertEqual(s.outputPoint!.y, end.y, accuracy: 1e-3)
    }

    /// 一方向へ動かしたとき、出力が逆行(オーバーシュート)しないこと
    func testMonotonicProgressAlongStroke() {
        var s = StrokeStabilizer(strength: 0.6)
        let inputs = (0..<100).map { SIMD2<Float>(Float($0) * 5, 50) } // 単調に +x、y 一定
        s.reset(at: inputs[0])
        var xs: [Float] = []
        for p in inputs { if let o = s.process(p) { xs.append(o.x) } }
        for p in s.flush(to: inputs.last!) { xs.append(p.x) }
        for i in 1..<xs.count {
            XCTAssertGreaterThanOrEqual(xs[i] + 1e-4, xs[i - 1], "出力 x は逆行しない")
        }
    }

    /// reset 後は前ストロークの anchor を引きずらず、最初の点を素通しすること
    func testResetClearsState() {
        var s = StrokeStabilizer(strength: 0.7)
        let first = (0..<40).map { SIMD2<Float>(Float($0) * 8, 0) }
        s.reset(at: first[0])
        for p in first { _ = s.process(p) }
        _ = s.flush(to: first.last!)

        let q = SIMD2<Float>(500, 500)
        s.reset(at: q)
        let o = s.process(q)
        XCTAssertNotNil(o)
        XCTAssertEqual(o!.x, q.x, accuracy: 1e-4, "reset 直後の最初の点は素通し")
        XCTAssertEqual(o!.y, q.y, accuracy: 1e-4)
    }

    /// 出力(anchor)は常に実カーソルから紐長以内にとどまること(遅延の上界)
    func testStaysWithinLeashOfTarget() {
        var s = StrokeStabilizer(strength: 0.5)
        let leash = s.leashLength
        let inputs = (0..<300).map { i -> SIMD2<Float> in
            SIMD2(Float(i) * 3 + 15 * sin(Float(i) * 0.9), 40 * cos(Float(i) * 0.7))
        }
        s.reset(at: inputs[0])
        for p in inputs {
            _ = s.process(p)
            XCTAssertLessThanOrEqual(simd_distance(s.outputPoint!, p), leash + 1e-3,
                                     "出力は実カーソルから紐長以内")
        }
    }
}
