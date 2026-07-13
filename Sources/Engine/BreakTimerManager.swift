import Foundation
import AppKit
import Observation
import Core
import ApplicationServices

// MARK: - Accessibility helpers (nonisolated — avoids Swift 6 shared-global-state error)

/// Silent check — does NOT show the system prompt. Safe to call every second.
private func checkAccessibilityPermission() -> Bool {
    let options = NSDictionary(
        object: kCFBooleanFalse as Any,
        forKey: "AXTrustedCheckOptionPrompt" as NSString
    )
    return AXIsProcessTrustedWithOptions(options)
}

/// Check + show system prompt. Call only once on user intent (start()).
private func promptAccessibilityPermission() -> Bool {
    let options = NSDictionary(
        object: kCFBooleanTrue as Any,
        forKey: "AXTrustedCheckOptionPrompt" as NSString
    )
    return AXIsProcessTrustedWithOptions(options)
}

// MARK: - TodoItem Model

public struct TodoItem: Identifiable, Codable, Equatable {
    public var id: UUID
    public var title: String
    public var isCompleted: Bool
    
    public init(id: UUID = UUID(), title: String, isCompleted: Bool = false) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
    }
}

// MARK: - BreakTimerManager

/// Central state machine for the eye-rest timer feature.
/// Drives the `idle → studying → warning → breaking` cycle using
/// wall-clock absolute deadlines so sleep/wake does not corrupt timing.
@available(macOS 14.2, *)
@Observable
@MainActor
public final class BreakTimerManager {

    // MARK: State

    public enum Phase: Equatable {
        case idle
        case studying
        case warning   // ~10 s before break
        case breaking
    }

    public private(set) var phase: Phase = .idle

    /// Seconds remaining in the current phase (updated every ~1 s).
    public private(set) var remaining: TimeInterval = 0

    // MARK: Configuration (persisted via UserDefaults)

    /// Study duration in seconds.
    public var studyDuration: TimeInterval {
        didSet {
            UserDefaults.standard.set(studyDuration, forKey: "btm_studyDuration")
        }
    }

    /// Break duration in seconds.
    public var breakDuration: TimeInterval {
        didSet {
            UserDefaults.standard.set(breakDuration, forKey: "btm_breakDuration")
        }
    }

    public var isConfigValid: Bool {
        studyDuration > 0 && breakDuration > 0
    }

    // MARK: Completed Sessions Stats

    public var completedSessionsToday: Int {
        didSet {
            let today = Calendar.current.startOfDay(for: Date()).description
            UserDefaults.standard.set(today, forKey: "btm_lastSessionDate")
            UserDefaults.standard.set(completedSessionsToday, forKey: "btm_completedSessions")
        }
    }

    // MARK: Todo List State & Operations

    public var todoItems: [TodoItem] {
        didSet {
            if let data = try? JSONEncoder().encode(todoItems) {
                UserDefaults.standard.set(data, forKey: "btm_todoItems")
            }
        }
    }

    public func addTodoItem(title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var current = todoItems
        current.append(TodoItem(title: clean))
        todoItems = current
    }

    public func toggleTodoItem(id: UUID) {
        var current = todoItems
        if let idx = current.firstIndex(where: { $0.id == id }) {
            current[idx].isCompleted.toggle()
            todoItems = current
        }
    }

    public func deleteTodoItem(id: UUID) {
        var current = todoItems
        current.removeAll(where: { $0.id == id })
        todoItems = current
    }

    // MARK: Lock mode

    /// Whether the event-tap hard-lock is available (Accessibility permission granted).
    public private(set) var hardLockAvailable = false

    // MARK: Injected dependencies

    public var audioEngineManager: AudioEngineManager = .shared

    public weak var inputBlocker: InputBlockerProtocol?
    public weak var overlayController: BreakOverlayControllerProtocol?

    /// Called by `AppDelegate` to let `BreakTimerManager` update the status-item title.
    public var onStatusItemUpdate: ((String?) -> Void)?

    // MARK: Private state

    private static let warningThreshold: TimeInterval = 10
    private static let maxLockDuration: TimeInterval = 300 // 5 min watchdog ceiling

    private var timer: DispatchSourceTimer?
    private var watchdogTimer: DispatchSourceTimer?

    /// Absolute deadline for the *end* of the current phase.
    private var deadline: Date = .distantFuture

    /// Volumes snapshotted before break (bundleID → volume), for ducking restore.
    private var preBreakVolumes: [String: Float] = [:]

