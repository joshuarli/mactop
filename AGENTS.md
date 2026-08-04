`mactop` is a macOS menu-bar utility for tracking system stats in a short, recent timeframe with the lowest possible runtime overhead.

Source layout is intentionally split so agents can search by subsystem:

- `Sources/mactop/Core/MetricHistory.swift`: shared metric history buffers and smoothing helpers used by readers and charts.
- `Sources/mactop/Core/SystemMetricsCoordinator.swift`: interval scheduling and callback delivery for core readers.
- `Sources/mactop/Core/Configuration/MactopConfig.swift`: optional update-interval configuration from `UserDefaults`.
- `Sources/mactop/Core/CPU/CPUUsageReader.swift`: typed CPU totals and per-core history via `CPUUsageReader.readCPUUsageDetail()`; Mach ownership is in `Sources/mactop/Platform/MachCPUPlatform.swift`.
- `Sources/mactop/Core/RAM/RAMUsageReader.swift`: typed RAM totals via `RAMUsageReader.readRAMUsageDetail()`; Mach VM ownership is in `Sources/mactop/Platform/MachRAMPlatform.swift`.
- `Sources/mactop/Core/GPU/GPUUsageReader.swift`: typed GPU history via `GPUUsageReader.readGPUUsageDetail()`; IOAccelerator ownership is in `Sources/mactop/Platform/IOAcceleratorPlatform.swift`.
- `Sources/mactop/Core/Power/PowerTelemetryReader.swift`: power reconciliation/history via `PowerTelemetryReader.readPowerUsageDetail()`; AppleSmartBattery and private IOReport ownership is in `Sources/mactop/Platform/PowerTelemetryPlatform.swift`.
- `Sources/mactop/Core/Network/NetworkInterfaceReader.swift`: typed interface rates via `NetworkInterfaceReader.readNetworkUsageDetail()`; `getifaddrs`/SystemConfiguration ownership is in `Sources/mactop/Platform/NetworkInterfacePlatform.swift`.
- `Sources/mactop/Core/Processes/CPUProcessUsageReader.swift`: native/`ps` CPU process ranking via `CPUProcessUsageReader.readTopCPUProcessMetrics()`; libproc ownership is in `Sources/mactop/Platform/ProcessPlatform.swift`.
- `Sources/mactop/Core/Processes/RAMProcessMemoryReader.swift`: per-process physical-footprint ranking via `RAMProcessMemoryReader.readTopRAMProcessMetrics()`; libproc ownership is in `Sources/mactop/Platform/ProcessPlatform.swift`.
- `Sources/mactop/Core/Processes/NetworkProcessReader.swift`: private `NetworkStatistics.framework` process ranking via `NetworkProcessReader.readTopNetworkProcessMetrics()`; callback ownership is in `Sources/mactop/Platform/NetworkStatisticsPlatform.swift`.
- `Sources/mactop/Core/Processes/ProcessReaderSupport.swift`: `RankedProcessMetric`, process deltas, sorted insertion, and `ps` parsing.
- `Sources/mactop/Core/Processes/ProcessDisplayName.swift`: process display-name and bundle-name resolution shared by CPU and RAM readers.
- `Sources/mactop/UI/MactopApp.swift`: AppKit lifecycle, `NSStatusItem` registration, popup routing, and visible-process refreshes.
- `Sources/mactop/UI/StatusItemViews.swift`: menu-bar CPU/RAM/GPU percentage, power, and network-speed views.
- `Sources/mactop/UI/MetricPopups.swift`: metric popup panels and detailed dashboard views.
- `Sources/mactop/UI/MetricCharts.swift`: popup chart views.
- `Sources/mactopBench/main.swift`: headless per-subsystem CPU and memory benchmark used by `make bench`.
- `Sources/mactop/Core/MetricReadPhaseRecorder.swift`: opt-in power/GPU phase timing used only by `mactopBench`.
- `PERF.md`: deferred power/GPU optimization plan, current baseline, and post-migration validation criteria.
- `Package.swift`: `mactopPlatform`, unsafe platform boundary; `mactopCore`, typed AppKit-free readers; AppKit `mactop`; and headless `mactopBench` target boundaries.
- `Tools/MactopLint`: standalone SwiftSyntax linter used by `make lint`; `make fmtlint` runs `swift-format` followed by the linter.
- `Tests/mactopTests/ProcessReadersTests.swift`: process ranking, CPU delta, power validation, and `ps` parser tests.
- `Makefile`: development, install, uninstall, and cleanup tasks.

