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
            VStack(spacing: 0) {
                if processes.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "speaker.minus")
                            .font(.system(size: 26))
                            .foregroundColor(.white.opacity(0.15))
                        
                        Text("No apps playing audio")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.35))
                    }
                    .frame(height: 140)
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(processes) { process in
                        AppRowView(process: process)
                    }
                }
            }
        }
        .frame(maxHeight: 280)
    }
}
