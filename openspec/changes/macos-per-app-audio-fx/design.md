## Context

macOS exposes audio routing through the Core Audio HAL (Hardware Abstraction Layer). Until macOS 14.2 (Sonoma), intercepting per-process audio required kernel extensions or private APIs — both untenable for distribution. The new `CATapDescription` / `AudioHardwareCreateProcessTap` public API enables clean per-process audio capture in user space.

The app must bridge three distinct subsystems:
1. **Core Audio HAL** (low-level, C API, real-time safe) — process tap, device enumeration
2. **AVAudioEngine** (high-level Swift-friendly graph) — FX chain, mixing, output routing
3. **Audio Server Plug-in** (C/C++, runs inside `coreaudiod`) — optional virtual device layer

Current state: empty project. No existing audio code to preserve.

## Goals / Non-Goals

**Goals:**
- Capture audio from individual macOS processes without modifying them
- Apply per-app parametric EQ and volume control in real time
- Mix processed streams and route to any output device
- Provide SwiftUI menu bar UI for live control
- Optional virtual audio device for transparent system-wide EQ (Phase 2)
- Persist presets across launches

**Non-Goals:**
- App Store distribution (incompatible with required entitlements)
- iOS / iPadOS support
- Recording / DAW integration
- MIDI control
- Plugin host (AUv3 host only for our own EQ units, not third-party)

## Decisions

### D1: Phase split — skip virtual device in Phase 1

**Decision**: Phase 1 uses Process Tap → AVAudioEngine → real output only. The HAL plugin (virtual device) is Phase 2.

**Rationale**: HAL plugin complexity (C/C++, coreaudiod sandbox, separate code-signed bundle, installer) is high and only needed for the "transparent proxy" use case. Per-app EQ (the primary use case) works without it. Phase 1 ships faster and validates the core loop.

**Alternative considered**: Build virtual device first, use it as the audio source. Rejected — makes debugging harder and adds 3-4 weeks to MVP.

---

### D2: Process Tap → AVAudioEngine bridge via AVAudioSourceNode

**Decision**: Use `AVAudioSourceNode` with a render block that pulls samples from the Core Audio tap's IOProc buffer.

```
CATap (Core Audio)
  │  AudioBufferList via render callback (real-time thread)
  ▼
AVAudioSourceNode (render block — pull model)
  │
AVAudioEngine graph
  │
AUv3 EQ node (per-app)
  │
AVAudioMixerNode (global mix)
  │
AVAudioOutputNode → kAudioObjectSystemObject
```

**Rationale**: `AVAudioSourceNode` is the standard bridge between raw PCM sources and AVAudioEngine. The render block runs on the audio thread — must be real-time safe (no malloc, no ObjC, no locks).

**Alternative considered**: `AVAudioPCMBuffer` ring buffer with manual scheduling. Rejected — adds latency and drift without benefit.

---

### D3: EQ implementation — use `AVAudioUnitEQ` (built-in), not custom AUv3 v1

**Decision**: Ship with `AVAudioUnitEQ` (system-provided parametric EQ, up to 16 bands) for Phase 1. Custom AUv3 is Phase 3 if needed.

**Rationale**: `AVAudioUnitEQ` is mature, zero-latency, and already AUv3-compatible. Building a custom AUv3 adds weeks and App Extension sandboxing complexity. Users get a working EQ faster.

**Alternative considered**: Third-party DSP lib (SoundpipeAudioKit). Rejected — adds dependency, license concerns.

---

### D4: Audio thread safety — lock-free ring buffer for tap → engine handoff

**Decision**: If the tap callback and engine render block run on different threads (likely), use a lock-free single-producer / single-consumer ring buffer (TPCircularBuffer or similar) to pass audio between them.

**Rationale**: Core Audio render callbacks are real-time and cannot block. Any shared state between tap and engine must be lock-free.

**Alternative considered**: `os_unfair_lock` with try-lock. Rejected — can still cause priority inversion.

---

### D5: Process enumeration — poll + NSWorkspace notifications

**Decision**: Build initial process list from `AudioObjectGetPropertyData(kAudioHardwarePropertyTranslateUIDToDevice)` + `NSRunningApplication`, refresh on `NSWorkspaceDidLaunchApplicationNotification` / `NSWorkspaceDidTerminateApplicationNotification`. Filter to processes with active audio output via `kAudioHardwarePropertyDevices` / tap probing.

**Rationale**: No single API gives "processes currently producing audio". Combining workspace notifications with tap probe (attach tap, check if audio flows) is the most reliable approach.

---

### D6: HAL Plugin (Phase 2) — separate signed bundle, not System Extension

**Decision**: Distribute HAL plugin as a standard Audio Server Plug-in (`/Library/Audio/Plug-Ins/HAL/`), not a System Extension.

**Rationale**: System Extensions require notarization + DriverKit, and DriverKit for audio is still limited. Traditional HAL plug-ins (like BlackHole) are well-understood, don't require kernel entitlements, and can be notarized. Installer (PKG) handles placement and `coreaudiod` restart.

## Risks / Trade-offs

**[Process Tap entitlement availability]** → Apple may require private entitlement for `CATapDescription` in some contexts. Mitigation: test on non-developer Mac; fall back to aggregate device tap if per-process tap is restricted.

**[Real-time thread violations]** → `AVAudioSourceNode` render block must be RT-safe. Any Swift allocation or ObjC message causes glitches or crashes. Mitigation: write render block in C or carefully audited Swift; use `os_signpost` to profile.

**[Multi-tap drift]** → Multiple process taps may have slightly different clocks, causing drift over time. Mitigation: use a single aggregate tap (tap all processes into one stream) if per-process independent clocks prove problematic.

**[HAL Plugin installer UX]** → Installing to `/Library/Audio/Plug-Ins/HAL/` requires admin auth and `coreaudiod` restart (audible pop). Mitigation: make Phase 2 opt-in, show clear warning in UI before install.

**[macOS version fragmentation]** → Process Tap = macOS 14.2+. Drop below that = no core feature. Mitigation: hard minimum 14.2 in Info.plist.

## Open Questions

1. Does `CATapDescription` require a private entitlement on non-development machines? Need to test on a clean Mac.
2. Can we tap the system mixer (aggregate tap) as a simpler alternative to per-process taps for the system-wide EQ use case?
3. For the virtual device (Phase 2): user-space AudioServerPlugin vs DriverKit AudioDriverKit — is DriverKit stable enough on macOS 14+ for audio?
