#!/usr/bin/env swift

import Foundation
import AVFoundation
import AudioToolbox

// ─── Inline RingBuffer ───
import libkern

final class RingBuffer {
    private let capacity: Int
    private let buffer: UnsafeMutablePointer<UInt8>
    private var writeOffset: Int = 0
    private var readOffset: Int = 0
    
    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        self.buffer.initialize(repeating: 0, count: capacity)
    }
    
    deinit { buffer.deallocate() }
    
    var bytesAvailableForRead: Int {
        OSMemoryBarrier()
        let w = writeOffset; let r = readOffset
        return w >= r ? (w - r) : (capacity - r + w)
    }
    
    var bytesAvailableForWrite: Int { capacity - 1 - bytesAvailableForRead }
    
    @discardableResult
    func write(_ data: UnsafeRawPointer, byteCount: Int) -> Int {
        let w = writeOffset; let r = readOffset
        let available = capacity - 1 - (w >= r ? (w - r) : (capacity - r + w))
        guard available >= byteCount else { return 0 }
        let rawBuffer = UnsafeMutableRawPointer(buffer)
        let firstPart = min(byteCount, capacity - w)
        rawBuffer.advanced(by: w).copyMemory(from: data, byteCount: firstPart)
        if firstPart < byteCount {
            rawBuffer.copyMemory(from: data.advanced(by: firstPart), byteCount: byteCount - firstPart)
        }
        OSMemoryBarrier()
        writeOffset = (w + byteCount) % capacity
        return byteCount
    }
    
    @discardableResult
    func writeOverwriting(_ data: UnsafeRawPointer, byteCount: Int) -> Int {
        guard byteCount > 0 && byteCount < capacity else { return 0 }
        let w = writeOffset; let r = readOffset
        let used = w >= r ? (w - r) : (capacity - r + w)
        let available = capacity - 1 - used
        if available < byteCount {
            let deficit = byteCount - available
            OSMemoryBarrier()
            readOffset = (r + deficit) % capacity
        }
        let rawBuffer = UnsafeMutableRawPointer(buffer)
        let firstPart = min(byteCount, capacity - w)
        rawBuffer.advanced(by: w).copyMemory(from: data, byteCount: firstPart)
        if firstPart < byteCount {
            rawBuffer.copyMemory(from: data.advanced(by: firstPart), byteCount: byteCount - firstPart)
        }
        OSMemoryBarrier()
        writeOffset = (w + byteCount) % capacity
        return byteCount
    }
    
    @discardableResult
    func read(_ dest: UnsafeMutableRawPointer, byteCount: Int) -> Int {
        let r = readOffset; let w = writeOffset
        let available = w >= r ? (w - r) : (capacity - r + w)
        guard available >= byteCount else { return 0 }
        let rawBuffer = UnsafeRawPointer(buffer)
        let firstPart = min(byteCount, capacity - r)
        dest.copyMemory(from: rawBuffer.advanced(by: r), byteCount: firstPart)
        if firstPart < byteCount {
            dest.advanced(by: firstPart).copyMemory(from: rawBuffer, byteCount: byteCount - firstPart)
        }
        OSMemoryBarrier()
        readOffset = (r + byteCount) % capacity
        return byteCount
    }
}

