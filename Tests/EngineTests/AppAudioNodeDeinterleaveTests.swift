import Testing
import AVFoundation
import CoreAudio
@testable import Engine
@testable import Core

@Suite
struct AppAudioNodeDeinterleaveTests {
    @Test func deinterleaveStridedChannelOrdering() {
        // 4 stereo frames interleaved: [L0, R0, L1, R1, L2, R2, L3, R3]
        let input: [Float] = [0.1, 0.9, 0.2, 0.8, 0.3, 0.7, 0.4, 0.6]
        let frameCount = 4
        let channelCount = 2
        
        let leftBuf = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        let rightBuf = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer {
            leftBuf.deallocate()
            rightBuf.deallocate()
        }
        
        var dstChannels: [UnsafeMutablePointer<Float>?] = [leftBuf, rightBuf]
        
        dstChannels.withUnsafeMutableBufferPointer { bp in
            input.withUnsafeBufferPointer { ip in
                AppAudioNode.deinterleaveStrided(
                    source: ip.baseAddress!,
                    actualFrames: 4,
                    frameCount: 4,
                    channelCount: channelCount,
                    destinationChannels: bp.baseAddress!
                )
            }
        }
        
        #expect(leftBuf[0] == 0.1)
        #expect(leftBuf[1] == 0.2)
        #expect(leftBuf[2] == 0.3)
        #expect(leftBuf[3] == 0.4)
        
        #expect(rightBuf[0] == 0.9)
        #expect(rightBuf[1] == 0.8)
        #expect(rightBuf[2] == 0.7)
        #expect(rightBuf[3] == 0.6)
    }

    @Test func deinterleaveStridedPartialFrameUnderrun() {
        // 2 valid stereo frames available: [L0, R0, L1, R1]
        let input: [Float] = [0.15, 0.85, 0.25, 0.75]
        let actualFrames = 2
        let frameCount = 5 // requested 5 frames -> 3 frames underrun
        let channelCount = 2
        
        let leftBuf = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        let rightBuf = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer {
            leftBuf.deallocate()
            rightBuf.deallocate()
        }
        
        // Initialize with non-zero dummy sentinel values
        for i in 0..<frameCount {
            leftBuf[i] = 999.0
            rightBuf[i] = 999.0
        }
        
        var dstChannels: [UnsafeMutablePointer<Float>?] = [leftBuf, rightBuf]
        
        dstChannels.withUnsafeMutableBufferPointer { bp in
            input.withUnsafeBufferPointer { ip in
                AppAudioNode.deinterleaveStrided(
                    source: ip.baseAddress!,
                    actualFrames: actualFrames,
                    frameCount: frameCount,
                    channelCount: channelCount,
                    destinationChannels: bp.baseAddress!
                )
            }
        }
        
        // Valid frames copied correctly
        #expect(leftBuf[0] == 0.15)
        #expect(leftBuf[1] == 0.25)
        #expect(rightBuf[0] == 0.85)
        #expect(rightBuf[1] == 0.75)
        
        // Underrun tail zeroed out
        #expect(leftBuf[2] == 0.0)
        #expect(leftBuf[3] == 0.0)
        #expect(leftBuf[4] == 0.0)
        #expect(rightBuf[2] == 0.0)
        #expect(rightBuf[3] == 0.0)
        #expect(rightBuf[4] == 0.0)
    }

    @Test func deinterleaveStridedZeroFramesUnderrun() {
        let actualFrames = 0
        let frameCount = 4
        let channelCount = 2
        
        let leftBuf = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        let rightBuf = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer {
            leftBuf.deallocate()
            rightBuf.deallocate()
        }
        
        for i in 0..<frameCount {
            leftBuf[i] = 123.0
            rightBuf[i] = 456.0
        }
        
        var dstChannels: [UnsafeMutablePointer<Float>?] = [leftBuf, rightBuf]
        
        dstChannels.withUnsafeMutableBufferPointer { bp in
            let dummySrc = UnsafeMutablePointer<Float>.allocate(capacity: 1)
            defer { dummySrc.deallocate() }
            AppAudioNode.deinterleaveStrided(
                source: dummySrc,
                actualFrames: actualFrames,
                frameCount: frameCount,
                channelCount: channelCount,
                destinationChannels: bp.baseAddress!
            )
        }
        
        for i in 0..<frameCount {
            #expect(leftBuf[i] == 0.0)
            #expect(rightBuf[i] == 0.0)
        }
    }

    @Test func deinterleaveStridedMultiChannelOrdering() {
        // 2 frames of 4-channel audio
        let input: [Float] = [
            1.0, 2.0, 3.0, 4.0, // Frame 0
            5.0, 6.0, 7.0, 8.0  // Frame 1
        ]
        let frameCount = 2
        let channelCount = 4
        
        let ch0 = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        let ch1 = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        let ch2 = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        let ch3 = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer {
            ch0.deallocate()
            ch1.deallocate()
            ch2.deallocate()
            ch3.deallocate()
        }
        
        var dstChannels: [UnsafeMutablePointer<Float>?] = [ch0, ch1, ch2, ch3]
        
        dstChannels.withUnsafeMutableBufferPointer { bp in
            input.withUnsafeBufferPointer { ip in
                AppAudioNode.deinterleaveStrided(
                    source: ip.baseAddress!,
                    actualFrames: 2,
                    frameCount: 2,
                    channelCount: channelCount,
                    destinationChannels: bp.baseAddress!
                )
            }
        }
        
        #expect(ch0[0] == 1.0 && ch0[1] == 5.0)
        #expect(ch1[0] == 2.0 && ch1[1] == 6.0)
        #expect(ch2[0] == 3.0 && ch2[1] == 7.0)
        #expect(ch3[0] == 4.0 && ch3[1] == 8.0)
    }

