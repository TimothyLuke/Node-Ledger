local NL = NodeLedger
local Util = NL.Util
local Store = NL.Store
local Geo = NL.Geo
local Codec = NL.Codec
local IsSecret = NL.Compat.IsSecret

-- Sharing finds with the guild and friends, and taking theirs.
--
-- What we observe is queued and sent in batches: to GUILD, as a whisper to
-- online character friends (skipping guildmates, who have it already), and
-- through Battle.net to Battle.net friends playing the same game. Received
-- observations go straight into the store and are never passed on, so
-- nothing echoes around a guild.
--
-- Only the guild channel and people on our friends lists are listened to,
-- and each sender is rate-limited.
--
-- Catching up: arriving on a map, we tell the guild how many nodes we have
-- there. Guildmates with more wait a random moment, and the first to answer
-- says so on the guild channel (the rest stand down) and whispers us its
-- gathered nodes for that map, behind any live finds in the send queue.
NL.Share = {}
local Share = NL.Share

local PREFIX = "NodeLedger"
-- Retail and Forever map IDs mean different places, so each only takes its own.
local FLAVOR = NL.IsForever and "F" or "R"
local FLUSH_SECONDS = 10
-- The client throttles addon messages per prefix; one a second stays under it.
local SEND_SECONDS = 1
local MAX_OUTBOX = 100
local RECEIVE_PER_MINUTE = 60
-- Catching up.
local SYNC_LOGIN_DELAY = 15
local SYNC_ZONE_DELAY = 5
local SYNC_ANSWER_MIN, SYNC_ANSWER_MAX = 2, 8
-- Only answer when we have at least this many more nodes than the asker.
local SYNC_MARGIN = 3
local SYNC_MAX_NODES = 400
local SYNC_RECEIVE_PER_MINUTE = 600
-- Don't answer the same person about the same map again for this long.
local SYNC_REPEAT_SECONDS = 300

local pending = {}
local outbox = {}
local syncQueue = {}
local guildNames = {}
local senders = {}
local asked = {}
local answering = {}

local THROTTLED = {}
if Enum and Enum.SendAddonMessageResult then
    for _, key in ipairs({"AddonMessageThrottle", "ChannelThrottle"}) do
        local value = Enum.SendAddonMessageResult[key]
        if value ~= nil then
            THROTTLED[value] = true
        end
    end
end

local function options()
    return Store.Options().share
end

--- "Name" for our own realm, "Name-Realm" otherwise.
local function shortName(name)
    return Ambiguate(name, "none")
end

--- "Name-Realm" always, so every guildmate names a player the same way.
local function fullName(name)
    if name:find("-", 1, true) then
        return name
    end
    return name .. "-" .. (GetNormalizedRealmName() or "")
end

-- Sending ------------------------------------------------------------------------

