-- Isolated Lua-only work measurement. No browser calls or live switcher changes.
-- hs -c 'dofile(".../scripts/benchmark_reconciliation.lua")(".../baseline/init.lua", ".../candidate/init.lua")'
local source = debug.getinfo(1, "S").source:sub(2)
local root = assert(source:match("^(.*)/scripts/[^/]+$"), "use an absolute script path")
local factory = dofile(root .. "/tests/support/mock_hs.lua")

return function(baseline, candidate)
    assert(not debug.gethook(), "run without another Lua debug hook")
    local snapshot = {}
    for i = 1, 1000 do
        snapshot[i] = string.format("window|tab-%d|%d|Title %d", i, i, i)
    end
    snapshot = table.concat(snapshot, "\n")

    local function measure(path)
        local f = factory(path)
        for i = 1, 100 do
            f:observeBrowser("com.google.Chrome", "window", "tab-" .. i, "Before " .. i, i)
        end
        assert(f:key("keyDown", {cmd=true}))
        f:flush()
        local instructions = 0
        debug.sethook(function() instructions = instructions + 1000 end, "", 1000)
        local start = os.clock()
        local ok, err = pcall(function()
            f:complete(f:task("metadata", "com.google.Chrome"), snapshot)
        end)
        local seconds = os.clock() - start
        debug.sethook()
        f:stop()
        assert(ok, err)
        return instructions, seconds * 1000
    end

    local before, beforeMS = measure(baseline)
    local after, afterMS = measure(candidate)
    print(string.format("Reconcile 1000 tabs against 100 history + 100 cycle entries: baseline ~%d instructions (%.2f ms); candidate ~%d (%.2f ms); %.1fx fewer instructions",
        before, beforeMS, after, afterMS, before / after))
    return {baselineInstructions=before, candidateInstructions=after}
end