Core files must remain AppKit-free; UI files own AppKit views and presentation-only formatting. A reader returns typed metric data, while a popup or status-item view formats and renders that data.

## Profiling Procedure

Use the headless core benchmark for repeatable subsystem baselines:

```sh
make bench
```

`make bench` builds and runs the `mactopBench` executable from `Sources/mactopBench/main.swift`. It links only the `mactopCore` target from `Sources/mactop/Core/`; it does not create an `NSApplication`, register an `NSStatusItem`, construct popup views, run AppKit timers, or execute `SystemMetricsCoordinator`.

The benchmark launches one isolated child process per subsystem and starts all nine children concurrently: `CPUUsageReader`, `RAMUsageReader`, `GPUUsageReader`, `PowerTelemetryReader`, `NetworkInterfaceReader`, `CPUProcessUsageReader`, `RAMProcessMemoryReader`, `NetworkProcessReader`, and `SystemMetricsCoordinator`. Each child gets two warm-up ticks, then one read per interval for five seconds, so the default measured wall time is approximately five seconds plus child startup and build time. The output reports the actual completed `ticks`. Per-subsystem allocator and footprint measurements are isolated because each child owns exactly one reader or coordinator. The network-interface run performs no external network requests; the network-process run exercises the private `NetworkStatistics.framework` callbacks in its own child. The coordinator run drives its utility queues and main-actor callbacks through a headless `RunLoop`, reporting callback deliveries in addition to read ticks.

The default cadence can be overridden without editing the repository:

```sh
BENCH_SECONDS=20 BENCH_INTERVAL=1 BENCH_WARMUP_TICKS=3 BENCH_PROCESS_COUNT=8 make bench
```

The output columns are defined as follows:

- `wall_ms`: elapsed time for that subsystem child’s measured window, including tick sleeps; all rows overlap in wall time.
- `total_wall`: parent-process elapsed time from launching the eight children until all eight exit.
- `cpu_ms`: user plus system CPU time for the benchmark thread, measured with Mach `thread_info`; tick sleeps do not count as CPU time.
- `cpu_ms/tick`: `cpu_ms` divided by the actual number of completed reads.
- `peak_live_allocs`: peak increase in live malloc blocks from the post-warm-up baseline, sampled with `malloc_zone_statistics(nil, ...)`.
- `peak_live_bytes`: peak increase in live malloc bytes from that same baseline.
- `peak_reserved`: peak increase in allocator-reserved bytes.
- `peak_footprint`: peak increase in task physical footprint from Mach `TASK_VM_INFO`.

The report also prints opt-in phase timings for power and GPU. Power phases are `battery.read`, `io_report.sample`, `io_report.delta`, `io_report.parse`, and history work. GPU phases are `ioaccelerator.properties`, `ioaccelerator.service_lookup`, and history work. Phase timings are wall-clock durations summed across measured ticks; initialization phases are normally consumed by warm-up and may be absent from the steady-state report.

These allocation columns measure live and peak allocator state, not the total number of malloc calls. Use Instruments only after `make bench` identifies a subsystem that needs call-site attribution. For a Time Profiler or Allocations trace, profile `mactopBench` rather than the menu-bar app so launch/AppKit work remains separate from core reader behavior.

