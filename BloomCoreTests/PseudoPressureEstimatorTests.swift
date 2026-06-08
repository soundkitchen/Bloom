import XCTest
@testable import BloomCore

final class PseudoPressureEstimatorTests: XCTestCase {

    /// 速く動かすほど筆圧が下がる(= 細く・かすれる)こと
    func testFasterMovementYieldsLowerPressure() {
        var slowEstimator = PseudoPressureEstimator(initial: 0.55)
        var fastEstimator = PseudoPressureEstimator(initial: 0.55)
        var slow: Float = 0
        var fast: Float = 0
        for i in 0..<60 {
            let t = TimeInterval(i) * 0.01
            slow = slowEstimator.estimate(point: SIMD2(Float(i) * 1.0, 0), time: t)   // 100 pt/s
            fast = fastEstimator.estimate(point: SIMD2(Float(i) * 50.0, 0), time: t)  // 5000 pt/s
        }
        XCTAssertGreaterThan(slow, fast)
        XCTAssertGreaterThan(slow, 0.7, "ゆっくりなら高筆圧に収束する")
        XCTAssertLessThan(fast, 0.3, "速ければ低筆圧に収束する")
    }

    /// 出力が常に 0...1 の範囲に収まること
    func testPressureStaysInUnitRange() {
        var estimator = PseudoPressureEstimator()
        for i in 0..<200 {
            let speed = Float(i % 7) * 800 // 速度を激しく変動させる
            let p = estimator.estimate(
                point: SIMD2(Float(i) * speed * 0.01, 0),
                time: TimeInterval(i) * 0.01
            )
            XCTAssertGreaterThanOrEqual(p, 0)
            XCTAssertLessThanOrEqual(p, 1)
        }
    }

    /// reset 後は前のストロークの速度履歴を引きずらないこと
    func testResetClearsHistory() {
        var estimator = PseudoPressureEstimator(initial: 0.55)
        for i in 0..<60 {
            _ = estimator.estimate(point: SIMD2(Float(i) * 50, 0), time: TimeInterval(i) * 0.01)
        }
        estimator.reset(initial: 0.55)
        let p = estimator.estimate(point: SIMD2(0, 0), time: 100)
        XCTAssertEqual(p, 0.55, accuracy: 0.001, "reset 直後は初期値から始まる")
    }
}
