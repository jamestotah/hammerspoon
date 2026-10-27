-- Read-only live capture check. Does not change focus, tabs, history or settings.
-- hs -c 'dofile("/absolute/checkout/scripts/verify_dia_capture.lua")("/absolute/report.json")'
-- Wait for the JSON report; the check runs on Hammerspoon's event loop.
return function(reportPath)
    local switcher = assert(spoon.UnifiedCommandTab, "Load the live Spoon first")
    assert(switcher:isEnabled(), "Enable Unified Command-Tab first")
    local app = assert(hs.application.frontmostApplication())
    assert(app:bundleID() == "company.thebrowser.dia", "Leave Dia frontmost during this check")

    local function locate(fn, wanted, seen)
        seen = seen or {}
        if seen[fn] then return end
        seen[fn] = true
        local children = {}
        for i = 1, 200 do
            local name, value = debug.getupvalue(fn, i)
            if not name then break end
            if name == wanted then
                return function() local _, current = debug.getupvalue(fn, i); return current end
            end
            if type(value) == "function" then children[#children + 1] = value end
        end
        for _, child in ipairs(children) do
            local getter = locate(child, wanted, seen)
            if getter then return getter end
        end
    end

    local history = assert(locate(switcher.start, "history"))
    local lastObserved = assert(locate(switcher.start, "lastObservedTarget"))
    local started = hs.timer.secondsSinceEpoch()
    local deadline = started + 15
    local function check()
        local count = 0
        for _, target in ipairs(history()) do
            if target.kind == "browserTab" and target.browser.appID == "company.thebrowser.dia" then
                count = count + 1
            end
        end
        local current, observed = hs.application.frontmostApplication(), lastObserved()
        local frontmostUnchanged = current and current:pid() == app:pid()
        local captured = count > 0 and observed and observed.kind == "browserTab"
            and observed.browser.appID == "company.thebrowser.dia"
        if captured or not frontmostUnchanged or hs.timer.secondsSinceEpoch() >= deadline then
            local passed = captured and frontmostUnchanged or false
            assert(hs.json.write({passed = passed, diaHistoryEntries = count,
                diaInstances = #hs.application.applicationsForBundleID("company.thebrowser.dia"),
                frontmostUnchanged = frontmostUnchanged or false,
                elapsedSeconds = hs.timer.secondsSinceEpoch() - started}, reportPath, true, true))
            print("Dia live capture: " .. (passed and "PASS" or "FAIL"))
        else
            hs.timer.doAfter(0.25, check)
        end
    end
    hs.timer.doAfter(0, check)
    print("Dia live capture check started; report: " .. reportPath)
end