--- Queues an observation of ours to share: {mapID, x, y, kind, source, name,
-- objectID, items, money}. The entry is sent at the next flush, so fields
-- set before then (money, which arrives after the loot window) go with it.
function Share.Queue(entry)
    if options().send then
        pending[#pending + 1] = entry
    end
end

--- Where to whisper: online character friends and same-game Battle.net
-- friends, each once, leaving out guildmates when the guild is sent to.
function Share.Recipients()
    local list, seen = {}, {}
    local skipGuild = options().guild and IsInGuild()
    local function want(name)
        local key = shortName(name)
        if seen[key] or (skipGuild and guildNames[key]) then
            return false
        end
        seen[key] = true
        return true
    end
    if C_FriendList and C_FriendList.GetNumFriends then
        for i = 1, C_FriendList.GetNumFriends() do
            local info = C_FriendList.GetFriendInfoByIndex(i)
            if info and info.connected and info.name and want(info.name) then
                list[#list + 1] = {channel = "WHISPER", target = info.name}
            end
        end
    end
    if BNGetNumFriends and BNSendGameData and C_BattleNet and C_BattleNet.GetFriendNumGameAccounts then
        for i = 1, BNGetNumFriends() do
            for j = 1, C_BattleNet.GetFriendNumGameAccounts(i) or 0 do
                local game = C_BattleNet.GetFriendGameAccountInfo(i, j)
                if
                    game and game.isOnline and game.clientProgram == BNET_CLIENT_WOW and
                        game.wowProjectID == WOW_PROJECT_ID and
                        game.gameAccountID and
                        game.characterName
                 then
                    local name = game.characterName
                    if game.realmName and game.realmName ~= "" then
                        name = name .. "-" .. game.realmName:gsub("[%s%-]", "")
                    end
                    if want(name) then
                        list[#list + 1] = {channel = "BNET", target = game.gameAccountID}
                    end
                end
            end
        end
    end
    return list
end

local function push(item)
    if #outbox >= MAX_OUTBOX then
        table.remove(outbox, 1)
    end
    outbox[#outbox + 1] = item
end

local function flush()
    if #pending == 0 then
        return
    end
    local entries = pending
    pending = {}
    local opts = options()
    if not opts.send then
        return
    end
    local recipients = opts.friends and Share.Recipients() or {}
    for _, text in ipairs(Codec.EncodeBatch(FLAVOR, entries)) do
        if opts.guild and IsInGuild() then
            push({channel = "GUILD", text = text})
        end
        for _, r in ipairs(recipients) do
            push({channel = r.channel, target = r.target, text = text})
        end
    end
end

local function sendNext()
    -- Live finds first; a catch-up only uses the quiet seconds.
    local item = table.remove(outbox, 1) or table.remove(syncQueue, 1)
    if not item then
        return
    end
    if item.channel == "BNET" then
        BNSendGameData(item.target, PREFIX, item.text)
        return
    end
    local result = C_ChatInfo.SendAddonMessage(PREFIX, item.text, item.channel, item.target)
    if result ~= nil and THROTTLED[result] then
        table.insert(outbox, 1, item)
    end
end

-- Receiving ----------------------------------------------------------------------

--- How many more entries `sender` may give us this minute.
local function allowance(sender)
    local now = GetTime()
    local s = senders[sender]
    if not s or now - s.t > 60 then
        s = {t = now, n = 0, sync = 0}
        senders[sender] = s
    end
    return s
end

--- A caught-up node only fills a gap: one we already know is left alone, so
-- catching up never inflates what we've seen ourselves.
local function applySync(e, w, h, now)
    local radius = Store.Options().mergeRadius
    if Store.FindNear(e.mapID, e.x, e.y, e.kind, radius, w, h) then
        return false
    end
    local node = Store.Observe(e.mapID, e.x, e.y, e.kind, e.name, "sync", w, h, now, e.objectID)
    node.shared = (node.shared or 0) + 1
    return true
end

local function apply(sender, text)
    if not options().receive then
        return
    end
    local flavor, entries = Codec.Decode(text)
    if flavor ~= FLAVOR then
        return
    end
    local budget = allowance(sender)
    local now = Util.Now()
    local added = 0
    for _, e in ipairs(entries) do
        local sync = e.source == "sync"
        local used = sync and budget.sync or budget.n
        if used >= (sync and SYNC_RECEIVE_PER_MINUTE or RECEIVE_PER_MINUTE) then
            break
        end
        if sync then
            budget.sync = used + 1
        else
            budget.n = used + 1
        end
        local w, h = Geo.MapSize(e.mapID)
        if w and sync then
            if applySync(e, w, h, now) then
                added = added + 1
            end
        elseif w then
            local node, isNew = Store.Observe(e.mapID, e.x, e.y, e.kind, e.name, e.source, w, h, now, e.objectID)
            node.shared = (node.shared or 0) + 1
            if e.source == "gather" then
                local name = e.name or node.lastName
                Store.AddHaul(node, name, e.items or {})
                if e.money then
                    Store.AddMoney(node, name, e.money)
                end
            end
            if isNew then
                added = added + 1
            end
        end
    end
    if added > 0 then
        Util.Debug(string.format("%d new node(s) from %s", added, sender))
    end
    NL.Changed()
end

local function isSelf(sender)
    return shortName(sender) == UnitName("player")
end

local function isFriend(sender)
    return C_FriendList and C_FriendList.GetFriendInfo and C_FriendList.GetFriendInfo(shortName(sender)) ~= nil
end

-- Catching up ----------------------------------------------------------------------

--- The entries to whisper someone catching up on `mapID`, most gathered first.
local function syncEntries(mapID)
    local nodes = Store.ExactNodes(mapID)
    table.sort(
        nodes,
        function(a, b)
            return a.gathered > b.gathered
        end
    )
    local entries = {}
    for i = 1, math.min(#nodes, SYNC_MAX_NODES) do
        local node = nodes[i]
        entries[i] = {
            mapID = mapID,
            x = node.x,
            y = node.y,
            kind = node.kind,
            source = "sync",
            name = node.lastName,
            objectID = node.objects and next(node.objects) or nil
        }
    end
    return entries
end

local function answer(state, requester, query)
    if state.cancelled then
        return
    end
    state.sent = true
    local entries = syncEntries(query.mapID)
    push({channel = "GUILD", text = Codec.EncodeOffer(FLAVOR, query.mapID, requester, #entries)})
    for _, text in ipairs(Codec.EncodeBatch(FLAVOR, entries)) do
        syncQueue[#syncQueue + 1] = {channel = "WHISPER", target = requester, text = text}
    end
    Util.Debug(string.format("Catching %s up on map %d: %d node(s)", requester, query.mapID, #entries))
end

local function onQuery(sender, query)
    local opts = options()
    -- One catch-up at a time is plenty for the send queue.
    if not (opts.send and opts.guild) or #syncQueue > 0 then
        return
    end
    local requester = fullName(sender)
    local key = requester .. ":" .. query.mapID
    if answering[key] then
        return
    end
    if #Store.ExactNodes(query.mapID) < query.count + SYNC_MARGIN then
        return
    end
    local state = {}
    answering[key] = state
    C_Timer.After(
        SYNC_ANSWER_MIN + math.random() * (SYNC_ANSWER_MAX - SYNC_ANSWER_MIN),
        function()
            answer(state, requester, query)
        end
    )
    C_Timer.After(
        SYNC_REPEAT_SECONDS,
        function()
            answering[key] = nil
        end
    )
end

--- Someone else is answering: stand down if we were about to.
local function onOffer(offer)
    local state = answering[offer.requester .. ":" .. offer.mapID]
    if state and not state.sent then
        state.cancelled = true
    end
end

--- Asks the guild for the nodes on the map we're on, once per map a session
-- unless `force`.
function Share.RequestSync(force)
    local opts = options()
    if not (opts.receive and opts.catchUp) or not IsInGuild() then
        return false
    end
    local mapID = Geo.PlayerPosition()
    if not mapID or (asked[mapID] and not force) then
        return false
    end
    asked[mapID] = true
    local count = #Store.ExactNodes(mapID)
    push({channel = "GUILD", text = Codec.EncodeQuery(FLAVOR, mapID, count)})
    Util.Debug(string.format("Asked the guild about map %d (we have %d)", mapID, count))
    return true
end

function Share.OnZoneChanged()
    C_Timer.After(SYNC_ZONE_DELAY, Share.RequestSync)
end

function Share.OnAddonMessage(_, prefix, text, channel, sender)
    if prefix ~= PREFIX or IsSecret(text) or IsSecret(sender) or not sender or isSelf(sender) then
        return
    end
    if channel == "GUILD" then
        local control = Codec.DecodeControl(text)
        if control then
            if control.flavor == FLAVOR and control.kind == "Q" then
                onQuery(sender, control)
            elseif control.flavor == FLAVOR and control.kind == "O" then
                onOffer(control)
            end
            return
        end
        apply(sender, text)
    elseif channel == "WHISPER" and (isFriend(sender) or guildNames[shortName(sender)]) then
        apply(sender, text)
    end
end

--- Battle.net game data only ever comes from Battle.net friends.
function Share.OnBNAddonMessage(_, prefix, text, _, senderID)
    if prefix ~= PREFIX or IsSecret(text) then
        return
    end
    apply("bn:" .. tostring(senderID), text)
end

function Share.OnGuildRoster()
    wipe(guildNames)
    if not IsInGuild() then
        return
    end
    for i = 1, GetNumGuildMembers() do
        local name = GetGuildRosterInfo(i)
        if name and not IsSecret(name) then
            guildNames[shortName(name)] = true
        end
    end
end

function Share.Init()
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    C_Timer.NewTicker(FLUSH_SECONDS, flush)
    C_Timer.NewTicker(SEND_SECONDS, sendNext)
    if IsInGuild() and C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    end
    C_Timer.After(SYNC_LOGIN_DELAY, Share.RequestSync)
end
