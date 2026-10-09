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

Two sliders appear directly in the main menu, followed by the Curve submenu:

- **Speed** has five stops: Automatic, Medium, High, Extra high and Full speed.
  With Cool to Off, these return control to macOS, request 4000 RPM,
  request 5000 RPM, request 6000 RPM or request hardware maximum.
- **Cool to** starts at Off. Its remaining positions select cooling targets from
  30°C to 85°C and activate continuous temperature control. While a target is
  selected, the Speed slider becomes **Max speed**, setting the speed cap instead
  of a fixed speed. Turning Cool to Off returns to the selected speed preset.
- **Curve** selects Linear, Exponential, Logarithmic or Smoothstep. Changing it
  while Cool to is Off saves the choice without activating control.

Automatic is unavailable in Max speed mode. Enabling Cool to while Speed is Auto
selects Full as the cap, allowing temperature regulation up to hardware maximum
without immediately forcing full RPM. Medium, High and Extra high cap at 4000,
5000 and 6000 RPM. All caps stay within hardware limits. The 92°C emergency
override still bypasses the cap.

The speed icon is `fan.badge.automatic` at zero. Other positions use
`fan.gauge.open`, with its line animated to the selected value on macOS 26.
The menu-bar icon follows the same selected gauge and animation.
Older supported macOS versions use a drawn fan gauge. Reduced Motion disables
animation.

Temperature readings and both controls are grouped before memory. The filtered
control temperature appears only while temperature control is active. Targets
and curves persist, including when migrating from the earlier Fan Menu prototype.
Launch and wake always reset Cool to Off and Speed to Automatic; saved
settings never reactivate control on their own.

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

Hovering or clicking anywhere in the memory summary, including the pressure
history, opens the ten largest identifiable apps, with app icons,
memory footprints, relative usage bars and a Quit button for each. The largest
app fills its bar; the others use the same scale. Helpers inside an app bundle
and child processes are grouped under the owning app using macOS metadata and
process ancestry, not a list of app names. Unattributed and OS infrastructure
processes are omitted.

Quit requests a normal app shutdown, allowing save prompts or cancellation.
Minilet never force-quits helpers. App identity and process start time are checked
again before quitting. App footprints include attributed compressed memory, so
they do not sum to physical RAM or promise an exact amount freed by quitting.

App scans run without administrator permission on a separate utility queue each
time the apps submenu opens, even if the main menu stays open. Values and bars
refresh every two seconds while the submenu is open. Closed apps show "Closed"
and disable Quit on the next sample. Rows keep their original app identity and position
under the pointer; reopening the submenu refreshes the ranking and removes closed
apps. Sampling stops when the submenu closes.

## CPU and GPU meters

Two rows of tiny squares sit below the RAM bar, without widening the menu-bar
item. Each row has eleven 2×2-point squares with 1-point gaps, matching the RAM
bar's 32-point width. The whole stack is 14 points high. CPU is the middle row;
GPU is the bottom row.

CPU cores overlap across the row. If every core is at 10%, the first 10% is
opaque. If one of twelve cores is at 100%, the whole row has 1/12 opacity.
Fractional edge squares preserve usage between square boundaries. Unused squares
use the inverse light/dark theme color so the row's full length stays visible.

CPU uses per-core Mach counter deltas, not boot-to-date averages. GPU uses the
AGX driver's aggregate Device Utilization percentage, not invented per-GPU-core
values. Both are sampled with RAM every two seconds without fan authorization.
The existing tooltip and accessibility label include measured CPU/GPU values.
The first CPU reading establishes a baseline; sleep, long gaps and topology
changes reset it. Missing readings are marked Unavailable, not zero.

## Temperature guard

Guard reads the hottest usable Apple Silicon `tdie` sensor every five seconds.
It stays in manual RPM control while selected, including when the Mac is cool.
Crossing the target never switches between manual and automatic control.

- Target range: 30–85°C, default saved target 80°C; temperature control starts Off.
- Speed cap: Medium 4000 RPM, High 5000 RPM, Extra high 6000 RPM or hardware maximum.
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

Temperature and curve changes are debounced by 400 milliseconds. Speed-cap
changes request a fresh sample immediately. Neither clears the filter or speed
history. Changes queued during a hardware operation apply when it finishes.

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
Sources/Control.swift      Presets, shared speed caps and temperature regulation
Sources/FanPresetUI.swift  Inline speed and temperature sliders, variable fan icons
Sources/Hardware.swift     SMC access and IOHID thermal readings
Sources/Worker.swift       Session worker, Unix-socket IPC and watchdog
Sources/Memory.swift       Unprivileged RAM, pressure, swap and history
Sources/Processor.swift    Per-core CPU deltas, aggregate GPU readings and tile opacity
Sources/ProcessorUI.swift  Compact RAM/CPU/GPU menu-bar stack
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

There are 845 controller/IPC checks, 47 memory checks, 28 app-memory grouping/identity
checks, 51 processor checks and 312 native menu/welcome checks. They run without fan writes or administrator authorization. Coverage includes curve bounds,
continuous RPM control across temperature thresholds, filtering, elapsed-time
speed limits, live option changes, emergency behavior, settings migration,
monitoring without writes, presets, cleanup failures, icons and conditional menu
visibility, welcome dismissal, isolated startup preferences and support actions.
Memory checks cover page accounting, real pressure levels, unsupported readings,
bounded history, usage ratios, rounded rendering, pressure colors, independent
readouts, accessible indicators and native API reads. App-memory checks cover
bundle ownership, nested helpers, parent chains, unknown processes, denied reads,
ranking, relative bars, PID reuse, Quit button bindings, live value updates,
closed-app states and submenu polling lifecycle.

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
