local NL = NodeLedger
local Util = NL.Util
local Store = NL.Store
local Names = NL.Names
local Geo = NL.Geo
local IsSecret = NL.Compat.IsSecret

-- Rings around known nodes on the minimap, and nodes found by hovering the
-- minimap.
--
-- The client draws tracking blips itself and gives addons no list of them.
-- What it does give is the blip's tooltip: hovering a blip shows its name(s)
-- on GameTooltip, owned by Minimap. From the cursor's offset, the zoom level
-- and the player's position we work out where that node is and record it.
--
-- The rings never take the mouse, so they can't get in the way of that
-- hover. Instead this file watches the cursor and, over a ring, either adds
-- the node's lines to the blip tooltip or shows one of its own.
NL.Minimap = {}
local MM = NL.Minimap

local UPDATE_INTERVAL = 0.05
local HOVER_INTERVAL = 0.1
-- How close (pixels) the cursor must be to a ring to show its node.
local HOVER_PIXELS = 8
-- A hover is recorded where the cursor is, not at the blip's centre, so it
-- lands up to half a blip from the node. Retail's gathering blips are about
-- 24px across, twice the old minimap's.
local HOVER_ERROR_PIXELS = 12
-- The cursor counts as resting on a blip once it has moved no more than this
-- many pixels per frame for this long.
local HOVER_STILL_PIXELS = 1
local HOVER_SETTLE_SECONDS = 0.15
-- Rings past the minimap's edge by up to this factor of its radius are
-- considered before the exact circle/square test.
local SQUARE_REACH = 1.42

local pins = {}
local shownCount = 0
local ownTip = false
local lastBlipText
-- Set when we add to GameTooltip, cleared whenever it's cleared: whether the
-- blip tooltip already has our lines, and which node our own tooltip shows.
local annotated = false
local ownNode
-- Retail builds the blip tooltip itself every frame; see onMinimapMouseover.
-- It may not when there's no blip under the cursor, so once it goes quiet the
-- polling below shows bare rings itself.
local mouseoverHooked = false
local lastMouseoverTime = 0
local MOUSEOVER_QUIET_SECONDS = 0.2

local function acquirePin(i)
    local pin = pins[i]
    if pin then
        return pin
    end
    pin = CreateFrame("Frame", nil, Minimap)
    pin:SetFrameLevel(Minimap:GetFrameLevel() + 5)
    pin.ring = pin:CreateTexture(nil, "OVERLAY")
    pin.ring:SetAllPoints()
    pin.ring:SetTexture(NL.Media.Ring)
    pin.variant = pin:CreateTexture(nil, "OVERLAY")
    pin.variant:SetPoint("CENTER")
    pin.variant:SetTexture(NL.Media.Ring)
    pin.variant:SetVertexColor(NL.VariantColor[1], NL.VariantColor[2], NL.VariantColor[3])
    pins[i] = pin
    return pin
end

local function isSquare()
    return GetMinimapShape and GetMinimapShape() == "SQUARE"
end

-- Rings ---------------------------------------------------------------------------

local function updateRings()
    local count = 0
    local mapID, px, py, w, h = Geo.PlayerPosition()
    local nodes = mapID and Store.Nodes(mapID)
    local rotation, ok = Geo.MinimapRotation()
    if nodes and ok and Minimap:IsVisible() then
        local options = Store.Options()
        local ypp = Geo.MinimapYardsPerPixel()
        local half = Minimap:GetWidth() / 2
        local reach = half * ypp * SQUARE_REACH
        local square = isSquare()
        local size = options.ringSize
        for _, node in pairs(nodes) do
            if options.show[node.kind] then
                local east, south = (node.x - px) * w, (node.y - py) * h
                if math.abs(east) <= reach and math.abs(south) <= reach then
                    local dx, dy = Geo.ToMinimap(east, south, ypp, rotation)
                    local inside
                    if square then
                        inside = math.abs(dx) <= half and math.abs(dy) <= half
                    else
                        inside = dx * dx + dy * dy <= half * half
                    end
                    if inside then
                        count = count + 1
                        local pin = acquirePin(count)
                        local color = NL.KindColors[node.kind]
                        pin:SetSize(size, size)
                        pin:ClearAllPoints()
                        pin:SetPoint("CENTER", Minimap, "CENTER", dx, dy)
                        pin.ring:SetVertexColor(color[1], color[2], color[3])
                        pin.variant:SetSize(size * 0.55, size * 0.55)
                        pin.variant:SetShown(Store.IsVariant(node))
                        pin.node, pin.dx, pin.dy = node, dx, dy
                        pin:Show()
                    end
                end
            end
        end
    end
    for i = count + 1, shownCount do
        pins[i]:Hide()
        pins[i].node = nil
    end
    shownCount = count
