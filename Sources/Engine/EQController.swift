import Foundation
import AVFoundation

@available(macOS 14.2, *)
public class EQController: @unchecked Sendable {
    public let avAudioUnit: AVAudioUnitEQ
    
    public init(avAudioUnit: AVAudioUnitEQ) {
        self.avAudioUnit = avAudioUnit
    }
    
    public func setBand(index: Int, frequency: Float, gain: Float, bandwidth: Float, type: AVAudioUnitEQFilterType = .parametric, bypass: Bool = false) {
        guard index >= 0 && index < avAudioUnit.bands.count else { return }
        let band = avAudioUnit.bands[index]
        band.filterType = type
        band.frequency = frequency
        band.gain = gain
        band.bandwidth = bandwidth
        band.bypass = bypass
    }
    
    public func setBypass(_ bypass: Bool) {
        avAudioUnit.bypass = bypass
    }
    
    public func getPresetData(volume: Float) -> EQPresetData {
        let bandsData = avAudioUnit.bands.map { band in
            EQBandData(
                frequency: band.frequency,
                gain: band.gain,
                bandwidth: band.bandwidth,
                filterType: band.filterType.rawValue,
                bypass: band.bypass
            )
        }
        return EQPresetData(bands: bandsData, bypass: avAudioUnit.bypass, volume: volume)
    }
    
    public func applyPresetData(_ data: EQPresetData) {
        avAudioUnit.bypass = data.bypass
        for (i, bandData) in data.bands.enumerated() {
            if i < avAudioUnit.bands.count {
                let band = avAudioUnit.bands[i]
                band.frequency = bandData.frequency
                band.gain = bandData.gain
                band.bandwidth = bandData.bandwidth
                if let type = AVAudioUnitEQFilterType(rawValue: bandData.filterType) {
                    band.filterType = type
                }
                band.bypass = bandData.bypass
            }
        }
    }
    
    // Set default flat EQ bands
    public func setFlat() {
        let defaultFrequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        for (i, freq) in defaultFrequencies.enumerated() {
            setBand(index: i, frequency: freq, gain: 0.0, bandwidth: 1.0, type: .parametric, bypass: false)
        }
        avAudioUnit.bypass = false
    }
}

public struct EQBandData: Codable, Hashable, Sendable {
    public let frequency: Float
    public let gain: Float
    public let bandwidth: Float
    public let filterType: Int
    public let bypass: Bool
    
    public init(frequency: Float, gain: Float, bandwidth: Float, filterType: Int, bypass: Bool) {
        self.frequency = frequency
        self.gain = gain
        self.bandwidth = bandwidth
        self.filterType = filterType
        self.bypass = bypass
    }
}

public struct EQPresetData: Codable, Hashable, Sendable {
    public let bands: [EQBandData]
    public let bypass: Bool
    public let volume: Float
    
    public init(bands: [EQBandData], bypass: Bool, volume: Float) {
        self.bands = bands
        self.bypass = bypass
        self.volume = volume
    }
    
    public static var flat: EQPresetData {
        let defaultFrequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        let bands = defaultFrequencies.map { freq in
            EQBandData(frequency: freq, gain: 0.0, bandwidth: 1.0, filterType: AVAudioUnitEQFilterType.parametric.rawValue, bypass: false)
        }
        return EQPresetData(bands: bands, bypass: false, volume: 1.0)
    }
}
