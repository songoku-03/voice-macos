## 1. Project Setup

- [x] 1.1 Create Xcode project: macOS App (SwiftUI), no sandbox, deployment target macOS 14.2
- [x] 1.2 Set up project structure: `Core/`, `Engine/`, `UI/`, `HALPlugin/` directories
- [x] 1.3 Configure entitlements: disable App Sandbox, add `com.apple.security.temporary-exception.audio-unit-host`
- [x] 1.4 Set LSUIElement = YES in Info.plist (hide Dock icon, menu bar only)
- [x] 1.5 Add C/C++ target for HAL plugin (separate bundle target in same Xcode project)

## 2. Process Tap — Core Audio Layer

- [x] 2.1 Implement `AudioProcessEnumerator`: list running apps, filter to those with audio output using Core Audio property queries
- [x] 2.2 Subscribe to `NSWorkspaceDidLaunchApplicationNotification` + `NSWorkspaceDidTerminateApplicationNotification` for live list updates
- [x] 2.3 Implement `ProcessTapManager`: create/destroy `CATap` via `AudioHardwareCreateProcessTap` per process PID
- [x] 2.4 Implement lock-free ring buffer (TPCircularBuffer or hand-rolled SPSC) for tap → engine audio handoff
- [x] 2.5 Write tap IOProc that writes captured `AudioBufferList` into ring buffer (real-time safe, no alloc)
- [x] 2.6 Implement aggregate tap mode: single `CATapDescription` capturing all output processes
- [x] 2.7 Test: verify tap produces correct PCM on Spotify, Safari, and Zoom simultaneously

## 3. AVAudioEngine Graph

- [x] 3.1 Implement `AudioEngineManager`: owns `AVAudioEngine` instance, manages start/stop/restart
- [x] 3.2 Implement `AppAudioNode`: pairs `AVAudioSourceNode` + `AVAudioUnitEQ` for one process; render block pulls from ring buffer
- [x] 3.3 Connect `AppAudioNode` to `AVAudioMixerNode` (global mix) → `AVAudioOutputNode`
- [x] 3.4 Implement dynamic graph modification: add/remove `AppAudioNode` while engine is running without stopping it
- [x] 3.5 Implement `AVAudioConverter` for sample rate and channel format mismatch between tap format and engine format
- [x] 3.6 Implement per-app volume control: set mixer input bus volume on `AVAudioMixerNode`
- [x] 3.7 Implement per-app mute: store pre-mute volume, set bus to 0.0 on mute, restore on unmute
- [x] 3.8 Implement output device switching: change engine output node's manual rendering device without restart
- [x] 3.9 Test: verify end-to-end latency ≤ 20ms at 512-sample buffer; verify no RT violations with `os_signpost`

## 4. EQ Control

- [x] 4.1 Wrap `AVAudioUnitEQ` in `EQController`: expose `setBand(index:frequency:gain:q:type:)` API
- [x] 4.2 Implement EQ bypass toggle per app (`avAudioUnit.bypass`)
- [x] 4.3 Define `EQPresetData` Codable struct: array of band parameters + bypass state + volume
- [x] 4.4 Test: verify EQ changes apply within one buffer cycle, no zipper noise on gain sweep

## 5. Menu Bar UI

- [x] 5.1 Implement `AppDelegate` with `NSStatusItem`; use SwiftUI `NSPopover` for popover content
- [x] 5.2 Create `ProcessListView`: scrollable list of `AppRowView` items bound to `AudioProcessEnumerator` observable
- [x] 5.3 Create `AppRowView`: app icon + name + VU meter + expand toggle
- [x] 5.4 Implement real-time VU meter: read RMS from `AVAudioMixerNode` metering data, update at 30fps via `CADisplayLink`
- [x] 5.5 Create `AppControlsView` (expanded state): volume slider, mute button, EQ toggle
- [x] 5.6 Create `EQCurveEditor`: SwiftUI Canvas-based graphical EQ with draggable band nodes (frequency = x, gain = y)
- [x] 5.7 Create `OutputDevicePicker`: dropdown listing available `AVAudioOutputNode` devices
- [x] 5.8 Create empty state view: "No apps playing audio" shown when process list is empty
- [x] 5.9 Create preset selector in popover header: name display + Load/Save buttons
- [x] 5.10 Test: verify popover opens/closes, controls respond live, no main-thread audio operations

## 6. Preset Management

- [x] 6.1 Define `Preset` Codable struct: name, isDefault flag, dictionary of `[bundleID: EQPresetData]`
- [x] 6.2 Implement `PresetStore`: read/write `~/Library/Application Support/SoundsSource/presets.json`
- [x] 6.3 Implement save-current-state-as-preset from `AudioEngineManager` state
- [x] 6.4 Implement load-preset: apply per-app settings to running apps; cache settings for not-yet-running apps
- [x] 6.5 Implement default preset auto-apply on engine start
- [x] 6.6 Implement rename and delete operations in `PresetStore`
- [x] 6.7 Test: save preset, quit app, relaunch, verify preset persists and auto-applies

