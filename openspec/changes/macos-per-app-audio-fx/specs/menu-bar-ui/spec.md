## ADDED Requirements

### Requirement: Menu bar status item and popover
The system SHALL run as a macOS menu bar app (no Dock icon) with an `NSStatusItem` that opens a SwiftUI popover on click.

#### Scenario: App launches
- **WHEN** app starts
- **THEN** a speaker/waveform icon SHALL appear in the menu bar, no window or Dock icon

#### Scenario: Click menu bar icon
- **WHEN** user clicks the status item icon
- **THEN** a popover SHALL open showing the full control UI

#### Scenario: Popover dismissal
- **WHEN** user clicks outside the popover
- **THEN** popover SHALL close without losing any unsaved changes (changes are applied live)

---

### Requirement: Live process list with audio indicators
The popover SHALL display a scrollable list of all audio-producing processes with their app icon, name, and a live audio level meter.

#### Scenario: Process list populates
- **WHEN** popover opens
- **THEN** all processes currently producing audio SHALL be listed within 1 second

#### Scenario: Live VU meter
- **WHEN** a listed process is producing audio
- **THEN** a VU meter beside its name SHALL animate in real time reflecting audio level

#### Scenario: Silent process indicator
- **WHEN** a process is listed but currently silent
- **THEN** its VU meter SHALL show flat/zero and it SHALL be visually distinguished (dimmed row)

---

### Requirement: Per-app EQ and volume controls
Each process row SHALL expand to show a volume slider, mute button, EQ toggle, and an EQ curve editor with up to 10 draggable bands.

#### Scenario: Expand app row
- **WHEN** user taps/clicks a process row
- **THEN** it SHALL expand in-place to show volume slider and EQ controls without navigating away

#### Scenario: EQ curve editor
- **WHEN** EQ section is expanded
- **THEN** a graphical EQ display SHALL show bands as draggable nodes; dragging changes frequency (horizontal) and gain (vertical)

#### Scenario: Mute toggle
- **WHEN** user clicks mute button for a process
- **THEN** process audio silences immediately and mute icon replaces VU meter

---

### Requirement: Global output device selector
The popover SHALL include a dropdown to select which physical output device receives the processed mix.

#### Scenario: Device list
- **WHEN** user opens device selector dropdown
- **THEN** all currently available Core Audio output devices SHALL be listed by name

#### Scenario: Select device
- **WHEN** user selects a device from the list
- **THEN** engine output SHALL switch to that device and selection SHALL persist to next launch

---

### Requirement: No active processes empty state
The popover SHALL show a clear empty state when no audio-producing processes are detected.

#### Scenario: No audio apps running
- **WHEN** no processes are currently producing audio
- **THEN** popover SHALL show "No apps playing audio" message with a muted speaker illustration

---

### Requirement: Preset selector in popover header
The popover header SHALL include a preset name display and quick-access buttons to load/save presets.

#### Scenario: Load preset
- **WHEN** user clicks the preset picker in the header
- **THEN** a list of saved presets SHALL appear and selecting one SHALL apply it to all current app EQ settings

#### Scenario: Save preset
- **WHEN** user clicks "Save" next to the preset name
- **THEN** current EQ state for all apps SHALL be saved under the current preset name (or prompt for new name)
