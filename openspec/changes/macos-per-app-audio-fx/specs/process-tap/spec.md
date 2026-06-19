## ADDED Requirements

### Requirement: Enumerate audio-producing processes
The system SHALL detect all running macOS processes that are currently producing audio output, using Core Audio device property queries combined with NSWorkspace application listing.

#### Scenario: App produces audio
- **WHEN** a running application begins outputting audio to any Core Audio device
- **THEN** it SHALL appear in the process list within 2 seconds

#### Scenario: App stops audio
- **WHEN** a running application stops producing audio and terminates
- **THEN** it SHALL be removed from the process list

#### Scenario: App launches mid-session
- **WHEN** a new application launches and starts producing audio after the app is already running
- **THEN** it SHALL appear in the list without requiring a restart

---

### Requirement: Attach per-process audio tap
The system SHALL attach a Core Audio Process Tap (via `CATapDescription` + `AudioHardwareCreateProcessTap`) to any individual process to capture its raw PCM audio stream.

#### Scenario: Tap attach succeeds
- **WHEN** user enables capture for a listed process
- **THEN** a `CATap` SHALL be created for that process's PID and audio SHALL begin flowing within 500ms

#### Scenario: Tap attach on non-audio process
- **WHEN** a process is listed but not currently producing audio
- **THEN** tap creation SHALL succeed but deliver silence until the process produces audio

#### Scenario: Tap detach on disable
- **WHEN** user disables capture for a process
- **THEN** `AudioHardwareDestroyProcessTap` SHALL be called and the tap's IOProc SHALL stop within one render cycle

---

### Requirement: Stream tap audio to engine in real-time
The system SHALL bridge captured PCM audio from the Core Audio tap callback to AVAudioEngine via a lock-free ring buffer, with no blocking on the audio render thread.

#### Scenario: Continuous audio flow
- **WHEN** a tap is active and the source process is producing audio
- **THEN** audio SHALL flow to AVAudioEngine with end-to-end latency ≤ 20ms at 512-sample buffer size

#### Scenario: Real-time safety
- **WHEN** the tap IOProc or AVAudioSourceNode render block executes
- **THEN** no heap allocation, mutex lock, or ObjC message send SHALL occur on that thread

#### Scenario: Buffer underrun
- **WHEN** the ring buffer is empty (source process paused audio)
- **THEN** the engine render block SHALL output silence without error or glitch

---

### Requirement: Support aggregate tap for system-wide capture
The system SHALL support an optional aggregate tap mode that captures all system audio output (not per-process) as a single stream, for users who want system-wide EQ without per-app configuration.

#### Scenario: Aggregate tap enable
- **WHEN** user selects "All system audio" mode
- **THEN** a single aggregate `CATapDescription` SHALL capture the mix of all output processes

#### Scenario: Aggregate tap and per-app taps are mutually exclusive
- **WHEN** aggregate tap mode is active
- **THEN** per-process taps SHALL be disabled and their UI controls grayed out
