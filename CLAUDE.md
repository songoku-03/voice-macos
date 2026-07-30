# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

SoundsSource is a macOS menu-bar app for per-application audio control: capture any app's audio, then set its own volume, mute, 10-band EQ, and output device. It is built on Apple's Core Audio **process-tap** API (`CATapDescription`, `AudioHardwareCreateProcessTap`), which only exists on **macOS 14.2+** — hence almost every type is gated behind `@available(macOS 14.2, *)`.

## Commands

```bash
# Build the executable (SwiftPM)
swift build                      # debug
swift build -c release

# Assemble + ad-hoc-sign the .app bundle (required to actually run — see below)
./scripts/build_app.sh           # release → build/SoundsSource.app
./scripts/build_app.sh --debug   # debug build
./scripts/build_dmg.sh           # package build/SoundsSource.dmg

open build/SoundsSource.app      # launch

# Tests (XCTest suite in the EngineTests target)
./scripts/test.sh                                   # full suite
./scripts/test.sh --filter PresetStoreTests         # one test class
./scripts/test.sh --filter PresetStoreTests/testRename   # one test method
```

**Always run tests via `./scripts/test.sh`, not `swift test` directly.** Under Command Line Tools (no full Xcode), SwiftPM doesn't add the Swift Testing framework's search/runtime paths; the script passes them explicitly. With a full Xcode install the flags are harmless.

**You cannot just `swift run` this app.** Audio capture requires running **unsandboxed** with the `com.apple.security.system-audio-capture` entitlement (see `entitlements.plist`), which only takes effect on a code-signed bundle. `build_app.sh` copies the binary + `Info.plist` into the bundle and applies an ad-hoc signature (`codesign --sign -`). The first launch also prompts for the microphone/recording permission, which must be granted or no audio flows.

## Architecture

Four SwiftPM targets in a strict dependency stack (`Package.swift`); upper layers depend only downward:

```
SoundsSource (executable: menu-bar app, AppDelegate)
  └─ UI       (SwiftUI popover, app rows, EQ curve editor)
       └─ Engine   (AVAudioEngine graph, routing, EQ, preset persistence)
            └─ Core (Core Audio process taps, process enumeration, RingBuffer)
```

### The audio pipeline (the part that requires reading several files)

The signal path crosses a real-time boundary via lock-free ring buffers:

1. **`Core/ProcessTapManager`** creates a `CATapDescription` for an app's process object(s), wraps it in a **private aggregate device** (a process tap is not itself an `AudioDevice`, so the aggregate bridges it to `AudioDeviceCreateIOProcID`), and registers a C IOProc. That IOProc runs on the **real-time audio thread** and must stay allocation-free — it only `writeOverwriting`s captured bytes into `Core/RingBuffer` instances (one per channel when non-interleaved).
2. **`Engine/AudioEngineManager`** (the central `@MainActor @Observable` singleton, `.shared`) owns one **`OutputDeviceEngine` (an `AVAudioEngine`) per output device**. Each tapped app becomes an **`Engine/AppAudioNode`** connected to that engine's mixer on its own dynamically allocated bus. This is what enables routing different apps to different devices simultaneously.
3. **`Engine/AppAudioNode`** holds an `AVAudioSourceNode` whose render block (also real-time) pulls from the ring buffers — directly when formats match, or through an `AudioConverter` when the tap format differs from the engine format — then applies per-app volume and feeds the `SpectrumTap` analyzer. The EQ is an `AVAudioUnitEQ` (10 bands) sitting between the source node and the mixer, driven by `Engine/EQController`.

All per-app state in `AudioEngineManager` (volume, mute, routing, EQ) is **keyed by bundle ID**, not PID. Settings for apps that aren't currently tapped are held in `cachedAppSettings` and re-applied when the app starts playing again.

### State, persistence, and device-following conventions

