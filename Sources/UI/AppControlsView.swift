import SwiftUI
import CoreAudio
import Engine

@available(macOS 14.2, *)
public struct AppControlsView: View {
    let bundleID: String
    let eqController: EQController

    private var isEQBypassed: Bool {
        AudioEngineManager.shared.getEQBypass(bundleID: bundleID)
    }

    private var volume: Float {
        AudioEngineManager.shared.getVolume(bundleID: bundleID)
    }

    private var isMuted: Bool {
        AudioEngineManager.shared.getMute(bundleID: bundleID)
    }

    private var volumeBinding: Binding<Float> {
        Binding(
            get: { AudioEngineManager.shared.getVolume(bundleID: bundleID) },
            set: { AudioEngineManager.shared.setVolume(bundleID: bundleID, volume: $0) }
        )
    }

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
                            .fill(isMuted ? DS.danger.opacity(0.12) : DS.surfaceHi)
                            .frame(width: 24, height: 24)
                        
                        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isMuted ? DS.danger : DS.textSecondary)
                    }
                    .overlay(
                        Circle()
                            .strokeBorder(isMuted ? DS.danger.opacity(0.3) : DS.stroke, lineWidth: DS.borderWidth)
                    )
                }
                .buttonStyle(.plain)

                CustomSlider(value: volumeBinding)

                Text("\(Int(volume * 100))%")
                    .font(DSFont.mono)
                    .foregroundStyle(DS.textSecondary)
                    .frame(width: 36, alignment: .trailing)

                Button(action: toggleEQBypass) {
                    Text(isEQBypassed ? "EQ OFF" : "EQ ON")
                        .font(DSFont.label)
                        .tracking(0.6)
                        .padding(.horizontal, DS.s + 2)
                        .padding(.vertical, DS.xs)
                        .background(
                            Group {
                                if isEQBypassed {
                                    DS.surfaceHi
                                } else {
                                    DS.control.opacity(0.15)
                                }
                             }
                        )
                        .foregroundStyle(isEQBypassed ? DS.textTertiary : DS.control)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(isEQBypassed ? DS.stroke : DS.control.opacity(0.4), lineWidth: DS.borderWidth)
                        )
                }
                .buttonStyle(.plain)
            }

            // EQ curve — stays visible when bypassed, but dimmed and inert so the
            // user keeps their curve in view while EQ is off.
            EQCurveEditor(
                bundleID: bundleID,
                eqController: eqController,
                spectrum: AudioEngineManager.shared.activeNodes[bundleID]?.spectrumTap
            )
            .opacity(isEQBypassed ? 0.4 : 1.0)
            .allowsHitTesting(!isEQBypassed)
        }
        .padding(.vertical, DS.s)
        .animation(.easeInOut(duration: 0.2), value: isEQBypassed)
    }

    private func toggleMute() {
        AudioEngineManager.shared.setMute(bundleID: bundleID, muted: !isMuted)
    }

    private func toggleEQBypass() {
        AudioEngineManager.shared.setEQBypass(bundleID: bundleID, bypassed: !isEQBypassed)
    }
}

// MARK: - Custom Slider for Audio Controls
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
                    .fill(DS.surfaceHi)
                    .frame(height: 6)
                    .overlay(
                        Capsule()
                            .strokeBorder(DS.stroke, lineWidth: DS.borderWidth)
                    )
                
                // Active track with gradient
                Capsule()
                    .fill(DS.sliderGradient)
                    .frame(width: max(0, filledWidth), height: 6)
                
                // Thumb
                Circle()
                    .fill(DS.control)
                    .frame(width: thumbSize, height: thumbSize)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.8), lineWidth: 1.0)
                    )
                    .shadow(color: Color.black.opacity(0.2), radius: 3, x: 0, y: 1)
                    .scaleEffect(isDragging ? 1.15 : (isHovered ? 1.08 : 1.0))
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