// ─── Mock SpectrumTap ───
class SpectrumTap {
    var sampleRate: Float = 48000
    func capture(_ ioData: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {}
}

// ─── Inline EQ Classes ───
struct EQBandData: Codable, Hashable, Sendable {
    let frequency: Float
    let gain: Float
    let bandwidth: Float
    let filterType: Int
    let bypass: Bool
}

struct EQPresetData: Codable, Hashable, Sendable {
    let bands: [EQBandData]
    let bypass: Bool
    let volume: Float
}

class EQController: @unchecked Sendable {
    let avAudioUnit: AVAudioUnitEQ
    init(avAudioUnit: AVAudioUnitEQ) {
        self.avAudioUnit = avAudioUnit
    }
    func setBand(index: Int, frequency: Float, gain: Float, bandwidth: Float, type: AVAudioUnitEQFilterType = .parametric, bypass: Bool = false) {
        guard index >= 0 && index < avAudioUnit.bands.count else { return }
        let band = avAudioUnit.bands[index]
        band.filterType = type
        band.frequency = frequency
        band.gain = gain
        band.bandwidth = bandwidth
        band.bypass = bypass
    }
    func setFlat() {
        let defaultFrequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        for (i, freq) in defaultFrequencies.enumerated() {
            setBand(index: i, frequency: freq, gain: 0.0, bandwidth: 1.0, type: .parametric, bypass: false)
        }
        avAudioUnit.bypass = false
    }
    func getPresetData(volume: Float) -> EQPresetData {
        let bandsData = avAudioUnit.bands.map { band in
            EQBandData(frequency: band.frequency, gain: band.gain, bandwidth: band.bandwidth, filterType: band.filterType.rawValue, bypass: band.bypass)
        }
        return EQPresetData(bands: bandsData, bypass: avAudioUnit.bypass, volume: volume)
    }
    func applyPresetData(_ data: EQPresetData) {
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
}

// ─── Inline AppAudioNode ───
final class AppAudioVolumeContainer: @unchecked Sendable {
    var volume: Float = 1.0
}

class AppAudioNode {
    let sourceNode: AVAudioSourceNode
    let eqNode: AVAudioUnitEQ
    let eqController: EQController
    let spectrumTap = SpectrumTap()

    private let ringBuffers: [RingBuffer]
    private let sourceFormat: AudioStreamBasicDescription
    private let engineFormat: AVAudioFormat
    
    private var converter: AudioConverterRef? = nil
    private var renderContext: AppAudioRenderContext? = nil
    
    private let volumeContainer = AppAudioVolumeContainer()
    var volume: Float {
        get { volumeContainer.volume }
        set { volumeContainer.volume = newValue }
    }
    
