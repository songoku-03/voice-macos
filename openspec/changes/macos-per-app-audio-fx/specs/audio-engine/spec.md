## ADDED Requirements

### Requirement: Build per-app audio processing graph
The system SHALL construct an AVAudioEngine graph with one `AVAudioSourceNode` per tapped process, each feeding into its own `AVAudioUnitEQ` chain before merging at a global mixer.

#### Scenario: Add app to graph
- **WHEN** a process tap is attached for a new process
- **THEN** an `AVAudioSourceNode` + `AVAudioUnitEQ` node pair SHALL be added to the engine graph and connected to the mixer without stopping engine playback

#### Scenario: Remove app from graph
- **WHEN** a process tap is detached
- **THEN** its corresponding source and EQ nodes SHALL be disconnected and released without audio glitch

#### Scenario: Engine runs continuously
- **WHEN** the app is open
- **THEN** AVAudioEngine SHALL remain running even if zero apps are tapped (silent output)

---

### Requirement: Per-app parametric EQ
The system SHALL provide a parametric EQ with up to 10 bands per process using `AVAudioUnitEQ`, controllable in real time.

#### Scenario: Band frequency adjustment
- **WHEN** user drags an EQ band frequency control
- **THEN** audio output SHALL reflect the new filter frequency within one audio buffer cycle (≤ 512 samples)

#### Scenario: Band gain adjustment
- **WHEN** user adjusts an EQ band gain (range: -24 dB to +24 dB)
- **THEN** output gain SHALL change smoothly without click or zipper noise

#### Scenario: EQ bypass
- **WHEN** user toggles EQ bypass for a process
- **THEN** the EQ node SHALL be bypassed (`bypass = true`) and audio passes through unmodified

---

### Requirement: Per-app volume and mute
The system SHALL provide per-process volume (0.0–2.0) and mute controls that operate on the engine graph mixer input for that process.

#### Scenario: Volume change
- **WHEN** user adjusts per-app volume slider
- **THEN** the corresponding mixer input bus volume SHALL update and audio level changes within 10ms

#### Scenario: Mute toggle
- **WHEN** user mutes a process
- **THEN** its mixer input bus SHALL be set to volume 0.0 immediately and "Muted" indicator shown

#### Scenario: Volume persists across mute toggle
- **WHEN** user unmutes a previously muted process
- **THEN** volume SHALL restore to the level it was at before muting

---

### Requirement: Route processed mix to selected output device
The system SHALL route the engine's final mix to a user-selected Core Audio output device, defaulting to the system default output.

#### Scenario: Default output routing
- **WHEN** app launches and no device preference is saved
- **THEN** output SHALL route to `kAudioObjectSystemObject` default output device

#### Scenario: User selects output device
- **WHEN** user selects a specific output device from the device picker
- **THEN** engine output SHALL switch to that device within 500ms without restart

#### Scenario: Output device disconnected
- **WHEN** the selected output device is disconnected (e.g., AirPods disconnected)
- **THEN** engine SHALL automatically fall back to system default output and notify the user in the menu bar UI

---

### Requirement: Format matching between tap and engine
The system SHALL handle sample rate and channel format conversion between the tap source format and the engine's processing format automatically.

#### Scenario: Sample rate mismatch
- **WHEN** a tapped process runs at 44100 Hz but the engine graph is at 48000 Hz
- **THEN** an `AVAudioConverter` SHALL resample without audible artifacts

#### Scenario: Channel mismatch
- **WHEN** a tapped process outputs mono audio
- **THEN** audio SHALL be upmixed to stereo before entering the engine graph
