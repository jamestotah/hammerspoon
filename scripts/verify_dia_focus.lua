-- Opt-in native smoke test: focuses existing Dia tabs, then restores selections.
-- Does not install/start a real switcher, move tabs, or open/close windows/tabs.
-- hs -t 90 -c 'dofile("/absolute/checkout/scripts/verify_dia_focus.lua")()'
local source = debug.getinfo(1, "S").source:sub(2)
local root = assert(source:match("^(.*)/scripts/[^/]+$"), "use an absolute script path")
local factory = dofile(root .. "/tests/support/mock_hs.lua")
local modulePath = root .. "/Spoons/UnifiedCommandTab.spoon/init.lua"
local DIA = "company.thebrowser.dia"

local function quote(value)
    return '"' .. tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

return function()
    assert(hs.application.get(DIA), "Dia must already be running")
    local originalApp = assert(hs.application.frontmostApplication(), "No frontmost application")
    local originalWindow = hs.window.frontmostWindow()
    local windowsOK, windows = hs.osascript.applescript([[
tell application id "company.thebrowser.dia"
    set snapshot to {}
    repeat with w in windows
        set end of snapshot to {(id of w as text), (id of active tab of w as text), (id of tabs of w)}
    end repeat
    return snapshot
end tell]])
    assert(windowsOK and type(windows) == "table" and #windows > 0, "Cannot capture Dia windows")

    local function selected()
        local ok, state = hs.osascript.applescript([[
tell application id "company.thebrowser.dia"
    return {(id of front window as text), (id of active tab of front window as text)}
end tell]])
        assert(ok and type(state) == "table", "Cannot read selected Dia tab")
        return state
    end

    local function capture(windowID, tabID)
        local f = factory(modulePath)
        f:observeBrowser(DIA, windowID, tabID, "Target")
        f:observeBrowser(DIA, "fixture-window", "fixture-other-tab", "Other")
        assert(f:key("keyDown", {cmd=true}))
        f:flush()
        f:click("browserTab:" .. DIA .. ":" .. tabID)
        assert(#f.selectionScripts == 1)
        local script = f.selectionScripts[1]
        f:stop()
        return script
    end

    local results = {}
    local function check(name, recordedWindowID, tabID, expectedWindowID, succeeds)
        local script = capture(recordedWindowID, tabID)
        local before = selected()
        local start = hs.timer.absoluteTime()
        local ok, result = hs.osascript.applescript(script)
        local returned = hs.timer.absoluteTime()
        assert(ok, name .. ": selection AppleScript failed")
        assert(result == succeeds, name .. ": unexpected selection result")
        local after = selected()
        local verified = hs.timer.absoluteTime()
        if succeeds then
            assert(after[1] == expectedWindowID and after[2] == tabID,
                name .. ": actual selection mismatch (window=" .. tostring(after[1] == expectedWindowID)
                .. ", tab=" .. tostring(after[2] == tabID) .. ")")
            local frontmost = hs.application.frontmostApplication()
            assert(frontmost and frontmost:bundleID() == DIA, name .. ": Dia did not become frontmost")
        else
            assert(after[1] == before[1] and after[2] == before[2], name .. ": missing target changed selection")
        end
        results[#results + 1] = {case=name, commandMs=(returned-start)/1e6,
            commandAndVerificationMs=(verified-start)/1e6, passed=true}
    end

    local ok, failure = xpcall(function()
        local largest = windows[1]
        for _, window in ipairs(windows) do
            if #window[3] > #largest[3] then largest = window end
        end
        assert(#largest[3] >= 2, "Need at least two existing tabs")
        check("large_window_first_tab", largest[1], largest[3][1], largest[1], true)
        check("large_window_last_tab", largest[1], largest[3][#largest[3]], largest[1], true)

        if #windows >= 2 then
            local other = windows[1] == largest and windows[2] or windows[1]
            check("other_window_selected_tab", other[1], other[2], other[1], true)
            -- Use a tab unique to the destination window: this is the state a
            -- moved tab leaves behind, without moving any user tabs ourselves.
            local inOther = {}
            for _, id in ipairs(other[3]) do inOther[id] = true end
            local unique
            for _, id in ipairs(largest[3]) do if not inOther[id] then unique = id; break end end
            assert(unique, "Need a tab unique to the destination window for live-window fallback")
            check("wrong_existing_window_fallback", other[1], unique, largest[1], true)
        end
        check("missing_window_fallback", "native-test-missing-window", largest[2], largest[1], true)
        check("missing_tab_no_substitute", largest[1], "native-test-missing-tab", nil, false)
    end, function(err) return tostring(err) end)

    -- Cleanup runs even on test failure. Restore back-to-front to preserve the
    -- original front window, and use the known baseline indexed-ID scan rather
    -- than relying on the new whose-ID selector to recover from its own failure.
    local restorationFailures = {}
    for i = #windows, 1, -1 do
        local window = windows[i]
        local restored, value = hs.osascript.applescript(string.format([[
tell application id "company.thebrowser.dia"
    set w to first window whose id is %s
    repeat with t in tabs of w
        if (id of t as text) is %s then
            focus t
            return (id of active tab of w as text) is %s
        end if
    end repeat
    return false
end tell]], quote(window[1]), quote(window[2]), quote(window[2])))
        if not restored or value ~= true then restorationFailures[#restorationFailures + 1] = "Dia window " .. i end
    end
    local appRestored = pcall(function()
        originalApp:activate()
        if originalWindow then originalWindow:focus() end
    end)
    if not appRestored then restorationFailures[#restorationFailures + 1] = "original application/window" end
    local currentApp = hs.application.frontmostApplication()
    if not currentApp or currentApp:pid() ~= originalApp:pid() then
        restorationFailures[#restorationFailures + 1] = "original frontmost application"
    end
    local currentWindow = hs.window.frontmostWindow()
    local originalWindowRestored = not originalWindow
        or (currentWindow and currentWindow:id() == originalWindow:id()) or false
    if not originalWindowRestored then
        restorationFailures[#restorationFailures + 1] = "original frontmost window"
    end
    print(hs.json.encode({nativeFocusResults=results, windowCount=#windows, testFailure=not ok and failure or nil,
        restored=#restorationFailures == 0, originalWindowRestored=originalWindowRestored,
        restorationFailures=restorationFailures}))
    assert(#restorationFailures == 0, "Restoration incomplete: " .. table.concat(restorationFailures, ", "))
    assert(ok, failure)
    print("Dia native focus: PASS (production scripts; selections and original application restored)")
end
