import AppKit
import SwiftUI
import Engine
import Core

// MARK: - BreakOverlayWindow (4.1)

/// A borderless `NSPanel` that covers a single screen during a break.
///
/// Key decisions per spec:
/// - Level `.screenSaver` so it sits above fullscreen apps.
/// - `canJoinAllSpaces + fullScreenAuxiliary` collection behaviour.
/// - Override `canBecomeKey`/`canBecomeMain` → `true` so the Skip button gets
///   focus and click events even while the `CGEventTap` is active (hybrid model).
/// - `.nonactivatingPanel` prevents the panel from stealing app-activation focus
///   from the frontmost app on show, while still allowing clicks on its content.
@available(macOS 14.2, *)
final class BreakOverlayWindow: NSPanel {

    init(screen: NSScreen, manager: BreakTimerManager) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(0.85)
        ignoresMouseEvents = false  // must receive mouse to allow Skip click

        // 4.3: SwiftUI content — countdown centred + Skip button
        let hostingView = NSHostingView(
            rootView: BreakOverlayContentView()
                .environmentObject(BreakTimerManagerObservableWrapper(manager: manager))
        )
        hostingView.frame = contentRect(forFrameRect: frame)
        hostingView.autoresizingMask = [.width, .height]
        contentView = hostingView
    }

    // 4.1: Required — allows the Skip button to receive focus and clicks
    // even while the CGEventTap suppresses keyboard shortcuts.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - BreakOverlayContentView (4.3)

/// SwiftUI view displayed on each overlay window: centred countdown + Skip button.
@available(macOS 14.2, *)
struct BreakOverlayContentView: View {
    @EnvironmentObject private var wrapper: BreakTimerManagerObservableWrapper

    var body: some View {
        ZStack {
            // Dark translucent background (window itself is already 0.85 black)
            Color.clear

            VStack(spacing: 32) {
                // Eye-rest icon
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 60, weight: .thin))
                    .foregroundStyle(.white.opacity(0.7))

                // Countdown clock — reads from one shared source (4.2)
                Text(formattedRemaining)
                    .font(.system(size: 72, weight: .ultraLight, design: .monospaced))
                    .foregroundStyle(.white)
                    .monospacedDigit()

                Text("Nghỉ mắt đi nào 👀")
                    .font(.system(size: 20, weight: .light, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))

                // Skip button — must receive click even while tap is running (4.3)
                Button {
                    BreakTimerManager.shared.skip()
                } label: {
                    Text("Bỏ qua")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1.0)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: []) // Allow Escape to skip (not suppressed by tap)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
    }

    private var formattedRemaining: String {
        let t = max(0, Int(wrapper.remaining))
        let m = t / 60
        let s = t % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Observable wrapper for EnvironmentObject

/// Bridges `BreakTimerManager` (which uses `@Observable`, not `ObservableObject`)
/// into an `ObservableObject` suitable for `@EnvironmentObject` injection.
/// Marked `@MainActor` so it can read `@MainActor`-isolated `BreakTimerManager` properties.
@available(macOS 14.2, *)
@MainActor
final class BreakTimerManagerObservableWrapper: ObservableObject {
    @Published var remaining: TimeInterval = 0
    @Published var phase: BreakTimerManager.Phase = .idle

    private let manager: BreakTimerManager
    // nonisolated(unsafe) so deinit (which is nonisolated) can access it.
    nonisolated(unsafe) var timer: Timer?

    init(manager: BreakTimerManager) {
        self.manager = manager
        self.remaining = manager.remaining
        self.phase = manager.phase

        // Poll at 0.5s — lightweight and sufficient for a countdown display.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.remaining = manager.remaining
                self.phase = manager.phase
            }
        }
    }

    deinit { timer?.invalidate() }
}

// MARK: - BreakOverlayController (4.2, 4.4, 4.5)

/// Manages one `BreakOverlayWindow` per connected screen (4.2).
/// Handles hot-plug / screen reconfiguration atomically without resetting the timer (4.4).
/// `@MainActor` because all operations touch `NSWindow`/`NSScreen` AppKit APIs.
@available(macOS 14.2, *)
@MainActor
public final class BreakOverlayController {

    private weak var manager: BreakTimerManager?
    private var windows: [NSScreen: BreakOverlayWindow] = [:]
    private var isShowing = false

    public init(manager: BreakTimerManager) {
        self.manager = manager
        setupScreenChangeObserver()
    }

    // MARK: Public API (BreakOverlayControllerProtocol)

    public func showOverlays() {
        isShowing = true
        syncOverlaysToScreens()
        windows.values.forEach { w in
            w.orderFrontRegardless()
            w.makeKey()
        }
    }

    public func hideOverlays() {
        isShowing = false
        windows.values.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    // MARK: Screen reconfig (4.4)

    private func setupScreenChangeObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screensChanged() {
        guard isShowing else { return }
        // Atomic diff: add/remove windows without touching the timer (4.4).
        syncOverlaysToScreens()
    }

    /// Diffs the current screen list against existing windows, adds/removes without
    /// disrupting the countdown or resetting any timers.
    private func syncOverlaysToScreens() {
        guard let manager else { return }
        let currentScreens = Set(NSScreen.screens)

        // Remove windows for disconnected screens.
        for screen in windows.keys where !currentScreens.contains(screen) {
            windows[screen]?.orderOut(nil)
            windows.removeValue(forKey: screen)
        }

        // Add windows for new screens.
        for screen in currentScreens where windows[screen] == nil {
            let w = BreakOverlayWindow(screen: screen, manager: manager)
            windows[screen] = w
            if isShowing {
                w.orderFrontRegardless()
                w.makeKey()
            }
        }
    }
}

// MARK: - BreakOverlayControllerProtocol conformance

@available(macOS 14.2, *)
extension BreakOverlayController: BreakOverlayControllerProtocol {}
