local NL = NodeLedger
local Util = NL.Util
local Store = NL.Store
local Names = NL.Names
local Geo = NL.Geo
local IsSecret = NL.Compat.IsSecret

-- Nodes found by doing: gathering, fishing and opening chests (with what came
-- out of them), plus retail treasure vignettes. Minimap hover is in Minimap.lua.
NL.Detect = {}
local Detect = NL.Detect

-- How long a gather cast stays the explanation for the loot that follows.
local CAST_SECONDS = 10
-- How long a moused-over world object's name stays a candidate for its loot
-- (no cast for instant-loot treasures, and none naming the pool for fishing).
local WORLD_TIP_SECONDS = 30
-- The bobber is a game object too; loot from it is open water, not a pool.
local BOBBER_OBJECT_ID = 35591
-- A bobber lands about this far in front of you, so that's where the pool is.
local CAST_DISTANCE = 17
-- Coins arrive a moment after the loot window closes.
local MONEY_DELAY = 0.5
local VIGNETTE_DELAY = 0.5

local LOOT_SLOT_ITEM = (Enum and Enum.LootSlotType and Enum.LootSlotType.Item) or 1

local cast -- {kind, name, castGUID, t}
local worldTip -- {name, t}
local lootHandled = false
local moneyPending -- {node, name, money}
local vignetteQueued = false
local seenVignettes = {}

local function recent(entry, seconds)
    return entry and GetTime() - entry.t <= seconds and entry or nil
end

-- Casts ------------------------------------------------------------------------

function Detect.OnSpellcastSent(_, unit, target, castGUID, spellID)
    if unit ~= "player" then
        return
    end
    local kind = Names.SpellKind(spellID)
    if not kind then
        return
    end
    if IsSecret(target) or Util.IsEmpty(target) then
        target = nil
    end
    cast = {kind = kind, name = target, castGUID = castGUID, t = GetTime()}
end

function Detect.OnSpellcastFailed(_, unit, castGUID)
    if unit == "player" and cast and cast.castGUID == castGUID then
        cast = nil
    end
end

-- World object tooltips ----------------------------------------------------------

--- A tooltip on the default anchor with no unit behind it is a world object
-- under the cursor: remember its name.
local function onTooltipShow(tooltip)
    if tooltip:GetOwner() ~= UIParent or UnitExists("mouseover") then
        return
    end
    local line = _G[tooltip:GetName() .. "TextLeft1"]
    local text = line and line:GetText()
    if not text or IsSecret(text) then
        return
    end
    worldTip = {name = Util.StripCodes(text), t = GetTime()}
end

-- Loot ---------------------------------------------------------------------------

--- The object ID of the game object being looted, or nil for a creature.
local function lootObjectID()
    for slot = 1, GetNumLootItems() do
        local guid = GetLootSourceInfo(slot)
        if guid and not IsSecret(guid) then
            return Util.ObjectIDFromGUID(guid)
        end
    end
    return nil
end

--- items[itemID] = quantity for what's in the loot window.
local function readLoot()
    local items = {}
    for slot = 1, GetNumLootItems() do
        if GetLootSlotType(slot) == LOOT_SLOT_ITEM then
            local itemID = Util.ItemIDFromLink(GetLootSlotLink(slot))
            local _, name, quantity = GetLootSlotInfo(slot)
            if itemID and not IsSecret(itemID) then
                items[itemID] = (items[itemID] or 0) + (quantity or 1)
                if not IsSecret(name) then
                    Store.RememberItemName(itemID, name)
                end
            end
        end
    end
    return items
end

