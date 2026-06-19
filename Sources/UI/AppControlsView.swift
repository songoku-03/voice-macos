import SwiftUI
import CoreAudio
import Engine

@available(macOS 14.2, *)
public struct AppControlsView: View {
    let bundleID: String
    let eqController: EQController
    
    @State private var volume: Float = 1.0
    @State private var isMuted = false
    @State private var isEQBypassed = false
    
    public init(bundleID: String, eqController: EQController) {
        self.bundleID = bundleID
        self.eqController = eqController
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Routing selection
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.purple)
                    Text("ROUTE TO")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.4))
                }
                
                Spacer()
                
                OutputDevicePicker(
                    selection: Binding(
                        get: { AudioEngineManager.shared.getAppOutputDevice(bundleID: bundleID) },
                        set: { newDeviceID in
                            AudioEngineManager.shared.setAppOutputDevice(bundleID: bundleID, deviceID: newDeviceID)
                        }
                    ),
                    includeDefault: true
                )
            }
            .padding(.bottom, 2)
            
            // Volume controls
            HStack(spacing: 8) {
                // Mute button
                Button(action: toggleMute) {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundColor(isMuted ? .gray : .cyan)
                        .font(.system(size: 11))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                
                // Volume slider
                Slider(value: $volume, in: 0.0...2.0)
                    .onChange(of: volume) { _, newValue in
                        AudioEngineManager.shared.setVolume(bundleID: bundleID, volume: newValue)
                    }
                    .accentColor(.cyan)
                
                // Volume percentage
                Text("\(Int(volume * 100))%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 32, alignment: .trailing)
                
                // EQ Bypass Button
                Button(action: toggleEQBypass) {
                    Text(isEQBypassed ? "Bypassed" : "EQ On")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(isEQBypassed ? Color.white.opacity(0.05) : Color.purple.opacity(0.2))
                        .cornerRadius(4)
                        .foregroundColor(isEQBypassed ? .white.opacity(0.5) : .purple)
                }
                .buttonStyle(.plain)
            }
            
            // EQ Curve Editor
            if !isEQBypassed {
                EQCurveEditor(
                    eqController: eqController,
                    spectrum: AudioEngineManager.shared.activeNodes[bundleID]?.spectrumTap
                )
                .transition(.opacity)
            }
        }
        .padding(.vertical, 6)
        .onAppear {
            self.volume = AudioEngineManager.shared.getVolume(bundleID: bundleID)
            self.isMuted = AudioEngineManager.shared.getMute(bundleID: bundleID)
            self.isEQBypassed = eqController.avAudioUnit.bypass
        }
    }
    
    private func toggleMute() {
        isMuted.toggle()
        AudioEngineManager.shared.setMute(bundleID: bundleID, muted: isMuted)
    }
    
    private func toggleEQBypass() {
        isEQBypassed.toggle()
        eqController.setBypass(isEQBypassed)
    }
}
