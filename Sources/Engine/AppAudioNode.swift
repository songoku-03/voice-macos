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
}

public final class AppAudioNodeLifetimeToken: @unchecked Sendable {
    let converter: AudioConverterRef?
    let buffersPtr: UnsafeMutablePointer<UnsafeMutableRawPointer>
    let contextPtr: UnsafeMutablePointer<AppAudioConverterContext>?
    let volumePtr: UnsafeMutablePointer<Float>
    let volumeLock: UnsafeMutablePointer<os_unfair_lock_s>
    let converterLock: UnsafeMutablePointer<os_unfair_lock_s>?
    
    init(
        converter: AudioConverterRef?,
        buffersPtr: UnsafeMutablePointer<UnsafeMutableRawPointer>,
        contextPtr: UnsafeMutablePointer<AppAudioConverterContext>?,
        volumePtr: UnsafeMutablePointer<Float>,
        volumeLock: UnsafeMutablePointer<os_unfair_lock_s>,
        converterLock: UnsafeMutablePointer<os_unfair_lock_s>?
    ) {
        self.converter = converter
        self.buffersPtr = buffersPtr
        self.contextPtr = contextPtr
        self.volumePtr = volumePtr
        self.volumeLock = volumeLock
        self.converterLock = converterLock
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
        volumeLock.deinitialize(count: 1)
        volumeLock.deallocate()
        if let cLock = converterLock {
            cLock.deinitialize(count: 1)
            cLock.deallocate()
        }
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
    private let volumeLock: UnsafeMutablePointer<os_unfair_lock_s>
    private let lifetimeToken: AppAudioNodeLifetimeToken
    
    public var volume: Float {
        get {
            os_unfair_lock_lock(volumeLock)
            defer { os_unfair_lock_unlock(volumeLock) }
            return volumePtr.pointee
        }
        set {
            os_unfair_lock_lock(volumeLock)
            defer { os_unfair_lock_unlock(volumeLock) }
            volumePtr.pointee = newValue
        }
    }
    
    public init?(ringBuffers: [RingBuffer], sourceFormat: AudioStreamBasicDescription, engineFormat: AVAudioFormat) {
        self.ringBuffers = ringBuffers
        self.sourceFormat = sourceFormat
        self.engineFormat = engineFormat
        
        // Initialize EQ node
        self.eqNode = AVAudioUnitEQ(numberOfBands: 10)
        self.eqNode.bypass = false
        self.eqNode.bypass = false
        self.eqController = EQController(avAudioUnit: self.eqNode)
        self.eqController.setFlat()
        
        // Setup converter if formats differ
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
        let formatFlagsMatch = (srcFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == (dstFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved)
        
        let needsConverter = !sampleRateMatch || !channelMatch || !formatFlagsMatch
        
        let bufferCount = ringBuffers.count
        let buffersPtr = UnsafeMutablePointer<UnsafeMutableRawPointer>.allocate(capacity: bufferCount)
        for i in 0..<bufferCount {
            buffersPtr[i] = Unmanaged.passUnretained(ringBuffers[i]).toOpaque()
        }
        
        let volumePtr = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        volumePtr.initialize(to: 1.0)
        self.volumePtr = volumePtr
        
        let volumeLock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        volumeLock.initialize(to: os_unfair_lock_s())
        self.volumeLock = volumeLock
        
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
                    lock: cLock
                ))
                os_unfair_lock_unlock(cLock)
                
                print("AppAudioNode: Initialized AudioConverter for format mismatch (SR: \(srcFormat.mSampleRate) -> \(dstFormat.mSampleRate), Ch: \(srcFormat.mChannelsPerFrame) -> \(dstFormat.mChannelsPerFrame), srcInterleaved=\(srcInterleaved), chPerBuf=\(channelsPerBuffer))")
            } else {
                print("AppAudioNode: Failed to create AudioConverter: \(status)")
                buffersPtr.deallocate()
                volumePtr.deinitialize(count: 1)
                volumePtr.deallocate()
                volumeLock.deinitialize(count: 1)
                volumeLock.deallocate()
                return nil
            }
        }
        
        let lifetimeToken = AppAudioNodeLifetimeToken(
            converter: tempConverter,
            buffersPtr: buffersPtr,
            contextPtr: contextPtr,
            volumePtr: volumePtr,
            volumeLock: volumeLock,
            converterLock: converterLock
        )
        self.lifetimeToken = lifetimeToken
        
        let localConverter = tempConverter
        let bytesPerFrame = Int(dstFormat.mBytesPerFrame)
        let opaqueSpectrum = Unmanaged.passUnretained(self.spectrumTap).toOpaque()

        self.spectrumTap.sampleRate = Float(dstFormat.mSampleRate > 0 ? dstFormat.mSampleRate : 48000)

        self.sourceNode = AVAudioSourceNode(format: engineFormat) { [lifetimeToken, bufferCount, buffersPtr, contextPtr, volumePtr, volumeLock, opaqueSpectrum, bytesPerFrame, localConverter, spectrumTap = self.spectrumTap] isSilence, timestamp, frameCount, ioData in
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
                let buffers = UnsafeMutableAudioBufferListPointer(ioData)
                if status != noErr {
                    // Fill output buffers with silence on error
                    for buffer in buffers {
                        if let mData = buffer.mData {
                            memset(mData, 0, Int(frameCount) * bytesPerFrame)
                        }
                    }
                } else if ioOutputDataPackets < frameCount {
                    // Zero the tail the converter didn't fill so we don't emit stale audio.
                    let filled = Int(ioOutputDataPackets) * bytesPerFrame
                    let total = Int(frameCount) * bytesPerFrame
                    for buffer in buffers {
                        if let mData = buffer.mData, total > filled {
                            memset(mData.advanced(by: filled), 0, total - filled)
                        }
                    }
                }
            } else {
                // Direct read - pull from ring buffers using unmanaged references (no ARC)
                let buffers = UnsafeMutableAudioBufferListPointer(ioData)
                let bytesToRead = Int(frameCount) * bytesPerFrame
                
                var minAvailable = Int.max
                for i in 0..<bufferCount {
                    let available = Unmanaged<RingBuffer>.fromOpaque(buffersPtr[i])._withUnsafeGuaranteedRef { $0.bytesAvailableForRead }
                    minAvailable = min(minAvailable, available)
                }
                
                let actualBytesToRead = min(bytesToRead, minAvailable)
                let actualFrames = actualBytesToRead / bytesPerFrame
                
                for (i, buffer) in buffers.enumerated() {
                    if i < bufferCount {
                        if let mData = buffer.mData {
                            if actualFrames > 0 {
                                let bytesRead = Unmanaged<RingBuffer>.fromOpaque(buffersPtr[i])._withUnsafeGuaranteedRef { rb in
                                    rb.read(mData, byteCount: actualFrames * bytesPerFrame)
                                }
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

            os_unfair_lock_lock(volumeLock)
            let vol = volumePtr.pointee
            os_unfair_lock_unlock(volumeLock)
            
            // Apply gain whenever volume isn't unity — both attenuation (< 1.0) and amplification (> 1.0).
            if vol != 1.0 {
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

            // Push rendered output into the spectrum analyzer (UI-thread runs the FFT).
            Unmanaged<SpectrumTap>.fromOpaque(opaqueSpectrum)._withUnsafeGuaranteedRef { $0.capture(ioData, frameCount: Int(frameCount)) }

            _ = spectrumTap
            _ = lifetimeToken
            return noErr
        }
    }
}

// C-style input callback for AudioConverter
private let converterInputProc: AudioConverterComplexInputDataProc = { _, ioNumberDataPackets, ioData, _, inUserData in
    guard let userData = inUserData else { return -1 }
    let contextPtr = userData.assumingMemoryBound(to: AppAudioConverterContext.self)
    
    os_unfair_lock_lock(contextPtr.pointee.lock)
    let context = contextPtr.pointee
    os_unfair_lock_unlock(contextPtr.pointee.lock)

    let bytesPerFrame = context.bytesPerFrame
    let requestedFrames = min(Int(ioNumberDataPackets.pointee), context.scratchCapacityFrames)
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)

    var minAvailable = Int.max
    for i in 0..<context.ringBufferCount {
        let rbPtr = context.ringBuffers[i]
        let available = Unmanaged<RingBuffer>.fromOpaque(rbPtr)._withUnsafeGuaranteedRef { rb in
            rb.bytesAvailableForRead
        }
        minAvailable = min(minAvailable, available)
    }
    let framesAvailable = minAvailable / bytesPerFrame
    let frames = min(requestedFrames, framesAvailable)

    if frames == 0 {
        for i in 0..<buffers.count {
            let s = context.scratch[i < context.ringBufferCount ? i : 0]
            memset(s, 0, requestedFrames * bytesPerFrame)
            buffers[i].mData = s
            buffers[i].mDataByteSize = UInt32(requestedFrames * bytesPerFrame)
            buffers[i].mNumberChannels = UInt32(context.channelsPerBuffer)
        }
        ioNumberDataPackets.pointee = UInt32(requestedFrames)
        return noErr
    }

    for i in 0..<buffers.count {
        let s = context.scratch[i < context.ringBufferCount ? i : 0]
        if i < context.ringBufferCount {
            let rbPtr = context.ringBuffers[i]
            let bytesRead = Unmanaged<RingBuffer>.fromOpaque(rbPtr)._withUnsafeGuaranteedRef { rb in
                rb.read(s, byteCount: frames * bytesPerFrame)
            }
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
