import AppKit
import AVFoundation

/// 計測値の表示と最小限の調整。M5 で SwiftUI のパネルに置き換える
final class ControlPanel: NSPanel {
    private let pipeline: Pipeline
    private let renderer: Renderer
    private let statsLabel = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?
    private var styleButton: NSPopUpButton?

    init(pipeline: Pipeline, renderer: Renderer, cameraName: String) {
        self.pipeline = pipeline
        self.renderer = renderer
        super.init(contentRect: NSRect(x: 40, y: 120, width: 300, height: 500),
                   styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
        title = "catcam — \(cameraName)"
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        hidesOnDeactivate = false

        statsLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        let sensitivity = NSSlider(value: 0.7, minValue: 0.05, maxValue: 0.98, target: self, action: #selector(sensitivityChanged(_:)))
        let minSize = NSSlider(value: 20, minValue: 4, maxValue: 400, target: self, action: #selector(minSizeChanged(_:)))
        let maxWindow = NSSlider(value: 0.25, minValue: 0.08, maxValue: 0.8, target: self, action: #selector(maxWindowChanged(_:)))
        let display = NSPopUpButton(frame: .zero, pullsDown: false)
        display.addItems(withTitles: DisplayMode.allCases.map(\.label))
        display.selectItem(at: (renderer.avatarOn ? DisplayMode.avatar : renderer.catStyle != nil ? .filter : .human).rawValue)
        display.item(at: DisplayMode.photo.rawValue)?.isEnabled = renderer.cats != nil
        display.item(at: DisplayMode.avatar.rawValue)?.isEnabled = renderer.avatar != nil
        display.autoenablesItems = false
        display.target = self
        display.action = #selector(displayChanged(_:))
        let style = NSPopUpButton(frame: .zero, pullsDown: false)
        style.addItems(withTitles: CatStyle.presets.map(\.name))
        style.target = self
        style.action = #selector(styleChanged(_:))
        styleButton = style
        let fullFrame = NSButton(checkboxWithTitle: "全画面（窓を出さない）", target: self, action: #selector(fullFrameChanged(_:)))
        fullFrame.state = renderer.fullFrame ? .on : .off
        let mirror = NSButton(checkboxWithTitle: "Mirror", target: self, action: #selector(mirrorChanged(_:)))
        mirror.state = renderer.mirror ? .on : .off
        let background = NSPopUpButton(frame: .zero, pullsDown: false)
        background.addItems(withTitles: BackgroundMode.allCases.map(\.label))
        background.selectItem(at: renderer.backgroundMode.rawValue)
        background.target = self
        background.action = #selector(backgroundChanged(_:))
        // リアクション・背景などのビデオエフェクトはプロセス内で重い処理を走らせるので、ここから切れるようにする
        let effects = NSButton(title: "Video Effects…（macOS のリアクション・背景を切る）", target: self, action: #selector(showVideoEffects))
        let quit = NSButton(title: "Quit (esc)", target: NSApp, action: #selector(NSApplication.terminate(_:)))

        let stack = NSStackView(views: [
            statsLabel,
            NSTextField(labelWithString: "Sensitivity"), sensitivity,
            NSTextField(labelWithString: "Minimum size"), minSize,
            NSTextField(labelWithString: "Max window size（超えたら分割）"), maxWindow,
            NSTextField(labelWithString: "表示"), display,
            NSTextField(labelWithString: "猫の種類"), style,
            NSTextField(labelWithString: "背景"), background,
            fullFrame, mirror, effects, quit,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        for v in [statsLabel, sensitivity, minSize, maxWindow, display, style, background] {
            v.widthAnchor.constraint(equalToConstant: 276).isActive = true
        }
        contentView = stack
    }

    func startUpdating(log: Bool) {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let line = pipeline.stats.roll()
            statsLabel.stringValue = line.replacingOccurrences(of: "  ", with: "\n")
            if log { print(line + "  fx[\(Doctor.videoEffectsSummary())]") }
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

    @objc private func maxWindowChanged(_ s: NSSlider) {
        pipeline.setMaxWindow(s.doubleValue)
    }

    @objc private func displayChanged(_ p: NSPopUpButton) {
        guard let mode = DisplayMode(rawValue: p.indexOfSelectedItem) else { return }
        let styleIndex = styleButton?.indexOfSelectedItem ?? 0
        renderer.catStyle = mode == .filter ? CatStyle.presets[max(styleIndex, 0)] : nil
        renderer.avatarOn = mode == .avatar
        pipeline.setAvatarPoser(mode == .avatar ? renderer.avatar?.model.makePoser() : nil)
        pipeline.setCatsEnabled(mode == .photo)
        updatePersonEnabled()
    }

    @objc private func styleChanged(_ p: NSPopUpButton) {
        guard renderer.catStyle != nil, CatStyle.presets.indices.contains(p.indexOfSelectedItem) else { return }
        renderer.catStyle = CatStyle.presets[p.indexOfSelectedItem]
    }

    @objc private func fullFrameChanged(_ b: NSButton) {
        renderer.fullFrame = b.state == .on
    }

    private func updatePersonEnabled() {
        // 「そのまま」では人物切り抜きを止めて軽くする。ただし猫フィルタは人物の形が要る
        pipeline.setPersonEnabled(renderer.backgroundMode.needsPersonMask || renderer.catStyle != nil)
    }

    @objc private func mirrorChanged(_ b: NSButton) {
        renderer.mirror = b.state == .on
    }

    @objc private func backgroundChanged(_ p: NSPopUpButton) {
        guard let mode = BackgroundMode(rawValue: p.indexOfSelectedItem) else { return }
        renderer.backgroundMode = mode
        updatePersonEnabled()
    }

    @objc private func showVideoEffects() {
        AVCaptureDevice.showSystemUserInterface(.videoEffects)
    }
}

/// 人物の部分に何を出すか
enum DisplayMode: Int, CaseIterable {
    case avatar, filter, photo, human

    var label: String {
        switch self {
        case .avatar: "毒チワワ（3D アバター）"
        case .filter: "猫フィルタ（人を猫にする）"
        case .photo: "形の似た猫の写真（M3）"
        case .human: "人のまま"
        }
    }
}
