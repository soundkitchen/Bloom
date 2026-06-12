import XCTest
import simd
import Metal
import ImageIO
@testable import BloomCore

/// MCP サーバ向けに追加した API(makePNGData / wetFraction)のテスト
@MainActor
final class MCPSupportTests: XCTestCase {

    /// オフスクリーンテクスチャへ renderFrame を回す(ヘッドレスの 1 tick = アプリの 1 描画フレーム相当)
    private func tick(_ e: SimulationEngine, frames: Int = 1) throws {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: e.gridWidth, height: e.gridHeight, mipmapped: false
        )
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .shared
        guard let tex = e.metalDevice.makeTexture(descriptor: desc) else {
            throw SimulationEngine.EngineError.pipelineFailed("test texture")
        }
        for _ in 0..<frames {
            guard let cb = e.makeCommandBuffer() else {
                throw SimulationEngine.EngineError.pipelineFailed("test command buffer")
            }
            e.renderFrame(into: tex, commandBuffer: cb)
            cb.commit()
            cb.waitUntilCompleted()
        }
    }

    func testMakePNGDataReturnsValidPNGWithGridSize() throws {
        let e = try SimulationEngine(width: 96, height: 64)
        let data = try e.makePNGData()
        XCTAssertEqual(
            [UInt8](data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
            "PNG シグネチャで始まること"
        )
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return XCTFail("PNG としてデコードできること")
        }
        XCTAssertEqual(img.width, 96, "グリッド等倍であること")
        XCTAssertEqual(img.height, 64)
    }

    func testMakePNGDataMaxDimensionScalesDown() throws {
        let e = try SimulationEngine(width: 96, height: 64)
        let data = try e.makePNGData(maxDimension: 48)
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return XCTFail("PNG としてデコードできること")
        }
        XCTAssertEqual(img.width, 48, "長辺が maxDimension に縮むこと")
        XCTAssertEqual(img.height, 32, "アスペクト比が保たれること")
    }

    func testWetFractionRisesWithStrokeAndFallsWithClear() throws {
        let e = try SimulationEngine(width: 64, height: 64)
        XCTAssertEqual(e.wetFraction, 0, "初期状態は乾いている")

        e.brush = .watercolor
        e.beginStroke()
        e.addStrokeSample(at: SIMD2(32, 32), pressure: 1.0)
        e.endStroke()
        try tick(e) // スタンプが W に反映されるのは renderFrame 時
        XCTAssertGreaterThan(e.wetFraction, 0, "ストローク直後は濡れている")

        e.clear()
        XCTAssertEqual(e.wetFraction, 0, "クリアでウェットも消える")
    }
}
