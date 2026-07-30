import Foundation
import AppKit
import CoreAudio

public struct AudioProcess: Identifiable, Hashable {
    public var id: String { "\(audioObjectID)-\(pid)-\(bundleID)" }
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

    public static func normalizeBundleID(_ bundleID: String) -> String {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = trimmed.components(separatedBy: ".")
        while parts.count > 2, let last = parts.last {
            let lower = last.lowercased()
            if lower == "helper" || lower == "renderer" {
                parts.removeLast()
            } else {
                break
            }
        }
        if parts.isEmpty {
            return trimmed
        }
        return parts.joined(separator: ".")
    }

    public init(audioObjectID: AudioObjectID, pid: pid_t, bundleID: String, name: String, icon: NSImage?, isRunningOutput: Bool, isRegularApp: Bool = false) {
        self.audioObjectID = audioObjectID
        self.pid = pid
        let trimmedBundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bundleID = AudioProcess.normalizeBundleID(trimmedBundle)
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func isHelperLikeName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        
        let genericKeywords = ["helper", "renderer"]
        for keyword in genericKeywords {
            if lower == keyword {
                return true
            }
            if lower.hasSuffix(keyword) {
                let index = lower.index(lower.endIndex, offsetBy: -keyword.count)
                if index > lower.startIndex {
                    let precedingCharIndex = lower.index(before: index)
                    let precedingChar = lower[precedingCharIndex]
                    if !precedingChar.isLetter && !precedingChar.isNumber {
                        return true
                    }
                }
            }
        }
        
        let specificKeywords = ["gpuprocess", "webcontent", "serviceworker"]
        let cleanName = lower.replacingOccurrences(of: " ", with: "")
        for keyword in specificKeywords {
            if cleanName.contains(keyword) {
                return true
            }
        }
        return false
    }

    private static func isLocalizedName(_ name: String, bundleID: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        
        if isHelperLikeName(trimmed) {
            return false
        }
        
        let lowerName = trimmed.lowercased()
        if lowerName.hasPrefix("process ") {
            return false
        }
        
        if trimmed.contains(".") {
            if !bundleID.isEmpty && trimmed.caseInsensitiveCompare(bundleID) == .orderedSame {
                return false
            }
            let isBundlePrefix = lowerName.hasPrefix("com.") || lowerName.hasPrefix("org.") || lowerName.hasPrefix("net.") || lowerName.hasPrefix("co.") || lowerName.hasPrefix("io.") || lowerName.hasPrefix("apple.")
            if isBundlePrefix && !trimmed.contains(" ") {
                return false
            }
            let pathExtension = trimmed.components(separatedBy: ".").last?.lowercased() ?? ""
            let blacklistExtensions = ["app", "plist", "dylib", "framework", "sh", "py", "json", "xml", "bin", "dmg", "exe", "dll", "helper", "renderer", "bundle"]
            if blacklistExtensions.contains(pathExtension) && !trimmed.contains(" ") {
                return false
            }
            let dotCount = trimmed.filter { $0 == "." }.count
            if dotCount > 1 && !trimmed.contains(" ") {
                return false
            }
        }
        
        return true
    }

