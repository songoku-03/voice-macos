import Foundation
import os
import AVFoundation
import Accelerate

// Computes a 10-band spectrum from the live signal WITHOUT installing an AVAudioEngine
// tap (installing a tap on an in-path node reconfigures the running graph and breaks
// audio). Instead the render block pushes its output samples here via `capture(...)`,
// and the UI calls `computeLevels()` on a timer to run the FFT off the audio thread.
@available(macOS 14.2, *)
public final class SpectrumTap: @unchecked Sendable {
    public static let bandCount = 10
    public static let maxChannelPointers = 64

    // Center frequencies aligned with EQController's 10 bands.
    private let bandFreqs: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    private let n: Int
    private let halfN: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup

    // Fixed-capacity raw channel-pointer buffer pre-allocated in init
    private let channelPointers: UnsafeMutablePointer<UnsafePointer<Float>?>

    // Rolling window of the most recent mono samples (written by the audio thread).
    private let ring: UnsafeMutablePointer<Float>
    private var writeIdx: Int = 0
    private let ringLock: UnsafeMutablePointer<os_unfair_lock_s>

    // Atomic observer count for gating capture execution.
    private let observerCountPtr: UnsafeMutablePointer<Int32>

    public var observerCount: Int32 {
        return OSAtomicAdd32Barrier(0, observerCountPtr)
    }

    // FFT scratch (used only on the UI/compute thread).
    private var window: [Float]
    private var windowed: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var magnitudes: [Float]

    private let levelLock = NSLock()
    private var _levels = [Float](repeating: 0, count: bandCount)

    public var sampleRate: Float = 48000

    public init(fftSize: Int = 1024) {
        self.n = fftSize
        self.halfN = fftSize / 2
        self.log2n = vDSP_Length(log2(Float(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

        self.observerCountPtr = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        self.observerCountPtr.initialize(to: 0)

        self.channelPointers = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: Self.maxChannelPointers)
        self.channelPointers.initialize(repeating: nil, count: Self.maxChannelPointers)
        
        self.ring = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
        self.ring.initialize(repeating: 0, count: fftSize)
        
        self.ringLock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        self.ringLock.initialize(to: os_unfair_lock_s())
        
        self.window = [Float](repeating: 0, count: fftSize)
        self.windowed = [Float](repeating: 0, count: fftSize)
        self.realp = [Float](repeating: 0, count: fftSize / 2)
        self.imagp = [Float](repeating: 0, count: fftSize / 2)
        self.magnitudes = [Float](repeating: 0, count: fftSize / 2)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)

        observerCountPtr.deinitialize(count: 1)
        observerCountPtr.deallocate()

        channelPointers.deinitialize(count: Self.maxChannelPointers)
        channelPointers.deallocate()
        
        ring.deinitialize(count: n)
        ring.deallocate()
        
        ringLock.deinitialize(count: 1)
        ringLock.deallocate()
    }

    public func addObserver() {
        OSAtomicAdd32Barrier(1, observerCountPtr)
    }

    public func removeObserver() {
        while true {
            let current = OSAtomicAdd32Barrier(0, observerCountPtr)
            if current <= 0 {
                break
            }
            let next = current - 1
            if OSAtomicCompareAndSwap32Barrier(current, next, observerCountPtr) {
                if next == 0 {
                    reset()
                }
                break
            }
        }
    }

    /// Extracted mono-downmix arithmetic taking raw channel pointers, frame count, channel count, and destination.
    public static func downmixMono(
        channelPointers: UnsafePointer<UnsafePointer<Float>?>,
        frameCount: Int,
        channelCount: Int,
        interleaved: Bool,
        destination: UnsafeMutablePointer<Float>,
        sourceFrameOffset: Int = 0
    ) {
        guard frameCount > 0 && channelCount > 0 else { return }
        let reciprocalChannels = 1.0 / Float(channelCount)

        if interleaved {
            if let ptr = channelPointers[0] {
                var f = 0
                while f < frameCount {
                    let sampleFrame = sourceFrameOffset + f
                    let frameOffset = sampleFrame * channelCount
                    var sum: Float = 0
                    var c = 0
                    while c < channelCount {
                        sum += ptr[frameOffset + c]
                        c += 1
                    }
                    destination[f] = sum * reciprocalChannels
                    f += 1
                }
            } else {
                memset(destination, 0, frameCount * MemoryLayout<Float>.size)
            }
        } else {
            var f = 0
            while f < frameCount {
                let sampleFrame = sourceFrameOffset + f
                var sum: Float = 0
                var c = 0
                while c < channelCount {
                    if let ptr = channelPointers[c] {
                        sum += ptr[sampleFrame]
                    }
                    c += 1
                }
                destination[f] = sum * reciprocalChannels
                f += 1
            }
        }
    }

    // Thread-safe snapshot for the UI.
    public func levels() -> [Float] {
        levelLock.lock(); defer { levelLock.unlock() }
        return _levels
    }

    public func reset() {
        os_unfair_lock_lock(ringLock)
        for i in 0..<n { ring[i] = 0 }
        writeIdx = 0
        os_unfair_lock_unlock(ringLock)
        
        levelLock.lock(); _levels = [Float](repeating: 0, count: Self.bandCount); levelLock.unlock()
    }

    private static let mBuffersOffset = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers)!

