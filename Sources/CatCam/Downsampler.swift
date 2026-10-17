import CatCore
import CoreVideo

/// BGRA のカメラフレームを検出用の小さなグレースケール画像にする。
/// 各出力画素のマス内 4 点だけを読んで平均する（vImageScale はこの用途には重すぎた: CPU 約 19%）
final class Downsampler {
    let width: Int
    let height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    func gray(_ pb: CVPixelBuffer) -> GrayImage {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

        var out = GrayImage(width: width, height: height)
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return out }
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        let cellW = CVPixelBufferGetWidth(pb) / width, cellH = CVPixelBufferGetHeight(pb) / height
        let qx = cellW / 4, qy = cellH / 4

        // BGRA の並び。ITU-R BT.601 の近似係数（合計 256）
        @inline(__always) func luma(_ p: UnsafePointer<UInt8>) -> UInt32 {
            let b = UInt32(p[0]), g = UInt32(p[1]), r = UInt32(p[2])
            return r * 77 + g * 150 + b * 29
        }

        for oy in 0..<height {
            let row0 = base + (oy * cellH + qy) * rowBytes
            let row1 = base + (oy * cellH + 3 * qy) * rowBytes
            for ox in 0..<width {
                let x0 = (ox * cellW + qx) * 4, x1 = (ox * cellW + 3 * qx) * 4
                let sum = luma(row0 + x0) + luma(row0 + x1) + luma(row1 + x0) + luma(row1 + x1)
                out.pixels[oy * width + ox] = UInt8(sum >> 10)
            }
        }
        return out
    }
}
