import XCTest
@testable import BloomCore

@MainActor
final class DocumentTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bloom-test-\(UUID().uuidString).bloom")
    }

    func testRoundTripPreservesLayers() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let a = try SimulationEngine(width: 96, height: 72)
        a.addLayer()                       // 2枚目(手前・アクティブ)
        a.setLayerOpacity(row: 0, opacity: 0.5)
        a.toggleLayerVisible(row: 1)       // 奥を非表示
        try a.saveDocument(to: url)

        let b = try SimulationEngine(width: 96, height: 72)
        try b.loadDocument(from: url)

        XCTAssertEqual(b.layerCount, 2)
        let infos = b.layerInfos // row0 = 手前
        XCTAssertEqual(infos[0].opacity, 0.5, accuracy: 0.001)
        XCTAssertFalse(infos[1].visible, "奥の非表示が保たれる")
        XCTAssertEqual(infos.map(\.name), a.layerInfos.map(\.name))
        XCTAssertEqual(b.activeLayerRow, a.activeLayerRow)
    }

    func testLoadResetsUndoHistory() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let a = try SimulationEngine(width: 64, height: 64)
        try a.saveDocument(to: url)

        let b = try SimulationEngine(width: 64, height: 64)
        b.addLayer() // 履歴ができる
        XCTAssertTrue(b.canUndo)
        try b.loadDocument(from: url)
        XCTAssertFalse(b.canUndo, "読み込みで履歴はリセットされる")
    }

    func testDimensionMismatchThrows() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let a = try SimulationEngine(width: 64, height: 64)
        try a.saveDocument(to: url)

        let b = try SimulationEngine(width: 80, height: 64) // 異なる幅
        XCTAssertThrowsError(try b.loadDocument(from: url))
    }

    func testBadMagicThrows() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0, 1, 2, 3, 4, 5]).write(to: url)

        let e = try SimulationEngine(width: 64, height: 64)
        XCTAssertThrowsError(try e.loadDocument(from: url))
    }
}
