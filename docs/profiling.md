# Profile core readers

Run the headless release benchmark from the repository root:

```sh
make bench
```

[main.swift](../Sources/mactopBench/main.swift) launches nine concurrent child processes: CPU, RAM, GPU, power, network interface, three process readers, and the coordinator.
It links the core and platform targets and never starts AppKit or constructs status items, popups, or icons.
The coordinator scenario drives `SystemMetricsCoordinator` utility queues and main-actor callbacks through a Foundation run loop.
Profile mactopBench with Instruments for reader attribution. Profile the app separately for popup and icon work.

## Configure a run

The defaults are five measured seconds, a one-second interval, two warm-up reads, eight process rows, and coordinator history disabled.
Override them without changing code:

```sh
BENCH_SECONDS=20 BENCH_INTERVAL=1 BENCH_WARMUP_TICKS=3 BENCH_PROCESS_COUNT=8 BENCH_COORDINATOR_HISTORY=1 make bench
```

Reader scenarios perform warm-up reads back to back, without sleeping. They request history for all aggregate reads.
The coordinator instead warms up by running its timers for interval times warm-up ticks. `BENCH_COORDINATOR_HISTORY=1` enables its history delivery.
Process row count is clamped to 1–128. Duration, interval, and warm-up limits live in `BenchConfiguration`.

## Interpret output

The columns have these meanings:

| Column | Reader scenarios | Coordinator |
| --- | --- | --- |
| `ticks` | Completed reads | Duration divided by interval, truncated, not observed ticks |
| `deliveries` | Same as reads | Observed callback deliveries |
| `wall_ms` | Measured window including sleeps | Run-loop window |
| `cpu_ms` | Benchmark-thread user + system CPU around each read, from Mach `thread_info` | Process thread CPU from `TASK_THREAD_TIMES_INFO` across the measured window |
| `cpu_ms/tick` | CPU divided by completed reads | CPU divided by estimated ticks |
| `peak_live_allocs` | Maximum sampled live-block increase over post-warm-up baseline | Endpoint increase only |
| `peak_live_bytes` | Maximum sampled live-byte increase over baseline | Endpoint increase only |
| `peak_reserved` | Maximum sampled allocator-reserved increase over baseline | Endpoint increase only |
| `peak_footprint` | Maximum sampled physical-footprint increase over baseline | Endpoint increase only |

Memory snapshots use `malloc_zone_statistics` and Mach `TASK_VM_INFO`.
They measure live state, not total malloc calls. Reader snapshots taken after reads can also miss transient peaks within a read.
Thread CPU omits work on NetworkStatistics callback queues. Compare CPU only within the same scenario and configuration.
`total_wall` spans parent launch of all nine children through their completion, including warm-up and startup but excluding the build.

Power and GPU report summed wall-clock phase durations and counts. Phase time is not CPU time.
GPU currently records `ioaccelerator.properties` and history append, not separate service-lookup or history-snapshot phases.
Instrumentation adds overhead. The platform's IOReport timing is currently unconditional even when the core recorder is absent.

## Compare changes

Compare the same machine, power state, duration, interval, history setting, and process count.
Keep discovery and initialization in warm-up unless startup is the measurement target.
Network source availability, live traffic, and battery/driver caches can vary between runs.

For time-based gates, require `perf-gate-ready` to exit zero before a measurement and run it again with `-1` immediately afterward.
Discard runs that overlapped load. If the host remains busy, report `perf gate deferred: host busy`.
Use CPU time, the minimum of repeated runs, and interleaved baseline/candidate runs. Treat a regression as actionable only when it exceeds observed spread.
Memory and binary-size gates still run when time gates are deferred.
Historical results are in [performance history](performance-history.md). They are not a current pass or release gate.
