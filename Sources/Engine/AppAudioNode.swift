import Foundation
import os
import AVFoundation
import CoreAudio
import AudioToolbox
import Core

public struct AppAudioConverterContext {
    public let ringBuffers: UnsafeMutablePointer<UnsafeMutableRawPointer>
    public let ringBufferCount: Int
    public let bytesPerFrame: Int
    public let channelsPerBuffer: Int
    public let scratch: UnsafeMutablePointer<UnsafeMutableRawPointer>
    public let scratchCapacityFrames: Int
    public let lock: UnsafeMutablePointer<os_unfair_lock_s>
    public let dstChannels: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    public let srcChannelPtrs: UnsafeMutablePointer<UnsafePointer<Float>?>
    public let tempBuf: UnsafeMutablePointer<Float>
}

public final class AppAudioNodeLifetimeToken: @unchecked Sendable {
    let converter: AudioConverterRef?
    let buffersPtr: UnsafeMutablePointer<UnsafeMutableRawPointer>
    let contextPtr: UnsafeMutablePointer<AppAudioConverterContext>?
    let volumePtr: UnsafeMutablePointer<Float>
    let converterLock: UnsafeMutablePointer<os_unfair_lock_s>?
    let ringBuffers: [RingBuffer]
    let spectrumTap: SpectrumTap
    let dstChannels: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    let srcChannelPtrs: UnsafeMutablePointer<UnsafePointer<Float>?>
    let tempBuf: UnsafeMutablePointer<Float>
    
    init(
        converter: AudioConverterRef?,
        buffersPtr: UnsafeMutablePointer<UnsafeMutableRawPointer>,
        contextPtr: UnsafeMutablePointer<AppAudioConverterContext>?,
        volumePtr: UnsafeMutablePointer<Float>,
        converterLock: UnsafeMutablePointer<os_unfair_lock_s>?,
        ringBuffers: [RingBuffer],
        spectrumTap: SpectrumTap,
        dstChannels: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>,
        srcChannelPtrs: UnsafeMutablePointer<UnsafePointer<Float>?>,
        tempBuf: UnsafeMutablePointer<Float>
    ) {
        self.converter = converter
        self.buffersPtr = buffersPtr
        self.contextPtr = contextPtr
        self.volumePtr = volumePtr
        self.converterLock = converterLock
        self.ringBuffers = ringBuffers
        self.spectrumTap = spectrumTap
        self.dstChannels = dstChannels
        self.srcChannelPtrs = srcChannelPtrs
        self.tempBuf = tempBuf
    }
    
    deinit {
        if let conv = converter {
            AudioConverterDispose(conv)
        }
        if let ctxPtr = contextPtr {
            let ctx = ctxPtr.pointee
            for i in 0..<ctx.ringBufferCount {
                ctx.scratch[i].deallocate()
            }
            ctx.scratch.deallocate()
            ctxPtr.deinitialize(count: 1)
            ctxPtr.deallocate()
        }
        buffersPtr.deallocate()
        volumePtr.deinitialize(count: 1)
        volumePtr.deallocate()
        if let cLock = converterLock {
            cLock.deinitialize(count: 1)
            cLock.deallocate()
        }
        dstChannels.deinitialize(count: 64)
        dstChannels.deallocate()
        srcChannelPtrs.deinitialize(count: 64)
        srcChannelPtrs.deallocate()
        tempBuf.deinitialize(count: 16384)
        tempBuf.deallocate()
    }
}

@available(macOS 14.2, *)
public class AppAudioNode: @unchecked Sendable {
    public let sourceNode: AVAudioSourceNode
    public let eqNode: AVAudioUnitEQ
    public let eqController: EQController
    public let spectrumTap = SpectrumTap()

    private let ringBuffers: [RingBuffer]
    private let sourceFormat: AudioStreamBasicDescription
    private let engineFormat: AVAudioFormat
    
    private let volumePtr: UnsafeMutablePointer<Float>
    let lifetimeToken: AppAudioNodeLifetimeToken
    
