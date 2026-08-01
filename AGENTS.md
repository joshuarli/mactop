`mactop` is a macOS menu-bar utility for tracking system stats in a short, recent timeframe with the lowest possible runtime overhead.

Source layout is intentionally split so agents can search by subsystem:

- `Sources/mactop/Core/MetricHistory.swift`: shared metric history buffers and smoothing helpers used by readers and charts.
- `Sources/mactop/Core/SystemMetricsCoordinator.swift`: interval scheduling and callback delivery for core readers.
- `Sources/mactop/Core/Configuration/MactopConfig.swift`: optional update-interval configuration from `UserDefaults`.
- `Sources/mactop/Core/CPU/CPUUsageReader.swift`: Mach CPU totals and per-core history via `CPUUsageReader.readCPUUsageDetail()`.
- `Sources/mactop/Core/RAM/RAMUsageReader.swift`: Mach VM/RAM totals via `RAMUsageReader.readRAMUsageDetail()`.
- `Sources/mactop/Core/GPU/GPUUsageReader.swift`: IOKit `IOAccelerator` statistics via `GPUUsageReader.readGPUUsageDetail()`.
- `Sources/mactop/Core/Power/PowerTelemetryReader.swift`: AppleSmartBattery and private IOReport power telemetry via `PowerTelemetryReader.readPowerUsageDetail()`.
- `Sources/mactop/Core/Network/NetworkInterfaceReader.swift`: interface counters and SystemConfiguration metadata via `NetworkInterfaceReader.readNetworkUsageDetail()`.
- `Sources/mactop/Core/Processes/CPUProcessUsageReader.swift`: native/`ps` CPU process ranking via `CPUProcessUsageReader.readTopCPUProcessMetrics()`.
- `Sources/mactop/Core/Processes/RAMProcessMemoryReader.swift`: per-process physical-footprint ranking via `RAMProcessMemoryReader.readTopRAMProcessMetrics()`.
- `Sources/mactop/Core/Processes/NetworkProcessReader.swift`: private `NetworkStatistics.framework` process ranking via `NetworkProcessReader.readTopNetworkProcessMetrics()`.
- `Sources/mactop/Core/Processes/ProcessReaderSupport.swift`: `RankedProcessMetric`, process deltas, sorted insertion, and `ps` parsing.
- `Sources/mactop/Core/Processes/ProcessDisplayName.swift`: process display-name and bundle-name resolution shared by CPU and RAM readers.
- `Sources/mactop/UI/MactopApp.swift`: AppKit lifecycle, `NSStatusItem` registration, popup routing, and visible-process refreshes.
- `Sources/mactop/UI/StatusItemViews.swift`: menu-bar CPU/RAM/GPU percentage, power, and network-speed views.
- `Sources/mactop/UI/MetricPopups.swift`: metric popup panels and detailed dashboard views.
- `Sources/mactop/UI/MetricCharts.swift`: popup chart views.
- `Sources/mactopBench/main.swift`: headless per-subsystem CPU and memory benchmark used by `make bench`.
- `Sources/mactop/Core/MetricReadPhaseRecorder.swift`: opt-in power/GPU phase timing used only by `mactopBench`.
- `PERF.md`: deferred power/GPU optimization plan, current baseline, and post-migration validation criteria.
- `Package.swift`: `mactopCore`, AppKit `mactop`, and headless `mactopBench` target boundaries.
- `Tests/mactopTests/ProcessReadersTests.swift`: process ranking, CPU delta, power validation, and `ps` parser tests.
- `Makefile`: development, install, uninstall, and cleanup tasks.

Core files must remain AppKit-free; UI files own AppKit views and presentation-only formatting. A reader returns typed metric data, while a popup or status-item view formats and renders that data.

## Profiling Procedure

Use the headless core benchmark for repeatable subsystem baselines:

```sh
make bench
```

`make bench` builds and runs the `mactopBench` executable from `Sources/mactopBench/main.swift`. It links only the `mactopCore` target from `Sources/mactop/Core/`; it does not create an `NSApplication`, register an `NSStatusItem`, construct popup views, run AppKit timers, or execute `SystemMetricsCoordinator`.

The benchmark launches one isolated child process per subsystem and starts all five children concurrently: `CPUUsageReader`, `RAMUsageReader`, `GPUUsageReader`, `PowerTelemetryReader`, and `NetworkInterfaceReader`. Each child gets two warm-up ticks, then one read per interval for five seconds, so the default measured wall time is approximately five seconds plus child startup and build time. The output reports the actual completed `ticks`. Per-subsystem allocator and footprint measurements are isolated because each child owns exactly one reader. The network run sets `fetchPublicIP: false` so external HTTP latency and callbacks do not contaminate the baseline.

The default cadence can be overridden without editing the repository:

```sh
BENCH_SECONDS=20 BENCH_INTERVAL=1 BENCH_WARMUP_TICKS=3 make bench
```

The output columns are defined as follows:

