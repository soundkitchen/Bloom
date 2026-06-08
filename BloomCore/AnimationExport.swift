import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// アニメーション書き出し: GIF / スプライトシート / PNG 連番。
/// 各フレームに移動して合成を CGImage 化(`renderFrameCGImage`)し、ImageIO/CoreGraphics で書く。
/// いずれも書き出し後に currentFrame を元へ戻す。書き出すのは乾いた deposit(ウェットは含めない)。
extension SimulationEngine {

    /// 全フレームを CGImage 配列にする(currentFrame・オニオン設定は元に戻す)
    private func renderAllFrames() throws -> [CGImage] {
        let savedFrame = currentFrameIndex
        let savedOnion = onionEnabled
        setOnionEnabled(false) // 書き出しにオニオンは含めない
        defer { setOnionEnabled(savedOnion); goToFrame(savedFrame) }
        var images: [CGImage] = []
        for f in 0..<frameTotal {
            goToFrame(f)
            images.append(try renderFrameCGImage())
        }
        return images
    }

    /// アニメーション GIF。fps はフレーム遅延、loop=0 で無限ループ。
    public func exportGIF(to url: URL, fps: Double = 12, loop: Int = 0) throws {
        let frames = try renderAllFrames()
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw EngineError.pipelineFailed("gif dest")
        }
        let gifProps = [kCGImagePropertyGIFDictionary as String:
                        [kCGImagePropertyGIFLoopCount as String: loop]]
        CGImageDestinationSetProperties(dest, gifProps as CFDictionary)
        let delay = 1.0 / max(fps, 1)
        let frameProps = [kCGImagePropertyGIFDictionary as String: [
            kCGImagePropertyGIFUnclampedDelayTime as String: delay,
            kCGImagePropertyGIFDelayTime as String: delay,
        ]]
        for img in frames { CGImageDestinationAddImage(dest, img, frameProps as CFDictionary) }
        guard CGImageDestinationFinalize(dest) else { throw EngineError.pipelineFailed("gif finalize") }
    }

    /// フレームごとの番号付き PNG(frame_0001.png …)
    public func exportPNGSequence(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let savedFrame = currentFrameIndex
        let savedOnion = onionEnabled
        setOnionEnabled(false)
        defer { setOnionEnabled(savedOnion); goToFrame(savedFrame) }
        for f in 0..<frameTotal {
            goToFrame(f)
            try savePNG(to: directory.appendingPathComponent(String(format: "frame_%04d.png", f + 1)))
        }
    }

    /// スプライトシート(1 枚 PNG に格子配置)+ メタ JSON。Unity/Unreal でスライス可能。
    public func exportSpriteSheet(to url: URL, columns: Int? = nil) throws {
        let frames = try renderAllFrames()
        guard !frames.isEmpty else { return }
        let cols = max(1, columns ?? Int(ceil(Double(frames.count).squareRoot())))
        let rows = Int(ceil(Double(frames.count) / Double(cols)))
        let fw = gridWidth, fh = gridHeight
        guard let ctx = CGContext(
            data: nil, width: cols * fw, height: rows * fh, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw EngineError.pipelineFailed("sheet ctx")
        }
        let sheetH = rows * fh
        for (i, img) in frames.enumerated() {
            let col = i % cols, row = i / cols
            // CGContext は左下原点。上から row 行目 → y = sheetH - (row+1)*fh
            ctx.draw(img, in: CGRect(x: col * fw, y: sheetH - (row + 1) * fh, width: fw, height: fh))
        }
        guard let sheet = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw EngineError.pipelineFailed("sheet image")
        }
        CGImageDestinationAddImage(dest, sheet, nil)
        guard CGImageDestinationFinalize(dest) else { throw EngineError.pipelineFailed("sheet finalize") }

        let meta = "{\"frameWidth\":\(fw),\"frameHeight\":\(fh)," +
                   "\"frameCount\":\(frames.count),\"columns\":\(cols),\"rows\":\(rows)}"
        try meta.data(using: .utf8)?.write(to: url.deletingPathExtension().appendingPathExtension("json"))
    }
}
