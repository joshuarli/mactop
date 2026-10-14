# Aggregate metric sources

The [source map](architecture.md#source-map) links each reader to its platform boundary.

## CPU and RAM

CPU uses Mach `host_processor_info` interval deltas. Load averages come from `getloadavg`, cached for five seconds.
Uptime comes from `kern.boottime`. Per-core kinds come from `cluster-type` properties below AppleARMPE, with unknown kinds when lookup fails.
The implementation does not query `hw.perflevel*` sysctls.

RAM uses Mach VM statistics, `hw.memsize`, and the host page size.
Swap usage and `kern.memorystatus_vm_pressure_level` are cached for five seconds.
These are public system interfaces. Per-process access limits are described in [process ranking](processes.md).

## GPU

The platform reader discovers an IOAccelerator service and reads its undocumented `PerformanceStatistics` dictionary.
It tries a single-key `IORegistryEntryCreateCFProperty` read before the full-properties fallback.
Total utilization uses `Device Utilization %`, then `GPU Activity(%)`. Renderer and tiler use their respective utilization keys.
Missing fields become zero. A failed platform read leaves the core reader's last values unchanged, initially zero.

The popup shows renderer/tiler columns only after their values differ by more than 0.005 in normalized units.
This checks driver output rather than guessing by chip family. Some drivers mirror all three values.
The split remains enabled once observed.

Earlier live investigations found recursive `IORegistryEntrySearchCFProperty` snapshots stale and immediate repeat reads susceptible to zeros.
Keep those observations in mind when comparing polling tools. They have not been revalidated in this refresh.

## Network

Totals sum byte counters for all `en*` interfaces through `getifaddrs`.
Metadata uses SystemConfiguration's active IPv4 `PrimaryInterface`, so the displayed interface need not account for all aggregate traffic.
IP, SSID, MAC, and link metadata refresh about every fifteen seconds.
Initial rate samples, counter resets, and invalid elapsed times produce zero rates.
The reader makes no external network requests.
