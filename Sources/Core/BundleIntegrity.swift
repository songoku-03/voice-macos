import Foundation

public enum IneligibleLocationReason: Equatable, Sendable {
    case protectedFolder(String)
    case appTranslocation
}

public enum LocationEligibility: Equatable, Sendable {
    case eligible
    case ineligible(reason: IneligibleLocationReason)
}

public enum BundleDiagnostic: Equatable, Sendable {
    case ok
    case missing
    case ineligibleLocation(reason: IneligibleLocationReason)
    case staleExecutable
    case unknown
}

public struct BundleIntegrityChecker: Sendable {
    public static func classifyLocation(path: String, homeDirectoryPath: String = NSHomeDirectory()) -> LocationEligibility {
        let normalizedPath = (path as NSString).standardizingPath
        let normalizedHome = (homeDirectoryPath as NSString).standardizingPath
        
        if normalizedPath.contains("/AppTranslocation/") || normalizedPath.contains("AppTranslocation") {
            return .ineligible(reason: .appTranslocation)
        }
        
        let protectedFolders = ["Documents", "Desktop", "Downloads"]
        for folder in protectedFolders {
            let folderPath = (normalizedHome as NSString).appendingPathComponent(folder)
            if normalizedPath == folderPath || normalizedPath.hasPrefix(folderPath + "/") {
                return .ineligible(reason: .protectedFolder(folder))
            }
        }
        
        return .eligible
    }
    
    public static func checkExistence(bundlePath: String, fileManager: FileManager = .default) -> Bool {
        return fileManager.fileExists(atPath: bundlePath)
    }
    
    public static func checkStaleness(
        bundlePath: String,
        runningExecutablePath: String,
        fileManager: FileManager = .default
    ) -> Bool {
        guard fileManager.fileExists(atPath: bundlePath),
              fileManager.fileExists(atPath: runningExecutablePath) else {
            return false
        }
        
        let bundleURL = URL(fileURLWithPath: bundlePath)
        let bundle = Bundle(url: bundleURL)
        let executablePath = bundle?.executablePath ?? (bundlePath as NSString).appendingPathComponent("Contents/MacOS/SoundsSource")
        
        guard fileManager.fileExists(atPath: executablePath) else {
            return false
        }
        
        do {
            let runningAttr = try fileManager.attributesOfItem(atPath: runningExecutablePath)
            let diskAttr = try fileManager.attributesOfItem(atPath: executablePath)
            
            let runningModDate = runningAttr[.modificationDate] as? Date
            let diskModDate = diskAttr[.modificationDate] as? Date
            let runningSize = runningAttr[.size] as? Int64
            let diskSize = diskAttr[.size] as? Int64
            
            if runningExecutablePath == executablePath {
                let runningInode = runningAttr[.systemFileNumber] as? UInt
                let diskInode = diskAttr[.systemFileNumber] as? UInt
                if let rInode = runningInode, let dInode = diskInode, rInode != dInode {
                    return true
                }
            }
            
            if let rDate = runningModDate, let dDate = diskModDate, abs(rDate.timeIntervalSince(dDate)) > 1.0 {
                return true
            }
            if let rSize = runningSize, let dSize = diskSize, rSize != dSize {
                return true
            }
        } catch {
            return false
        }
        
        return false
    }
    
    public static func diagnose(
        bundleURL: URL? = Bundle.main.bundleURL,
        runningExecutablePath: String? = CommandLine.arguments.first,
        homeDirectoryPath: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> BundleDiagnostic {
        guard let bundleURL = bundleURL else {
            return .unknown
        }
        let bundlePath = bundleURL.path
        
        if !checkExistence(bundlePath: bundlePath, fileManager: fileManager) {
            return .missing
        }
        
        let eligibility = classifyLocation(path: bundlePath, homeDirectoryPath: homeDirectoryPath)
        if case .ineligible(let reason) = eligibility {
            return .ineligibleLocation(reason: reason)
        }
        
        if let runningPath = runningExecutablePath,
           checkStaleness(bundlePath: bundlePath, runningExecutablePath: runningPath, fileManager: fileManager) {
            return .staleExecutable
        }
        
        return .ok
    }
}
