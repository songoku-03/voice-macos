# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Build release app bundle (signed ad-hoc, ready to launch)
./scripts/build_app.sh

# Build debug app bundle
./scripts/build_app.sh --debug

# Build only (no bundle assembly)
swift build -c release

# Run tests
swift test

# Run single test
swift test --filter PlaceholderTests
```

The assembled `.app` lands at `build/SoundsSource.app`. Launch it from Finder or `open build/SoundsSource.app`.

## Requirements

- macOS 14.2+ (uses `CATapDescription` / `AudioHardwareCreateProcessTap` — new in macOS 14.2)
- No sandbox (`com.apple.security.app-sandbox = false`) — required for process audio tapping
- Entitlements: `com.apple.security.system-audio-capture` + `com.apple.security.temporary-exception.audio-unit-host`
- Ad-hoc code signing via `codesign --sign -` (no Apple Developer account needed locally)

## Architecture

Four SPM targets with a strict dependency chain:

```
SoundsSource (executable)
    └── UI → Engine → Core
         └── (HALPlugin — standalone C++ target, not linked to main app)
```

### Core (`Sources/Core/`)
Low-level audio primitives:
- `AudioProcess` — value type representing a running app with audio output
- `AudioProcessEnumerator` — `@Observable` class; queries CoreAudio `'prs#'` property to list all audio-producing processes; refreshes on app launch/terminate via `NSWorkspace` notifications and a CoreAudio property listener
- `ProcessTapManager` — singleton; creates/destroys `CATapDescription` process taps via `AudioHardwareCreateProcessTap`; feeds captured PCM into `RingBuffer`s via a C-style `AudioDeviceIOProc` callback
- `RingBuffer` — lock-free circular buffer for audio bytes

### Engine (`Sources/Engine/`)
AVAudioEngine graph management:
- `AudioEngineManager` — `@Observable` singleton; owns one `OutputDeviceEngine` per output device; manages per-app `AppAudioNode` lifecycle (attach/detach from engine graph); handles device switching by migrating active nodes; stores volume/mute/EQ state keyed by bundle ID; persists settings as presets via `PresetStore`
- `AppAudioNode` — wraps an `AVAudioSourceNode` + `AVAudioUnitEQ` pair; reads from `RingBuffer`s in its render block; uses `AudioConverter` when sample rate/channel count differs between tap format and engine format
- `EQController` — thin wrapper around `AVAudioUnitEQ`; 10 parametric bands at 32 Hz–16 kHz; handles preset serialization (`EQPresetData` / `EQBandData` are `Codable`)
- `PresetStore` — `@Observable` singleton; persists presets to `UserDefaults` as JSON
- `AudioDevice` — value type with `deviceID`, `name`, `uid`

### UI (`Sources/UI/`)
SwiftUI menu bar popover:
- `PopoverContentView` — root view; hosts process list + preset picker + output device picker
- `ProcessListView` / `AppRowView` — list of tappable processes; each row toggles tapping and shows volume/mute controls
- `AppControlsView` — per-app volume slider + mute toggle
- `EQCurveEditor` — interactive EQ curve visualization/editing
- `OutputDevicePicker` — picker bound to `AudioEngineManager.selectedDeviceID`

### Entry Point (`Sources/SoundsSource/`)
- `main.swift` — creates `NSApplication`, sets delegate
- `AppDelegate` — creates `NSStatusItem` (menu bar icon), `NSPopover` with `PopoverContentView`, initializes `AudioEngineManager.shared`

### HALPlugin (`Sources/HALPlugin/`)
Standalone C++ target — a CoreAudio HAL plugin stub. Not linked into the main app; built separately if needed.

## Key Data Flow

```
CATapDescription (per app or system global)
    → AudioDeviceIOProc callback → RingBuffer(s)
        → AVAudioSourceNode render block (pulls from RingBuffer)
            → AVAudioUnitEQ (10-band parametric)
                → AVAudioMixerNode (per OutputDeviceEngine)
                    → AVAudioOutputNode → physical output device
```

## CoreAudio Property Selectors

Several selectors are used as raw 4CC hex values because Swift doesn't expose them directly:
- `0x70727323` (`'prs#'`) — `kAudioHardwarePropertyProcessObjectList`
- `0x70706964` (`'ppid'`) — process PID
- `0x70626964` (`'pbid'`) — process bundle ID
- `0x7069726f` (`'piro'`) — process is running output
- `0x69643270` (`'id2p'`) — translate PID to process object
