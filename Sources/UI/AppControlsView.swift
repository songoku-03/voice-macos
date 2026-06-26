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
        VStack(alignment: .leading, spacing: DS.m) {
            // Routing
            HStack(spacing: DS.s) {
                Label {
                    Text("ROUTE TO")
                        .font(DSFont.label)
                        .tracking(0.8)
                        .foregroundStyle(DS.textTertiary)
                } icon: {
                    Image(systemName: "arrow.turn.up.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(DS.accentPink)
                }

                Spacer()

                OutputDevicePicker(
                    selection: Binding(
                        get: { AudioEngineManager.shared.getAppOutputDevice(bundleID: bundleID) },
                        set: { AudioEngineManager.shared.setAppOutputDevice(bundleID: bundleID, deviceID: $0) }
                    ),
                    includeDefault: true
                )
            }

            // Volume + EQ toggle
            HStack(spacing: DS.m) {
                Button(action: toggleMute) {
                    ZStack {
                        Circle()
                            .fill(isMuted ? DS.danger.opacity(0.12) : DS.cardBgActive)
                            .frame(width: 24, height: 24)
                        
                        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(isMuted ? DS.danger : DS.textSecondary)
                    }
                    .overlay(
                        Circle()
                            .strokeBorder(DS.stroke, lineWidth: DS.borderWidth)
                    )
                }
                .buttonStyle(.plain)

                CustomSlider(value: $volume)
                    .onChange(of: volume) { _, newValue in
                        AudioEngineManager.shared.setVolume(bundleID: bundleID, volume: newValue)
                    }

                Text("\(Int(volume * 100))%")
                    .font(DSFont.mono)
                    .foregroundStyle(DS.textSecondary)
                    .frame(width: 36, alignment: .trailing)

                Button(action: toggleEQBypass) {
                    Text(isEQBypassed ? "EQ OFF" : "EQ ON")
                        .font(DSFont.label)
                        .tracking(0.6)
                        .padding(.horizontal, DS.s + 3)
                        .padding(.vertical, DS.xs)
                        .background(
                            Group {
                                if isEQBypassed {
                                    DS.cardBgActive
                                } else {
                                    DS.accentGradient
                                }
                             }
                        )
                        .foregroundStyle(isEQBypassed ? DS.textTertiary : DS.stroke)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(DS.stroke, lineWidth: DS.borderWidth)
                        )
                }
                .buttonStyle(.plain)
            }

            // EQ curve
            if !isEQBypassed {
                EQCurveEditor(
                    eqController: eqController,
                    spectrum: AudioEngineManager.shared.activeNodes[bundleID]?.spectrumTap
                )
                .transition(.opacity)
            }
        }
        .padding(.vertical, DS.s)
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
        withAnimation(.easeInOut(duration: 0.2)) { isEQBypassed.toggle() }
        eqController.setBypass(isEQBypassed)
    }
}

// MARK: - Custom Slider for Playful Cartoon Audio Controls
struct CustomSlider: View {
    @Binding var value: Float
    var range: ClosedRange<Float> = 0.0...2.0
    
    @State private var isHovered = false
    @State private var isDragging = false
    
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let percentage = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let filledWidth = percentage * width
            let thumbSize: CGFloat = 14
            
            ZStack(alignment: .leading) {
                // Background track
                Capsule()
                    .fill(DS.stroke.opacity(0.3))
                    .frame(height: 8)
                    .overlay(
                        Capsule()
                            .stroke(DS.stroke, lineWidth: DS.borderWidth)
                    )
                
                // Active track with gradient
                Capsule()
                    .fill(DS.sliderGradient)
                    .frame(width: max(0, filledWidth), height: 8)
                    .overlay(
                        Capsule()
                            .stroke(DS.stroke, lineWidth: DS.borderWidth)
                            .frame(width: max(0, filledWidth))
                    )
                
                // Thumb
                Circle()
                    .fill(DS.accent)
                    .frame(width: thumbSize, height: thumbSize)
                    .overlay(
                        Circle()
                            .strokeBorder(DS.stroke, lineWidth: DS.borderWidth)
                    )
                    .background(
                        Circle()
                            .fill(DS.shadowColor)
                            .offset(x: 2, y: 2)
                    )
                    .offset(x: max(0, min(width - thumbSize, filledWidth - thumbSize/2)))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { val in
                        isDragging = true
                        let x = val.location.x
                        let clampedX = max(0, min(width, x))
                        let pct = clampedX / width
                        let newValue = Float(pct) * (range.upperBound - range.lowerBound) + range.lowerBound
                        value = newValue
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isHovered = hovering
                }
            }
        }
        .frame(height: 16)
    }
}

