-- Opt-in real OS-event trial of the installed switcher. Runs asynchronously so
-- Hammerspoon can process event taps, polling tasks and canvas updates normally.
-- hs -t 30 -c 'dofile("/absolute/checkout/scripts/verify_live_cmd_tab.lua")("/absolute/report.json")'
-- Read report.json after completion. No test calls the switcher's private methods.
return function(reportPath)
    local spoonObject = assert(rawget(spoon or {}, "UnifiedCommandTab"), "Load the live Spoon first")
    assert(spoonObject:isEnabled(), "Live switcher must be enabled")
    assert(not hs.eventtap.isSecureInputEnabled(), "Secure input blocks the trial")
    local flags = hs.eventtap.checkKeyboardModifiers()
    assert(not (flags.cmd or flags.shift or flags.ctrl or flags.alt), "Release keyboard modifiers before testing")
    local originalApp = assert(hs.application.frontmostApplication())
    local originalWindow = hs.window.frontmostWindow()
    local originalMouse = hs.mouse.absolutePosition()
    local DIA = "company.thebrowser.dia"
    assert(hs.application.get(DIA), "Dia must already be running")
    local ok, windows = hs.osascript.applescript([[
tell application id "company.thebrowser.dia"
    set snapshot to {}
    repeat with w in windows
        set end of snapshot to {(id of w as text), (id of active tab of w as text), (id of tabs of w)}
    end repeat
    return snapshot
end tell]])
    assert(ok and #windows > 0, "Cannot snapshot Dia selections")

    -- Read-only observation of state: unlike invoking a callback, this cannot
    -- bypass the real macOS key delivery / event-tap path being exercised.
    local function locate(fn, wanted, visited)
        visited = visited or {}
        if visited[fn] then return end
        visited[fn] = true
        local children = {}
        for i = 1, 200 do
            local name, value = debug.getupvalue(fn, i)
            if not name then break end
            if name == wanted then return function() local _, v = debug.getupvalue(fn, i); return v end end
            if type(value) == "function" then children[#children + 1] = value end
        end
        for _, child in ipairs(children) do
            local getter = locate(child, wanted, visited)
            if getter then return getter end
        end
    end
    local state = {}
    for _, name in ipairs({"history", "lastObservedTarget", "cycle", "overlay", "eventTap"}) do
        state[name] = assert(locate(spoonObject.start, name) or locate(spoonObject.stop, name), "Cannot observe " .. name)
    end
    assert(not state.cycle(), "Finish the current switcher cycle first")

    local results, timers, stopped = {}, {}, false
    local now = hs.timer.absoluteTime
    local function quote(s) return '"' .. tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"' end
    local function current()
        local success, value = hs.osascript.applescript([[
tell application id "company.thebrowser.dia"
    return {(id of front window as text), (id of active tab of front window as text)}
end tell]])
        assert(success, "Cannot read actual Dia selection")
        return value
    end
    local function focus(windowID, tabID)
        local success, value = hs.osascript.applescript(string.format([[
tell application id "company.thebrowser.dia"
    set w to first window whose id is %s
    set t to first tab of w whose id is %s
    focus t
    return true
end tell]], quote(windowID), quote(tabID)))
        assert(success and value == true, "Could not focus the requested existing Dia tab")
    end
    local event = hs.eventtap.event
    local injectedFlags = {}
    local function key(name, down)
        if name == "cmd" or name == "shift" then injectedFlags[name] = down or nil end
        event.newKeyEvent(name, down):setFlags(injectedFlags):post()
    end
    local function tab()
        key("tab", true)
        key("tab", false)
    end
    local function hidden()
        local canvas = state.overlay()
        return not canvas or not canvas:isShowing()
    end

    local finish
    local function after(seconds, fn)
        local timer = hs.timer.doAfter(seconds, function()
            if stopped then return end
            local success, err = xpcall(fn, function(e) return tostring(e) end)
            if not success then finish(err) end
        end)
        timers[#timers + 1] = timer
    end
    local function waitFor(label, predicate, nextStep, seconds)
        local deadline = now() + (seconds or 12) * 1e9
        local function check()
            if predicate() then nextStep()
            elseif now() > deadline then error("Timed out: " .. label)
            else after(0.05, check) end
        end
        after(0.05, check)
    end

    finish = function(failure)
        if stopped then return end
        stopped = true
        for _, timer in ipairs(timers) do timer:stop() end
        -- Always release injected keys; allow the real release handler to finish
        -- before restoring selections, even on an assertion failure.
        key("tab", false); key("shift", false); key("cmd", false)
        hs.timer.doAfter(0.5, function()
            local restorationFailures = {}
            local function writeReport()
                local modifiers = hs.eventtap.checkKeyboardModifiers()
                local overlayHidden, cycleCleared = hidden(), state.cycle() == nil
                local tap = state.eventTap()
                local tapEnabled = tap and tap:isEnabled() or false
                local keysReleased = not modifiers.cmd and not modifiers.shift
                local report = {passed=not failure and #restorationFailures == 0
                        and overlayHidden and cycleCleared and keysReleased and tapEnabled,
                    failure=failure, cases=results, restored=#restorationFailures == 0,
                    restorationFailures=restorationFailures, overlayHidden=overlayHidden,
                    cycleCleared=cycleCleared, commandReleased=not modifiers.cmd,
                    shiftReleased=not modifiers.shift, eventTapEnabled=tapEnabled}
                assert(hs.json.write(report, reportPath, true, true), "Could not write trial report")
                print("Live Command-Tab trial: " .. (report.passed and "PASS" or "FAIL"))
            end
            local function settle(predicate, nextStep, label)
                local deadline = now() + 4e9
                local function check()
                    local success, matched = pcall(predicate)
                    if success and matched then nextStep()
                    elseif now() > deadline then
                        restorationFailures[#restorationFailures + 1] = label
                        nextStep()
                    else hs.timer.doAfter(0.1, check) end
                end
                hs.timer.doAfter(0.1, check)
            end
            local function restoreApp()
                pcall(function()
                    originalApp:activate()
                    if originalWindow then originalWindow:focus() end
                    hs.mouse.absolutePosition(originalMouse)
                end)
                settle(function()
                    local app, window = hs.application.frontmostApplication(), hs.window.frontmostWindow()
                    return app and app:pid() == originalApp:pid()
                        and (not originalWindow or (window and window:id() == originalWindow:id()))
                end, writeReport, "original application/window")
            end
            local function restoreWindow(i)
                if i == 0 then restoreApp(); return end
                local w = windows[i]
                if not pcall(focus, w[1], w[2]) then
                    restorationFailures[#restorationFailures + 1] = "Dia window " .. i
                    restoreWindow(i-1)
                    return
                end
                settle(function()
                    local selected = current()
                    return selected[1] == w[1] and selected[2] == w[2]
                end, function() restoreWindow(i-1) end, "Dia window " .. i)
            end
            restoreWindow(#windows)
        end)
    end

    local largest = windows[1]
    for _, w in ipairs(windows) do if #w[3] > #largest[3] then largest = w end end
    assert(#largest[3] >= 3, "Need three existing tabs")
    local targets = {largest[3][1], largest[3][math.ceil(#largest[3]/2)], largest[3][#largest[3]]}
    local function targetKey(id) return "browserTab:" .. DIA .. ":" .. id end

    local function seed(index, nextStep)
        if index > #targets then nextStep(); return end
        focus(largest[1], targets[index])
        waitFor("active-tab observation", function()
            local observed = state.lastObservedTarget()
            if not observed or observed.key ~= targetKey(targets[index]) then return false end
            local actual = current()
            return actual[1] == largest[1] and actual[2] == targets[index]
        end, function() seed(index + 1, nextStep) end, 20)
    end
    local cases = {
        {name="forward_tab_up_first", commandFirst=false},
        {name="forward_command_up_first", commandFirst=true},
        {name="repeated_forward_then_reverse", steps={1, -1}, commandFirst=false},
        {name="reverse_wrap_to_current", steps={-1, -1, 1}, commandFirst=false},
    }
    local runCase
    runCase = function(number)
        local spec = cases[number]
        if not spec then finish(); return end
        seed(1, function()
            local starting = current()
            assert(starting[2] == targets[3], "Seed did not leave the expected tab active")
            key("cmd", true)
            waitFor("synthetic Command delivery", function()
                return hs.eventtap.checkKeyboardModifiers().cmd
            end, function()
                key("tab", true)
                if not spec.commandFirst then key("tab", false) end
                waitFor("visible custom overlay", function()
                    return state.cycle() ~= nil and not hidden()
                end, function()
                    local c = state.cycle()
                    assert(c.selected.key == targetKey(targets[2]), "First Tab did not select previous target")
                    local rows = 0
                    for _, el in ipairs(state.overlay():canvasElements()) do
                        if el.id and tostring(el.id):match("^target:") then rows = rows + 1 end
                    end
                    assert(rows == math.min(12, #c.order), "Visible row count mismatch")
                    local index = 1
                    local function advance()
                        local direction = spec.steps and spec.steps[index]
                        if direction then
                            local before = state.cycle()
                            local expected = ((before.index - 1 + direction) % #before.order) + 1
                            if direction == -1 then key("shift", true) end
                            tab()
                            after(0.1, function()
                                assert(state.cycle() and state.cycle().index == expected, "Cycle direction/wrap mismatch")
                                local actual = current()
                                assert(actual[1] == starting[1] and actual[2] == starting[2],
                                    "A cycling step activated an intermediate tab")
                                if direction == -1 then key("shift", false) end
                                index = index + 1
                                advance()
                            end)
                        else
                            local still = current()
                            assert(still[1] == starting[1] and still[2] == starting[2], "Cycling activated an intermediate tab")
                            local expected = state.cycle().selected
                            assert(expected.kind == "browserTab" and expected.browser.appID == DIA,
                                "Unexpected non-Dia target in trial")
                            local released = now()
                            key("cmd", false)
                            waitFor("cycle and overlay cleanup", function() return state.cycle() == nil and hidden() end,
                                function()
                                    if spec.commandFirst then key("tab", false) end
                                    local checks, matchedWindow, matchedTab = 0, false, false
                                    local deadline = now() + 4e9
                                    local function verifyFocus()
                                        local actual = current()
                                        checks = checks + 1
                                        matchedWindow = actual[1] == expected.windowID
                                        matchedTab = actual[2] == expected.tabID
                                        if matchedWindow and matchedTab then
                                            results[#results + 1] = {case=spec.name, passed=true, rows=rows,
                                                releaseToVerifiedMs=(now()-released)/1e6, verificationReads=checks,
                                                noIntermediateActivation=true, overlayHidden=true}
                                            after(0.2, function() runCase(number + 1) end)
                                        elseif now() > deadline then
                                            error("Released Command did not focus highlighted tab after settling: window="
                                                .. tostring(matchedWindow) .. ", tab=" .. tostring(matchedTab))
                                        else
                                            after(0.1, verifyFocus)
                                        end
                                    end
                                    verifyFocus()
                                end)
                        end
                    end
                    advance()
                end)
            end, 2)
        end)
    end
    after(0, function() runCase(1) end)
    print("Live Command-Tab trial started; asynchronous report will be written to " .. reportPath)
end
