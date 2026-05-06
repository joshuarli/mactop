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

## Runtime Flow

`AppDelegate.applicationDidFinishLaunching` creates four status items: network, CPU, RAM, GPU. The network item is registered first so macOS is less likely to hide it when menu-bar space is tight. `statusPanels` must stay in the same order as `statusItems`, because click routing uses the index.

`SystemMonitor` owns the core readers and schedules interval timers:

- CPU: `CPUReader.read()` plus `CPUProcessReader.read()`
- RAM: `RAMReader.read()` plus `RAMProcessReader.read()`
- GPU: `GPUReader.read()`
- Network totals: `NetReader.read()`

Network top processes are separate: `AppDelegate` runs `NetProcessReader.read()` every 3 seconds on a utility queue, then updates `NetPopupView` on the main thread.

## Data Sources

CPU totals use Mach `host_processor_info`. CPU top processes currently shell out to `/bin/ps`.

RAM totals use Mach VM statistics and `sysctl`; RAM top processes use `libproc` APIs.

GPU uses IOKit `IOAccelerator` performance statistics.

Network interface totals use `getifaddrs` and sum `en*` interface byte counters. Interface metadata uses SystemConfiguration. Public IP is fetched asynchronously from `https://api.ipify.org`.

Network top processes are intended to use the private `NetworkStatistics.framework` in-process. This is the same underlying data source used by `nettop`, but it is a private Apple ABI and may change across macOS releases.

## Known Network Caveats

`NetReader` uses SystemConfiguration's active IPv4 `PrimaryInterface` for interface metadata, local IP, SSID, MAC, and link speed. It still sums byte counters across `en*` interfaces for the menu-bar aggregate.

`NetProcessReader` uses private `NetworkStatistics.framework` callbacks. The add-source APIs can return positive values on success. Count callbacks may omit PID/name and only include byte counters, so per-source state must merge description and count dictionaries by source pointer.

The remaining intentional external process is `/bin/ps` in `CPUProcessReader`. Network process reporting should not depend on `nettop`.

## Editing Notes

Keep changes small and local. This is a compact AppKit codebase without a formal design system or test suite. Prefer preserving existing direct style over adding abstractions. Useful comments that document non-obvious system APIs or private framework behavior should be updated, not removed.