`BENCH_PROCESS_COUNT` controls the number of rows retained by each process-ranking reader; it defaults to 8 and is capped at 128. Process readers are benchmarked in isolated children so their libproc scans, `/bin/ps` fallback, display-name resolution, and private NetworkStatistics callbacks do not contaminate the aggregate readers. The benchmark does not create AppKit views, so icon lookup remains outside this coverage.
`BENCH_PROCESS_COUNT` controls the number of rows retained by each process-ranking reader; it defaults to 8 and is capped at 128. Process readers are benchmarked in isolated children so their libproc scans, `/bin/ps` fallback, display-name resolution, and private NetworkStatistics callbacks do not contaminate the aggregate readers. The benchmark does not create AppKit views, so icon lookup remains outside this coverage.

`BENCH_COORDINATOR_HISTORY=1` enables history delivery for all five coordinator metrics; the default `0` measures the normal hidden-popup path. The coordinator row's `deliveries` value counts callback deliveries to its headless sinks; the five metric callbacks normally produce five deliveries per completed coordinator tick.

When interpreting results, compare like-for-like runs on the same machine and power state. The power reader may load private `IOReport` lazily, the GPU reader may discover its IOKit service on the first read, network interface metadata may change when the active interface changes, and NetworkStatistics availability/source counts may change with system traffic; keep those first-read effects in the warm-up window unless startup cost is the subject of the investigation.

## Runtime Flow

`MactopAppDelegate.applicationDidFinishLaunching` creates five status items: network, CPU, RAM, GPU, PWR. The network item is registered first so macOS is less likely to hide it when menu-bar space is tight. PWR is registered after GPU. `statusPanels` must stay in the same order as `statusItems`, because click routing uses the index.

`SystemMetricsCoordinator` owns the core readers and schedules interval timers:

- CPU totals: `CPUUsageReader.readCPUUsageDetail()`
- RAM totals: `RAMUsageReader.readRAMUsageDetail()`
- GPU: `GPUUsageReader.readGPUUsageDetail()`
- Power: `PowerTelemetryReader.readPowerUsageDetail()`
- Network totals: `NetworkInterfaceReader.readNetworkUsageDetail()`

Top-process readers are separate and visible-only. `MactopAppDelegate` refreshes CPU, RAM, and network process lists on utility queues when the matching popup is visible or opened. Network process reporting lazily initializes the private `NetworkStatistics.framework` reader so hidden idle does not pay for callbacks.

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
- `PlatformBatteryPowerReader` reads `AppleSmartBattery` from IOKit.
- `PowerTelemetryData.SystemPowerIn` is preferred, falling back to `SystemCurrentIn * SystemVoltageIn`, `SystemLoad`, `BatteryPower`, then raw battery `Voltage * InstantAmperage`/`Amperage`.
- This is intended to represent whole-machine input/draw and includes power outside the SoC: display panel/backlight, radios, storage, USB/Thunderbolt, PMIC/conversion losses, charging/battery behavior, fans where present, and other board rails.
- `AppleSmartBattery` telemetry can update slowly or stay cached for seconds/minutes on AC/full battery. Keep a System-minus-modeled baseline from that source, then let the live modeled subtotal move within it so menu-bar System power responds to fast IOReport changes.
- This source may be unavailable on desktops or unusual battery states; in that case PWR falls back to modeled component power.
- Charging data also comes from `AppleSmartBattery`: `AdapterDetails.Watts` is the negotiated adapter maximum, `SystemPowerIn` is current system input, and `BatteryPower` is battery charge/discharge when available. The popup's Charging section should keep those concepts separate; do not label adapter max as live draw.

