std = "lua51"
max_line_length = false
exclude_files = {
    "spec/**",
    ".luacheckrc"
}
ignore = {
    "212" -- unused argument (event handlers take what they're given)
}
globals = {
    "NodeLedger",
    "NodeLedgerDB",
    "NodeLedgerWorldMapPinMixin",
    "SLASH_NODELEDGER1",
    "SLASH_NODELEDGER2",
    "SlashCmdList",
    "StaticPopupDialogs"
}
read_globals = {
    -- Lua / WoW Lua extensions
    "issecretvalue", "wipe", "date",
    -- Namespaces and mixins
    "C_AddOns", "C_BattleNet", "C_ChatInfo", "C_FriendList", "C_GuildInfo", "C_CVar", "C_EventUtils", "C_Item", "C_Map", "C_Minimap", "C_Spell", "C_Timer", "C_VignetteInfo", "Enum",
    "CreateFromMixins", "TooltipDataProcessor", "Settings", "CreateSettingsListSectionHeaderInitializer",
    "CreateSettingsButtonInitializer", "MinimalSliderWithSteppersMixin", "StaticPopup_Show", "YES", "NO", "CreateVector2D", "MapCanvasDataProviderMixin", "MapCanvasPinMixin",
    -- Functions
    "Ambiguate", "BNGetNumFriends", "BNSendGameData", "GetGuildRosterInfo", "GetNumGuildMembers", "IsInGuild",
    "UnitName", "GetNormalizedRealmName",
    "CreateFrame", "GetAddOnMetadata", "GetBuildInfo", "GetCVar", "GetCursorPosition", "GetItemInfo",
    "GetLootSlotInfo", "GetLootSlotLink", "GetLootSlotType", "GetLootSourceInfo", "GetMinimapShape", "GetMoney",
    "GetMoneyString", "GetNumLootItems", "GetPlayerFacing", "GetServerTime", "GetSpellInfo", "GetTime",
    "IsFishingLoot", "IsInInstance", "IsIndoors", "UnitExists", "hooksecurefunc", "GetMouseFoci", "GetMouseFocus",
    -- Constants
    "BNET_CLIENT_WOW", "WOW_PROJECT_ID",
    -- Frames
    "GameTooltip", "GameTooltipTextLeft1", "Minimap", "UIParent", "WorldFrame", "WorldMapFrame"
}
files["Localization/*.lua"] = {ignore = {"211"}}
