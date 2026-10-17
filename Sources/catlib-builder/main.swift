import CatCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Oxford-IIIT Pet の猫画像と trimap から、形マッチング用の猫ライブラリを作る。
//   swift run -c release catlib-builder [--data data/oxford-pets] [--out catlib] [--max 1024]
// 出力: <out>/shape_atlas.png（128px のマスに切り抜きを詰めたもの）と <out>/index.json

struct Options {
    var data = "data/oxford-pets"
    var out = "catlib"
    var max = 1024
    let cell = 128
    let atlas = 4096

    init(_ args: [String]) {
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--data": data = it.next() ?? data
            case "--out": out = it.next() ?? out
            case "--max": max = it.next().flatMap(Int.init) ?? max
            default: fatalError("unknown option: \(a)")
            }
        }
    }
}

/// trimap の値: 1 = 前景、2 = 背景、3 = 境界
struct Candidate {
    let name: String
    let width: Int
    let height: Int
    let trimap: [UInt8]
    let box: Component
    let shape: ShapeDescriptor
}

enum Reject: String, CaseIterable, Error {
    case unreadable, sizeMismatch, tooSmall, truncated
}

func loadImage(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

/// 8bit グレーとして画素値をそのまま読む（trimap は 1/2/3 の値がそのまま入っている）
func grayBytes(_ img: CGImage) -> [UInt8]? {
    var bytes = [UInt8](repeating: 0, count: img.width * img.height)
    let ok = bytes.withUnsafeMutableBytes { buf -> Bool in
        guard let ctx = CGContext(data: buf.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8,
                                  bytesPerRow: img.width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return true
    }
    return ok ? bytes : nil
}

func makeCandidate(name: String, dataDir: URL) -> Result<Candidate, Reject> {
    let imageURL = dataDir.appendingPathComponent("images/\(name).jpg")
    let trimapURL = dataDir.appendingPathComponent("annotations/trimaps/\(name).png")
    guard let image = loadImage(imageURL), let trimapImage = loadImage(trimapURL),
          let trimap = grayBytes(trimapImage) else { return .failure(.unreadable) }
    guard image.width == trimapImage.width, image.height == trimapImage.height else { return .failure(.sizeMismatch) }

    let w = image.width, h = image.height
    var mask = BinaryMask(width: w, height: h)
    var box = Component(minX: w, minY: h, maxX: -1, maxY: -1, area: 0)
    var edge = 0
    for y in 0..<h {
        for x in 0..<w where trimap[y * w + x] == 1 {
            mask[x, y] = true
            box.minX = min(box.minX, x)
            box.maxX = max(box.maxX, x)
            box.minY = min(box.minY, y)
            box.maxY = max(box.maxY, y)
            box.area += 1
            if x == 0 || y == 0 || x == w - 1 || y == h - 1 { edge += 1 }
        }
    }
    guard Double(box.area) >= 0.05 * Double(w * h) else { return .failure(.tooSmall) }
    // 画像の端で大きく切れている猫は形が不完全なので使わない
    guard Double(edge) <= 0.1 * Double(2 * (w + h)) else { return .failure(.truncated) }
    return .success(Candidate(name: name, width: w, height: h, trimap: trimap, box: box,
                              shape: ShapeDescriptor(mask: mask, box: box)))
}

/// 縦横比の対数で 12 区間に分け、区間を順番に回って選ぶ（丸まった猫ばかりにならないように）
func selectDiverse(_ cs: [Candidate], max: Int) -> [Candidate] {
    guard cs.count > max else { return cs }
    let bins = 12
    var buckets = [[Candidate]](repeating: [], count: bins)
    for c in cs {
        let t = (log2(c.shape.aspect) + 2) / 4
        buckets[Swift.max(0, Swift.min(bins - 1, Int(t * Double(bins))))].append(c)
    }
    var out: [Candidate] = []
    var round = 0
    while out.count < max {
        var added = false
        for b in buckets where round < b.count && out.count < max {
            out.append(b[round])
            added = true
        }
        if !added { break }
        round += 1
    }
    return out
}

func maskImage(_ c: Candidate, crop: (x: Int, y: Int, w: Int, h: Int)) -> CGImage? {
    var bytes = [UInt8](repeating: 0, count: crop.w * crop.h)
    for y in 0..<crop.h {
        for x in 0..<crop.w {
            switch c.trimap[(crop.y + y) * c.width + crop.x + x] {
            case 1: bytes[y * crop.w + x] = 255
            case 3: bytes[y * crop.w + x] = 128
            default: break
            }
        }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(width: crop.w, height: crop.h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: crop.w,
                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

func writePNG(_ img: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}

let opt = Options(CommandLine.arguments)
let dataDir = URL(fileURLWithPath: opt.data)
let outDir = URL(fileURLWithPath: opt.out)
let list = try String(contentsOf: dataDir.appendingPathComponent("annotations/list.txt"), encoding: .utf8)
// 書式: <名前> <CLASS-ID> <SPECIES 1=猫 2=犬> <BREED ID>
let catNames = list.split(separator: "\n").compactMap { line -> String? in
    let f = line.split(separator: " ")
    return !line.hasPrefix("#") && f.count >= 3 && f[2] == "1" ? String(f[0]) : nil
}

var candidates: [Candidate] = []
var rejects: [Reject: Int] = [:]
for name in catNames {
    switch makeCandidate(name: name, dataDir: dataDir) {
    case .success(let c): candidates.append(c)
    case .failure(let r): rejects[r, default: 0] += 1
    }
}
let capacity = (opt.atlas / opt.cell) * (opt.atlas / opt.cell)
let selected = selectDiverse(candidates, max: min(opt.max, capacity))

guard let atlas = CGContext(data: nil, width: opt.atlas, height: opt.atlas, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("atlas context") }
atlas.interpolationQuality = .high
let cols = opt.atlas / opt.cell
let atlasSize = Double(opt.atlas)
var entries: [CatLibraryIndex.Entry] = []
for (i, c) in selected.enumerated() {
    guard let image = loadImage(dataDir.appendingPathComponent("images/\(c.name).jpg")) else { continue }
    // 前景の箱を 2px 広げて切り出す（境界の半透明部分を含めるため）
    let x0 = max(0, c.box.minX - 2), y0 = max(0, c.box.minY - 2)
    let x1 = min(c.width - 1, c.box.maxX + 2), y1 = min(c.height - 1, c.box.maxY + 2)
    let crop = (x: x0, y: y0, w: x1 - x0 + 1, h: y1 - y0 + 1)
    guard let cropped = image.cropping(to: CGRect(x: crop.x, y: crop.y, width: crop.w, height: crop.h)),
          let mask = maskImage(c, crop: crop) else { continue }

    let scale = Double(opt.cell - 4) / Double(max(crop.w, crop.h))
    let dw = Double(crop.w) * scale, dh = Double(crop.h) * scale
    let dx = Double((i % cols) * opt.cell) + (Double(opt.cell) - dw) / 2
    let dyTop = Double((i / cols) * opt.cell) + (Double(opt.cell) - dh) / 2
    // CoreGraphics は左下原点
    let dest = CGRect(x: dx, y: atlasSize - dyTop - dh, width: dw, height: dh)
    atlas.saveGState()
    atlas.clip(to: dest, mask: mask)
    atlas.draw(cropped, in: dest)
    atlas.restoreGState()
    entries.append(.init(name: c.name, uv: Rect(x: dx / atlasSize, y: dyTop / atlasSize, w: dw / atlasSize, h: dh / atlasSize),
                         shape: c.shape))
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
guard let atlasImage = atlas.makeImage() else { fatalError("atlas image") }
try writePNG(atlasImage, to: outDir.appendingPathComponent("shape_atlas.png"))
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
try encoder.encode(CatLibraryIndex(atlasSize: opt.atlas, cellSize: opt.cell, entries: entries))
    .write(to: outDir.appendingPathComponent("index.json"))

print("cats: \(catNames.count)  usable: \(candidates.count)  selected: \(entries.count)")
print("rejected:", Reject.allCases.map { "\($0.rawValue)=\(rejects[$0, default: 0])" }.joined(separator: " "))
// 縦横比の分布（横長ほど右）。細長い形の不足を確認するため
let edges = [0.0, 0.5, 0.75, 1.0, 1.33, 2.0, .infinity]
for (lo, hi) in zip(edges, edges.dropFirst()) {
    let n = entries.filter { $0.shape.aspect >= lo && $0.shape.aspect < hi }.count
    print(String(format: "aspect [%.2f, %.2f): %4d %@", lo, hi, n, String(repeating: "#", count: n / 10)))
}
