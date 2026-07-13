# Original User Request

## Initial Request — 2026-07-12T23:00:03Z

Fix duplicate application listings (like Finder) in the SoundsSource popover list by grouping and deduplicating processes if EITHER their bundle IDs match OR their names match case-insensitively, and choosing the best representative.

Working directory: /Users/mac/Documents/GitHub/voice-macos
Integrity mode: demo

## Requirements

### R1. Cross-matching Deduplication
- Update `AudioProcess.visibleRows` to merge processes if they share the same non-empty bundle ID (case-insensitive) OR share the same name (case-insensitive).

### R2. Representative Selection Heuristics
- Select the best representative process when duplicates are merged, prioritizing processes outputting audio, regular applications, processes with icons, and localized names.

## Acceptance Criteria

### Automated Verification
- [ ] Running all unit and integration tests successfully with zero failures.
- [ ] Add unit tests in `AudioProcessTests.swift` validating grouping of processes where one has an empty bundle ID but the same name casing (e.g. `(bundleID: "", name: "finder")` merging with `(bundleID: "com.apple.finder", name: "Finder")`).
- [ ] Build the app bundle successfully using `./scripts/build_app.sh --debug`.
