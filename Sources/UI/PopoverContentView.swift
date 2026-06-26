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
            // Header: Title & Preset + Output Device Picker
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text("SoundsSource")
                        .font(.system(size: 13, weight: .black))
                        .foregroundColor(.cyan)
                    
                    Picker("", selection: $selectedPresetName) {
                        ForEach(store.presets) { preset in
                            Text(preset.name).tag(preset.name)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 85)
                    .onChange(of: selectedPresetName) { _, newValue in
                        engineManager.loadPreset(name: newValue)
                    }
                }
                
                Spacer(minLength: 4)
                
                OutputDevicePicker(selection: Bindable(engineManager).selectedDeviceID)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(Color.white.opacity(0.04))
            
            Divider()
                .background(Color.white.opacity(0.08))
            
            // App List
            ProcessListView(processes: visibleProcesses)
            
            Divider()
                .background(Color.white.opacity(0.08))
            
            // Footer: Save Preset & Quit App
            HStack {
                Button(action: { showSaveAlert = true }) {
                    Label("Save Preset", systemImage: "plus.circle")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                Button(action: { NSApp.terminate(nil) }) {
                    Text("Quit SoundsSource")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.red.opacity(0.75))
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(Color.white.opacity(0.02))
        }
        .frame(width: 360)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSaveAlert) {
            VStack(spacing: 12) {
                Text("Save Current Preset")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                
                TextField("Preset Name", text: $newPresetName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 180)
                
                HStack {
                    Button("Cancel") {
                        showSaveAlert = false
                        newPresetName = ""
                    }
                    .controlSize(.small)
                    
                    Spacer()
                    
                    Button("Save") {
                        if !newPresetName.isEmpty {
                            engineManager.saveCurrentStateAsPreset(name: newPresetName)
                            selectedPresetName = newPresetName
                        }
                        showSaveAlert = false
                        newPresetName = ""
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
                .frame(width: 180)
            }
            .padding(14)
            .frame(width: 220)
            .background(Color(NSColor.windowBackgroundColor))
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
