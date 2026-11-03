local NL = NodeLedger

-- The wire format for sharing nodes. Pure, so spec/ can load it.
--
-- One addon message is a header and observations:
--   "<version>;<flavor>;" entry "~" entry ...
-- and one entry is
--   mapID^x^y^kind^source^name^objectID^items^money
-- with x and y in ten-thousandths of the map, kind and source as one
-- letter, items as "itemID:qty+itemID:qty" and empty fields for nothing.
--
-- Everything received comes from another player, so Decode checks every
-- field and drops any entry that doesn't fit.
NL.Codec = {}
local Codec = NL.Codec

Codec.VERSION = 1
-- Addon messages are capped at 255 bytes.
Codec.MAX_LENGTH = 255

local KIND_CODES = {mine = "m", herb = "h", fish = "f", treasure = "t"}
local SOURCE_CODES = {gather = "g", minimap = "m", vignette = "v"}
local KINDS, SOURCES = {}, {}
for k, v in pairs(KIND_CODES) do
    KINDS[v] = k
end
for k, v in pairs(SOURCE_CODES) do
    SOURCES[v] = k
end

local SCALE = 10000
local MAX_NAME = 64
local MAX_ITEMS = 16
local MAX_ID = 10000000
local MAX_QTY = 1000
local MAX_MONEY = 1000000000

--- Strips the characters the format uses from a name.
local function clean(name)
    return ((name or ""):gsub("[;~%^|:+]", ""):sub(1, MAX_NAME))
end

local function encodeItems(items)
    if not items then
        return ""
    end
    local ids = {}
    for itemID in pairs(items) do
        ids[#ids + 1] = itemID
    end
    table.sort(ids)
    local parts = {}
    for i = 1, math.min(#ids, MAX_ITEMS) do
        parts[i] = ids[i] .. ":" .. items[ids[i]]
    end
    return table.concat(parts, "+")
end

--- One observation as an entry string.
function Codec.EncodeEntry(e)
    return table.concat(
        {
            e.mapID,
            math.floor(e.x * SCALE + 0.5),
            math.floor(e.y * SCALE + 0.5),
            KIND_CODES[e.kind],
            SOURCE_CODES[e.source],
            clean(e.name),
            e.objectID or "",
            encodeItems(e.items),
            e.money and e.money > 0 and math.floor(e.money) or ""
        },
        "^"
    )
end

--- Packs observations into as few messages as fit.
function Codec.EncodeBatch(flavor, entries)
    local header = Codec.VERSION .. ";" .. flavor .. ";"
    local messages, current = {}, nil
    for _, e in ipairs(entries) do
        local entry = Codec.EncodeEntry(e)
        if current and #current + 1 + #entry <= Codec.MAX_LENGTH then
            current = current .. "~" .. entry
        else
            if current then
                messages[#messages + 1] = current
            end
            current = header .. entry
        end
    end
    if current then
        messages[#messages + 1] = current
    end
    return messages
end

local function int(s, min, max)
    if not s or not s:match("^%d+$") then
        return nil
    end
    local n = tonumber(s)
    if n < min or n > max then
        return nil
    end
    return n
end

local function decodeItems(s)
    local items, count = {}, 0
    if s == "" then
        return items
    end
    for part in s:gmatch("[^+]+") do
        local id, qty = part:match("^(%d+):(%d+)$")
        id, qty = int(id, 1, MAX_ID), int(qty, 1, MAX_QTY)
        count = count + 1
        if not id or not qty or count > MAX_ITEMS then
            return nil
        end
        items[id] = (items[id] or 0) + qty
    end
    return items
end

local function decodeEntry(s)
    local f = {}
    for field in (s .. "^"):gmatch("([^%^]*)%^") do
        f[#f + 1] = field
    end
    if #f ~= 9 then
        return nil
    end
    local mapID = int(f[1], 1, MAX_ID)
    local x, y = int(f[2], 0, SCALE), int(f[3], 0, SCALE)
    local kind, source = KINDS[f[4]], SOURCES[f[5]]
    local name = f[6]
    local objectID = f[7] == "" or int(f[7], 1, MAX_ID)
    local items = decodeItems(f[8])
    local money = f[9] == "" or int(f[9], 1, MAX_MONEY)
    if not (mapID and x and y and kind and source and objectID and items and money) then
        return nil
    end
    if #name > MAX_NAME or name:find("[|]") then
        return nil
    end
    return {
        mapID = mapID,
        x = x / SCALE,
        y = y / SCALE,
        kind = kind,
        source = source,
        name = name ~= "" and name or nil,
        objectID = objectID ~= true and objectID or nil,
        items = next(items) and items or nil,
        money = money ~= true and money or nil
    }
end

--- flavor, entries from a message, or nil if it isn't one we can read.
-- Malformed entries are dropped; the rest of the message still counts.
function Codec.Decode(text)
    if type(text) ~= "string" or #text > Codec.MAX_LENGTH then
        return nil
    end
    local version, flavor, body = text:match("^(%d+);(%a);(.*)$")
    if tonumber(version) ~= Codec.VERSION then
        return nil
    end
    local entries = {}
    for s in body:gmatch("[^~]+") do
        local e = decodeEntry(s)
        if e then
            entries[#entries + 1] = e
        end
    end
    return flavor, entries
end