**Modeled component power**:
- `PlatformModeledPowerReader` dynamically loads private `IOReport` with `dlopen`, trying `/usr/lib/libIOReport.dylib`, `libIOReport.dylib`, the old private framework path, then `IOReport`. Do not link IOReport in `Package.swift`.
- It subscribes to `Energy Model` plus DCP/DCPEXT display-report groups, samples every 2 seconds, deltas counters with real elapsed time, and converts `mJ`/`uJ`/`nJ` to watts. Avoid `IOReportCopyAllChannels`; DCP `display stats` subgroup-only subscriptions can return zero deltas for `power`, so use the DCP group and filter to `display stats` while parsing.
- Channel mapping: `GPU Energy` → GPU; names ending in `CPU Energy` → CPU; names starting with `ANE` → ANE; names starting with `DRAM`, `AMCC`, or `GPU SRAM` → Memory; DCP/DCPEXT `display stats` `power` deltas are preferred for Display, with Energy Model `DCS*` used only as a fallback; names starting with `AVE`, `ISP`, or `MSR` → Media; names containing `PCIe` or starting with `apciec` → Other SoC.
- Avoid summing detailed CPU/GPU subrails such as `PACC*_CPU*`, `PCPUDTL*`, and similar detail channels into totals; they overlap with aggregate CPU/GPU energy channels and would double-count.
- It is normal for System power to be considerably higher than modeled component power. The modeled subtotal is not board power. The PWR popup should keep System and the modeled subtotal separate and graph System as the outer total with the component stack inside it, so the System-minus-modeled delta is visible. Keep Display and Media as separate chart bands; do not collapse them into Other SoC after computing them as separate rows.
- Set `MACTOP_DEBUG_POWER=1` to print the matched private power channels and watts once after the first delta sample. This is useful when Apple changes channel names on new chips or macOS releases.

Network interface totals use `getifaddrs` and sum `en*` interface byte counters. Interface metadata uses SystemConfiguration for the active interface, local IP, SSID, MAC, and link speed.

Network top processes are intended to use the private `NetworkStatistics.framework` in-process. This is the same underlying data source used by `nettop`, but it is a private Apple ABI and may change across macOS releases.

## Private ABI Inventory

Every private or undocumented Apple interface `mactop` touches, with the exact symbols/keys, the stability reasoning, and the degradation behavior when an interface changes. "Private" means Apple ships no stable public contract and can break it in any OS update; every use is deliberately scoped so a break degrades that one feature instead of crashing or corrupting data.

**IOReport — modeled component power** (`Sources/mactop/Core/Power/PowerTelemetryReader.swift`):
- Loaded with `dlopen` at first power read; never linked in `Package.swift`. Paths tried: `/usr/lib/libIOReport.dylib`, `libIOReport.dylib`, `/System/Library/PrivateFrameworks/IOReport.framework/IOReport`, `IOReport`. All symbols resolved with `dlsym`; any miss disables modeled power (`PlatformModeledPowerReader` init returns nil) and PWR falls back to System-only.
- Symbols: `IOReportCopyChannelsInGroup`, `IOReportCreateSubscription`, `IOReportCreateSamples`, `IOReportCreateSamplesDelta`, `IOReportMergeChannels`, `IOReportChannelGetGroup`, `IOReportChannelGetSubGroup`, `IOReportChannelGetChannelName`, `IOReportChannelGetChannelID`, `IOReportChannelGetDriverID`, `IOReportChannelGetUnitLabel`, `IOReportSimpleGetIntegerValue`.
- Channel addressing: a channel is `(driverID, channelID)`. The channel ID alone is **not** unique — e.g. PCIe ports and `apciec*` rails share the `"EngyPt0"` id (`0x456e677950727430`) and DCP/DCPEXT0/DCPEXT1 share `"IOMFBENG"` (`0x494f4d4642454e47`). The `ModeledPowerReader.channelCache` classification cache is keyed on both values for this reason.
- Subscription filtering: `copyPowerChannels` keeps only the channels `classifyChannel` matches (see "Channel mapping" above), so the kernel samples ~18 channels instead of all 591 in the four groups. `channelCache` is built from that same filtered set; `parsePower` looks up delta channels by `(driverID, channelID)` and falls back to string classification if a getter ever changes, so a renamed channel degrades exactly as it did before filtering (silently ignored).
- Stability: these symbols and the Energy Model/DCP group structure have been stable across the recent macOS releases; channel IDs encode channel names, and provider IDs are IOKit registry entry IDs, so both are stable per boot and per macOS/chip. Apple changing a channel name is expected and handled by `classifyChannel`. Validate after any OS or chip change with `MACTOP_DEBUG_POWER=1`.
- Measured cost: sampling the filtered set is ~2.9 ms per sample, of which a fixed ~1.1 ms is the kernel round trip and ~1.2 ms is inherent to sampling any DCP display-power channel (1 or 3 channels cost the same). `readModeledPowerSample` samples on a 2-second cadence and returns the last computed sample in between, so the per-tick cost is roughly half (~1.1–1.3 ms/tick); the System total still updates every tick from `AppleSmartBattery`. IOReport counters are accumulated energy, so the longer delta is equally accurate, and `maximumSampleInterval` (5 s at the default cadence) already tolerated such gaps.

