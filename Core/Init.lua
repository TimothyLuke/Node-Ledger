local addonName = ...

-- Node Ledger uses no libraries: events, tooltips, map pins and timers are all native.
NodeLedger = {}
local NL = NodeLedger

NL.addonName = addonName or "node-ledger"

-- Locale: Localization/enUS.lua is the master phrase list and other locales
-- override it. `L[phrase] = true` means the value is the key, and a missing
-- key shows the key rather than erroring.
NL.L =
    setmetatable(
    {},
    {
        __index = function(t, k)
            rawset(t, k, k)
            return k
        end,
        __newindex = function(t, k, v)
            rawset(t, k, v == true and k or v)
        end
    }
)

local GetAddOnMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
NL.VersionString = GetAddOnMetadata(NL.addonName, "Version") or "dev"
--@debug@
if NL.VersionString:find("@project", 1, true) then
    NL.VersionString = "dev"
end
--@end-debug@

-- WoW Forever runs vanilla content (1.60.x) on the Retail API surface, so the
-- same code serves both; IsForever is only for content differences.
local FOREVER_MAJOR, FOREVER_MIN_MINOR = 1, 60
local gameVersion = GetBuildInfo()
local major, minor = gameVersion:match("^(%d+)%.(%d+)")
major, minor = tonumber(major), tonumber(minor)
NL.IsForever = major == FOREVER_MAJOR and minor ~= nil and minor >= FOREVER_MIN_MINOR

-- The four kinds of node and the ring colour each is drawn in.
NL.Kinds = {"mine", "herb", "fish", "treasure"}
NL.KindColors = {
    mine = {0.65, 0.42, 0.18},
    herb = {0.20, 0.85, 0.25},
    fish = {0.25, 0.60, 1.00},
    treasure = {0.70, 0.30, 0.95}
}
-- Inner ring on spawn points that have shown more than one node (Mithril/Truesilver).
NL.VariantColor = {1.00, 0.82, 0.00}

NL.Media = {
    Ring = "Interface\\AddOns\\" .. NL.addonName .. "\\Media\\Ring"
}

-- API shims across the clients we load on.
NL.Compat = {
    GetSpellName = (C_Spell and C_Spell.GetSpellName) or function(spellID)
            return (GetSpellInfo(spellID))
        end,
    GetItemName = (C_Item and C_Item.GetItemNameByID) or function(itemID)
            return (GetItemInfo(itemID))
        end,
    GetCVar = (C_CVar and C_CVar.GetCVar) or GetCVar,
    -- Midnight hands addons "secret" values in some restricted contexts. Any
    -- operation on one errors, so values from the client are checked first.
    IsSecret = issecretvalue or function()
            return false
        end
}

-- Events: one handler per event, called as handler(event, ...).
local eventFrame = CreateFrame("Frame")
local handlers = {}
eventFrame:SetScript(
    "OnEvent",
    function(_, event, ...)
        local handler = handlers[event]
        if handler then
            handler(event, ...)
        end
    end
)

function NL:RegisterEvent(event, handler)
    handlers[event] = handler
    eventFrame:RegisterEvent(event)
end

function NL:UnregisterEvent(event)
    handlers[event] = nil
    eventFrame:UnregisterEvent(event)
end

--- Registers an event only if this client knows it; a frame errors on an unknown one.
function NL:RegisterEventIfExists(event, handler)
    if C_EventUtils and C_EventUtils.IsEventValid then
        if not C_EventUtils.IsEventValid(event) then
            return false
        end
    else
        local ok = pcall(eventFrame.RegisterEvent, eventFrame, event)
        if not ok then
            return false
        end
    end
    self:RegisterEvent(event, handler)
    return true
end

-- Lifecycle: OnInitialize once our saved variables are loaded, OnEnable at
-- login when the rest of the UI is up.
NL:RegisterEvent(
    "ADDON_LOADED",
    function(_, name)
        if name == NL.addonName then
            NL:UnregisterEvent("ADDON_LOADED")
            NL:OnInitialize()
        end
    end
)
NL:RegisterEvent(
    "PLAYER_LOGIN",
    function()
        NL:UnregisterEvent("PLAYER_LOGIN")
        NL:OnEnable()
    end
)
