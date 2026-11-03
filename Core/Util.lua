local NL = NodeLedger

NL.Util = {}
local Util = NL.Util

local PREFIX = "|cffc8a050Node Ledger:|r "

function Util.IsEmpty(s)
    return s == nil or s == ""
end

function Util.Now()
    return GetServerTime()
end

function Util.ItemIDFromLink(link)
    if not link then
        return nil
    end
    return tonumber(link:match("|Hitem:(%d+)") or link:match("^item:(%d+)"))
end

--- The object ID out of a "GameObject-0-server-instance-zone-objectID-spawn" GUID.
function Util.ObjectIDFromGUID(guid)
    if type(guid) ~= "string" then
        return nil
    end
    return tonumber(guid:match("^GameObject%-%d+%-%d+%-%d+%-%d+%-(%d+)%-"))
end

--- Tooltip text without textures, atlases, colour codes or surrounding space.
function Util.StripCodes(s)
    if not s then
        return nil
    end
    s = s:gsub("|T.-|t", ""):gsub("|A.-|a", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- 90 -> "1m", 7200 -> "2h", 200000 -> "2d".
function Util.Ago(seconds)
    seconds = math.max(0, seconds or 0)
    if seconds < 3600 then
        return math.floor(seconds / 60) .. "m"
    elseif seconds < 86400 then
        return math.floor(seconds / 3600) .. "h"
    end
    return math.floor(seconds / 86400) .. "d"
end

--- Copper as "12g 34s 56c" with the stock coin icons where the client has them.
function Util.FormatMoney(copper)
    copper = math.floor(copper or 0)
    if GetMoneyString then
        return GetMoneyString(copper, true)
    end
    return string.format("%dg %ds %dc", math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100)
end

function Util.Print(message)
    print(PREFIX .. tostring(message))
end

function Util.Debug(message)
    if NodeLedgerDB and NodeLedgerDB.options and NodeLedgerDB.options.debug then
        print(PREFIX .. "|cff888888" .. tostring(message) .. "|r")
    end
end
