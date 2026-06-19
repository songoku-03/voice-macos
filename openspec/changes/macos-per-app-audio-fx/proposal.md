## Why

macOS has no built-in per-app EQ or audio routing control. Users who want to apply EQ to Spotify independently of Zoom, or duck a browser tab while keeping music loud, have no native option. Third-party solutions (Boom 3D, eqMac) are closed-source, subscription-based, or don't expose per-process granularity. Process Tap API (macOS 14.2+) now makes per-app audio capture possible without kernel extensions.

## What Changes

- New macOS menu bar app (Swift + SwiftUI) for per-app and per-device audio control
- Per-process audio capture via Core Audio Process Tap API
- Per-app EQ and volume chain using AVAudioEngine + AUv3 Audio Units
- Optional virtual audio device (Audio Server Plug-in, C/C++) for transparent system-wide routing
- Real-time mixer that re-routes processed audio to user-selected output device

## Capabilities

### New Capabilities

- `process-tap`: Enumerate running audio-producing processes, attach/detach Core Audio Process Taps per process, stream raw PCM into the processing engine
- `audio-engine`: AVAudioEngine graph wiring — per-app source nodes, parametric EQ chains (AUv3), volume/pan controls, mix to output device
- `virtual-device`: Audio Server Plug-in (C/C++) implementing a HAL virtual audio device; acts as proxy output so any app can route through the FX chain without explicit configuration
- `menu-bar-ui`: SwiftUI menu bar app — live list of audio-producing apps, per-app controls (volume, EQ toggle, mute), output device selector, preset management
- `preset-management`: Save/load EQ and routing presets per app or per output device; persist across launches via UserDefaults or JSON config

### Modified Capabilities

## Impact

- **Platform**: macOS 14.2+ (Sonoma) minimum; SDK 26.5 used for development
- **Languages**: Swift 6 (app + engine layer), C/C++ (HAL plugin)
- **Distribution**: Direct download only (DMG/PKG) — App Store incompatible due to HAL plugin + Process Tap entitlements
- **Entitlements needed**: `com.apple.security.temporary-exception.audio-unit-host`, potentially `com.apple.developer.avfoundation.capture-session` variants; HAL plugin requires separate signed bundle in `/Library/Audio/Plug-Ins/HAL/`
- **No sandbox**: Main app must run unsandboxed to install/manage HAL plugin and access Process Tap
- **Dependencies**: No third-party audio libs; pure Apple frameworks (CoreAudio, AVFoundation, AudioToolbox)
