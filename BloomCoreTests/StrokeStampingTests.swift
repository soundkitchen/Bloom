import XCTest
import simd
@testable import BloomCore

@MainActor
final class StrokeStampingTests: XCTestCase {

    /// 回帰テスト: ゆっくり描いても(1 イベントの移動が間隔未満でも)
    /// 距離が累積して最終的にスタンプが打たれること。
    /// 以前はアンカーが毎イベント前進して距離がリセットされ、永遠に描かれなかった。
    func testSlowMovementStillProducesStamps() throws {
        let engine = try SimulationEngine(width: 128, height: 128)
        engine.brush = .watercolor
        engine.beginStroke()

        // 始点で 1 つ打たれる
        engine.addStrokeSample(at: SIMD2(10, 10), pressure: 1.0)
        let afterFirst = engine.pendingStampCount
        XCTAssertEqual(afterFirst, 1)

        // 1pt ずつの細かい移動を 40 回(= スタンプ間隔 6.6pt より遥かに細かい)
        for i in 1...40 {
            engine.addStrokeSample(at: SIMD2(10 + Float(i), 10), pressure: 1.0)
        }

        // 累積 40pt 移動 → 間隔ごとに複数スタンプが打たれているはず
        XCTAssertGreaterThan(
            engine.pendingStampCount, afterFirst,
            "ゆっくりした移動でもスタンプが追加されること"
        )
    }

    /// 全く動かなければ始点の 1 つだけ(移動由来の重複スタンプを増やさない)
    func testStationaryProducesSingleStamp() throws {
        let engine = try SimulationEngine(width: 128, height: 128)
        engine.beginStroke()
        engine.addStrokeSample(at: SIMD2(20, 20), pressure: 1.0)
        for _ in 0..<10 {
            engine.addStrokeSample(at: SIMD2(20, 20), pressure: 1.0)
        }
        XCTAssertEqual(engine.pendingStampCount, 1)
    }

    /// 筆を下ろしている間は、動かさなくてもドウェル供給でスタンプが継ぎ足される
    func testDwellFeedsWhileBrushIsDown() throws {
        let engine = try SimulationEngine(width: 128, height: 128)
        engine.beginStroke()
        engine.addStrokeSample(at: SIMD2(40, 40), pressure: 1.0)
        let baseline = engine.pendingStampCount

        // renderFrame 相当のドウェル tick を 5 回
        for _ in 0..<5 { engine.emitDwellStamp() }
        XCTAssertEqual(engine.pendingStampCount, baseline + 5, "下ろしている間は毎フレーム継ぎ足す")
    }

    /// 筆を上げたら(endStroke)ドウェル供給は止まる
    func testDwellStopsAfterEndStroke() throws {
        let engine = try SimulationEngine(width: 128, height: 128)
        engine.beginStroke()
        engine.addStrokeSample(at: SIMD2(40, 40), pressure: 1.0)
        engine.endStroke()
        let baseline = engine.pendingStampCount

        for _ in 0..<5 { engine.emitDwellStamp() }
        XCTAssertEqual(engine.pendingStampCount, baseline, "上げたら継ぎ足さない")
    }
}
