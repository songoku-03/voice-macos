import AppKit
import SwiftUI
import UI
import Engine

@available(macOS 14.2, *)
@MainActor
public class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    
    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Create Popover
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 440)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverContentView())
        self.popover = popover
        
        // Create Status Item in Menu Bar
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "SoundsSource")
            button.action = #selector(togglePopover)
            button.target = self
        }
        self.statusItem = statusItem
        
        // Initialize AudioEngineManager
        _ = AudioEngineManager.shared
        print("SoundsSource: AppDelegate initialized successfully.")
    }
    
    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }
        
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
