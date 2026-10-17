import AppKit
import AVFoundation

/// 計測値の表示と最小限の調整。M5 で SwiftUI のパネルに置き換える
final class ControlPanel: NSPanel {
    private let pipeline: Pipeline
    private let renderer: Renderer
    private let statsLabel = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?

    init(pipeline: Pipeline, renderer: Renderer, cameraName: String) {
        self.pipeline = pipeline
        self.renderer = renderer
        super.init(contentRect: NSRect(x: 40, y: 120, width: 300, height: 300),
                   styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
        title = "catcam — \(cameraName)"
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        hidesOnDeactivate = false

        statsLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        let sensitivity = NSSlider(value: 0.7, minValue: 0.05, maxValue: 0.98, target: self, action: #selector(sensitivityChanged(_:)))
        let minSize = NSSlider(value: 20, minValue: 4, maxValue: 400, target: self, action: #selector(minSizeChanged(_:)))
        let mirror = NSButton(checkboxWithTitle: "Mirror", target: self, action: #selector(mirrorChanged(_:)))
        mirror.state = renderer.mirror ? .on : .off
        let person = NSButton(checkboxWithTitle: "Person only（背景を消す）", target: self, action: #selector(personChanged(_:)))
        person.state = pipeline.personEnabled ? .on : .off
        // リアクション等のビデオエフェクトはプロセス内で重い検出を走らせるので、ここから切れるようにする
        let effects = NSButton(title: "Video Effects…（リアクションを切る）", target: self, action: #selector(showVideoEffects))
        let quit = NSButton(title: "Quit (esc)", target: NSApp, action: #selector(NSApplication.terminate(_:)))

        let stack = NSStackView(views: [
            statsLabel,
            NSTextField(labelWithString: "Sensitivity"), sensitivity,
            NSTextField(labelWithString: "Minimum size"), minSize,
            mirror, person, effects, quit,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        for v in [statsLabel, sensitivity, minSize] {
            v.widthAnchor.constraint(equalToConstant: 276).isActive = true
        }
        contentView = stack
    }

    func startUpdating(log: Bool) {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let line = pipeline.stats.roll()
            statsLabel.stringValue = line.replacingOccurrences(of: "  ", with: "\n")
            if log { print(line) }
        }
    }

    @objc private func sensitivityChanged(_ s: NSSlider) {
        let v = s.doubleValue
        pipeline.updateMotionConfig { $0.sensitivity = v }
    }

    @objc private func minSizeChanged(_ s: NSSlider) {
        let v = Int(s.doubleValue)
        pipeline.updateMotionConfig { $0.minArea = v }
    }

    @objc private func mirrorChanged(_ b: NSButton) {
        renderer.mirror = b.state == .on
    }

    @objc private func personChanged(_ b: NSButton) {
        pipeline.setPersonEnabled(b.state == .on)
    }

    @objc private func showVideoEffects() {
        AVCaptureDevice.showSystemUserInterface(.videoEffects)
    }
}
