import Foundation
import simd

/// 制御点列からなめらかなストローク点列を作るユーティリティ。
/// MCP のように「少数の制御点で形を指定する」呼び出し元のためのもので、
/// ライブ入力(マウス/タブレット)は通さない(そちらは StrokeStabilizer が担当)。
public enum StrokePath {

    /// 制御点列を Catmull-Rom スプラインで約 spacing 間隔の点列に補間する。
    /// 筆圧は制御点間で線形補間。点が 2 個なら直線補間、1 個以下はそのまま返す。
    ///
    /// uniform パラメータ化なので制御点間隔が極端に不揃いだと膨らみが出ることがあるが、
    /// 描画用途では許容範囲(必要になったら centripetal 化を検討)。
    public static func interpolate(_ points: [InputSample], spacing: Float) -> [InputSample] {
        guard points.count > 1 else { return points }
        let step = max(spacing, 0.5)
        let n = points.count
        var result: [InputSample] = []
        result.reserveCapacity(n * 8)
        for i in 0..<(n - 1) {
            // 端は制御点を複製してスプラインを端点まで通す
            let p0 = points[max(i - 1, 0)].position
            let p1 = points[i].position
            let p2 = points[i + 1].position
            let p3 = points[min(i + 2, n - 1)].position
            let chord = simd_length(p2 - p1)
            let steps = max(Int((chord / step).rounded(.up)), 1)
            for k in 0..<steps {
                let t = Float(k) / Float(steps)
                result.append(InputSample(
                    position: catmullRom(p0, p1, p2, p3, t),
                    pressure: points[i].pressure + (points[i + 1].pressure - points[i].pressure) * t
                ))
            }
        }
        result.append(points[n - 1])
        return result
    }

    private static func catmullRom(
        _ p0: SIMD2<Float>, _ p1: SIMD2<Float>,
        _ p2: SIMD2<Float>, _ p3: SIMD2<Float>, _ t: Float
    ) -> SIMD2<Float> {
        let t2: Float = t * t
        let t3: Float = t2 * t
        let a: SIMD2<Float> = p1 * Float(2)
        let b: SIMD2<Float> = (p2 - p0) * t
        var c: SIMD2<Float> = p0 * Float(2) - p1 * Float(5)
        c += p2 * Float(4) - p3
        c *= t2
        var d: SIMD2<Float> = p1 * Float(3) - p0
        d += p3 - p2 * Float(3)
        d *= t3
        return (a + b + c + d) * Float(0.5)
    }
}