- `wall_ms`: elapsed time for that subsystem child’s measured window, including tick sleeps; all rows overlap in wall time.
- `total_wall`: parent-process elapsed time from launching the five children until all five exit.
- `cpu_ms`: user plus system CPU time for the benchmark thread, measured with Mach `thread_info`; tick sleeps do not count as CPU time.
- `cpu_ms/tick`: `cpu_ms` divided by the actual number of completed reads.
- `peak_live_allocs`: peak increase in live malloc blocks from the post-warm-up baseline, sampled with `malloc_zone_statistics(nil, ...)`.
- `peak_live_bytes`: peak increase in live malloc bytes from that same baseline.
- `peak_reserved`: peak increase in allocator-reserved bytes.
- `peak_footprint`: peak increase in task physical footprint from Mach `TASK_VM_INFO`.

The report also prints opt-in phase timings for power and GPU. Power phases are `battery.read`, `io_report.sample`, `io_report.delta`, `io_report.parse`, and history work. GPU phases are `ioaccelerator.properties`, `ioaccelerator.service_lookup`, and history work. Phase timings are wall-clock durations summed across measured ticks; initialization phases are normally consumed by warm-up and may be absent from the steady-state report.

These allocation columns measure live and peak allocator state, not the total number of malloc calls. Use Instruments only after `make bench` identifies a subsystem that needs call-site attribution. For a Time Profiler or Allocations trace, profile `mactopBench` rather than the menu-bar app so launch/AppKit work remains separate from core reader behavior.

When interpreting results, compare like-for-like runs on the same machine and power state. The power reader may load private `IOReport` lazily, the GPU reader may discover its IOKit service on the first read, and network interface metadata may change when the active interface changes; keep those first-read effects in the warm-up window unless startup cost is the subject of the investigation.

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
- `PowerTelemetryReader.BatteryPowerReader` reads `AppleSmartBattery` from IOKit.
- `PowerTelemetryData.SystemPowerIn` is preferred, falling back to `SystemCurrentIn * SystemVoltageIn`, `SystemLoad`, `BatteryPower`, then raw battery `Voltage * InstantAmperage`/`Amperage`.
- This is intended to represent whole-machine input/draw and includes power outside the SoC: display panel/backlight, radios, storage, USB/Thunderbolt, PMIC/conversion losses, charging/battery behavior, fans where present, and other board rails.
- `AppleSmartBattery` telemetry can update slowly or stay cached for seconds/minutes on AC/full battery. Keep a System-minus-modeled baseline from that source, then let the live modeled subtotal move within it so menu-bar System power responds to fast IOReport changes.
- This source may be unavailable on desktops or unusual battery states; in that case PWR falls back to modeled component power.
- Charging data also comes from `AppleSmartBattery`: `AdapterDetails.Watts` is the negotiated adapter maximum, `SystemPowerIn` is current system input, and `BatteryPower` is battery charge/discharge when available. The popup's Charging section should keep those concepts separate; do not label adapter max as live draw.

**Modeled component power**:
- `PowerTelemetryReader.ModeledPowerReader` dynamically loads private `IOReport` with `dlopen`, trying `/usr/lib/libIOReport.dylib`, `libIOReport.dylib`, the old private framework path, then `IOReport`. Do not link IOReport in `Package.swift`.
- It subscribes to `Energy Model` plus DCP/DCPEXT display-report groups, samples twice, deltas counters with real elapsed time, and converts `mJ`/`uJ`/`nJ` to watts. Avoid `IOReportCopyAllChannels`; DCP `display stats` subgroup-only subscriptions can return zero deltas for `power`, so use the DCP group and filter to `display stats` while parsing.
- Channel mapping: `GPU Energy` → GPU; names ending in `CPU Energy` → CPU; names starting with `ANE` → ANE; names starting with `DRAM`, `AMCC`, or `GPU SRAM` → Memory; DCP/DCPEXT `display stats` `power` deltas are preferred for Display, with Energy Model `DCS*` used only as a fallback; names starting with `AVE`, `ISP`, or `MSR` → Media; names containing `PCIe` or starting with `apciec` → Other SoC.
- Avoid summing detailed CPU/GPU subrails such as `PACC*_CPU*`, `PCPUDTL*`, and similar detail channels into totals; they overlap with aggregate CPU/GPU energy channels and would double-count.
- It is normal for System power to be considerably higher than modeled component power. The modeled subtotal is not board power. The PWR popup should keep System and the modeled subtotal separate and graph System as the outer total with the component stack inside it, so the System-minus-modeled delta is visible. Keep Display and Media as separate chart bands; do not collapse them into Other SoC after computing them as separate rows.
- Set `MACTOP_DEBUG_POWER=1` to print the matched private power channels and watts once after the first delta sample. This is useful when Apple changes channel names on new chips or macOS releases.

Network interface totals use `getifaddrs` and sum `en*` interface byte counters. Interface metadata uses SystemConfiguration. Public IP is fetched asynchronously from `https://api.ipify.org`.

Network top processes are intended to use the private `NetworkStatistics.framework` in-process. This is the same underlying data source used by `nettop`, but it is a private Apple ABI and may change across macOS releases.

## Known Network Caveats

`NetworkInterfaceReader` uses SystemConfiguration's active IPv4 `PrimaryInterface` for interface metadata, local IP, SSID, MAC, and link speed. It still sums byte counters across `en*` interfaces for the menu-bar aggregate.

`NetworkProcessReader` uses private `NetworkStatistics.framework` callbacks. The add-source APIs can return positive values on success. Count callbacks may omit PID/name and only include byte counters, so per-source state must merge description and count dictionaries by source pointer.

Network process reporting should not depend on `nettop`.
