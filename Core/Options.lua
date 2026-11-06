local NL = NodeLedger
local L = NL.L
local Store = NL.Store
local Commands = NL.Commands

-- The options panel under Options > AddOns, built on the client's own
-- Settings API. Every setting writes straight into NodeLedgerDB.options, the
-- same table the slash commands change.
NL.Options = {}
local Options = NL.Options

local category

local KIND_LABELS = {
    mine = L["Mining nodes"],
    herb = L["Herbs"],
    fish = L["Fishing pools"],
    treasure = L["Treasure"]
}

local function header(layout, text)
    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text))
end

--- A setting stored at `tbl[key]`, under a unique `id`.
local function register(id, tbl, key, name)
    local setting = Settings.RegisterAddOnSetting(category, "NodeLedger_" .. id, key, tbl, type(tbl[key]), name, tbl[key])
    setting:SetValueChangedCallback(NL.Changed)
    return setting
end

local function checkbox(id, tbl, key, name, tooltip)
    Settings.CreateCheckbox(category, register(id, tbl, key, name), tooltip)
end

local function slider(id, tbl, key, name, tooltip, low, high)
    local options = Settings.CreateSliderOptions(low, high, 1)
    options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
    Settings.CreateSlider(category, register(id, tbl, key, name), options, tooltip)
end

local function button(layout, name, text, onClick, tooltip)
    layout:AddInitializer(CreateSettingsButtonInitializer(name, text, onClick, tooltip, true))
end

function Options.Register()
    if not (Settings and Settings.RegisterVerticalLayoutCategory) then
        return
    end
    local options = Store.Options()
    local layout
    category, layout = Settings.RegisterVerticalLayoutCategory(L["Node Ledger"])

    header(layout, L["Show"])
    for _, kind in ipairs(NL.Kinds) do
        checkbox("show_" .. kind, options.show, kind, KIND_LABELS[kind], L["show or hide a kind of node"])
    end
    checkbox("worldMap", options, "worldMap", L["World map rings"], L["show or hide world map rings"])
    slider("ringSize", options, "ringSize", L["Minimap ring size"], L["minimap ring size"], 6, 48)
    slider(
        "mergeRadius",
        options,
        "mergeRadius",
        L["Merge radius (yards)"],
        L["how close two sightings must be to count as one node"],
        3,
        60
    )

    header(layout, L["Sharing"])
    checkbox("share_send", options.share, "send", L["Share my finds"], L["Send what you find to others."])
    checkbox("share_guild", options.share, "guild", L["With my guild"], L["Send finds to your guild."])
    checkbox(
        "share_friends",
        options.share,
        "friends",
        L["With my friends"],
        L["Send finds to online character and Battle.net friends."]
    )
    checkbox("share_receive", options.share, "receive", L["Take others' finds"], L["Add what your guild and friends find."])
    checkbox(
        "share_catchUp",
        options.share,
        "catchUp",
        L["Catch up from the guild"],
        L["Arriving on a map, ask the guild for the nodes found there before you joined or while you were away."]
    )
    button(layout, L["Catch up on this map now"], L["Ask"], Commands.Sync, L["ask the guild for this map's nodes now"])

    header(layout, L["Nodes"])
    button(layout, L["Node counts"], L["Print"], Commands.Stats, L["node counts, here and everywhere"])
    button(layout, L["Forget nearest node"], L["Forget"], Commands.Forget, L["remove the nearest node within 30 yards"])
    button(
        layout,
        L["Wipe this map"],
        L["Wipe"],
        function()
            StaticPopup_Show("NODELEDGER_WIPEMAP")
        end,
        L["remove every node on this map"]
    )

    header(layout, L["Troubleshooting"])
    checkbox("debug", options, "debug", L["Debug messages"], L["toggle debug messages"])

    Settings.RegisterAddOnCategory(category)

    StaticPopupDialogs.NODELEDGER_WIPEMAP = {
        text = L["Remove every node on this map? This can't be undone."],
        button1 = YES,
        button2 = NO,
        OnAccept = Commands.WipeMap,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true
    }
end

function Options.Open()
    if category then
        Settings.OpenToCategory(category:GetID())
    end
end
