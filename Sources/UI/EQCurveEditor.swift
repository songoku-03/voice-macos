import SwiftUI
import AVFoundation
import Engine

@available(macOS 14.2, *)
public struct EQCurveEditor: View {
    let eqController: EQController
    let spectrum: SpectrumTap?

    // Binding to refresh state
    @State private var bandGains: [Float] = Array(repeating: 0.0, count: 10)
    @State private var bandFrequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    @State private var activeDragIndex: Int? = nil
    @State private var spectrumLevels: [Float] = Array(repeating: 0.0, count: 10)

    private let minFreq: Float = 20.0
    private let maxFreq: Float = 20000.0
    private let minGain: Float = -24.0
    private let maxGain: Float = 24.0

    // ~30fps refresh for the spectrum bars.
    private let spectrumTimer = Timer.publish(every: 0.033, on: .main, in: .common).autoconnect()

    public init(eqController: EQController, spectrum: SpectrumTap? = nil) {
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
                    
                    // 0dB Center line (thick cartoon style)
                    Path { path in
                        let y = yForGain(0.0, height: size.height)
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    .stroke(DS.stroke.opacity(0.35), lineWidth: DS.borderWidth)

                    // 1b. Live spectrum bars (move with the music)
                    ForEach(0..<10, id: \.self) { idx in
                        let barW = max(3, size.width / 15)
                        let level = CGFloat(idx < spectrumLevels.count ? spectrumLevels[idx] : 0)
                        let h = max(1, level * size.height * 0.95)
                        let x = xForFreq(bandFrequencies[idx], width: size.width)
                        RoundedRectangle(cornerRadius: 2.0)
                            .fill(
                                LinearGradient(
                                    colors: [DS.accentPink.opacity(0.24), DS.accentPink.opacity(0.01)],
                                    startPoint: .bottom,
                                    endPoint: .top
                                )
                            )
                            .frame(width: barW, height: h)
                            .position(x: x, y: size.height - h / 2)
                    }

                    // 2. Draw Response Curve (Thick cartoon curve)
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
                        style: StrokeStyle(lineWidth: 4.0, lineCap: .round, lineJoin: .round)
                    )

                    // 3. Draw Interactive Band Nodes (Yellow bubbles with dark outlines)
                    ForEach(0..<10, id: \.self) { idx in
                        let x = xForFreq(bandFrequencies[idx], width: size.width)
                        let y = yForGain(bandGains[idx], height: size.height)
                        let isDragging = activeDragIndex == idx

                        ZStack {
                            if isDragging {
                                Circle()
                                    .fill(DS.accentPink.opacity(0.25))
                                    .frame(width: 26, height: 26)
                            }
                            
                            Circle()
                                .fill(isDragging ? DS.accentPink : DS.accent)
                                .frame(width: isDragging ? 14 : 11, height: isDragging ? 14 : 11)
                                .overlay(
                                    Circle()
                                        .strokeBorder(DS.stroke, lineWidth: DS.borderWidth)
                                )
                                .background(
                                    Circle()
                                        .fill(DS.shadowColor)
                                        .offset(x: 1.5, y: 1.5)
                                )
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
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            let location = val.location
                            let dragIdx: Int
                            if let active = activeDragIndex {
                                dragIdx = active
                            } else {
                                // Find closest node within touch radius
                                var closestIdx = 0
                                var minDistance: CGFloat = CGFloat.infinity
                                for idx in 0..<10 {
                                    let x = xForFreq(bandFrequencies[idx], width: size.width)
                                    let y = yForGain(bandGains[idx], height: size.height)
                                    let dist = hypot(location.x - x, location.y - y)
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
                            
                            // Update values
                            let newFreq = freqForX(Float(location.x), width: size.width)
                            let newGain = gainForY(Float(location.y), height: size.height)
                            
                            updateBand(index: dragIdx, freq: newFreq, gain: newGain)
                        }
                        .onEnded { _ in
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                activeDragIndex = nil
                            }
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
        }
        .padding(.horizontal, DS.xs)
        .onAppear {
            readBands()
        }
        .onReceive(spectrumTimer) { _ in
            guard let spectrum = spectrum else { return }
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
                bandFrequencies[i] = b.frequency
            }
        }
    }
    
    private func updateBand(index: Int, freq: Float, gain: Float) {
        let clampedFreq = max(minFreq, min(maxFreq, freq))
        let clampedGain = max(minGain, min(maxGain, gain))
        
        bandFrequencies[index] = clampedFreq
        bandGains[index] = clampedGain
        
        eqController.setBand(
            index: index,
            frequency: clampedFreq,
            gain: clampedGain,
            bandwidth: 1.0, // standard Q width
            type: .parametric,
            bypass: false
        )
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
