import SwiftUI
import Core

@available(macOS 14.2, *)
public struct ProcessListView: View {
    let processes: [AudioProcess]
    
    public init(processes: [AudioProcess]) {
        self.processes = processes
    }
    
    public var body: some View {
        ScrollView {
            VStack(spacing: DS.s) {
                if processes.isEmpty {
                    VStack(spacing: DS.l) {
                        ZStack {
                            Circle()
                                .fill(DS.accent.opacity(0.06))
                                .frame(width: 54, height: 54)
                            
                            Image(systemName: "music.note.house.fill")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(DS.accentGradient)
                                .shadow(color: DS.accent.opacity(0.35), radius: 5)
                        }

                        VStack(spacing: DS.xs) {
                            Text("No Audio Apps Running")
                                .font(DSFont.rowTitle)
                                .foregroundStyle(DS.textPrimary)
                            Text("Start playing music from Spotify, Youtube or Chrome")
                                .font(DSFont.caption)
                                .foregroundStyle(DS.textSecondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 240)
                        }
                    }
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(processes) { process in
                        AppRowView(process: process)
                    }
                }
            }
            .padding(.horizontal, DS.s + 2)
            .padding(.vertical, DS.s)
        }
        .frame(maxHeight: 300)
    }
}
