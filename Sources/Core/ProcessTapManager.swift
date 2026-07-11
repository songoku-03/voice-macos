import Foundation
import CoreAudio
import AppKit

// Aggregate device dictionary keys (raw string values of CoreAudio CFString constants)
private enum AggDevKey {
    static let name    = "name"
    static let uid     = "uid"
    static let private_ = "private"
    static let tapList = "taps"   // kAudioAggregateDeviceTapListKey — macOS 14.2+
    static let subUID  = "uid"    // kAudioSubDeviceUIDKey (same value as uid, used in tap entry dict)
}

@available(macOS 14.2, *)
public final class TapIOContext: @unchecked Sendable {
    public let ringBuffers: [RingBuffer]
    public let buffersPtr: UnsafeMutablePointer<UnsafeMutableRawPointer>
    public let bufferCount: Int

    public init(ringBuffers: [RingBuffer]) {
        self.ringBuffers = ringBuffers
        self.bufferCount = ringBuffers.count
        self.buffersPtr = UnsafeMutablePointer<UnsafeMutableRawPointer>.allocate(capacity: ringBuffers.count)
        for i in 0..<ringBuffers.count {
            self.buffersPtr[i] = Unmanaged.passUnretained(ringBuffers[i]).toOpaque()
        }
    }

    deinit {
        buffersPtr.deallocate()
    }
}

@available(macOS 14.2, *)
public class ProcessTapManager: @unchecked Sendable {
    public static let shared = ProcessTapManager()

    private struct ActiveTap {
        let tapID: AudioObjectID
        let aggDevID: AudioObjectID   // private aggregate device wrapping the tap
        let ioProcID: AudioDeviceIOProcID
        let ringBuffers: [RingBuffer]
        let format: AudioStreamBasicDescription
        let ioContext: TapIOContext  // Keeps the unmanaged context alive for the real-time thread!
    }

    private var activeTaps: [String: ActiveTap] = [:]
    private let lock = NSLock()

    private init() {}

    public func startTapping(bundleID: String, pid: pid_t) -> ([RingBuffer], AudioStreamBasicDescription)? {
        print("ProcessTapManager: startTapping for \(bundleID) with PID \(pid)")
        lock.lock()
        defer { lock.unlock() }

        if let active = activeTaps[bundleID] {
            return (active.ringBuffers, active.format)
        }

        var processObjectIDs = getProcessObjectIDs(for: bundleID)
        if processObjectIDs.isEmpty {
            if let processObjectID = getProcessObjectID(pid: pid) {
                processObjectIDs.append(processObjectID)
            }
        }

        guard !processObjectIDs.isEmpty else {
            print("ProcessTapManager: Could not find any process object IDs for \(bundleID) (PID \(pid))")
            return nil
        }

        print("ProcessTapManager: Tapping \(processObjectIDs.count) process objects for \(bundleID)")
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.name = "SoundsSource Tap (\(bundleID))"
        description.muteBehavior = CATapMuteBehavior.muted

        return createAndStartTap(key: bundleID, description: description)
    }

