import AppKit

// M0 menubar app entry point (§4): global hotkey (KeyboardShortcuts), mic
// capture (AVAudioEngine), and the insertion strategy registry are wired in
// `AppDelegate`. This is a plain SwiftPM executable (no .app bundle/
// Info.plist yet — that lands with code signing in M3), so it runs as a
// regular process; `NSApp.setActivationPolicy(.accessory)` in the delegate
// keeps it out of the Dock while still running the AppKit run loop needed
// for the status item and global hotkey.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
