-- Minimal WoW environment for the pure layers (no frames, no UI).
local helper = {}

function helper.load()
    _G.NodeLedger = {
        Compat = {
            GetSpellName = function()
                return nil
            end,
            IsSecret = function()
                return false
            end
        },
        L = setmetatable({}, {__index = function(_, k)
                    return k
                end})
    }
    _G.NodeLedgerDB = nil
    for _, f in ipairs({"Store", "Names"}) do
        dofile("Core/" .. f .. ".lua")
    end
    NodeLedger.Store.Init()
    return NodeLedger
end

-- A 1000 x 1000 yard map: 0.001 of map is one yard.
helper.W, helper.H = 1000, 1000

return helper