--- kind, name for this loot, or nil when it isn't a node.
local function classify(objectID, fishing)
    local gather = recent(cast, CAST_SECONDS)
    local tipName = recent(worldTip, WORLD_TIP_SECONDS) and worldTip.name or nil
    if fishing then
        local tipIsPool = Names.KindOf(tipName) == "fish"
        if objectID == BOBBER_OBJECT_ID or not objectID then
            -- Open water, unless we just moused over a pool.
            if not tipIsPool then
                return nil
            end
        end
        return "fish", tipIsPool and tipName or nil
    end
    if not objectID then
        return nil
    end
    if gather and (gather.kind == "herb" or gather.kind == "mine") then
        return gather.kind, gather.name or tipName
    end
    local name = (gather and gather.name) or tipName
    local kind = Store.ObjectKind(objectID) or Names.KindOf(name)
    if kind == "herb" or kind == "mine" or kind == "treasure" then
        return kind, name
    end
    -- An Opening cast that produced loot from an object we don't know: a chest.
    if gather and gather.kind == "open" then
        return "treasure", name
    end
    return nil
end

function Detect.OnLootReady()
    if lootHandled then
        return
    end
    lootHandled = true
    local objectID = lootObjectID()
    local fishing = IsFishingLoot and IsFishingLoot()
    local kind, name = classify(objectID, fishing)
    cast = nil
    if not kind then
        return
    end
    local mapID, x, y, w, h = Geo.PlayerPosition()
    if not mapID then
        return
    end
    if kind == "fish" then
        local facing = Geo.Facing()
        if facing then
            x, y = Geo.Ahead(x, y, w, h, facing, CAST_DISTANCE)
        end
        if objectID == BOBBER_OBJECT_ID then
            objectID = nil
        end
    end
    local node, isNew = Store.Observe(mapID, x, y, kind, name, "gather", w, h, Util.Now(), objectID)
    name = name or node.lastName
    Store.AddHaul(node, name, readLoot())
    moneyPending = {node = node, name = name, money = GetMoney()}
    Util.Debug(string.format("%s %s: %s", isNew and "New" or "Gathered", kind, name or "?"))
    NL.Changed()
end

function Detect.OnLootClosed()
    lootHandled = false
    local pending = moneyPending
    moneyPending = nil
    if not pending then
        return
    end
    C_Timer.After(
        MONEY_DELAY,
        function()
            local gained = GetMoney() - pending.money
            if gained > 0 then
                Store.AddMoney(pending.node, pending.name, gained)
            end
        end
    )
end

-- Vignettes ----------------------------------------------------------------------

local function isTreasureVignette(info)
    local atlas = info.atlasName
    if not atlas or IsSecret(atlas) then
        return false
    end
    atlas = atlas:lower()
    return atlas:find("loot", 1, true) ~= nil or atlas:find("treasure", 1, true) ~= nil
end

--- Treasure vignettes carry an exact position, so they are recorded as soon
-- as they appear, gathered or not.
function Detect.ScanVignettes()
    vignetteQueued = false
    if not (C_VignetteInfo and C_VignetteInfo.GetVignettes) then
        return
    end
    local mapID, _, _, w, h = Geo.PlayerPosition()
    if not mapID then
        return
    end
    local changed = false
    for _, guid in ipairs(C_VignetteInfo.GetVignettes() or {}) do
        if not IsSecret(guid) and not seenVignettes[guid] then
            local info = C_VignetteInfo.GetVignetteInfo(guid)
            if info and isTreasureVignette(info) then
                local pos = C_VignetteInfo.GetVignettePosition(guid, mapID)
                if pos then
                    local x, y = pos:GetXY()
                    if not IsSecret(x) and not IsSecret(info.name) then
                        seenVignettes[guid] = true
                        local objectID = not IsSecret(info.objectGUID) and Util.ObjectIDFromGUID(info.objectGUID) or nil
                        Store.Observe(mapID, x, y, "treasure", info.name, "vignette", w, h, Util.Now(), objectID)
                        changed = true
                    end
                end
            end
        end
    end
    if changed then
        NL.Changed()
    end
end

function Detect.QueueVignetteScan()
    if not vignetteQueued then
        vignetteQueued = true
        C_Timer.After(VIGNETTE_DELAY, Detect.ScanVignettes)
    end
end

function Detect.Init()
    GameTooltip:HookScript("OnShow", onTooltipShow)
end
