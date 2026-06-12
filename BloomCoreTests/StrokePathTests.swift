import XCTest
import simd
@testable import BloomCore

final class StrokePathTests: XCTestCase {

    private func sample(_ x: Float, _ y: Float, _ p: Float = 0.5) -> InputSample {
        InputSample(position: SIMD2(x, y), pressure: p)
    }

    func testEndpointsArePreserved() {
        let points = [sample(10, 10, 0.2), sample(60, 40, 0.9), sample(120, 10, 0.4)]
        let out = StrokePath.interpolate(points, spacing: 3)
        XCTAssertEqual(out.first!.position, points.first!.position)
        XCTAssertEqual(out.last!.position, points.last!.position)
        XCTAssertEqual(out.first!.pressure, points.first!.pressure)
        XCTAssertEqual(out.last!.pressure, points.last!.pressure)
    }

    func testDensifiesSparseControlPoints() {
        // 100pt 離れた 2 点 → spacing 3 なら 30 点以上に増える
        let out = StrokePath.interpolate([sample(0, 0), sample(100, 0)], spacing: 3)
        XCTAssertGreaterThanOrEqual(out.count, 30)
        // 2 点なら直線: y はずっと 0
        for s in out { XCTAssertEqual(s.position.y, 0, accuracy: 0.001) }
    }

    func testPressureInterpolatesLinearly() {
        let out = StrokePath.interpolate([sample(0, 0, 0.0), sample(100, 0, 1.0)], spacing: 1)
        // 中間点の筆圧は位置に比例する(直線なので x/100)
        for s in out {
            XCTAssertEqual(s.pressure, s.position.x / 100, accuracy: 0.05)
        }
    }

    func testCurvePassesNearControlPoints() {
        // 山なりの 3 点。スプラインは制御点を通る(Catmull-Rom の性質)
        let mid = sample(50, 60, 0.5)
        let out = StrokePath.interpolate([sample(0, 0), mid, sample(100, 0)], spacing: 2)
        let nearest = out.map { simd_length($0.position - mid.position) }.min()!
        XCTAssertLessThan(nearest, 2.5, "スプラインが中間制御点のそばを通ること")
    }

    func testSinglePointPassesThrough() {
        let out = StrokePath.interpolate([sample(5, 5)], spacing: 3)
        XCTAssertEqual(out.count, 1)
    }
}
