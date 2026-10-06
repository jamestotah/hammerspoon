-- Treat selected browser tabs and ordinary application windows as one
-- most-recently-used list for Command-Tab.
--
-- Supported browsers:
--   Google Chrome (com.google.Chrome)
--   Dia          (company.thebrowser.dia)
--
-- The module intentionally uses each browser's AppleScript dictionary:
-- Chrome selects an active tab by index, while Dia exposes a tab focus command.

local obj = {}

local SETTINGS_KEY = "unifiedCmdTab.enabled"
-- Browser state comes from AppleScript, which is relatively expensive. Run it
-- out of process and at a human-scale cadence so it never blocks key events.
local POLL_INTERVAL = 0.50
local BROWSER_METADATA_INTERVAL = 1.50
local MAX_HISTORY = 100

local BROWSERS = {
    ["com.google.Chrome"] = {
        name = "Google Chrome",
        appID = "com.google.Chrome",
        mode = "chrome",
    },
    ["company.thebrowser.dia"] = {
        name = "Dia",
        appID = "company.thebrowser.dia",
        mode = "dia",
    },
}

-- Spokenly is an accessory app (LSUIElement = 1), so macOS omits it from
-- the native app switcher and it has no normal window to track.
local SWITCHABLE_APPLICATIONS = {
    ["app.spokenly"] = {
        name = "Spokenly",
        appID = "app.spokenly",
    },
}

local history = {}
local lastObservedKey = nil
local lastObservedTarget = nil
local cycle = nil
local suppressNextTabUp = false
local eventTap = nil
local browserTimer = nil
local windowFilter = nil
local applicationWatcher = nil
local menuRefresh = nil
local overlay = nil
local iconCache = {}
local overlayUpdateTimer = nil
local overlayVisible = false
local enabled = true
local browserReadTask = nil
local browserMetadataReadTask = nil
local lastBrowserMetadataReadAt = 0
local browserMetadataGeneration = 0
local browserMetadataReadGeneration = 0
local pendingBrowserMetadataReads = {}
local diaTabObserver = nil
local diaTabObserverPID = nil
local diaTabObserverRebindTimer = nil
local diaTabObserverGeneration = 0
local scheduleOverlayUpdate
local finishCycle

local OVERLAY_WIDTH = 680
local MAX_VISIBLE_ROWS = 12
local ROW_HEIGHT = 48
local HEADER_HEIGHT = 72
local FOOTER_HEIGHT = 36

local function copyTarget(target)
    if not target then
        return nil
    end

    local copy = {}
    for key, value in pairs(target) do
        copy[key] = value
    end
    return copy
end

local function normalizeTarget(target)
    if not target then
        return nil
    end

    -- Older in-memory entries may have been recorded through a temporary
    -- Spokenly window. Collapse those entries to Spokenly's canonical app
    -- identity before they can be inserted again.
    if target.bundleID == "app.spokenly" then
        if hs.application.get("app.spokenly") then
            return {
                kind = "application",
                key = "application:app.spokenly",
                bundleID = "app.spokenly",
                appName = "Spokenly",
                title = "Spokenly",
            }
        end
    end

    return target
end

local function remember(target)
    target = normalizeTarget(target)
    if not target then
        return
    end

    for i = #history, 1, -1 do
        if history[i].key == target.key then
            table.remove(history, i)
        end
    end

    table.insert(history, 1, copyTarget(target))
    lastObservedKey = target.key
    lastObservedTarget = copyTarget(target)

    while #history > MAX_HISTORY do
        table.remove(history)
    end
end

local function forgetTargets(predicate)
    for i = #history, 1, -1 do
        if predicate(history[i]) then
            table.remove(history, i)
        end
    end

    if lastObservedTarget and predicate(lastObservedTarget) then
        lastObservedKey = nil
        lastObservedTarget = nil
    end
end

local function observe(target)
    -- Focus changes caused by our own switcher must not rewrite the MRU list
    -- while Command is still held.
    if cycle or not target then
        return
    end

    if target.key ~= lastObservedKey then
        remember(target)
        return
    end

    -- A browser tab keeps the same identity while its title changes. Keep the
    -- existing MRU position, but refresh the metadata shown in the switcher.
    if target.title and target.title ~= "" then
        for _, historicalTarget in ipairs(history) do
            if historicalTarget.key == target.key then
                historicalTarget.title = target.title
                break
            end
        end

        if lastObservedTarget and lastObservedTarget.key == target.key then
            lastObservedTarget.title = target.title
        end
    end
end

local function quoteAppleScriptString(value)
    value = tostring(value)
    value = value:gsub("\\", "\\\\")
    value = value:gsub('"', '\\"')
    return '"' .. value .. '"'
end

local function browserForApplication(app)
    if not app then
        return nil
    end
    return BROWSERS[app:bundleID()]
end

