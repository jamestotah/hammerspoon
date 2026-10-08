-- Returns a factory, not a singleton. Each instance loads and starts the Spoon
-- with private globals. Timers, tasks, windows, settings and scripts are mocks.
--
-- Benchmark capture (nothing is selected in a real browser):
-- local factory = dofile(".../tests/support/mock_hs.lua")
-- local f = factory(".../Spoons/UnifiedCommandTab.spoon/init.lua")
-- f:observeBrowser("company.thebrowser.dia", "window-1", "tab-1", "One")
-- f:observeBrowser("company.thebrowser.dia", "window-2", "tab-2", "Two")
-- assert(f:key("keyDown", { cmd = true }))
-- f:flush()
-- f:click("browserTab:company.thebrowser.dia:tab-1")
-- local script = assert(f.selectionScripts[1])
-- f:stop()
return function(modulePath, options)
    options = options or {}
    local f = {
        now = 0, timers = {}, tasks = {}, apps = {}, windows = {},
        canvases = {}, observers = {}, taps = {}, filters = {}, watchers = {},
        selectionScripts = {}, focuses = {}, activations = {}, operations = {},
        settings = {}, settingsWrites = {}, alerts = {}, modifiers = {},
        counts = {
            taskCreated = 0, taskStarted = 0, taskTerminated = 0, lateDeliveries = 0,
            render = 0, focus = 0, activate = 0, icon = 0, show = 0, hide = 0,
            timerCallbacks = 0, timerCancelled = 0,
        },
    }
    f.settings["unifiedCmdTab.enabled"] = options.enabled
    local screen = { frame = function() return { x = 0, y = 0, w = 1000, h = 800 } end }

    local function record(kind, value)
        table.insert(f.operations, { kind = kind, value = value })
    end

    local function timer(delay, callback, interval)
        local t = { due = f.now + delay, callback = callback, interval = interval, stopped = false }
        function t:stop()
            if not self.stopped then f.counts.timerCancelled = f.counts.timerCancelled + 1 end
            self.stopped = true
        end
        table.insert(f.timers, t)
        return t
    end

    -- One run-loop turn: work scheduled by a callback waits for the next flush.
    -- Cancelled callbacks never run, including callbacks cancelled mid-turn.
    function f:flush()
        local ready = {}
        for _, t in ipairs(self.timers) do
            if not t.stopped and t.due <= self.now then table.insert(ready, t) end
        end
        for _, t in ipairs(ready) do
            if not t.stopped then
                if t.interval then t.due = t.due + t.interval else t.stopped = true end
                self.counts.timerCallbacks = self.counts.timerCallbacks + 1
                t.callback()
            end
        end
    end

    function f:advance(seconds)
        assert(seconds >= 0, "time cannot run backwards")
        local deadline, turns = self.now + seconds, 0
        while true do
            local due
            for _, t in ipairs(self.timers) do
                if not t.stopped and t.due <= deadline then due = math.min(due or t.due, t.due) end
            end
            if not due then break end
            self.now = math.max(self.now, due)
            self:flush()
            turns = turns + 1
            assert(turns < 10000, "scheduler did not settle")
        end
        self.now = deadline
    end

    local function axNode(role, attributes, children)
        return { attributeValue = function(_, name)
            if name == "AXRole" then return role end
            if name == "AXChildren" then return children or {} end
            return (attributes or {})[name]
        end }
    end
    f.diaTabList = axNode("AXList", {}, { axNode("AXUnknown", { AXIdentifier = "tab" }) })
    f.diaWindowAX = axNode("AXWindow", {}, { f.diaTabList })
    f.diaApplicationAX = axNode("AXApplication")

    function f:newApp(bundleID, name)
        local app = { windows = {}, running = true, identity = bundleID or name }
        function app:bundleID() return bundleID end
        function app:name() return name end
        function app:pid() return 4321 end
        function app:allWindows() return self.windows end
        function app:activate()
            f.counts.activate = f.counts.activate + 1
            table.insert(f.activations, self.identity)
            record("activate", self.identity)
        end
        self.apps[app.identity], self.apps[name] = app, app
        return app
    end

    function f:newWindow(app, id, title)
        local window = { owner = app, windowID = id, windowTitle = title }
        function window:application() return self.owner end
        function window:id() return self.windowID end
        function window:title() return self.windowTitle end
        function window:screen() return screen end
        function window:focus()
            f.counts.focus = f.counts.focus + 1
            table.insert(f.focuses, self.windowID)
            record("focus", self.windowID)
        end
        self.windows[id] = window
        table.insert(app.windows, window)
        return window
    end

    function f:windowEvent(event, window)
        for _, filter in ipairs(self.filters) do
            if filter.callbacks[event] then filter.callbacks[event](window) end
        end
    end

    function f:observeWindow(window)
        self.frontmostApp, self.frontmostWindow = window:application(), window
        self:windowEvent("focused", window)
    end

    function f:appEvent(event, app)
        for _, watcher in ipairs(self.watchers) do
            if watcher.running then watcher.callback(app:name(), event, app) end
        end
    end

    function f:pollBrowser()
        for _, t in ipairs(self.timers) do
            if t.interval == 0.5 and not t.stopped then t.callback() end
        end
    end

    function f:pending(kind, appID)
        local found = {}
        for _, task in ipairs(self.tasks) do
            if not task.completed and not task.terminated
                and (not kind or task.kind == kind)
                and (not appID or task.appID == appID) then
                table.insert(found, task)
            end
        end
        return found
    end

    function f:task(kind, appID)
        local found = self:pending(kind, appID)
        assert(#found == 1, "expected one " .. tostring(kind) .. " task, got " .. #found)
        return found[1]
    end

    function f:complete(task, output, exitCode)
        assert(not task.completed and not task.terminated, "task is no longer pending; use deliverLate for termination races")
        task.completed = true
        return task.callback(exitCode or 0, output or "")
    end

    function f:deliverLate(task, output, exitCode)
        assert(task.terminated and not task.completed, "late delivery requires an uncompleted terminated task")
        task.completed = true
        self.counts.lateDeliveries = self.counts.lateDeliveries + 1
        return task.callback(exitCode or 0, output or "")
    end

    function f:observeBrowser(appID, windowID, tabID, title, tabIndex)
        local names = { ["com.google.Chrome"] = "Google Chrome", ["company.thebrowser.dia"] = "Dia" }
        assert(names[appID], "unsupported fixture browser")
        local app = self.apps[appID]
        if not app then
            app = self:newApp(appID, names[appID])
            self:newWindow(app, windowID, title or "")
            self:appEvent("launched", app)
        end
        self.frontmostApp, self.frontmostWindow = app, nil
        self:pollBrowser()
        local fields = { tostring(windowID), tostring(tabID) }
        if appID == "com.google.Chrome" then table.insert(fields, tostring(tabIndex or 1)) end
        table.insert(fields, title or "")
        self:complete(self:task("active", appID), table.concat(fields, "|"))
    end

    function f:key(eventName, flags, keyCode)
        self.modifiers = flags or {}
        local tap = self.taps[#self.taps]
        if not tap or not tap.running then return false end
        return tap.callback({
            getType = function() return assert(self.hs.eventtap.event.types[eventName]) end,
            getFlags = function() return self.modifiers end,
            getKeyCode = function() return keyCode or 48 end,
        })
    end

    function f:canvas() return self.canvases[#self.canvases] end

    function f:rows()
        local result, canvas = {}, self:canvas()
        for _, element in ipairs(canvas and canvas.elements or {}) do
            local key = element.id and element.id:match("^target:(.+)$")
            if element.type == "rectangle" and key then
                local row = { key = key, selected = element.fillColor.red ~= nil }
                for _, text in ipairs(canvas.elements) do
                    if text.type == "text" and text.frame.y == element.frame.y + 24 then row.title = text.text end
                end
                table.insert(result, row)
            end
        end
        return result
    end

    function f:selectedKey()
        for _, row in ipairs(self:rows()) do if row.selected then return row.key end end
    end

    function f:mouse(message, targetKey)
        local canvas = assert(self:canvas(), "flush before clicking")
        assert(canvas.visible, "cannot click hidden canvas")
        canvas.callback(canvas, message, "target:" .. targetKey:gsub("^target:", ""))
    end

    function f:click(targetKey)
        self:mouse("mouseDown", targetKey)
        self:mouse("mouseUp", targetKey)
    end

    function f:notifyDia(notification)
        local observer = assert(self.observers[#self.observers], "no Dia observer")
        local element = notification == "AXWindowCreated" and self.diaApplicationAX or self.diaTabList
        if observer.running then
            for _, watch in ipairs(observer.watches) do
                if watch.element == element and watch.notification == notification then
                    observer.callbackFn(observer, element, notification, {})
                end
            end
        end
    end

    function f:toggle()
        local items = self.switcher:addMenuItems({})
        items[2].fn()
    end

    local function watcher(registry, callback)
        local w = { callback = callback, running = false }
        function w:start() self.running = true; return self end
        function w:stop() self.running = false; return self end
        table.insert(registry, w)
        return w
    end

    f.hs = {
        logger = { new = function() return {} end },
        settings = {
            get = function(key) return f.settings[key] end,
            set = function(key, value)
                f.settings[key] = value
                table.insert(f.settingsWrites, { key = key, value = value })
            end,
        },
        alert = { show = function(text) table.insert(f.alerts, text) end },
        application = {
            get = function(id) local app = f.apps[id]; return app and app.running and app or nil end,
            frontmostApplication = function() return f.frontmostApp end,
            watcher = {
                activated = "activated", launched = "launched", terminated = "terminated",
                new = function(callback) return watcher(f.watchers, callback) end,
            },
        },
        window = {
            get = function(id) return f.windows[id] end,
            frontmostWindow = function() return f.frontmostWindow end,
            filter = {
                windowFocused = "focused", windowDestroyed = "destroyed", windowNotVisible = "hidden",
                new = function()
                    local filter = { callbacks = {} }
                    function filter:subscribe(event, callback) self.callbacks[event] = callback end
                    function filter:unsubscribeAll() self.callbacks = {} end
                    table.insert(f.filters, filter)
                    return filter
                end,
            },
        },
        timer = {
            secondsSinceEpoch = function() return f.now end,
            doAfter = function(delay, callback) return timer(delay, callback) end,
            doEvery = function(interval, callback) return timer(interval, callback, interval) end,
        },
        task = { new = function(_, callback, args)
            local script = args[2]
            local kind = script:find("set tabPresenceRecords to {}", 1, true) and "presence"
                or script:find("set tabRecords to {}", 1, true) and "metadata" or "active"
            local task = { script = script, kind = kind, callback = callback,
                appID = script:match('tell application id "([^"]+)"') }
            f.counts.taskCreated = f.counts.taskCreated + 1
            function task:start()
                assert(not self.started, "task started twice")
                self.started = true
                f.counts.taskStarted = f.counts.taskStarted + 1
                table.insert(f.tasks, self)
                return self
            end
            function task:terminate()
                self.terminated = true
                f.counts.taskTerminated = f.counts.taskTerminated + 1
            end
            return task
        end },
        osascript = { applescript = function(script)
            table.insert(f.selectionScripts, script)
            record("select", script)
            if f.selectionError then error(f.selectionError) end
            return true, true
        end },
        eventtap = {
            event = { types = { keyDown = 1, keyUp = 2, flagsChanged = 3 } },
            new = function(_, callback) return watcher(f.taps, callback) end,
            checkKeyboardModifiers = function() return f.modifiers end,
        },
        keycodes = { map = { tab = 48 } },
        screen = { mainScreen = function() return screen end },
        image = { imageFromAppBundle = function(appID)
            f.counts.icon = f.counts.icon + 1
            if options.noIcons then return nil end
            return { appID = appID }
        end },
        canvas = {
            windowLevels = { overlay = 1 },
            new = function(frame)
                local canvas = { currentFrame = frame, visible = false, elements = {} }
                function canvas:level() return self end
                function canvas:behaviorAsLabels() return self end
                function canvas:clickActivating(value) assert(value == false); return self end
                function canvas:mouseCallback(callback) self.callback = callback; return self end
                function canvas:frame(value) self.currentFrame = value; return self end
                function canvas:replaceElements(elements)
                    self.elements = elements
                    f.counts.render = f.counts.render + 1
                    record("render")
                    return self
                end
                function canvas:show() self.visible = true; f.counts.show = f.counts.show + 1; return self end
                function canvas:hide()
                    self.visible = false
                    f.counts.hide = f.counts.hide + 1
                    record("hide")
                    return self
                end
                function canvas:bringToFront(activate) assert(activate == false); return self end
                table.insert(f.canvases, canvas)
                return canvas
            end,
        },
        axuielement = {
            windowElement = function() return f.diaWindowAX end,
            applicationElement = function() return f.diaApplicationAX end,
            observer = { new = function(pid)
                local observer = watcher(f.observers)
                observer.pid, observer.watches = pid, {}
                function observer:callback(callback) self.callbackFn = callback; return self end
                function observer:addWatcher(element, notification)
                    table.insert(self.watches, { element = element, notification = notification })
                    return self
                end
                return observer
            end },
        },
    }

    local hostGlobals = _G
    local environment = setmetatable({ hs = f.hs }, { __index = hostGlobals })
    environment._G = environment
    environment.dofile = function(path) return assert(loadfile(path, "t", environment))() end
    f.switcher = environment.dofile(modulePath)
    function f:stop() self.switcher:stop() end
    f.switcher:start()
    return f
end