end

--- The node whose ring is nearest the cursor, within HOVER_PIXELS.
local function nodeUnderCursor(cx, cy)
    local best, bestDist
    for i = 1, shownCount do
        local pin = pins[i]
        local dx, dy = pin.dx - cx, pin.dy - cy
        local d = dx * dx + dy * dy
        if d <= HOVER_PIXELS * HOVER_PIXELS and (not bestDist or d < bestDist) then
            best, bestDist = pin.node, d
        end
    end
    return best
end

-- Hover ---------------------------------------------------------------------------

--- Records every node named in a blip tooltip at the cursor's position.
local function recordBlips(text, cx, cy)
    local mapID, px, py, w, h = Geo.PlayerPosition()
    local rotation, ok = Geo.MinimapRotation()
    if not mapID or not ok then
        Util.Debug(
            string.format(
                "Blip skipped: %s, rotation known %s",
                mapID and "position ok" or Geo.WhyNoPosition(), tostring(ok)
            )
        )
        return
    end
    local ypp = Geo.MinimapYardsPerPixel()
    local east, south = Geo.FromMinimap(cx, cy, ypp, rotation)
    local x, y = px + east / w, py + south / h
    Util.Debug(
        string.format(
            "Hover cursor %.1f,%.1f size %.1fx%.1f scale %.3f ypp %.3f viewRadius %s zoom %d shape %s rotate %s -> %.1f yd E, %.1f yd S",
            cx, cy, Minimap:GetWidth(), Minimap:GetHeight(), Minimap:GetEffectiveScale(), ypp,
            tostring(C_Minimap and C_Minimap.GetViewRadius and C_Minimap.GetViewRadius()), Minimap:GetZoom(),
            tostring(GetMinimapShape and GetMinimapShape()), tostring(rotation), east, south
        )
    )
    -- Zoomed out a hover is coarse: widen the merge and trust it less.
    local errorYards = HOVER_ERROR_PIXELS * ypp
    local weight = math.min(1, 5 / errorYards)
    local changed = false
    for line in text:gmatch("[^\n]+") do
        local name = Util.StripCodes(line)
        local kind = Names.KindOf(name)
        if kind then
            -- Two hovers of one blip can land on opposite edges of it.
            local _, isNew, fresh =
                Store.Observe(mapID, x, y, kind, name, "minimap", w, h, Util.Now(), nil, 2 * errorYards, weight)
            if fresh then
                NL.Share.Queue({mapID = mapID, x = x, y = y, kind = kind, source = "minimap", name = name})
            end
            if isNew then
                Util.Debug(string.format("New %s from minimap: %s", kind, name))
            end
            changed = changed or isNew
        elseif name ~= "" then
            Util.Debug("Unrecognised minimap blip: " .. name)
        end
    end
    if changed then
        NL.Changed()
    end
end

local function hideOwnTip()
    if ownTip then
        ownTip = false
        if ownNode then
            GameTooltip:Hide()
        end
    end
end

-- Retail shows a blip's tooltip as soon as the cursor reaches the edge of its
-- hover area, so where the cursor is when it appears is the edge it came in
-- from. The blip is where the cursor comes to rest; failing that, the middle
-- of everywhere it went while the tooltip was up.
local hover -- {text, sumX, sumY, n, x, y, stillSince, done}

local function commitHover(x, y)
    if not hover or hover.done then
        return
    end
    hover.done = true
    local ok, err = pcall(recordBlips, hover.text, x, y)
    if not ok then
        Util.Debug("Blip error: " .. tostring(err))
    end
    updateRings()
end

--- The hover ended without the cursor settling: use the middle of its path.
local function endHover()
    if hover and not hover.done then
        commitHover(hover.sumX / hover.n, hover.sumY / hover.n)
    end
    hover = nil
end

