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
public class ProcessTapManager: @unchecked Sendable {
    public static let shared = ProcessTapManager()

    private struct ActiveTap {
        let tapID: AudioObjectID
        let aggDevID: AudioObjectID   // private aggregate device wrapping the tap
        let ioProcID: AudioDeviceIOProcID
        let ringBuffers: [RingBuffer]
        let format: AudioStreamBasicDescription
    }

    private var activeTaps: [String: ActiveTap] = [:]
    private var activeTapsByDevice: [AudioObjectID: ActiveTap] = [:] // keyed by aggDevID
    private let lock = NSLock()

    private init() {}

    public func startTapping(bundleID: String, pid: pid_t) -> ([RingBuffer], AudioStreamBasicDescription)? {
        lock.lock()
        defer { lock.unlock() }

        if let active = activeTaps[bundleID] {
            return (active.ringBuffers, active.format)
        }

        guard let processObjectID = getProcessObjectID(pid: pid) else {
            print("ProcessTapManager: Could not find process object ID for PID \(pid)")
            return nil
        }

        let description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        description.name = "SoundsSource Tap (\(bundleID))"
        description.muteBehavior = CATapMuteBehavior.muted

        return createAndStartTap(key: bundleID, description: description)
    }

    public func startSystemGlobalTap() -> ([RingBuffer], AudioStreamBasicDescription)? {
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

    public func stopTapping(bundleID: String) {
        lock.lock()
        defer { lock.unlock() }

        guard let active = activeTaps.removeValue(forKey: bundleID) else { return }
        activeTapsByDevice.removeValue(forKey: active.aggDevID)

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

    fileprivate func getActiveTapInfo(for deviceID: AudioObjectID) -> ([RingBuffer], AudioStreamBasicDescription)? {
        lock.lock()
        defer { lock.unlock() }
        guard let active = activeTapsByDevice[deviceID] else { return nil }
        return (active.ringBuffers, active.format)
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
        // kAudioTapPropertyUID ('tuid') is tap-specific — kAudioObjectPropertyUID ('uid ') doesn't work on taps.
        guard let tapUID = getTapUID(tapID) else {
            print("ProcessTapManager: Failed to get tap UID — cannot build aggregate device")
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        // Step 3: Wrap the tap in a private aggregate device.
        // AudioDeviceCreateIOProcID requires an AudioDevice, but a process tap
        // AudioObject is not a device. The aggregate device bridges the gap.
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
            // 256 KB ≈ 680ms at 48kHz stereo float per channel
            ringBuffers.append(RingBuffer(capacity: 256 * 1024))
        }

        let clientData = Unmanaged.passUnretained(self).toOpaque()

        // Step 5: Register IOProc on aggDevID, not tapID.
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
            format: format
        )
        activeTaps[key] = active
        activeTapsByDevice[aggDevID] = active  // IOProc callback receives aggDevID as inDevice
        print("ProcessTapManager: Started tap for '\(key)' — \(format.mSampleRate)Hz \(format.mChannelsPerFrame)ch (\(isNonInterleaved ? "non-interleaved" : "interleaved"))")

        return (ringBuffers, format)
    }

    private func getTapUID(_ tapObjectID: AudioObjectID) -> String? {
        // kAudioTapPropertyUID = 'tuid' = 0x74756964
        // NOT kAudioObjectPropertyUID ('uid ') — process tap objects use a tap-specific selector
        var address = AudioObjectPropertyAddress(
            mSelector: 0x74756964,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidCF: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(tapObjectID, &address, 0, nil, &size, &uidCF)
        guard status == noErr, let cf = uidCF else {
            print("ProcessTapManager: kAudioTapPropertyUID query failed — status \(status)")
            return nil
        }
        return cf.takeRetainedValue() as String
    }

    private func getTapFormat(_ tapObjectID: AudioObjectID) -> AudioStreamBasicDescription? {
        // kAudioTapPropertyFormat = 'tfmt' = 0x74666d74 — format directly from tap object
        var address = AudioObjectPropertyAddress(
            mSelector: 0x74666d74,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapObjectID, &address, 0, nil, &size, &format)
        return status == noErr ? format : nil
    }

    private func createAggregateDevice(tapUID: String, key: String) -> AudioObjectID? {
        // Use raw string literals for keys to avoid SDK version / Swift 6 import issues.
        let tapEntry: [String: Any] = [AggDevKey.subUID: tapUID]
        let aggDesc: [String: Any] = [
            AggDevKey.name:     "SoundsSource-Agg-\(key)",
            AggDevKey.uid:      UUID().uuidString,
            AggDevKey.private_: true,
            AggDevKey.tapList:  [tapEntry]
        ]

        var aggDevID: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggDevID)
        guard status == noErr && aggDevID != kAudioObjectUnknown else {
            print("ProcessTapManager: Failed to create aggregate device: \(status)")
            return nil
        }
        return aggDevID
    }

    private func getStreamFormat(deviceID: AudioObjectID) -> AudioStreamBasicDescription? {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        let scopes: [AudioObjectPropertyScope] = [
            kAudioObjectPropertyScopeOutput,
            kAudioObjectPropertyScopeInput,
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
            mSelector: 0x69643270, // 'id2p' — kAudioHardwarePropertyTranslatePIDToProcessObject
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

// Debug counters (racy, debug-only — fine for diagnostics).
private nonisolated(unsafe) var tapDbgCalls = 0
private nonisolated(unsafe) var tapDbgBytes = 0

// C-style IOProc callback — runs on real-time audio thread, must be allocation-free.
// inDevice will be aggDevID (not tapID) after the aggregate device fix.
@available(macOS 14.2, *)
private let tapIOProc: AudioDeviceIOProc = { inDevice, _, inInputData, _, _, _, inClientData in
    guard let clientData = inClientData else { return noErr }
    let tapManager = Unmanaged<ProcessTapManager>.fromOpaque(clientData).takeUnretainedValue()

    guard let (ringBuffers, _) = tapManager.getActiveTapInfo(for: inDevice) else { return noErr }

    let numberBuffers = inInputData.pointee.mNumberBuffers
    let mBuffersOffset = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers)!
    let firstBufferPtr = UnsafeRawPointer(inInputData)
        .advanced(by: mBuffersOffset)
        .assumingMemoryBound(to: AudioBuffer.self)

    let buffers = UnsafeBufferPointer(start: firstBufferPtr, count: Int(numberBuffers))
    var wrote = 0
    for (i, buffer) in buffers.enumerated() {
        if i < ringBuffers.count, let mData = buffer.mData, buffer.mDataByteSize > 0 {
            ringBuffers[i].writeOverwriting(mData, byteCount: Int(buffer.mDataByteSize))
            wrote += Int(buffer.mDataByteSize)
        }
    }

    tapDbgCalls += 1
    tapDbgBytes += wrote
    if tapDbgCalls % 100 == 0 {
        print("TAP[capture]: calls=\(tapDbgCalls) lastWrote=\(wrote)B numBuffers=\(numberBuffers) ringAvail=\(ringBuffers.first?.bytesAvailableForRead ?? -1)B")
    }

    return noErr
}
