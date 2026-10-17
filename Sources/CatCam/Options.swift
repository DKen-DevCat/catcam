struct Options {
    var doctor = false
    /// カメラ名の部分一致（例: "iPhone"）
    var cameraName: String?
    /// 指定秒数で自動終了（計測用）
    var seconds: Double?
    var mirror = true
    /// システムの顔検出が使えても自前の Vision を使う
    var visionFaces = false
    /// 両方の顔検出結果をログに出す
    var compareFaces = false
    /// 顔検出を止める（計測用）
    var noFace = false
    /// 人物セグメンテーションを止め、背景も含めて出す
    var noPerson = false

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--doctor": o.doctor = true
            case "--camera": o.cameraName = it.next()
            case "--seconds": o.seconds = it.next().flatMap(Double.init)
            case "--no-mirror": o.mirror = false
            case "--vision-faces": o.visionFaces = true
            case "--compare-faces": o.compareFaces = true
            case "--no-face": o.noFace = true
            case "--no-person": o.noPerson = true
            default: print("unknown option: \(a)")
            }
        }
        return o
    }
}
