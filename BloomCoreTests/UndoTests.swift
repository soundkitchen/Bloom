import XCTest
@testable import BloomCore

@MainActor
final class UndoTests: XCTestCase {

    func testInitialHasNoHistory() throws {
        let engine = try SimulationEngine(width: 64, height: 64)
        XCTAssertFalse(engine.canUndo)
        XCTAssertFalse(engine.canRedo)
    }

    func testAddLayerThenUndoRedo() throws {
        let engine = try SimulationEngine(width: 64, height: 64)
        engine.addLayer()
        XCTAssertEqual(engine.layerCount, 2)
        XCTAssertTrue(engine.canUndo)

        engine.undo()
        XCTAssertEqual(engine.layerCount, 1, "レイヤー追加を取り消すと 1 枚に戻る")
        XCTAssertTrue(engine.canRedo)

        engine.redo()
        XCTAssertEqual(engine.layerCount, 2, "やり直すと 2 枚に戻る")
    }

    func testDeleteLayerThenUndoRestores() throws {
        let engine = try SimulationEngine(width: 64, height: 64)
        engine.addLayer() // 2枚
        engine.addLayer() // 3枚
        XCTAssertEqual(engine.layerCount, 3)
        engine.deleteLayer(row: 0)
        XCTAssertEqual(engine.layerCount, 2)
        engine.undo()
        XCTAssertEqual(engine.layerCount, 3, "削除を取り消すと層が戻る")
    }

    func testNewActionClearsRedo() throws {
        let engine = try SimulationEngine(width: 64, height: 64)
        engine.addLayer()
        engine.undo()
        XCTAssertTrue(engine.canRedo)
        engine.addLayer() // 新しい操作で redo は破棄される
        XCTAssertFalse(engine.canRedo)
    }

    func testStrokeIsUndoable() throws {
        let engine = try SimulationEngine(width: 64, height: 64)
        engine.beginStroke()
        engine.addStrokeSample(at: SIMD2(20, 20), pressure: 1.0)
        engine.endStroke()
        XCTAssertTrue(engine.canUndo, "ストロークは取り消し単位になる")
    }

    func testUndoDepthIsBounded() throws {
        let engine = try SimulationEngine(width: 32, height: 32)
        for _ in 0..<40 { engine.clear() } // 上限 30 を超える回数
        var count = 0
        while engine.canUndo { engine.undo(); count += 1 }
        XCTAssertLessThanOrEqual(count, 30, "undo 履歴は上限で頭打ち")
    }
}
