import SwiftUI
import Engine
import Core

@available(macOS 14.2, *)
public struct AppRowView: View {
    let process: AudioProcess

    @State private var isExpanded = false
    @State private var engineManager = AudioEngineManager.shared
    @State private var isHovered = false
    @State private var isToggling = false

    private var isTapped: Bool {
        engineManager.activeNodes[process.bundleID] != nil
    }

    public init(process: AudioProcess) {
        self.process = process
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Main row header
            HStack(spacing: DS.m) {
                // App icon
                Group {
                    if let icon = process.icon {
                        Image(nsImage: icon)
                            .resizable()
                    } else {
                        Image(systemName: "app.dashed")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(DS.textSecondary)
                            .padding(2)
                    }
                }
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: DS.radiusS))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusS)
                        .strokeBorder(DS.stroke, lineWidth: 1.0)
                )

                // Name + live status
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DS.xs + 2) {
                        Text(process.name)
                            .font(DSFont.rowTitle)
                            .foregroundStyle(isTapped ? DS.textPrimary : DS.textSecondary)
                            .lineLimit(1)
                        
                        if process.isRunningOutput {
                            Circle()
                                .fill(DS.playing)
                                .frame(width: 6, height: 6)
                        }
                    }
                }

                Spacer(minLength: DS.s)

                // VU meter — only animates when tapped AND producing audio
                VUMeterView(isActive: isTapped && process.isRunningOutput)

                // Capture toggle (playful bubble button)
                Button(action: toggleTap) {
                    ZStack {
                        Circle()
                            .fill(isTapped ? DS.controlDim : Color.clear)
                            .frame(width: 24, height: 24)
                        
                        if isToggling {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: isTapped ? "power.circle.fill" : "power.circle")
                                .font(.system(size: 19, weight: .bold))
                                .foregroundStyle(isTapped ? DS.control : DS.textTertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isToggling)
                .help(isTapped ? "Stop capturing this app" : "Capture this app's audio")

                // Expand chevron
                Button(action: { 
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { 
                        isExpanded.toggle() 
                    } 
                }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(isTapped ? DS.textSecondary : DS.textTertiary.opacity(0.4))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .frame(width: 20, height: 20)
                        .background(isExpanded ? DS.controlDim : Color.clear)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!isTapped)
            }
            .padding(.horizontal, DS.m)
            .padding(.vertical, DS.s + 3)
            
            // Expanded controls
            if isExpanded && isTapped {
                if let appNode = engineManager.activeNodes[process.bundleID] {
                    AppControlsView(bundleID: process.bundleID, eqController: appNode.eqController)
                        .padding(.horizontal, DS.m)
                        .padding(.bottom, DS.m)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .background(
            isExpanded ? DS.cardBgActive : (isHovered ? DS.cardBgHover : DS.cardBg)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusM))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusM)
                .strokeBorder(DS.stroke, lineWidth: DS.borderWidth)
        )
        .cartoonShadow(radius: DS.radiusM)
        .padding(.horizontal, DS.m)
        .padding(.vertical, DS.s)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }

    private func toggleTap() {
        guard !isToggling else { return }
        isToggling = true
        
        Task {
            if isTapped {
                isExpanded = false
                engineManager.userStopAppTapping(bundleID: process.bundleID)
            } else {
                engineManager.startAppTapping(bundleID: process.bundleID, pid: process.pid)
                // Auto expand only if tapped successfully
                if engineManager.activeNodes[process.bundleID] != nil {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        isExpanded = true
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
            isToggling = false
        }
    }
}

// Animated VU meter — cute fat capsules
struct VUMeterView: View {
    let isActive: Bool
    @State private var levels: [CGFloat] = Array(repeating: 0.1, count: 6)

    private static let timer = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    private func color(_ idx: Int) -> Color {
        idx > 4 ? DS.danger : (idx > 3 ? DS.warning : DS.playing)
    }

    var body: some View {
        HStack(spacing: 2.0) {
            ForEach(0..<6, id: \.self) { idx in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isActive ? color(idx) : DS.stroke.opacity(0.4))
                    .frame(width: 3.5, height: levels[idx] * 12)
            }
        }
        .frame(width: 31, height: 12)
        .onReceive(Self.timer) { _ in
            guard isActive else {
                let defaultLevels = Array(repeating: CGFloat(0.1), count: 6)
                if levels != defaultLevels {
                    withAnimation(.easeOut(duration: 0.2)) {
                        levels = defaultLevels
                    }
                }
                return
            }
            withAnimation(.linear(duration: 0.08)) {
                levels = (0..<6).map { _ in CGFloat.random(in: 0.15...1.0) }
            }
        }
    }
}
