local NL = NodeLedger
local L = NL.L
local Util = NL.Util
local Store = NL.Store

-- The lines a node adds to a tooltip: what the point spawns as, how often it
-- has been gathered, and the average haul of each spawn, for this node and
-- for every node of that name.
NL.Tooltip = {}
local Tooltip = NL.Tooltip

local KIND_LABELS = {
    mine = L["Mining node"],
    herb = L["Herb"],
    fish = L["Fishing pool"],
    treasure = L["Treasure"]
}
local MAX_ITEMS = 6
local GREY = "|cff999999"
local GOLD = "|cffffd100"

local function itemName(itemID)
    local name = NL.Compat.GetItemName(itemID)
    if name and not NL.Compat.IsSecret(name) then
        return name
    end
    return Store.ItemName(itemID) or ("item:" .. itemID)
end

local function avgText(entry, haul)
    if not entry then
        return "-"
    end
    return string.format("%.1f", entry.qty / haul.visits)
end

--- One spawn name's hauls: this node's (if any) beside every node's.
local function addHauls(tooltip, name, haul, all)
    local main = (haul and haul.visits > 0) and haul or all
    if not main or main.visits == 0 then
        return
    end
    local mine = haul and haul.visits > 0 and haul.visits or 0
    tooltip:AddDoubleLine(
        GOLD .. name .. "|r",
        string.format(L["%d here |cff999999/ %d all|r"], mine, all and all.visits or 0)
    )
    local shown = 0
    for _, row in ipairs(Store.HaulSummary(main)) do
        shown = shown + 1
        if shown > MAX_ITEMS then
            break
        end
        local here = haul and haul.visits > 0 and haul.items[row.itemID]
        local every = all and all.items[row.itemID]
        local right
        if haul and haul.visits > 0 then
            right = avgText(here, haul) .. GREY .. " / " .. avgText(every, all) .. "|r"
        else
            right = GREY .. "- / " .. avgText(every, all) .. "|r"
        end
        right = right .. GREY .. string.format("  %d%%", row.chance * 100 + 0.5) .. "|r"
        tooltip:AddDoubleLine("  " .. itemName(row.itemID), right, 1, 1, 1, 1, 1, 1)
    end
    local money = main.money / main.visits
    if money >= 1 then
        tooltip:AddDoubleLine("  " .. L["Money"], Util.FormatMoney(money), 1, 1, 1, 1, 1, 1)
    end
end

--- Appends `node` to `tooltip`. `withTitle` adds a heading line, for
-- tooltips that are ours alone (a minimap blip's already has the name).
function Tooltip.AddNodeLines(tooltip, node, withTitle)
    local color = NL.KindColors[node.kind]
    local names = Store.SortedNames(node)
    if withTitle then
        tooltip:AddLine(names[1] and names[1].name or KIND_LABELS[node.kind], color[1], color[2], color[3])
    else
        tooltip:AddLine(" ")
    end
    tooltip:AddLine(L["Node Ledger"], 0.78, 0.63, 0.31)

    local total = 0
    for _, entry in ipairs(names) do
        total = total + entry.count
    end
    if #names > 1 then
        tooltip:AddLine(L["Spawns as:"], 0.8, 0.8, 0.8)
        for _, entry in ipairs(names) do
            tooltip:AddDoubleLine(
                "  " .. entry.name,
                string.format("%d%% (%d)", entry.count / total * 100 + 0.5, entry.count),
                1,
                1,
                1,
                1,
                1,
                1
            )
        end
    end

    tooltip:AddDoubleLine(
        L["Gathered"],
        string.format(L["%d times, seen %s ago"], node.gathered, Util.Ago(Util.Now() - (node.lastObserved or 0))),
        0.8,
        0.8,
        0.8,
        1,
        1,
        1
    )

    local anyHaul = false
    for _, entry in ipairs(names) do
        local haul, all = node.hauls[entry.name], Store.NameHaul(entry.name)
        if (haul and haul.visits > 0) or (all and all.visits > 0) then
            if not anyHaul then
                anyHaul = true
                tooltip:AddDoubleLine(L["Average haul"], GREY .. L["here / all, chance"] .. "|r", 0.8, 0.8, 0.8)
            end
            addHauls(tooltip, entry.name, haul, all)
        end
    end
    if not anyHaul then
        tooltip:AddLine(L["No hauls recorded yet"], 0.6, 0.6, 0.6)
    end
end
