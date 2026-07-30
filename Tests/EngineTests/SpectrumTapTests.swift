import Foundation
import Testing
import CoreAudio
import AVFoundation
import Accelerate
@testable import Engine

@Suite struct SpectrumTapTests {
    @Test func testMonoDownmixSingleChannel() {
        let frameCount = 64
        let channelCount = 1
        let inputSamples: [Float] = (0..<frameCount).map { Float($0) * 0.1 }
        var outputSamples = [Float](repeating: 0, count: frameCount)

        inputSamples.withUnsafeBufferPointer { inBp in
            let rawPtrs: [UnsafePointer<Float>?] = [inBp.baseAddress]
            rawPtrs.withUnsafeBufferPointer { rawBp in
                outputSamples.withUnsafeMutableBufferPointer { outBp in
                    SpectrumTap.downmixMono(
                        channelPointers: rawBp.baseAddress!,
                        frameCount: frameCount,
                        channelCount: channelCount,
                        interleaved: false,
                        destination: outBp.baseAddress!
                    )
                }
            }
        }

        for i in 0..<frameCount {
            #expect(abs(outputSamples[i] - inputSamples[i]) < 0.0001, "Frame \(i) mono sample mismatch")
        }
    }

    @Test func testMonoDownmixStereoNonInterleaved() {
        let frameCount = 64
        let channelCount = 2
        let ch0: [Float] = (0..<frameCount).map { Float($0) * 0.2 }
        let ch1: [Float] = (0..<frameCount).map { Float($0) * 0.8 }
        var outputSamples = [Float](repeating: 0, count: frameCount)

        ch0.withUnsafeBufferPointer { ch0Bp in
            ch1.withUnsafeBufferPointer { ch1Bp in
                let rawPtrs: [UnsafePointer<Float>?] = [ch0Bp.baseAddress, ch1Bp.baseAddress]
                rawPtrs.withUnsafeBufferPointer { rawBp in
                    outputSamples.withUnsafeMutableBufferPointer { outBp in
                        SpectrumTap.downmixMono(
                            channelPointers: rawBp.baseAddress!,
                            frameCount: frameCount,
                            channelCount: channelCount,
                            interleaved: false,
                            destination: outBp.baseAddress!
                        )
                    }
                }
            }
        }

        for i in 0..<frameCount {
            let expected = (ch0[i] + ch1[i]) / 2.0
            #expect(abs(outputSamples[i] - expected) < 0.0001, "Frame \(i) non-interleaved mean mismatch")
        }
    }

    @Test func testMonoDownmixStereoInterleaved() {
        let frameCount = 64
        let channelCount = 2
        var interleaved: [Float] = []
        interleaved.reserveCapacity(frameCount * channelCount)

        for i in 0..<frameCount {
            let left = Float(i) * 0.3
            let right = Float(i) * 0.7
            interleaved.append(left)
            interleaved.append(right)
        }

        var outputSamples = [Float](repeating: 0, count: frameCount)

        interleaved.withUnsafeBufferPointer { inBp in
            let rawPtrs: [UnsafePointer<Float>?] = [inBp.baseAddress]
            rawPtrs.withUnsafeBufferPointer { rawBp in
                outputSamples.withUnsafeMutableBufferPointer { outBp in
                    SpectrumTap.downmixMono(
                        channelPointers: rawBp.baseAddress!,
                        frameCount: frameCount,
                        channelCount: channelCount,
                        interleaved: true,
                        destination: outBp.baseAddress!
                    )
                }
            }
        }

        for i in 0..<frameCount {
            let left = Float(i) * 0.3
            let right = Float(i) * 0.7
            let expected = (left + right) / 2.0
            #expect(abs(outputSamples[i] - expected) < 0.0001, "Frame \(i) interleaved mean mismatch")
        }
    }