## 7. Virtual Audio Device — HAL Plugin (Phase 2)

- [ ] 7.1 Set up C/C++ HAL plugin target: bundle type `AudioServerPlugIn`, implement `AudioServerPlugIn_CreateInitOpts`
- [ ] 7.2 Implement `AudioServerPlugInDriverInterface` vtable: GetPropertyDataSize, GetPropertyData, SetPropertyData for Device/Stream/Control objects
- [ ] 7.3 Implement virtual device IOProc: ring buffer to pass audio from plugin (coreaudiod) to main app
- [ ] 7.4 Advertise supported formats: Float32 stereo @ 44100Hz and 48000Hz
- [ ] 7.5 Implement privileged helper tool (SMAppService) for plugin install/uninstall to `/Library/Audio/Plug-Ins/HAL/`
- [ ] 7.6 Implement plugin presence check on app launch; prompt re-install if missing
- [ ] 7.7 Add "SoundsSource Device" toggle in UI with install/uninstall flow and coreaudiod restart warning
- [ ] 7.8 Code-sign plugin bundle with Hardened Runtime; notarize installer package
- [ ] 7.9 Test: virtual device appears in System Settings; Spotify routes to it; processed audio heard from speakers

## 8. Distribution

- [ ] 8.1 Set up code signing: Developer ID Application + Installer certificates
- [ ] 8.2 Build DMG for Phase 1 (no HAL plugin); build PKG for Phase 2 (includes HAL plugin)
- [ ] 8.3 Notarize and staple both distribution artifacts
- [ ] 8.4 Test on clean macOS 14.2 VM: install, verify process tap works without existing audio setup

## 9. Bug Fixes (Phase 1 Corrections)

> **Review note**: Section 9 was auto-reviewed via /autoplan. Tasks below incorporate corrections from dual-voice eng review — 8 task-level bugs and 2 scope gaps found and addressed.

### Fix A — Process Tap IOProc via Aggregate Device (blocks all audio)

**Root cause**: `AudioDeviceCreateIOProcID(tapID, ...)` fails with `kAudioHardwareBadDeviceError` (~`0x21646576`). A process tap `AudioObjectID` from `AudioHardwareCreateProcessTap` is not an `AudioDevice` and does not accept IOProc registration directly. The stream format query also fails on `tapID` for the same reason.

**Fix**: Wrap the tap in a private HAL aggregate device before creating the IOProc. The aggregate device IS a proper `AudioDevice` and accepts IOProc registration. This is the required macOS 14.2+ pattern for process taps.

**Design note on `muteBehavior = .muted`**: This is intentional. With `.muted`, the source app's audio is removed from the system mix when tapped — SoundsSource becomes the exclusive output path and re-outputs the processed audio through the engine. If Fix A fails silently, the source app goes silent with no audio output. Verify Fix A works end-to-end before shipping to avoid this UX trap.

- [x] 9.1 In `ProcessTapManager.createAndStartTap`: after `AudioHardwareCreateProcessTap` succeeds, query `kAudioObjectPropertyUID` (raw 4CC `0x75696420`) from `tapID` via `getObjectUID(_:)` helper
- [x] 9.2 Create a private aggregate device via `AudioHardwareCreateAggregateDevice` with raw-string keys (CFString constant import unreliable in Swift 6): `"name"`, `"uid"` (UUID), `"private": true`, `"taps": [["uid": tapUID]]`; store returned `aggDevID`
- [x] 9.3 Replace `AudioDeviceCreateIOProcID(tapID, ...)` / `AudioDeviceStart(tapID, ...)` with `aggDevID`
- [x] 9.4 `getStreamFormat` now receives `aggDevID` (renamed parameter from `tapID` to `deviceID`); aggregate device exposes stream format where raw tap object did not
- [x] 9.5 `stopTapping` teardown order fixed: Stop → DestroyIOProc → DestroyAggregateDevice → DestroyProcessTap
- [x] 9.6 `ActiveTap` struct gains `aggDevID: AudioObjectID` field alongside `tapID`
- [x] 9.7 `activeTapsByDevice` keyed by `aggDevID`; IOProc callback receives `inDevice = aggDevID` → lookup resolves correctly
- [ ] 9.8 Verify entitlements: confirm `com.apple.security.system-audio-capture` in `entitlements.plist` covers `CATapDescription` on the target macOS version (14.2+); if tap creation starts failing on non-dev machines, may need `com.apple.developer.coreaudio.process-tap` (private entitlement requiring Apple approval)
- [ ] 9.9 Test: tap Spotify → verify IOProc fires → ring buffer fills → hear EQ-processed audio on output device; also verify Spotify audio resumes when tap is stopped

