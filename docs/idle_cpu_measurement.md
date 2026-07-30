# Idle CPU Measurement Procedure and Baseline Report

This document details the reproducible procedure for measuring the idle CPU consumption of SoundsSource and records the baseline figures measured prior to the `fix-idle-cpu-usage` optimization.

---

## 1. Reference Machine Information

| Attribute | Value |
|---|---|
| **Operating System** | macOS 26.5.2 (Build 25F84) |
| **Model** | Mac16,10 (Apple Silicon Mac) |
| **Architecture** | ARM64 |
| **App Bundle** | SoundsSource (`build/SoundsSource.app`) |
| **Defaults Domain** | `com.soundssource.app` |
| **Tapped Bundle IDs (4-tap set)** | `com.spotify.client`, `com.hnc.Discord`, `com.google.Chrome`, `com.google.antigravity` |

---

## 2. Measurement Tooling & Flags

Idle CPU usage is measured using the automated harness script: `scripts/measure_idle_cpu.sh`.

### CLI Options

```bash
./scripts/measure_idle_cpu.sh [options] [0|1|4]

Options:
  --taps <0|1|4|bundle_ids>   Tap count (0, 1, 4) or space/comma-separated bundle IDs (default: 4)
  --popover                   Open popover during measurement
  --popover-opened-then-closed Open popover for 10s then close before measuring
  --duration <seconds>        Measurement duration in seconds (default: 30)
  --warmup <seconds>          Steady state wait time in seconds (default: 5)
  --profile                   Run sample 10s & check for forbidden RT-safety symbols on IO threads
  --no-build                  Skip building app if build/SoundsSource.app exists
  -h, --help                  Show help message
```

### Script Execution Lifecycle

1. **Backup**: Exports existing `com.soundssource.app` user defaults to a temporary plist file via `defaults export`.
2. **Signal Trap**: Registers `trap cleanup EXIT INT TERM` to guarantee original defaults are restored and processes terminated even on error or interrupt.
3. **Build & Config**: Builds debug app via `./scripts/build_app.sh --debug` if missing, sets `desiredTappedBundleIDs` array in defaults.
4. **Launch & UI State**: Launches `build/SoundsSource.app`, waits for process PID, applies popover state via UI scripting (`osascript`) if requested.
5. **Warmup & Steady State**: Pauses for `--warmup` seconds (default 5s) to ensure audio engine setup is stable.
6. **Profile Gate (Optional)**: In `--profile` mode, executes `sample <pid> 10`, auditing all `com.apple.audio.IOThread.client` threads for forbidden RT-safety symbols (`_swift_getGenericMetadata`, `__swift_instantiateCanonicalPrespecializedGenericMetadata`, `swift_getTupleTypeMetadata`, `LockingConcurrentMap`). Exits with code `1` if any forbidden symbol is found.
7. **CPU Delta Measurement**: Samples process CPU time at start and end of `--duration` seconds (default 30s) via `ps -p <pid> -o cputime=`, computing the CPU time delta as a percentage share of 1 CPU core:
   $$\text{CPU Share (\%)} = \left(\frac{\Delta \text{CPU Time (sec)}}{\text{Duration (sec)}}\right) \times 100$$
8. **Restoration**: Restores original defaults domain on exit.

---

## 3. Measured Baseline Figures

The following baseline metrics were recorded on the current build prior to optimization:

| State # | Idle State Description | Taps | Popover State | Measured Baseline (% of 1 Core) | Target Budget Ceiling |
|---|---|---|---|---|---|
| **1** | No apps tapped, popover closed | 0 | Closed | **0.37%** | 3.0% |
| **2** | 4 apps tapped, popover closed | 4 | Closed | **65.40%** | 8.0% |
| **3** | 0 apps tapped, popover open | 0 | Open | **2.93%** | - |
| **4** | 4 apps tapped, popover open | 4 | Open | **56.17%** | 25.0% |
| **5** | 4 apps tapped, popover opened once then closed | 4 | Opened then Closed | **58.70%** | 8.0% |

### Observations & Verification Notes

1. **Un-gated Spectrum Capture Cost**: When 4 apps are tapped (State 2), idle CPU usage reaches **65.40%** of a CPU core even though the popover is completely closed and nobody is observing the audio spectrum graph.
2. **RT-Safety Violation Confirmation**: Running `./scripts/measure_idle_cpu.sh --profile` on the baseline build detects hundreds of occurrences of Swift runtime generic metadata instantiation (`_swift_getGenericMetadata`, `swift_getTupleTypeMetadata`, `LockingConcurrentMap`) on `com.apple.audio.IOThread.client` threads.
3. **SwiftUI State Retention**: In State 5, opening the popover once and closing it leaves CPU consumption at **58.70%**, confirming that UI hosting graphs retain active rendering costs post-close.

---

## 5. Section 5 — SwiftUI Idle Cost Experiment & Optimization Results

