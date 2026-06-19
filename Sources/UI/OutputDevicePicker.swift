import SwiftUI
import CoreAudio
import Engine

@available(macOS 14.2, *)
public struct OutputDevicePicker: View {
    @Binding var selection: AudioDeviceID
    let includeDefault: Bool
    
    @State private var engineManager = AudioEngineManager.shared
    
    public init(selection: Binding<AudioDeviceID>, includeDefault: Bool = false) {
        self._selection = selection
        self.includeDefault = includeDefault
    }
    
    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundColor(.cyan)
                .font(.system(size: 10, weight: .bold))
            
            Picker("", selection: $selection) {
                if includeDefault {
                    Text("Default Output").tag(kAudioObjectUnknown)
                }
                ForEach(engineManager.outputDevices) { device in
                    Text(device.name).tag(device.deviceID)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .frame(minWidth: 110, maxWidth: 160)
            .help("Select output audio device")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.06))
        .cornerRadius(6)
    }
}
