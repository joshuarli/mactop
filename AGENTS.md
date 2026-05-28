# mactop Agent Guide

## Project Shape

`mactop` is a Swift Package Manager macOS menu-bar utility. It is an accessory `NSApplication`, not a bundled `.app`. The entry point is `Sources/mactop/App.swift`.

Core files:

- `App.swift`: app lifecycle, `NSStatusItem` registration, popup routing, timers, and `SystemMonitor`.
- `Views.swift`: small menu-bar drawing views for CPU/RAM/GPU, power, and network speed.
- `Popups.swift`: popup panels and detailed dashboard views.
- `Readers.swift`: CPU, RAM, GPU, power, and interface-level network readers.
- `Processes.swift`: top-process readers for CPU, RAM, and network.
- `Charts.swift`: popup chart views.
- `Config.swift`: reads optional update intervals from `UserDefaults`.
- `Makefile`: development, install, uninstall, and cleanup tasks.

## Build And Run

- Use `make dev` for local iteration. It runs `swift build`, ad-hoc signs `.build/debug/mactop`, clears quarantine, then launches the debug binary.
- Use `make build` to compile and sign the debug binary without launching it.
- Do not run release builds unless specifically requested. The project instructions prohibit `cargo build --release`; this repo is Swift, but the same intent applies: avoid unnecessary release artifact churn.
- `make install` builds release, installs to `~/.local/bin/mactop`, signs with `mactop.entitlements`, and registers a LaunchAgent.

## Profiling Procedure

Use the debug binary for profiling unless the user explicitly asks for release measurements.

1. Build and sign first:

   ```sh
   make build
   ```

2. Confirm Instruments templates are available:

   ```sh
   xcrun xctrace list templates
   ```

3. Capture launch/idle Time Profiler and Allocations traces:

   ```sh
   mkdir -p traces
   xcrun xctrace record --template 'Time Profiler' --time-limit 20s --output traces/mactop-idle-time.trace --launch -- .build/debug/mactop
   xcrun xctrace record --template 'Allocations' --time-limit 20s --output traces/mactop-idle-alloc.trace --launch -- .build/debug/mactop
   ```

4. Export the Time Profiler table of contents and detailed table when needed:

   ```sh
   xcrun xctrace export --input traces/mactop-idle-time.trace --toc
   xcrun xctrace export --input traces/mactop-idle-time.trace --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' --output traces/mactop-idle-time-profile.xml
   ```

5. Capture a settled idle sample after launch noise has passed:

   ```sh
   .build/debug/mactop & pid=$!
   sleep 5
   sample $pid 10 -file traces/mactop-idle.sample.txt
   kill $pid 2>/dev/null || true
   wait $pid 2>/dev/null || true
   ```

6. Inspect sampled hot spots directly:

   ```sh
   rg -n 'NetworkStatistics|network-statistics|NetProcessReader|SpeedView\.draw|MiniView\.draw|NetReader|primaryInterfaceName|String\.init\(format|PairHistory|GPUReader|CPUReader|RAMReader|DispatchQueue_.*mactop' traces/mactop-idle.sample.txt
   ```

7. For popup-specific profiling, repeat the settled `sample` run, manually open one popup during the 10-second sample window, and save the result as `traces/mactop-<popup>.sample.txt`.

8. Remove generated trace artifacts before finishing unless the user explicitly asks to keep them:

   ```sh
   rm -rf traces
   ```

When interpreting results, ignore launch-only dyld/AppKit setup unless optimizing startup. For idle discipline, look for work outside sleeping run loops: private `NetworkStatistics` callbacks while the network popup is hidden, repeated `SCDynamicStoreCopyValue`, IOKit GPU polling, IOReport power polling, status-item drawing allocations, formatter creation, `String(format:)`, array shifting, and full-list process sorting.

## Runtime Flow

`AppDelegate.applicationDidFinishLaunching` creates five status items: network, CPU, RAM, GPU, PWR. The network item is registered first so macOS is less likely to hide it when menu-bar space is tight. PWR is registered after GPU. `statusPanels` must stay in the same order as `statusItems`, because click routing uses the index.

`SystemMonitor` owns the core readers and schedules interval timers:

- CPU totals: `CPUReader.read()`
- RAM totals: `RAMReader.read()`
- GPU: `GPUReader.read()`
- Power: `PowerReader.read()`
- Network totals: `NetReader.read()`

Top-process readers are separate and visible-only. `AppDelegate` refreshes CPU, RAM, and network process lists on utility queues when the matching popup is visible or opened. Network process reporting lazily initializes the private `NetworkStatistics.framework` reader so hidden idle does not pay for callbacks.

## Data Sources

CPU totals use Mach `host_processor_info`. CPU top processes use one of two paths, selected once at startup by probing `proc_pid_rusage` on PID 1 (root-owned launchd):

**Native path** (succeeds only with `com.apple.system-task-ports.read` or setuid root):
- Same-user processes: `proc_pid_rusage` nanosecond delta → true instantaneous CPU%.
- Cross-user processes: `sysctl KERN_PROC_ALL` `p_pctcpu` decay average (best available natively).

**PS path** (active in the common case — no special entitlement):
- Runs `/bin/ps -Aceo pid,pcpu,comm -r`, which is setuid root and sees all processes.
- Values are `p_pctcpu`-based (decay average) but consistent across all users.
- Process names from `proc_name` fall back to the `comm` field from ps output.