    /// Whether ducking is active (persisted for crash-safe restore).
    private static let duckingActiveKey = "btm_duckingActive"
    private static let preBreakVolumesKey = "btm_preBreakVolumes"

    // MARK: Shared instance

    public static let shared = BreakTimerManager()

    public init() {
        let study = UserDefaults.standard.double(forKey: "btm_studyDuration")
        self.studyDuration = study > 0 ? study : 25 * 60

        let brk = UserDefaults.standard.double(forKey: "btm_breakDuration")
        self.breakDuration = brk > 0 ? brk : 5 * 60

        let lastDate = UserDefaults.standard.string(forKey: "btm_lastSessionDate") ?? ""
        let today = Calendar.current.startOfDay(for: Date()).description
        if lastDate != today {
            UserDefaults.standard.set(today, forKey: "btm_lastSessionDate")
            UserDefaults.standard.set(0, forKey: "btm_completedSessions")
            self.completedSessionsToday = 0
        } else {
            self.completedSessionsToday = UserDefaults.standard.integer(forKey: "btm_completedSessions")
        }

        if let data = UserDefaults.standard.data(forKey: "btm_todoItems"),
           let items = try? JSONDecoder().decode([TodoItem].self, from: data) {
            self.todoItems = items
        } else {
            self.todoItems = []
        }

        setupWorkspaceObservers()
        crashSafeRestoreIfNeeded()
    }

    // MARK: - Public API

    /// Start the study cycle. No-op if not `idle`. Performs Accessibility preflight once.
    public func start() {
        guard phase == .idle else { return }
        guard isConfigValid else { return }

        // 1.3: Preflight Accessibility permission once before entering the cycle.
        // Call via a nonisolated helper to avoid Swift 6 shared-global-state error.
        // prompt=true so the system dialog appears on first run.
        hardLockAvailable = promptAccessibilityPermission()

        enterStudying()
    }

    /// Stop from any active state → idle. Goes through shared teardown.
    public func stop() {
        guard phase != .idle else { return }
        endBreak(reason: .stopped)
    }

    /// Skip the current break → triggers end-break teardown then auto-loops.
    public func skip() {
        guard phase == .breaking || phase == .warning else { return }
        endBreak(reason: .skipped)
    }

    /// Delay/Snooze the upcoming break by 5 minutes during the warning phase.
    public func snooze() {
        guard phase == .warning else { return }
        phase = .studying
        let snoozeDuration: TimeInterval = 5 * 60
        deadline = Date().addingTimeInterval(snoozeDuration)
        remaining = snoozeDuration
        updateStatusItem()
    }

    // MARK: - State transitions

    private func enterStudying() {
        phase = .studying
        deadline = Date().addingTimeInterval(studyDuration)
        remaining = studyDuration
        startHeartbeat()
        updateStatusItem()
    }

    private func enterWarning() {
        guard phase == .studying else { return }
        phase = .warning
        deadline = Date().addingTimeInterval(BreakTimerManager.warningThreshold)
        remaining = BreakTimerManager.warningThreshold
        updateStatusItem()
        // Surface warning outside the (potentially-closed) popover via status item title flash.
        flashWarningOnStatusItem()
    }

    private func enterBreaking() {
        // 1.8: Guard double-enter.
        guard phase == .warning || phase == .studying else { return }
        phase = .breaking
        deadline = Date().addingTimeInterval(breakDuration)
        remaining = breakDuration

        // Lock input and show overlay.
        if hardLockAvailable { inputBlocker?.install() }
        overlayController?.showOverlays()

        // Audio: duck + chime.
        duckAudio()
        playChime(start: true)

        // 2.6: Independent watchdog.
        startWatchdog()

        updateStatusItem()
    }

    // MARK: - Shared teardown (7.2)

    public enum EndBreakReason {
        case timeout, skipped, stopped, watchdog, appTerminate
    }

