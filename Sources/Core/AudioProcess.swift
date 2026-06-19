import Foundation
import AppKit
import CoreAudio

public struct AudioProcess: Identifiable, Hashable {
    public var id: AudioObjectID { audioObjectID }
    public let audioObjectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String
    public let name: String
    public let icon: NSImage?
    public var isRunningOutput: Bool
    
    public init(audioObjectID: AudioObjectID, pid: pid_t, bundleID: String, name: String, icon: NSImage?, isRunningOutput: Bool) {
        self.audioObjectID = audioObjectID
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.icon = icon
        self.isRunningOutput = isRunningOutput
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(audioObjectID)
        hasher.combine(pid)
    }
    
    public static func == (lhs: AudioProcess, rhs: AudioProcess) -> Bool {
        return lhs.audioObjectID == rhs.audioObjectID && lhs.pid == rhs.pid
    }
}
