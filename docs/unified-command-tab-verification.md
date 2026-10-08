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

## Native Dia focus test

This is an opt-in test that changes focus temporarily. Run it only when a brief
interruption is acceptable:

```sh
hs -t 90 -c 'dofile("/absolute/checkout/scripts/verify_dia_focus.lua")()'
```

The script captures the candidate's unmodified production selection scripts
using the isolated fixture, then executes them through
`hs.osascript.applescript`. It checks the active tab/window and whether Dia is
frontmost. It snapshots each window's original selected tab, restores selections
back-to-front even after a test failure, and restores the original application
and window. It does not install a switcher or open, close, or move any tabs.

On October 8, 2026, the full test passed with two Dia windows containing 16 and
193 tabs:

| Case | Selection command | Command plus verification |
| --- | ---: | ---: |
| First tab in large window | 805 ms | 889 ms |
| Last tab in large window | 813 ms | 913 ms |
| Other window's selected tab | 468 ms | 565 ms |
| Wrong existing window fallback | 769 ms | 855 ms |
| Missing window fallback | 219 ms | 458 ms |
| Missing tab, no substitute | 137 ms | 248 ms |

All six cases passed and restoration checks confirmed the original Dia
selections, application, and frontmost window. These are individual smoke-test
measurements, not medians or key-release latency. The wrong-window test uses a
target absent from the recorded window but present in another open window; it
does not physically move a tab. An initial invocation hit the CLI's default
four-second receive timeout after four passing cases and restored the original
state; its final case diagnostic was unavailable. The complete rerun used the
90-second CLI timeout shown above.

## Installed Command-Tab trial

On October 8, 2026, the live checkout was switched from baseline `0bbd584` to
`live/unified-command-tab-optimized` at the committed optimization, and
Hammerspoon was reloaded. The registered, enabled `UnifiedCommandTab` Spoon
reported its source as `~/.hammerspoon/Spoons/UnifiedCommandTab.spoon/init.lua`.
Accessibility was available and Secure Input was off.

An opt-in asynchronous trial posts actual macOS Command/Shift/Tab events to the
installed event tap. It seeds history through native focus changes and waits
for normal browser observation. It reads private Lua state only to inspect the
highlight, cycle, and canvas; it neither modifies that state nor invokes private
callbacks. Native AppleScript read-back confirms the active tab/window.

```sh
hs -t 30 -c 'dofile("/absolute/checkout/scripts/verify_live_cmd_tab.lua")("/absolute/writable/trial-report.json")'
```

The call returns when the trial starts. Wait for the JSON report before using
the keyboard or interpreting the outcome. Run only when brief focus changes
are acceptable, with all physical modifiers released. The trial restores each
Dia window's selected tab, the original frontmost application/window, and the
mouse position. Normal MRU observations made during testing remain in history.

The final run passed all four cases:

| Real event sequence | Release to verified target |
| --- | ---: |
| Forward; Tab up before Command up | 501 ms |
| Forward; Command up before Tab up | 370 ms |
| Repeated forward then reverse | 257 ms |
| Reverse across the list boundary and back to current | 138 ms |

All cases preserved the active tab while cycling and selected the highlighted
target on release. The canvas showed 10 rows for 10 entries. Final checks
confirmed hidden overlay, cleared cycle, enabled event tap, released Command
and Shift, and successful restoration. These are individual synthetic-event
smoke timings including read-back/polling overhead, not hardware-key latency
percentiles.

Earlier trial attempts exposed two harness assumptions: Dia's active-tab
property can briefly lag a successful focus command, and synthetic modifier
events need explicit flags. The harness now allows bounded focus settling and
posts explicit modifier flags. No production change was needed; cleanup
succeeded on failed attempts as well.

### Rollback on this Mac

The previous branch remains available. With a clean live working tree:

```sh
git -C ~/.hammerspoon switch fix/unified-command-tab-overlay-recovery
hs -c 'hs.timer.doAfter(0.1, hs.reload)'
```

Reloading rebuilds in-memory history. To restore the optimized version, switch
back to `live/unified-command-tab-optimized` and reload again.

## Remaining limits

The installed trial exercised Dia keyboard selection. Native Chrome activation,
Spokenly, mouse selection, physical tab moves, and multiple displays have not
received a live acceptance trial in this work. Their covered Lua behavior
continues to pass the isolated suite; Chrome's selection code is unchanged.

Aggregate background CPU and battery impact have not been established. The
polling and observer cadence is unchanged; use the same live workload before
and after installation to measure that impact separately.

A separate pre-existing lifecycle defect was reproduced during test work:
an active-tab task delivered after `stop()` can alter history because that
callback lacks the metadata task's lifecycle guard. The optimization does not
change that path. A follow-up should test stop/restart with a late active-task
completion and prevent it from mutating history or clearing a newer task.
