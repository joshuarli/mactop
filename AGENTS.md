# mactop Agent Guide

## Project Shape

`mactop` is a Swift Package Manager macOS menu-bar utility. It is an accessory `NSApplication`, not a bundled `.app`. The entry point is `Sources/mactop/App.swift`.

Core files:

- `App.swift`: app lifecycle, `NSStatusItem` registration, popup routing, timers, and `SystemMonitor`.
- `Views.swift`: small menu-bar drawing views for CPU/RAM/GPU and network speed.
- `Popups.swift`: popup panels and detailed dashboard views.
- `Readers.swift`: CPU, RAM, GPU, and interface-level network readers.
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

When interpreting results, ignore launch-only dyld/AppKit setup unless optimizing startup. For idle discipline, look for work outside sleeping run loops: private `NetworkStatistics` callbacks while the network popup is hidden, repeated `SCDynamicStoreCopyValue`, IOKit GPU polling, status-item drawing allocations, formatter creation, `String(format:)`, array shifting, and full-list process sorting.

## Runtime Flow

`AppDelegate.applicationDidFinishLaunching` creates four status items: network, CPU, RAM, GPU. The network item is registered first so macOS is less likely to hide it when menu-bar space is tight. `statusPanels` must stay in the same order as `statusItems`, because click routing uses the index.

`SystemMonitor` owns the core readers and schedules interval timers:

- CPU totals: `CPUReader.read()`
- RAM totals: `RAMReader.read()`
- GPU: `GPUReader.read()`
- Network totals: `NetReader.read()`

Top-process readers are separate and visible-only. `AppDelegate` refreshes CPU, RAM, and network process lists on utility queues when the matching popup is visible or opened. Network process reporting lazily initializes the private `NetworkStatistics.framework` reader so hidden idle does not pay for callbacks.

## Data Sources

CPU totals use Mach `host_processor_info`. CPU top processes use `libproc` and per-pid CPU-time deltas.

RAM totals use Mach VM statistics and `sysctl`; RAM top processes use `libproc` APIs.

GPU uses IOKit `IOAccelerator` performance statistics.

Network interface totals use `getifaddrs` and sum `en*` interface byte counters. Interface metadata uses SystemConfiguration. Public IP is fetched asynchronously from `https://api.ipify.org`.

Network top processes are intended to use the private `NetworkStatistics.framework` in-process. This is the same underlying data source used by `nettop`, but it is a private Apple ABI and may change across macOS releases.

## Known Network Caveats

`NetReader` uses SystemConfiguration's active IPv4 `PrimaryInterface` for interface metadata, local IP, SSID, MAC, and link speed. It still sums byte counters across `en*` interfaces for the menu-bar aggregate.

`NetProcessReader` uses private `NetworkStatistics.framework` callbacks. The add-source APIs can return positive values on success. Count callbacks may omit PID/name and only include byte counters, so per-source state must merge description and count dictionaries by source pointer.

Network process reporting should not depend on `nettop`.

## Editing Notes

Keep changes small and local. This is a compact AppKit codebase without a formal design system or test suite. Prefer preserving existing direct style over adding abstractions. Useful comments that document non-obvious system APIs or private framework behavior should be updated, not removed.
