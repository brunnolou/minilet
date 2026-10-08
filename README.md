# <img src="Resources/Minilet.png" width="128" alt="Minilet app icon"> Minilet 

A native tiny macOS menu-bar fan and memory monitor for Apple Silicon Macs with fans.

Presets for fixed speeds, live temperature and RPM readings, memory pressure, and a temperature-driven Guard.

Built with Swift and AppKit, without third-party dependencies.

|Default|Set temperature|
|--|--|
|<img width="420" height="429" alt="image" src="https://github.com/user-attachments/assets/fe053427-8b00-416b-85c2-58d8c50bce66" />|<img width="447" height="668" alt="image" src="https://github.com/user-attachments/assets/c9181a79-f784-4bd6-9407-b3e39ed5ae14" />|

## Download and install

Requires an Apple Silicon Mac with fans, running macOS 13 or newer.

1. Download the app ZIP, named `Minilet-<version>-arm64.zip`, from
   [GitHub Releases](https://github.com/brunnolou/minilet/releases).
2. Unzip it and move `Minilet.app` to your Applications folder.
3. Open Minilet and look for the fan icon near the clock.

No Python, Xcode, developer tools or Terminal commands are needed to run the app.
The separate source ZIP is for developers who want to build or modify Minilet.

### If macOS blocks the app

Minilet is ad-hoc signed, not Apple-notarized. Only approve it if you trust its source.

1. Click **Done** in the "Minilet Not Opened" warning, not Move to Trash.
2. Open **System Settings > Privacy & Security** and scroll to the Security section.
3. Find the Minilet blocked message and click **Open Anyway**, then confirm.

"Open Anyway" appears in System Settings, not in the initial warning popup.
Do this shortly after attempting to launch the app. Do not disable Gatekeeper globally.

<img width="320" alt="minilet-open-anyway" src="https://github.com/user-attachments/assets/82d4e47b-7f98-4df2-acbe-283cb8276606" />

## Using Minilet

Minilet starts in read-only monitoring mode. Selecting a fan preset requests
administrator authorization when needed. One session controller runs until the
app quits. Changing presets within that session does not prompt again. **No permanent daemon or sudoers exception is installed**.

Memory and temperature monitoring do not require administrator permission.
Fan approval currently lasts for the app session, not across relaunches. Persistent
approval would require a separate installed privileged helper. Apple's modern
`SMAppService` daemon route requires a notarized app; this ad-hoc build does not
install that service or save your password.

Each preset has its own native icon:

- **Automatic** returns fan control to macOS.
- **Medium** requests 50% of each fan's maximum speed, bounded by its hardware limits.
- **High** requests 5000 RPM.
- **Extra high** requests 6000 RPM.
- **Full speed** requests each fan's hardware maximum.
- **Set temperature** opens temperature-control settings, with the current target
  right-aligned in the main menu. Adjusting the target, speed cap or curve starts
  continuous temperature control and requests authorization when needed.
  Opening the submenu alone does not change the fans.

Temperature readings and fan controls are grouped before the memory section.
Temperature settings remain accessible with every preset. The filtered control
temperature appears inside the submenu only while temperature control is selected.

Settings persist, including when migrating from the earlier Fan Menu prototype.
Active presets never restart automatically on launch or after waking from sleep.

## Memory monitoring

Temperature and a small rounded RAM-usage bar appear together in the menu bar.
The fan icon is 50% opaque while monitoring only, and fully opaque with a confirmed
fan preset. Temperature and RAM stay at full opacity.
The fill represents physical RAM used, from 0–100%. Its color follows macOS memory
pressure: system-neutral for Normal, yellow for Warning, red for Critical.

The menu keeps detailed RAM values, the current pressure state, compressed RAM,
swap used and a rounded five-minute pressure timeline. History starts at launch,
clears after sleep and leaves gaps for missing readings. Exact values and pressure
remain available in the menu-bar tooltip and accessibility label.

Memory is sampled every two seconds with unprivileged native Mach/sysctl calls,
independently of fan operations. The menu can open Activity Monitor.

"Apps using memory" contains the ten largest identifiable apps, with app icons,
memory footprints, relative usage bars and a Quit button for each. The largest
app fills its bar; the others use the same scale. Helpers inside an app bundle
and child processes are grouped under the owning app using macOS metadata and
process ancestry, not a list of app names. Unattributed and OS infrastructure
processes are omitted.

Quit requests a normal app shutdown, allowing save prompts or cancellation.
Minilet never force-quits helpers. App identity and process start time are checked
again before quitting. App footprints include attributed compressed memory, so
they do not sum to physical RAM or promise an exact amount freed by quitting.

App scans run without administrator permission on a separate utility queue when
the menu opens. Ranked rows do not reshuffle while the submenu is open.

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

### Build from source

This section is for developers, not required to use the downloaded app.
Building requires macOS 13 or newer, a Swift 6 toolchain, Python 3 and Apple's
command-line build tools.

```sh
git clone https://github.com/brunnolou/minilet.git
cd minilet
./build.sh
```

This runs the tests and creates:

- `.build/Minilet.app`, a self-contained app bundle.
- `.build/Minilet.zip`, a packaged copy.

The default build does not replace or stop a running app. To install your build,
quit Minilet first, then run:

```sh
./build.sh --install
open "$HOME/Applications/Minilet.app"
```

Builds target the Mac's native architecture and are ad-hoc signed and verified
locally, not notarized for public distribution.

### Project layout

```
Sources/App.swift          AppKit menu, authorization and settings
Sources/Control.swift      Presets, curves and temperature regulation
Sources/Hardware.swift     SMC access and IOHID thermal readings
Sources/Worker.swift       Session worker, Unix-socket IPC and watchdog
Sources/Memory.swift       Unprivileged RAM, pressure, swap and history
Sources/MemoryUI.swift     Pressure indicators and timeline
Sources/Welcome.swift      Welcome window, startup preference and support link
Tests/ControllerTests.swift
Tests/MemoryTests.swift
Resources/Minilet.png      Source app icon
Info.plist                 Bundle metadata
build.sh                   Build, tests, signing and packaging
```

### Tests

Run just the tests:

```sh
./build.sh --test
```

There are 693 controller/IPC checks, 47 memory checks, 26 app-memory grouping/identity checks and 113 native menu/welcome
checks. They run without fan writes or administrator authorization. Coverage includes curve bounds,
continuous RPM control across temperature thresholds, filtering, elapsed-time
speed limits, live option changes, emergency behavior, settings migration,
monitoring without writes, presets, cleanup failures, icons and conditional menu
visibility, welcome dismissal, isolated startup preferences and support actions.
Memory checks cover page accounting, real pressure levels, unsupported readings,
bounded history, usage ratios, rounded rendering, pressure colors, independent
readouts, accessible indicators and native API reads. App-memory checks cover
bundle ownership, nested helpers, parent chains, unknown processes, denied reads,
ranking, relative bars, PID reuse and Quit button bindings.

The socket regression simulates a 2.5-second reply and verifies that accepted
connections clear the nonblocking flag inherited from a macOS listener.

## License and support

Copyright 2026 brunnolou. Licensed under GNU GPL v3.0 only. Read [LICENSE.md](LICENSE.md)
for the full terms and [NOTICE](NOTICE) for the project notice.

Commercial use, resale and donations are allowed. If you distribute Minilet or
modified versions, you must comply with the GPL, including preserving notices,
providing the corresponding source, and licensing covered modifications under
GPL v3.0. There are no added noncommercial or donation restrictions.

"About Minilet" contains the GitHub and Buy Me a Coffee links, plus a small
copyright/GPL line that opens the full license. These links are not separate
main-menu entries. App bundles include the full license, project notice and
matching-release source location.
GitHub releases provide the corresponding source ZIP alongside the app ZIP.

Version 0.1.1 and later use GPL v3.0; the historical 0.1.0 preview used different terms.
Each GPL release includes its matching source ZIP and build instructions.

Minilet comes without warranty. Donations support the author but are not required.

[Buy me a coffee](https://buymeacoffee.com/brunnolou)