    private static func isBetterRepresentative(_ lhs: AudioProcess, than rhs: AudioProcess) -> Bool {
        // 1. Prioritize processes outputting audio
        if lhs.isRunningOutput != rhs.isRunningOutput {
            return lhs.isRunningOutput
        }
        // 2. Prioritize regular applications
        if lhs.isRegularApp != rhs.isRegularApp {
            return lhs.isRegularApp
        }
        // 3. Prioritize processes with icons
        let lhsHasIcon = lhs.icon != nil
        let rhsHasIcon = rhs.icon != nil
        if lhsHasIcon != rhsHasIcon {
            return lhsHasIcon
        }
        // 4. Prioritize non-helper-like names over helper-like names
        let lhsIsHelper = isHelperLikeName(lhs.name)
        let rhsIsHelper = isHelperLikeName(rhs.name)
        if lhsIsHelper != rhsIsHelper {
            return !lhsIsHelper
        }
        
        // 5. Bundle ID Containment Heuristic
        let targetBundleID = !lhs.bundleID.isEmpty ? lhs.bundleID : rhs.bundleID
        if !targetBundleID.isEmpty && (lhs.bundleID.isEmpty || rhs.bundleID.isEmpty || lhs.bundleID.caseInsensitiveCompare(rhs.bundleID) == .orderedSame) {
            let lhsClean = lhs.name.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ".", with: "")
            let rhsClean = rhs.name.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ".", with: "")
            let bundleClean = targetBundleID.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ".", with: "")
            
            if !lhsClean.isEmpty && !rhsClean.isEmpty {
                let lhsMatches = bundleClean.contains(lhsClean)
                let rhsMatches = bundleClean.contains(rhsClean)
                if lhsMatches != rhsMatches {
                    return lhsMatches
                } else if lhsMatches {
                    if lhsClean.count != rhsClean.count {
                        return lhsClean.count > rhsClean.count
                    }
                }
            }
        }
        
        // 6. Case-insensitive Prefix/Shorter Name Heuristic
        let lhsTrimmed = lhs.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsTrimmed = rhs.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lhsTrimmed.isEmpty && !rhsTrimmed.isEmpty {
            let lhsLower = lhsTrimmed.lowercased()
            let rhsLower = rhsTrimmed.lowercased()
            if lhsLower.hasPrefix(rhsLower) || rhsLower.hasPrefix(lhsLower) {
                if lhsTrimmed.count != rhsTrimmed.count {
                    return lhsTrimmed.count < rhsTrimmed.count
                }
            }
        }
        
        // 7. Prioritize localized names
        let lhsIsLocalized = isLocalizedName(lhs.name, bundleID: lhs.bundleID)
        let rhsIsLocalized = isLocalizedName(rhs.name, bundleID: rhs.bundleID)
        if lhsIsLocalized != rhsIsLocalized {
            return lhsIsLocalized
        }
        
        // 8. Casing Tie-breaker: Prioritize capitalized names over lowercase if case-insensitively equal
        let lhsLower = lhs.name.lowercased()
        let rhsLower = rhs.name.lowercased()
        if lhsLower == rhsLower {
            let lhsStartsUpper = lhs.name.first?.isUppercase ?? false
            let rhsStartsUpper = rhs.name.first?.isUppercase ?? false
            if lhsStartsUpper != rhsStartsUpper {
                return lhsStartsUpper
             }
        }
        
        // 9. Prioritize shorter bundle ID when bundle IDs are compatible (e.g. main app vs helper/plugin)
        let lhsHasBundleID = !lhs.bundleID.isEmpty
        let rhsHasBundleID = !rhs.bundleID.isEmpty
        if lhsHasBundleID && rhsHasBundleID && areBundleIDsCompatible(lhs.bundleID, rhs.bundleID) && lhs.bundleID.caseInsensitiveCompare(rhs.bundleID) != .orderedSame {
            return lhs.bundleID.count < rhs.bundleID.count
        }
        if lhsHasBundleID != rhsHasBundleID {
            return lhsHasBundleID
        }
        // Deterministic fallback
        if lhs.audioObjectID != rhs.audioObjectID {
            return lhs.audioObjectID < rhs.audioObjectID
        }
        return lhs.pid < rhs.pid
    }

    private static func areBundleIDsCompatible(_ bI: String, _ bJ: String) -> Bool {
        if bI.isEmpty || bJ.isEmpty {
            return true
        }
        let lowerI = bI.lowercased()
        let lowerJ = bJ.lowercased()
        if lowerI == lowerJ {
            return true
        }
        if lowerI.hasPrefix(lowerJ + ".") || lowerJ.hasPrefix(lowerI + ".") {
            return true
        }
        return false
    }

    /// Collapse raw audio-process objects into one visible row per app.
    ///
    /// Multi-process apps (Chrome, Discord) expose several audio objects that all resolve
    /// to the same app; this keeps regular foreground apps (or anything currently tapped),
    /// dedupes by name preferring the object that's outputting (so its tap captures live
    /// audio), and sorts by name. Pure function — unit-testable without CoreAudio.
    public static func visibleRows(from processes: [AudioProcess], tappedBundleIDs: Set<String>) -> [AudioProcess] {
        let candidates = processes.filter { $0.isRegularApp || tappedBundleIDs.contains($0.bundleID) }
        let n = candidates.count
        guard n > 0 else { return [] }
        
        let lowercasedNames = candidates.map { $0.name.lowercased() }
        let lowercasedBundles = candidates.map { $0.bundleID.lowercased() }
        
        var parent = Array(0..<n)
        var groupLowerBundle = lowercasedBundles
        
        func find(_ i: Int) -> Int {
            var root = i
            while root != parent[root] {
                root = parent[root]
            }
            var curr = i
            while curr != root {
                let nxt = parent[curr]
                parent[curr] = root
                curr = nxt
            }
            return root
        }
        
        func union(_ i: Int, _ j: Int) {
            let rootI = find(i)
            let rootJ = find(j)
            if rootI != rootJ {
                let bI = groupLowerBundle[rootI]
                let bJ = groupLowerBundle[rootJ]
                if !areBundleIDsCompatible(bI, bJ) {
                    return // Prevent bridging different apps
                }
                parent[rootI] = rootJ
                if groupLowerBundle[rootJ].isEmpty {
                    groupLowerBundle[rootJ] = bI
                }
            }
        }
        
        for i in 0..<n {
            for j in (i + 1)..<n {
                let a = candidates[i]
                let b = candidates[j]
                
                let sameBundle = !a.bundleID.isEmpty && !b.bundleID.isEmpty && lowercasedBundles[i] == lowercasedBundles[j]
                let sameName = !a.name.isEmpty && !b.name.isEmpty && lowercasedNames[i] == lowercasedNames[j]
                
                if sameBundle || sameName {
                    union(i, j)
                }
            }
        }
        
        var groups: [Int: [AudioProcess]] = [:]
        for i in 0..<n {
            let root = find(i)
            groups[root, default: []].append(candidates[i])
        }
        
        var representatives: [AudioProcess] = []
        for (_, group) in groups {
            guard let first = group.first else { continue }
            var best = first
            for proc in group.dropFirst() {
                if isBetterRepresentative(proc, than: best) {
                    best = proc
                }
            }
            representatives.append(best)
        }
        
        return representatives.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
