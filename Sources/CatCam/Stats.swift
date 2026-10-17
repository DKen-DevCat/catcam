import Darwin
import Foundation
import QuartzCore

/// fps・処理時間・CPU 使用率の集計。`roll()` を定期的に呼ぶと区間の値を確定する
final class Stats {
    private let lock = NSLock()
    private var camFrames = 0
    private var renderFrames = 0
    private var frameMsSum = 0.0
    private var frameMsMax = 0.0
    private var faceMsSum = 0.0
    private var faceRuns = 0
    private var blobs = 0
    private var tracks = 0
    private var start = CACurrentMediaTime()
    private var cpuStart = Stats.cpuSeconds()

    func recordFrame(ms: Double, blobs: Int, tracks: Int) {
        lock.lock()
        camFrames += 1
        frameMsSum += ms
        frameMsMax = max(frameMsMax, ms)
        self.blobs = blobs
        self.tracks = tracks
        lock.unlock()
    }

    func recordFace(ms: Double) {
        lock.lock()
        faceMsSum += ms
        faceRuns += 1
        lock.unlock()
    }

    func recordRender() {
        lock.lock()
        renderFrames += 1
        lock.unlock()
    }

    func roll() -> String {
        lock.lock()
        defer { lock.unlock() }
        let now = CACurrentMediaTime(), cpu = Stats.cpuSeconds()
        let dt = max(now - start, 1e-6)
        let line = String(
            format: "cam %.1ffps  render %.1ffps  detect %.2fms (max %.2f)  face %.1fms@%.1fHz  blobs %d  tracks %d  cpu %.1f%%",
            Double(camFrames) / dt, Double(renderFrames) / dt,
            camFrames > 0 ? frameMsSum / Double(camFrames) : 0, frameMsMax,
            faceRuns > 0 ? faceMsSum / Double(faceRuns) : 0, Double(faceRuns) / dt,
            blobs, tracks, (cpu - cpuStart) / dt * 100
        )
        camFrames = 0
        renderFrames = 0
        frameMsSum = 0
        frameMsMax = 0
        faceMsSum = 0
        faceRuns = 0
        start = now
        cpuStart = cpu
        return line
    }

    private static func cpuSeconds() -> Double {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(ru.ru_utime) + s(ru.ru_stime)
    }
}
