local NL = NodeLedger
local Store = NL.Store
local Detect = NL.Detect

function NL:OnInitialize()
    Store.Init()
    NL.Commands.Register()
    NL.Options.Register()
end

function NL:OnEnable()
    NL.Names.Init()
    Detect.Init()
    NL.Minimap.Init()
    NL.WorldMap.Init()
    NL.Share.Init()

    self:RegisterEvent("UNIT_SPELLCAST_SENT", Detect.OnSpellcastSent)
    self:RegisterEvent("UNIT_SPELLCAST_FAILED", Detect.OnSpellcastFailed)
    self:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED", Detect.OnSpellcastFailed)

    -- LOOT_READY still has the items when autoloot empties the window before
    -- LOOT_OPENED; Detect handles whichever comes first once per window.
    self:RegisterEventIfExists("LOOT_READY", Detect.OnLootReady)
    self:RegisterEvent("LOOT_OPENED", Detect.OnLootReady)
    self:RegisterEvent("LOOT_CLOSED", Detect.OnLootClosed)

    self:RegisterEventIfExists("VIGNETTES_UPDATED", Detect.QueueVignetteScan)
    self:RegisterEventIfExists("VIGNETTE_MINIMAP_UPDATED", Detect.QueueVignetteScan)
    -- One handler per event, so the zone change does both jobs.
    self:RegisterEvent(
        "ZONE_CHANGED_NEW_AREA",
        function()
            Detect.QueueVignetteScan()
            NL.Share.OnZoneChanged()
        end
    )
    Detect.QueueVignetteScan()

    self:RegisterEvent("CHAT_MSG_ADDON", NL.Share.OnAddonMessage)
    self:RegisterEventIfExists("BN_CHAT_MSG_ADDON", NL.Share.OnBNAddonMessage)
    self:RegisterEvent("GUILD_ROSTER_UPDATE", NL.Share.OnGuildRoster)
end
