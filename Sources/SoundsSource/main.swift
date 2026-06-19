import AppKit
import SwiftUI
import Foundation

@available(macOS 14.2, *)
@MainActor
func startApp() {
    // Disable stdout/stderr buffering for real-time console logging
    setbuf(stdout, nil)
    setbuf(stderr, nil)
    
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    
    // Hide dock icon, making it a menu-bar-only app programmatically just in case
    app.setActivationPolicy(.accessory)
    
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
}

if #available(macOS 14.2, *) {
    startApp()
} else {
    print("SoundsSource requires macOS 14.2 or newer.")
}
