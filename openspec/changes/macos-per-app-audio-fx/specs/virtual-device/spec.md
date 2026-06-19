## ADDED Requirements

### Requirement: Implement Audio Server Plug-in virtual device
The system SHALL provide a HAL Audio Server Plug-in (C/C++) that creates a virtual audio output device visible to all macOS applications, enabling transparent audio routing through the FX chain without per-app Process Tap configuration.

#### Scenario: Virtual device appears in system
- **WHEN** the HAL plugin is installed and `coreaudiod` restarts
- **THEN** a device named "SoundsSource" SHALL appear in System Settings → Sound → Output and in any audio device picker

#### Scenario: Virtual device receives audio from any app
- **WHEN** any macOS application outputs audio to the "SoundsSource" virtual device
- **THEN** that audio SHALL be available as input to the main app's AVAudioEngine for processing

#### Scenario: Processed audio routes to real hardware
- **WHEN** processed audio exits AVAudioEngine
- **THEN** it SHALL be written to a real hardware output device selected by the user

---

### Requirement: HAL plugin implements AudioServerPlugInDriverInterface
The plugin SHALL implement the full `AudioServerPlugInDriverInterface` COM-style vtable including device, stream, and control objects required by Core Audio.

#### Scenario: Plugin loads in coreaudiod
- **WHEN** coreaudiod loads the plugin from `/Library/Audio/Plug-Ins/HAL/SoundsSource.driver`
- **THEN** `AudioServerPlugIn_CreateInitOpts` SHALL return success and the driver SHALL initialize without crashing coreaudiod

#### Scenario: Plugin survives audio stress
- **WHEN** multiple apps simultaneously route audio through the virtual device at high sample rate (192kHz)
- **THEN** coreaudiod SHALL remain stable and CPU usage SHALL not exceed 5% for the plugin

---

### Requirement: Plugin installation via privileged helper
The system SHALL install and uninstall the HAL plugin using a privileged helper tool (SMJobBless / SMAppService) to avoid requiring manual admin interaction beyond an initial authorization prompt.

#### Scenario: First-time install
- **WHEN** user enables the virtual device feature for the first time
- **THEN** macOS authorization dialog SHALL appear once, plugin SHALL be copied to `/Library/Audio/Plug-Ins/HAL/`, and `coreaudiod` SHALL restart automatically

#### Scenario: Uninstall
- **WHEN** user disables the virtual device feature
- **THEN** plugin SHALL be removed from `/Library/Audio/Plug-Ins/HAL/` and `coreaudiod` SHALL restart, removing the virtual device from all pickers

#### Scenario: Reinstall after system update
- **WHEN** a macOS update removes the plugin
- **THEN** app SHALL detect absence of the plugin on launch and prompt re-installation

---

### Requirement: Virtual device supports standard audio formats
The virtual device SHALL advertise and accept standard PCM formats: 16-bit int and 32-bit float, at 44100 Hz and 48000 Hz, stereo minimum.

#### Scenario: Format negotiation
- **WHEN** an app queries the virtual device's supported formats
- **THEN** it SHALL enumerate at minimum: Float32 stereo @ 44100Hz and 48000Hz

#### Scenario: Non-standard format fallback
- **WHEN** an app requests a format not natively supported by the virtual device
- **THEN** Core Audio SHALL perform format conversion transparently (no action required from plugin)
