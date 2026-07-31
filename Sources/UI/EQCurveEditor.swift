import SwiftUI
import AVFoundation
import Engine

@available(macOS 14.2, *)
public struct EQCurveEditor: View {
    let bundleID: String?
    let eqController: EQController
    let spectrum: SpectrumTap?

    private static let defaultFrequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    // Binding to refresh state
    @State private var bandGains: [Float] = Array(repeating: 0.0, count: 10)
    @State private var bandFrequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    @State private var activeDragIndex: Int? = nil
    @State private var spectrumLevels: [Float] = Array(repeating: 0.0, count: 10)

    @State private var isObserved: Bool = false
    @State private var customHzText: String = ""

    private let minFreq: Float = 20.0
    private let maxFreq: Float = 20000.0
    private let minGain: Float = -24.0
    private let maxGain: Float = 24.0

    // ~30fps refresh for the spectrum bars.
    private static let spectrumTimer = Timer.publish(every: 0.033, on: .main, in: .common).autoconnect()

    public init(bundleID: String? = nil, eqController: EQController, spectrum: SpectrumTap? = nil) {
        self.bundleID = bundleID
        self.eqController = eqController
        self.spectrum = spectrum
    }
    
    public var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let size = geo.size
                
                ZStyle {
                    // 1. Draw Grid Lines
                    Path { path in
                        // Horizontal Gain Grid Lines (-12dB, 12dB)
                        for gainVal in [-12.0, 12.0] as [Float] {
                            let y = yForGain(gainVal, height: size.height)
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: size.width, y: y))
                        }
                        