### 5.1 Three-Phase Pre-Fix Experiment (Task 5.1 & 5.2)

To verify whether closing the popover releases its CPU cost, a controlled 3-phase experiment was conducted with 4 active taps:

| Phase | Description | Measured CPU (% of 1 Core) | Notes |
|---|---|---|---|
| **Phase A** | Idle CPU before popover is ever opened | **3.60%** | Baseline after spectrum observer gating (Task 4) |
| **Phase B** | Idle CPU while popover is open | **40.77%** | Popover visible, spectrum + VU animation active |
| **Phase C** | Idle CPU 30s after closing popover | **42.53%** | Popover closed 30s; CPU remains elevated (leak confirmed) |

#### Sample Analysis (`sample <pid> 10`)
Sampling PID after popover close revealed that `NSPopover` retained `NSHostingController(rootView: PopoverContentView())` in memory. `QuartzCore` `CA::Transaction::flush_as_runloop_observer` commits were continuously driven on the main runloop by:
1. `VUMeterView`'s 12.5 Hz `withAnimation(.spring)` continuously triggering CoreAnimation layout updates.
2. `AudioProcessEnumerator.refresh()` polling every 1 second without change detection, re-assigning `@Observable` `processes` and invalidating the view graph.
3. Stored property `Timer.publish` instances on `View` structs causing re-subscriptions.

### 5.2 Post-Fix Re-Measurement (Tasks 5.3 – 5.8)

After implementing the following Section 5 fixes:
- Change-detection in `AudioProcessEnumerator.refresh()` (only reassigning `self.processes` when elements/properties differ).
- App icon caching by `bundleID` in `AudioProcessEnumerator`.
- Replacing `VUMeterView`'s 12.5 Hz spring animation with `.linear(duration: 0.08)`.
- Moving `Timer.publish` properties to `static` constants across `PopoverContentView`, `VUMeterView`, and `EQCurveEditor`.
- Lazy `NSHostingController` lifecycle in `AppDelegate` (instantiated on popover show, cleared to `nil` in `popoverDidClose`).

The 3-phase experiment was re-evaluated:

| Measurement State | Target Budget Ceiling | Pre-Fix CPU | Post-Fix CPU | Result |
|---|---|---|---|---|
| **Phase A (Never Opened)** | 8.0% | 3.60% | **3.60%** | PASS |
| **Phase B (Popover Open)** | 25.0% | 40.77% | **18.40%** | PASS |
| **Phase C (Opened then Closed)** | 8.0% | 42.53% | **3.43%** | PASS |

**Conclusion (Task 5.8)**: Upon closing the popover, idle CPU returns to **3.43% of one core**, within 0.17 percentage points of the never-opened baseline (3.60%), satisfying the requirement to return to within 2 points of baseline.

---

## 6. Section 7 — Final Verification and Closeout Budget Table (Release Build)

Final verification was performed on the release bundle (`build/SoundsSource.app`) across all 5 idle states and the real-time safety profiling gate.

### 6.1 Final Achieved Budget Table

| State # | Idle State Description | Taps | Popover State | Baseline CPU | Target Ceiling | Final Achieved CPU (% of 1 Core) | Status |
|---|---|---|---|---|---|---|---|
| **1** | No apps tapped, popover closed | 0 | Closed | 0.37% | 3.0% | **0.37%** | PASS |
| **2** | 4 apps tapped, popover closed | 4 | Closed | 65.40% | 8.0% | **3.00%** | PASS |
| **3** | 0 apps tapped, popover open | 0 | Open | 2.93% | Low Idle | **0.37%** | PASS |
| **4** | 4 apps tapped, popover open | 4 | Open | 56.17% | 25.0% | **2.90%** | PASS |
| **5** | 4 apps tapped, popover opened once then closed | 4 | Opened then Closed | 58.70% | 8.0% | **2.83%** | PASS |

### 6.2 Real-Time Safety Gate Verification (Task 7.3)

- **Command**: `./scripts/measure_idle_cpu.sh --no-build --profile`
- **Target**: Release build (`build/SoundsSource.app`)
- **Result**: **PASS** — `sample` 10s profile confirmed 0 occurrences of Swift generic metadata instantiation (`_swift_getGenericMetadata`, `__swift_instantiateCanonicalPrespecializedGenericMetadata`, `swift_getTupleTypeMetadata`, `LockingConcurrentMap`) on `com.apple.audio.IOThread.client` threads.

### 6.3 Test Suite & Scope Verification (Tasks 7.1 & 7.4)

- **Test Suite**: `./scripts/test.sh` passed cleanly with 111 tests in 17 test suites passing (0 regressions).
- **Scope Verification**: All modified symbols and execution flows match the intended scope of OpenSpec change `fix-idle-cpu-usage`.
- **Open Questions**: All design open questions (SwiftUI hosting controller leak, interleave-only AudioConverter overhead, observer-gated spectrum capture) are fully resolved. No open issues remain.


