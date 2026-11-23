local _, ns = ...

local Protocol = ns.Protocol
local Outbox = ns.Outbox
local Log = ns.Log

local Comm = {}

Comm.PREFIX = "ForeverGroups"

-- The channel's name and password are put together here, so neither stands
-- as plain text in the files. That keeps out a curious /join; whoever reads
-- the code can still work them out. Every version keeps the same two.
local function unscramble(codes, seed)
    local chars, key = {}, seed
    for i, code in ipairs(codes) do
        chars[i] = string.char((code - key) % 256)
        key = (key * 73 + 41) % 251
    end
    return table.concat(chars)
end

Comm.CHANNEL = unscramble({ 13, 67, 145, 49, 163, 234, 169, 100, 100, 118, 219, 3 }, 157)
local PASSWORD = unscramble({ 166, 90, 21, 76, 40, 106, 113, 140, 195, 159, 225, 110, 76, 227, 50, 221, 53, 115,
    146, 198 }, 89)
local OLD_CHANNELS = { "ForeverGroupsNet", "DungeonQueueNet" }
-- Older versions listen only there; told that a newer one runs, they show their
-- own update warning (once two players have said so).
local OLD_ANNOUNCE = "ForeverGroupsNet"
local OLD_STAY = 5
local OLD_LATE = 30

local JOIN_DELAY = 5
local JOIN_POLL_ATTEMPTS = 15
local RETRY_WAITS = { 30, 60, 120, 300 }
local HANDSHAKE_RETRY = 10
local HANDSHAKE_ATTEMPTS = 5
local RECENT_EVENTS = 10

local REFUSALS = ns.Locale.mark({
    WRONG_PASSWORD = "wrong password",
    BANNED = "you are banned from it",
    WRONG_FACTION = "it belongs to the other faction",
    INVALID_NAME = "WoW refused the channel's name",
    THROTTLED = "WoW limits joining channels right now",
})
local NO_ANSWER = ns.Locale.mark("WoW did not answer")

local channelId
local joining = false
local failure
local attempts, failures = 0, 0
local refusal, warnedReason
local connectedAt
local events = {}
local handshakeText
local handshakeAttempts = 0
local callbacks = {}
local lastSentAt
local dev = {}
--@do-not-package@
-- The developer copy (a symlink, tested before a release) never tells the old
-- channel about its version: that would set off update warnings for everyone.
dev.copy = true

-- Developer copy only, the packager strips it from releases: with /fg debug
-- on, the same party message (sent every few seconds) is logged once per
-- 10 minutes, so it doesn't push the rest out of the log.
local partyLogged, partyLoggedCount = {}, 0
function dev.skipPartyLog(line)
    if not (ns.db and ns.db.debug) then
        return false
    end
    local now = GetTime()
    if partyLogged[line] and now - partyLogged[line] < 600 then
        return true
    end
    if partyLoggedCount >= 200 then
        partyLogged, partyLoggedCount = {}, 0
    end
    if not partyLogged[line] then
        partyLoggedCount = partyLoggedCount + 1
    end
    partyLogged[line] = now
    return false
end
--@end-do-not-package@

local function isSecret(value)
    return issecretvalue ~= nil and issecretvalue(value) == true
end

local function isOurChannel(name)
    return type(name) == "string" and not isSecret(name) and string.lower(name) == string.lower(Comm.CHANNEL)
end

