## ADDED Requirements

### Requirement: Save and load EQ presets
The system SHALL allow users to save the current EQ configuration for all apps as a named preset and load it in a future session.

#### Scenario: Save preset
- **WHEN** user saves a preset with a given name
- **THEN** all per-app EQ band settings (frequency, gain, Q, type, bypass state) and per-app volume SHALL be serialized and persisted

#### Scenario: Load preset
- **WHEN** user loads a named preset
- **THEN** per-app EQ and volume settings from the preset SHALL be applied to any matching apps (matched by bundle ID) currently in the process list

#### Scenario: Load preset with missing apps
- **WHEN** a preset references a bundle ID that is not currently running
- **THEN** those settings SHALL be stored and auto-applied when that app launches later in the same session

---

### Requirement: Persist presets across launches
The system SHALL store presets in a JSON file in Application Support so they survive app restarts and macOS reboots.

#### Scenario: Preset survives restart
- **WHEN** user saves a preset and the app is quit and relaunched
- **THEN** the preset SHALL appear in the preset list and be loadable

#### Scenario: Preset file location
- **WHEN** app creates preset storage
- **THEN** presets SHALL be stored at `~/Library/Application Support/SoundsSource/presets.json`

---

### Requirement: Default preset auto-apply on launch
The system SHALL support marking one preset as "default", which is automatically applied on app launch.

#### Scenario: Default preset set
- **WHEN** user marks a preset as default
- **THEN** on next launch, that preset SHALL be applied to all matching running apps within 2 seconds of engine start

#### Scenario: No default preset
- **WHEN** no preset is marked as default
- **THEN** app SHALL launch with flat EQ and 100% volume for all apps

---

### Requirement: Delete and rename presets
The system SHALL allow users to rename and delete existing presets.

#### Scenario: Rename preset
- **WHEN** user renames a preset
- **THEN** the new name SHALL be saved and old name SHALL no longer appear in the preset list

#### Scenario: Delete preset
- **WHEN** user deletes a preset
- **THEN** it SHALL be removed from storage and the preset list immediately; if it was the default, default SHALL be cleared
