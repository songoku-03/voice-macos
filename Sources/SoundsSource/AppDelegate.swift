import AppKit
import SwiftUI
import UI
import Engine
import Core

@available(macOS 14.2, *)
@MainActor
public class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    // Eye-rest timer dependencies (7.1, 7.3)
    private var breakTimerManager: BreakTimerManager?
    private var inputBlocker: InputBlocker?
    private var overlayController: BreakOverlayController?
    
    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Redirect stdout and stderr to a file for persistent logging
        let logPath = "/Users/mac/Documents/GitHub/voice-macos/app.log"
        freopen(logPath, "a", stdout)
        freopen(logPath, "a", stderr)
        setbuf(stdout, nil)
        setbuf(stderr, nil)
        
        print("\n--- APP LAUNCHED (App Bundle) ---")
        
        // Create Popover
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 520)
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

        // 7.1: Initialise eye-rest timer subsystem
        let btm = BreakTimerManager.shared
        let blocker = InputBlocker()
        let overlayCtrl = BreakOverlayController(manager: btm)

        btm.inputBlocker = blocker
        btm.overlayController = overlayCtrl

        // 6.7: Status item update hook — set title during cycle, restore icon at idle
        btm.onStatusItemUpdate = { [weak self] title in
            guard let self, let button = self.statusItem?.button else { return }
            if let title, !title.isEmpty {
                button.image = nil
                button.title = title
            } else {
                button.title = ""
                button.image = NSImage(systemSymbolName: "waveform",
                                       accessibilityDescription: "SoundsSource")
            }
        }

        self.breakTimerManager = btm
        self.inputBlocker = blocker
        self.overlayController = overlayCtrl

        print("SoundsSource: AppDelegate initialized successfully.")
    }
    
    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }
        
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // 7.2: Graceful teardown — ensures tap removed, overlay hidden, audio restored
    public func applicationWillTerminate(_ notification: Notification) {
        let keys = Array(AudioEngineManager.shared.activeNodes.keys)
        for bundleID in keys {
            AudioEngineManager.shared.stopAppTapping(bundleID: bundleID)
        }
        // stopAppTapping snapshotted each node's EQ state; wait (bounded) for the
        // chained app-settings write so the last session's state lands on disk.
        AudioEngineManager.shared.flushAppSettingsBeforeTermination()
        AudioEngineManager.shared.teardown()
        breakTimerManager?.teardownOnTerminate()
    }
}