    init?(ringBuffers: [RingBuffer], sourceFormat: AudioStreamBasicDescription, engineFormat: AVAudioFormat) {
        self.ringBuffers = ringBuffers
        self.sourceFormat = sourceFormat
        self.engineFormat = engineFormat
        
        self.eqNode = AVAudioUnitEQ(numberOfBands: 10)
        self.eqNode.bypass = false
        self.eqController = EQController(avAudioUnit: self.eqNode)
        self.eqController.setFlat()
        
        var dstFormat = engineFormat.streamDescription.pointee
        var srcFormat = sourceFormat

        let sampleRateMatch = abs(srcFormat.mSampleRate - dstFormat.mSampleRate) < 0.01
        let channelMatch = srcFormat.mChannelsPerFrame == dstFormat.mChannelsPerFrame
        let formatFlagsMatch = (srcFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == (dstFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved)
        
        let needsConverter = !sampleRateMatch || !channelMatch || !formatFlagsMatch
        
        if needsConverter {
            var tempConverter: AudioConverterRef? = nil
            let status = AudioConverterNew(&srcFormat, &dstFormat, &tempConverter)
            if status == noErr {
                self.converter = tempConverter
                let bytesPerFrame = Int(srcFormat.mBytesPerFrame)
                let srcInterleaved = (srcFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
                let channelsPerBuffer = srcInterleaved ? Int(srcFormat.mChannelsPerFrame) : 1
                self.renderContext = AppAudioRenderContext(ringBuffers: ringBuffers, bytesPerFrame: bytesPerFrame, channelsPerBuffer: channelsPerBuffer)
            } else {
                print("AppAudioNode: Failed to create AudioConverter: \(status)")
                return nil
            }
        }
        
        let localConverter = self.converter
        let localContext = self.renderContext
        let localBuffers = self.ringBuffers
        let bytesPerFrame = Int(dstFormat.mBytesPerFrame)
        let localSpectrum = self.spectrumTap
        let localVolumeContainer = self.volumeContainer

        self.sourceNode = AVAudioSourceNode(format: engineFormat) { isSilence, timestamp, frameCount, ioData in
            if let conv = localConverter, let ctx = localContext {
                var ioOutputDataPackets = frameCount
                let status = AudioConverterFillComplexBuffer(
                    conv,
                    converterInputProc,
                    Unmanaged.passUnretained(ctx).toOpaque(),
                    &ioOutputDataPackets,
                    ioData,
                    nil
                )
                let buffers = UnsafeMutableAudioBufferListPointer(ioData)
                if status != noErr {
                    for buffer in buffers {
                        if let mData = buffer.mData {
                            memset(mData, 0, Int(frameCount) * bytesPerFrame)
                        }
                    }
                } else if ioOutputDataPackets < frameCount {
                    let filled = Int(ioOutputDataPackets) * bytesPerFrame
                    let total = Int(frameCount) * bytesPerFrame
                    for buffer in buffers {
                        if let mData = buffer.mData, total > filled {
                            memset(mData.advanced(by: filled), 0, total - filled)
                        }
                    }
                }
            } else {
                let buffers = UnsafeMutableAudioBufferListPointer(ioData)
                let bytesToRead = Int(frameCount) * bytesPerFrame
                var minAvailable = Int.max
                for rb in localBuffers {
                    minAvailable = min(minAvailable, rb.bytesAvailableForRead)
                }
                let actualBytesToRead = min(bytesToRead, minAvailable)
                let actualFrames = actualBytesToRead / bytesPerFrame
                for (i, buffer) in buffers.enumerated() {
                    if i < localBuffers.count {
                        if let mData = buffer.mData {
                            if actualFrames > 0 {
                                let bytesRead = localBuffers[i].read(mData, byteCount: actualFrames * bytesPerFrame)
                                if bytesRead < bytesToRead {
                                    let offset = bytesRead
                                    memset(mData.advanced(by: offset), 0, bytesToRead - offset)
                                }
                            } else {
                                memset(mData, 0, bytesToRead)
                            }
                        }
                    }
                }
            }
            
            let vol = localVolumeContainer.volume
            if vol < 1.0 {
                let buffers = UnsafeMutableAudioBufferListPointer(ioData)
                for buffer in buffers {
                    if let mData = buffer.mData {
                        if vol <= 0.0 {
                            memset(mData, 0, Int(frameCount) * bytesPerFrame)
                        } else {
                            let ptr = mData.assumingMemoryBound(to: Float.self)
                            let count = Int(frameCount)
                            for i in 0..<count {
                                ptr[i] *= vol
                            }
                        }
                    }
                }
            }
            
            localSpectrum.capture(ioData, frameCount: Int(frameCount))
            return noErr
        }
    }
    
    deinit {
        if let conv = converter {
            AudioConverterDispose(conv)
        }
    }
}

final class AppAudioRenderContext: @unchecked Sendable {
    let ringBuffers: [RingBuffer]
    let bytesPerFrame: Int
    let channelsPerBuffer: Int
    let scratchCapacityFrames: Int
    let scratch: [UnsafeMutableRawPointer]

    init(ringBuffers: [RingBuffer], bytesPerFrame: Int, channelsPerBuffer: Int) {
        self.ringBuffers = ringBuffers
        self.bytesPerFrame = bytesPerFrame
        self.channelsPerBuffer = channelsPerBuffer
        let capFrames = 16384
        self.scratchCapacityFrames = capFrames
        self.scratch = ringBuffers.map { _ in
            UnsafeMutableRawPointer.allocate(byteCount: capFrames * bytesPerFrame, alignment: 16)
        }
    }
    deinit {
        scratch.forEach { $0.deallocate() }
    }
}

private let converterInputProc: AudioConverterComplexInputDataProc = { _, ioNumberDataPackets, ioData, _, inUserData in
    guard let userData = inUserData else { return -1 }
    let context = Unmanaged<AppAudioRenderContext>.fromOpaque(userData).takeUnretainedValue()
    let bytesPerFrame = context.bytesPerFrame
    let requestedFrames = min(Int(ioNumberDataPackets.pointee), context.scratchCapacityFrames)
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)

    var minAvailable = Int.max
    for rb in context.ringBuffers {
        minAvailable = min(minAvailable, rb.bytesAvailableForRead)
    }
    let framesAvailable = minAvailable / bytesPerFrame
    let frames = min(requestedFrames, framesAvailable)

    if frames == 0 {
        for i in 0..<buffers.count {
            let s = context.scratch[i < context.scratch.count ? i : 0]
            memset(s, 0, requestedFrames * bytesPerFrame)
            buffers[i].mData = s
            buffers[i].mDataByteSize = UInt32(requestedFrames * bytesPerFrame)
            buffers[i].mNumberChannels = UInt32(context.channelsPerBuffer)
        }
        ioNumberDataPackets.pointee = UInt32(requestedFrames)
        return noErr
    }

    for i in 0..<buffers.count {
        let s = context.scratch[i < context.scratch.count ? i : 0]
        if i < context.ringBuffers.count {
            let bytesRead = context.ringBuffers[i].read(s, byteCount: frames * bytesPerFrame)
            buffers[i].mData = s
            buffers[i].mDataByteSize = UInt32(bytesRead)
        } else {
            memset(s, 0, frames * bytesPerFrame)
            buffers[i].mData = s
            buffers[i].mDataByteSize = UInt32(frames * bytesPerFrame)
        }
        buffers[i].mNumberChannels = UInt32(context.channelsPerBuffer)
    }
    ioNumberDataPackets.pointee = UInt32(frames)
    return noErr
}

// ─── Assert Helpers ───
var passed = 0
var failed = 0
var failures: [String] = []

func assertGT(_ a: Float, _ b: Float, _ msg: String = "", file: String = #file, line: Int = #line) {
    if a <= b {
        failures.append("line \(line): \(msg.isEmpty ? "\(a) <= \(b)" : "\(msg): \(a) <= \(b)")")
    }
}

func assertLT(_ a: Float, _ b: Float, _ msg: String = "", file: String = #file, line: Int = #line) {
    if a >= b {
        failures.append("line \(line): \(msg.isEmpty ? "\(a) >= \(b)" : "\(msg): \(a) >= \(b)")")
    }
}

func runTest(_ name: String, _ body: () throws -> Void) {
    let prev = failures.count
    do {
        try body()
    } catch {
        failures.append("Test threw error: \(error)")
    }
    if failures.count == prev {
        passed += 1
        print("  ✅ \(name)")
    } else {
        failed += 1
        print("  ❌ \(name)")
    }
}

// ─── Test Execution ───
print("🚀 Running Offline Audio Engine Integration Tests...")

runTest("Offline rendering with Sine Wave at Volume 1.0 (Sound Output)") {
    let sampleRate: Double = 48000.0
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let engine = AVAudioEngine()
    
    // Enable manual rendering
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    
    // Populate RingBuffer with Sine Wave (440Hz)
    let ringBuffer = RingBuffer(capacity: 64 * 1024)
    let sineFreq = 440.0
    let framesCount = 2048
    var sineData = [Float](repeating: 0, count: framesCount * 2)
    for i in 0..<framesCount {
        let t = Double(i) / sampleRate
        let val = Float(sin(2.0 * .pi * sineFreq * t))
        sineData[i * 2] = val     // L
        sineData[i * 2 + 1] = val // R
    }
    
    let bytesWritten = sineData.withUnsafeBufferPointer { ptr in
        ringBuffer.write(ptr.baseAddress!, byteCount: framesCount * 2 * MemoryLayout<Float>.size)
    }
    assertGT(Float(bytesWritten), 0, "Should write sine data to RingBuffer")
    
    // Setup tap ASBD (interleaved float)
    var tapASBD = AudioStreamBasicDescription()
    tapASBD.mSampleRate = sampleRate
    tapASBD.mFormatID = kAudioFormatLinearPCM
    tapASBD.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian
    tapASBD.mBytesPerPacket = 8
    tapASBD.mFramesPerPacket = 1
    tapASBD.mBytesPerFrame = 8
    tapASBD.mChannelsPerFrame = 2
    tapASBD.mBitsPerChannel = 32
    
    guard let appNode = AppAudioNode(ringBuffers: [ringBuffer], sourceFormat: tapASBD, engineFormat: format) else {
        failures.append("Could not instantiate AppAudioNode")
        return
    }
    
    engine.attach(appNode.sourceNode)
    engine.attach(appNode.eqNode)
    
    engine.connect(appNode.sourceNode, to: appNode.eqNode, format: format)
    engine.connect(appNode.eqNode, to: engine.mainMixerNode, format: format)
    
    // Volume = 1.0
    appNode.volume = 1.0
    
    try engine.start()
    
    let renderBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    let status = try engine.renderOffline(512, to: renderBuffer)
    
    if status == .success {
        var sumSquares: Float = 0.0
        let leftChannel = renderBuffer.floatChannelData![0]
        let rightChannel = renderBuffer.floatChannelData![1]
        for i in 0..<512 {
            sumSquares += leftChannel[i] * leftChannel[i]
            sumSquares += rightChannel[i] * rightChannel[i]
        }
        let rms = sqrt(sumSquares / Float(512 * 2))
        print("  Info: Rendered sound output RMS = \(rms)")
        assertGT(rms, 0.01, "Sound output should be loud and clear (non-zero RMS) when volume is 1.0")
    } else {
        failures.append("Offline rendering status was not .success")
    }
    
    engine.stop()
}

runTest("Offline rendering with Sine Wave at Volume 0.0 (Silence)") {
    let sampleRate: Double = 48000.0
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let engine = AVAudioEngine()
    
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    
    let ringBuffer = RingBuffer(capacity: 64 * 1024)
    let sineFreq = 440.0
    let framesCount = 2048
    var sineData = [Float](repeating: 0, count: framesCount * 2)
    for i in 0..<framesCount {
        let t = Double(i) / sampleRate
        let val = Float(sin(2.0 * .pi * sineFreq * t))
        sineData[i * 2] = val
        sineData[i * 2 + 1] = val
    }
    
    ringBuffer.write(sineData, byteCount: framesCount * 2 * MemoryLayout<Float>.size)
    
    var tapASBD = AudioStreamBasicDescription()
    tapASBD.mSampleRate = sampleRate
    tapASBD.mFormatID = kAudioFormatLinearPCM
    tapASBD.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian
    tapASBD.mBytesPerPacket = 8
    tapASBD.mFramesPerPacket = 1
    tapASBD.mBytesPerFrame = 8
    tapASBD.mChannelsPerFrame = 2
    tapASBD.mBitsPerChannel = 32
    
    guard let appNode = AppAudioNode(ringBuffers: [ringBuffer], sourceFormat: tapASBD, engineFormat: format) else {
        failures.append("Could not instantiate AppAudioNode")
        return
    }
    
    engine.attach(appNode.sourceNode)
    engine.attach(appNode.eqNode)
    
    engine.connect(appNode.sourceNode, to: appNode.eqNode, format: format)
    engine.connect(appNode.eqNode, to: engine.mainMixerNode, format: format)
    
    // Mute (Volume = 0.0)
    appNode.volume = 0.0
    
    try engine.start()
    
    let renderBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    let status = try engine.renderOffline(512, to: renderBuffer)
    
    if status == .success {
        var sumSquares: Float = 0.0
        let leftChannel = renderBuffer.floatChannelData![0]
        let rightChannel = renderBuffer.floatChannelData![1]
        for i in 0..<512 {
            sumSquares += leftChannel[i] * leftChannel[i]
            sumSquares += rightChannel[i] * rightChannel[i]
        }
        let rms = sqrt(sumSquares / Float(512 * 2))
        print("  Info: Rendered muted output RMS = \(rms)")
        assertLT(rms, 0.00001, "Sound output should be completely silent (zero RMS) when volume is 0.0")
    } else {
        failures.append("Offline rendering status was not .success")
    }
    
    engine.stop()
}

// ─── Print Summary ───
print("\n📝 Test Summary:")
print("  Passed: \(passed)")
print("  Failed: \(failed)")
if failed > 0 {
    print("\n❌ Failures:")
    for f in failures {
        print("  - \(f)")
    }
    exit(1)
} else {
    print("  🎉 All tests passed successfully!")
    exit(0)
}
