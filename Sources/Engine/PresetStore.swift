import Foundation
import Observation

@available(macOS 14.2, *)
@Observable
@MainActor
public class PresetStore: @unchecked Sendable {
    public static let shared = PresetStore()
    
    public private(set) var presets: [Preset] = []
    
    private let fileURL: URL
    
    private init() {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("SoundsSource")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        self.fileURL = directory.appendingPathComponent("presets.json")
        
        loadFromDisk()
        
        // If empty, add a default Flat preset
        if presets.isEmpty {
            let flatPreset = Preset(name: "Flat", isDefault: true, appSettings: [:])
            presets.append(flatPreset)
            saveToDisk()
        }
    }
    
    public func savePreset(name: String, appSettings: [String: EQPresetData]) {
        // If preset already exists, update it. Otherwise, append new one.
        if let idx = presets.firstIndex(where: { $0.name == name }) {
            var updated = presets[idx]
            updated.appSettings = appSettings
            presets[idx] = updated
        } else {
            let newPreset = Preset(name: name, isDefault: false, appSettings: appSettings)
            presets.append(newPreset)
        }
        saveToDisk()
    }
    
    public func deletePreset(name: String) {
        presets.removeAll { $0.name == name }
        // Ensure we still have at least one default or if we deleted the default, set flat as default
        if !presets.contains(where: { $0.isDefault }) && !presets.isEmpty {
            presets[0].isDefault = true
        }
        saveToDisk()
    }
    
    public func renamePreset(oldName: String, newName: String) {
        guard !newName.isEmpty && oldName != newName else { return }
        if let idx = presets.firstIndex(where: { $0.name == oldName }) {
            presets[idx].name = newName
            saveToDisk()
        }
    }
    
    public func setDefaultPreset(name: String) {
        for idx in 0..<presets.count {
            presets[idx].isDefault = (presets[idx].name == name)
        }
        saveToDisk()
    }
    
    public var defaultPreset: Preset? {
        return presets.first { $0.isDefault }
    }
    
    private func saveToDisk() {
        do {
            let data = try JSONEncoder().encode(presets)
            try data.write(to: fileURL, options: .atomic)
            print("PresetStore: Saved \(presets.count) presets to disk.")
        } catch {
            print("PresetStore: Failed to save presets: \(error)")
        }
    }
    
    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            self.presets = try JSONDecoder().decode([Preset].self, from: data)
            print("PresetStore: Loaded \(presets.count) presets from disk.")
        } catch {
            print("PresetStore: Failed to load presets: \(error)")
        }
    }
}

@available(macOS 14.2, *)
public struct Preset: Codable, Identifiable, Hashable {
    public var id: String { name }
    public var name: String
    public var isDefault: Bool
    public var appSettings: [String: EQPresetData] // Keyed by bundle ID
    
    public init(name: String, isDefault: Bool, appSettings: [String: EQPresetData]) {
        self.name = name
        self.isDefault = isDefault
        self.appSettings = appSettings
    }
}
