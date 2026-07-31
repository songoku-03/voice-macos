import SwiftUI
import Engine
import AppKit

/// Eye-rest timer control panel embedded in the popover (5.1–5.4).
/// Contains duration inputs, Start/Stop button, status display,
/// Accessibility permission guidance, a Snooze/Delay button,
/// and a persisted Todo List for productivity.
@available(macOS 14.2, *)
public struct EyeRestTimerView: View {

    private var manager = BreakTimerManager.shared

    // Local string-backed storage for the text fields (so we can validate).
    @State private var studyMinutesText: String = ""
    @State private var breakMinutesText: String = ""
    @State private var showAccessibilityAlert = false
    @State private var newTodoTitle = ""

    public init() {}

    // MARK: - Body

    public var body: some View {
        VStack(spacing: DS.m) {
            // Section header
            HStack(spacing: DS.xs) {
                Image(systemName: "eye.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DS.accentText)
                Text("Nghỉ mắt")
                    .font(DSFont.label)
                    .foregroundStyle(DS.textPrimary)
                
                if manager.completedSessionsToday > 0 {
                    Text("• 📖 \(manager.completedSessionsToday)")
                        .font(DSFont.caption)
                        .foregroundStyle(DS.accentText)
                        .fontWeight(.bold)
                }
                
                Spacer()
                // 5.3: Status badge — visible even when popover is open
                if manager.phase != .idle {
                    statusBadge
                }
            }

            // 5.1: Duration inputs (only editable when idle)
            if manager.phase == .idle {
                HStack(spacing: DS.s) {
                    durationField(
                        label: "Học (phút)",
                        text: $studyMinutesText,
                        placeholder: "25"
                    )
                    durationField(
                        label: "Nghỉ (phút)",
                        text: $breakMinutesText,
                        placeholder: "1"
                    )
                }
            }

            // Snooze / Delay Break button (Visible ONLY during warning phase)
            if manager.phase == .warning {
                Button(action: {
                    withAnimation {
                        manager.snooze()
                    }
                }) {
                    HStack(spacing: DS.xs) {
                        Image(systemName: "hourglass.badge.plus")
                        Text("Trì hoãn break thêm 5 phút")
                            .fontWeight(.bold)
                    }
                    .font(DSFont.caption)
                    .foregroundStyle(DS.accentText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.s)
                    .background(DS.control.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: DS.radiusM))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.radiusM)
                            .strokeBorder(DS.control.opacity(0.3), lineWidth: DS.borderWidth)
                    )
                }
                .buttonStyle(.plain)
                .hoverEffectHelper()
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // 5.4: Accessibility degraded-mode notice (shows whenever !hardLockAvailable, including at .idle)
            if !manager.hardLockAvailable {
                HStack(spacing: DS.xs) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(DS.accentText)
                        .font(.system(size: 11))
                    Text(degradedModeNoticeText)
                        .font(DSFont.caption)
                        .foregroundStyle(DS.textSecondary)
                    Spacer()
                    Button("Cấp quyền") {
                        let granted = manager.requestAccessibilityPermission()
                        if !granted {
                            showAccessibilityAlert = true
                        }
                    }
                    .font(DSFont.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.accentText)
                }
                .padding(DS.xs + 2)
                .background(DS.control.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: DS.radiusS))
            }

            // 5.2: Start / Stop button
            startStopButton

            // --- Integrated Todo List Section ---
            Divider().background(DS.stroke)

            VStack(alignment: .leading, spacing: DS.s) {
                Text("Việc cần làm")
                    .font(DSFont.label)
                    .foregroundStyle(DS.textSecondary)

                // Add Todo input
                HStack(spacing: DS.s) {
                    TextField("Thêm việc học mới...", text: $newTodoTitle)
                        .textFieldStyle(.plain)
                        .font(DSFont.caption)
                        .foregroundStyle(DS.textPrimary)
                        .padding(.horizontal, DS.s)
                        .padding(.vertical, DS.xs + 2)
                        .background(DS.surface)
                        .clipShape(RoundedRectangle(cornerRadius: DS.radiusS))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.radiusS)
                                .strokeBorder(DS.stroke, lineWidth: DS.borderWidth)
                        )
                        .onSubmit {
                            addTodo()
                        }

                    Button(action: addTodo) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(newTodoTitle.isEmpty ? DS.textTertiary : DS.accentText)
                    }
                    .buttonStyle(.plain)
                    .disabled(newTodoTitle.isEmpty)
                }

                // List of items
                if manager.todoItems.isEmpty {
                    Text("Chưa có công việc nào. Hãy thêm một mục để bắt đầu!")
                        .font(DSFont.caption)
                        .foregroundStyle(DS.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, DS.s)
                } else {
                    VStack(spacing: DS.xs) {
                        ForEach(manager.todoItems) { item in
                            HStack(spacing: DS.s) {
                                Button(action: {
                                    withAnimation(.spring(response: 0.2)) {
                                        manager.toggleTodoItem(id: item.id)
                                    }
                                }) {
                                    Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 14))
                                        .foregroundStyle(item.isCompleted ? DS.playing : DS.textTertiary)
                                }
                                .buttonStyle(.plain)

                                Text(item.title)
                                    .font(DSFont.caption)
                                    .foregroundStyle(item.isCompleted ? DS.textTertiary : DS.textPrimary)
                                    .strikethrough(item.isCompleted)
                                    .lineLimit(1)
                                
                                Spacer()

                                Button(action: {
                                    withAnimation(.spring(response: 0.2)) {
                                        manager.deleteTodoItem(id: item.id)
                                    }
                                }) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10))
                                        .foregroundStyle(DS.danger.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, DS.s)
                            .padding(.vertical, DS.xs + 2)
                            .background(DS.surface.opacity(0.4))
                            .clipShape(RoundedRectangle(cornerRadius: DS.radiusS))
                        }
                    }
                }
            }
        }
        .padding(DS.m)
        .background(DS.surfaceHi)
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusM))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusM)
                .strokeBorder(DS.stroke, lineWidth: DS.borderWidth)
        )
        .onAppear { loadFromManager() }
        .alert("Cấp quyền Accessibility", isPresented: $showAccessibilityAlert) {
            Button("Mở System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Đóng", role: .cancel) {}
        } message: {
            Text(accessibilityAlertMessage)
        }
    }

    private var degradedModeNoticeText: String {
        if case .ineligibleLocation = manager.bundleDiagnostic {
            return "Ứng dụng nằm ở vị trí không thể cấp Accessibility"
        }
        return "Chế độ overlay-only (chưa cấp Accessibility)"
    }

    private var accessibilityAlertMessage: String {
        switch manager.bundleDiagnostic {
        case .missing:
            return "Không tìm thấy file ứng dụng trên đĩa. Vui lòng chạy ứng dụng từ thư mục đã cài đặt ~/Applications/SoundsSource.app."
        case .ineligibleLocation(let reason):
            switch reason {
            case .protectedFolder(let folder):
                return "Ứng dụng đang nằm trong thư mục được bảo vệ (\(folder)). Trình chọn ứng dụng của System Settings không thể duyệt thư mục này để thêm quyền. Vui lòng di chuyển hoặc cài đặt ứng dụng vào thư mục ~/Applications hoặc /Applications."
            case .appTranslocation:
                return "Ứng dụng đang chạy trong chế độ cách ly AppTranslocation. Vui lòng di chuyển ứng dụng vào ~/Applications và chạy lại."
            }
        case .staleExecutable:
            return "Mã ứng dụng trên đĩa không khớp với tiến trình đang chạy. Vui lòng khởi động lại ứng dụng từ thư mục cài đặt ~/Applications/SoundsSource.app."
        case .ok, .unknown:
            let installedPath = (NSHomeDirectory() as NSString).appendingPathComponent("Applications/SoundsSource.app")
            return "Vào System Settings → Privacy & Security → Accessibility, nhấn nút [+] và chọn ứng dụng tại đường dẫn:\n\(installedPath)"
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(manager.phase == .breaking ? DS.danger : DS.control)
                .frame(width: 6, height: 6)
            Text(statusLabel)
                .font(DSFont.caption)
                .foregroundStyle(manager.phase == .breaking ? DS.danger : DS.accentText)
                .monospacedDigit()
        }
        .padding(.horizontal, DS.s)
        .padding(.vertical, 3)
        .background((manager.phase == .breaking ? DS.danger : DS.control).opacity(0.12))
        .clipShape(Capsule())
    }

    private var statusLabel: String {
        let t = max(0, Int(manager.remaining))
        let m = t / 60; let s = t % 60
        let time = String(format: "%02d:%02d", m, s)
        switch manager.phase {
        case .studying: return "📖 \(time)"
        case .warning:  return "⚠️ \(time)"
        case .breaking: return "😌 \(time)"
        case .idle:     return ""
        }
    }

    @ViewBuilder
    private var startStopButton: some View {
        let isRunning = manager.phase != .idle
        let valid = validateInputs()

        Button {
            if isRunning {
                manager.stop()
            } else {
                commitToManager()
                manager.start()
                // 5.4: If Accessibility wasn't granted, show guidance.
                if !manager.hardLockAvailable {
                    showAccessibilityAlert = true
                }
            }
        } label: {
            HStack(spacing: DS.xs) {
                Image(systemName: isRunning ? "stop.circle.fill" : "play.circle.fill")
                Text(isRunning ? "Dừng" : "Bắt đầu")
                    .fontWeight(.bold)
            }
            .font(DSFont.control)
            .foregroundStyle(isRunning ? DS.danger : DS.onAccent())
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.s + 2)
            .background(isRunning ? DS.danger.opacity(0.15) : DS.control)
            .clipShape(RoundedRectangle(cornerRadius: DS.radiusM))
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusM)
                    .strokeBorder(DS.stroke, lineWidth: DS.borderWidth)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isRunning && !valid)
        .opacity((!isRunning && !valid) ? 0.45 : 1.0)
        .hoverEffectHelper()
    }

    @ViewBuilder
    private func durationField(label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(DSFont.caption)
                .foregroundStyle(DS.textSecondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(DSFont.control)
                .foregroundStyle(DS.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.s)
                .padding(.vertical, DS.xs + 2)
                .background(DS.surface)
                .clipShape(RoundedRectangle(cornerRadius: DS.radiusS))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusS)
                        .strokeBorder(DS.stroke, lineWidth: DS.borderWidth)
                )
                .disabled(manager.phase != .idle)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Validation & persistence helpers

    private func validateInputs() -> Bool {
        guard let m = Double(studyMinutesText), m > 0,
              let b = Double(breakMinutesText), b > 0 else { return false }
        return true
    }

    private func commitToManager() {
        if let m = Double(studyMinutesText), m > 0 {
            manager.studyDuration = m * 60
        }
        if let b = Double(breakMinutesText), b > 0 {
            manager.breakDuration = b * 60  // phút → giây
        }
    }

    private func loadFromManager() {
        manager.refreshBundleDiagnostic()
        studyMinutesText = String(format: "%.0f", manager.studyDuration / 60)
        breakMinutesText = String(format: "%.0f", manager.breakDuration / 60)
    }

    private func addTodo() {
        let clean = newTodoTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        manager.addTodoItem(title: clean)
        newTodoTitle = ""
    }
}