    /// The one idempotent teardown path for every exit from `breaking`/`warning`/`studying`.
    /// Order: remove tap → hide overlay → restore audio → reset status item → cancel timers → chime.
    public func endBreak(reason: EndBreakReason) {
        let wasBreaking = (phase == .breaking || phase == .warning)

        // 1. Gỡ tap (idempotent).
        inputBlocker?.uninstall()

        // 2. Ẩn overlay.
        if wasBreaking { overlayController?.hideOverlays() }

        // 3. Khôi phục audio.
        unduckAudio()

        // 4. Reset trạng thái.
        phase = .idle
        remaining = 0
        cancelTimers()

        // 5. Reset status item.
        onStatusItemUpdate?(nil)

        // 6. Chuông kết thúc (sau khi unlock xong).
        if wasBreaking { playChime(start: false) }

        // 7. Auto-loop (trừ khi bị stop/terminate).
        if reason == .timeout || reason == .skipped {
            if reason == .timeout {
                completedSessionsToday += 1
            }
            // Small delay to let chime start before restarting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.enterStudying()
            }
        }
    }

    // MARK: - Heartbeat timer (1Hz)

    private func startHeartbeat() {
        cancelHeartbeat()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func cancelHeartbeat() {
        timer?.cancel()
        timer = nil
    }

    private func cancelTimers() {
        cancelHeartbeat()
        cancelWatchdog()
    }

    private func tick() {
        // Auto re-check Accessibility permission every tick (1s) so the UI
        // updates immediately after the user grants it in System Settings —
        // no need to Stop + Start again.
        if !hardLockAvailable {
            let granted = checkAccessibilityPermission()
            if granted {
                hardLockAvailable = true
                // If we're currently in a break, install the tap now.
                if phase == .breaking {
                    inputBlocker?.install()
                }
            }
        }

        // Recompute from absolute deadline (1.4) — immune to sleep/wake drift.
        let now = Date()
        let r = deadline.timeIntervalSince(now)

        switch phase {
        case .idle:
            break

        case .studying:
            if r <= BreakTimerManager.warningThreshold {
                remaining = max(0, r)
                enterWarning()
            } else {
                remaining = r
            }

        case .warning:
            if r <= 0 {
                remaining = 0
                enterBreaking()
            } else {
                remaining = r
            }

        case .breaking:
            if r <= 0 {
                remaining = 0
                endBreak(reason: .timeout)
            } else {
                remaining = r
            }
        }

        updateStatusItem()
    }

    // MARK: - Watchdog (2.6)

    private func startWatchdog() {
        cancelWatchdog()
        let cap = BreakTimerManager.maxLockDuration
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + cap, repeating: .never)
        t.setEventHandler { [weak self] in
            print("BreakTimerManager: Watchdog fired — forcing endBreak")
            self?.endBreak(reason: .watchdog)
        }
        t.resume()
        watchdogTimer = t
    }

    private func cancelWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    // MARK: - Sleep / Wake observers (1.5)

    private func setupWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(handleSleep), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleWake), name: NSWorkspace.didWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleSessionLock), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleSessionUnlock), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    }

    @objc private func handleSleep() {
        // Nothing to do — deadline is absolute, tick() will recompute on wake.
    }

    @objc private func handleWake() {
        // Recompute immediately without waiting for the next tick.
        let now = Date()
        switch phase {
        case .studying, .warning:
            let r = deadline.timeIntervalSince(now)
            if r <= 0 {
                // Study time elapsed while sleeping → go straight to break.
                enterBreaking()
            } else {
                remaining = r
                updateStatusItem()
            }
        case .breaking:
            let r = deadline.timeIntervalSince(now)
            if r <= 0 {
                endBreak(reason: .timeout)
            } else {
                // Re-assert overlay + tap in case they were dismissed.
                if hardLockAvailable { inputBlocker?.install() }
                overlayController?.showOverlays()
                remaining = r
                updateStatusItem()
            }
        case .idle:
            break
        }
    }

    @objc private func handleSessionLock() {
        // Session locked — pause is implicit; deadline still ticking.
    }

    @objc private func handleSessionUnlock() {
        // Same as wake: recompute and re-assert.
        handleWake()
    }

    // MARK: - Status item (6.7)

    private func updateStatusItem() {
        switch phase {
        case .idle:
            onStatusItemUpdate?(nil)
        case .studying:
            onStatusItemUpdate?("📖 \(formattedTime(remaining))")
        case .warning:
            onStatusItemUpdate?("⚠️ \(formattedTime(remaining))")
        case .breaking:
            onStatusItemUpdate?("😌 \(formattedTime(remaining))")
        }
    }

    private func flashWarningOnStatusItem() {
        // Flash the status item 3 times to surface the warning even when popover is closed.
        // Use a DispatchSource on the main queue to avoid Sendable capture issues with
        // a mutable `count` var (Swift 6).
        var count = 0
        let src = DispatchSource.makeTimerSource(queue: .main)
        src.schedule(deadline: .now() + 0.4, repeating: 0.4, leeway: .milliseconds(50))
        src.setEventHandler { [weak self] in
            guard let self else { src.cancel(); return }
            count += 1
            let show = count % 2 == 1
            self.onStatusItemUpdate?(show ? "⚠️ NGHỈ SẮP TỚI!" : "")
            if count >= 6 { src.cancel(); self.updateStatusItem() }
        }
        src.resume()
    }

    private func formattedTime(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        let m = s / 60
        let sec = s % 60
        return m > 0 ? "\(m):\(String(format: "%02d", sec))" : "\(sec)s"
    }

    // MARK: - Audio: ducking (6.2–6.6)

    private func duckAudio() {
        let manager = audioEngineManager
        var snapshot: [String: Float] = [:]

        for bundleID in manager.activeNodes.keys {
            let vol = manager.getVolume(bundleID: bundleID)
            snapshot[bundleID] = vol
            let muted = manager.getMute(bundleID: bundleID)
            manager.setNodeVolumeDirect(bundleID: bundleID, volume: muted ? 0.0 : vol * 0.1)
        }

        preBreakVolumes = snapshot

        // Persist for crash-safe restore (6.6).
        let encoded = snapshot.mapValues { Double($0) }
        UserDefaults.standard.set(encoded, forKey: BreakTimerManager.preBreakVolumesKey)
        UserDefaults.standard.set(true, forKey: BreakTimerManager.duckingActiveKey)
    }

    private func unduckAudio() {
        guard !preBreakVolumes.isEmpty else {
            clearDuckingPersistence()
            return
        }
        let manager = audioEngineManager
        for (bundleID, vol) in preBreakVolumes {
            // Restore appNode's volume directly.
            let muted = manager.getMute(bundleID: bundleID)
            manager.setNodeVolumeDirect(bundleID: bundleID, volume: muted ? 0.0 : vol)
        }
        preBreakVolumes = [:]
        clearDuckingPersistence()
    }

    /// Called by AudioEngineManager when a new app starts tapping mid-break (6.3).
    public func duckNewNode(bundleID: String, manager: AudioEngineManager? = nil) {
        guard phase == .breaking else { return }
        guard preBreakVolumes[bundleID] == nil else { return }
        let targetManager = manager ?? audioEngineManager
        let vol = targetManager.getVolume(bundleID: bundleID)
        preBreakVolumes[bundleID] = vol   // record pre-break volume

        let muted = targetManager.getMute(bundleID: bundleID)
        targetManager.setNodeVolumeDirect(bundleID: bundleID, volume: muted ? 0.0 : vol * 0.1)

        // Persist updated map.
        let encoded = preBreakVolumes.mapValues { Double($0) }
        UserDefaults.standard.set(encoded, forKey: BreakTimerManager.preBreakVolumesKey)
    }

    /// Update pre-break volume snapshot if user changes it during break (6.5)
    public func updatePreBreakVolume(bundleID: String, volume: Float) {
        guard phase == .breaking else { return }
        preBreakVolumes[bundleID] = volume
        
        // Persist updated map.
        let encoded = preBreakVolumes.mapValues { Double($0) }
        UserDefaults.standard.set(encoded, forKey: BreakTimerManager.preBreakVolumesKey)
    }

    private func clearDuckingPersistence() {
        UserDefaults.standard.set(false, forKey: BreakTimerManager.duckingActiveKey)
        UserDefaults.standard.removeObject(forKey: BreakTimerManager.preBreakVolumesKey)
    }

    /// 6.6: On launch, if a previous session crashed while ducking, restore volumes immediately.
    private func crashSafeRestoreIfNeeded() {
        guard UserDefaults.standard.bool(forKey: BreakTimerManager.duckingActiveKey) else { return }
        guard let raw = UserDefaults.standard.dictionary(forKey: BreakTimerManager.preBreakVolumesKey) else {
            clearDuckingPersistence()
            return
        }
        let snapshot = raw.compactMapValues { $0 as? Double }.mapValues { Float($0) }
        let manager = audioEngineManager
        for (bundleID, vol) in snapshot {
            manager.setVolume(bundleID: bundleID, volume: vol)
        }
        print("BreakTimerManager: Crash-safe restore applied for \(snapshot.count) app(s).")
        clearDuckingPersistence()
    }

    // MARK: - Chimes (6.1)

    private func playChime(start: Bool) {
        // Use NSSound system sounds — no external assets needed.
        let name: String = start ? "Glass" : "Ping"
        NSSound(named: name)?.play()
    }

    // MARK: - Teardown on app terminate (7.2)

    public func teardownOnTerminate() {
        endBreak(reason: .appTerminate)
    }
}

// MARK: - Helpers

private extension Double {
    func nonZeroOr(_ fallback: Double) -> Double {
        self > 0 ? self : fallback
    }
}
