local NL = NodeLedger

-- Pure data layer: no frames and no client APIs, so spec/ can load it.
--
-- NodeLedgerDB.maps[uiMapID][nodeID] = node, where a node is one spawn point:
--   x, y          map position (0-1), a weighted mean of every observation
--   kind          "mine" | "herb" | "fish" | "treasure"
--   names[name]   how many times this point has spawned as `name`, so a
--                 Mithril point that sometimes spawns Truesilver shows both
--   hauls[name]   {visits, money, items[itemID] = {qty, hits}} per spawn name
--   gathered, sightings, first, lastObserved, lastName, objects[objectID]
NL.Store = {}
local Store = NL.Store

local DB_VERSION = 1

-- A point seen again within this long under the same name is the same spawn,
-- not a new one, so hovering a blip or gathering what you just hovered
-- doesn't inflate its counts.
local RESPAWN_SECONDS = 300
-- Position weights. A gather puts you within a few yards of the node, a
-- vignette is exact, a minimap hover is only as good as the zoom level.
local SOURCE_WEIGHT = {gather = 3, vignette = 5, minimap = 1}
-- Capped so an old node still settles toward newer, better observations.
local MAX_WEIGHT = 20

local DEFAULT_OPTIONS = {
    show = {mine = true, herb = true, fish = true, treasure = true},
    ringSize = 18,
    mergeRadius = 15,
    worldMap = true,
    debug = false
}

local function fillDefaults(t, defaults)
    for k, v in pairs(defaults) do
        if t[k] == nil then
            t[k] = type(v) == "table" and fillDefaults({}, v) or v
        elseif type(v) == "table" and type(t[k]) == "table" then
            fillDefaults(t[k], v)
        end
    end
    return t
end

function Store.Init()
    NodeLedgerDB = NodeLedgerDB or {}
    local db = NodeLedgerDB
    db.version = db.version or DB_VERSION
    db.options = fillDefaults(db.options or {}, DEFAULT_OPTIONS)
    db.maps = db.maps or {}
    db.nextID = db.nextID or 1
    -- What we've learned: node name -> kind, object ID -> kind, item names.
    db.nameKinds = db.nameKinds or {}
    db.objectKinds = db.objectKinds or {}
    db.itemNames = db.itemNames or {}
    -- Every haul of every node, per spawn name, for "all Mithril Deposits" averages.
    db.nameHauls = db.nameHauls or {}
end

function Store.Options()
    return NodeLedgerDB.options
end

function Store.Nodes(mapID)
    return NodeLedgerDB.maps[mapID]
end

--- Yards between two points on a map `w` by `h` yards.
function Store.Distance(x1, y1, x2, y2, w, h)
    local dx, dy = (x1 - x2) * w, (y1 - y2) * h
    return math.sqrt(dx * dx + dy * dy)
end

--- The nearest node within `radius` yards, of `kind` (or any kind if nil).
function Store.FindNear(mapID, x, y, kind, radius, w, h)
    local nodes = NodeLedgerDB.maps[mapID]
    if not nodes then
        return nil
    end
    local best, bestDist
    for _, node in pairs(nodes) do
        if kind == nil or node.kind == kind then
            local d = Store.Distance(node.x, node.y, x, y, w, h)
            if d <= radius and (not bestDist or d < bestDist) then
                best, bestDist = node, d
            end
        end
    end
    return best, bestDist
end

function Store.LearnName(name, kind)
    if name and kind then
        NodeLedgerDB.nameKinds[name] = kind
    end
end

function Store.NameKind(name)
    return name and NodeLedgerDB.nameKinds[name]
end

function Store.ObjectKind(objectID)
    return objectID and NodeLedgerDB.objectKinds[objectID]
end

function Store.RememberItemName(itemID, name)
    if itemID and name and name ~= "" then
        NodeLedgerDB.itemNames[itemID] = name
    end
end

function Store.ItemName(itemID)
    return NodeLedgerDB.itemNames[itemID]
end

