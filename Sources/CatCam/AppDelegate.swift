import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: Options
    private let pipeline = Pipeline()
    private var camera: CameraSource?
    private var overlay: OverlayWindow?
    private var panel: ControlPanel?

    init(options: Options) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        do {
            guard let device = MTLCreateSystemDefaultDevice(), let screen = NSScreen.main else {
                throw NSError(domain: "catcam", code: 3, userInfo: [NSLocalizedDescriptionKey: "Metal or screen unavailable"])
            }
            let pipeline = pipeline
            let camera = try CameraSource(
                nameHint: options.cameraName, queue: pipeline.queue,
                onFrame: { pipeline.process($0) }, onFaces: { pipeline.receiveSystemFaces($0) }
            )
            pipeline.useSystemFaces = camera.providesFaces && !options.visionFaces
            pipeline.compareFaces = options.compareFaces
            pipeline.faceEnabled = !options.noFace
            pipeline.personEnabled = !options.noPerson
            let overlay = try OverlayWindow(screen: screen, device: device, source: pipeline, mirror: options.mirror)
            overlay.orderFrontRegardless()
            overlay.renderer.backgroundMode = options.noPerson ? .original : .glass
            do {
                let cats = try CatAtlas(directory: options.catlib.map(URL.init(fileURLWithPath:)) ?? CatAtlas.defaultDirectory,
                                        device: device)
                overlay.renderer.cats = cats
                pipeline.setCatMatcher(cats.matcher)
                print("cats: \(cats.index.entries.count)")
            } catch {
                print("cats: unavailable (\(error.localizedDescription)). catlib-builder で catlib/ を作ると猫に差し替わる")
            }
            let panel = ControlPanel(pipeline: pipeline, renderer: overlay.renderer, cameraName: camera.deviceName)
            panel.makeKeyAndOrderFront(nil)
            panel.startUpdating(log: true)
            print("camera: \(camera.deviceName)  faces: \(pipeline.useSystemFaces ? "system" : "vision")  video effects: \(Doctor.videoEffectsSummary())")
            self.camera = camera
            self.overlay = overlay
            self.panel = panel

            AVCaptureDevice.requestAccess(for: .video) { granted in
                guard granted else {
                    print("camera access denied")
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async { camera.start() }
            }
        } catch {
            print("startup failed:", error.localizedDescription)
            NSApp.terminate(nil)
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { NSApp.terminate(nil) }  // esc
            return event
        }
        if let s = options.seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { NSApp.terminate(nil) }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        camera?.stop()
    }

    private func buildMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit catcam", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let item = NSMenuItem()
        item.submenu = appMenu
        let main = NSMenu()
        main.addItem(item)
        NSApp.mainMenu = main
    }
}
