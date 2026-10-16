# Changelog

All notable changes to Blackout are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Releases are tagged `vMAJOR.MINOR.PATCH[-beta.N]`.

## [Unreleased]

### Added
- Shortcut recorder in Settings: click a shortcut and press the keys instead of typing `ctrl+alt+r`. Esc cancels recording and Delete clears the shortcut. Blackout's own hotkeys are paused while recording, so pressing a current shortcut records it instead of toggling a monitor. ([#6](https://github.com/miketomkins/Blackout/issues/6))
- Conflict flagging while recording: duplicates and the reserved ⌃⌥0 are shown in red and block saving; enabled macOS keyboard shortcuts are shown in orange as a warning. ([#6](https://github.com/miketomkins/Blackout/issues/6))

### Changed
- A monitor's shortcut can now be cleared. A cleared shortcut stays cleared instead of being re-seeded, and Settings no longer fills an empty shortcut with `ctrl+alt+r`. ([#2](https://github.com/miketomkins/Blackout/issues/2))

### Fixed
- Reconnect All (⌃⌥0) is now registered on its own, so a problem with any per-monitor shortcut can no longer disable it. ([#1](https://github.com/miketomkins/Blackout/issues/1))
- Default shortcuts never reuse a key that's already taken. Previously a monitor added later, or more than nine saved monitors, could produce duplicates that left Blackout with no global shortcuts at launch. ([#1](https://github.com/miketomkins/Blackout/issues/1))
- A saved duplicate shortcut is now skipped with a warning instead of blocking every other monitor's shortcut. ([#1](https://github.com/miketomkins/Blackout/issues/1))
- The menu bar no longer freezes while a display change is waiting for the lock or for macOS to confirm it. Changes run on a background queue, and monitor menu items are disabled until the change finishes. ([#3](https://github.com/miketomkins/Blackout/issues/3))

## [1.0.0-beta.1] - 2026-10-16

- Menu-bar disconnect/reconnect for external monitors, custom names and global shortcuts, Reconnect All, Launch at Login, and a command-line interface. See the README for known limitations.

[Unreleased]: https://github.com/miketomkins/Blackout/compare/v1.0.0-beta.1...HEAD
[1.0.0-beta.1]: https://github.com/miketomkins/Blackout/releases/tag/v1.0.0-beta.1
