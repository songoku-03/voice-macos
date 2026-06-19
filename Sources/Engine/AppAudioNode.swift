import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import Core

@available(macOS 14.2, *)
public class AppAudioNode: @unchecked Sendable {
    public let sourceNode: AVAudioSourceNode
    public let volumeNode: AVAudioMixerNode  // AVAudioMixerNode conforms to AVAudioMixing; eqNode does not
    public let eqNode: AVAudioUnitEQ
    public let eqController: EQController

    private let ringBuffers: [RingBuffer]
    private let sourceFormat: AudioStreamBasicDescription
    private let engineFormat: AVAudioFormat
    
    private var converter: AudioConverterRef? = nil
    private var renderContext: AppAudioRenderContext? = nil
    
    public init?(ringBuffers: [RingBuffer], sourceFormat: AudioStreamBasicDescription, engineFormat: AVAudioFormat) {
        self.ringBuffers = ringBuffers
        self.sourceFormat = sourceFormat
        self.engineFormat = engineFormat
        
        // Initialize volume mixer node and EQ node
        self.volumeNode = AVAudioMixerNode()
        self.eqNode = AVAudioUnitEQ(numberOfBands: 10)
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
        
        if needsConverter {
            var tempConverter: AudioConverterRef? = nil
            let status = AudioConverterNew(&srcFormat, &dstFormat, &tempConverter)
            if status == noErr {
                self.converter = tempConverter
                let bytesPerFrame = Int(srcFormat.mBytesPerFrame)
                let srcInterleaved = (srcFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
                // Interleaved: 1 ring buffer carries all channels. Non-interleaved: 1 channel per buffer.
                let channelsPerBuffer = srcInterleaved ? Int(srcFormat.mChannelsPerFrame) : 1
                self.renderContext = AppAudioRenderContext(ringBuffers: ringBuffers, bytesPerFrame: bytesPerFrame, channelsPerBuffer: channelsPerBuffer)
                print("AppAudioNode: Initialized AudioConverter for format mismatch (SR: \(srcFormat.mSampleRate) -> \(dstFormat.mSampleRate), Ch: \(srcFormat.mChannelsPerFrame) -> \(dstFormat.mChannelsPerFrame), srcInterleaved=\(srcInterleaved), chPerBuf=\(channelsPerBuffer))")
            } else {
                print("AppAudioNode: Failed to create AudioConverter: \(status)")
                return nil
            }
        }
        
        // Capture local copies for the render block closure
        let localConverter = self.converter
        let localContext = self.renderContext
        let localBuffers = self.ringBuffers
        let bytesPerFrame = Int(dstFormat.mBytesPerFrame)
        
        let usesConverter = (self.converter != nil)

        // Setup Source Node
        self.sourceNode = AVAudioSourceNode(format: engineFormat) { isSilence, timestamp, frameCount, ioData in
            renderDbgCalls += 1
            let shouldLog = (renderDbgCalls % 100 == 0)
            if shouldLog {
                var avail = Int.max
                for rb in localBuffers { avail = min(avail, rb.bytesAvailableForRead) }
                print("RENDER[play]: calls=\(renderDbgCalls) path=\(usesConverter ? "converter" : "direct") frameCount=\(frameCount) ringAvail=\(avail)B")
            }
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
                if shouldLog { print("RENDER[play]: converterStatus=\(status) outPackets=\(ioOutputDataPackets)") }
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
                // Direct read - pull from ring buffers
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
            
            return noErr
        }
    }
    
    deinit {
        if let conv = converter {
            AudioConverterDispose(conv)
        }
    }
}

// Debug counter (racy, debug-only).
private nonisolated(unsafe) var renderDbgCalls = 0

// C-style helper context for AudioConverter.
// Owns scratch storage the input proc points the converter at — an AudioConverter
// input proc receives buffers with mData == NULL and is expected to SET mData to
// point at the supplied input, not copy into pre-allocated storage.
public final class AppAudioRenderContext: @unchecked Sendable {
    public let ringBuffers: [RingBuffer]
    public let bytesPerFrame: Int
    public let channelsPerBuffer: Int   // 2 for interleaved stereo in 1 buffer; 1 for non-interleaved
    let scratchCapacityFrames: Int
    let scratch: [UnsafeMutableRawPointer]

    public init(ringBuffers: [RingBuffer], bytesPerFrame: Int, channelsPerBuffer: Int) {
        self.ringBuffers = ringBuffers
        self.bytesPerFrame = bytesPerFrame
        self.channelsPerBuffer = channelsPerBuffer
        let capFrames = 16384  // generous; converter requests far fewer per call
        self.scratchCapacityFrames = capFrames
        self.scratch = ringBuffers.map { _ in
            UnsafeMutableRawPointer.allocate(byteCount: capFrames * bytesPerFrame, alignment: 16)
        }
    }

    deinit {
        scratch.forEach { $0.deallocate() }
    }
}

// C-style input callback for AudioConverter
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

    // No data yet — hand the converter a block of silence so it still emits output
    // (returning 0 packets would leave the source node's buffer partially filled).
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

    // Read ring buffer data into our scratch, then point the converter's input at it.
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
