#!/usr/bin/env python3
"""Compare production-generated Dia selection lookups without changing focus."""

import argparse
import json
import math
from pathlib import Path
import resource
import re
import statistics
import subprocess
import time


ROOT = Path(__file__).resolve().parents[1]


def applescript(script, timeout=30):
    result = subprocess.run(
        ["/usr/bin/osascript", "-e", script], capture_output=True, text=True,
        timeout=timeout,
    )
    if result.returncode:
        # Native error descriptions may echo window/tab identifiers.
        detail = re.sub(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", "<ID>", result.stderr.strip())
        raise RuntimeError(detail[:500])
    return result.stdout.strip()


def lua_string(text):
    # JSON's ASCII \u escapes are not Lua string escapes.
    return json.dumps(str(text), ensure_ascii=False)


def capture_script(module, window_id, tab_id):
    """Drive the isolated fixture's public cycle/click path; capture, never focus."""
    command = """
local factory = dofile(%s)
local f = factory(%s)
f:observeBrowser("company.thebrowser.dia", %s, %s, "Benchmark target")
f:observeBrowser("company.thebrowser.dia", "benchmark-other-window", "benchmark-other-tab", "Other target")
assert(f:key("keyDown", {cmd=true}))
f:flush()
f:click("browserTab:company.thebrowser.dia:" .. %s)
assert(#f.selectionScripts == 1, "expected exactly one captured selection")
f.switcher:stop()
print("DIA_SCRIPT=" .. hs.json.encode({script=f.selectionScripts[1]}))
""" % tuple(map(lua_string, (
        ROOT / "tests/support/mock_hs.lua", module, window_id, tab_id, tab_id,
    )))
    result = subprocess.run(["hs", "-c", command], capture_output=True, text=True,
                            timeout=10)
    lines = [line for line in result.stdout.splitlines() if line.startswith("DIA_SCRIPT=")]
    if len(lines) != 1:
        raise RuntimeError("Script capture failed: " + result.stdout + result.stderr)
    return json.loads(lines[0].removeprefix("DIA_SCRIPT="))["script"]


def lookup_only(script):
    """Replace every production focus statement with a returned identity check."""
    lines = script.splitlines()
    count = 0
    for index, line in enumerate(lines):
        if line.strip() == "focus theTab":
            # Return the actual resolved ID, checked against the expected ID in Python.
            lines[index] = "return id of theTab as text"
            count += 1
    if count == 0:
        raise RuntimeError("No recognized focus statement; refusing to run the script")
    probe = "\n".join(lines)
    if any(line.strip().startswith(("focus ", "activate", "close ", "make "))
           for line in probe.splitlines()):
        raise RuntimeError("Unexpected action in lookup-only script")
    return probe


def measure(script, expected, timeout):
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    start = time.perf_counter()
    result = applescript(script, timeout)
    elapsed = (time.perf_counter() - start) * 1000
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    if result != expected:
        raise AssertionError("Resolved the wrong target (IDs omitted)")
    cpu = ((after.ru_utime + after.ru_stime) -
           (before.ru_utime + before.ru_stime)) * 1000
    return elapsed, cpu


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True,
                        help="Baseline Spoon init.lua (e.g. the original checkout)")
    parser.add_argument("--candidate", type=Path,
                        default=ROOT / "Spoons/UnifiedCommandTab.spoon/init.lua")
    parser.add_argument("--samples", type=int, default=5)
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--cases", nargs="+", default=["first", "middle", "last", "moved_window_fallback", "closed_tab"],
                        choices=["first", "middle", "last", "moved_window_fallback", "closed_tab"])
    parser.add_argument("--max-candidate-ms", type=float,
                        help="Fail if any candidate case exceeds this median lookup time")
    args = parser.parse_args()
    if args.samples < 1 or args.timeout <= 0:
        parser.error("samples and timeout must be positive")

    # The outer guard avoids launching a stopped browser.
    info = applescript('''
if application id "company.thebrowser.dia" is not running then error "Dia must already be running"
tell application id "company.thebrowser.dia"
    if (count of windows) is 0 then error "Dia needs an open window"
    set w to front window
    set ids to id of tabs of w
    if (count of ids) is 0 then error "Dia needs an open tab"
    return (version as text) & linefeed & ((count of windows) as text) & linefeed & (id of w as text) & linefeed & ((count of ids) as text) & linefeed & (item 1 of ids as text) & linefeed & (item (((count of ids) + 1) div 2) of ids as text) & linefeed & (item -1 of ids as text)
end tell
''').splitlines()
    version, windows, window_id, tabs, first, middle, last = info
    report = {"dia_version": version, "windows": int(windows), "front_window_tabs": int(tabs),
              "samples": args.samples, "mode": "lookup-only", "results": {}}
    modules = {"baseline": args.baseline.resolve(), "candidate": args.candidate.resolve()}
    cases = {"first": (window_id, first), "middle": (window_id, middle),
             "last": (window_id, last),
             "moved_window_fallback": ("benchmark-missing-window", last),
             "closed_tab": (window_id, "benchmark-missing-tab")}
    for name in args.cases:
        recorded_window, tab_id = cases[name]
        probes = {label: lookup_only(capture_script(module, recorded_window, tab_id))
                  for label, module in modules.items()}
        results = {label: [] for label in probes}
        expected = "false" if name == "closed_tab" else tab_id
        for sample in range(args.samples):
            # Alternate order to reduce warm-cache/order bias.
            for label in (list(probes) if sample % 2 == 0 else list(reversed(probes))):
                results[label].append(measure(probes[label], expected, args.timeout))
        report["results"][name] = {}
        for label, values in results.items():
            wall = sorted(v[0] for v in values)
            report["results"][name][label] = {
                "median_ms": round(statistics.median(wall), 1),
                "p95_ms": round(wall[math.ceil(len(wall) * .95) - 1], 1),
                "child_cpu_median_ms": round(statistics.median(v[1] for v in values), 1),
            }
        print(name + ": " + json.dumps(report["results"][name]), flush=True)
    report["notes"] = [
        "Includes osascript startup and production lookup; excludes focus and key delivery.",
        "Fallback simulates a stale recorded window ID; no tabs were moved or closed.",
        "Child CPU measures osascript only, not Dia or Hammerspoon/background overhead.",
        "Keep the tab set stable during the run; no titles or IDs are reported.",
    ]
    print(json.dumps(report, indent=2))
    if args.max_candidate_ms is not None:
        assert all(result["candidate"]["median_ms"] <= args.max_candidate_ms
                   for result in report["results"].values()), "Candidate lookup exceeded the median budget"


if __name__ == "__main__":
    main()
