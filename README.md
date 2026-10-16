# Blackout — Beta

![Status: Beta](https://img.shields.io/badge/status-beta-orange)
![Platform: macOS](https://img.shields.io/badge/platform-macOS-black)

A small macOS menu-bar app for disconnecting and reconnecting external monitors, with memorable names and customizable global shortcuts.

Blackout is built for desks where external monitors are shared between a Mac and another computer, such as a work laptop or PC. Turn a monitor off on the Mac to hand it to the other machine, keep working on your remaining screens, then bring it back with a shortcut — no cables to swap. Whether the monitor switches to the other input on its own depends on its auto-input setting.

> **Experimental beta.** Blackout uses a private macOS display API. Keep physical access to your Mac and a way to reconnect your displays while testing. It is not a panel power-off utility and does not aim to reproduce BetterDisplay's full feature set.

## Features

- Disconnect/reconnect an individual monitor from the menu bar.
- Rename monitors; names follow their stable display identities.
- Record global shortcuts in Settings, with conflict warnings.
- Reconnect All, including a reserved global shortcut.
- Protect the last active display and built-in displays.
- Optional Launch at Login through macOS ServiceManagement.
- Remember disconnected monitors across app restarts, and forget monitors that are no longer connected.
- Reconnect displays Blackout disabled when quitting normally.

### Two-monitor defaults

| Action | Shortcut |
|---|---|
| Toggle Left | Control–Option–L |
| Toggle Right | Control–Option–R |
| Reconnect All | Control–Option–0 |

Open **Settings…** to rename monitors and change shortcuts, then **Save Changes**. To set a shortcut, click it and press the keys you want: a letter or digit with Control, Option or Command (Shift is optional). Esc cancels recording and Delete clears the shortcut. Physical key positions use the US mapping. Control–Option–0 is reserved.

Conflicts are flagged as you record. These are shown in red and block saving: a shortcut used by another monitor, the reserved Control–Option–0, or a standard app shortcut such as ⌘C (Copy), ⌘V or ⌘Z, because a global shortcut would replace it in every app. These are shown in orange and can still be saved: an enabled macOS keyboard shortcut (macOS may catch it first), or another Command-only combination such as ⌘1. A specific app's own custom shortcuts can't be detected.

“Off” removes the display from macOS's active desktop, so windows can move to the remaining display. It does **not** cut electrical power to the panel.

## Download and install

Download the Apple Silicon ZIP from [Releases](https://github.com/miketomkins/Blackout/releases). Releases are explicitly marked **pre-release** while Blackout is in beta.

The initial prebuilt beta requires **macOS 26 or later on Apple Silicon**. It was tested on macOS 26.6.2 with two external Dell U2723QE monitors. Other combinations are not validated.

Unzip and move `Blackout.app` into Applications. Open it and look for the monitor icon in the menu bar. Launch at Login is optional and can require macOS approval.

The build is **ad-hoc signed, not Developer ID signed or notarized**; macOS may block a downloaded copy. Build from source if you do not want to run the distributed local build. The initial beta's app bundle displays version 1.0.0; its public release tag is `v1.0.0-beta.1`.

## Build and test

Requires macOS and an installed Swift compiler / Xcode Command Line Tools. No third-party package dependencies are required.

```sh
git clone https://github.com/miketomkins/Blackout.git
cd Blackout
bash build.sh
bash test.sh
open build/Blackout.app
```

The build targets the current compiler's host architecture and deployment defaults. Only the macOS 26 Apple Silicon build has been exercised; the Info.plist minimum-version field alone is not evidence of older-OS compatibility.

Tests cover policy, saved settings, simulated hardware failures/reconnects and the real command-line interface. The suite includes real **read-only** native display enumeration and therefore expects an active macOS graphical session with a display. Tests do not disconnect physical monitors. `Tests/BlackoutQA.swift` is a separate manual acceptance helper: its explicit keyboard and Accessibility actions can affect a running app and are not run by `test.sh`.

## Command line

```sh
/Applications/Blackout.app/Contents/MacOS/Blackout --list
/Applications/Blackout.app/Contents/MacOS/Blackout --diagnostics
/Applications/Blackout.app/Contents/MacOS/Blackout --toggle UUID
/Applications/Blackout.app/Contents/MacOS/Blackout --connect UUID
/Applications/Blackout.app/Contents/MacOS/Blackout --disconnect UUID
/Applications/Blackout.app/Contents/MacOS/Blackout --connect-all
/Applications/Blackout.app/Contents/MacOS/Blackout --show-settings
```

Use the exact UUID from `--list`, not an array index. `--list` and `--diagnostics` are read-only. Mutating operations are serialized between app and CLI processes. Unknown/incomplete arguments are rejected.

Preferences use the `com.miketomkins.Blackout.preferences` UserDefaults domain. The display-operation lock is in the current user's `Library/Application Support/Blackout` directory. Blackout has no network service, telemetry or runtime dependency on BetterDisplay. Carbon shortcuts do not require Accessibility permission.

## Known beta limitations

- On the tested setup, disconnecting one monitor changed the remaining monitor's logical workspace from 3840×2160 to 1920×1080. Reconnecting restored the previous arrangement. This depended on which monitor was disconnected; exact mode and window-layout preservation are **not guaranteed**.
- Private macOS APIs can change with OS releases.
- Sleep/wake, physical cable hotplug, other hardware/OS versions and launch after an actual logout/login are not yet validated. Login-item registration and persistence across app restart were tested.
- A disconnected display can lose its live UUID. Reconnect may use its last validated runtime address, rejects a conflicting current identity, and checks that the intended display returns. After a cable/identity change, reconnect the cable normally if Blackout cannot restore it.
- Another display controller was left running during live acceptance. Native operation was verified, but coexistence without interference is not guaranteed.
- An unexpected app termination does not automatically reconnect monitors. Relaunch Blackout and use Reconnect All; normal Quit attempts to restore only its owned-disabled displays.

If a display does not return, try Control–Option–0 or Reconnect All, then reconnect the cable or use an existing display controller. Do not disconnect the remaining active screen.

## Verification of the initial beta

Local verification passed: core assertions, backend assertions, executable CLI tests, bundle signature checks and extracted release-archive checks. Live acceptance exercised both monitors, menu actions, default/custom global shortcuts, saved names, last-display rejection, concurrent requests, app restart after forced termination and reconnect on normal Quit. These are bounded results on one setup, not cross-device reliability certification. No hosted CI result is claimed.

The implementation is original Swift/AppKit code. Its private display-enable function declaration was cross-checked against [displayplacer](https://github.com/jakehilborn/displayplacer), Header.h blob `f8bf91b07f795d9fa6ed145bab7511a7c2527b69`. No BetterDisplay binary or source is bundled.

Bug reports are welcome via [Issues](https://github.com/miketomkins/Blackout/issues). Include your macOS version, hardware/connection type, symptoms and reproduction steps. Redact display UUIDs, serial numbers and personal paths from diagnostics before posting.
