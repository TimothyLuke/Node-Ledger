local NL = NodeLedger
local IsSecret = NL.Compat.IsSecret

-- Positions and the minimap's projection.
--
-- Everything is worked in map coordinates (0-1, x east, y south) plus the map's
-- size in yards, which C_Map gives us from its world coordinates. That needs
-- no per-zone data and no UnitPosition, which Midnight restricts.
NL.Geo = {}
local Geo = NL.Geo

local sizes = {}

--- Width and height of `mapID` in yards, or nil for maps with no world position.
function Geo.MapSize(mapID)
    local cached = sizes[mapID]
    if cached ~= nil then
        if cached then
            return cached.w, cached.h
        end
        return nil
    end
    local w, h
    if C_Map.GetWorldPosFromMapPos and CreateVector2D then
        local _, a = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0, 0))
        local _, b = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(1, 1))
        if a and b and not IsSecret(a.x) and not IsSecret(b.x) then
            -- World x runs north and world y runs west.
            w, h = math.abs(a.y - b.y), math.abs(a.x - b.x)
        end
    end
    if w and w > 0 and h > 0 then
        sizes[mapID] = {w = w, h = h}
        return w, h
    end
    sizes[mapID] = false
    return nil
end

--- mapID, x, y, mapWidth, mapHeight for the player, or nil when there is no
-- usable position (instances, loading, restricted).
function Geo.PlayerPosition()
    if IsInInstance() then
        return nil
    end
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID or IsSecret(mapID) then
        return nil
    end
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then
        return nil
    end
    local x, y = pos:GetXY()
    if IsSecret(x) or IsSecret(y) or (x == 0 and y == 0) then
        return nil
    end
    local w, h = Geo.MapSize(mapID)
    if not w then
        return nil
    end
    return mapID, x, y, w, h
end

--- Which step of PlayerPosition fails right now, for debug output.
function Geo.WhyNoPosition()
    if IsInInstance() then
        return "in an instance"
    end
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then
        return "no map for player"
    end
    if IsSecret(mapID) then
        return "map ID is secret"
    end
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then
        return "no position on map " .. mapID
    end
    local x, y = pos:GetXY()
    if IsSecret(x) or IsSecret(y) then
        return "position is secret on map " .. mapID
    end
    if not Geo.MapSize(mapID) then
        return "no world size for map " .. mapID
    end
    return string.format("position %.4f,%.4f on map %d looks fine", x, y, mapID)
end

--- Radians, 0 north, counter-clockwise; nil if unknown.
function Geo.Facing()
    local facing = GetPlayerFacing and GetPlayerFacing()
    if facing == nil or IsSecret(facing) then
        return nil
    end
    return facing
end

--- The map position `yards` in front of x,y when facing `facing`.
function Geo.Ahead(x, y, w, h, facing, yards)
    return x - math.sin(facing) * yards / w, y - math.cos(facing) * yards / h
end

-- Minimap diameter in yards per zoom level, for clients that can't tell us
-- (the values HereBeDragons falls back to). Retail's minimap doesn't match them.
local OUTDOOR = {[0] = 466 + 2 / 3, 400, 333 + 1 / 3, 266 + 2 / 3, 200, 133 + 1 / 3}
local INDOOR = {[0] = 300, 240, 180, 120, 80, 50}

function Geo.MinimapYardsPerPixel()
    local radius = C_Minimap and C_Minimap.GetViewRadius and C_Minimap.GetViewRadius()
    if radius and not IsSecret(radius) and radius > 0 then
        return 2 * radius / Minimap:GetWidth()
    end
    local zoom = Minimap:GetZoom()
    local diameter = (IsIndoors() and INDOOR or OUTDOOR)[zoom] or OUTDOOR[0]
    return diameter / Minimap:GetWidth()
end

--- rotation, ok. Rotation is nil on a north-up minimap. ok is false when the
-- minimap rotates but the client won't tell us which way we face.
function Geo.MinimapRotation()
    if NL.Compat.GetCVar("rotateMinimap") ~= "1" then
        return nil, true
    end
    local facing = Geo.Facing()
    return facing, facing ~= nil
end

local function rotate(x, y, angle)
    local c, s = math.cos(angle), math.sin(angle)
    return x * c - y * s, x * s + y * c
end

--- Yards east/south of the player -> pixels right/up of the minimap centre.
function Geo.ToMinimap(east, south, ypp, rotation)
    local dx, dy = east / ypp, -south / ypp
    if rotation then
        dx, dy = rotate(dx, dy, -rotation)
    end
    return dx, dy
end

--- Pixels right/up of the minimap centre -> yards east/south of the player.
function Geo.FromMinimap(dx, dy, ypp, rotation)
    if rotation then
        dx, dy = rotate(dx, dy, rotation)
    end
    return dx * ypp, -dy * ypp
end

--- The cursor in pixels right/up of the minimap centre.
function Geo.CursorOnMinimap()
    local x, y = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    local cx, cy = Minimap:GetCenter()
    return x / scale - cx, y / scale - cy
end
