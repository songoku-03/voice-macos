# Project: SoundsSource Core Improvements

## Architecture
SoundsSource is structured into four main targets:
1. `SoundsSource`: Executable menu-bar application.
2. `UI`: SwiftUI interface for managing applications, volumes, and EQ.
3. `Engine`: Manages `AVAudioEngine` instances (specifically `OutputDeviceEngine` per output device) and routes tapped audio via `AppAudioNode`.
4. `Core`: Handles low-level Core Audio process taps (`ProcessTapManager`, aggregate devices) and the lock-free circular audio buffer (`RingBuffer`).

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| 1 | Exploration & Analysis | Initial code analysis of routing, pipeline, and button sync logic | None | DONE |
| 2 | Robust Audio Routing (R1) | Implement UserDefaults persistence for output device/follow states, sleep/wake notifications handling, configuration changes, and idle engine cleanup | M1 | DONE |
| 3 | Audio Pipeline Performance (R2) | Implement lock-free context in IOProc, atomic RingBuffer offsets, dynamic allocations/locks cleanup, and ARC capture reduction in render block | M2 | DONE |
| 4 | Tap/Power Button Sync (R3) | Implement app termination observer, periodic liveness PID check, and applicationWillTerminate cleanup | M3 | DONE |
| 5 | Verification & Forensic Audit | Run swift tests and execute teamwork_preview_auditor checks | M4 | IN_PROGRESS |

## Interface Contracts
- **AudioEngineManager ↔ ProcessTapManager**: Communication for starting/stopping taps and aggregate devices.
- **AppAudioNode ↔ RingBuffer**: Audio buffer read/write logic on real-time threads.

## Code Layout
- `Sources/Core`: Core audio capture, ring buffer, device/process enumeration.
- `Sources/Engine`: AVAudioEngine graph, routing, and preset persistence.
- `Sources/UI`: SwiftUI popover and app-specific rows.
- `Sources/SoundsSource`: App entry point and AppDelegate.
- `Tests/`: Swift scripts and test targets.