    public var volume: Float {
        get {
            let bits = OSAtomicAdd32Barrier(0, UnsafeMutableRawPointer(volumePtr).assumingMemoryBound(to: Int32.self))
            return Float(bitPattern: UInt32(bitPattern: bits))
        }
        set {
            let bits = Int32(bitPattern: newValue.bitPattern)
            let intPtr = UnsafeMutableRawPointer(volumePtr).assumingMemoryBound(to: Int32.self)
            while true {
                let old = OSAtomicAdd32Barrier(0, intPtr)
                if OSAtomicCompareAndSwap32Barrier(old, bits, intPtr) {
                    break
                }
            }
        }
    }

    /// De-interleaves interleaved Float audio samples from `source` into non-interleaved channel buffers `destinationChannels`.
    public static func deinterleaveStrided(
        source: UnsafePointer<Float>,
        actualFrames: Int,
        frameCount: Int,
        channelCount: Int,
        destinationChannels: UnsafePointer<UnsafeMutablePointer<Float>?>
    ) {
        let validFrames = actualFrames < frameCount ? actualFrames : frameCount
        var c = 0
        while c < channelCount {
            if let dstPtr = destinationChannels[c] {
                if validFrames > 0 {
                    var f = 0
                    while f < validFrames {
                        dstPtr[f] = source[f * channelCount + c]
                        f += 1
                    }
                }
                if validFrames < frameCount {
                    memset(dstPtr.advanced(by: validFrames), 0, (frameCount - validFrames) * MemoryLayout<Float>.size)
                }
            }
            c += 1
        }
    }

    /// Interleaves non-interleaved Float channel buffers `sourceChannels` into an interleaved output buffer `destination`.
    public static func interleaveStrided(
        sourceChannels: UnsafePointer<UnsafePointer<Float>?>,
        actualFrames: Int,
        frameCount: Int,
        channelCount: Int,
        destination: UnsafeMutablePointer<Float>
    ) {
        let validFrames = actualFrames < frameCount ? actualFrames : frameCount
        if validFrames > 0 {
            var f = 0
            while f < validFrames {
                var c = 0
                while c < channelCount {
                    if let srcPtr = sourceChannels[c] {
                        destination[f * channelCount + c] = srcPtr[f]
                    } else {
                        destination[f * channelCount + c] = 0.0
                    }
                    c += 1
                }
                f += 1
            }
        }
        if validFrames < frameCount {
            let tailStart = validFrames * channelCount
            let tailFloats = (frameCount - validFrames) * channelCount
            memset(destination.advanced(by: tailStart), 0, tailFloats * MemoryLayout<Float>.size)
        }
    }
    
