local NL = NodeLedger
local Store = NL.Store

-- What kind of node a name is, and what kind of gather a spell is.
--
-- Names are learned: every gather records name -> kind, so anything you have
-- gathered once is recognised on the minimap from then on, in any locale. The
-- seeds and patterns below are enUS only and cover what you haven't gathered yet.
NL.Names = {}
local Names = NL.Names

local SEED = {}
local function seed(kind, list)
    for _, name in ipairs(list) do
        SEED[name] = kind
    end
end

seed(
    "herb",
    {
        "Peacebloom", "Silverleaf", "Earthroot", "Mageroyal", "Briarthorn", "Stranglekelp", "Bruiseweed",
        "Wild Steelbloom", "Grave Moss", "Kingsblood", "Liferoot", "Fadeleaf", "Goldthorn", "Khadgar's Whisker",
        "Wintersbite", "Firebloom", "Purple Lotus", "Arthas' Tears", "Sungrass", "Blindweed", "Ghost Mushroom",
        "Gromsblood", "Golden Sansam", "Dreamfoil", "Mountain Silversage", "Plaguebloom", "Icecap", "Black Lotus",
        "Bloodthistle", "Felweed", "Dreaming Glory", "Ragveil", "Terocone", "Flame Cap", "Netherbloom",
        "Nightmare Vine", "Mana Thistle", "Goldclover", "Tiger Lily", "Talandra's Rose", "Adder's Tongue",
        "Lichbloom", "Icethorn", "Frost Lotus", "Mycobloom", "Luredrop", "Orbinid", "Blessing Blossom",
        "Arathor's Spear"
    }
)
seed("mine", {"Bismuth", "Aqirite", "Ironclaw Seam", "Serevite Deposit", "Draconium Deposit", "Khaz'gorite Deposit"})

-- Lowercase Lua patterns, tried in order.
local PATTERNS = {
    {"mine", " vein$"},
    {"mine", " deposit$"},
    {"mine", " seam$"},
    {"mine", " lode$"},
    {"fish", "^school of "},
    {"fish", " school$"},
    {"fish", " pool$"},
    {"fish", " shoal$"},
    {"fish", " swarm$"},
    {"fish", "wreckage$"},
    {"fish", "^floating debris"},
    {"treasure", "chest$"},
    {"treasure", "treasure"},
    {"treasure", " cache$"},
    {"treasure", " coffer$"},
    {"treasure", " strongbox$"},
    {"treasure", " footlocker$"},
    {"treasure", " trunk$"},
    {"treasure", " stash$"}
}

local function lookup(name)
    local kind = Store.NameKind(name) or SEED[name]
    if kind then
        return kind
    end
    local lower = name:lower()
    for _, entry in ipairs(PATTERNS) do
        if lower:find(entry[2]) then
            return entry[1]
        end
    end
    return nil
end

--- "mine", "herb", "fish", "treasure" or nil. Unknown names are retried
-- without their leading words, so "Rich Bismuth" and "Lush Mycobloom" are
-- found from "Bismuth" and "Mycobloom".
function Names.KindOf(name)
    if not name or name == "" then
        return nil
    end
    local rest = name
    while rest do
        local kind = lookup(rest)
        if kind then
            return kind
        end
        rest = rest:match("^%S+%s+(.+)$")
    end
    return nil
end

-- Gather spells. Retail has a different spell per expansion for each
-- profession, so beyond these IDs a cast is also matched by its (localised)
-- name against the names of these base spells.
local SPELL_KINDS = {
    [2366] = "herb", -- Herb Gathering
    [2575] = "mine", -- Mining
    [7620] = "fish", -- Fishing
    [131474] = "fish", -- Fishing (retail)
    [3365] = "open", -- Opening
    [6247] = "open",
    [6477] = "open",
    [6478] = "open",
    [21248] = "open",
    [22810] = "open"
}
local spellNameKinds

function Names.Init()
    spellNameKinds = {}
    for spellID, kind in pairs(SPELL_KINDS) do
        local name = NL.Compat.GetSpellName(spellID)
        if name and not NL.Compat.IsSecret(name) then
            spellNameKinds[name] = kind
        end
    end
end

--- "herb", "mine", "fish", "open" or nil for `spellID`.
function Names.SpellKind(spellID)
    if not spellID or NL.Compat.IsSecret(spellID) then
        return nil
    end
    local kind = SPELL_KINDS[spellID]
    if kind or not spellNameKinds then
        return kind
    end
    local name = NL.Compat.GetSpellName(spellID)
    return name and not NL.Compat.IsSecret(name) and spellNameKinds[name] or nil
end
