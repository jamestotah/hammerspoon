-- Run with: hs -c 'dofile(".../tests/unified_cmd_tab_test.lua")'
-- This exercises the closed-tab history regression through the public key path.
-- Value: protects closed browser tabs staying out of Command-Tab history after close, empty snapshots, and stale poll races; fails_when=metadata pruning or generation checks are removed; why_new=no pre-existing regression test covers browser history cleanup; seam=none
local realHS = hs
local now = 0
local tasks = {}
local browserPoll
local keyHandler
local applicationWatcherCallback
local axObservers = {}
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
local finder = { bundleID = function() return "com.apple.finder" end }
local frontmostApp = chrome
local mockHS = {
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
                return { subscribe = function() end, unsubscribeAll = function() end }
            end,
        },
        frontmostWindow = function() return nil end,
    },
    timer = {
        secondsSinceEpoch = function() return now end,
        doEvery = function(_, callback) browserPoll = callback; return { stop = function() end } end,
        doAfter = function() return { stop = function() end } end,
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
    osascript = { applescript = function() return true, true end },
    eventtap = {
        event = { types = { keyDown = 1, keyUp = 2, flagsChanged = 3 } },
        new = function(_, callback) keyHandler = callback; return { start = function() end, stop = function() end } end,
    },
    keycodes = { map = { tab = 48 } },
    screen = { mainScreen = function() return { frame = function() return { x = 0, y = 0, w = 1000, h = 800 } end } end },
    canvas = { windowLevels = { overlay = 1 } },
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

local ok, err = xpcall(function()
    hs = mockHS
    local modulePath = testSourcePath:gsub("/tests/[^/]+$", "/unified_cmd_tab.lua")
    local switcher = dofile(modulePath)
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

    local intercepted = keyHandler({
        getType = function() return mockHS.eventtap.event.types.keyDown end,
        getKeyCode = function() return mockHS.keycodes.map.tab end,
        getFlags = function() return { cmd = true } end,
    })
    assert(intercepted == true, "moving an open tab to another window discarded its history")
    keyHandler({
        getType = function() return mockHS.eventtap.event.types.flagsChanged end,
        getKeyCode = function() return mockHS.keycodes.map.tab end,
        getFlags = function() return { cmd = false } end,
    })

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
    assert(#tasks == 1, "Dia tab-list notification did not trigger an immediate metadata read")
    assert(tasks[1].script:find("company.thebrowser.dia", 1, true),
        "Dia tab-list notification did not target Dia metadata")
    assert(tasks[1].script:find("set tabPresenceRecords to {}", 1, true),
        "Dia tab-list notification did not use the fast presence-only snapshot")
    assert(tasks[1].script:find("id of tabs of theWindow", 1, true),
        "Dia fast snapshot did not bulk-read tab IDs")
    assert(not tasks[1].script:find("title of theTab", 1, true),
        "Dia fast snapshot unnecessarily read tab titles")
    assert(not tasks[1].script:find("Google Chrome", 1, true),
        "Dia tab-list notification unnecessarily queried Chrome")
    completeTask(true, "dia-window|dia-open|")
    intercepted = keyHandler({
        getType = function() return mockHS.eventtap.event.types.keyDown end,
        getKeyCode = function() return mockHS.keycodes.map.tab end,
        getFlags = function() return { cmd = true } end,
    })
    assert(intercepted == false, "fast Dia presence snapshot did not prune the closed tab from history")

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
    assert(intercepted == false, "periodic Dia snapshot failed to prune a closed tab")

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
    browserPoll()
    local pendingMetadata
    for index, task in ipairs(tasks) do
        if task.script:find("set tabRecords to {}", 1, true) then
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
end, debug.traceback)

hs = realHS
if not ok then error(err) end
print("Unified Command-Tab closed-tab regression: PASS")
