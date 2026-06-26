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
    // True when this audio object belongs to a regular foreground app (Spotify, Chrome…)
    // that is currently running. Drives list visibility: an open audio-capable app shows
    // even while silent, and disappears when the app quits. System daemons stay false.
    public var isRegularApp: Bool

    public init(audioObjectID: AudioObjectID, pid: pid_t, bundleID: String, name: String, icon: NSImage?, isRunningOutput: Bool, isRegularApp: Bool = false) {
        self.audioObjectID = audioObjectID
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.icon = icon
        self.isRunningOutput = isRunningOutput
        self.isRegularApp = isRegularApp
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(audioObjectID)
        hasher.combine(pid)
    }
    
    public static func == (lhs: AudioProcess, rhs: AudioProcess) -> Bool {
        return lhs.audioObjectID == rhs.audioObjectID && lhs.pid == rhs.pid
    }

    /// Collapse raw audio-process objects into one visible row per app.
    ///
    /// Multi-process apps (Chrome, Discord) expose several audio objects that all resolve
    /// to the same app; this keeps regular foreground apps (or anything currently tapped),
    /// dedupes by name preferring the object that's outputting (so its tap captures live
    /// audio), and sorts by name. Pure function — unit-testable without CoreAudio.
    public static func visibleRows(from processes: [AudioProcess], tappedBundleIDs: Set<String>) -> [AudioProcess] {
        let candidates = processes.filter { $0.isRegularApp || tappedBundleIDs.contains($0.bundleID) }
        var byApp: [String: AudioProcess] = [:]
        for proc in candidates {
            if let existing = byApp[proc.name] {
                if proc.isRunningOutput && !existing.isRunningOutput {
                    byApp[proc.name] = proc
                }
            } else {
                byApp[proc.name] = proc
            }
        }
        return byApp.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
