import Foundation
import CoreGraphics
import CoreText

/// スナップショットへの座標グリッド焼き込み。
/// MCP エージェントが「どこに描けたか」を目視でなく座標で確認するための計器
/// (AppKit 非依存: CoreGraphics + CoreText のみ)。
enum SnapshotGrid {

    /// image にグリッド線とラベルを焼き込んだ CGImage を返す。
    /// - spacingPt: グリッド間隔(キャンバス座標 pt)
    /// - scale: image がキャンバス等倍から縮小されている場合の倍率(線の位置に乗算)
    /// - canvasSize: 元のキャンバス寸法(ラベルはこの座標系の値で振る)
    static func draw(
        on image: CGImage, spacingPt: Int, scale: CGFloat, canvasSize: (width: Int, height: Int)
    ) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let lineColor = CGColor(srgbRed: 0.20, green: 0.35, blue: 0.85, alpha: 0.30)
        let labelColor = CGColor(srgbRed: 0.15, green: 0.25, blue: 0.70, alpha: 0.85)
        let font = CTFontCreateWithName("Menlo" as CFString, 9, nil)

        func drawLabel(_ text: String, x: CGFloat, y: CGFloat) {
            // y はキャンバス座標(y 下向き)。CGContext は y 上向きなので反転する
            let attr = NSAttributedString(string: text, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: labelColor,
            ])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: x, y: CGFloat(h) - y)
            CTLineDraw(line, ctx)
        }

        ctx.setStrokeColor(lineColor)
        ctx.setLineWidth(1)

        // 縦線 + x ラベル(上端)
        var x = spacingPt
        while x < canvasSize.width {
            let px = (CGFloat(x) * scale).rounded()
            ctx.move(to: CGPoint(x: px, y: 0))
            ctx.addLine(to: CGPoint(x: px, y: CGFloat(h)))
            ctx.strokePath()
            drawLabel("\(x)", x: px + 2, y: 11)
            x += spacingPt
        }
        // 横線 + y ラベル(左端)
        var y = spacingPt
        while y < canvasSize.height {
            let py = (CGFloat(y) * scale).rounded()
            ctx.move(to: CGPoint(x: 0, y: CGFloat(h) - py))
            ctx.addLine(to: CGPoint(x: CGFloat(w), y: CGFloat(h) - py))
            ctx.strokePath()
            drawLabel("\(y)", x: 2, y: py - 2)
            y += spacingPt
        }
        return ctx.makeImage()
    }
}