                        // Vertical Frequency Grid Lines (100Hz, 1kHz, 10kHz)
                        for freqVal in [100.0, 1000.0, 10000.0] as [Float] {
                            let x = xForFreq(freqVal, width: size.width)
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: size.height))
                        }
                    }
                    .stroke(DS.stroke.opacity(0.18), lineWidth: 1.0)
                    
                    // 0dB Center line
                    Path { path in
                        let y = yForGain(0.0, height: size.height)
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    .stroke(DS.stroke.opacity(0.4), lineWidth: 1.0)

                    // 1b. Live spectrum bars (move with the music)
                    ForEach(0..<10, id: \.self) { idx in
                        let barW = max(3, size.width / 15)
                        let level = CGFloat(idx < spectrumLevels.count ? spectrumLevels[idx] : 0)
                        let h = max(1, level * size.height * 0.95)
                        let x = xForFreq(bandFrequencies[idx], width: size.width)
                        RoundedRectangle(cornerRadius: 2.0)
                            .fill(
                                LinearGradient(
                                    colors: [DS.accentPink.opacity(0.25), DS.accentPink.opacity(0.01)],
                                    startPoint: .bottom,
                                    endPoint: .top
                                )
                            )
                            .frame(width: barW, height: h)
                            .position(x: x, y: size.height - h / 2)
                    }

                    // 2. Draw Response Curve
                    Path { path in
                        let points = (0...Int(size.width)).map { screenX -> CGPoint in
                            let freq = freqForX(Float(screenX), width: size.width)
                            let gain = compositeGainAt(frequency: freq)
                            let y = yForGain(gain, height: size.height)
                            return CGPoint(x: CGFloat(screenX), y: y)
                        }
                        
                        if let first = points.first {
                            path.move(to: first)
                            for pt in points.dropFirst() {
                                path.addLine(to: pt)
                            }
                        }
                    }
                    .stroke(
                        DS.eqGradient,
                        style: StrokeStyle(lineWidth: 3.0, lineCap: .round, lineJoin: .round)
                    )

                    // 3. Draw Interactive Band Nodes (Glowing control nodes)
                    ForEach(0..<10, id: \.self) { idx in
                        let x = xForFreq(bandFrequencies[idx], width: size.width)
                        let y = yForGain(bandGains[idx], height: size.height)
                        let isDragging = activeDragIndex == idx

                        ZStack {
                            if isDragging {
                                Circle()
                                    .fill(DS.accentPink.opacity(0.3))
                                    .frame(width: 24, height: 24)
                            }
                            
                            Circle()
                                .fill(isDragging ? DS.control : DS.surface)
                                .frame(width: isDragging ? 13 : 10, height: isDragging ? 13 : 10)
                                .overlay(
                                    Circle()
                                        .strokeBorder(DS.control, lineWidth: 1.5)
                                )
                                .shadow(color: Color.black.opacity(0.2), radius: 2, x: 0, y: 1)
                        }
                        .position(x: x, y: y)
                    }
                }
                .background(DS.surface)
                .clipShape(RoundedRectangle(cornerRadius: DS.radiusM))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusM)
                        .strokeBorder(DS.stroke, lineWidth: DS.borderWidth)
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            let location = val.location
                            let dragIdx: Int
                            if let active = activeDragIndex {
                                dragIdx = active
                            } else {
                                // Find node with closest X position
                                var closestIdx = 0
                                var minDistance: CGFloat = .infinity
                                for idx in 0..<10 {
                                    let x = xForFreq(bandFrequencies[idx], width: size.width)
                                    let dist = abs(location.x - x)
                                    if dist < minDistance {
                                        minDistance = dist
                                        closestIdx = idx
                                    }
                                }
                                dragIdx = closestIdx
                                withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                                    activeDragIndex = dragIdx
                                }
                            }
                            
                            // Update gain for the selected band
                            let newGain = gainForY(Float(location.y), height: size.height)
                            updateBand(index: dragIdx, gain: newGain)
                        }
                        .onEnded { _ in
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                activeDragIndex = nil
                            }
                            persistState()
                        }
                )
            }
            .frame(height: 120)
            
            // Frequency / Gain labels
            HStack {
                Text("20 Hz")
                Spacer()
                Text("1 kHz")
                Spacer()
                Text("20 kHz")
            }
            .font(DSFont.mono)
            .foregroundStyle(DS.textTertiary)

            // Quick Hz Target Presets
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.xs) {
                    presetChip("Flat") {
                        eqController.setFlat()
                        readBands()
                        persistState()
                    }
                    presetChip("🎯 40 Hz") {
                        eqController.applyTargetFrequency(hz: 40)
                        readBands()
                        persistState()
                    }
                    presetChip("🌙 432 Hz") {
                        eqController.applyTargetFrequency(hz: 432)
                        readBands()
                        persistState()
                    }
                    presetChip("🔊 Bass") {
                        eqController.applyTargetFrequency(hz: 80, maxBoost: 10)
                        readBands()
                        persistState()
                    }
                    presetChip("🎙️ Vocal") {
                        eqController.applyTargetFrequency(hz: 1500, maxBoost: 8)
                        readBands()
                        persistState()
                    }
                }
            }

            // Custom Hz Input
            HStack(spacing: DS.xs) {
                Text("Mốc Hz:")
                    .font(DSFont.caption)
                    .foregroundStyle(DS.textSecondary)

                TextField("Ví dụ 432", text: $customHzText)
                    .textFieldStyle(.plain)
                    .font(DSFont.mono)
                    .foregroundStyle(DS.textPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(DS.surface)
                    .clipShape(RoundedRectangle(cornerRadius: DS.radiusS))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.radiusS)
                            .strokeBorder(DS.stroke, lineWidth: DS.borderWidth)
                    )
                    .frame(width: 75)
                    .onSubmit { applyCustomHz() }

                Button(action: applyCustomHz) {
                    Text("Áp dụng")
                        .font(DSFont.caption)
                        .foregroundStyle(DS.control)
                        .padding(.horizontal, DS.s)
                        .padding(.vertical, 3)
                        .background(DS.control.opacity(0.12))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(DS.control.opacity(0.3), lineWidth: DS.borderWidth)
                        )
                }
                .buttonStyle(.plain)
                .disabled(customHzText.isEmpty)
                .hoverEffectHelper()
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, DS.xs)
        .onAppear {
            readBands()
            spectrum?.addObserver()
            isObserved = true
        }
        .onDisappear {
            if isObserved {
                isObserved = false
                spectrum?.removeObserver()
            }
        }
        .onReceive(Self.spectrumTimer) { _ in
            guard isObserved, let spectrum = spectrum else { return }
            spectrum.computeLevels()
            let latest = spectrum.levels()
            withAnimation(.easeOut(duration: 0.08)) {
                spectrumLevels = latest
            }
        }
    }
    
    // Grid conversions
    private func xForFreq(_ freq: Float, width: CGFloat) -> CGFloat {
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)
        let logVal = log10(max(minFreq, min(maxFreq, freq)))
        return CGFloat((logVal - logMin) / (logMax - logMin)) * width
    }
    
    private func freqForX(_ x: Float, width: CGFloat) -> Float {
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)
        let pct = max(0.0, min(1.0, x / Float(width)))
        let logVal = logMin + pct * (logMax - logMin)
        return pow(10.0, logVal)
    }
    
    private func yForGain(_ gain: Float, height: CGFloat) -> CGFloat {
        let pct = (gain - minGain) / (maxGain - minGain)
        return height - CGFloat(pct) * height
    }
    
    private func gainForY(_ y: Float, height: CGFloat) -> Float {
        let pct = 1.0 - max(0.0, min(1.0, y / Float(height)))
        return minGain + pct * (maxGain - minGain)
    }
    
    // Composite gain estimate (simplification of band-pass responses for drawing)
    private func compositeGainAt(frequency: Float) -> Float {
        var total: Float = 0.0
        for i in 0..<10 {
            let f0 = bandFrequencies[i]
            let g = bandGains[i]
            // Standard bandwidth / resonance curve approximation
            let q: Float = 1.0 // Q factor
            let x = frequency / f0
            let h = g / sqrt(1.0 + q * q * pow(x - 1.0 / x, 2))
            total += h
        }
        return max(minGain, min(maxGain, total))
    }
    
    private func readBands() {
        for i in 0..<10 {
            if i < eqController.avAudioUnit.bands.count {
                let b = eqController.avAudioUnit.bands[i]
                bandGains[i] = b.gain
                if b.frequency > 0 {
                    bandFrequencies[i] = b.frequency
                } else {
                    bandFrequencies[i] = Self.defaultFrequencies[i]
                }
            } else {
                bandFrequencies[i] = Self.defaultFrequencies[i]
            }
        }
    }
    
    private func updateBand(index: Int, gain: Float) {
        let clampedGain = max(minGain, min(maxGain, gain))
        bandGains[index] = clampedGain
        
        eqController.setBand(
            index: index,
            frequency: bandFrequencies[index],
            gain: clampedGain,
            bandwidth: 1.0, // standard Q width
            type: .parametric,
            bypass: false
        )
    }

    private func applyCustomHz() {
        guard let hz = Float(customHzText), hz >= 20 && hz <= 20000 else { return }
        withAnimation(.spring(response: 0.3)) {
            eqController.applyTargetFrequency(hz: hz)
            readBands()
            persistState()
        }
    }

    private func persistState() {
        if let bundleID = bundleID {
            AudioEngineManager.shared.persistEQForApp(bundleID: bundleID)
        }
    }

    @ViewBuilder
    private func presetChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: {
            withAnimation(.spring(response: 0.3)) {
                action()
            }
        }) {
            Text(title)
                .font(DSFont.caption)
                .foregroundStyle(DS.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(DS.surface)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(DS.stroke, lineWidth: DS.borderWidth)
                )
        }
        .buttonStyle(.plain)
        .hoverEffectHelper()
    }
}

// ZStack equivalent helper for SwiftUI in package environments
struct ZStyle<Content: View>: View {
    let content: () -> Content
    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }
    var body: some View {
        ZStack {
            content()
        }
    }
}
