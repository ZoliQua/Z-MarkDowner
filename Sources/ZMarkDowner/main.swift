import AppKit

let app = NSApplication.shared
// The first document controller instance becomes the shared one
_ = DocumentController()
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