**NetworkStatistics.framework — per-process network bytes** (`Sources/mactop/Core/Processes/NetworkProcessReader.swift`):
- Loaded with `dlopen("/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics", RTLD_NOW)` lazily; the reader stays dormant until the network popup is visible so hidden idle pays nothing. Any `dlsym` miss or `dlopen` failure leaves network process ranking empty.
- Symbols: `NStatManagerCreate`, `NStatManagerSetFlags`, `NStatManagerAddAllTCPWithFilter`, `NStatManagerAddAllUDPWithFilter`, `NStatSourceSetDescriptionBlock`, `NStatSourceSetCountsBlock`, `NStatSourceSetRemovedBlock`, `NStatSourceQueryDescription`, `NStatManagerQueryAllSourcesUpdate`, and string keys `kNStatSrcKeyPID`, `kNStatSrcKeyProcessName`, `kNStatSrcKeyRxBytes`, `kNStatSrcKeyTxBytes`.
- Callback ABI: description and count callbacks can fire separately for the same source and count callbacks may omit PID/name, so per-source state merges both dictionaries by source pointer. Add-source APIs can return positive values on success (do not treat as error).
- Stability: this is the same private ABI `nettop` uses and may change across macOS releases; the block-based merge logic in `NetworkStatisticsPlatform.update` is the fragile part to re-check when a new macOS ships.

**AppleSmartBattery IOKit — System power and charging** (`PlatformBatteryPowerReader`):
- Public-ish IOKit service, but the dictionary keys are undocumented. Any lookup is via `[String: Any]` bridging, so an absent key just yields `nil` and the next fallback runs.
- Keys: `PowerTelemetryData` (with `SystemPowerIn`, `SystemCurrentIn`, `SystemVoltageIn`, `SystemLoad`, `BatteryPower`, `WallEnergyEstimate`, `SystemEnergyConsumed`), `AdapterDetails`/`AppleRawAdapterDetails` (`Name`, `Watts`), `ExternalConnected`/`AppleRawExternalConnected`, `IsCharging`, `FullyCharged`, `CurrentCapacity`/`AppleRawCurrentCapacity`, `MaxCapacity`/`AppleRawMaxCapacity`, `Voltage`/`AppleRawBatteryVoltage`, `InstantAmperage`, `Amperage`.
- The `systemWatts` fallback chain (`SystemPowerIn` → `SystemCurrentIn * SystemVoltageIn` → `SystemLoad` → `BatteryPower` → `Voltage * Amperage`) makes individual key changes degrade gracefully. On desktops the whole source may be unavailable; PWR falls back to modeled power.
- Reads use single-key `IORegistryEntryCreateCFProperty` lookups, not the full property tree (`IORegistryEntryCreateCFProperties`, ~60 keys, ~0.6 ms). Each single-key read is ~0.005–0.015 ms with identical values, so the whole `battery.read` is ~0.1 ms and is further cached every 2 s.
- Validate key coverage with `MACTOP_DEBUG_BATTERY=1`.

