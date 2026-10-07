-- Run with: hs -c 'dofile(".../tests/unified_cmd_tab_test.lua")'
-- Exercise browser-history cleanup, stable row selection, stale window IDs,
-- missed Command-release recovery, and activation-error cleanup via public paths.
-- Value: protects stable click identity and clean cycle recovery; fails_when=rows resolve by index or finish leaves stale cycle state; why_new=prior test missed reordered and mismatched mouse release paths; seam=none
local realHS = hs
local now = 0
local tasks = {}
local browserPoll
local keyHandler
local cycleWatchdog
local applicationWatcherCallback
local windowFocusedCallback
local cycleWatchdogTimer
local axObservers = {}
local deferredCallbacks = {}
local selectionScripts = {}
local canvasInstances = {}
local commandDown = false
local selectionShouldThrow = false
local windowLookup = {}
local foreignWindowFocusCount = 0
local legacyWindowFocusCount = 0
local activeTabID = "tab-a"
local activeWindowID = "window-1"
local chromeRunning = true
local diaRunning = false
local testSourcePath = debug.getinfo(1, "S").source:sub(2)

local chrome = { bundleID = function() return "com.google.Chrome" end }
local function axNode(role, attributes, children)
    local node = { role = role, attributes = attributes or {}, children = children or {} }
    function node:attributeValue(name)
        if name == "AXRole" then return self.role end
        if name == "AXChildren" then return self.children end
        return self.attributes[name]
    end
    return node
