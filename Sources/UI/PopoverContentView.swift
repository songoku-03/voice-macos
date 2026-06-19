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

    public init() {}

    // Only show apps actively producing audio, plus any currently tapped app
    // (so it doesn't vanish from the list when its audio pauses mid-session).
    private var visibleProcesses: [AudioProcess] {
        enumerator.processes.filter { proc in
            proc.isRunningOutput || engineManager.activeNodes[proc.bundleID] != nil
        }
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
        .onAppear {
            enumerator.refresh()
            if let def = store.defaultPreset {
                selectedPresetName = def.name
            }
        }
    }
}