local function targetForSwitchableApplication(app)
    if not app then
        return nil
    end
    local switchable = SWITCHABLE_APPLICATIONS[app:bundleID()]
    if not switchable then
        return nil
    end

    -- Spokenly keeps its menu-bar process alive after its UI window closes.
    -- Only make it switchable while it has an actual window to return to.
    if #app:allWindows() == 0 then
        return nil
    end

    return {
        kind = "application",
        key = "application:" .. switchable.appID,
        bundleID = switchable.appID,
        appName = switchable.name,
        title = switchable.name,
    }
end

local function browserReadScript(browser)
    local script

    if browser.mode == "chrome" then
        script = string.format([[
using terms from application "Google Chrome"
tell application id %s
    if (count of windows) is 0 then
        return ""
    end if

    set theWindow to front window
    set theTab to active tab of theWindow

    return (id of theWindow as text) & "|" & ¬
           (id of theTab as text) & "|" & ¬
           (active tab index of theWindow as text) & "|" & ¬
           (title of theTab as text)
end tell
end using terms from
]], quoteAppleScriptString(browser.appID))
    else
        script = string.format([[
tell application id %s
    if (count of windows) is 0 then
        return ""
    end if

    set theWindow to front window
    set theTab to active tab of theWindow

    return (id of theWindow as text) & "|" & ¬
           (id of theTab as text) & "|" & ¬
           (title of theTab as text)
end tell
]], quoteAppleScriptString(browser.appID))
    end

    return script
end

local function parseBrowserTarget(browser, result)
    result = result and result:gsub("[\r\n]+$", "")
    if type(result) ~= "string" or result == "" then
        return nil
    end

    local windowID, tabID, tabIndex, title
    if browser.mode == "chrome" then
        windowID, tabID, tabIndex, title = result:match("^([^|]+)|([^|]+)|([^|]+)|(.*)$")
    else
        windowID, tabID, title = result:match("^([^|]+)|([^|]+)|(.*)$")
    end
    if not windowID or not tabID then
        return nil
    end

    return {
        kind = "browserTab",
        browser = browser,
        key = "browserTab:" .. browser.appID .. ":" .. tabID,
        windowID = windowID,
        tabID = tabID,
        tabIndex = tonumber(tabIndex),
        title = title or "",
    }
end

local function browserMetadataReadScript(browser)
    if browser.mode == "chrome" then
        return string.format([[
using terms from application "Google Chrome"
tell application id %s
    set tabRecords to {}
    repeat with theWindow in windows
        set windowID to (id of theWindow as text)
        repeat with i from 1 to (count of tabs of theWindow)
            set theTab to tab i of theWindow
            set end of tabRecords to windowID & "|" & (id of theTab as text) & "|" & (i as text) & "|" & (title of theTab as text)
        end repeat
    end repeat
    set AppleScript's text item delimiters to linefeed
    return tabRecords as text
end tell
end using terms from
]], quoteAppleScriptString(browser.appID))
    end

    return string.format([[
tell application id %s
    set tabRecords to {}
    repeat with theWindow in windows
        set windowID to (id of theWindow as text)
        repeat with theTab in tabs of theWindow
            set end of tabRecords to windowID & "|" & (id of theTab as text) & "|" & (title of theTab as text)
        end repeat
    end repeat
    set AppleScript's text item delimiters to linefeed
    return tabRecords as text
end tell
]], quoteAppleScriptString(browser.appID))
end

local function browserTabPresenceReadScript(browser)
    return string.format([[
tell application id %s
    set tabPresenceRecords to {}
    repeat with theWindow in windows
        set windowID to id of theWindow as text
        set windowTabIDs to id of tabs of theWindow
        repeat with tabID in windowTabIDs
            set end of tabPresenceRecords to windowID & "|" & (tabID as text) & "|"
        end repeat
    end repeat
    set AppleScript's text item delimiters to linefeed
    return tabPresenceRecords as text
end tell
]], quoteAppleScriptString(browser.appID))
end

