import Foundation
import CoreGraphics
import AppKit

// MARK: - Protocols (defined in Core so Engine can import them)

@available(macOS 14.2, *)
public protocol InputBlockerProtocol: AnyObject {
    func install()
    func uninstall()
}

@available(macOS 14.2, *)
public protocol BreakOverlayControllerProtocol: AnyObject {
    @MainActor func showOverlays()
    @MainActor func hideOverlays()
}

// MARK: - Event classification (2.1)
// Pure function — no alloc, no locks, no @MainActor. Testable in isolation.

/// Determines whether a keyboard event should be suppressed during a break.
/// Returns `true` if the event should be swallowed.
///
/// Suppressed: system escape shortcuts that could let the user leave the break
///   • Cmd-Tab / Cmd-Shift-Tab  (app switcher)
///   • Mission Control key (F3 / kVK_F3 on some keyboards, or via modifier)
///   • Cmd-Q, Cmd-W, Cmd-H, Cmd-` (quit / close / hide / next-window)
///   • Escape — prevents bare Escape from invoking some system dialogs
///
/// NOT suppressed: mouse events (overlay relies on mouse for the Skip button).
func shouldSuppressEvent(keycode: CGKeyCode, flags: CGEventFlags) -> Bool {
    let cmd = flags.contains(.maskCommand)
    let shift = flags.contains(.maskShift)
    _ = flags.contains(.maskControl)

    // Cmd-Tab / Cmd-Shift-Tab — app switcher
    if cmd && keycode == 48 { return true }            // kVK_Tab = 48

    // Mission Control (kVK_F3 = 99 on Apple keyboard layout)
    if keycode == 99 { return true }

    // Cmd-Q — quit frontmost app
    if cmd && keycode == 12 { return true }            // kVK_ANSI_Q = 12

    // Cmd-W — close window
    if cmd && keycode == 13 { return true }            // kVK_ANSI_W = 13

    // Cmd-H — hide
    if cmd && keycode == 4 { return true }             // kVK_ANSI_H = 4

    // Cmd-` — next window in same app (backtick)
    if cmd && !shift && keycode == 50 { return true }  // kVK_ANSI_Grave = 50

    // Cmd-M — minimise
    if cmd && keycode == 46 { return true }            // kVK_ANSI_M = 46

    // Escape key — bare Escape
    if keycode == 53 { return true }                   // kVK_Escape = 53

    return false
}

// MARK: - InputBlocker (2.2–2.6)

/// Wraps a `CGEventTap` that suppresses system escape shortcuts during a break.
///
/// - **Thread safety**: `@unchecked Sendable`; the callback is `nonisolated` and
///   never touches `@MainActor` state — it only reads `nonisolated(unsafe)` flags.
/// - **Install/uninstall** are idempotent and safe to call from the main actor.
@available(macOS 14.2, *)
public final class InputBlocker: @unchecked Sendable {

    // MARK: - nonisolated(unsafe) state read by the C callback

    private let lock: UnsafeMutablePointer<os_unfair_lock_s>
    private var _isActive: Bool = false

    /// When `true`, the callback suppresses matched key events.
    nonisolated private var isActive: Bool {
        get {
            os_unfair_lock_lock(lock)
            defer { os_unfair_lock_unlock(lock) }
            return _isActive
        }
        set {
            os_unfair_lock_lock(lock)
            defer { os_unfair_lock_unlock(lock) }
            _isActive = newValue
        }
    }

    // MARK: - Private

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var installed = false

    // Watchdog timer independent of the state machine (2.6).
    private var watchdogTimer: DispatchSourceTimer?

    public init() {
        self.lock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock_s())
    }

    deinit {
        uninstall()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    // MARK: - Public API

    /// Install the event tap. Idempotent.
    public func install() {
        guard !installed else { return }

        // We tap keyboard events only (2.3: NEVER suppress mouse).
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)   |
            (1 << CGEventType.flagsChanged.rawValue) |
            // Also intercept "null" events used to signal tap-disabled.
            (1 << CGEventType.tapDisabledByTimeout.rawValue) |
            (1 << CGEventType.tapDisabledByUserInput.rawValue)

        // Pass `self` as refcon via Unmanaged so the C callback can reach us
        // without any allocation or locking (2.2).
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: inputBlockerCallback,
            userInfo: refcon
        ) else {
            print("InputBlocker: Failed to create CGEventTap — Accessibility permission missing?")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)

        tap = newTap
        runLoopSource = source
        isActive = true
        installed = true
        print("InputBlocker: Event tap installed.")

        // Start independent watchdog to automatically uninstall the tap after max duration (300s)
        // to protect the user from being locked out of their system in case of app crashes/hangs.
        startWatchdog(maxDuration: 300)
    }

    /// Uninstall the event tap. Idempotent.
    public func uninstall() {
        guard installed else { return }
        isActive = false

        if let t = tap {
            CGEvent.tapEnable(tap: t, enable: false)
            if let src = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            }
        }
        tap = nil
        runLoopSource = nil
        installed = false
        cancelWatchdog()
        print("InputBlocker: Event tap uninstalled.")
    }

    // MARK: - Re-enable on timeout (2.4)

    /// Called from the C callback when the OS disables the tap.
    nonisolated func handleTapDisabled() {
        guard let t = tap else { return }
        CGEvent.tapEnable(tap: t, enable: true)
        print("InputBlocker: Tap re-enabled after OS disable.")
    }

    // MARK: - Classify (2.1 bridge)

    /// Called from the C callback; returns whether the event should be suppressed.
    nonisolated func classify(keycode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard isActive else { return false }
        return shouldSuppressEvent(keycode: keycode, flags: flags)
    }

    // MARK: - Watchdog (2.6)

    /// Start the independent watchdog. `maxDuration` should match `BreakTimerManager.maxLockDuration`.
    public func startWatchdog(maxDuration: TimeInterval) {
        cancelWatchdog()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + maxDuration, repeating: .never)
        t.setEventHandler { [weak self] in
            print("InputBlocker: Watchdog expired — force uninstalling tap.")
            self?.uninstall()
        }
        t.resume()
        watchdogTimer = t
    }

    private func cancelWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }
}

// MARK: - C callback (real-time safe: no alloc, no lock, no @MainActor)

private func inputBlockerCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    guard let refcon else { return Unmanaged.passRetained(event) }
    let blocker = Unmanaged<InputBlocker>.fromOpaque(refcon).takeUnretainedValue()

    // Handle tap-disabled events (2.4).
    if type == .tapDisabledByTimeout {
        blocker.handleTapDisabled()
        return Unmanaged.passRetained(event)
    } else if type == .tapDisabledByUserInput {
        print("InputBlocker: Event tap disabled due to user secure input (Secure Input). NOT re-enabling to respect system security.")
        return Unmanaged.passRetained(event)
    }

    // Only suppress keyDown / keyUp / flagsChanged (2.3: never suppress mouse).
    guard type == .keyDown || type == .keyUp || type == .flagsChanged else {
        return Unmanaged.passRetained(event)
    }

    let keycode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags

    if blocker.classify(keycode: keycode, flags: flags) {
        // Suppress: return nil drops the event.
        return nil
    }

    return Unmanaged.passRetained(event)
}

// MARK: - BreakTimerManager conformance

@available(macOS 14.2, *)
extension InputBlocker: InputBlockerProtocol {}
