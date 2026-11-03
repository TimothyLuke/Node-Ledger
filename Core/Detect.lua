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
-- A node you can mouse over in the world is usually within this many yards.
local WORLD_HOVER_YARDS = 40
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

local function mouseOverWorld()
    local focus
    if GetMouseFoci then
        focus = GetMouseFoci()[1]
    elseif GetMouseFocus then
        focus = GetMouseFocus()
    end
    return focus == WorldFrame
end

--- The game won't say where a hovered object is, only that you can see it,
-- so it's recorded at your feet as a rough sighting for better sources to
-- correct. Not shared: it's too coarse to be worth anyone else's ring.
local function recordWorldHover(name, objectID)
    local kind = Store.ObjectKind(objectID) or Names.KindOf(name)
    if not kind then
        Util.Debug(string.format("World hover: %s (object %s) isn't a node", name, tostring(objectID)))
        return
    end
    local mapID, x, y, w, h = Geo.PlayerPosition()
    if not mapID then
        Util.Debug("World hover skipped: " .. Geo.WhyNoPosition())
        return
    end
    local _, isNew =
        Store.Observe(mapID, x, y, kind, name, "world", w, h, Util.Now(), objectID, WORLD_HOVER_YARDS)
    Util.Debug(string.format("%s %s from world hover: %s", isNew and "New" or "Seen", kind, name))
    if isNew then
        NL.Changed()
    end
end

--- Retail fills world object tooltips through the tooltip data system, which
-- names the object and gives its GUID, so no guessing from the tooltip owner.
local function onTooltipData(tooltip, data)
    if tooltip ~= GameTooltip or not data or data.type ~= Enum.TooltipDataType.Object then
        return
    end
    if Minimap:IsMouseOver() then
        return
    end
    local line = data.lines and data.lines[1]
    local text = line and line.leftText
    if not text or IsSecret(text) or text == "" then
        return
    end
    local name = Util.StripCodes(text)
    local guid = data.guid
    local objectID = guid and not IsSecret(guid) and Util.ObjectIDFromGUID(guid) or nil
    -- The tooltip is refreshed while it stays up; that's still the one hover.
    local again = worldTip and worldTip.name == name and GetTime() - worldTip.t < WORLD_TIP_SECONDS
    worldTip = {name = name, t = GetTime()}
    if not again then
        recordWorldHover(name, objectID)
    end
end

--- A tooltip on the default anchor with no unit behind it is a world object
-- under the cursor: remember its name.
local function onTooltipShow(tooltip)
    -- Retail's minimap blip tooltip is owned by UIParent too.
    if tooltip:GetOwner() ~= UIParent or UnitExists("mouseover") or Minimap:IsMouseOver() then
        return
    end
    local line = _G[tooltip:GetName() .. "TextLeft1"]
    local text = line and line:GetText()
    if not text or IsSecret(text) then
        return
    end
    local name = Util.StripCodes(text)
    worldTip = {name = name, t = GetTime()}
    -- Recording needs more certainty than naming the next loot does.
    if mouseOverWorld() then
        recordWorldHover(name)
    end
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
    local castKind = cast and cast.kind
    local kind, name = classify(objectID, fishing)
    cast = nil
    Util.Debug(
        string.format(
            "Loot: object %s, cast %s, fishing %s -> %s %s",
            tostring(objectID), tostring(castKind), tostring(fishing), tostring(kind), tostring(name)
        )
    )
    if not kind then
        return
    end
    local mapID, x, y, w, h = Geo.PlayerPosition()
    if not mapID then
        Util.Debug("Loot skipped: " .. Geo.WhyNoPosition())
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
    local items = readLoot()
    Store.AddHaul(node, name, items)
    local entry = {
        mapID = mapID,
        x = x,
        y = y,
        kind = kind,
        source = "gather",
        name = name,
        objectID = objectID,
        items = items
    }
    NL.Share.Queue(entry)
    moneyPending = {node = node, name = name, money = GetMoney(), entry = entry}
    Util.Debug(
        string.format("%s %s: %s at %.4f,%.4f (map %d)", isNew and "New" or "Gathered", kind, name or "?", x, y, mapID)
    )
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
                -- Still queued: the share flush is well after this.
                pending.entry.money = gained
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
                        local _, _, fresh =
                            Store.Observe(mapID, x, y, "treasure", info.name, "vignette", w, h, Util.Now(), objectID)
                        if fresh then
                            NL.Share.Queue(
                                {
                                    mapID = mapID,
                                    x = x,
                                    y = y,
                                    kind = "treasure",
                                    source = "vignette",
                                    name = info.name,
                                    objectID = objectID
                                }
                            )
                        end
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
    if TooltipDataProcessor and Enum.TooltipDataType and Enum.TooltipDataType.Object then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Object, onTooltipData)
    else
        GameTooltip:HookScript("OnShow", onTooltipShow)
    end
end
