import SwiftUI
import Observation
import Core
import Engine

@available(macOS 14.2, *)
public struct PopoverContentView: View {
    @State private var enumerator = AudioProcessEnumerator()
    @State private var engineManager = AudioEngineManager.shared
    @State private var store = PresetStore.shared
    
    @State private var selectedPresetName: String = "Flat"
    @State private var showSaveAlert = false
    @State private var newPresetName = ""

    // Poll the audio process list while the popover is open. CoreAudio's process-object
    // list listener only fires when processes are added/removed — not when an already
    // running app STARTS or STOPS producing output (its isRunningOutput flag flips but
    // the object list is unchanged). Polling keeps the list live for play/pause events.
    private let refreshTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    public init() {}

    // Show every running audio-capable foreground app (Spotify, Chrome, Discord…) even
    // when it's silent, so the user can pre-set EQ; the list updates in realtime as apps
    // open/close. System daemons are excluded (isRegularApp == false). A green dot marks
    // the ones actually producing audio right now (isRunningOutput).
    private var visibleProcesses: [AudioProcess] {
        AudioProcess.visibleRows(
            from: enumerator.processes,
            tappedBundleIDs: Set(engineManager.activeNodes.keys)
        )
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header — playful cartoon logo + device
            HStack(spacing: DS.s) {
                Image(systemName: "music.note.house.fill")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(DS.accentGradient)
                
                Text("Minh Thw ☁️")
                    .font(DSFont.wordmark)
                    .foregroundStyle(DS.textPrimary)

                Spacer(minLength: DS.s)

                OutputDevicePicker(selection: Bindable(engineManager).selectedDeviceID)
            }
            .padding(.horizontal, DS.l)
            .padding(.vertical, DS.m + 2)
            .background(DS.surface)
            
            Rectangle().fill(DS.stroke).frame(height: DS.borderWidth)

            // App List
            ProcessListView(processes: visibleProcesses)

            Rectangle().fill(DS.stroke).frame(height: DS.borderWidth)

            // Footer — Save Preset & Quit
            HStack {
                Button(action: { showSaveAlert = true }) {
                    Label("Save Preset", systemImage: "plus.circle")
                        .font(DSFont.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(DS.textSecondary)
                        .padding(.horizontal, DS.m)
                        .padding(.vertical, DS.xs + 3)
                        .background(DS.surfaceHi)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(DS.stroke, lineWidth: DS.borderWidth)
                        )
                }
                .buttonStyle(.plain)
                .hoverEffectHelper()

                Spacer()

                Button(action: { NSApp.terminate(nil) }) {
                    Text("Quit")
                        .font(DSFont.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(DS.danger)
                        .padding(.horizontal, DS.m + 4)
                        .padding(.vertical, DS.xs + 3)
                        .background(DS.danger.opacity(0.12))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(DS.stroke, lineWidth: DS.borderWidth)
                        )
                }
                .buttonStyle(.plain)
                .hoverEffectHelper()
            }
            .padding(.horizontal, DS.l)
            .padding(.vertical, DS.m)
            .background(DS.surface)
        }
        .frame(width: 360)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .overlay(DS.bg.opacity(0.95))
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusL))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusL)
                .strokeBorder(DS.stroke, lineWidth: DS.borderWidth)
        )
        .tint(DS.accent)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSaveAlert) {
            VStack(alignment: .leading, spacing: DS.m) {
                Text("Save Preset")
                    .font(.system(size: 14, weight: .bold, design: .serif))
                    .foregroundStyle(DS.textPrimary)

                Text("Capture the current EQ, volume and routing for every active app.")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("Preset name", text: $newPresetName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.regular)
                    .tint(DS.accent)

                HStack(spacing: DS.s) {
                    Spacer()
                    Button("Cancel") {
                        showSaveAlert = false
                        newPresetName = ""
                    }
                    .controlSize(.regular)

                    Button("Save") {
                        if !newPresetName.isEmpty {
                            engineManager.saveCurrentStateAsPreset(name: newPresetName)
                            selectedPresetName = newPresetName
                        }
                        showSaveAlert = false
                        newPresetName = ""
                    }
                    .controlSize(.regular)
                    .buttonStyle(.borderedProminent)
                    .tint(DS.accent)
                    .disabled(newPresetName.isEmpty)
                }
            }
            .padding(DS.l)
            .frame(width: 260)
            .background(DS.surface)
        }
        .onReceive(refreshTimer) { _ in
            enumerator.refresh()
        }
        .onAppear {
            enumerator.refresh()
            if let def = store.defaultPreset {
                selectedPresetName = def.name
            }
        }
    }
}

// MARK: - Visual Effect View for macOS Glassmorphism
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Hover Effect Helper
extension View {
    func hoverEffectHelper() -> some View {
        self.modifier(HoverEffectModifier())
    }
}

struct HoverEffectModifier: ViewModifier {
    @State private var isHovered = false
    
    func body(content: Content) -> some View {
        content
            .opacity(isHovered ? 1.0 : 0.85)
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}