    private func getProcessObjectIDs(for bundleID: String) -> [AudioObjectID] {
        guard !bundleID.isEmpty else { return [] }
        var address = AudioObjectPropertyAddress(
            mSelector: 0x70727323, // 'prs#'
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        var status = AudioObjectGetPropertyDataSize(systemObjectID, &address, 0, nil, &size)
        guard status == noErr else { return [] }
        
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(systemObjectID, &address, 0, nil, &size, &processIDs)
        guard status == noErr else { return [] }
        
        var matches: [AudioObjectID] = []
        for processID in processIDs {
            var bundleAddress = AudioObjectPropertyAddress(
                mSelector: 0x70626964, // 'pbid'
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var bundleIDCF: Unmanaged<CFString>? = nil
            var bundleIDSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let s = AudioObjectGetPropertyData(processID, &bundleAddress, 0, nil, &bundleIDSize, &bundleIDCF)
            if s == noErr, let cf = bundleIDCF {
                let bid = cf.takeRetainedValue() as String
                if bid == bundleID {
                    matches.append(processID)
                }
            }
        }
        return matches
    }

    public func stopTapping(bundleID: String) {
        lock.lock()
        defer { lock.unlock() }

        guard let active = activeTaps.removeValue(forKey: bundleID) else { return }

        // Teardown order is critical: aggDevID holds a reference to tapID.
        // Destroying tap before aggregate causes a dangling HAL reference.
        AudioDeviceStop(active.aggDevID, active.ioProcID)
        AudioDeviceDestroyIOProcID(active.aggDevID, active.ioProcID)
        AudioHardwareDestroyAggregateDevice(active.aggDevID)
        AudioHardwareDestroyProcessTap(active.tapID)
        print("ProcessTapManager: Stopped tapping \(bundleID)")
    }

    public func stopSystemGlobalTap() {
        stopTapping(bundleID: "system_global")
    }

    public func getRingBuffers(bundleID: String) -> [RingBuffer]? {
        lock.lock()
        defer { lock.unlock() }
        return activeTaps[bundleID]?.ringBuffers
    }

    public func getActiveTapFormat(bundleID: String) -> AudioStreamBasicDescription? {
        lock.lock()
        defer { lock.unlock() }
        return activeTaps[bundleID]?.format
    }

    public func startSystemGlobalTap() -> ([RingBuffer], AudioStreamBasicDescription)? {
        print("ProcessTapManager: startSystemGlobalTap")
        lock.lock()
        defer { lock.unlock() }

        let key = "system_global"
        if let active = activeTaps[key] {
            return (active.ringBuffers, active.format)
        }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "SoundsSource System Global Tap"
        description.muteBehavior = CATapMuteBehavior.muted

        return createAndStartTap(key: key, description: description)
    }

    private func createAndStartTap(key: String, description: CATapDescription) -> ([RingBuffer], AudioStreamBasicDescription)? {
        // Step 1: Create the process tap object.
        var tapID: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr && tapID != kAudioObjectUnknown else {
            print("ProcessTapManager: Failed to create process tap: \(tapStatus)")
            return nil
        }

        // Step 2: Get the tap's UID so we can reference it in the aggregate device.
        guard let tapUID = getTapUID(tapID) else {
            print("ProcessTapManager: Failed to get tap UID — cannot build aggregate device")
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        // Step 3: Wrap the tap in a private aggregate device.
        guard let aggDevID = createAggregateDevice(tapUID: tapUID, key: key) else {
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        // Step 4: Query format — try tap's kAudioTapPropertyFormat first, then aggDevID.
        let format: AudioStreamBasicDescription
        if let resolved = getTapFormat(tapID) ?? getStreamFormat(deviceID: aggDevID) {
            format = resolved
        } else {
            print("ProcessTapManager: Warning — stream format query failed, using 48kHz stereo float fallback")
            var fb = AudioStreamBasicDescription()
            fb.mSampleRate = 48000.0
            fb.mFormatID = kAudioFormatLinearPCM
            fb.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagsNativeEndian
            fb.mBytesPerPacket = 4
            fb.mFramesPerPacket = 1
            fb.mBytesPerFrame = 4
            fb.mChannelsPerFrame = 2
            fb.mBitsPerChannel = 32
            format = fb
        }

        let isNonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let ringBufferCount = isNonInterleaved ? Int(format.mChannelsPerFrame) : 1

        var ringBuffers: [RingBuffer] = []
        for _ in 0..<ringBufferCount {
            ringBuffers.append(RingBuffer(capacity: 256 * 1024))
        }

        // Create the TapIOContext which holds the ringBuffers and raw pointer array for real-time safety
        let ioContext = TapIOContext(ringBuffers: ringBuffers)
        let clientData = Unmanaged.passUnretained(ioContext).toOpaque()

        // Step 5: Register IOProc on aggDevID, passing ioContext as clientData.
        var ioProcID: AudioDeviceIOProcID? = nil
        let ioProcStatus = AudioDeviceCreateIOProcID(aggDevID, tapIOProc, clientData, &ioProcID)
        guard ioProcStatus == noErr, let procID = ioProcID else {
            print("ProcessTapManager: Failed to create IOProc on aggregate device: \(ioProcStatus)")
            AudioHardwareDestroyAggregateDevice(aggDevID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        // Step 6: Start the aggregate device.
        let startStatus = AudioDeviceStart(aggDevID, procID)
        guard startStatus == noErr else {
            print("ProcessTapManager: Failed to start aggregate device: \(startStatus)")
            AudioDeviceDestroyIOProcID(aggDevID, procID)
            AudioHardwareDestroyAggregateDevice(aggDevID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        let active = ActiveTap(
            tapID: tapID,
            aggDevID: aggDevID,
            ioProcID: procID,
            ringBuffers: ringBuffers,
            format: format,
            ioContext: ioContext
        )
        activeTaps[key] = active
        print("ProcessTapManager: Started tap for '\(key)' — \(format.mSampleRate)Hz \(format.mChannelsPerFrame)ch (\(isNonInterleaved ? "non-interleaved" : "interleaved"))")

        return (ringBuffers, format)
    }

    private func getTapUID(_ tapObjectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: 0x74756964,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidCF: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(tapObjectID, &address, 0, nil, &size, &uidCF)
        guard status == noErr, let cf = uidCF else { return nil }
        return cf.takeRetainedValue() as String
    }

    private func getTapFormat(_ tapObjectID: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: 0x74666d74, // 'tfmt'
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapObjectID, &address, 0, nil, &size, &format)
        return status == noErr ? format : nil
    }

    private func createAggregateDevice(tapUID: String, key: String) -> AudioObjectID? {
        var pluginAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyPlugInForBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pluginID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let bundleID = "com.apple.audio.CoreAudio" as CFString
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &pluginAddress,
            UInt32(MemoryLayout<CFString>.size),
            Unmanaged.passUnretained(bundleID).toOpaque(),
            &size,
            &pluginID
        )
        guard status == noErr && pluginID != kAudioObjectUnknown else { return nil }

        let subDeviceEntry: [String: Any] = [
            AggDevKey.subUID: tapUID
        ]
        let aggName = "SoundsSourceAggDev_\(key)"
        let aggUID = "SoundsSourceAggDevUID_\(key)"
        let description: [String: Any] = [
            AggDevKey.name: aggName,
            AggDevKey.uid: aggUID,
            AggDevKey.private_: 1,
            AggDevKey.tapList: [subDeviceEntry]
        ]

        var aggDevID = kAudioObjectUnknown
        var aggAddress = AudioObjectPropertyAddress(
            mSelector: 0x63616764, // 'cagd' — kAudioPlugInCreateAggregateDevice
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        size = UInt32(MemoryLayout<AudioObjectID>.size)
        let dictRef = description as CFDictionary
        status = AudioObjectGetPropertyData(
            pluginID,
            &aggAddress,
            UInt32(MemoryLayout<CFDictionary>.size),
            Unmanaged.passUnretained(dictRef).toOpaque(),
            &size,
            &aggDevID
        )

        if status != noErr {
            print("ProcessTapManager: Failed to create aggregate device: \(status)")
            return nil
        }
        return aggDevID
    }

    private func getStreamFormat(deviceID: AudioObjectID) -> AudioStreamBasicDescription? {
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var format = AudioStreamBasicDescription()
        let scopes = [
            kAudioDevicePropertyScopeInput,
            kAudioDevicePropertyScopeOutput,
            kAudioObjectPropertyScopeGlobal
        ]

        for scope in scopes {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamFormat,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &format)
            if status == noErr {
                return format
            }
        }

        print("ProcessTapManager: Failed to get stream format on all scopes for device \(deviceID)")
        return nil
    }

    private func getProcessObjectID(pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: 0x69643270, // 'id2p'
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var processObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var pidVal = pid

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pidVal,
            &size,
            &processObjectID
        )

        return (status == noErr && processObjectID != kAudioObjectUnknown) ? processObjectID : nil
    }
}

// C-style IOProc callback — runs on real-time audio thread, must be allocation-free and lock-free.
@available(macOS 14.2, *)
private let tapIOProc: AudioDeviceIOProc = { inDevice, _, inInputData, _, _, _, inClientData in
    guard let clientData = inClientData else { return noErr }
    let context = Unmanaged<TapIOContext>.fromOpaque(clientData).takeUnretainedValue()

    let ringBuffersPtr = context.buffersPtr
    let ringBuffersCount = context.bufferCount

    let numberBuffers = inInputData.pointee.mNumberBuffers
    let mBuffersOffset = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers)!
    let firstBufferPtr = UnsafeRawPointer(inInputData)
        .advanced(by: mBuffersOffset)
        .assumingMemoryBound(to: AudioBuffer.self)

    let buffers = UnsafeBufferPointer(start: firstBufferPtr, count: Int(numberBuffers))
    for i in 0..<Int(numberBuffers) {
        if i < ringBuffersCount, let mData = buffers[i].mData, buffers[i].mDataByteSize > 0 {
            let rb = Unmanaged<RingBuffer>.fromOpaque(ringBuffersPtr[i]).takeUnretainedValue()
            rb.writeOverwriting(mData, byteCount: Int(buffers[i].mDataByteSize))
        }
    }

    return noErr
}
