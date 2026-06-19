import SwiftUI
import AVFoundation
import Engine

@available(macOS 14.2, *)
public struct EQCurveEditor: View {
    let eqController: EQController
    
    // Binding to refresh state
    @State private var bandGains: [Float] = Array(repeating: 0.0, count: 10)
    @State private var bandFrequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    @State private var activeDragIndex: Int? = nil
    
    private let minFreq: Float = 20.0
    private let maxFreq: Float = 20000.0
    private let minGain: Float = -24.0
    private let maxGain: Float = 24.0
    
    public init(eqController: EQController) {
        self.eqController = eqController
    }
    
    public var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let size = geo.size
                
                ZStyle {
                    // 1. Draw Grid Lines
                    Path { path in
                        // Horizontal Gain Grid Lines (-12dB, 0dB, 12dB)
                        for gainVal in [-12.0, 0.0, 12.0] as [Float] {
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
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    
                    // 2. Draw Response Curve
                    Path { path in
                        let points = (0...Int(size.width)).map { screenX -> CGPoint in
                            let freq = freqForX(Float(screenX), width: size.width)
                            // Estimate composite gain at this frequency
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
                        LinearGradient(
                            colors: [.cyan, .purple],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        lineWidth: 3
                    )
                    
                    // 3. Draw Interactive Band Nodes
                    ForEach(0..<10, id: \.self) { idx in
                        let x = xForFreq(bandFrequencies[idx], width: size.width)
                        let y = yForGain(bandGains[idx], height: size.height)
                        let isDragging = activeDragIndex == idx
                        
                        Circle()
                            .fill(isDragging ? Color.cyan : Color.white)
                            .frame(width: 14, height: 14)
                            .shadow(color: Color.black.opacity(0.3), radius: 3)
                            .overlay(
                                Circle()
                                    .stroke(Color.purple, lineWidth: 2)
                            )
                            .position(x: x, y: y)
                    }
                }
                .background(Color.black.opacity(0.4))
                .cornerRadius(8)
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
                                activeDragIndex = dragIdx
                            }
                            
                            // Update values
                            let newFreq = freqForX(Float(location.x), width: size.width)
                            let newGain = gainForY(Float(location.y), height: size.height)
                            
                            updateBand(index: dragIdx, freq: newFreq, gain: newGain)
                        }
                        .onEnded { _ in
                            activeDragIndex = nil
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
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white.opacity(0.4))
        }
        .padding(.horizontal, 4)
        .onAppear {
            readBands()
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
