-- Safe in a running Hammerspoon: every test, including its dofile calls, gets
-- private globals. No test replaces the live hs table or loads the live config.
-- hs -c 'dofile("/Users/totah/.agents/worktrees/hammerspoon/unified-command-tab/tests/run.lua")'
-- Also works with Lua 5.2+ from any working directory: lua tests/run.lua
local source = debug.getinfo(1, "S").source:sub(2)
local directory = source:match("^(.*)/[^/]+$") or "."
if directory:sub(1, 1) ~= "/" then directory = "./" .. directory end
local hostGlobals, liveHS = _G, hs

local function run(filename)
    local environment = setmetatable({}, { __index = function(_, key)
        if key ~= "hs" then return hostGlobals[key] end
    end })
    environment._G = environment
    environment.dofile = function(path)
        return assert(loadfile(path, "t", environment))()
    end
    local ok, err = xpcall(function()
        environment.dofile(directory .. "/" .. filename)
    end, debug.traceback)
    assert(hostGlobals.hs == liveHS, "test replaced live hs globals")
    if not ok then error(err, 0) end
end

run("unified_cmd_tab_test.lua")
run("unified_cmd_tab_behavior_test.lua")
print("Unified Command-Tab private test runner: PASS (live hs unchanged)")