local function refreshBrowserMetadata(browser, result)
    if type(result) ~= "string" then
        return
    end

    local seenTabs = {}
    for line in result:gmatch("[^\r\n]+") do
        local windowID, tabID, tabIndex, title
        if browser.mode == "chrome" then
            windowID, tabID, tabIndex, title = line:match("^([^|]+)|([^|]+)|([^|]+)|(.*)$")
        else
            windowID, tabID, title = line:match("^([^|]+)|([^|]+)|(.*)$")
        end

        if windowID and tabID then
            -- Tab IDs remain stable when a tab moves to another window. Keep
            -- windowID as target metadata for focusing, not as tab identity.
            local key = "browserTab:" .. browser.appID .. ":" .. tabID
            seenTabs[key] = true
            local function refreshTarget(target)
                if target and target.key == key then
                    target.windowID = windowID
                    if title and title ~= "" then
                        target.title = title
                        if browser.mode == "chrome" then
                            target.tabIndex = tonumber(tabIndex) or target.tabIndex
                        end
                    end
                end
            end

            for _, target in ipairs(history) do
                refreshTarget(target)
            end

            if cycle then
                for _, target in ipairs(cycle.order) do
                    refreshTarget(target)
                end
            end

            refreshTarget(lastObservedTarget)
        end
    end

    -- The metadata response is a complete snapshot for this browser. The
    -- active-tab poll cannot detect a closed background tab, so remove any
    -- history entries whose stable tab IDs are no longer present.
    forgetTargets(function(target)
        return target.kind == "browserTab"
            and target.browser
            and target.browser.appID == browser.appID
            and not seenTabs[target.key]
    end)

    if cycle then
        local selectedKey = cycle.selected and cycle.selected.key
        local oldIndex = cycle.index
        local remaining = {}
        for _, target in ipairs(cycle.order) do
            if target.kind ~= "browserTab"
                or not target.browser
                or target.browser.appID ~= browser.appID
                or seenTabs[target.key] then
                table.insert(remaining, target)
            end
        end
        cycle.order = remaining

        if #remaining == 0 then
            cycle.index = 0
            cycle.selected = nil
        else
            cycle.index = math.min(oldIndex, #remaining)
            cycle.selected = remaining[cycle.index]
            if selectedKey then
                for index, target in ipairs(remaining) do
                    if target.key == selectedKey then
                        cycle.index = index
                        cycle.selected = target
                        break
                    end
                end
            end
        end
    end
end

local function refreshBrowserMetadataAsync(requestedBrowser, presenceOnly)
    if browserMetadataReadTask then
        if requestedBrowser then
            local pending = pendingBrowserMetadataReads[requestedBrowser.appID]
            if not pending or (pending.presenceOnly and not presenceOnly) then
                pendingBrowserMetadataReads[requestedBrowser.appID] = {
                    browser = requestedBrowser,
                    presenceOnly = presenceOnly,
                }
            end
        end
        return
    end

    if not requestedBrowser then
        lastBrowserMetadataReadAt = hs.timer.secondsSinceEpoch()
    end
    browserMetadataGeneration = browserMetadataGeneration + 1
    browserMetadataReadGeneration = browserMetadataReadGeneration + 1
    local readGeneration = browserMetadataReadGeneration

    local browsers = {}
    if requestedBrowser then
        if hs.application.get(requestedBrowser.appID) then
            table.insert(browsers, requestedBrowser)
        end
    else
        local activeApp = hs.application.frontmostApplication()
        local activeBrowser = browserForApplication(activeApp)
        if activeBrowser and hs.application.get(activeBrowser.appID) then
            table.insert(browsers, activeBrowser)
        end
        for _, browser in pairs(BROWSERS) do
            -- AppleScript's `tell application` launches a stopped app. Snapshot
            -- only browsers that Hammerspoon reports as already running; the
            -- application watcher removes history when a browser terminates.
            if browser ~= activeBrowser and hs.application.get(browser.appID) then
                table.insert(browsers, browser)
            end
        end
    end

    local function readPendingMetadata()
        local pendingRefresh
        for appID, refresh in pairs(pendingBrowserMetadataReads) do
            pendingRefresh = refresh
            pendingBrowserMetadataReads[appID] = nil
            break
        end
        if pendingRefresh then
            refreshBrowserMetadataAsync(pendingRefresh.browser, pendingRefresh.presenceOnly)
        end
    end

    local browserIndex = 1
    local function readNextBrowser()
        if readGeneration ~= browserMetadataReadGeneration then
            return
        end

        local browser = browsers[browserIndex]
        browserIndex = browserIndex + 1
        if not browser then
            browserMetadataReadTask = nil
            readPendingMetadata()
            return
        end
        -- A full snapshot may already be about to read the browser whose
        -- notification was queued. That read satisfies the queued refresh.
        local pendingRefresh = pendingBrowserMetadataReads[browser.appID]
        if pendingRefresh and (not presenceOnly or not pendingRefresh.presenceOnly) then
            pendingBrowserMetadataReads[browser.appID] = nil
        end

        browserMetadataReadTask = hs.task.new("/usr/bin/osascript", function(exitCode, stdOut)
            if readGeneration ~= browserMetadataReadGeneration then
                return true
            end
            browserMetadataReadTask = nil
            if exitCode == 0 then
                -- Presence-only reads return the same window|tab|title shape,
                -- with an empty title, so normal reconciliation prunes history
                -- without waiting for the slower title refresh.
                refreshBrowserMetadata(browser, stdOut)
                browserMetadataGeneration = browserMetadataGeneration + 1
                if cycle then
                    scheduleOverlayUpdate()
                end
            end
            readNextBrowser()
            return true
        end, { "-e", presenceOnly
            and browserTabPresenceReadScript(browser)
            or browserMetadataReadScript(browser) })
        browserMetadataReadTask:start()
    end

    readNextBrowser()
end

local function diaAccessibilityAttribute(element, name)
    local ok, value = pcall(function()
        return element:attributeValue(name)
    end)
    if ok then
        return value
    end
    return nil
end

local function diaTabListElements(app)
    local lists = {}
    local visited = {}
    local budget = 3000

    local function visit(element, depth)
        if not element or depth > 16 or budget <= 0 then
            return
        end

        local identity = tostring(element)
        if visited[identity] then
            return
        end
        visited[identity] = true
        budget = budget - 1

        local children = diaAccessibilityAttribute(element, "AXChildren") or {}
        if diaAccessibilityAttribute(element, "AXRole") == "AXList" then
            for _, child in ipairs(children) do
                if diaAccessibilityAttribute(child, "AXIdentifier") == "tab" then
                    table.insert(lists, element)
                    break
                end
            end
        end

        for _, child in ipairs(children) do
            visit(child, depth + 1)
        end
    end

    for _, window in ipairs(app:allWindows()) do
        local ok, root = pcall(hs.axuielement.windowElement, window)
        if ok and root then
            visit(root, 0)
        end
    end

    return lists
end

local function stopDiaTabObserver()
    diaTabObserverGeneration = diaTabObserverGeneration + 1
    if diaTabObserverRebindTimer then
        diaTabObserverRebindTimer:stop()
        diaTabObserverRebindTimer = nil
    end
    if diaTabObserver then
        pcall(function()
            diaTabObserver:stop()
        end)
        diaTabObserver = nil
        diaTabObserverPID = nil
    end
end

local function ensureDiaTabObserver(forceRebind)
    local app = hs.application.get(BROWSERS["company.thebrowser.dia"].appID)
    if not app or not hs.axuielement or not hs.axuielement.observer then
        if not app then
            stopDiaTabObserver()
        end
        return
    end

    local pid = app:pid()
    if diaTabObserver and diaTabObserverPID == pid and not forceRebind then
        return
    end

    stopDiaTabObserver()
    local generation = diaTabObserverGeneration
    local ok, observer = pcall(hs.axuielement.observer.new, pid)
    if not ok or not observer then
        return
    end

    diaTabObserver = observer
    diaTabObserverPID = pid
    observer:callback(function(_, _, notification)
        if not eventTap or not enabled or generation ~= diaTabObserverGeneration then
            return
        end

        if notification == "AXSelectedChildrenChanged" then
            -- Dia exposes its tab strip as an AXList and signals tab changes
            -- on that list. Use the notification to prompt an authoritative
            -- AppleScript snapshot; periodic polling remains the fallback.
            refreshBrowserMetadataAsync(BROWSERS["company.thebrowser.dia"], true)
        elseif notification == "AXWindowCreated" then
            if diaTabObserverRebindTimer then
                diaTabObserverRebindTimer:stop()
            end
            diaTabObserverRebindTimer = hs.timer.doAfter(0.1, function()
                diaTabObserverRebindTimer = nil
                if eventTap and generation == diaTabObserverGeneration then
                    ensureDiaTabObserver(true)
                end
            end)
        end
    end)

    local appElementOK, appElement = pcall(hs.axuielement.applicationElement, app)
    if appElementOK and appElement then
        pcall(function()
            observer:addWatcher(appElement, "AXWindowCreated")
        end)
    end

    for _, tabList in ipairs(diaTabListElements(app)) do
        pcall(function()
            observer:addWatcher(tabList, "AXSelectedChildrenChanged")
        end)
    end

    local started = pcall(function()
        observer:start()
    end)
    if not started then
        stopDiaTabObserver()
    end
end

local function readBrowserTargetAsync(browser, callback)
    -- Never overlap reads. A slow browser used to stack synchronous work on
    -- Hammerspoon's main thread and delay all keyboard event processing.
    if browserReadTask then
        return
    end

    browserReadTask = hs.task.new("/usr/bin/osascript", function(exitCode, stdOut)
        browserReadTask = nil
        if exitCode == 0 then
            callback(parseBrowserTarget(browser, stdOut))
        end
        return true
    end, { "-e", browserReadScript(browser) })
    browserReadTask:start()
end

local function targetForWindow(window)
    if not window then
        return nil
    end

    local app = window:application()
    local windowID = window:id()
    if not app or not windowID then
        return nil
    end

    local browser = browserForApplication(app)
    if browser then
        -- Focus notifications must stay non-blocking. The browser timer will
        -- resolve the active tab asynchronously.
        return nil
    end

    -- Keep the allowlisted accessory app on the same identity path whether
    -- it is reported by the application watcher or by a focused-window
    -- event. This prevents two Spokenly entries in the MRU list.
    local switchable = targetForSwitchableApplication(app)
    if switchable then
        return switchable
    end

    local bundleID = app:bundleID() or app:name()
    return {
        kind = "window",
        key = "window:" .. tostring(bundleID) .. ":" .. tostring(windowID),
        windowID = windowID,
        bundleID = bundleID,
        appName = app:name(),
        title = window:title(),
    }
end

local function targetIsAvailable(target)
    if not target then
        return false
    end

    if target.kind == "application" then
        local app = hs.application.get(target.bundleID)
        return app ~= nil and #app:allWindows() > 0
    end

    if target.kind == "browserTab" then
        return hs.application.get(target.browser and target.browser.appID) ~= nil
    end

    local window = hs.window.get(target.windowID)
    if not window then
        return false
    end

    local app = window:application()
    if not app or (target.bundleID and app:bundleID() ~= target.bundleID) then
        return false
    end
    return hs.application.get(target.bundleID or app:bundleID()) ~= nil
end

local function pruneHistory()
    local cleaned = {}
    local seen = {}

    for _, target in ipairs(history) do
        target = normalizeTarget(target)
        if target and targetIsAvailable(target) and not seen[target.key] then
            table.insert(cleaned, target)
            seen[target.key] = true
        end
    end

    history = cleaned

    lastObservedTarget = normalizeTarget(lastObservedTarget)
    if lastObservedTarget and not targetIsAvailable(lastObservedTarget) then
        lastObservedKey = nil
        lastObservedTarget = nil
    end
end

-- Avoid an AppleScript round trip when the browser poll has already observed
-- the current tab. The poll may be up to POLL_INTERVAL old, which is a better
-- tradeoff for Command-Tab responsiveness than blocking the first key press.
local function currentTargetFast()
    local app = hs.application.frontmostApplication()
    if not app then
        return nil
    end

    local browser = browserForApplication(app)
    if browser then
        if lastObservedTarget
            and lastObservedTarget.kind == "browserTab"
            and lastObservedTarget.browser
            and lastObservedTarget.browser.appID == browser.appID then
            return copyTarget(lastObservedTarget)
        end
        return nil
    end

    local switchable = targetForSwitchableApplication(app)
    if switchable then
        return switchable
    end

    return targetForWindow(hs.window.frontmostWindow())
end

local function targetAppID(target)
    if target.kind == "browserTab" and target.browser then
        return target.browser.appID
    end
    return target.bundleID
end

local function targetAppName(target)
    if target.kind == "browserTab" and target.browser then
        return target.browser.name
    end
    return target.appName or "Application"
end

local function targetTitle(target)
    local title = target.title
    if title and title ~= "" then
        return title
    end
    return targetAppName(target)
end

local function targetIcon(target)
    local appID = targetAppID(target)
    if not appID then
        return nil
    end

    if iconCache[appID] == nil then
        iconCache[appID] = hs.image.imageFromAppBundle(appID) or false
    end

    return iconCache[appID] or nil
end

local function overlayScreen()
    if cycle and cycle.screen then
        return cycle.screen
    end
    return hs.screen.mainScreen()
end

local function overlayElements()
    if not cycle then
        return {}
    end

    local total = #cycle.order
    local visible = math.min(total, MAX_VISIBLE_ROWS)
    local selected = cycle.index
    local first = 1

    if total > visible then
        first = math.max(1, math.min(selected - math.floor(visible / 2), total - visible + 1))
    end

    local height = HEADER_HEIGHT + (visible * ROW_HEIGHT) + FOOTER_HEIGHT
    local screen = overlayScreen()
    local frame = screen:frame()
    local x = frame.x + math.floor((frame.w - OVERLAY_WIDTH) / 2)
    local y = frame.y + math.floor((frame.h - height) / 2)

    if not overlay then
        overlay = hs.canvas.new({ x = x, y = y, w = OVERLAY_WIDTH, h = height })
        overlay:level(hs.canvas.windowLevels.overlay)
        overlay:behaviorAsLabels({ "canJoinAllSpaces", "stationary" })
        overlay:clickActivating(false)
        overlay:mouseCallback(function(_, message, id)
            local rowIndex = tonumber(tostring(id):match("^row:(%d+)$"))
            if not rowIndex or not cycle or not cycle.order[rowIndex] then
                return
            end

            if message == "mouseDown" then
                cycle.index = rowIndex
                cycle.selected = cycle.order[rowIndex]
                scheduleOverlayUpdate()
            elseif message == "mouseUp" then
                cycle.index = rowIndex
                cycle.selected = cycle.order[rowIndex]
                finishCycle()
            end
        end)
    else
        overlay:frame({ x = x, y = y, w = OVERLAY_WIDTH, h = height })
    end

    local elements = {
        {
            type = "rectangle",
            frame = { x = 0, y = 0, w = OVERLAY_WIDTH, h = height },
            roundedRectRadii = { xRadius = 14, yRadius = 14 },
            fillColor = { white = 0.08, alpha = 0.97 },
            strokeColor = { white = 1.0, alpha = 0.16 },
            strokeWidth = 1,
            withShadow = true,
        },
        {
            type = "text",
            frame = { x = 24, y = 16, w = OVERLAY_WIDTH - 48, h = 24 },
            text = "Unified Command-Tab",
            textFont = "Helvetica Neue Medium",
            textSize = 18,
            textColor = { white = 1.0, alpha = 0.98 },
            textAlignment = "left",
        },
        {
            type = "text",
            frame = { x = 24, y = 42, w = OVERLAY_WIDTH - 48, h = 18 },
            text = string.format("%d of %d  •  Tab to continue  •  click a row or release Command to choose", selected, total),
            textFont = "Helvetica Neue",
            textSize = 11,
            textColor = { white = 1.0, alpha = 0.58 },
            textAlignment = "left",
        },
    }

    for offset = 0, visible - 1 do
        local index = first + offset
        local target = cycle.order[index]
        local rowY = HEADER_HEIGHT + (offset * ROW_HEIGHT)
        local isSelected = index == selected
        local icon = targetIcon(target)

        table.insert(elements, {
            type = "rectangle",
            id = "row:" .. tostring(index),
            frame = { x = 12, y = rowY, w = OVERLAY_WIDTH - 24, h = ROW_HEIGHT - 2 },
            roundedRectRadii = { xRadius = 7, yRadius = 7 },
            fillColor = isSelected
                and { red = 0.20, green = 0.43, blue = 0.86, alpha = 0.92 }
                or { white = 1.0, alpha = 0.04 },
            strokeColor = isSelected
                and { red = 0.48, green = 0.67, blue = 1.0, alpha = 0.95 }
                or { white = 1.0, alpha = 0.0 },
            strokeWidth = 1,
            trackMouseDown = true,
            trackMouseUp = true,
        })

        table.insert(elements, {
            type = "text",
            frame = { x = 24, y = rowY + 12, w = 20, h = 24 },
            text = isSelected and "▶" or "",
            textFont = "Helvetica Neue",
            textSize = 13,
            textColor = { white = 1.0, alpha = 0.95 },
            textAlignment = "center",
        })

        if icon then
            table.insert(elements, {
                type = "image",
                frame = { x = 54, y = rowY + 8, w = 32, h = 32 },
                image = icon,
                imageScaling = "scaleProportionally",
                imageAlignment = "center",
            })
        end

        table.insert(elements, {
            type = "text",
            frame = { x = 100, y = rowY + 6, w = OVERLAY_WIDTH - 124, h = 18 },
            text = targetAppName(target),
            textFont = "Helvetica Neue Medium",
            textSize = 12,
            textColor = { white = 1.0, alpha = isSelected and 0.98 or 0.75 },
            textLineBreak = "truncateTail",
            textAlignment = "left",
        })

        table.insert(elements, {
            type = "text",
            frame = { x = 100, y = rowY + 24, w = OVERLAY_WIDTH - 124, h = 17 },
            text = targetTitle(target),
            textFont = "Helvetica Neue",
            textSize = 11,
            textColor = { white = 1.0, alpha = isSelected and 0.88 or 0.55 },
            textLineBreak = "truncateMiddle",
            textAlignment = "left",
        })
    end

    local footer = ""
    if first > 1 then
        footer = "↑ " .. tostring(first - 1) .. " more  "
    end
    if first + visible <= total then
        footer = footer .. "↓ " .. tostring(total - first - visible + 1) .. " more"
    end

    table.insert(elements, {
        type = "text",
        frame = { x = 24, y = height - 28, w = OVERLAY_WIDTH - 48, h = 18 },
        text = footer,
        textFont = "Helvetica Neue",
        textSize = 10,
        textColor = { white = 1.0, alpha = 0.48 },
        textAlignment = "center",
    })

    return elements
end

local function updateOverlay()
    if not cycle then
        return
    end

    local elements = overlayElements()
    overlay:replaceElements(elements)
    if not overlayVisible then
        overlay:show()
        overlay:bringToFront(false)
        overlayVisible = true
    end
end

scheduleOverlayUpdate = function()
    if overlayUpdateTimer then
        overlayUpdateTimer:stop()
    end

    -- Let the key event return before doing the canvas work. This keeps Tab
    -- repeat responsive while the overlay catches up on the next run-loop
    -- turn. Coalescing also prevents a rapid burst of Tab presses from
    -- queueing one full redraw per key.
    overlayUpdateTimer = hs.timer.doAfter(0, function()
        overlayUpdateTimer = nil
        updateOverlay()
    end)
end

local function hideOverlay()
    if overlayUpdateTimer then
        overlayUpdateTimer:stop()
        overlayUpdateTimer = nil
    end

    if overlay then
        overlay:hide()
        overlayVisible = false
    end
end

local function selectBrowserTarget(target)
    local browser = target.browser
    local script

    if browser.mode == "chrome" then
        script = string.format([[
using terms from application "Google Chrome"
tell application id %s
    set wantedWindowID to %s
    set wantedTabIndex to %d

    -- The usual path: the target tab's window is still the same window.
    try
        set theWindow to first window whose id is wantedWindowID
        if wantedTabIndex is greater than 0 and wantedTabIndex is less than or equal to (count of tabs of theWindow) then
            if (id of tab wantedTabIndex of theWindow as text) is %s then
                set index of theWindow to 1
                set active tab index of theWindow to wantedTabIndex
                return true
            end if
        end if
    end try

    -- Fallback for a tab that was moved to another window.
    repeat with theWindow in windows
        repeat with i from 1 to (count of tabs of theWindow)
            if (id of tab i of theWindow as text) is %s then
                set index of theWindow to 1
                set active tab index of theWindow to i
                return true
            end if
        end repeat
    end repeat
    return false
end tell
end using terms from
]], quoteAppleScriptString(browser.appID), quoteAppleScriptString(target.windowID),
            target.tabIndex or 1, quoteAppleScriptString(target.tabID), quoteAppleScriptString(target.tabID))
    else
        -- Dia's scripting dictionary exposes `focus tab`, which also brings
        -- the tab's window forward.
        script = string.format([[
tell application id %s
    set wantedWindowID to %s

    -- Dia exposes a stable text window ID, so avoid walking every window
    -- when the tab is still in its original window.
    try
        set theWindow to first window whose id is wantedWindowID
        repeat with theTab in tabs of theWindow
            if (id of theTab as text) is %s then
                focus theTab
                return true
            end if
        end repeat
    end try

    -- Fallback for a tab that was moved to another window.
    repeat with theWindow in windows
        repeat with theTab in tabs of theWindow
            if (id of theTab as text) is %s then
                focus theTab
                return true
            end if
        end repeat
    end repeat
    return false
end tell
]], quoteAppleScriptString(browser.appID), quoteAppleScriptString(target.windowID),
            quoteAppleScriptString(target.tabID), quoteAppleScriptString(target.tabID))
    end

    local ok, result = hs.osascript.applescript(script)
    return ok and (result == true or result == "true")
end

local function selectTarget(target)
    if not target then
        return false
    end

    if target.kind == "browserTab" then
        return selectBrowserTarget(target)
    end

    if target.kind == "application" then
        local app = hs.application.get(target.bundleID)
        if app then
            app:activate()
            return true
        end
        return false
    end

    local window = hs.window.get(target.windowID)
    if window then
        window:focus()
        return true
    end

    local app = hs.application.get(target.appName or target.bundleID)
    if app then
        app:activate()
        return true
    end

    return false
end

local function moveWithinCycle()
    if not cycle or #cycle.order == 0 then
        return false
    end

    local count = #cycle.order
    for _ = 1, count do
        cycle.index = ((cycle.index - 1 + cycle.direction) % count) + 1
        local candidate = cycle.order[cycle.index]

        -- Selection is intentionally deferred until Command is released.
        -- While cycling, we only move the highlight in the snapshot so the
        -- browser/app does not have to activate every intermediate target.
        cycle.selected = candidate
        scheduleOverlayUpdate()
        return true
    end

    return false
end

local function beginCycle(direction)
    local current = currentTargetFast()
    if current then
        remember(current)
    end

    if #history < 2 then
        return false
    end

    local order = {}
    for i, target in ipairs(history) do
        order[i] = copyTarget(target)
    end

    cycle = {
        order = order,
        -- history[1] is the current target. The first Command-Tab moves
        -- directly to history[2], without focusing it yet.
        index = 1,
        direction = direction,
        selected = nil,
        screen = (hs.window.frontmostWindow() and hs.window.frontmostWindow():screen()) or hs.screen.mainScreen(),
    }

    if not moveWithinCycle() then
        cycle = nil
        return false
    end

    -- Refresh titles for all known browser tabs in the background. A tab's
    -- identity is stable while its title can change after navigation, so this
    -- repairs entries that were first seen as "Untitled" without blocking the
    -- Command-Tab key event.
    refreshBrowserMetadataAsync()

    -- Defer the initial canvas work until after the event callback returns.
    -- This keeps Hammerspoon out of the keyboard delivery path.
    if overlayUpdateTimer then
        overlayUpdateTimer:stop()
        overlayUpdateTimer = nil
    end
    scheduleOverlayUpdate()

    return true
end

finishCycle = function()
    hideOverlay()

    if cycle and cycle.selected then
        -- Perform exactly one activation, after the user has released
        -- Command. This is the only target-selection operation during a
        -- cycle.
        if selectTarget(cycle.selected) then
            remember(cycle.selected)
        end
    end
    cycle = nil
end

local function toggleEnabled()
    enabled = not obj:isEnabled()
    hs.settings.set(SETTINGS_KEY, enabled)

    if not enabled then
        finishCycle()
    end

    if menuRefresh then
        menuRefresh()
    end

    hs.alert.show("Unified Command-Tab " .. (enabled and "enabled" or "disabled"))
end

function obj:isEnabled()
    return enabled
end

function obj:setMenuRefresh(fn)
    menuRefresh = fn
end

function obj:addMenuItems(items)
    table.insert(items, { title = "-" })
    table.insert(items, {
        title = "Unified ⌘Tab: " .. (self:isEnabled() and "On" or "Off"),
        checked = self:isEnabled(),
        fn = toggleEnabled,
    })
    table.insert(items, {
        title = "Unified ⌘Tab includes Chrome + Dia tabs + Spokenly",
        disabled = true,
    })
    return items
end

function obj:start()
    if eventTap then
        return self
    end

    local persistedEnabled = hs.settings.get(SETTINGS_KEY)
    enabled = persistedEnabled == nil or persistedEnabled == true

    windowFilter = hs.window.filter.new()
    windowFilter:subscribe(hs.window.filter.windowFocused, function(window)
        if cycle then
            return
        end
        local app = window and window:application()
        if app and app:bundleID() == BROWSERS["company.thebrowser.dia"].appID then
            ensureDiaTabObserver()
        end
        observe(targetForWindow(window))
    end)
    windowFilter:subscribe(hs.window.filter.windowDestroyed, function(window)
        local app = window and window:application()
        local windowID = window and window:id()
        local bundleID = app and app:bundleID()
        if windowID or bundleID == "app.spokenly" then
            forgetTargets(function(target)
                return (windowID and target.kind == "window" and target.windowID == windowID)
                    or (bundleID == "app.spokenly" and target.bundleID == bundleID)
            end)
        end
    end)
    windowFilter:subscribe(hs.window.filter.windowNotVisible, function(window)
        local app = window and window:application()
        if app and app:bundleID() == "app.spokenly" then
            pruneHistory()
        end
    end)

    -- Keep this exception limited to explicitly allowlisted accessory apps.
    applicationWatcher = hs.application.watcher.new(function(appName, event)
        if event == hs.application.watcher.terminated then
            if appName == BROWSERS["company.thebrowser.dia"].name then
                stopDiaTabObserver()
            end
            forgetTargets(function(target)
                return target.appName == appName
                    or (target.browser and target.browser.name == appName)
            end)
            return
        end

        if event == hs.application.watcher.activated
            or event == hs.application.watcher.launched then
            local app = hs.application.get(appName)
            if app and app:bundleID() == BROWSERS["company.thebrowser.dia"].appID then
                ensureDiaTabObserver()
            end
            observe(targetForSwitchableApplication(app))
        end
    end)
    applicationWatcher:start()
    observe(targetForSwitchableApplication(hs.application.get("app.spokenly")))
    ensureDiaTabObserver()

    browserTimer = hs.timer.doEvery(POLL_INTERVAL, function()
        if cycle or not enabled then
            return
        end

        if hs.timer.secondsSinceEpoch() - lastBrowserMetadataReadAt >= BROWSER_METADATA_INTERVAL then
            refreshBrowserMetadataAsync()
        end

        local app = hs.application.frontmostApplication()
        local browser = browserForApplication(app)
        if browser then
            local metadataGeneration = browserMetadataGeneration
            readBrowserTargetAsync(browser, function(target)
                -- The async result may arrive after focus changed.
                local currentApp = hs.application.frontmostApplication()
                if not cycle
                    and enabled
                    and metadataGeneration == browserMetadataGeneration
                    and browserForApplication(currentApp) == browser then
                    observe(target)
                end
            end)
        end
    end)

    eventTap = hs.eventtap.new({
        hs.eventtap.event.types.keyDown,
        hs.eventtap.event.types.keyUp,
        hs.eventtap.event.types.flagsChanged,
    }, function(event)
        if not enabled then
            return false
        end

        local eventType = event:getType()

        -- End the custom switcher when Command is released. This matches the
        -- native switcher's commit behavior and handles either release order.
        if eventType == hs.eventtap.event.types.flagsChanged then
            if cycle and not event:getFlags().cmd then
                finishCycle()
            end
            return false
        end

        if event:getKeyCode() ~= hs.keycodes.map.tab then
            return false
        end

        if eventType == hs.eventtap.event.types.keyUp then
            if cycle or suppressNextTabUp then
                suppressNextTabUp = false
                return true
            end
            return false
        end

        local flags = event:getFlags()
        if not flags.cmd or flags.alt or flags.ctrl or flags.fn then
            return false
        end

        local direction = flags.shift and -1 or 1

        if not cycle then
            if not beginCycle(direction) then
                return false
            end
        else
            cycle.direction = direction
            moveWithinCycle()
        end

        suppressNextTabUp = true
        -- Suppress macOS's native application switcher.
        return true
    end)

    eventTap:start()
    return self
end

function obj:stop()
    browserMetadataReadGeneration = browserMetadataReadGeneration + 1
    pendingBrowserMetadataReads = {}
    stopDiaTabObserver()
    if eventTap then
        eventTap:stop()
        eventTap = nil
    end
    if browserTimer then
        browserTimer:stop()
        browserTimer = nil
    end
    if browserReadTask then
        browserReadTask:terminate()
        browserReadTask = nil
    end
    if browserMetadataReadTask then
        browserMetadataReadTask:terminate()
        browserMetadataReadTask = nil
    end
    if windowFilter then
        windowFilter:unsubscribeAll()
        windowFilter = nil
    end
    if applicationWatcher then
        applicationWatcher:stop()
        applicationWatcher = nil
    end
    finishCycle()
end

return obj
