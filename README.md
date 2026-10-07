# Minilet

<img src="Resources/Minilet.png" width="128" alt="Minilet app icon">

A native macOS menu-bar fan controller for Apple Silicon Macs with fans. Presets
for fixed speeds, live temperature and RPM readings, and a temperature-driven Guard.
Built with Swift and AppKit, without third-party dependencies.

## Download

Get the app ZIP from [GitHub Releases](https://github.com/brunnolou/minilet/releases).
Extract it, move `Minilet.app` to your Applications folder, and open it. Releases
are previews for Apple Silicon Macs with fans, running macOS 13 or newer.
Each GPL release includes its matching source ZIP and build instructions.
Version 0.1.1 and later use GPL v3.0; the historical 0.1.0 preview used different terms.

The app is ad-hoc signed, not notarized. macOS may require approval in System
Settings > Privacy & Security. Only approve the app if you trust its source.

<img width="320" alt="minilet-open-anyway" src="https://github.com/user-attachments/assets/82d4e47b-7f98-4df2-acbe-283cb8276606" />


## Build and install

Requires macOS 13 or newer, a Swift 6 toolchain and Python 3. Apple's command-line
build tools provide the remaining utilities.

```sh
git clone https://github.com/brunnolou/minilet.git
cd minilet
./build.sh
```

This runs the tests and creates:

- `.build/Minilet.app`, a self-contained app bundle.
- `.build/Minilet.zip`, a packaged copy.

The default build does not replace or stop a running app. To install, quit Minilet
first, then run:

```sh
./build.sh --install
open "$HOME/Applications/Minilet.app"
```

The app is ad-hoc signed and verified locally, not notarized for public distribution.
Builds target the Mac's native architecture. Running the bundle does not require
Swift or Python to be installed separately.

## Using Minilet

Minilet starts in read-only monitoring mode. Selecting a preset or clicking
"Enable fan controls" opens a macOS administrator authorization prompt. One
session controller runs until the app quits. Changing presets within that session
does not prompt again. **No permanent daemon or sudoers exception is installed**.

Each preset has its own native icon:

- **Automatic** returns fan control to macOS.
- **Medium** requests 50% of each fan's maximum speed, bounded by its hardware limits.
- **High** requests 5000 RPM.
- **Extra high** requests 6000 RPM.
- **Full speed** requests each fan's hardware maximum.
- **Temperature guard** adjusts RPM continuously using temperature and the selected curve.

Guard has a separate menu section. Its curve, sliders, ramp details and filtered
temperature are hidden unless Guard is selected. Selecting another preset hides
those options immediately.

Settings persist, including when migrating from the earlier Fan Menu prototype.
Active presets never restart automatically on launch or after waking from sleep.

## Temperature guard

Guard reads the hottest usable Apple Silicon `tdie` sensor every five seconds.
It stays in manual RPM control while selected, including when the Mac is cool.
Crossing the target never switches between manual and automatic control.

- Target range: 40–85°C, default 80°C.
- Speed cap: 3200–8000 RPM, default 5500 RPM, bounded by each fan's hardware limits.
- Below target minus 5°C, fans hold their hardware minimum.
- At target plus 10°C, the curve reaches the selected speed cap.
- The ramp endpoint never exceeds 92°C.


All curves share those endpoints:

| Curve | Formula | Behavior |
| --- | --- | --- |
| Linear | `t` | Steady ramp |
| Exponential | `expm1(3*t) / expm1(3)` | Quieter near the start |
| Logarithmic | `log1p(expm1(3)*t) / 3` | Stronger cooling near the start |
| Smoothstep | `t*t*(3 - 2*t)` | Gentle start and finish |

A ten-second exponential moving average filters temperature spikes. Normal speed
increases are limited to 160 RPM per second and decreases to 60 RPM per second.
Lowering the speed cap can clamp RPM immediately.

A raw reading of 92°C requests hardware maximum immediately, bypassing the filter,
curve and speed limits. Maximum is held until the raw temperature falls to 88°C.

Slider and curve changes are debounced by 400 milliseconds, then request a fresh
sensor sample without clearing the filter or speed history. Changes queued during
a hardware operation apply when it finishes.

Very low targets may be unreachable under load and can keep fans at their cap.
The target is a fan-policy setting, not a guaranteed temperature or an
Apple-certified thermal limit.

## Safety and limitations

**This is a local prototype, not a production privileged-helper installation.**
It uses private Apple IOHID/SMC APIs and launches a temporarily authorized
executable from a user-writable app bundle. It is not intended for shared or
untrusted multi-user environments.

The controller attempts to restore automatic control on normal quit, handled
termination signals, sleep, loss of the UI process, sensor/write errors, or
20 seconds without UI socket contact. Its own hardware operations do not count
as idle time. Cleanup releases mode flags and held RPM targets, clears `Ftst`,
and checks for a full second of stable automatic mode. Failures are shown in the UI.

A crashed or forcibly killed root worker cannot run cleanup. Automatic restoration
is not guaranteed in that case. Use a trusted fan-control utility to restore
macOS automatic control if cleanup fails.

Do not run Macs Fan Control or another fan controller while Minilet controls the
fans. A session lock prevents competing Minilet and legacy Fan Menu workers, but
cannot prevent unrelated utilities from writing to the hardware. Fixed presets
remain fixed until changed or control is released. Use Guard for temperature-driven
cooling.

IPC uses a user-owned, mode-0600 Unix socket in the root-owned `/var/run` directory.
The worker checks the connecting user's identity. Commands are a fixed preset
whitelist and validated settings, never arbitrary shell commands. The UI allows
slow hardware replies for up to 150 seconds without blocking the main thread.

## Development

```
Sources/App.swift          AppKit menu, authorization and settings
Sources/Control.swift      Presets, curves and temperature regulation
Sources/Hardware.swift     SMC access and IOHID thermal readings
Sources/Worker.swift       Session worker, Unix-socket IPC and watchdog
Sources/Welcome.swift      Welcome window, startup preference and support link
Tests/ControllerTests.swift
Resources/Minilet.png      Source app icon
Info.plist                 Bundle metadata
build.sh                   Build, tests, signing and packaging
```

Run just the tests:

```sh
./build.sh --test
```

There are 693 controller/IPC checks and 53 native menu/welcome checks. They run without
fan writes or administrator authorization. Coverage includes curve bounds,
continuous RPM control across temperature thresholds, filtering, elapsed-time
speed limits, live option changes, emergency behavior, settings migration,
monitoring without writes, presets, cleanup failures, icons and conditional menu
visibility, welcome dismissal, isolated startup preferences and support actions.

The socket regression simulates a 2.5-second reply and verifies that accepted
connections clear the nonblocking flag inherited from a macOS listener.

## License and support

Copyright 2026 brunnolou. Licensed under GNU GPL v3.0 only. Read [LICENSE.md](LICENSE.md)
for the full terms and [NOTICE](NOTICE) for the project notice.

Commercial use, resale and donations are allowed. If you distribute Minilet or
modified versions, you must comply with the GPL, including preserving notices,
providing the corresponding source, and licensing covered modifications under
GPL v3.0. There are no added noncommercial or donation restrictions.

The app's "License and source" submenu displays copyright and warranty notices,
opens the included license, and links to the source repository. App bundles
include the full license, project notice and matching-release source location.
GitHub releases provide the corresponding source ZIP alongside the app ZIP.

Minilet comes without warranty. Donations support the author but are not required.

[Buy me a coffee](https://buymeacoffee.com/brunnolou)
