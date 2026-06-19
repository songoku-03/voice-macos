import Foundation
import AVFoundation
import Accelerate

// Computes a 10-band spectrum from the live signal WITHOUT installing an AVAudioEngine
// tap (installing a tap on an in-path node reconfigures the running graph and breaks
// audio). Instead the render block pushes its output samples here via `capture(...)`,
// and the UI calls `computeLevels()` on a timer to run the FFT off the audio thread.
@available(macOS 14.2, *)
public final class SpectrumTap: @unchecked Sendable {
    public static let bandCount = 10

    // Center frequencies aligned with EQController's 10 bands.
    private let bandFreqs: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    private let n: Int
    private let halfN: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup

    // Rolling window of the most recent mono samples (written by the audio thread).
    private var ring: [Float]
    private var writeIdx: Int = 0
    private let ringLock = NSLock()

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
        self.ring = [Float](repeating: 0, count: fftSize)
        self.window = [Float](repeating: 0, count: fftSize)
        self.windowed = [Float](repeating: 0, count: fftSize)
        self.realp = [Float](repeating: 0, count: fftSize / 2)
        self.imagp = [Float](repeating: 0, count: fftSize / 2)
        self.magnitudes = [Float](repeating: 0, count: fftSize / 2)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    // Thread-safe snapshot for the UI.
    public func levels() -> [Float] {
        levelLock.lock(); defer { levelLock.unlock() }
        return _levels
    }

    public func reset() {
        ringLock.lock(); for i in 0..<n { ring[i] = 0 }; writeIdx = 0; ringLock.unlock()
        levelLock.lock(); _levels = [Float](repeating: 0, count: Self.bandCount); levelLock.unlock()
    }

    // Called from the AVAudioSourceNode render block. Mono-downmixes the output buffers
    // into the rolling window. Uses try() so the audio thread never blocks on the UI.
    public func capture(_ ioData: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        guard ringLock.try() else { return }
        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        let bufCount = abl.count
        if bufCount == 0 { ringLock.unlock(); return }

        // Engine format is non-interleaved float (one channel per buffer). Handle the
        // interleaved single-buffer case defensively too.
        let interleaved = (bufCount == 1 && abl[0].mNumberChannels > 1)
        let channels = interleaved ? Int(abl[0].mNumberChannels) : bufCount

        for f in 0..<frameCount {
            var s: Float = 0
            if interleaved {
                if let md = abl[0].mData {
                    let fp = md.assumingMemoryBound(to: Float.self)
                    for c in 0..<channels { s += fp[f * channels + c] }
                }
            } else {
                for b in 0..<bufCount {
                    if let md = abl[b].mData {
                        let fp = md.assumingMemoryBound(to: Float.self)
                        s += fp[f]
                    }
                }
            }
            ring[writeIdx] = s / Float(max(1, channels))
            writeIdx = (writeIdx + 1) % n
        }
        ringLock.unlock()
    }

    // Run the FFT on the latest window and update band levels. Call from a UI timer.
    public func computeLevels() {
        // Copy the rolling window in chronological order.
        ringLock.lock()
        let start = writeIdx
        for i in 0..<n { windowed[i] = ring[(start + i) % n] }
        ringLock.unlock()

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
            let loBin = max(1, Int(lo / binHz))
            let hiBin = min(halfN - 1, max(loBin, Int(hi / binHz)))
            var peak: Float = 0
            for bin in loBin...hiBin { peak = max(peak, magnitudes[bin]) }
            let db = 10 * log10(peak / Float(n) + 1e-9)
            var level = (db + 50) / 60          // ~[-50dB, +10dB] → [0,1]
            level = min(1, max(0, level))
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
