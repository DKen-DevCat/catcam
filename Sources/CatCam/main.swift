import AppKit

let options = Options.parse(CommandLine.arguments)
if options.doctor {
    Doctor.run()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate(options: options)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