    // Called from the AVAudioSourceNode render block. Mono-downmixes the output buffers
    // into the rolling window. Uses try() so the audio thread never blocks on the UI.
    public func capture(_ ioData: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        guard OSAtomicAdd32Barrier(0, observerCountPtr) > 0 else { return }
        guard os_unfair_lock_trylock(ringLock) else { return }

        let numberBuffers = Int(ioData.pointee.mNumberBuffers)
        if numberBuffers == 0 || frameCount == 0 {
            os_unfair_lock_unlock(ringLock)
            return
        }

        let firstBufferPtr = UnsafeRawPointer(ioData)
            .advanced(by: Self.mBuffersOffset)
            .assumingMemoryBound(to: AudioBuffer.self)

        let firstBufChannels = Int((firstBufferPtr + 0).pointee.mNumberChannels)
        let interleaved = (numberBuffers == 1 && firstBufChannels > 1)
        let channelCount = interleaved ? firstBufChannels : numberBuffers
        let cappedChannels = channelCount < Self.maxChannelPointers ? channelCount : Self.maxChannelPointers

        if interleaved {
            if let mData = (firstBufferPtr + 0).pointee.mData {
                channelPointers[0] = UnsafePointer(mData.assumingMemoryBound(to: Float.self))
            } else {
                channelPointers[0] = nil
            }
        } else {
            var c = 0
            while c < cappedChannels {
                if let mData = (firstBufferPtr + c).pointee.mData {
                    channelPointers[c] = UnsafePointer(mData.assumingMemoryBound(to: Float.self))
                } else {
                    channelPointers[c] = nil
                }
                c += 1
            }
        }

        let effectiveFrames = frameCount < n ? frameCount : n
        let sourceOffset = frameCount - effectiveFrames
        let startIdx = writeIdx
        let spaceToEnd = n - startIdx
        let run1Count = effectiveFrames < spaceToEnd ? effectiveFrames : spaceToEnd
        let run2Count = effectiveFrames - run1Count

        Self.downmixMono(
            channelPointers: UnsafePointer(channelPointers),
            frameCount: run1Count,
            channelCount: cappedChannels,
            interleaved: interleaved,
            destination: ring.advanced(by: startIdx),
            sourceFrameOffset: sourceOffset
        )

        if run2Count > 0 {
            Self.downmixMono(
                channelPointers: UnsafePointer(channelPointers),
                frameCount: run2Count,
                channelCount: cappedChannels,
                interleaved: interleaved,
                destination: ring,
                sourceFrameOffset: sourceOffset + run1Count
            )
        }

        let totalWritten = startIdx + effectiveFrames
        writeIdx = totalWritten < n ? totalWritten : (totalWritten % n)
        os_unfair_lock_unlock(ringLock)
    }

    /// Read rolling ring contents in chronological order (oldest to newest).
    public func readRingChronological(destination: UnsafeMutablePointer<Float>) {
        os_unfair_lock_lock(ringLock)
        let start = writeIdx
        let run1Count = n - start
        let run2Count = start
        destination.update(from: ring.advanced(by: start), count: run1Count)
        if run2Count > 0 {
            destination.advanced(by: run1Count).update(from: ring, count: run2Count)
        }
        os_unfair_lock_unlock(ringLock)
    }

    // Run the FFT on the latest window and update band levels. Call from a UI timer.
    public func computeLevels() {
        // Copy the rolling window in chronological order.
        windowed.withUnsafeMutableBufferPointer { bp in
            readRingChronological(destination: bp.baseAddress!)
        }

        vDSP_vmul(windowed, 1, window, 1, &windowed, 1, vDSP_Length(n))

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

        let binHz = sampleRate / Float(n)
        var newLevels = [Float](repeating: 0, count: Self.bandCount)
        for b in 0..<Self.bandCount {
            let lo = b == 0 ? 20.0 : sqrt(bandFreqs[b - 1] * bandFreqs[b])
            let hi = b == Self.bandCount - 1 ? sampleRate / 2 : sqrt(bandFreqs[b] * bandFreqs[b + 1])
            let loBinCalc = Int(lo / binHz)
            let loBin = loBinCalc > 1 ? loBinCalc : 1
            let hiBinCalc = loBin > Int(hi / binHz) ? loBin : Int(hi / binHz)
            let hiBin = (halfN - 1) < hiBinCalc ? (halfN - 1) : hiBinCalc
            var peak: Float = 0
            for bin in loBin...hiBin {
                if magnitudes[bin] > peak { peak = magnitudes[bin] }
            }
            let db = 10 * log10(peak / Float(n) + 1e-9)
            var level = (db + 50) / 60          // ~[-50dB, +10dB] → [0,1]
            let levelMin = level > 0 ? level : 0
            level = levelMin < 1 ? levelMin : 1
            newLevels[b] = level
        }

        levelLock.lock()
        for b in 0..<Self.bandCount {
            let prev = _levels[b]
            _levels[b] = newLevels[b] > prev ? newLevels[b] : prev * 0.82 + newLevels[b] * 0.18
        }
        levelLock.unlock()
    }
}
