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
                self.renderContext = AppAudioRenderContext(ringBuffers: ringBuffers, bytesPerFrame: bytesPerFrame)
                print("AppAudioNode: Initialized AudioConverter for format mismatch (SR: \(srcFormat.mSampleRate) -> \(dstFormat.mSampleRate), Ch: \(srcFormat.mChannelsPerFrame) -> \(dstFormat.mChannelsPerFrame))")
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
        
        // Setup Source Node
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
                if status != noErr {
                    // Fill output buffers with silence on error
                    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
                    for buffer in buffers {
                        if let mData = buffer.mData {
                            memset(mData, 0, Int(frameCount) * bytesPerFrame)
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

// C-style helper context for AudioConverter
public class AppAudioRenderContext: @unchecked Sendable {
    public let ringBuffers: [RingBuffer]
    public let bytesPerFrame: Int
    
    public init(ringBuffers: [RingBuffer], bytesPerFrame: Int) {
        self.ringBuffers = ringBuffers
        self.bytesPerFrame = bytesPerFrame
    }
}

// C-style input callback for AudioConverter
private let converterInputProc: AudioConverterComplexInputDataProc = { inAudioConverter, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData in
    guard let userData = inUserData else { return -1 }
    let context = Unmanaged<AppAudioRenderContext>.fromOpaque(userData).takeUnretainedValue()
    
    let requestedFrames = ioNumberDataPackets.pointee
    let bytesPerFrame = context.bytesPerFrame
    let bytesToRead = Int(requestedFrames) * bytesPerFrame
    
    var minAvailable = Int.max
    for rb in context.ringBuffers {
        minAvailable = min(minAvailable, rb.bytesAvailableForRead)
    }
    
    let actualBytesToRead = min(bytesToRead, minAvailable)
    let actualFrames = UInt32(actualBytesToRead / bytesPerFrame)
    
    if actualFrames == 0 {
        // Output silence if no data
        ioNumberDataPackets.pointee = requestedFrames
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        for i in 0..<buffers.count {
            if let mData = buffers[i].mData {
                memset(mData, 0, Int(requestedFrames) * bytesPerFrame)
                buffers[i].mDataByteSize = UInt32(requestedFrames) * UInt32(bytesPerFrame)
            }
        }
        return noErr
    }
    
    ioNumberDataPackets.pointee = actualFrames
    
    // Read from ring buffers
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    for i in 0..<buffers.count {
        if i < context.ringBuffers.count {
            if let mData = buffers[i].mData {
                let bytesRead = context.ringBuffers[i].read(mData, byteCount: Int(actualFrames) * bytesPerFrame)
                buffers[i].mDataByteSize = UInt32(bytesRead)
            }
        } else {
            // Fill extra channels with silence
            if let mData = buffers[i].mData {
                memset(mData, 0, Int(actualFrames) * bytesPerFrame)
                buffers[i].mDataByteSize = UInt32(actualFrames) * UInt32(bytesPerFrame)
            }
        }
    }
    
    return noErr
}
