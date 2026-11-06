local NL = NodeLedger
local L = NL.L
local Util = NL.Util
local Store = NL.Store
local Geo = NL.Geo

NL.Commands = {}
local Commands = NL.Commands

-- /nodes forget removes the nearest node within this many yards of you.
local FORGET_YARDS = 30

local KIND_ALIASES = {
    mine = "mine", mining = "mine", ore = "mine",
    herb = "herb", herbs = "herb", herbalism = "herb",
    fish = "fish", fishing = "fish", pool = "fish", pools = "fish",
    treasure = "treasure", chest = "treasure", chests = "treasure"
}

local function help()
    Util.Print(L["Commands:"])
    print("  /nodes options - " .. L["open the options panel"])
    print("  /nodes stats - " .. L["node counts, here and everywhere"])
    print("  /nodes toggle <mine|herb|fish|treasure> - " .. L["show or hide a kind of node"])
    print("  /nodes size <pixels> - " .. L["minimap ring size"])
    print("  /nodes merge <yards> - " .. L["how close two sightings must be to count as one node"])
    print("  /nodes worldmap - " .. L["show or hide world map rings"])
    print("  /nodes forget - " .. L["remove the nearest node within 30 yards"])
    print("  /nodes wipemap confirm - " .. L["remove every node on this map"])
    print("  /nodes share - " .. L["show what is shared"])
    print("  /nodes share <on|off|guild|friends|receive|catchup> - " .. L["turn sharing on or off, or toggle one part"])
    print("  /nodes sync - " .. L["ask the guild for this map's nodes now"])
    print("  /nodes debug - " .. L["toggle debug messages"])
end

function Commands.Stats()
    local mapID = Geo.PlayerPosition()
    local total, here = Store.Counts(mapID)
    for _, kind in ipairs(NL.Kinds) do
        Util.Print(string.format(L["%s: %d here, %d total"], kind, here[kind] or 0, total[kind] or 0))
    end
end

local function onOff(value)
    return value and L["on"] or L["off"]
end

local function share(arg)
    local opts = Store.Options().share
    arg = arg:lower()
    if arg == "on" or arg == "off" then
        opts.send = arg == "on"
        opts.receive = opts.send
    elseif arg == "guild" or arg == "friends" or arg == "receive" then
        opts[arg] = not opts[arg]
    elseif arg == "catchup" then
        opts.catchUp = not opts.catchUp
    elseif arg ~= "" then
        help()
        return
    end
    Util.Print(
        string.format(
            L["Sharing: send %s (guild %s, friends %s), receive %s, catch up %s."],
            onOff(opts.send),
            onOff(opts.guild),
            onOff(opts.friends),
            onOff(opts.receive),
            onOff(opts.catchUp)
        )
    )
end

--- Asks the guild for this map's nodes now, even if it was asked already.
function Commands.Sync()
    if NL.Share.RequestSync(true) then
        Util.Print(L["Asked the guild for this map's nodes."])
    else
        Util.Print(L["Can't catch up here: needs a guild, a map position, and receiving and catch-up turned on."])
    end
end

function Commands.Forget()
    local mapID, x, y, w, h = Geo.PlayerPosition()
    if not mapID then
        Util.Print(L["No map position here."])
        return
    end
    local node = Store.FindNear(mapID, x, y, nil, FORGET_YARDS, w, h)
    if not node then
        Util.Print(L["No node within 30 yards."])
        return
    end
    Store.Remove(mapID, node.id)
    Util.Print(string.format(L["Forgot %s."], node.lastName or node.kind))
    NL.Changed()
end

--- Removes every node on the player's current map; false if there's no map.
function Commands.WipeMap()
    local mapID = Geo.PlayerPosition()
    if not mapID then
        Util.Print(L["No map position here."])
        return false
    end
    Store.WipeMap(mapID)
    Util.Print(L["Removed every node on this map."])
    NL.Changed()
    return true
end

function Commands.Run(input)
    local command, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
    command = command:lower()
    local options = Store.Options()
    if command == "stats" then
        Commands.Stats()
    elseif command == "options" or command == "config" then
        NL.Options.Open()
    elseif command == "toggle" then
        local kind = KIND_ALIASES[rest:lower()]
        if not kind then
            help()
            return
        end
        options.show[kind] = not options.show[kind]
        Util.Print(string.format(options.show[kind] and L["Showing %s."] or L["Hiding %s."], kind))
        NL.Changed()
    elseif command == "size" and tonumber(rest) then
        options.ringSize = math.max(6, math.min(48, tonumber(rest)))
        Util.Print(string.format(L["Ring size %d."], options.ringSize))
    elseif command == "merge" and tonumber(rest) then
        options.mergeRadius = math.max(3, math.min(60, tonumber(rest)))
        Util.Print(string.format(L["Merge radius %d yards."], options.mergeRadius))
    elseif command == "worldmap" then
        options.worldMap = not options.worldMap
        Util.Print(options.worldMap and L["World map rings on."] or L["World map rings off."])
        NL.Changed()
    elseif command == "forget" then
        Commands.Forget()
    elseif command == "wipemap" then
        if rest:lower() ~= "confirm" then
            Util.Print(L["Type /nodes wipemap confirm to remove every node on this map."])
            return
        end
        Commands.WipeMap()
    elseif command == "share" then
        share(rest)
    elseif command == "sync" then
        Commands.Sync()
    elseif command == "debug" then
        options.debug = not options.debug
        Util.Print(options.debug and L["Debug on."] or L["Debug off."])
    else
        help()
    end
end

function Commands.Register()
    SLASH_NODELEDGER1 = "/nodes"
    SLASH_NODELEDGER2 = "/nodeledger"
    SlashCmdList.NODELEDGER = Commands.Run
end
