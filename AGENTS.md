# mactop

mactop is a macOS menu-bar utility for recent system metrics with low runtime overhead.

Build with `make build`, run with `make dev`, and test with `swift test` (Swift 6.4, macOS 27+).

- Keep Core AppKit-free and return typed metric data. UI owns views and presentation.
- Keep process rankings per PID rather than combining children under a parent.
- Load private IOReport and NetworkStatistics dynamically so missing symbols can disable their features.
- Keep System power separate from modeled component power, including separate Display and Media bands.

Use these topic docs:

- [Build, install, checks, and release](docs/development.md)
- [Target boundaries, source map, runtime, and history](docs/architecture.md)
- [CPU, RAM, GPU, and network data sources](docs/metrics.md)
- [Process ranking and access limits](docs/processes.md)
- [Power sources, reconciliation, and private IOReport](docs/power.md)
- [Benchmark procedure and output](docs/profiling.md)
- [Historical performance measurements](docs/performance-history.md)
- [Open findings](TODO.md)
