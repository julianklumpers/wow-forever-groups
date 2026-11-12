local _, ns = ...

local Protocol = ns.Protocol
local Outbox = ns.Outbox
local Log = ns.Log

local Comm = {}

Comm.PREFIX = "DungeonQueue"
Comm.CHANNEL = "DungeonQueueNet"

local JOIN_DELAY = 5
local JOIN_POLL_ATTEMPTS = 15
local HANDSHAKE_RETRY = 10
local HANDSHAKE_ATTEMPTS = 5

local channelId
local joining = false
local failure
local handshakeText
local handshakeAttempts = 0
local callbacks = {}
local lastSentAt

local function isSecret(value)
    return issecretvalue ~= nil and issecretvalue(value) == true
end

local function isOurChannel(name)
    return type(name) == "string" and not isSecret(name) and string.lower(name) == string.lower(Comm.CHANNEL)
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
    end
    return "error"
end

local function transmit(text)
    if not channelId then
        return "blocked"
    end
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
        return "blocked"
    end
    local ok, code = pcall(C_ChatInfo.SendAddonMessage, Comm.PREFIX, text, "CHANNEL", tostring(channelId))
    local outcome = ok and result(code) or "error"
    Log.debug("-> %s [%s]", text, outcome)
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

-- The dungeon (v2|) and questing (q1|) queues each have their own heartbeat.
function Comm.send(text)
    local space, kind = string.match(text, "^(%a%d+)|(%a)")
    local heartbeat = space and (space .. "heartbeat")
    if kind == "L" then
        -- A heartbeat still waiting would go out after the leave (it has a
        -- lower priority) and put us back in everyone's queue.
        Comm.outbox:remove(heartbeat)
    end
    Comm.outbox:push(text, PRIORITY[kind] or Outbox.NORMAL, kind == "Q" and heartbeat or nil)
    Comm.outbox:flush()
end

-- Bypasses the queue; used on logout when there is no next tick.
function Comm.sendNow(text)
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
        failure = "no answer on the channel; try /reload"
        Log.warn("Could not reach the Forever Groups channel. Try /reload.")
        return
    end
    handshakeText = Protocol.encode({ kind = "sync", nonce = randomNonce() })
    Comm.send(handshakeText)
    Comm.flush()
    C_Timer.After(HANDSHAKE_RETRY, handshake)
end

local function pollJoined(attempt)
    local id = GetChannelName(Comm.CHANNEL)
    if type(id) == "number" and id > 0 then
        joining = false
        channelId = id
        hideChannel()
        Log.debug("joined channel %s as /%d", Comm.CHANNEL, id)
        if not Comm.selfName then
            handshake()
        end
        return
    end
    if attempt >= JOIN_POLL_ATTEMPTS then
        joining = false
        failure = "could not join the channel (too many chat channels?)"
        Log.warn("Could not join the Forever Groups channel (too many chat channels?). Trying again in a minute.")
        C_Timer.After(60, Comm.join)
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
    failure = nil
    local ok, err = pcall(JoinTemporaryChannel, Comm.CHANNEL)
    if not ok then
        joining = false
        failure = "joining the channel failed"
        Log.warn("Joining the channel failed: %s", tostring(err))
        return
    end
    C_Timer.After(1, function()
        pollJoined(1)
    end)
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
            callbacks.onReady(sender)
        end
        return
    end
    if sender == Comm.selfName or not allowed(sender) then
        return
    end
    Log.debug("<- %s: %s", sender, text)
    callbacks.onMessage(sender, text)
end

local function onChannelNotice(text, _, _, _, _, _, _, _, baseName)
    if isOurChannel(baseName) and text == "YOU_LEFT" then
        channelId = nil
        C_Timer.After(JOIN_DELAY, Comm.join)
    end
end

local function hideNotice(_, _, _, _, _, _, _, _, _, _, baseName)
    return isOurChannel(baseName)
end

function Comm.channelId()
    return channelId
end

-- { state = "connected"|"connecting"|"paused"|"sending"|"failed", text, detail }
function Comm.connection()
    if failure then
        return { state = "failed", text = "Not connected", detail = failure }
    end
    if not channelId or not Comm.selfName then
        return { state = "connecting", text = "Connecting...", detail = "Joining the Forever Groups channel." }
    end
    local detail = "Channel /" .. channelId .. " (" .. Comm.CHANNEL .. ")"
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
        return { state = "paused", text = "Paused", detail = "WoW blocks addon messages right now; they go out later." }
    end
    local waiting = Comm.outbox and Comm.outbox:size() or 0
    if waiting > 3 then
        return { state = "sending", text = "Sending...", detail = waiting .. " messages wait for the server's limit." }
    end
    return { state = "connected", text = "Connected", detail = detail }
end

-- Small, rare party status messages; sent directly instead of queued.
function Comm.sendParty(text)
    if not IsInGroup() or (C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown()) then
        return
    end
    local ok, code = pcall(C_ChatInfo.SendAddonMessage, Comm.PREFIX, text, "PARTY")
    Log.debug("-> party %s [%s]", text, ok and tostring(code) or "error")
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
        end,
    })
    C_ChatInfo.RegisterAddonMessagePrefix(Comm.PREFIX)
    if ChatFrame_AddMessageEventFilter then
        ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_NOTICE", hideNotice)
    end
    ns.on("CHAT_MSG_ADDON", onAddonMessage)
    ns.on("CHAT_MSG_CHANNEL_NOTICE", onChannelNotice)
end

function Comm.start()
    C_Timer.After(JOIN_DELAY, Comm.join)
end

ns.Comm = Comm
