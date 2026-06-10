import XCTest
import AVFoundation
@testable import BloomCore

@MainActor
final class AnimationTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bloom-anim-\(UUID().uuidString).bloom")
    }

    func testInitialIsSingleFrame() throws {
        let e = try SimulationEngine(width: 64, height: 64)
        XCTAssertEqual(e.frameTotal, 1)
        XCTAssertEqual(e.currentFrameIndex, 0)
    }

    func testAddFrameInsertsHoldAndAdvances() throws {
        let e = try SimulationEngine(width: 64, height: 64)
        e.addFrame()
        XCTAssertEqual(e.frameTotal, 2)
        XCTAssertEqual(e.currentFrameIndex, 1)
        // 追加フレームは保持(セルなし)
        XCTAssertFalse(e.celExists(trackRow: 0, frame: 1))
        // フレーム0 には初期セルがある
        XCTAssertTrue(e.celExists(trackRow: 0, frame: 0))
    }

    func testDrawingOnHoldFrameCreatesCel() throws {
        let e = try SimulationEngine(width: 64, height: 64)
        e.addFrame() // frame 1 は保持
        XCTAssertFalse(e.celExists(trackRow: 0, frame: 1))
        e.beginStroke() // 保持を切って新原画
        XCTAssertTrue(e.celExists(trackRow: 0, frame: 1))
    }

    func testDuplicateFrameCreatesIndependentCel() throws {
        let e = try SimulationEngine(width: 64, height: 64)
        e.duplicateFrame() // frame0 の内容を複製して frame1 へ
        XCTAssertEqual(e.frameTotal, 2)
        XCTAssertEqual(e.currentFrameIndex, 1)
        XCTAssertTrue(e.celExists(trackRow: 0, frame: 1), "複製は実セルを持つ(保持ではない)")
    }

    func testDeleteFrameKeepsAtLeastOne() throws {
        let e = try SimulationEngine(width: 64, height: 64)
        e.deleteFrame()
        XCTAssertEqual(e.frameTotal, 1, "最後の 1 フレームは消えない")
    }

    func testGoToFrameClamps() throws {
        let e = try SimulationEngine(width: 64, height: 64)
        e.addFrame(); e.addFrame() // 3 フレーム
        e.goToFrame(99)
        XCTAssertEqual(e.currentFrameIndex, 2)
        e.goToFrame(-5)
        XCTAssertEqual(e.currentFrameIndex, 0)
    }

    func testFrameOpIsUndoable() throws {
        let e = try SimulationEngine(width: 64, height: 64)
        e.addFrame()
        XCTAssertEqual(e.frameTotal, 2)
        e.undo()
        XCTAssertEqual(e.frameTotal, 1, "フレーム追加を取り消すと 1 に戻る")
        e.redo()
        XCTAssertEqual(e.frameTotal, 2)
    }

    func testV2RoundTripPreservesFrames() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let a = try SimulationEngine(width: 80, height: 64)
        a.addFrame()
        a.duplicateFrame() // 3 フレーム
        a.addLayer()       // 2 トラック
        try a.saveDocument(to: url)

        let b = try SimulationEngine(width: 80, height: 64)
        try b.loadDocument(from: url)
        XCTAssertEqual(b.frameTotal, 3)
        XCTAssertEqual(b.layerCount, 2)
    }

    private func tempMP4URL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bloom-mp4-\(UUID().uuidString).mp4")
    }

    func testExportMP4ProducesPlayableVideo() async throws {
        let e = try SimulationEngine(width: 64, height: 48) // 偶数
        e.addFrame(); e.addFrame() // 3 フレーム
        let url = tempMP4URL()
        defer { try? FileManager.default.removeItem(at: url) }

        try e.exportMP4(to: url, fps: 12)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1, "動画トラックが 1 本ある")
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0, "尺がある")
    }

    func testExportMP4RoundsToEvenDimensions() async throws {
        let e = try SimulationEngine(width: 65, height: 49) // 奇数 → 64×48 に丸まる想定
        e.addFrame()
        let url = tempMP4URL()
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNoThrow(try e.exportMP4(to: url, fps: 12), "奇数寸法でも throw しない")

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let size = try await tracks[0].load(.naturalSize)
        XCTAssertEqual(size.width, 64, "幅は偶数へ切り捨て")
        XCTAssertEqual(size.height, 48, "高さは偶数へ切り捨て")
    }

    /// v1 ドキュメント(単一フレーム)を手組みして後方互換読み込みを検証
    func testV1BackwardCompatLoads() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let w = 16, h = 16
        var d = Data()
        func u32(_ v: UInt32) { d.append(UInt8(v & 0xff)); d.append(UInt8((v >> 8) & 0xff))
                                d.append(UInt8((v >> 16) & 0xff)); d.append(UInt8((v >> 24) & 0xff)) }
        d.append(contentsOf: [0x42, 0x4C, 0x4D, 0x31]) // magic
        u32(1)            // version 1
        u32(UInt32(w)); u32(UInt32(h))
        u32(1)            // layerCount
        u32(0)            // activeIndex
        u32(1)            // layerCounter
        let name = Array("レイヤー 1".utf8)
        u32(UInt32(name.count)); d.append(contentsOf: name)
        d.append(1)       // visible
        u32(Float(1.0).bitPattern) // opacity
        d.append(Data(count: w * h * 16)) // deposit raw(全 0)
        try d.write(to: url)

        let e = try SimulationEngine(width: w, height: h)
        try e.loadDocument(from: url)
        XCTAssertEqual(e.frameTotal, 1, "v1 は単一フレームとして読める")
        XCTAssertEqual(e.layerCount, 1)
    }
}
