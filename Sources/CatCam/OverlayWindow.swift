import AppKit
import MetalKit

/// 画面全体を覆う透明・クリック素通しのウィンドウ。偽ウィンドウはすべてここに描く
final class OverlayWindow: NSWindow {
    let renderer: Renderer

    init(screen: NSScreen, device: MTLDevice, source: Pipeline, mirror: Bool) throws {
        let view = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.preferredFramesPerSecond = 30
        view.layer?.isOpaque = false
        renderer = try Renderer(view: view, source: source, mirror: mirror)
        view.delegate = renderer

        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = view
        setFrame(screen.frame, display: false)
    }
}
