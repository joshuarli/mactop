# MAC-2: Account for network traffic by source

Status: draft

## Summary

Retain NetworkStatistics source identity across samples. Compute byte deltas per source, then sum rates by PID for presentation.

## Motivation

The current platform boundary drops source identity. The core overwrites counters from multiple sockets sharing a PID.
Summing cumulative counters per PID would still produce discontinuities when sockets disappear or source order changes.

## Design

Expose a source identity alongside PID, name, and counters at the typed platform boundary.
Distinguish a source lifetime from a reused pointer. Recreate its baseline when the framework registers a new lifetime.
A new source establishes a baseline. A known source contributes nonnegative receive and transmit deltas over the snapshot interval.
Counter resets establish a new baseline rather than subtracting unrelated values.

Aggregate deltas after source accounting, keeping individual process rows rather than combining child processes.
Remove baselines when their source lifetime ends. Decide how removal callbacks retain final counters before implementing that transition.
Keep callback state confined to the platform queue and publish a coherent snapshot to the core.

Test two sockets for one PID, reordered snapshots, a disappearing socket, counter resets, and a reused source pointer.
A process with two sockets must report their combined delta regardless of enumeration order.

## Alternatives considered

Summing cumulative counters by PID is smaller, but removal subtracts closed sockets from the next total and can hide surviving traffic.
Keeping one socket per PID preserves the current error and makes the selected connection arbitrary.

## Open questions

Should removal publish a final source delta before dropping its baseline?
Recommended: retain the final available counters until the next snapshot, then consume the removal once.
If the ABI supplies no final counters, document that the last interval of a closed source may be unavailable.

## Decision

Pending. No API or behavior change is implemented by this review.
