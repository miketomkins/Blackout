# Changelog

All notable changes to Blackout are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Releases are tagged `vMAJOR.MINOR.PATCH[-beta.N]`.

## [Unreleased]

### Added
- CI typechecks the manual `BlackoutQA` acceptance helper so it cannot drift, and the README documents building and running it. ([#23](https://github.com/miketomkins/Blackout/issues/23))

### Changed
- A second display operation now waits up to 10 seconds, not 3, for one already in progress, so a command run while a slow monitor is reconnecting no longer fails with "Another display operation is busy". ([#29](https://github.com/miketomkins/Blackout/issues/29))
- `MonitorPolicy.canDisable` no longer takes a `disabled` set it never read; the last-display guard stays decided by live OS state alone. ([#22](https://github.com/miketomkins/Blackout/issues/22))

### Fixed
- A Switch-input monitor that was on the other computer and then unplugged from the Mac no longer makes Reconnect All, `--connect-all` and Quit report a failure every time. It's skipped and still remembered as away, so Reconnect All brings it back once it's plugged in again. ([#28](https://github.com/miketomkins/Blackout/issues/28))
- Logout, restart and shutdown no longer wait while Blackout reconnects the monitors it turned off. Display changes last only for the login session, so macOS restores those monitors at the next login. Reconnecting them also switched them back from the other computer. On launch, Blackout clears its "turned off" mark for monitors that are back on. ([#33](https://github.com/miketomkins/Blackout/issues/33))

## [1.2.0] - 2026-10-16

### Added
- **Switch input** mode per monitor: a shortcut switches the monitor's input to another computer over DDC/CI and back, instead of disconnecting it, so macOS keeps the display and windows don't move. Settings detects the Mac's input and lists the monitor's own inputs for the other computer. Reconnect All and Quit bring switched monitors back to the Mac. `--inputs` reports each monitor's input; `--toggle` and `--connect-all` follow the monitor's mode. ([#6](https://github.com/miketomkins/Blackout/issues/6))
- **Identify** button in Settings: outlines a monitor in red with its name for two seconds, like Displays settings does, so you can tell which row is which screen. It appears only for monitors that are on the desktop.
- Shortcut recorder in Settings: click a shortcut and press the keys instead of typing `ctrl+alt+r`. Esc cancels recording and Delete clears the shortcut. Blackout's own hotkeys are paused while recording, so pressing a current shortcut records it instead of toggling a monitor. ([#6](https://github.com/miketomkins/Blackout/issues/6))
- Conflict flagging while recording: duplicates, the reserved ⌃⌥0 and standard app shortcuts such as ⌘C, ⌘V and ⌘Z are shown in red and block saving; enabled macOS keyboard shortcuts and other Command-only combinations are shown in orange as a warning. ([#6](https://github.com/miketomkins/Blackout/issues/6))

### Changed
- The project is now a Swift package (`BlackoutCore` library plus the `Blackout` app), Settings has its own file, and the code is formatted with swift-format. `test.sh` rebuilds before testing, so it works on a fresh clone. GitHub Actions runs lint, build and tests on every pull request. ([#6](https://github.com/miketomkins/Blackout/issues/6))
- The About panel is simpler: version, "Made by Mike Tomkins" and a link to the GitHub project, with no instructions.
- Choosing Quit from the menu now asks "Quit Blackout?" first. Logout, restart and shutdown are not interrupted.
- The version is now set only in `build.sh`; the app and CLI read it from Info.plist. ([#5](https://github.com/miketomkins/Blackout/issues/5))
- Settings shows each monitor's status (Connected, Inactive, Off (Blackout), Not connected) and a **Forget** button for monitors that aren't connected, so old projectors and TVs no longer pile up. Monitors Blackout itself disconnected can't be forgotten, because their saved address is needed to reconnect them. ([#2](https://github.com/miketomkins/Blackout/issues/2))
- A monitor's shortcut can now be cleared. A cleared shortcut stays cleared instead of being re-seeded, and Settings no longer fills an empty shortcut with `ctrl+alt+r`. ([#2](https://github.com/miketomkins/Blackout/issues/2))

### Fixed
- Reconnecting a monitor (its shortcut, Reconnect All or Quit) now switches it back to the Mac's input over DDC when it supports DDC. On a shared desk, the monitor's auto-input moves to the other computer when Blackout disconnects it, and it wouldn't come back to the Mac on its own while that computer was on. ([#6](https://github.com/miketomkins/Blackout/issues/6))
- The About panel shows your actual shortcuts instead of always saying ⌃⌥L / R, and shows the version and build from the app bundle. ([#5](https://github.com/miketomkins/Blackout/issues/5))
- `--connect-all` tries every monitor and reports all failures, like the menu's Reconnect All, instead of stopping at the first one. ([#5](https://github.com/miketomkins/Blackout/issues/5))
- Quitting during logout, restart or shutdown no longer shows a dialog that blocks it when a monitor can't reconnect. ([#5](https://github.com/miketomkins/Blackout/issues/5))
- The README documents `--disconnect UUID`. ([#5](https://github.com/miketomkins/Blackout/issues/5))
- A display that briefly has no ID (around wake or reconfiguration) is now skipped instead of making the whole menu show "Display state unavailable". A failed read while a change is being confirmed is retried instead of reporting a change that worked as an error. ([#4](https://github.com/miketomkins/Blackout/issues/4))
- Reconnect All (⌃⌥0) is now registered on its own, so a problem with any per-monitor shortcut can no longer disable it. ([#1](https://github.com/miketomkins/Blackout/issues/1))
- Default shortcuts never reuse a key that's already taken. Previously a monitor added later, or more than nine saved monitors, could produce duplicates that left Blackout with no global shortcuts at launch. ([#1](https://github.com/miketomkins/Blackout/issues/1))
- A saved duplicate shortcut is now skipped with a warning instead of blocking every other monitor's shortcut. ([#1](https://github.com/miketomkins/Blackout/issues/1))
- The menu bar no longer freezes while a display change is waiting for the lock or for macOS to confirm it. Changes run on a background queue, and monitor menu items are disabled until the change finishes. ([#3](https://github.com/miketomkins/Blackout/issues/3))

## [1.0.0-beta.1] - 2026-10-16

- Menu-bar disconnect/reconnect for external monitors, custom names and global shortcuts, Reconnect All, Launch at Login, and a command-line interface. See the README for known limitations.

[Unreleased]: https://github.com/miketomkins/Blackout/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/miketomkins/Blackout/compare/v1.0.0-beta.1...v1.2.0
[1.0.0-beta.1]: https://github.com/miketomkins/Blackout/releases/tag/v1.0.0-beta.1