**Why cross-user instantaneous CPU is unavailable without root:**
`p_uticks`/`p_sticks` (raw statclock accumulators) and `proc_pidinfo(PROC_PIDTASKINFO)` are zeroed by the kernel for non-root callers on modern macOS. `/bin/ps` and `/usr/bin/top` are both setuid root and carry the private entitlement `com.apple.system-task-ports.read`. Self-signing that entitlement does not work: with SIP enabled, `amfid` ignores it on non-Apple-signed binaries. The only paths to instantaneous cross-user CPU are (a) SIP disabled (not shippable) or (b) a privileged `SMJobBless` helper (requires paid Developer ID, significant architectural work).

RAM totals use Mach VM statistics and `sysctl`. RAM top processes use `proc_pid_rusage` → `ri_phys_footprint`, which matches Activity Monitor's per-process "Memory" column exactly.

**Preferred behavior:** show individual processes — do not group or roll up children under a responsible parent. Stats has a `combinedProcesses` mode that calls `responsibility_get_pid_responsible_for_pid` and collapses related processes (e.g. Claude, codex) under their terminal/tty ancestor. That is explicitly not wanted here.

**Known gap:** cross-user processes (WindowServer, root daemons) are absent from the RAM top list. `proc_pid_rusage` and `proc_pidinfo(PROC_PIDTASKINFO)` both return zero for non-root callers on modern macOS, so those processes are silently skipped. A `/usr/bin/top` subprocess fallback (analogous to the CPU ps path) could close this gap if it ever matters.

GPU uses IOKit `IOAccelerator` performance statistics.

Power uses two sources:

**System power** (preferred menu-bar total on MacBooks):
- `PowerReader.SystemPowerReader` reads `AppleSmartBattery` from IOKit.
- `PowerTelemetryData.SystemPowerIn` is preferred, falling back to `SystemCurrentIn * SystemVoltageIn`, `SystemLoad`, `BatteryPower`, then raw battery `Voltage * InstantAmperage`/`Amperage`.
- This is intended to represent whole-machine input/draw and includes power outside the SoC: display panel/backlight, radios, storage, USB/Thunderbolt, PMIC/conversion losses, charging/battery behavior, fans where present, and other board rails.
- `AppleSmartBattery` telemetry can update slowly or stay cached for seconds/minutes on AC/full battery. Keep a System-minus-modeled baseline from that source, then let the live modeled subtotal move within it so menu-bar System power responds to fast IOReport changes.
- This source may be unavailable on desktops or unusual battery states; in that case PWR falls back to modeled component power.
- Charging data also comes from `AppleSmartBattery`: `AdapterDetails.Watts` is the negotiated adapter maximum, `SystemPowerIn` is current system input, and `BatteryPower` is battery charge/discharge when available. The popup's Charging section should keep those concepts separate; do not label adapter max as live draw.

**Modeled component power**:
- `PowerReader.IOReportPowerSampler` dynamically loads private `IOReport` with `dlopen`, trying `/usr/lib/libIOReport.dylib`, `libIOReport.dylib`, the old private framework path, then `IOReport`. Do not link IOReport in `Package.swift`.
- It subscribes to `Energy Model` plus DCP/DCPEXT display-report groups, samples twice, deltas counters with real elapsed time, and converts `mJ`/`uJ`/`nJ` to watts. Avoid `IOReportCopyAllChannels`; DCP `display stats` subgroup-only subscriptions can return zero deltas for `power`, so use the DCP group and filter to `display stats` while parsing.
- Channel mapping: `GPU Energy` → GPU; names ending in `CPU Energy` → CPU; names starting with `ANE` → ANE; names starting with `DRAM`, `AMCC`, or `GPU SRAM` → Memory; DCP/DCPEXT `display stats` `power` deltas are preferred for Display, with Energy Model `DCS*` used only as a fallback; names starting with `AVE`, `ISP`, or `MSR` → Media; names containing `PCIe` or starting with `apciec` → Other SoC.
- Avoid summing detailed CPU/GPU subrails such as `PACC*_CPU*`, `PCPUDTL*`, and similar detail channels into totals; they overlap with aggregate CPU/GPU energy channels and would double-count.
- It is normal for System power to be considerably higher than modeled component power. The modeled subtotal is not board power. The PWR popup should keep System and the modeled subtotal separate and graph System as the outer total with the component stack inside it, so the System-minus-modeled delta is visible. Keep Display and Media as separate chart bands; do not collapse them into Other SoC after computing them as separate rows.
- Set `MACTOP_DEBUG_POWER=1` to print the matched private power channels and watts once after the first delta sample. This is useful when Apple changes channel names on new chips or macOS releases.

Network interface totals use `getifaddrs` and sum `en*` interface byte counters. Interface metadata uses SystemConfiguration. Public IP is fetched asynchronously from `https://api.ipify.org`.

Network top processes are intended to use the private `NetworkStatistics.framework` in-process. This is the same underlying data source used by `nettop`, but it is a private Apple ABI and may change across macOS releases.

## Known Network Caveats

`NetReader` uses SystemConfiguration's active IPv4 `PrimaryInterface` for interface metadata, local IP, SSID, MAC, and link speed. It still sums byte counters across `en*` interfaces for the menu-bar aggregate.

`NetProcessReader` uses private `NetworkStatistics.framework` callbacks. The add-source APIs can return positive values on success. Count callbacks may omit PID/name and only include byte counters, so per-source state must merge description and count dictionaries by source pointer.

Network process reporting should not depend on `nettop`.

## Editing Notes

Keep changes small and local. This is a compact AppKit codebase without a formal design system or test suite. Prefer preserving existing direct style over adding abstractions. Useful comments that document non-obvious system APIs or private framework behavior should be updated, not removed.
