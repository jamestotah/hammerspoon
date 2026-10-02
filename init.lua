-- Hammerspoon configuration
-- Uses ArrangeDesktop spoon to save and restore window layouts per monitor setup.

-- Make the `hs` command-line client available for future configuration changes.
pcall(function()
    require("hs.ipc")
    hs.ipc.cliInstall(os.getenv("HOME") .. "/.local/bin", true)
end)

-- Permit the `hs` CLI and AppleScript to reload/evaluate this configuration.
hs.allowAppleScript(true)

hs.loadSpoon("ArrangeDesktop")

-- Treat Chrome/Dia tabs and Spokenly as MRU entries for Command-Tab.
local unifiedCmdTab = dofile(hs.configdir .. "/unified_cmd_tab.lua")
unifiedCmdTab:start()

-- Add a menubar menu with your saved arrangements
local menubar = hs.menubar.new()
local unifiedCmdTabMenubar = hs.menubar.new()

local function updateMenu()
    local switcherItems = {}
    unifiedCmdTab:addMenuItems(switcherItems)
    unifiedCmdTabMenubar:setMenu(switcherItems)

    local items = {
        { title = "Save current arrangement", fn = function()
            spoon.ArrangeDesktop:createArrangement()
            updateMenu()
            hs.alert.show("Arrangement saved!")
        end },
        { title = "-" },
    }
    spoon.ArrangeDesktop:addMenuItems(items)
    menubar:setMenu(items)
end

menubar:setTitle("⊞")
unifiedCmdTabMenubar:setTitle("⌘Tab")
unifiedCmdTab:setMenuRefresh(updateMenu)
updateMenu()

-- Automatically reapply the first saved arrangement when screens change
-- (e.g. when you plug/unplug an external display)
local screenWatcher = hs.screen.watcher.new(function()
    hs.timer.doAfter(2, function()  -- wait 2s for screens to settle
        local arrangements = spoon.ArrangeDesktop.arrangements
        if arrangements and #arrangements > 0 then
            hs.alert.show("Display changed — reapplying: " .. (arrangements[1].name or "arrangement 1"))
            spoon.ArrangeDesktop:arrange(arrangements[1])
        else
            hs.alert.show("Display changed — no saved arrangement yet.\nUse the ⊞ menu to save one.")
        end
    end)
end)
screenWatcher:start()

hs.alert.show("Hammerspoon loaded")
