# SoundsSource

A macOS menu bar app for **per-application audio control**. Capture the audio of any running app, then adjust its volume, mute it, apply a 10-band parametric EQ, and route it to any output device — independently of every other app.

Built on CoreAudio process taps (`AudioHardwareCreateProcessTap`) and AVAudioEngine.

> **Note:** Requires macOS 14.2+. Process audio tapping uses `CATapDescription` / `AudioHardwareCreateProcessTap`, which are only available on macOS 14.2 and later.

---

## Features

- **Per-app capture** — tap the audio output of any individual app (Spotify, browsers, Discord, games…).
- **Per-app volume & mute** — independent volume slider and mute toggle for each captured app.
- **10-band parametric EQ** — per-app equalizer (32 Hz – 16 kHz) with an interactive curve editor.
- **Per-app output routing** — send each app to a different output device (e.g. Spotify → headphones, game → speakers).
- **Presets** — save and restore volume + EQ configurations across apps; set a default preset applied on launch.
- **Smart process list** — only shows apps currently producing audio. Helper/renderer processes (Chrome, Cốc Cốc, Discord) are resolved to their parent app's name and icon.
- **Live device handling** — follows the system default output and migrates active apps when devices are plugged/unplugged.

---

## Requirements

- macOS **14.2** or later
- Swift 6 toolchain (Xcode 16+ command line tools)
- No Apple Developer account needed — the app is signed ad-hoc locally

The app runs **without the sandbox** (required for process audio tapping) and uses these entitlements:

- `com.apple.security.system-audio-capture`
- `com.apple.security.temporary-exception.audio-unit-host`

On first launch macOS will ask for **audio recording permission** — grant it so the app can capture process audio.

---

## Build & Run

```bash
# Build a release .app bundle (ad-hoc signed, ready to launch)
./scripts/build_app.sh

# Build a debug bundle
./scripts/build_app.sh --debug

# Build only (no bundle assembly)
swift build -c release
```

The assembled bundle lands at `build/SoundsSource.app`. Launch it:

```bash
open build/SoundsSource.app
```

A waveform icon appears in the menu bar — click it to open the control popover.

### Tests

```bash
# Run all tests
swift test

# Run a single test
swift test --filter PlaceholderTests
```

---

## Usage

1. Click the menu bar icon to open the popover.
2. The list shows every app currently playing audio.
3. Click the **power button** on a row to start capturing that app.
4. Expand the row (chevron) to access:
   - **Volume** slider and **mute** toggle
   - **Route to** — pick an output device for that app
   - **EQ** — toggle and edit the 10-band curve
5. Use **Save Preset** to store the current volume/EQ setup across all apps, and the preset picker (top-left) to switch between saved presets.

---

## Architecture

Four SPM targets with a strict dependency chain:

```
SoundsSource (executable)
    └── UI → Engine → Core
         └── (HALPlugin — standalone C++ target, not linked into the app)
```

### `Sources/Core/` — low-level audio primitives
- **`AudioProcess`** — value type for a running app with audio output.
- **`AudioProcessEnumerator`** — `@Observable`; lists audio-producing processes via the CoreAudio `'prs#'` property; resolves helper processes to their parent app; refreshes on app launch/terminate and on CoreAudio property changes.
- **`ProcessTapManager`** — singleton; creates/destroys process taps (`CATapDescription` + private aggregate device) and feeds captured PCM into ring buffers via a C-style `AudioDeviceIOProc`.
- **`RingBuffer`** — lock-free circular buffer for audio bytes.

### `Sources/Engine/` — AVAudioEngine graph management
- **`AudioEngineManager`** — `@Observable` singleton; owns one engine per output device; manages per-app node lifecycle, device switching, volume/mute/EQ state, and presets.
- **`AppAudioNode`** — wraps an `AVAudioSourceNode` + `AVAudioUnitEQ`; reads from ring buffers and converts sample rate / channel count when the tap and engine formats differ.
- **`EQController`** — thin wrapper over `AVAudioUnitEQ` (10 parametric bands); handles preset serialization.
- **`PresetStore`** — `@Observable`; persists presets to `UserDefaults` as JSON.
- **`AudioDevice`** — value type (`deviceID`, `name`, `uid`).

### `Sources/UI/` — SwiftUI menu bar popover
- **`PopoverContentView`** — root view (process list + preset picker + output device picker).
- **`ProcessListView` / `AppRowView`** — tappable process list with per-row controls.
- **`AppControlsView`** — per-app volume slider + mute toggle.
- **`EQCurveEditor`** — interactive EQ curve editor.
- **`OutputDevicePicker`** — output device selector.

### `Sources/SoundsSource/` — entry point
- **`main.swift`** — creates `NSApplication` and sets the delegate.
- **`AppDelegate`** — creates the `NSStatusItem`, the `NSPopover`, and initializes `AudioEngineManager.shared`.

### `Sources/HALPlugin/` — standalone C++ CoreAudio HAL plugin stub
Not linked into the main app; built separately if needed.

## Audio data flow

```
CATapDescription (per app or system-global)
    → AudioDeviceIOProc callback → RingBuffer(s)
        → AVAudioSourceNode render block (pulls from RingBuffer)
            → AVAudioUnitEQ (10-band parametric)
                → AVAudioMixerNode (per output engine)
                    → AVAudioOutputNode → physical output device
```

---

## License

No license file is currently included. Add one before publishing if you intend others to reuse the code.
