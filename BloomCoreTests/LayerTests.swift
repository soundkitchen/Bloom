import XCTest
@testable import BloomCore

@MainActor
final class LayerTests: XCTestCase {

    func testStartsWithOneLayer() throws {
        let engine = try SimulationEngine(width: 64, height: 64)
        XCTAssertEqual(engine.layerCount, 1)
        XCTAssertEqual(engine.activeLayerRow, 0)
    }

    func testAddLayerInsertsAboveAndActivates() throws {
        let engine = try SimulationEngine(width: 64, height: 64)
        engine.addLayer()
        XCTAssertEqual(engine.layerCount, 2)
        // 追加した層が手前(row 0)でアクティブ
        XCTAssertEqual(engine.activeLayerRow, 0)
        XCTAssertEqual(engine.layerInfos.count, 2)
    }

    func testDeleteKeepsAtLeastOne() throws {
        let engine = try SimulationEngine(width: 64, height: 64)
        engine.deleteLayer(row: 0)
        XCTAssertEqual(engine.layerCount, 1, "最後の 1 枚は消えない")
    }

    func testDeleteAdjustsActive() throws {
        let engine = try SimulationEngine(width: 64, height: 64)
        engine.addLayer() // 2枚, active=手前(row0)
        engine.addLayer() // 3枚, active=手前(row0)
        XCTAssertEqual(engine.layerCount, 3)
        engine.deleteLayer(row: 0) // 手前(=アクティブ)を削除
        XCTAssertEqual(engine.layerCount, 2)
        XCTAssertGreaterThanOrEqual(engine.activeLayerRow, 0)
        XCTAssertLessThan(engine.activeLayerRow, engine.layerCount)
    }

    func testToggleVisibility() throws {
        let engine = try SimulationEngine(width: 64, height: 64)
        engine.addLayer()
        XCTAssertTrue(engine.layerInfos[1].visible)
        engine.toggleLayerVisible(row: 1)
        XCTAssertFalse(engine.layerInfos[1].visible)
        engine.toggleLayerVisible(row: 1)
        XCTAssertTrue(engine.layerInfos[1].visible)
    }

    func testSetActiveLayer() throws {
        let engine = try SimulationEngine(width: 64, height: 64)
        engine.addLayer() // active row 0
        engine.setActiveLayer(row: 1)
        XCTAssertEqual(engine.activeLayerRow, 1)
    }

    func testMoveLayerReorders() throws {
        let engine = try SimulationEngine(width: 64, height: 64)
        engine.addLayer() // 2枚: row0=レイヤー2(手前), row1=レイヤー1(奥)
        let before = engine.layerInfos.map(\.name)
        XCTAssertEqual(before, ["レイヤー 2", "レイヤー 1"])
        engine.moveLayer(fromRow: 1, toRow: 0) // 奥(レイヤー1)を手前へ
        let after = engine.layerInfos.map(\.name)
        XCTAssertEqual(after, ["レイヤー 1", "レイヤー 2"])
    }

    func testMoveLayerKeepsActiveLayer() throws {
        let engine = try SimulationEngine(width: 64, height: 64)
        engine.addLayer()                 // active = レイヤー2(row0)
        engine.setActiveLayer(row: 1)     // active = レイヤー1
        engine.moveLayer(fromRow: 0, toRow: 1) // 手前のレイヤー2 を奥へ
        // アクティブはレイヤー1 のまま追従する
        let activeName = engine.layerInfos[engine.activeLayerRow].name
        XCTAssertEqual(activeName, "レイヤー 1")
    }

    func testSetLayerOpacityClamps() throws {
        let engine = try SimulationEngine(width: 64, height: 64)
        engine.setLayerOpacity(row: 0, opacity: 2.0)
        XCTAssertEqual(engine.layerInfos[0].opacity, 1.0, accuracy: 0.001)
        engine.setLayerOpacity(row: 0, opacity: -1.0)
        XCTAssertEqual(engine.layerInfos[0].opacity, 0.0, accuracy: 0.001)
    }
}