local function remember(fmt, ...)
    local line = date("%H:%M:%S") .. " " .. string.format(fmt, ...)
    events[#events + 1] = line
    if #events > RECENT_EVENTS then
        table.remove(events, 1)
    end
    Log.debug("channel: %s", string.format(fmt, ...))
end

local function result(code)
    local enum = Enum and Enum.SendAddonMessageResult or {}
    if code == true or code == nil or code == (enum.Success or 0) then
        return "ok"
    elseif code == (enum.AddonMessageThrottle or 3) or code == (enum.ChannelThrottle or 8) then
        return "throttled"
    elseif code == (enum.AddOnMessageLockdown or 11) then
        return "blocked"
    elseif code == (enum.InvalidChannel or 7) then
        channelId = nil
        Comm.join()
        return "blocked"
    elseif code == (enum.InvalidPrefix or 1) or code == (enum.InvalidMessage or 2)
        or code == (enum.InvalidChatType or 4) then
        return "error"
    end
    return "retry"
end

-- Every client announces its version every few seconds; logged, they pushed
-- everything else out of the saved log within minutes.
local function isVersionPing(text)
    local prefix = ns.Version and ns.Version.PREFIX
    return prefix ~= nil and string.sub(text, 1, #prefix) == prefix
end

local function transmit(text)
    if not channelId then
        return "blocked"
    end
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
        return "blocked"
    end
    local ok, code = pcall(C_ChatInfo.SendAddonMessage, Comm.PREFIX, text, "CHANNEL", tostring(channelId))
    local outcome = ok and result(code) or "retry"
    if outcome ~= "ok" then
        Log.debug("-> %s [%s, %s]", text, outcome, ok and ("code " .. tostring(code)) or tostring(code))
    elseif not isVersionPing(text) then
        Log.debug("-> %s [%s]", text, outcome)
    end
    if outcome == "ok" then
        lastSentAt = GetServerTime()
    end
    return outcome
end

-- When this client last put a message on the channel (server time), or nil.
function Comm.lastSent()
    return lastSentAt
end

-- P shares A's priority so a matchmaker's own answer never overtakes its proposal.
local PRIORITY = { A = Outbox.HIGH, P = Outbox.HIGH, L = Outbox.NORMAL, Q = Outbox.LOW, S = Outbox.LOW }
-- How long a message may wait in the queue before it is worthless: a
-- proposal must reach its members before they count as gone (10 s), an
-- answer before the proposal ends, a keep-alive before the next one.
local TTL = { P = 8, A = 30, K = 10 }

-- The dungeon (v2|) and questing (q1|) queues each have their own heartbeat.
function Comm.send(text)
    if ns.Demo.isOn() then
        return
    end
    local space, kind = string.match(text, "^(%a%d+)|(%a)")
    local heartbeat = space and (space .. "heartbeat")
    if kind == "L" then
        -- A heartbeat still waiting would go out after the leave (it has a
        -- lower priority) and put us back in everyone's queue.
        Comm.outbox:remove(heartbeat)
    end
    Comm.outbox:push(text, PRIORITY[kind] or Outbox.NORMAL, kind == "Q" and heartbeat or nil, TTL[kind])
    Comm.outbox:flush()
end

-- A proposal of ours that never went out: its queue drops it, so nobody
-- waits for it and its players are not counted as gone.
function Comm.onDropped(text)
    local space, seq = string.match(text, "^(%a%d+)|P|(%d+)|")
    if not space then
        return
    end
    for _, engine in ipairs(ns.Queues.engines()) do
        if engine:prefix() == space then
            engine:cancelOwnProposal(tonumber(seq))
        end
    end
end

-- Bypasses the queue; used on logout when there is no next tick.
function Comm.sendNow(text)
    if ns.Demo.isOn() then
        return
    end
    if channelId then
        pcall(C_ChatInfo.SendAddonMessage, Comm.PREFIX, text, "CHANNEL", tostring(channelId))
    end
end

function Comm.flush()
    Comm.outbox:flush()
end

local function hideChannel()
    for i = 1, NUM_CHAT_WINDOWS or 10 do
        local frame = _G["ChatFrame" .. i]
        if frame and ChatFrame_RemoveChannel then
            pcall(ChatFrame_RemoveChannel, frame, Comm.CHANNEL)
        end
    end
end

local function randomNonce()
    local chars = {}
    for i = 1, 10 do
        local n = math.random(0, 35)
        chars[i] = n < 10 and string.char(48 + n) or string.char(87 + n)
    end
    return table.concat(chars)
end

local function handshake()
    if Comm.selfName then
        return
    end
    handshakeAttempts = handshakeAttempts + 1
    if handshakeAttempts > HANDSHAKE_ATTEMPTS then
        failure = ns.Locale.mark("no answer on the channel; try /reload")
        Log.warn("Could not reach the Forever Groups channel. Try /reload.")
        return
    end
    handshakeText = Protocol.encode({ kind = "sync", nonce = randomNonce() })
    Comm.send(handshakeText)
    Comm.flush()
    C_Timer.After(HANDSHAKE_RETRY, handshake)
end

-- Asks everyone on the channel for their queue entries again, the way a
-- newcomer does (which also has them announce themselves).
function Comm.resync()
    Comm.send(Protocol.encode({ kind = "sync", nonce = randomNonce() }))
end

local function joinFailed()
    joining = false
    failures = failures + 1
    local reason = refusal or NO_ANSWER
    local wait = RETRY_WAITS[math.min(failures, #RETRY_WAITS)]
    failure = string.format(ns.L["could not join the channel: %s"], ns.L[reason])
    remember("not joined after attempt %d (%s); next try in %d s", attempts, reason, wait)
    if failures == 1 or reason ~= warnedReason then
        warnedReason = reason
        if ns.Features.groupFinder() then
            Log.warn("Could not join the Forever Groups channel: %s. Trying again in %s. Until then Forever Groups "
                .. "works through WoW's Group Finder only.", ns.L[reason], ns.Widgets.formatTime(wait))
        else
            Log.warn("Could not join the Forever Groups channel: %s. Trying again in %s.", ns.L[reason],
                ns.Widgets.formatTime(wait))
        end
    end
    C_Timer.After(wait, Comm.join)
end

local function pollJoined(attempt)
    local id = GetChannelName(Comm.CHANNEL)
    if type(id) == "number" and id > 0 then
        joining = false
        channelId = id
        connectedAt = GetTime()
        hideChannel()
        remember("joined as /%d (attempt %d)", id, attempts)
        if failures > 0 then
            Log.info("Connected to the Forever Groups channel again.")
        end
        failures, failure, refusal, warnedReason = 0, nil, nil, nil
        if not Comm.selfName then
            handshake()
        end
        if ns.ChannelGuard then
            ns.ChannelGuard.onJoined()
        end
        return
    end
    if refusal or attempt >= JOIN_POLL_ATTEMPTS then
        joinFailed()
        return
    end
    C_Timer.After(1, function()
        pollJoined(attempt + 1)
    end)
end

function Comm.join()
    if joining then
        return
    end
    joining = true
    refusal = nil
    attempts = attempts + 1
    if type(LeaveChannelByName) == "function" then
        for _, old in ipairs(OLD_CHANNELS) do
            if (tonumber((GetChannelName(old))) or 0) > 0 then
                pcall(LeaveChannelByName, old)
                remember("left the old channel %s", old)
            end
        end
    end
    remember("joining, attempt %d", attempts)
    local ok, err = pcall(JoinTemporaryChannel, Comm.CHANNEL, PASSWORD)
    if not ok then
        remember("JoinTemporaryChannel raised %s", tostring(err))
        refusal = ns.Locale.mark("joining the channel failed")
        joinFailed()
        return
    end
    C_Timer.After(1, function()
        pollJoined(1)
    end)
end

function Comm.setPassword()
    if not channelId then
        return false
    end
    local ok, err = pcall(SetChannelPassword, Comm.CHANNEL, PASSWORD)
    if not ok then
        remember("SetChannelPassword raised %s", tostring(err))
    end
    return ok
end

function Comm.isDevCopy()
    return dev.copy == true
end

local announcedOld = false

-- Once per session, released copies only: into the old channel, our version
-- said once, out again.
local function announceToOld()
    if announcedOld or Comm.isDevCopy() or not ns.Version.mine() then
        return
    end
    announcedOld = true
    pcall(JoinTemporaryChannel, OLD_ANNOUNCE)
    local tries = 0
    local function sendWhenIn()
        tries = tries + 1
        local id = tonumber((GetChannelName(OLD_ANNOUNCE)))
        if id and id > 0 then
            local ok, code = pcall(C_ChatInfo.SendAddonMessage, Comm.PREFIX, ns.Version.announcementText(), "CHANNEL",
                tostring(id))
            remember("told %s that version %s runs (%s)", OLD_ANNOUNCE, ns.Version.mine(),
                ok and tostring(code) or "error")
            C_Timer.After(OLD_STAY, function()
                pcall(LeaveChannelByName, OLD_ANNOUNCE)
            end)
        elseif tries < 10 then
            C_Timer.After(1, sendWhenIn)
        else
            remember("could not get into %s to tell it about version %s", OLD_ANNOUNCE, ns.Version.mine())
            -- WoW may still let us in later; nobody should stay behind in it.
            pcall(LeaveChannelByName, OLD_ANNOUNCE)
            C_Timer.After(OLD_LATE, function()
                if (tonumber((GetChannelName(OLD_ANNOUNCE))) or 0) > 0 then
                    pcall(LeaveChannelByName, OLD_ANNOUNCE)
                end
            end)
        end
    end
    C_Timer.After(1, sendWhenIn)
end

-- When the channel was last joined (GetTime), or nil while not in it.
function Comm.connectedAt()
    return channelId and connectedAt or nil
end

-- For the bug report: { attempts, failure, events = { "12:00:01 joined as /6", ... } }.
function Comm.diagnostics()
    return { attempts = attempts, failure = failure, events = { unpack(events) } }
end

local function allowed(sender)
    local ok, justMuted = Comm.limit:allow(sender)
    if justMuted then
        Log.debug("%s sends too many messages; ignoring them for a while", sender)
        if callbacks.onFlood then
            callbacks.onFlood(sender)
        end
    end
    return ok
end

local function onAddonMessage(prefix, text, chatType, sender, _, _, _, channelName)
    if prefix ~= Comm.PREFIX or type(text) ~= "string" or type(sender) ~= "string" then
        return
    end
    if chatType == "PARTY" then
        if Comm.selfName and sender ~= Comm.selfName and not isSecret(text) and not isSecret(sender)
            and allowed(sender) then
            Log.debug("<- party %s: %s", sender, text)
            callbacks.onParty(sender, text)
        end
        return
    end
    if chatType ~= "CHANNEL" then
        return
    end
    if isSecret(text) or isSecret(sender) or not isOurChannel(channelName) then
        return
    end
    if not Comm.selfName then
        if text == handshakeText then
            Comm.selfName = sender
            failure = nil
            Log.debug("handshake: I am '%s'", sender)
            if ns.ChannelGuard then
                ns.ChannelGuard.onJoined()
            end
            callbacks.onReady(sender)
            announceToOld()
        end
        return
    end
    if sender == Comm.selfName or not allowed(sender) then
        return
    end
    if not isVersionPing(text) then
        Log.debug("<- %s: %s", sender, text)
    end
    callbacks.onMessage(sender, text)
end

local function onChannelNotice(text, player, _, _, player2, _, _, _, baseName)
    if not isOurChannel(baseName) or isSecret(text) or type(text) ~= "string" then
        return
    end
    remember("WoW: %s%s%s", text, player and player ~= "" and (" " .. tostring(player)) or "",
        player2 and player2 ~= "" and (" / " .. tostring(player2)) or "")
    if REFUSALS[text] and joining then
        refusal = REFUSALS[text]
    elseif text == "YOU_LEFT" and channelId then
        channelId = nil
        C_Timer.After(JOIN_DELAY, Comm.join)
    end
end

-- Owner, password, ban and moderator notices of our channel.
local function onChannelUserNotice(text, player, _, _, player2, _, _, _, baseName)
    if not isOurChannel(baseName) or isSecret(text) or type(text) ~= "string" or isSecret(player)
        or isSecret(player2) then
        return
    end
    remember("WoW: %s%s%s", text, player and player ~= "" and (" " .. tostring(player)) or "",
        player2 and player2 ~= "" and (" / " .. tostring(player2)) or "")
    if ns.ChannelGuard then
        ns.ChannelGuard.onNotice(text, player)
    end
end

local function hideNotice(_, _, _, _, _, _, _, _, _, _, baseName)
    return isOurChannel(baseName)
        or (type(baseName) == "string" and not isSecret(baseName) and string.lower(baseName) == "forevergroupsnet")
end

function Comm.channelId()
    return channelId
end

-- { state = "connected"|"connecting"|"paused"|"sending"|"failed", text, detail }
function Comm.connection()
    if failure then
        local detail = ns.L[failure]
        if ns.Features.groupFinder() then
            detail = detail .. "\n" .. ns.L["Until then Forever Groups works through WoW's Group Finder only."]
        end
        return { state = "failed", text = "Not connected", detail = detail }
    end
    if not channelId or not Comm.selfName then
        return { state = "connecting", text = "Connecting...", detail = "Joining the Forever Groups channel." }
    end
    local detail = string.format(ns.L["Channel /%s (%s)"], tostring(channelId), Comm.CHANNEL)
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
        return { state = "paused", text = "Paused", detail = "WoW blocks addon messages right now; they go out later." }
    end
    local waiting = Comm.outbox and Comm.outbox:size() or 0
    if waiting > 3 then
        return { state = "sending", text = "Sending...",
            detail = string.format(ns.L["%d messages wait for the server's limit."], waiting) }
    end
    return { state = "connected", text = "Connected", detail = detail }
end

-- Small, rare party status messages; sent directly instead of queued.
-- Returns whether WoW took the message.
function Comm.sendParty(text)
    if ns.Demo.isOn() then
        return false
    end
    if not IsInGroup() or (C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown()) then
        return false
    end
    local ok, code = pcall(C_ChatInfo.SendAddonMessage, Comm.PREFIX, text, "PARTY")
    local line = text .. " [" .. (ok and tostring(code) or "error") .. "]"
    if not (dev.skipPartyLog and dev.skipPartyLog(line)) then
        Log.debug("-> party %s", line)
    end
    return ok and result(code) == "ok"
end

function Comm.init(onReady, onMessage, onParty, onFlood)
    callbacks.onReady = onReady
    callbacks.onMessage = onMessage
    callbacks.onParty = onParty
    callbacks.onFlood = onFlood
    Comm.limit = ns.RateLimit.new({ clock = GetTime })
    Comm.outbox = Outbox.new({
        clock = GetTime,
        transmit = transmit,
        onDrop = function(text, reason)
            Log.debug("dropped %s (%s)", text, reason)
            Comm.onDropped(text)
        end,
    })
    C_ChatInfo.RegisterAddonMessagePrefix(Comm.PREFIX)
    if ChatFrame_AddMessageEventFilter then
        ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_NOTICE", hideNotice)
        ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_NOTICE_USER", hideNotice)
    end
    ns.on("CHAT_MSG_ADDON", onAddonMessage)
    ns.on("CHAT_MSG_CHANNEL_NOTICE", onChannelNotice)
    ns.on("CHAT_MSG_CHANNEL_NOTICE_USER", onChannelUserNotice)
end

function Comm.start()
    C_Timer.After(JOIN_DELAY, Comm.join)
end

ns.Comm = Comm
