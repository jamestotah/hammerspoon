# Unified Command-Tab verification

The optimization branch preserves the switcher's existing behavior and reduces
work in Dia selection, snapshot reconciliation, and initial redraw scheduling.
Production changes stay in `Spoons/UnifiedCommandTab.spoon/init.lua`; the public
Spoon interface, polling intervals, and settings key are unchanged.

## Isolated regression tests

From the repository root, run with Lua 5.2 or newer:

```sh
lua tests/run.lua
```

Alternatively, use Hammerspoon's Lua runtime with an absolute checkout path:

```sh
hs -c 'dofile("/absolute/checkout/tests/run.lua")'
```

The runner gives tests private globals and mocks all Hammerspoon operations.
It does not replace the live `hs`, reload the configuration, register native
watchers, change settings, or focus applications. Each behavior scenario loads
a fresh Spoon. The historical regression scenario is retained separately.

Coverage includes forward/reverse/wrapped cycling, modifier pass-through, both
key-release orders, deferred/coalesced rendering, quick release, watchdog
recovery, stable pointer selection, activation errors, window ownership,
bundle-less apps, Spokenly identity and window gating, the 100-entry MRU cap,
title updates, moved tabs, closed/empty snapshots, stale metadata, queued Dia
notifications, persistence, and resource shutdown. Timer cancellation and late
task delivery are explicit in the fixture.

These tests validate Lua behavior and generated script inputs. They do not
execute browser focus commands or prove native canvas/accessibility behavior.

## Read-only Dia benchmark

Run with Dia already open, Hammerspoon running, and `hs` on PATH:

```sh
python3 scripts/benchmark_dia.py \
  --baseline /absolute/baseline/Spoons/UnifiedCommandTab.spoon/init.lua \
  --samples 5 --max-candidate-ms 1000
```

The candidate defaults to this checkout's Spoon. The benchmark uses the isolated
fixture to capture each version's production-generated selection script. It
replaces `focus theTab` with a returned tab-ID check and verifies the result.
First, middle, and last tabs are tested, along with a missing recorded window ID
and a nonexistent tab ID. Keep the tab set stable during the run. Five samples
per case alternate baseline/candidate order; the reported p95 is the maximum
with this small sample count.

No tabs are focused, moved, opened, or closed. The stale window ID exercises the
moved-tab fallback but does not replace a real multi-window move test. Output
contains timings and counts, not tab titles or IDs. A latency budget is enforced
only when `--max-candidate-ms` is supplied. The example sets a 1,000 ms median
limit for each candidate case; choose a limit appropriate to the machine.
Use `--cases last` for a shorter run.

### Measured lookup results

Measured on October 8, 2026, with Dia 1.51.1, one window, and 183 tabs, comparing
baseline `0bbd584` with the stable-ID selection change in `0367fb8`:

| Case | Baseline median | Candidate median |
| --- | ---: | ---: |
| First tab | 345.5 ms | 364.6 ms |
| Middle tab | 3,847.2 ms | 318.1 ms |
| Last tab | 7,722.7 ms | 295.1 ms |
| Stale window-ID fallback | 4,699.0 ms | 300.9 ms |
| Missing tab | 11,586.4 ms | 274.6 ms |

All lookups returned the expected identity or `false`. The last-tab median was
about 26 times faster; first-tab lookup remained in a similar range. These
numbers include process startup and lookup, **not key delivery or focus**.
The reported child CPU figure measures only `osascript`, not Dia, Hammerspoon,
or total machine overhead.

## Snapshot reconciliation benchmark

```sh
hs -c 'local r = dofile("/absolute/checkout/scripts/benchmark_reconciliation.lua")("/absolute/baseline/Spoons/UnifiedCommandTab.spoon/init.lua", "/absolute/checkout/Spoons/UnifiedCommandTab.spoon/init.lua"); assert(r.candidateInstructions < r.baselineInstructions / 10)'
```

This synthetic workload reconciles 1,000 tab records against 100 history entries
and 100 cycle entries. A temporary Lua instruction-count hook measures only the
completion/reconciliation path and is removed after the measurement. It makes
no native browser calls.

The baseline used approximately 1,857,000 instructions versus 32,000 after
indexing target copies: about 58 times fewer. One run measured 13.62 ms versus
1.05 ms of Lua CPU time; instruction counts are the more repeatable comparison.
This does not measure AppleScript metadata-query time or idle CPU consumption.

## Live acceptance and remaining limits

Native focus testing and installation into the live configuration were deferred
at the user's request. Before rollout, identify the currently loaded switcher
version, then verify actual release-to-focus behavior for Dia and Chrome,
ordinary windows, Spokenly, moved/closed tabs, and multiple windows/displays.
Check mouse selection during reconciliation, rapid cycling, both key-release
orders, and overlay recovery. Reloading rebuilds in-memory history.

Aggregate background CPU and battery impact have not been established. The
polling and observer cadence is unchanged; use the same live workload before
and after installation to measure that impact separately.

A separate pre-existing lifecycle defect was reproduced during test work:
an active-tab task delivered after `stop()` can alter history because that
callback lacks the metadata task's lifecycle guard. The optimization does not
change that path. A follow-up should test stop/restart with a late active-task
completion and prevent it from mutating history or clearing a newer task.
