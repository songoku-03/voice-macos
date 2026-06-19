import SwiftUI
import Engine
import Core

@available(macOS 14.2, *)
public struct AppRowView: View {
    let process: AudioProcess
    
    @State private var isExpanded = false
    @State private var engineManager = AudioEngineManager.shared

    private var isTapped: Bool {
        engineManager.activeNodes[process.bundleID] != nil
    }
    
    public init(process: AudioProcess) {
        self.process = process
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Main row header
            HStack(spacing: 10) {
                // App Icon
                if let icon = process.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "waveform")
                        .foregroundColor(.gray)
                        .font(.system(size: 14))
                        .frame(width: 20, height: 20)
                }
                
                // Process Name and status dot
                HStack(spacing: 6) {
                    Text(process.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                    
                    if process.isRunningOutput {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 5, height: 5)
                            .shadow(color: .green.opacity(0.6), radius: 2)
                    }
                }
                
                Spacer()
                
                // VU Meter showing audio flow
                VUMeterView(isActive: isTapped && process.isRunningOutput)
                
                // Tapped (Active capture) toggle button
                Button(action: toggleTap) {
                    Image(systemName: isTapped ? "power.circle.fill" : "power.circle")
                        .font(.system(size: 16))
                        .foregroundColor(isTapped ? .cyan : .white.opacity(0.3))
                }
                .buttonStyle(.plain)
                .help(isTapped ? "Mute process tap" : "Capture process audio")
                
                // Expand toggle arrow
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .disabled(!isTapped)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(Color.white.opacity(isExpanded ? 0.03 : 0.0))
            
            // Expanded controls
            if isExpanded && isTapped {
                if let appNode = engineManager.activeNodes[process.bundleID] {
                    AppControlsView(bundleID: process.bundleID, eqController: appNode.eqController)
                        .padding(.leading, 30)
                        .padding(.trailing, 10)
                        .padding(.bottom, 10)
                        .background(Color.white.opacity(0.03))
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            
            Divider()
                .background(Color.white.opacity(0.05))
        }
    }
    
    private func toggleTap() {
        if isTapped {
            isExpanded = false
            engineManager.stopAppTapping(bundleID: process.bundleID)
        } else {
            engineManager.startAppTapping(bundleID: process.bundleID, pid: process.pid)
        }
    }
}

// Custom animating VU Meter View
struct VUMeterView: View {
    let isActive: Bool
    @State private var levels: [CGFloat] = Array(repeating: 0.1, count: 6)
    
    // We use a lighter, low-overhead timer for animation
    private let timer = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()
    
    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<6, id: \.self) { idx in
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(isActive ? (idx > 4 ? Color.red : (idx > 3 ? Color.orange : Color.green)) : Color.white.opacity(0.1))
                    .frame(width: 2, height: levels[idx] * 12)
            }
        }
        .frame(width: 22, height: 12)
        .onReceive(timer) { _ in
            guard isActive else {
                levels = Array(repeating: 0.1, count: 6)
                return
            }
            withAnimation(.spring(response: 0.12, dampingFraction: 0.55)) {
                levels = (0..<6).map { _ in CGFloat.random(in: 0.15...1.0) }
            }
        }
    }
}