    public init?(ringBuffers: [RingBuffer], sourceFormat: AudioStreamBasicDescription, engineFormat: AVAudioFormat) {
        self.ringBuffers = ringBuffers
        self.sourceFormat = sourceFormat
        self.engineFormat = engineFormat
        
        // Initialize EQ node
        self.eqNode = AVAudioUnitEQ(numberOfBands: 10)
        self.eqNode.bypass = false
        self.eqController = EQController(avAudioUnit: self.eqNode)
        self.eqController.setFlat()
        
        // Setup converter if sample rate or channel count differ
        var dstFormat = engineFormat.streamDescription.pointee
        var srcFormat = sourceFormat

        func dump(_ label: String, _ f: AudioStreamBasicDescription) -> String {
            let ni = (f.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
            let fl = (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            return "\(label): \(f.mSampleRate)Hz ch=\(f.mChannelsPerFrame) bpf=\(f.mBytesPerFrame) bits=\(f.mBitsPerChannel) \(fl ? "float" : "int") \(ni ? "non-interleaved" : "interleaved") flags=\(f.mFormatFlags)"
        }
        print("AppAudioNode: \(dump("SRC(tap)", srcFormat))")
        print("AppAudioNode: \(dump("DST(engine)", dstFormat))")

        let sampleRateMatch = abs(srcFormat.mSampleRate - dstFormat.mSampleRate) < 0.01
        let channelMatch = srcFormat.mChannelsPerFrame == dstFormat.mChannelsPerFrame
        
        let needsConverter = !sampleRateMatch || !channelMatch
        
        let bufferCount = ringBuffers.count
        let buffersPtr = UnsafeMutablePointer<UnsafeMutableRawPointer>.allocate(capacity: bufferCount)
        for i in 0..<bufferCount {
            buffersPtr[i] = Unmanaged.passUnretained(ringBuffers[i]).toOpaque()
        }
        
        let volumePtr = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        volumePtr.initialize(to: 1.0)
        self.volumePtr = volumePtr
        
        let dstChannels = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 64)
        dstChannels.initialize(repeating: nil, count: 64)
        
        let srcChannelPtrs = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: 64)
        srcChannelPtrs.initialize(repeating: nil, count: 64)
        
        let tempBuf = UnsafeMutablePointer<Float>.allocate(capacity: 16384)
        tempBuf.initialize(repeating: 0, count: 16384)

        var tempConverter: AudioConverterRef? = nil
        var contextPtr: UnsafeMutablePointer<AppAudioConverterContext>? = nil
        var converterLock: UnsafeMutablePointer<os_unfair_lock_s>? = nil
        
        if needsConverter {
            let status = AudioConverterNew(&srcFormat, &dstFormat, &tempConverter)
            if status == noErr {
                let bytesPerFrame = Int(srcFormat.mBytesPerFrame)
                let srcInterleaved = (srcFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
                let channelsPerBuffer = srcInterleaved ? Int(srcFormat.mChannelsPerFrame) : 1
                
                let scratchCapacityFrames = 16384
                let scratchPtr = UnsafeMutablePointer<UnsafeMutableRawPointer>.allocate(capacity: bufferCount)
                for i in 0..<bufferCount {
                    scratchPtr[i] = UnsafeMutableRawPointer.allocate(byteCount: scratchCapacityFrames * bytesPerFrame, alignment: 16)
                }
                
                let cLock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
                cLock.initialize(to: os_unfair_lock_s())
                converterLock = cLock
                
                contextPtr = UnsafeMutablePointer<AppAudioConverterContext>.allocate(capacity: 1)
                os_unfair_lock_lock(cLock)
                contextPtr?.initialize(to: AppAudioConverterContext(
                    ringBuffers: buffersPtr,
                    ringBufferCount: bufferCount,
                    bytesPerFrame: bytesPerFrame,
                    channelsPerBuffer: channelsPerBuffer,
                    scratch: scratchPtr,
                    scratchCapacityFrames: scratchCapacityFrames,
                    lock: cLock,
                    dstChannels: dstChannels,
                    srcChannelPtrs: srcChannelPtrs,
                    tempBuf: tempBuf
                ))
                os_unfair_lock_unlock(cLock)
                
                print("AppAudioNode: Initialized AudioConverter for format mismatch (SR: \(srcFormat.mSampleRate) -> \(dstFormat.mSampleRate), Ch: \(srcFormat.mChannelsPerFrame) -> \(dstFormat.mChannelsPerFrame), srcInterleaved=\(srcInterleaved), chPerBuf=\(channelsPerBuffer))")
            } else {
                print("AppAudioNode: Failed to create AudioConverter: \(status)")
                buffersPtr.deallocate()
                volumePtr.deinitialize(count: 1)
                volumePtr.deallocate()
                dstChannels.deinitialize(count: 64)
                dstChannels.deallocate()
                srcChannelPtrs.deinitialize(count: 64)
                srcChannelPtrs.deallocate()
                tempBuf.deinitialize(count: 16384)
                tempBuf.deallocate()
                return nil
            }
        } else {
            let srcInterleaved = (srcFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
            print("AppAudioNode: Direct path (no AudioConverter) (SR: \(srcFormat.mSampleRate) -> \(dstFormat.mSampleRate), Ch: \(srcFormat.mChannelsPerFrame) -> \(dstFormat.mChannelsPerFrame), srcInterleaved=\(srcInterleaved))")
        }
        
        let lifetimeToken = AppAudioNodeLifetimeToken(
            converter: tempConverter,
            buffersPtr: buffersPtr,
            contextPtr: contextPtr,
            volumePtr: volumePtr,
            converterLock: converterLock,
            ringBuffers: ringBuffers,
            spectrumTap: self.spectrumTap,
            dstChannels: dstChannels,
            srcChannelPtrs: srcChannelPtrs,
            tempBuf: tempBuf
        )
        self.lifetimeToken = lifetimeToken
        
        let localConverter = tempConverter
        let bytesPerFrame = Int(dstFormat.mBytesPerFrame)
        let opaqueSpectrum = Unmanaged.passUnretained(self.spectrumTap).toOpaque()
        let srcInterleaved = (srcFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        let dstInterleaved = (dstFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        let channelCount = Int(srcFormat.mChannelsPerFrame)

        self.spectrumTap.sampleRate = Float(dstFormat.mSampleRate > 0 ? dstFormat.mSampleRate : 48000)

        self.sourceNode = AVAudioSourceNode(format: engineFormat) { [lifetimeToken, bufferCount, buffersPtr, contextPtr, volumePtr, opaqueSpectrum, bytesPerFrame, localConverter, srcInterleaved, dstInterleaved, channelCount, dstChannels, srcChannelPtrs, tempBuf] isSilence, timestamp, frameCount, ioData in
            let numberBuffers = Int(ioData.pointee.mNumberBuffers)
            let firstBufferPtr = UnsafeMutableRawPointer(ioData)
                .advanced(by: audioBufferListBuffersOffset)
                .assumingMemoryBound(to: AudioBuffer.self)

            if let conv = localConverter, let ctxPtr = contextPtr {
                var ioOutputDataPackets = frameCount
                let status = AudioConverterFillComplexBuffer(
                    conv,
                    converterInputProc,
                    ctxPtr,
                    &ioOutputDataPackets,
                    ioData,
                    nil
                )
                if status != noErr {
                    // Fill output buffers with silence on error
                    var i = 0
                    while i < numberBuffers {
                        if let mData = (firstBufferPtr + i).pointee.mData {
                            memset(mData, 0, Int(frameCount) * bytesPerFrame)
                        }
                        i += 1
                    }
                } else if ioOutputDataPackets < frameCount {
                    // Zero the tail the converter didn't fill so we don't emit stale audio.
                    let filled = Int(ioOutputDataPackets) * bytesPerFrame
                    let total = Int(frameCount) * bytesPerFrame
                    var i = 0
                    while i < numberBuffers {
                        if let mData = (firstBufferPtr + i).pointee.mData, total > filled {
                            memset(mData.advanced(by: filled), 0, total - filled)
                        }
                        i += 1
                    }
                }
            } else {
                // Direct read / de-interleave path - pull from ring buffers using unmanaged references (no ARC)
                let numBufs = numberBuffers < 64 ? numberBuffers : 64
                var i = 0
                while i < numBufs {
                    if let mData = (firstBufferPtr + i).pointee.mData {
                        dstChannels[i] = mData.assumingMemoryBound(to: Float.self)
                    } else {
                        dstChannels[i] = nil
                    }
                    i += 1
                }
                
                if srcInterleaved && !dstInterleaved {
                    let rb = Unmanaged<RingBuffer>.fromOpaque(buffersPtr[0]).takeUnretainedValue()
                    let availBytes = rb.bytesAvailableForRead
                    let srcBytesPerFrame = channelCount * MemoryLayout<Float>.size
                    let availFrames = availBytes / srcBytesPerFrame
                    let actualFrames = Int(frameCount) < availFrames ? Int(frameCount) : availFrames
                    
                    if actualFrames > 0 {
                        rb.read(tempBuf, byteCount: actualFrames * srcBytesPerFrame)
                    }
                    AppAudioNode.deinterleaveStrided(
                        source: tempBuf,
                        actualFrames: actualFrames,
                        frameCount: Int(frameCount),
                        channelCount: channelCount,
                        destinationChannels: dstChannels
                    )
                } else if !srcInterleaved && !dstInterleaved {
                    var minAvailableBytes = Int.max
                    var c = 0
                    while c < bufferCount {
                        let rb = Unmanaged<RingBuffer>.fromOpaque(buffersPtr[c]).takeUnretainedValue()
                        let avail = rb.bytesAvailableForRead
                        if avail < minAvailableBytes { minAvailableBytes = avail }
                        c += 1
                    }
                    let availFrames = minAvailableBytes / MemoryLayout<Float>.size
                    let actualFrames = Int(frameCount) < availFrames ? Int(frameCount) : availFrames
                    
                    c = 0
                    while c < numberBuffers {
                        if let dstPtr = dstChannels[c] {
                            if c < bufferCount && actualFrames > 0 {
                                let rb = Unmanaged<RingBuffer>.fromOpaque(buffersPtr[c]).takeUnretainedValue()
                                let bytesRead = rb.read(dstPtr, byteCount: actualFrames * MemoryLayout<Float>.size)
                                let framesRead = bytesRead / MemoryLayout<Float>.size
                                if framesRead < Int(frameCount) {
                                    memset(dstPtr.advanced(by: framesRead), 0, (Int(frameCount) - framesRead) * MemoryLayout<Float>.size)
                                }
                            } else {
                                memset(dstPtr, 0, Int(frameCount) * MemoryLayout<Float>.size)
                            }
                        }
                        c += 1
                    }
                } else if srcInterleaved && dstInterleaved {
                    let rb = Unmanaged<RingBuffer>.fromOpaque(buffersPtr[0]).takeUnretainedValue()
                    let availBytes = rb.bytesAvailableForRead
                    let srcBytesPerFrame = channelCount * MemoryLayout<Float>.size
                    let availFrames = availBytes / srcBytesPerFrame
                    let actualFrames = Int(frameCount) < availFrames ? Int(frameCount) : availFrames
                    
                    if let dstPtr = dstChannels[0] {
                        let bytesToRead = Int(frameCount) * srcBytesPerFrame
                        if actualFrames > 0 {
                            let bytesRead = rb.read(dstPtr, byteCount: actualFrames * srcBytesPerFrame)
                            if bytesRead < bytesToRead {
                                memset(UnsafeMutableRawPointer(dstPtr).advanced(by: bytesRead), 0, bytesToRead - bytesRead)
                            }
                        } else {
                            memset(dstPtr, 0, bytesToRead)
                        }
                    }
                } else {
                    var minAvailableBytes = Int.max
                    var c = 0
                    while c < bufferCount {
                        let rb = Unmanaged<RingBuffer>.fromOpaque(buffersPtr[c]).takeUnretainedValue()
                        let avail = rb.bytesAvailableForRead
                        if avail < minAvailableBytes { minAvailableBytes = avail }
                        c += 1
                    }
                    let availFrames = minAvailableBytes / MemoryLayout<Float>.size
                    let actualFrames = Int(frameCount) < availFrames ? Int(frameCount) : availFrames
                    
                    let cappedCh = channelCount < 64 ? channelCount : 64
                    c = 0
                    while c < cappedCh {
                        if c < bufferCount && actualFrames > 0 {
                            let rb = Unmanaged<RingBuffer>.fromOpaque(buffersPtr[c]).takeUnretainedValue()
                            let channelBuf = tempBuf.advanced(by: c * actualFrames)
                            rb.read(channelBuf, byteCount: actualFrames * MemoryLayout<Float>.size)
                            srcChannelPtrs[c] = UnsafePointer(channelBuf)
                        } else {
                            srcChannelPtrs[c] = nil
                        }
                        c += 1
                    }
                    if let dstPtr = dstChannels[0] {
                        AppAudioNode.interleaveStrided(
                            sourceChannels: srcChannelPtrs,
                            actualFrames: actualFrames,
                            frameCount: Int(frameCount),
                            channelCount: channelCount,
                            destination: dstPtr
                        )
                    }
                }
            }

            let bits = OSAtomicAdd32Barrier(0, UnsafeMutableRawPointer(volumePtr).assumingMemoryBound(to: Int32.self))
            let vol = Float(bitPattern: UInt32(bitPattern: bits))
            
            // Apply gain whenever volume isn't unity — both attenuation (< 1.0) and amplification (> 1.0).
            if vol != 1.0 {
                var i = 0
                while i < numberBuffers {
                    if let mData = (firstBufferPtr + i).pointee.mData {
                        if vol <= 0.0 {
                            memset(mData, 0, Int(frameCount) * bytesPerFrame)
                        } else {
                            let ptr = mData.assumingMemoryBound(to: Float.self)
                            let count = Int(frameCount)
                            var f = 0
                            while f < count {
                                ptr[f] *= vol
                                f += 1
                            }
                        }
                    }
                    i += 1
                }
            }

            // Push rendered output into the spectrum analyzer (UI-thread runs the FFT).
            let tap = Unmanaged<SpectrumTap>.fromOpaque(opaqueSpectrum).takeUnretainedValue()
            tap.capture(ioData, frameCount: Int(frameCount))

            _ = lifetimeToken
            return noErr
        }
    }
}

private let audioBufferListBuffersOffset = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers)!

// C-style input callback for AudioConverter
private let converterInputProc: AudioConverterComplexInputDataProc = { _, ioNumberDataPackets, ioData, _, inUserData in
    guard let userData = inUserData else { return -1 }
    let contextPtr = userData.assumingMemoryBound(to: AppAudioConverterContext.self)
    
    let context = contextPtr.pointee

    let bytesPerFrame = context.bytesPerFrame
    let reqPackets = Int(ioNumberDataPackets.pointee)
    let scratchCap = context.scratchCapacityFrames
    let requestedFrames = reqPackets < scratchCap ? reqPackets : scratchCap
    
    let numberBuffers = Int(ioData.pointee.mNumberBuffers)
    let firstBufferPtr = UnsafeMutableRawPointer(ioData)
        .advanced(by: audioBufferListBuffersOffset)
        .assumingMemoryBound(to: AudioBuffer.self)

    var minAvailable = Int.max
    var i = 0
    while i < context.ringBufferCount {
        let rbPtr = context.ringBuffers[i]
        let rb = Unmanaged<RingBuffer>.fromOpaque(rbPtr).takeUnretainedValue()
        let avail = rb.bytesAvailableForRead
        if avail < minAvailable { minAvailable = avail }
        i += 1
    }
    let framesAvailable = minAvailable / bytesPerFrame
    let frames = requestedFrames < framesAvailable ? requestedFrames : framesAvailable

    if frames == 0 {
        i = 0
        while i < numberBuffers {
            let bufPtr = firstBufferPtr + i
            let scratchIndex = i < context.ringBufferCount ? i : 0
            let s = context.scratch[scratchIndex]
            memset(s, 0, requestedFrames * bytesPerFrame)
            bufPtr.pointee.mData = s
            bufPtr.pointee.mDataByteSize = UInt32(requestedFrames * bytesPerFrame)
            bufPtr.pointee.mNumberChannels = UInt32(context.channelsPerBuffer)
            i += 1
        }
        ioNumberDataPackets.pointee = UInt32(requestedFrames)
        return noErr
    }

    i = 0
    while i < numberBuffers {
        let bufPtr = firstBufferPtr + i
        let scratchIndex = i < context.ringBufferCount ? i : 0
        let s = context.scratch[scratchIndex]
        if i < context.ringBufferCount {
            let rbPtr = context.ringBuffers[i]
            let rb = Unmanaged<RingBuffer>.fromOpaque(rbPtr).takeUnretainedValue()
            let bytesRead = rb.read(s, byteCount: frames * bytesPerFrame)
            bufPtr.pointee.mData = s
            bufPtr.pointee.mDataByteSize = UInt32(bytesRead)
        } else {
            memset(s, 0, frames * bytesPerFrame)
            bufPtr.pointee.mData = s
            bufPtr.pointee.mDataByteSize = UInt32(frames * bytesPerFrame)
        }
        bufPtr.pointee.mNumberChannels = UInt32(context.channelsPerBuffer)
        i += 1
    }
    ioNumberDataPackets.pointee = UInt32(frames)
    return noErr
}