--- Records that a `kind` node called `name` was at x,y. Merges into the
-- nearest node of that kind within the merge radius (or `radius` when the
-- observation is coarser than that), otherwise starts a new node.
-- `source` is "gather", "minimap" or "vignette"; `weight` overrides its
-- default. Returns the node and whether it is new.
function Store.Observe(mapID, x, y, kind, name, source, w, h, now, objectID, radius, weight)
    local db = NodeLedgerDB
    radius = math.max(radius or 0, db.options.mergeRadius)
    local node = Store.FindNear(mapID, x, y, kind, radius, w, h)
    local isNew = node == nil
    if isNew then
        node = {
            id = db.nextID,
            x = x,
            y = y,
            w = 0,
            kind = kind,
            names = {},
            hauls = {},
            gathered = 0,
            sightings = 0,
            first = now
        }
        db.nextID = db.nextID + 1
        db.maps[mapID] = db.maps[mapID] or {}
        db.maps[mapID][node.id] = node
    end

    if name == "" then
        name = nil
    end
    local fresh =
        isNew or (name and name ~= node.lastName) or now - (node.lastObserved or 0) > RESPAWN_SECONDS
    local gather = source == "gather"

    if fresh or gather then
        weight = weight or SOURCE_WEIGHT[source] or 1
        local total = node.w + weight
        node.x = (node.x * node.w + x * weight) / total
        node.y = (node.y * node.w + y * weight) / total
        node.w = math.min(total, MAX_WEIGHT)
    end
    if gather then
        node.gathered = node.gathered + 1
    elseif fresh then
        node.sightings = node.sightings + 1
    end
    if name then
        if fresh then
            node.names[name] = (node.names[name] or 0) + 1
        end
        node.lastName = name
        Store.LearnName(name, kind)
    end
    node.lastObserved = now
    if objectID then
        node.objects = node.objects or {}
        node.objects[objectID] = true
        db.objectKinds[objectID] = kind
    end
    return node, isNew
end

local function newHaul()
    return {visits = 0, money = 0, items = {}}
end

local function addItems(haul, items)
    haul.visits = haul.visits + 1
    for itemID, qty in pairs(items) do
        local entry = haul.items[itemID] or {qty = 0, hits = 0}
        entry.qty = entry.qty + qty
        entry.hits = entry.hits + 1
        haul.items[itemID] = entry
    end
end

--- One gather of `node` while it was spawned as `name`: items[itemID] = qty.
function Store.AddHaul(node, name, items)
    name = name or node.lastName or "?"
    node.hauls[name] = node.hauls[name] or newHaul()
    addItems(node.hauls[name], items)
    local all = NodeLedgerDB.nameHauls
    all[name] = all[name] or newHaul()
    addItems(all[name], items)
end

--- Copper that came with the last haul of `node` as `name`.
function Store.AddMoney(node, name, copper)
    name = name or node.lastName or "?"
    local haul, all = node.hauls[name], NodeLedgerDB.nameHauls[name]
    if haul then
        haul.money = haul.money + copper
    end
    if all then
        all.money = all.money + copper
    end
end

function Store.NameHaul(name)
    return NodeLedgerDB.nameHauls[name]
end

--- {name, count} spawn names of `node`, most frequent first.
function Store.SortedNames(node)
    local list = {}
    for name, count in pairs(node.names) do
        list[#list + 1] = {name = name, count = count}
    end
    table.sort(
        list,
        function(a, b)
            if a.count ~= b.count then
                return a.count > b.count
            end
            return a.name < b.name
        end
    )
    return list
end

--- True when the point has spawned as more than one node.
function Store.IsVariant(node)
    return next(node.names, next(node.names)) ~= nil
end

--- {itemID, avg, chance} per item in `haul`, most per visit first.
function Store.HaulSummary(haul)
    local list = {}
    if not haul or haul.visits == 0 then
        return list
    end
    for itemID, entry in pairs(haul.items) do
        list[#list + 1] = {itemID = itemID, avg = entry.qty / haul.visits, chance = entry.hits / haul.visits}
    end
    table.sort(
        list,
        function(a, b)
            if a.avg ~= b.avg then
                return a.avg > b.avg
            end
            return a.itemID < b.itemID
        end
    )
    return list
end

function Store.Remove(mapID, nodeID)
    local nodes = NodeLedgerDB.maps[mapID]
    if nodes then
        nodes[nodeID] = nil
    end
end

function Store.WipeMap(mapID)
    NodeLedgerDB.maps[mapID] = nil
end

--- Node counts per kind: across every map, and on `mapID`.
function Store.Counts(mapID)
    local total, here = {}, {}
    for id, nodes in pairs(NodeLedgerDB.maps) do
        for _, node in pairs(nodes) do
            total[node.kind] = (total[node.kind] or 0) + 1
            if id == mapID then
                here[node.kind] = (here[node.kind] or 0) + 1
            end
        end
    end
    return total, here
end