    @Test func interleaveStridedChannelOrderingAndUnderrun() {
        let left: [Float] = [10.0, 20.0]
        let right: [Float] = [30.0, 40.0]
        let actualFrames = 2
        let frameCount = 4
        let channelCount = 2
        
        let dst = UnsafeMutablePointer<Float>.allocate(capacity: frameCount * channelCount)
        defer { dst.deallocate() }
        for i in 0..<(frameCount * channelCount) { dst[i] = 999.0 }
        
        left.withUnsafeBufferPointer { lp in
            right.withUnsafeBufferPointer { rp in
                let srcChannels: [UnsafePointer<Float>?] = [lp.baseAddress, rp.baseAddress]
                srcChannels.withUnsafeBufferPointer { sp in
                    AppAudioNode.interleaveStrided(
                        sourceChannels: sp.baseAddress!,
                        actualFrames: actualFrames,
                        frameCount: frameCount,
                        channelCount: channelCount,
                        destination: dst
                    )
                }
            }
        }
        
        #expect(dst[0] == 10.0 && dst[1] == 30.0) // Frame 0
        #expect(dst[2] == 20.0 && dst[3] == 40.0) // Frame 1
        #expect(dst[4] == 0.0 && dst[5] == 0.0)   // Frame 2 underrun
        #expect(dst[6] == 0.0 && dst[7] == 0.0)   // Frame 3 underrun
    }

    @Test func appAudioNodeDirectPathNoConverterCreated() {
        let sampleRate: Double = 48000.0
        let engineFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let ringBuffer = RingBuffer(capacity: 64 * 1024)
        
        // Tap format: 48kHz stereo interleaved float (differs only in interleaving from engine format)
        var tapASBD = AudioStreamBasicDescription()
        tapASBD.mSampleRate = sampleRate
        tapASBD.mFormatID = kAudioFormatLinearPCM
        tapASBD.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian
        tapASBD.mBytesPerPacket = 8
        tapASBD.mFramesPerPacket = 1
        tapASBD.mBytesPerFrame = 8
        tapASBD.mChannelsPerFrame = 2
        tapASBD.mBitsPerChannel = 32
        
        let node = AppAudioNode(ringBuffers: [ringBuffer], sourceFormat: tapASBD, engineFormat: engineFormat)
        #expect(node != nil)
        #expect(node?.lifetimeToken.converter == nil)
        #expect(node?.lifetimeToken.contextPtr == nil)
    }

    @Test func appAudioNodePreservesConverterForSampleRateMismatch() {
        let engineFormat = AVAudioFormat(standardFormatWithSampleRate: 48000.0, channels: 2)!
        let ringBuffer = RingBuffer(capacity: 64 * 1024)
        
        // Tap format: 44.1kHz stereo interleaved float (sample rate mismatch!)
        var tapASBD = AudioStreamBasicDescription()
        tapASBD.mSampleRate = 44100.0
        tapASBD.mFormatID = kAudioFormatLinearPCM
        tapASBD.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian
        tapASBD.mBytesPerPacket = 8
        tapASBD.mFramesPerPacket = 1
        tapASBD.mBytesPerFrame = 8
        tapASBD.mChannelsPerFrame = 2
        tapASBD.mBitsPerChannel = 32
        
        let node = AppAudioNode(ringBuffers: [ringBuffer], sourceFormat: tapASBD, engineFormat: engineFormat)
        #expect(node != nil)
        #expect(node?.lifetimeToken.converter != nil)
        #expect(node?.lifetimeToken.contextPtr != nil)
    }

    @Test func appAudioNodePreservesConverterForChannelCountMismatch() {
        let engineFormat = AVAudioFormat(standardFormatWithSampleRate: 48000.0, channels: 2)!
        let ringBuffer = RingBuffer(capacity: 64 * 1024)
        
        // Tap format: 48kHz mono float (channel count mismatch!)
        var tapASBD = AudioStreamBasicDescription()
        tapASBD.mSampleRate = 48000.0
        tapASBD.mFormatID = kAudioFormatLinearPCM
        tapASBD.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian
        tapASBD.mBytesPerPacket = 4
        tapASBD.mFramesPerPacket = 1
        tapASBD.mBytesPerFrame = 4
        tapASBD.mChannelsPerFrame = 1
        tapASBD.mBitsPerChannel = 32
        
        let node = AppAudioNode(ringBuffers: [ringBuffer], sourceFormat: tapASBD, engineFormat: engineFormat)
        #expect(node != nil)
        #expect(node?.lifetimeToken.converter != nil)
        #expect(node?.lifetimeToken.contextPtr != nil)
    }
}
