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
        HStack(spacing: DS.xs) {
            Image(systemName: "hifispeaker.fill")
                .foregroundStyle(DS.control)
                .font(.system(size: 10, weight: .semibold))

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
            .frame(minWidth: 104, maxWidth: 150)
            .help("Select output audio device")
        }
        .padding(.horizontal, DS.s)
        .padding(.vertical, DS.xs)
        .background(DS.surfaceHi.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusS))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusS)
                .strokeBorder(DS.stroke, lineWidth: DS.borderWidth)
        )
    }
}