**IOAccelerator IOKit + PerformanceStatistics — GPU** (`Sources/mactop/Core/GPU/GPUUsageReader.swift`):
- Matches `IOAccelerator` services via `IOServiceGetMatchingServices`, then reads `PerformanceStatistics`. The steady-state path uses `IORegistryEntryCreateCFProperty(service, "PerformanceStatistics", ...)` — a single-key read (~0.12 ms/tick) rather than the full property tree via `IORegistryEntryCreateCFProperties` (~2.5 ms/tick) — and extracts the three numeric fields with `CFDictionaryGetValue`/`CFNumberGetValue`. The full-properties read remains as a fallback if the single-key read misses. Failure to find a service leaves GPU at zero rather than failing the read.
- Keys: `"Device Utilization %"` or `"GPU Activity(%)"` for total — both spellings appear across Macs (this repo's M1 Pro reports `"Device Utilization %"`, some Apple Silicon chips report `"GPU Activity(%)"`), so the reader checks both and defaults to zero — plus `"Renderer Utilization %"` and `"Tiler Utilization %"`.
- Renderer/tiler independence: the AGX driver does not report these on every chip. On M1/M2 the three keys mirror the same busy value (identical graphs), while on M3+ they can be genuine splits (`Device 16% / Renderer 11% / Tiler 7%` observed on M3 Pro). `GPUUsageReader.renderTilerSplit` detects this at runtime (`abs(render - tiler) > 0.005` after any read) rather than guessing by chip family, and `GPUUsageDetail.hasRenderTilerSplit` drives the GPU popup: `GPUPopupView.setShowsRenderTiler` rebuilds `makeStatsView(showRenderTiler:)` to collapse to a single centered GPU circle + full-width chart when the driver reports no split.
- Stability: `PerformanceStatistics` is an undocumented driver-generated dict, but the keys and the `IORegistryEntryCreateCFProperty` single-key access have been stable across the recent macOS releases. `IORegistryEntrySearchCFProperty` is deliberately avoided: it returns a stale snapshot that disagrees with the full-properties read.
- Refresh semantics: the AGX driver refreshes `PerformanceStatistics` on its own cadence and a read "consumes" the fresh value — a second immediate read returns zeros. At the one-second cadence this is a non-issue. The single-key path is more robust than the full-properties path when another tool (Activity Monitor, Stats) polls the same service; the full path degrades to zeros under that competition while the single-key path stays live.

**libproc `proc_pid_rusage` / `proc_pidinfo` — process CPU/RAM** (`CPUProcessUsageReader`, `RAMProcessMemoryReader`, `ProcessReaderSupport`):
- Not a private framework, but the values are entitlement-dependent: `p_uticks`/`p_sticks` and `PROC_PIDTASKINFO` are zeroed for non-root callers without `com.apple.system-task-ports.read`. This is why the CPU reader gates the native path on a one-time probe of PID 1 and falls back to `/bin/ps`, and why cross-user processes are absent from the RAM top list.
- The `ps` fallback relies on `/bin/ps` being setuid root and carrying that private entitlement; parsing is defensive (whitespace-tolerant, missing columns skipped).

**AppleARMPE IOKit + `hw.perflevel*` sysctls — CPU cluster detection** (`Sources/mactop/Core/CPU/CPUUsageReader.swift`):
- Apple Silicon E/P-core split is read from `hw.perflevel0.name`/`hw.perflevel1.name` sysctls and `hw.perflevel*.physicalcpu`; cluster membership of individual cores comes from the `AppleARMPE` IOKit tree. On Intel these lookups miss and the reader falls back to a flat core list.

**Mach VM stats + `sysctl` — RAM and CPU totals**: public/stable interfaces (`host_processor_info`, `vm_statistics64`, `vm.swapusage`, `kern.memorystatus_vm_pressure_level`, `kern.boottime`); no special handling.

## Known Network Caveats

`NetworkInterfaceReader` uses SystemConfiguration's active IPv4 `PrimaryInterface` for interface metadata, local IP, SSID, MAC, and link speed. It still sums byte counters across `en*` interfaces for the menu-bar aggregate.

`NetworkProcessReader` uses private `NetworkStatistics.framework` callbacks. The add-source APIs can return positive values on success. Count callbacks may omit PID/name and only include byte counters, so per-source state must merge description and count dictionaries by source pointer.

Network process reporting should not depend on `nettop`.