local function trackHover(text, cx, cy)
    if not hover or hover.text ~= text then
        endHover()
        Util.Debug("Blip: " .. text:gsub("\n", " / "))
        hover = {text = text, sumX = cx, sumY = cy, n = 1, x = cx, y = cy}
        return
    end
    hover.sumX, hover.sumY, hover.n = hover.sumX + cx, hover.sumY + cy, hover.n + 1
    local moved = math.abs(cx - hover.x) + math.abs(cy - hover.y)
    hover.x, hover.y = cx, cy
    if moved > HOVER_STILL_PIXELS then
        hover.stillSince = nil
    elseif not hover.stillSince then
        hover.stillSince = GetTime()
    elseif GetTime() - hover.stillSince >= HOVER_SETTLE_SECONDS then
        commitHover(cx, cy)
    end
end

--- Retail's minimap rebuilds GameTooltip every frame it's hovered, owned by
-- UIParent, via SetMinimapMouseover. That wipes anything shown a frame
-- earlier, so the blip is read and our lines added right after each rebuild.
local function onMinimapMouseover(tooltip)
    if not Minimap:IsMouseOver() then
        return
    end
    lastMouseoverTime = GetTime()
    ownTip = false
    local cx, cy = Geo.CursorOnMinimap()
    local text = tooltip:NumLines() > 0 and GameTooltipTextLeft1 and GameTooltipTextLeft1:GetText()
    if text and IsSecret(text) then
        return
    end
    if text and text ~= "" then
        trackHover(text, cx, cy)
    else
        endHover()
        text = nil
    end
    -- No blip here: a ring for a node that isn't up right now.
    local node = nodeUnderCursor(cx, cy)
    if node then
        NL.Tooltip.AddNodeLines(tooltip, node, not text)
        tooltip:Show()
    end
end

local function updateHover()
    if not Minimap:IsVisible() or not Minimap:IsMouseOver() then
        lastBlipText = nil
        endHover()
        hideOwnTip()
        return
    end
    if mouseoverHooked and GetTime() - lastMouseoverTime < MOUSEOVER_QUIET_SECONDS then
        return
    end
    local cx, cy = Geo.CursorOnMinimap()
    local owned = not mouseoverHooked and GameTooltip:IsShown() and GameTooltip:GetOwner() == Minimap

    if owned and not ownNode then
        -- The client's blip tooltip.
        ownTip = false
        local text = GameTooltipTextLeft1 and GameTooltipTextLeft1:GetText()
        if not text or IsSecret(text) then
            return
        end
        if text ~= lastBlipText then
            lastBlipText = text
            recordBlips(text, cx, cy)
            updateRings()
        end
        if not annotated then
            annotated = true
            local node = nodeUnderCursor(cx, cy)
            if node then
                NL.Tooltip.AddNodeLines(GameTooltip, node, false)
                GameTooltip:Show()
            end
        end
        return
    end

    lastBlipText = nil
    -- No blip here: a ring for a node that isn't up right now.
    local node = nodeUnderCursor(cx, cy)
    if not node then
        hideOwnTip()
        return
    end
    if ownTip and GameTooltip:IsShown() and ownNode == node then
        return
    end
    GameTooltip:SetOwner(Minimap, "ANCHOR_CURSOR")
    NL.Tooltip.AddNodeLines(GameTooltip, node, true)
    GameTooltip:Show()
    ownNode = node
    ownTip = true
end

function MM.Init()
    -- Whatever the tooltip shows next, it isn't our annotation or our own tip.
    GameTooltip:HookScript(
        "OnTooltipCleared",
        function()
            annotated = false
            ownNode = nil
        end
    )
    if GameTooltip.SetMinimapMouseover then
        hooksecurefunc(GameTooltip, "SetMinimapMouseover", onMinimapMouseover)
        mouseoverHooked = true
    end
    local ringElapsed, hoverElapsed = 0, 0
    local driver = CreateFrame("Frame")
    driver:SetScript(
        "OnUpdate",
        function(_, elapsed)
            ringElapsed = ringElapsed + elapsed
            hoverElapsed = hoverElapsed + elapsed
            if ringElapsed >= UPDATE_INTERVAL then
                ringElapsed = 0
                updateRings()
            end
            if hoverElapsed >= HOVER_INTERVAL then
                hoverElapsed = 0
                updateHover()
            end
        end
    )
end

function MM.Refresh()
    updateRings()
end