### Fix B — Per-app Volume Control (silent no-op)

**Root cause**: `setNodeVolume(_ node: AVAudioNode, _ volume: Float)` casts `AVAudioUnitEQ` to `AVAudioMixing` — always fails because `AVAudioUnitEQ` (`AVAudioUnit → AVAudioNode`) does not conform to `AVAudioMixing`. Volume stored in `busVolumes` dict but never applied to the graph.

**Fix**: Insert a per-app `AVAudioMixerNode` between `AVAudioSourceNode` and `AVAudioUnitEQ`. `AVAudioMixerNode` conforms to `AVAudioMixing`. Additionally fix the `Slider` in `AppControlsView` which only calls `setVolume` at drag start/end, not continuously.

New per-app graph:
```
AVAudioSourceNode  →  AVAudioMixerNode (volume/mute here)  →  AVAudioUnitEQ  →  global AVAudioMixerNode
```

- [ ] 9.10 Add `volumeNode: AVAudioMixerNode` property to `AppAudioNode`; initialize it (`AVAudioMixerNode()`) in `AppAudioNode.init` — do NOT attempt engine connections here (no engine reference available in init)
- [ ] 9.11 In `AudioEngineManager.startAppTapping`:
  - Add `devEngine.engine.attach(appNode.volumeNode)`
  - Replace the current `connect(sourceNode → eqNode)` with two calls:
    ```
    engine.connect(appNode.sourceNode, to: appNode.volumeNode, format: engineFormat)
    engine.connect(appNode.volumeNode, to: appNode.eqNode, format: engineFormat)
    ```
  - The `connect(eqNode → devEngine.mixer)` call stays unchanged
- [ ] 9.12 In `AudioEngineManager.stopAppTapping`:
  - Add `disconnectNodeInput(appNode.volumeNode, bus: 0)` before `detach(appNode.volumeNode)` (detaching a connected node leaves graph inconsistent)
  - Add `devEngine.engine.detach(appNode.volumeNode)` alongside existing detach calls
- [ ] 9.13 In `AudioEngineManager.setAppOutputDevice` and `migrateActiveNode`: add `disconnectNodeInput(appNode.volumeNode, bus: 0)` before old-engine detach; add `newDevEngine.engine.attach(appNode.volumeNode)` + reconnect the full chain `sourceNode → volumeNode → eqNode` on the new engine
- [ ] 9.14 Fix `setNodeVolume`: change the node passed in from `appNode.eqNode` to `appNode.volumeNode` in all callers (`setVolume`, `setMute`, `startAppTapping` volume restore)
- [ ] 9.15 Fix `AppControlsView` volume slider: replace `onEditingChanged` with `.onChange(of: volume)` so `setVolume` fires on every frame during drag, not just at drag start/end:
  ```swift
  Slider(value: $volume, in: 0.0...2.0)
      .onChange(of: volume) { _, newValue in
          AudioEngineManager.shared.setVolume(bundleID: bundleID, volume: newValue)
      }
  ```
- [ ] 9.16 Test: drag slider continuously → verify volume changes in real-time while dragging; mute → silence; unmute → volume restored at pre-mute level; switch output device while volume at 50% → verify volume persists at 50% on new device

### Fix C — Output Picker Async Race + Redundant Refresh

**Root cause**: `refreshDevices()` wraps `outputDevices` and `selectedDeviceID` assignment in `Task { @MainActor in ... }` — unnecessary since `AudioEngineManager` is already `@MainActor`. This defers assignment by one run-loop turn, causing the picker to render blank on first open. Additionally, `init()` calls `refreshDevices()` twice (once via `setupEngine()`, once directly).

- [ ] 9.17 In `AudioEngineManager.refreshDevices()`: remove the `Task { @MainActor in ... }` wrapper entirely. Assign `self.outputDevices = finalDevices` and `self.selectedDeviceID = ...` synchronously (the method is already on `@MainActor`, the Task adds no value and introduces the race)
- [ ] 9.18 In `AudioEngineManager.setupEngine()`: call `self.selectedDeviceID = getDefaultOutputDeviceID()` as the first line (before calling `refreshDevices()`) so the engine is initialized with a valid device before any async path runs
- [ ] 9.19 Remove the second `refreshDevices()` call from `AudioEngineManager.init()` — it is already called inside `setupEngine()`
- [ ] 9.20 Test: open popover immediately after launch → global output picker shows current device (not blank); change output device in System Settings → picker updates within 1 second via CoreAudio listener