- **`Engine/PresetStore`** (`@MainActor @Observable`, `.shared`) is the SwiftUI-observed source of truth for presets. It delegates all disk I/O to the **`Engine/PresetRepository` actor** (off the main thread). Saves are fire-and-forget but **chained through `pendingSave`** so rapid mutations land on disk in order; `flush()` awaits the in-flight write (used at termination and in tests). `FileStoring` is injected so tests use `InMemoryFileStore` instead of touching disk. Presets persist to `~/Library/Application Support/SoundsSource/presets.json`.
- **Device following:** `selectedDeviceID` follows the system default output until the user makes an explicit pick (`followsSystemDefault` flips to false). The `_suppressFollowReset` flag lets internal listeners update `selectedDeviceID` *without* counting as a user pick. Don't remove these flags without understanding the Core Audio property listeners in `setupListeners()`.
- **Helper-process resolution:** Browsers (Chrome, Cốc Cốc, Edge) and Electron apps (Discord) emit audio from child *Helper* processes with no `NSRunningApplication`. `Core/AudioProcessEnumerator.resolveOwningApp` walks the parent-PID chain (sysctl) and falls back to bundle-ID prefix matching so the UI shows the real parent app's name + icon.

### The eye-rest break timer (second subsystem, independent of audio)

- **`Engine/BreakTimerManager`** (`@Observable @MainActor`) is the state machine driving `idle → studying → warning → breaking`. It uses **wall-clock absolute deadlines** (not accumulated ticks) so sleep/wake doesn't corrupt timing. Configuration, daily session counts, and todo items persist via `UserDefaults` under `btm_*` keys.
- **`Core/InputBlocker`** installs a `CGEventTap` during breaks that swallows escape shortcuts (Cmd-Tab, Cmd-Q, Escape, Mission Control) but **never mouse events** — the overlay's Skip button needs clicks. `shouldSuppressEvent` is a pure function kept free of allocation/locks so it's testable in isolation. The tap requires the **Accessibility permission**: `checkAccessibilityPermission()` (silent, safe to poll) vs `promptAccessibilityPermission()` (shows the system dialog — call only on user intent). A watchdog re-installs the tap if the system disables it, and it respects secure-input mode.
- **`UI/BreakOverlayWindow`** is a borderless `.screenSaver`-level `NSPanel` per screen (`canJoinAllSpaces` + `fullScreenAuxiliary` so it covers fullscreen apps); it overrides `canBecomeKey` so the Skip button works while the event tap is live. The protocols (`InputBlockerProtocol`, `BreakOverlayControllerProtocol`) live in Core so Engine can depend on them without importing UI.

### Conventions & gotchas

- **Hard-coded Core Audio four-char-code selectors.** Many `AudioObjectPropertySelector`s are written as raw hex (e.g. `0x70727323` = `'prs#'`, `'pbid'`, `'tuid'`, `'tfmt'`, `'id2p'`) with the FourCC in a comment, because the named SDK constants don't reliably resolve under the Swift 6 / Command Line Tools toolchain. Follow that pattern rather than assuming a constant exists.
- **Teardown order is load-bearing.** In `ProcessTapManager.stopTapping`, the aggregate device must be stopped/destroyed *before* the tap (`AudioHardwareDestroyProcessTap`) — the aggregate holds a reference to the tap. Reordering causes a dangling HAL reference.
- **Concurrency model:** real-time callbacks and Core Audio bridges use `@unchecked Sendable` and `nonisolated(unsafe)` deliberately. Code on the IOProc / render thread must not allocate, lock, or call back into `@MainActor` state.
- **Known wart:** `SoundsSource/AppDelegate.swift` redirects stdout/stderr to a **hard-coded absolute log path** (`/Users/mac/Documents/GitHub/voice-macos/app.log`). If you touch `applicationDidFinishLaunching`, this is worth fixing/parameterizing rather than copying.

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **voice-macos** (2306 symbols, 5983 relationships, 168 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> Index stale? Run `node .gitnexus/run.cjs analyze` from the project root — it auto-selects an available runner. No `.gitnexus/run.cjs` yet? `npx gitnexus analyze` (npm 11 crash → `npm i -g gitnexus`; #1939).

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows. For regression review, compare against the default branch: `detect_changes({scope: "compare", base_ref: "main"})`.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `context({name: "symbolName"})`.

## Never Do

- NEVER edit a function, class, or method without first running `impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `rename` which understands the call graph.
- NEVER commit changes without running `detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/voice-macos/context` | Codebase overview, check index freshness |
| `gitnexus://repo/voice-macos/clusters` | All functional areas |
| `gitnexus://repo/voice-macos/processes` | All execution flows |
| `gitnexus://repo/voice-macos/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
