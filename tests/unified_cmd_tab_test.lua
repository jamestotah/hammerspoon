-- Run with: hs -c 'dofile(".../tests/unified_cmd_tab_test.lua")'
-- This exercises the closed-tab history regression through the public key path.
-- Value: protects closed browser tabs staying out of Command-Tab history after close, empty snapshots, and stale poll races; fails_when=metadata pruning or generation checks are removed; why_new=no pre-existing regression test covers browser history cleanup; seam=none
local realHS = hs
local now = 0
local tasks = {}
local browserPoll
local keyHandler
local activeTabID = "tab-a"
local activeWindowID = "window-1"
local testSourcePath = debug.getinfo(1, "S").source:sub(2)

local chrome = { bundleID = function() return "com.google.Chrome" end }
local mockHS = {
    settings = { get = function() return nil end },
    application = {
        frontmostApplication = function() return chrome end,
        get = function(id) return id == "com.google.Chrome" and chrome or nil end,
        watcher = {
            activated = "activated", launched = "launched", terminated = "terminated",
            new = function() return { start = function() end, stop = function() end } end,
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
        local taskIsMetadata = task.script:find("set records to {}", 1, true) ~= nil
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
    local hasMetadataTask = false
    for _, task in ipairs(tasks) do
        if task.script:find("set records to {}", 1, true) then
            hasMetadataTask = true
            break
        end
    end
    if not hasMetadataTask then
        return
    end

    completeTask(true, chromeTabs)
    completeTask(true, "") -- Dia has no tabs in this test.
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
    browserPoll()
    local pendingMetadata
    for index, task in ipairs(tasks) do
        if task.script:find("set records to {}", 1, true) then
            pendingMetadata = table.remove(tasks, index)
            break
        end
    end
    assert(pendingMetadata, "expected a pending metadata read before stop")
    switcher:stop()
    local pendingCount = #tasks
    pendingMetadata.callback(0, "")
    assert(#tasks == pendingCount, "metadata callback started another read after stop")
end, debug.traceback)

hs = realHS
if not ok then error(err) end
print("Unified Command-Tab closed-tab regression: PASS")