end
local diaTab = axNode("AXUnknown", { AXIdentifier = "tab" })
local diaTabList = axNode("AXList", {}, { diaTab })
local diaWindowAX = axNode("AXWindow", {}, { diaTabList })
local diaApplicationAX = axNode("AXApplication")
local dia = {
    bundleID = function() return "company.thebrowser.dia" end,
    pid = function() return 4321 end,
    allWindows = function() return { {} } end,
}
local finder = {
    bundleID = function() return "com.apple.finder" end,
    name = function() return "Finder" end,
}
local unrelatedApp = {
    bundleID = function() return "com.example.unrelated" end,
    name = function() return "Unrelated" end,
}
local legacyApp = {
    bundleID = function() return nil end,
    name = function() return "Legacy App" end,
}
local recycledWindow = {
    application = function() return unrelatedApp end,
    focus = function() foreignWindowFocusCount = foreignWindowFocusCount + 1 end,
}
local legacyWindow = {
    application = function() return legacyApp end,
    focus = function() legacyWindowFocusCount = legacyWindowFocusCount + 1 end,
}
local frontmostApp = chrome
local mockHS = {
    logger = { new = function() return {} end },
    settings = { get = function() return nil end },
    application = {
        frontmostApplication = function() return frontmostApp end,
        get = function(id)
            if id == "com.google.Chrome" and chromeRunning then return chrome end
            if (id == "company.thebrowser.dia" or id == "Dia") and diaRunning then return dia end
            return nil
        end,
        watcher = {
            activated = "activated", launched = "launched", terminated = "terminated",
            new = function(callback)
                applicationWatcherCallback = callback
                return { start = function() end, stop = function() end }
            end,
        },
    },
    window = {
        filter = {
            windowFocused = "focused", windowDestroyed = "destroyed", windowNotVisible = "hidden",
            new = function()
                return {
                    subscribe = function(_, event, callback)
                        if event == "focused" then windowFocusedCallback = callback end
                    end,
                    unsubscribeAll = function() end,
                }
            end,
        },
        frontmostWindow = function() return nil end,
        get = function(id) return windowLookup[id] end,
    },
    timer = {
        secondsSinceEpoch = function() return now end,
        doEvery = function(interval, callback)
            local timer = { callback = callback, stopped = false }
            function timer:stop() self.stopped = true end
            if interval == 0.25 then
                cycleWatchdog = callback
                cycleWatchdogTimer = timer
            else
                browserPoll = callback
            end
            return timer
        end,
        doAfter = function(_, callback)
            table.insert(deferredCallbacks, callback)
            return { stop = function() end }
        end,
    },
    task = {
        new = function(_, callback, args)
            local task = { script = args[2], callback = callback }
            function task:start() tasks[#tasks + 1] = self end
            function task:terminate() self.terminated = true end
            return task
        end,
    },
    axuielement = {
        windowElement = function() return diaWindowAX end,
        applicationElement = function() return diaApplicationAX end,
        observer = {
            new = function(pid)
                local observer = { pid = pid, watchers = {} }
                function observer:callback(callback) self.callbackFn = callback; return self end
                function observer:addWatcher(element, notification)
                    table.insert(self.watchers, { element = element, notification = notification })
                    return self
                end
                function observer:start() self.running = true; return self end
                function observer:stop() self.running = false; return self end
                function observer:fire(element, notification)
                    for _, watcher in ipairs(self.watchers) do
                        if watcher.element == element and watcher.notification == notification then
                            self.callbackFn(self, element, notification, {})
                        end
                    end
                end
                table.insert(axObservers, observer)
                return observer
            end,
        },
    },
    osascript = { applescript = function(script)
        table.insert(selectionScripts, script)
        if selectionShouldThrow then error("simulated target activation failure") end
        return true, true
    end },
    eventtap = {
        event = { types = { keyDown = 1, keyUp = 2, flagsChanged = 3 } },
        new = function(_, callback) keyHandler = callback; return { start = function() end, stop = function() end } end,
        checkKeyboardModifiers = function() return { cmd = commandDown } end,
    },
    keycodes = { map = { tab = 48 } },
    screen = { mainScreen = function() return { frame = function() return { x = 0, y = 0, w = 1000, h = 800 } end } end },
    canvas = {
        windowLevels = { overlay = 1 },
        new = function(frame)
            local canvas = { initialFrame = frame, mouseCallbackFn = nil, visible = false, elements = {} }
            function canvas:level() return self end
            function canvas:behaviorAsLabels() return self end
            function canvas:clickActivating() return self end
            function canvas:mouseCallback(callback) self.mouseCallbackFn = callback; return self end
            function canvas:frame(value) if value then self.currentFrame = value end; return self end
            function canvas:replaceElements(elements) self.elements = elements; return self end
            function canvas:show() self.visible = true; return self end
            function canvas:hide() self.visible = false; return self end
            function canvas:bringToFront() return self end
            table.insert(canvasInstances, canvas)
            return canvas
        end,
    },
    image = { imageFromAppBundle = function() return nil end },
}

local function completeTask(isMetadata, output)
    for index, task in ipairs(tasks) do
        if task.script:find("set records to {}", 1, true) then
            error("metadata script uses AppleScript's reserved `records` identifier")
        end
        local taskIsMetadata = task.script:find("set tabRecords to {}", 1, true) ~= nil
            or task.script:find("set tabPresenceRecords to {}", 1, true) ~= nil
        if taskIsMetadata == isMetadata then
            table.remove(tasks, index)
            task.callback(0, output)
            return
        end
    end
    local pending = {}
    for _, task in ipairs(tasks) do
        table.insert(pending, tostring(task.script):sub(1, 80))
    end
    error("expected browser task not found; pending tasks=" .. table.concat(pending, "; "))
end

local function finishMetadataIfRunning(chromeTabs)
    completeTask(true, chromeTabs)
    for _, task in ipairs(tasks) do
        if task.script:find("company.thebrowser.dia", 1, true) then
            error("metadata polling queried Dia while it was not running")
        end
    end
end

local function pollActiveTab()
    completeTask(false, activeWindowID .. "|" .. activeTabID .. "|1|Tab " .. activeTabID)
end

local function flushDeferredCallbacks()
    while #deferredCallbacks > 0 do
        local callback = table.remove(deferredCallbacks, 1)
        callback()
    end
end

local function findCanvasRow(canvas, targetID)
    for _, element in ipairs(canvas.elements) do
        if element.type == "rectangle" and element.id == targetID then
            return element
        end
    end
    return nil
end

local ok, err = xpcall(function()
    hs = mockHS
    local modulePath = testSourcePath:gsub("/tests/[^/]+$", "/Spoons/UnifiedCommandTab.spoon/init.lua")
    local switcher = dofile(modulePath)
    assert(switcher.name == "UnifiedCommandTab" and switcher.version,
        "module did not expose Spoon metadata")
    switcher:start()

    -- Observe two tabs, creating two separate history entries.
    now = 2
    browserPoll()
    pollActiveTab()
    finishMetadataIfRunning("window-1|tab-a|1|Tab A\nwindow-1|tab-b|2|Tab B")

    now = 3.6
    activeTabID = "tab-b"
    activeWindowID = "window-2"
    browserPoll()
    pollActiveTab()
    finishMetadataIfRunning("window-1|tab-a|1|Tab A\nwindow-2|tab-b|1|Tab B")

    -- Add a third tab so pruning the first MRU row can move the clicked second
    -- row onto a different target before mouseUp arrives.
    now = 4.2
    activeTabID = "tab-c"
    activeWindowID = "window-3"
    browserPoll()
    pollActiveTab()

    commandDown = true
    local intercepted = keyHandler({
        getType = function() return mockHS.eventtap.event.types.keyDown end,
        getKeyCode = function() return mockHS.keycodes.map.tab end,
        getFlags = function() return { cmd = true } end,
    })
    assert(intercepted == true, "moving an open tab to another window discarded its history")
    flushDeferredCallbacks()
    local canvas = canvasInstances[#canvasInstances]
    assert(canvas and canvas.visible, "Command-Tab did not show the history overlay")
    local clickedTargetID = "target:browserTab:com.google.Chrome:tab-b"
    assert(findCanvasRow(canvas, clickedTargetID), "expected Chrome history row was not rendered")
    local selectionCount = #selectionScripts
    canvas.mouseCallbackFn(canvas, "mouseDown", clickedTargetID)
    -- Prune the current first row while the pointer is down. Tab B shifts from
    -- row 2 to row 1, and Tab A would occupy its old index in stale code.
    assert(#tasks > 0, "expected metadata refresh in flight during pointer press")
    completeTask(true, "window-1|tab-a|1|Tab A\nwindow-2|tab-b|1|Tab B")
    canvas.mouseCallbackFn(canvas, "mouseUp", clickedTargetID)
    assert(not canvas.visible, "clicking a history row did not close the overlay")
    assert(#selectionScripts == selectionCount + 1,
        "click did not activate the pressed target after rows were reindexed")
    assert(selectionScripts[#selectionScripts]:find('"tab%-b"'),
        "click activated a different target after history was reindexed")

    -- If the pressed target itself disappears before mouseUp, close without
    -- activating a substitute.
    intercepted = keyHandler({
        getType = function() return mockHS.eventtap.event.types.keyDown end,
        getKeyCode = function() return mockHS.keycodes.map.tab end,
        getFlags = function() return { cmd = true } end,
    })
    assert(intercepted == true, "pruned-target test could not start a switcher cycle")
    flushDeferredCallbacks()
    canvas = canvasInstances[#canvasInstances]
    selectionCount = #selectionScripts
    canvas.mouseCallbackFn(canvas, "mouseDown", clickedTargetID)
    completeTask(true, "window-1|tab-a|1|Tab A")
    canvas.mouseCallbackFn(canvas, "mouseUp", clickedTargetID)
    assert(not canvas.visible, "pruned target left the overlay visible")
    assert(#selectionScripts == selectionCount,
        "mouseUp activated a substitute after the pressed target disappeared")

    -- Restore the third tab so the separate identity-mismatch case has two
    -- live rows to click.
    activeTabID = "tab-b"
    activeWindowID = "window-2"
    browserPoll()
    pollActiveTab()

    -- Releasing over a different row than the one pressed must cancel rather
    -- than commit the target under the pointer at release time.
    intercepted = keyHandler({
        getType = function() return mockHS.eventtap.event.types.keyDown end,
        getKeyCode = function() return mockHS.keycodes.map.tab end,
        getFlags = function() return { cmd = true } end,
    })
    assert(intercepted == true, "identity-mismatch test could not start a switcher cycle")
    flushDeferredCallbacks()
    canvas = canvasInstances[#canvasInstances]
    local otherTargetID = "target:browserTab:com.google.Chrome:tab-a"
    assert(findCanvasRow(canvas, otherTargetID), "second browser row was not rendered")
    selectionCount = #selectionScripts
    canvas.mouseCallbackFn(canvas, "mouseDown", clickedTargetID)
    canvas.mouseCallbackFn(canvas, "mouseUp", otherTargetID)
    assert(not canvas.visible, "mismatched pointer release left the overlay visible")
    assert(#selectionScripts == selectionCount,
        "mismatched pointer release activated a target other than the one pressed")

    -- Restore Tab B as the active history entry for subsequent cycling tests.
    activeTabID = "tab-c"
    activeWindowID = "window-3"
    browserPoll()
    pollActiveTab()
    commandDown = false
    keyHandler({
        getType = function() return mockHS.eventtap.event.types.flagsChanged end,
        getKeyCode = function() return mockHS.keycodes.map.tab end,
        getFlags = function() return { cmd = false } end,
    })

    -- Window IDs can be recycled. If Finder's old ID now resolves to another
    -- app, selecting that stale history entry must not focus the new owner.
    local finderWindow = {
        application = function() return finder end,
        id = function() return 987 end,
        title = function() return "Finder window" end,
    }
    windowFocusedCallback(finderWindow)
    windowLookup[987] = recycledWindow
    intercepted = keyHandler({
        getType = function() return mockHS.eventtap.event.types.keyDown end,
        getKeyCode = function() return mockHS.keycodes.map.tab end,
        getFlags = function() return { cmd = true } end,
    })
    assert(intercepted == true, "recycled-window test could not start a switcher cycle")
    flushDeferredCallbacks()
    canvas = canvasInstances[#canvasInstances]
    local finderTargetID = "target:window:com.apple.finder:987"
    assert(findCanvasRow(canvas, finderTargetID), "Finder history row was not rendered")
    canvas.mouseCallbackFn(canvas, "mouseDown", finderTargetID)
    canvas.mouseCallbackFn(canvas, "mouseUp", finderTargetID)
    assert(foreignWindowFocusCount == 0, "stale window ID focused a different application")
    commandDown = false
    keyHandler({
        getType = function() return mockHS.eventtap.event.types.flagsChanged end,
        getKeyCode = function() return mockHS.keycodes.map.tab end,
        getFlags = function() return { cmd = false } end,
    })
    applicationWatcherCallback("Finder", "terminated")

    -- Targets without bundle IDs use the application name as identity and
    -- must remain selectable after the stale-window ownership check.
    local legacyFocusedWindow = {
        application = function() return legacyApp end,
        id = function() return 988 end,
        title = function() return "Legacy window" end,
    }
    windowFocusedCallback(legacyFocusedWindow)
    windowLookup[988] = legacyWindow
    intercepted = keyHandler({
        getType = function() return mockHS.eventtap.event.types.keyDown end,
        getKeyCode = function() return mockHS.keycodes.map.tab end,
        getFlags = function() return { cmd = true } end,
    })
    assert(intercepted == true, "bundle-ID-less window test could not start a switcher cycle")
    flushDeferredCallbacks()
    canvas = canvasInstances[#canvasInstances]
    local legacyTargetID = "target:window:Legacy App:988"
    assert(findCanvasRow(canvas, legacyTargetID), "bundle-ID-less app history row was not rendered")
    canvas.mouseCallbackFn(canvas, "mouseDown", legacyTargetID)
    canvas.mouseCallbackFn(canvas, "mouseUp", legacyTargetID)
    assert(legacyWindowFocusCount == 1, "valid bundle-ID-less window was rejected")
    commandDown = false
    keyHandler({
        getType = function() return mockHS.eventtap.event.types.flagsChanged end,
        getKeyCode = function() return mockHS.keycodes.map.tab end,
        getFlags = function() return { cmd = false } end,
    })
    applicationWatcherCallback("Legacy App", "terminated")

    -- Close the background tab. A complete metadata snapshot should remove it.
    now = 5.2
    browserPoll()
    pollActiveTab()
    finishMetadataIfRunning("window-2|tab-b|1|Tab B")

    intercepted = keyHandler({
        getType = function() return mockHS.eventtap.event.types.keyDown end,
        getKeyCode = function() return mockHS.keycodes.map.tab end,
        getFlags = function() return { cmd = true } end,
    })
    assert(intercepted == false, "closed tab remained in Command-Tab history")

    -- A slow active-tab response must not re-add a tab after the newer
    -- complete metadata snapshot has already removed it.
    now = 6.8
    activeTabID = "tab-a"
    activeWindowID = "window-1"
    browserPoll()
    finishMetadataIfRunning("window-2|tab-b|1|Tab B")
    pollActiveTab()

    intercepted = keyHandler({
        getType = function() return mockHS.eventtap.event.types.keyDown end,
        getKeyCode = function() return mockHS.keycodes.map.tab end,
        getFlags = function() return { cmd = true } end,
    })
    assert(intercepted == false, "stale active-tab poll restored a closed tab")

    -- An empty complete snapshot means the browser has no open tabs.
    now = 8.4
    activeTabID = "tab-b"
    activeWindowID = "window-2"
    browserPoll()
    finishMetadataIfRunning("")
    pollActiveTab()

    intercepted = keyHandler({
        getType = function() return mockHS.eventtap.event.types.keyDown end,
        getKeyCode = function() return mockHS.keycodes.map.tab end,
        getFlags = function() return { cmd = true } end,
    })
    assert(intercepted == false, "empty metadata snapshot retained browser history")

    -- A metadata completion delivered after stop must not continue the
    -- sequential browser-read chain or start another AppleScript task.
    now = 10
    frontmostApp = finder
    chromeRunning = false
    browserPoll()
    if diaRunning then
        completeTask(true, "dia-window|dia-tab|Dia tab")
    end
    assert(#tasks == 0, "metadata polling queried a stopped browser or started an unexpected read: "
        .. table.concat((function()
            local scripts = {}
            for _, task in ipairs(tasks) do table.insert(scripts, task.script) end
            return scripts
        end)(), "\n"))

    -- Dia's tab-list accessibility notification triggers a targeted metadata
    -- reconciliation immediately, without waiting for the polling interval.
    diaRunning = true
    applicationWatcherCallback("Dia", "launched")
    local diaObserver = axObservers[#axObservers]
    assert(diaObserver and diaObserver.running, "Dia tab observer was not started on launch")
    local watchesDiaTabList = false
    for _, watcher in ipairs(diaObserver.watchers) do
        if watcher.element == diaTabList
            and watcher.notification == "AXSelectedChildrenChanged" then
            watchesDiaTabList = true
        end
    end
    assert(watchesDiaTabList, "Dia tab-list notification was not registered")

    -- Keep one Chrome entry and one Dia entry in MRU so the event's snapshot
    -- must prune the closed Dia ID for the public Command-Tab path to pass.
    chromeRunning = true
    frontmostApp = chrome
    activeWindowID = "window-1"
    activeTabID = "chrome-open"
    now = 10.1
    browserPoll()
    pollActiveTab()
    frontmostApp = dia
    activeWindowID = "dia-window"
    activeTabID = "dia-closed"
    now = 10.2
    browserPoll()
    completeTask(false, "dia-window|dia-closed|Closed Dia tab")

    diaObserver:fire(diaTabList, "AXSelectedChildrenChanged")
    assert(#tasks == 1, "expected immediate tab-list metadata reconciliation")
    assert(tasks[1].script:find("company.thebrowser.dia", 1, true),
        "expected the targeted browser metadata read")
    assert(tasks[1].script:find("set tabPresenceRecords to {}", 1, true),
        "expected a presence-only browser snapshot")
    assert(tasks[1].script:find("id of tabs of theWindow", 1, true),
        "expected a bulk tab identifier read")
    assert(not tasks[1].script:find("title of theTab", 1, true),
        "expected titles to be omitted from the snapshot")
    assert(not tasks[1].script:find("Google Chrome", 1, true),
        "expected only one browser to be queried")
    completeTask(true, "dia-window|dia-open|")
    intercepted = keyHandler({
        getType = function() return mockHS.eventtap.event.types.keyDown end,
        getKeyCode = function() return mockHS.keycodes.map.tab end,
        getFlags = function() return { cmd = true } end,
    })
    assert(intercepted == false, "expected presence reconciliation to prune the closed tab")

    -- If the accessibility event is missed, periodic title-enriched polling
    -- still removes the Dia tab from history.
    activeTabID = "dia-fallback-closed"
    now = 10.3
    browserPoll()
    completeTask(false, "dia-window|dia-fallback-closed|Fallback Dia tab")
    now = 11.6
    browserPoll()
    completeTask(true, "dia-window|dia-open|Open Dia tab")
    completeTask(true, "window-1|chrome-open|1|Open Chrome tab")
    pollActiveTab()
    intercepted = keyHandler({
        getType = function() return mockHS.eventtap.event.types.keyDown end,
        getKeyCode = function() return mockHS.keycodes.map.tab end,
        getFlags = function() return { cmd = true } end,
    })
    assert(intercepted == false, "expected periodic reconciliation to prune a closed tab")

    -- Re-observe two currently active targets so the watchdog can exercise a
    -- real cycle after the closed-tab assertions have reduced history.
    frontmostApp = chrome
    activeTabID = "chrome-open"
    activeWindowID = "window-1"
    browserPoll()
    pollActiveTab()
    frontmostApp = dia
    activeTabID = "dia-open"
    activeWindowID = "dia-window"
    browserPoll()
    pollActiveTab()

    -- The watchdog must finish a cycle when Command's release event is lost.
    commandDown = true
    intercepted = keyHandler({
        getType = function() return mockHS.eventtap.event.types.keyDown end,
        getKeyCode = function() return mockHS.keycodes.map.tab end,
        getFlags = function() return { cmd = true } end,
    })
    assert(intercepted == true, "watchdog setup could not start a switcher cycle")
    flushDeferredCallbacks()
    canvas = canvasInstances[#canvasInstances]
    assert(canvas.visible, "watchdog setup overlay was not shown")
    local watchdogSelectionCount = #selectionScripts
    cycleWatchdog()
    assert(canvas.visible, "watchdog ended the cycle while Command was still held")
    assert(#selectionScripts == watchdogSelectionCount,
        "watchdog selected a target before Command was released")
    commandDown = false
    cycleWatchdog()
    assert(not canvas.visible, "watchdog did not hide overlay after a missed Command release")
    assert(#selectionScripts == watchdogSelectionCount + 1,
        "watchdog release did not activate the selected target exactly once")

    -- A failed activation must not leave cycle state or the canvas behind.
    commandDown = true
    intercepted = keyHandler({
        getType = function() return mockHS.eventtap.event.types.keyDown end,
        getKeyCode = function() return mockHS.keycodes.map.tab end,
        getFlags = function() return { cmd = true } end,
    })
    assert(intercepted == true, "activation-failure setup could not start a switcher cycle")
    flushDeferredCallbacks()
    canvas = canvasInstances[#canvasInstances]
    assert(canvas.visible, "activation-failure setup overlay was not shown")
    selectionShouldThrow = true
    commandDown = false
    keyHandler({
        getType = function() return mockHS.eventtap.event.types.flagsChanged end,
        getKeyCode = function() return mockHS.keycodes.map.tab end,
        getFlags = function() return { cmd = false } end,
    })
    selectionShouldThrow = false
    assert(not canvas.visible, "failed target activation left the overlay visible")

    -- The next Command-Tab must start at the first switcher position. If the
    -- failed activation left cycle state behind, this advances the old cycle.
    commandDown = true
    intercepted = keyHandler({
        getType = function() return mockHS.eventtap.event.types.keyDown end,
        getKeyCode = function() return mockHS.keycodes.map.tab end,
        getFlags = function() return { cmd = true } end,
    })
    assert(intercepted == true, "switcher did not start a fresh cycle after activation failed")
    flushDeferredCallbacks()
    canvas = canvasInstances[#canvasInstances]
    local headerText
    for _, element in ipairs(canvas.elements) do
        if element.type == "text" and element.text:find(" of ", 1, true) then
            headerText = element.text
            break
        end
    end
    assert(headerText and headerText:match("^2 of "),
        "activation failure left the prior cycle index active: " .. tostring(headerText))
    commandDown = false
    keyHandler({
        getType = function() return mockHS.eventtap.event.types.flagsChanged end,
        getKeyCode = function() return mockHS.keycodes.map.tab end,
        getFlags = function() return { cmd = false } end,
    })

    -- If Dia signals while a full Chrome-then-Dia snapshot is in progress,
    -- that snapshot's upcoming Dia read satisfies the queued notification.
    frontmostApp = chrome
    chromeRunning = true
    now = 13.2
    browserPoll()
    diaObserver:fire(diaTabList, "AXSelectedChildrenChanged")
    completeTask(true, "window-1|tab-a|1|Tab A\nwindow-2|tab-b|1|Tab B")
    completeTask(true, "dia-window|dia-tab|Dia tab")
    for _, task in ipairs(tasks) do
        assert(not task.script:find("set tabRecords to {}", 1, true),
            "Dia event queued a redundant read already covered by the full snapshot")
    end
    pollActiveTab()

    -- Keep another browser running so the stop-callback check can verify that
    -- a late Chrome completion does not continue the metadata-read chain.
    now = 14.8
    diaObserver:fire(diaTabList, "AXSelectedChildrenChanged")
    local pendingMetadata
    for index, task in ipairs(tasks) do
        if task.script:find("set tabPresenceRecords to {}", 1, true) then
            pendingMetadata = table.remove(tasks, index)
            break
        end
    end
    assert(pendingMetadata, "expected a pending metadata read before stop")
    switcher:stop()
    assert(not diaObserver.running, "Dia tab observer remained active after stop")
    local pendingCount = #tasks
    diaObserver:fire(diaTabList, "AXSelectedChildrenChanged")
    assert(#tasks == pendingCount, "Dia notification started a metadata read after stop")
    pendingMetadata.callback(0, "")
    assert(#tasks == pendingCount, "metadata callback started another read after stop")
    assert(cycleWatchdogTimer and cycleWatchdogTimer.stopped,
        "stop did not stop the Command-release watchdog")
end, debug.traceback)

hs = realHS
if not ok then error(err) end
print("Unified Command-Tab regression: PASS")
