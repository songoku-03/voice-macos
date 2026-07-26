import Testing
import AVFoundation
import CoreAudio
@testable import Engine
@testable import Core

@Suite
struct AppAudioNodeSafetyTests {
    @Test func appAudioNodeDeinitWhileEngineRunning() throws {
        let sampleRate: Double = 48000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        
        let ringBuffer = RingBuffer(capacity: 64 * 1024)
        var tapASBD = AudioStreamBasicDescription()
        tapASBD.mSampleRate = sampleRate
        tapASBD.mFormatID = kAudioFormatLinearPCM
        tapASBD.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian
        tapASBD.mBytesPerPacket = 8
        tapASBD.mFramesPerPacket = 1
        tapASBD.mBytesPerFrame = 8
        tapASBD.mChannelsPerFrame = 2
        tapASBD.mBitsPerChannel = 32
        
        var sourceNode: AVAudioSourceNode? = nil
        
        do {
            let appNode = AppAudioNode(ringBuffers: [ringBuffer], sourceFormat: tapASBD, engineFormat: format)
            #expect(appNode != nil)
            sourceNode = appNode?.sourceNode
            
            engine.attach(sourceNode!)
            engine.connect(sourceNode!, to: engine.mainMixerNode, format: format)
            
            try engine.start()
        } // appNode deinitializes here!
        
        let renderBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        
        // This will run the render block. Since appNode is deinitialized, it might crash or cause memory corruption!
        do {
            let status = try engine.renderOffline(512, to: renderBuffer)
            print("Render status: \(status.rawValue)")
        } catch {
            print("Render failed with error: \(error)")
        }
        
        engine.stop()
    }
}
