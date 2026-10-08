-- Independent public-path scenarios. No debug upvalues or production test seams.
local source = debug.getinfo(1, "S").source:sub(2)
local directory = source:match("^(.*)/[^/]+$")
local factory = dofile(directory .. "/support/mock_hs.lua")
local modulePath = directory .. "/../Spoons/UnifiedCommandTab.spoon/init.lua"
local CHROME, DIA = "com.google.Chrome", "company.thebrowser.dia"
local passed, activeFixture = 0

local function eq(actual, expected, message)
    assert(actual == expected, (message or "values differ")
        .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function fixture(options)
    activeFixture = factory(modulePath, options)
    return activeFixture
end

local function test(name, body)
    local ok, err = xpcall(body, debug.traceback)
    if activeFixture then activeFixture:stop(); activeFixture = nil end
    if not ok then error(name .. ":\n" .. err, 0) end
    passed = passed + 1
    print("  PASS " .. name)
end

local function windowKey(id, appID) return "window:" .. (appID or "test.editor") .. ":" .. id end
local function tabKey(appID, id) return "browserTab:" .. appID .. ":" .. id end

local function windowHistory(count, options)
    local f = fixture(options)
    local app = f:newApp("test.editor", "Editor")
    for i = 1, count do f:observeWindow(f:newWindow(app, i, "Document " .. i)) end
    return f, app
end

local function keys(f)
    local result = {}
    for _, row in ipairs(f:rows()) do table.insert(result, row.key) end
    return table.concat(result, ",")
end

local function rowsEqual(f, expected)
    eq(keys(f), table.concat(expected, ","), "exact visible history order")
end

local function press(f, reverse)
    eq(f:key("keyDown", { cmd = true, shift = reverse or nil }), true, "Command-Tab interception")
    f:flush()
end

local function release(f)
    eq(f:key("flagsChanged", {}), false, "Command release passes through")
end

local function assertHiddenBeforeFocus(f, kind)
    local count = #f.operations
    eq(f.operations[count].kind, kind)
    eq(f.operations[count - 1].kind, "hide", "overlay must hide before activation")
    assert(not f:canvas().visible, "overlay remained visible during activation")
end

test("scheduler cancels callbacks and separates next-turn work", function()
    local f, calls = fixture(), {}
    local cancelled = f.hs.timer.doAfter(0, function() error("cancelled timer ran") end)
    cancelled:stop()
    f.hs.timer.doAfter(0, function()
        table.insert(calls, "first")
        f.hs.timer.doAfter(0, function() table.insert(calls, "next") end)
    end)
    f.hs.timer.doAfter(0.1, function() table.insert(calls, "later") end)
    f:flush()
    eq(table.concat(calls, ","), "first")
    f:flush()
    eq(table.concat(calls, ","), "first,next")
    f:advance(0.1)
    eq(table.concat(calls, ","), "first,next,later")
end)

test("forward, reverse and wrap change highlight without activation", function()
    local f = windowHistory(3)
    press(f)
    rowsEqual(f, { windowKey(3), windowKey(2), windowKey(1) })
    eq(f:selectedKey(), windowKey(2))
    press(f)
    eq(f:selectedKey(), windowKey(1))
    press(f)
    eq(f:selectedKey(), windowKey(3), "forward wrap")
    press(f, true)
    eq(f:selectedKey(), windowKey(1), "reverse wrap")
    press(f, true)
    eq(f:selectedKey(), windowKey(2))
    eq(f.counts.focus + f.counts.activate + #f.selectionScripts, 0)
    release(f)
    eq(f.focuses[1], 2)
    assertHiddenBeforeFocus(f, "focus")
    eq(f.counts.icon, 1, "one cached icon per app across redraws")

    f:observeWindow(f.windows[2])
    press(f, true)
    eq(f:selectedKey(), windowKey(1), "reverse start chooses final MRU target")
    release(f)
    eq(f.focuses[2], 1)
end)

test("unsupported modifiers and non-Tab keys pass through", function()
    local f = windowHistory(2)
    for _, flags in ipairs({ {}, { shift = true }, { cmd = true, alt = true },
        { cmd = true, ctrl = true }, { cmd = true, fn = true } }) do
        eq(f:key("keyDown", flags), false)
    end
    eq(f:key("keyDown", { cmd = true }, 0), false)
    eq(f:key("keyUp", {}), false)
    eq(f:key("flagsChanged", { cmd = true }), false)
    eq(f.counts.render + f.counts.taskStarted + f.counts.focus, 0)
end)

test("focus notifications during a cycle do not rewrite its MRU snapshot", function()
    local f, app = windowHistory(3)
    press(f)
    f:observeWindow(f:newWindow(app, 4, "Transient focus"))
    f:flush()
    rowsEqual(f, { windowKey(3), windowKey(2), windowKey(1) })
    eq(f:selectedKey(), windowKey(2))
    press(f)
    eq(f:selectedKey(), windowKey(1))
    release(f)
    eq(f.focuses[1], 1)
end)

test("Tab-first release keeps cycle open until Command release", function()
    local f = windowHistory(2)
    press(f)
    eq(f:key("keyUp", { cmd = true }), true)
    eq(f.counts.focus, 0)
    assert(f:canvas().visible)
    release(f)
    eq(f.counts.focus, 1)
    eq(f:key("keyUp", {}), false, "Tab up suppression consumed only once")
    release(f)
    eq(f.counts.focus, 1)
end)

test("Command-first release commits once and suppresses trailing Tab up", function()
    local f = windowHistory(2)
    press(f)
    release(f)
    eq(f.counts.focus, 1)
    eq(f:key("keyUp", {}), true)
    eq(f:key("keyUp", {}), false)
    release(f)
    eq(f.counts.focus, 1)
end)

test("redraw bursts coalesce and missing icons are cached", function()
    local f = windowHistory(3, { noIcons = true })
    for _ = 1, 8 do eq(f:key("keyDown", { cmd = true }), true) end
    eq(f.counts.render, 0, "key callback must not render")
    eq(f.counts.icon, 0, "key callback must not load icons")
    eq(f.counts.focus, 0)
    f:flush()
    eq(f.counts.render, 1, "burst redraw count")
    eq(f:selectedKey(), windowKey(1))
    for _ = 1, 4 do f:key("keyDown", { cmd = true }) end
    f:flush()
    eq(f.counts.render, 2)
    eq(f.counts.show, 1, "visible canvas need not be shown again")
    eq(f.counts.icon, 1, "failed icon lookup should be cached")
    release(f)
end)

test("quick release cancels all deferred canvas work", function()
    local f = windowHistory(2)
    eq(f:key("keyDown", { cmd = true }), true)
    release(f)
    eq(f.focuses[1], 1)
    f:flush()
    eq(f.counts.render + f.counts.show + f.counts.icon, 0)
    eq(#f.canvases, 0, "quick release should not construct a canvas")
    eq(f:key("keyUp", {}), true)
end)

test("watchdog handles a missing Command release on deterministic time", function()
    local f = windowHistory(2)
    press(f)
    f:advance(0.25)
    eq(f.counts.focus, 0)
    f.modifiers = {}
    f:advance(0.25)
    eq(f.counts.focus, 1)
    assertHiddenBeforeFocus(f, "focus")
    f:advance(0.25)
    eq(f.counts.focus, 1)
end)

test("full metadata preserves MRU and exact keys, updates titles and moved IDs", function()
    local f = fixture()
    f:observeBrowser(CHROME, "old-a", "a", "Alpha", 2)
    f:observeBrowser(CHROME, "old-b", "b", "Bravo", 3)
    f:observeBrowser(CHROME, "old-c", "c", "Closed", 4)
    f:observeBrowser(DIA, "dia-w", "d", "Dia stays")
    local app = f:newApp("test.editor", "Editor")
    f:observeWindow(f:newWindow(app, 1, "Native stays"))
    f.frontmostApp, f.frontmostWindow = f.apps[CHROME], nil
    press(f)
    eq(f:selectedKey(), tabKey(DIA, "d"))
    local renderCount = f.counts.render
    -- Deliberately change snapshot order and include a never-observed tab.
    f:complete(f:task("metadata", CHROME), "moved-a|a|9|Alpha refreshed\nnew|unvisited|1|Never visited\nmoved-b|b|7|")
    eq(f.counts.render, renderCount, "metadata callback must defer drawing")
    f:complete(f:task("metadata", DIA), "dia-new|d|Dia refreshed")
    f:flush()
    eq(f.counts.render, renderCount + 1, "metadata burst coalesces")
    rowsEqual(f, { windowKey(1), tabKey(DIA, "d"), tabKey(CHROME, "b"), tabKey(CHROME, "a") })
    eq(f:selectedKey(), tabKey(DIA, "d"), "selected stable identity survives refresh")
    local rows = f:rows()
    eq(rows[2].title, "Dia refreshed")
    eq(rows[3].title, "Bravo", "empty snapshot title preserves observed title")
    eq(rows[4].title, "Alpha refreshed")
    f:click(tabKey(CHROME, "b"))
    assertHiddenBeforeFocus(f, "select")
    local script = f.selectionScripts[1]
    assert(script:find('"moved-b"', 1, true), "empty title must still update window ID")
    assert(script:find('"b"', 1, true), "selection lost stable tab ID")
    -- Current behavior: empty titles do not update Chrome's cached tab index.
    assert(script:find("set wantedTabIndex to 3", 1, true), "empty title changed cached Chrome index")
    f.frontmostApp = nil
    press(f)
    rowsEqual(f, { tabKey(CHROME, "b"), windowKey(1), tabKey(DIA, "d"), tabKey(CHROME, "a") })
    f:click(tabKey(CHROME, "a"))
    script = f.selectionScripts[2]
    assert(script:find('"moved-a"', 1, true))
    assert(script:find("set wantedTabIndex to 9", 1, true), "nonempty title refresh lost Chrome index")
end)

test("repeated snapshot rows preserve last window and last nonempty title/index", function()
    local f = fixture()
    f:observeBrowser(CHROME, "old-a", "a", "Alpha", 2)
    f:observeBrowser(CHROME, "old-b", "b", "Bravo", 3)
    press(f)
    f:complete(f:task("metadata", CHROME),
        "moved-a|a|9|Updated\nlast-a|a|7|\nw-b|b|3|Bravo")
    f:flush()
    rowsEqual(f, { tabKey(CHROME, "b"), tabKey(CHROME, "a") })
    eq(f:rows()[2].title, "Updated")
    eq(f:selectedKey(), tabKey(CHROME, "a"))
    release(f)
    local script = f.selectionScripts[1]
    assert(script:find('"last-a"', 1, true))
    assert(script:find("set wantedTabIndex to 9", 1, true))
    f.frontmostApp = nil
    press(f)
    rowsEqual(f, { tabKey(CHROME, "a"), tabKey(CHROME, "b") })
    eq(f:rows()[1].title, "Updated", "history must receive the same metadata as cycle")
end)

test("retained current-tab metadata survives next-cycle reinsertion", function()
    local f = fixture()
    f:observeBrowser(CHROME, "old-a", "a", "Alpha", 2)
    f:observeBrowser(CHROME, "old-b", "b", "Bravo", 3)
    press(f)
    f:complete(f:task("metadata", CHROME), "old-a|a|2|Alpha\nmoved-b|b|8|Updated Bravo")
    f:flush()
    -- Cancel the pointer selection so lastObservedTarget remains the current B.
    f:mouse("mouseDown", tabKey(CHROME, "a"))
    f:mouse("mouseUp", tabKey(CHROME, "b"))
    press(f)
    rowsEqual(f, { tabKey(CHROME, "b"), tabKey(CHROME, "a") })
    eq(f:rows()[1].title, "Updated Bravo")
    f:click(tabKey(CHROME, "b"))
    local script = f.selectionScripts[1]
    assert(script:find('"moved-b"', 1, true), "current-target reinsertion restored stale window")
    assert(script:find("set wantedTabIndex to 8", 1, true), "current-target reinsertion restored stale index")
end)

test("empty snapshot during cycling leaves nothing to activate", function()
    local f = fixture()
    f:observeBrowser(CHROME, "w", "a", "Alpha")
    f:observeBrowser(CHROME, "w", "b", "Bravo")
    press(f)
    f:complete(f:task("metadata", CHROME), "")
    f:flush()
    rowsEqual(f, {})
    eq(f:selectedKey(), nil)
    eq(f:key("keyDown", { cmd = true }), true)
    release(f)
    eq(#f.selectionScripts, 0)
    assert(not f:canvas().visible)
    eq(f:key("keyDown", { cmd = true }), false, "empty history should use native fallback")
end)

test("same-tab observation refreshes title without duplicates", function()
    local f = fixture()
    f:observeBrowser(CHROME, "w", "a", "Alpha")
    f:observeBrowser(CHROME, "w", "b", "Bravo")
    f:observeBrowser(CHROME, "w", "b", "Renamed")
    f:observeBrowser(CHROME, "w", "b", "")
    press(f)
    rowsEqual(f, { tabKey(CHROME, "b"), tabKey(CHROME, "a") })
    eq(f:rows()[1].title, "Renamed")
    release(f)
end)

test("Dia presence refresh prunes only absent keys and keeps titles", function()
    local f = fixture()
    f:observeBrowser(CHROME, "cw", "a", "Chrome")
    f:observeBrowser(DIA, "dw", "a", "Dia A")
    f:observeBrowser(DIA, "dw", "b", "Dia B")
    f:notifyDia("AXSelectedChildrenChanged")
    f:complete(f:task("presence", DIA), "moved|a|\nnew|unvisited|")
    press(f)
    rowsEqual(f, { tabKey(DIA, "a"), tabKey(CHROME, "a") })
    eq(f:rows()[1].title, "Dia A")
    f:click(tabKey(DIA, "a"))
    local script = f.selectionScripts[1]
    assert(script:find('"moved"', 1, true), "Dia moved-window metadata not passed to selection")
    assert(script:find('"a"', 1, true))
end)

test("history retains exactly the most recent 100 identities", function()
    local f = windowHistory(103)
    press(f)
    local selected = { f:selectedKey() }
    for _ = 2, 100 do press(f); table.insert(selected, f:selectedKey()) end
    local expected = {}
    for id = 102, 4, -1 do table.insert(expected, windowKey(id)) end
    table.insert(expected, windowKey(103))
    eq(table.concat(selected, ","), table.concat(expected, ","), "all retained MRU keys through public cycling")
    press(f)
    eq(f:selectedKey(), windowKey(102), "wrap at 100 entries")
    eq(f.counts.focus, 0)
    release(f)
end)

test("recycled window ownership is checked again at commit", function()
    local f = windowHistory(2)
    press(f)
    local foreign = f:newApp("test.foreign", "Foreign")
    f:newWindow(foreign, 1, "Recycled")
    release(f)
    eq(f.counts.focus, 0, "must not focus the new owner of a recycled ID")
    assert(not f:canvas().visible)
end)

test("bundleless windows use application name identity", function()
    local f = windowHistory(1)
    local app = f:newApp(nil, "Legacy")
    f:observeWindow(f:newWindow(app, 9, "Legacy document"))
    press(f)
    rowsEqual(f, { windowKey(9, "Legacy"), windowKey(1) })
    f:click(windowKey(9, "Legacy"))
    eq(f.focuses[1], 9)
    assertHiddenBeforeFocus(f, "focus")
end)

test("destroyed windows and terminated apps leave no history substitutes", function()
    local f, app = windowHistory(3)
    f:windowEvent("destroyed", f.windows[1])
    f.windows[1] = nil
    press(f)
    rowsEqual(f, { windowKey(3), windowKey(2) })
    release(f)
    f:appEvent("terminated", app)
    app.running = false
    f.frontmostApp, f.frontmostWindow = nil, nil
    eq(f:key("keyDown", { cmd = true }), false)
end)

test("Spokenly window and application observations share one identity", function()
    local f = windowHistory(1)
    local spokenly = f:newApp("app.spokenly", "Spokenly")
    f:appEvent("launched", spokenly)
    eq(f:key("keyDown", { cmd = true }), false, "windowless Spokenly must not enter history")
    local window = f:newWindow(spokenly, 8, "Temporary Spokenly window")
    f:appEvent("activated", spokenly)
    f:observeWindow(window)
    f:appEvent("activated", spokenly)
    press(f)
    rowsEqual(f, { "application:app.spokenly", windowKey(1) })
    f:click("application:app.spokenly")
    eq(f.activations[1], "app.spokenly")
    eq(f.counts.focus, 0, "canonical Spokenly target activates the app")
    assertHiddenBeforeFocus(f, "activate")
    spokenly.windows = {}
    f:windowEvent("hidden", window)
    f:observeWindow(f.windows[1])
    eq(f:key("keyDown", { cmd = true }), false, "Spokenly should disappear when its UI closes")
end)

test("persisted disable and menu toggle retain their current semantics", function()
    local f = windowHistory(2, { enabled = false })
    eq(f.switcher:isEnabled(), false)
    eq(f:key("keyDown", { cmd = true }), false)
    f:advance(2)
    eq(f.counts.taskStarted + f.counts.render + f.counts.focus, 0)
    local refreshes = 0
    f.switcher:setMenuRefresh(function() refreshes = refreshes + 1 end)
    local menu = f.switcher:addMenuItems({})
    eq(menu[2].checked, false)
    f:toggle()
    eq(f.switcher:isEnabled(), true)
    eq(f.settings["unifiedCmdTab.enabled"], true)
    press(f)
    f:toggle()
    eq(f.switcher:isEnabled(), false)
    eq(f.focuses[1], 1, "disabling an active cycle commits the highlighted target")
    assertHiddenBeforeFocus(f, "focus")
    eq(#f.settingsWrites, 2)
    eq(f.settingsWrites[2].value, false)
    eq(refreshes, 2)
    eq(#f.alerts, 2)
    f:stop()
    f.switcher:start()
    eq(f.switcher:isEnabled(), false, "restart reads persisted setting")
end)

test("start is idempotent and stop cancels timers, tasks and subscriptions", function()
    local f = fixture()
    f:observeBrowser(CHROME, "cw", "a", "Chrome")
    f:observeBrowser(DIA, "dw", "d", "Dia")
    f.frontmostApp = f.apps[CHROME]
    f:pollBrowser() -- Leave the active read in flight as well as metadata below.
    press(f)
    f:notifyDia("AXWindowCreated") -- Pending observer rebind timer.
    f:key("keyDown", { cmd = true }) -- Pending redraw timer.
    local timers, tasks, observers = #f.timers, #f.tasks, #f.observers
    eq(f.switcher:start(), f.switcher)
    eq(#f.taps, 1)
    eq(#f.filters, 1)
    eq(#f.watchers, 1)
    eq(#f.timers, timers)
    eq(#f.tasks, tasks)
    eq(#f.observers, observers)
    f:stop()
    for _, timer in ipairs(f.timers) do assert(timer.stopped, "timer survived stop") end
    for _, task in ipairs(f:pending()) do error("task survived stop: " .. task.kind) end
    for _, observer in ipairs(f.observers) do assert(not observer.running) end
    eq(next(f.filters[1].callbacks), nil)
    assert(not f.watchers[1].running and not f.taps[1].running)
    assert(not f:canvas().visible)
    eq(f.counts.taskTerminated, 2)
    local renders, selections = f.counts.render, #f.selectionScripts
    f:advance(3)
    eq(f.counts.render, renders)
    eq(#f.selectionScripts, selections)
    eq(#f.tasks, tasks)
    f:stop()
    eq(f.counts.taskTerminated, 2, "repeated stop does not terminate twice")
end)

test("late full metadata after stop cannot mutate history or start queued Dia reads", function()
    local f = fixture()
    f:observeBrowser(CHROME, "cw", "a", "Chrome")
    f:observeBrowser(DIA, "dw", "d", "Dia")
    f.frontmostApp = f.apps[CHROME]
    press(f)
    local pending = f:task("metadata", CHROME)
    f:notifyDia("AXSelectedChildrenChanged")
    eq(#f:pending("presence", DIA), 0, "Dia refresh should queue behind Chrome")
    release(f)
    f:stop()
    assert(pending.terminated)
    local tasks, renders = f.counts.taskStarted, f.counts.render
    f:deliverLate(pending, "") -- Would delete Chrome if the callback were accepted.
    f:flush()
    eq(f.counts.taskStarted, tasks, "late Chrome completion continued the browser chain")
    eq(f.counts.render, renders)
    eq(f.counts.lateDeliveries, 1)
    f.switcher:start()
    f.frontmostApp = nil
    press(f)
    rowsEqual(f, { tabKey(CHROME, "a"), tabKey(DIA, "d") })
    eq(#f:pending("presence", DIA), 0, "stop must also clear queued presence reads")
end)

print("Unified Command-Tab behavior: PASS (" .. passed .. " scenarios)")
