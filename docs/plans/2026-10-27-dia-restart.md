# Dia restart recovery implementation plan

> **Execution:** Use `executing-plans` to carry out this plan task by task.

**Goal:** Capture and select Dia tabs when login restores multiple processes with the same bundle ID.

**Architecture:** Keep the existing AppleScript path for a single Dia process. When multiple instances run, resolve the foreground or window-owning instance and use JavaScript for Automation (JXA) addressed by its current PID. Use the same routing for active-tab reads, full snapshots, presence snapshots, and selection; never persist a PID across restarts.

**Tech Stack:** Hammerspoon, Lua, macOS OSA (AppleScript and JXA), isolated Lua fixtures.

---

### Task 1: Reproduce duplicate-instance routing

**Files:** `tests/support/mock_hs.lua`, `tests/unified_cmd_tab_behavior_test.lua`

1. Extend the fixture to model multiple application instances and capture script languages.
2. Add a scenario with a window-owning Dia instance and a second windowless Dia instance.
3. Run `hs -c 'dofile("/Users/totah/.hammerspoon/tests/run.lua")'`. Expect failure because the generated script targets the bundle ID instead of the window owner's PID.

### Task 2: Route every Dia operation to the correct process

**Files:** `Spoons/UnifiedCommandTab.spoon/init.lua`

1. Resolve the current foreground or window-owning Dia instance when duplicate instances exist.
2. Generate PID-addressed JXA for active reads, full and presence snapshots, and stable-ID selection. Preserve existing record formats and the single-instance AppleScript path.
3. Cover moved tabs, missing tabs, background reads, process replacement, and normal single-instance routing.
4. Run the full isolated suite. Expect all scenarios to pass.

### Task 3: Verify installed recovery

**Files:** `scripts/verify_dia_capture.lua`, `docs/unified-command-tab-verification.md`

1. Add a read-only, bounded live check that asserts Dia capture without exposing titles or URLs.
2. Reload Hammerspoon and run the live check. Expect a captured current Dia tab with both original processes still running.
3. Exercise generated full and presence scripts against the real window-owning process; verify counts only.
4. Record the root cause, regression command, and limits. Do not reboot the computer or close browser processes during verification.