    @Test func testRingWraparoundChronologicalRead() {
        let fftSize = 1024
        let totalFramesWritten = 1200
        guard #available(macOS 14.2, *) else { return }
        let tap = SpectrumTap(fftSize: fftSize)
        tap.addObserver()

        // Generate 1200 frames of mono audio with sample values 1.0 ... 1200.0
        var samples: [Float] = (1...totalFramesWritten).map { Float($0) }

        // Construct AudioBufferList in memory
        var audioBuffer = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(totalFramesWritten * MemoryLayout<Float>.size),
            mData: nil
        )

        samples.withUnsafeMutableBufferPointer { sampleBp in
            audioBuffer.mData = UnsafeMutableRawPointer(sampleBp.baseAddress)

            var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: (audioBuffer))
            withUnsafeMutablePointer(to: &abl) { ablPtr in
                tap.capture(ablPtr, frameCount: totalFramesWritten)
            }
        }

        var readBuffer = [Float](repeating: 0, count: fftSize)
        readBuffer.withUnsafeMutableBufferPointer { readBp in
            tap.readRingChronological(destination: readBp.baseAddress!)
        }

        // Capacity is 1024, written 1200.
        // Oldest sample in ring must be (1200 - 1024 + 1) = 177.0
        // Newest sample in ring must be 1200.0
        #expect(readBuffer.count == fftSize)
        let expectedFirst = Float(totalFramesWritten - fftSize + 1) // 177.0
        let expectedLast = Float(totalFramesWritten)                // 1200.0

        #expect(abs(readBuffer[0] - expectedFirst) < 0.0001, "Oldest sample after wrap mismatch")
        #expect(abs(readBuffer[fftSize - 1] - expectedLast) < 0.0001, "Newest sample after wrap mismatch")

        for i in 0..<fftSize {
            let expectedSample = Float(totalFramesWritten - fftSize + 1 + i)
            #expect(abs(readBuffer[i] - expectedSample) < 0.0001, "Chronological index \(i) mismatch")
        }
    }

    @Test func testCaptureFrameCountExceedsRingCapacity() {
        let fftSize = 1024
        let frameCount = 4096
        guard #available(macOS 14.2, *) else { return }
        let tap = SpectrumTap(fftSize: fftSize)
        tap.addObserver()

        // Generate 4096 frames of mono audio with sample values 1.0 ... 4096.0
        var samples: [Float] = (1...frameCount).map { Float($0) }

        var audioBuffer = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(frameCount * MemoryLayout<Float>.size),
            mData: nil
        )

        samples.withUnsafeMutableBufferPointer { sampleBp in
            audioBuffer.mData = UnsafeMutableRawPointer(sampleBp.baseAddress)

            var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: (audioBuffer))
            withUnsafeMutablePointer(to: &abl) { ablPtr in
                tap.capture(ablPtr, frameCount: frameCount)
            }
        }

        var readBuffer = [Float](repeating: 0, count: fftSize)
        readBuffer.withUnsafeMutableBufferPointer { readBp in
            tap.readRingChronological(destination: readBp.baseAddress!)
        }

        // Ring capacity is 1024, frameCount = 4096.
        // Only the most recent 1024 samples should be retained (samples 3073.0 ... 4096.0).
        #expect(readBuffer.count == fftSize)
        let expectedFirst = Float(frameCount - fftSize + 1) // 3073.0
        let expectedLast = Float(frameCount)                // 4096.0

        #expect(abs(readBuffer[0] - expectedFirst) < 0.0001, "Oldest sample mismatch when frameCount > n")
        #expect(abs(readBuffer[fftSize - 1] - expectedLast) < 0.0001, "Newest sample mismatch when frameCount > n")

        for i in 0..<fftSize {
            let expectedSample = Float(frameCount - fftSize + 1 + i)
            #expect(abs(readBuffer[i] - expectedSample) < 0.0001, "Chronological index \(i) mismatch when frameCount > n")
        }
    }

    @Test func testObserverCountAcquireReleaseCycles() {
        guard #available(macOS 14.2, *) else { return }
        let tap = SpectrumTap()
        #expect(tap.observerCount == 0)

        // 20 individual acquire and release cycles
        for _ in 0..<20 {
            tap.addObserver()
            #expect(tap.observerCount == 1)
            tap.removeObserver()
            #expect(tap.observerCount == 0)
        }

        // 20 nested acquires followed by 20 releases
        for _ in 0..<20 {
            tap.addObserver()
        }
        #expect(tap.observerCount == 20)
        for _ in 0..<20 {
            tap.removeObserver()
        }
        #expect(tap.observerCount == 0)
    }

    @Test func testSpectrumBandLevelsMatchingPreChangeWhileObserved() {
        let fftSize = 1024
        let sampleRate: Float = 48000
        guard #available(macOS 14.2, *) else { return }
        let tap = SpectrumTap(fftSize: fftSize)
        tap.sampleRate = sampleRate

        // 1. Generate 1024 frames of 1000 Hz sine wave test signal
        var samples = [Float](repeating: 0, count: fftSize)
        for i in 0..<fftSize {
            let t = Float(i) / sampleRate
            samples[i] = 0.5 * sin(2.0 * Float.pi * 1000.0 * t)
        }

        var audioBuffer = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(fftSize * MemoryLayout<Float>.size),
            mData: nil
        )

        // 2. Push while unobserved -> capture is inert, computeLevels produces 0s
        samples.withUnsafeMutableBufferPointer { sampleBp in
            audioBuffer.mData = UnsafeMutableRawPointer(sampleBp.baseAddress)
            var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: (audioBuffer))
            withUnsafeMutablePointer(to: &abl) { ablPtr in
                tap.capture(ablPtr, frameCount: fftSize)
            }
        }
        tap.computeLevels()
        for level in tap.levels() {
            #expect(level == 0.0, "Unobserved capture should produce zero levels")
        }

        // 3. Register observer and capture test signal
        tap.addObserver()
        #expect(tap.observerCount == 1)

        samples.withUnsafeMutableBufferPointer { sampleBp in
            audioBuffer.mData = UnsafeMutableRawPointer(sampleBp.baseAddress)
            var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: (audioBuffer))
            withUnsafeMutablePointer(to: &abl) { ablPtr in
                tap.capture(ablPtr, frameCount: fftSize)
            }
        }

        tap.computeLevels()
        let observedLevels = tap.levels()
        #expect(observedLevels.count == SpectrumTap.bandCount)

        // Calculate expected levels using the pre-change FFT formulation
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        let halfN = fftSize / 2
        let log2n = vDSP_Length(log2(Float(fftSize)))
        let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)
        var magnitudes = [Float](repeating: 0, count: halfN)

        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(halfN))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(halfN))
            }
        }
        vDSP_destroy_fftsetup(fftSetup)

        let bandFreqs: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        let binHz = sampleRate / Float(fftSize)
        var expectedLevels = [Float](repeating: 0, count: SpectrumTap.bandCount)

        for b in 0..<SpectrumTap.bandCount {
            let lo = b == 0 ? 20.0 : sqrt(bandFreqs[b - 1] * bandFreqs[b])
            let hi = b == SpectrumTap.bandCount - 1 ? sampleRate / 2 : sqrt(bandFreqs[b] * bandFreqs[b + 1])
            let loBin = max(1, Int(lo / binHz))
            let hiBin = min(halfN - 1, max(loBin, Int(hi / binHz)))
            var peak: Float = 0
            for bin in loBin...hiBin { peak = max(peak, magnitudes[bin]) }
            let db = 10 * log10(peak / Float(fftSize) + 1e-9)
            var level = (db + 50) / 60
            level = min(1, max(0, level))
            expectedLevels[b] = level
        }

        // Assert matching within 0.01 tolerance while observed
        for b in 0..<SpectrumTap.bandCount {
            let diff = abs(observedLevels[b] - expectedLevels[b])
            #expect(diff < 0.01, "Band \(b) observed level (\(observedLevels[b])) differs from expected (\(expectedLevels[b])) by \(diff) >= 0.01")
        }

        // 4. Removing observer zeroes out levels immediately (1 -> 0 transition)
        tap.removeObserver()
        #expect(tap.observerCount == 0)
        for level in tap.levels() {
            #expect(level == 0.0, "Reset after 1->0 transition should zero band levels")
        }
    }
}
