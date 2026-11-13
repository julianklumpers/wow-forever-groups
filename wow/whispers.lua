local _, ns = ...

local Log = ns.Log

-- Every whisper Forever Groups sends for the player goes through here, so
-- the "To ...:" line WoW echoes into the player's chat can be hidden: the
-- whisper still reaches the other player, only the copy in our own chat is
-- left out (setting showSentWhispers). Whispers the player types and
-- answers that come back are never hidden. Verified in Forever with /fgp
-- chatfilter (2026-11-12): the filter runs for each "To ..." line and the
-- text is readable.
local Whispers = {}

-- How long a sent whisper waits for its echo.
local ECHO_WAIT = 10

local pending = {}
-- Players whose whispers to us are answers to a whisper the addon sent
-- (a leader it asked): name => until when they stay out of the chat.
local quiet = {}

-- WoW may give a name with or without the realm.
local function sameName(a, b)
    if a == b then
        return true
    end
    return type(a) == "string" and type(b) == "string"
        and (string.match(a, "^([^%-]+)") == string.match(b, "^([^%-]+)"))
end

-- The key of names (a table keyed by player name) that is this player,
-- with or without the realm; nil when none is.
function Whispers.find(names, name)
    if type(name) ~= "string" or ns.isSecret(name) then
        return nil
    end
    if names[name] ~= nil then
        return name
    end
    for key in pairs(names) do
        if sameName(key, name) then
            return key
        end
    end
    return nil
end

local function prune()
    local now = GetTime()
    for i = #pending, 1, -1 do
        if now - pending[i].at > ECHO_WAIT then
            table.remove(pending, i)
        end
    end
end

local function hideEcho(_, _, text, target)
    if ns.db and (ns.db.showSentWhispers or ns.db.debug) then
        return false
    end
    if ns.isSecret(text) or ns.isSecret(target) or type(text) ~= "string" then
        return false
    end
    prune()
    for _, sent in ipairs(pending) do
        -- A whisper shows in every chat window that lists whispers; the
        -- echo stays matched for all of them until it expires.
        if sent.text == text and sameName(sent.name, target) then
            return true
        end
    end
    return false
end

-- Whispers from this player are answers to the addon's question for the
-- next `seconds`: kept out of the chat (shown with /fg debug on).
function Whispers.expectReplies(name, seconds)
    quiet[name] = GetTime() + seconds
end

local function hideReply(_, _, text, sender)
    if (ns.db and (ns.db.showSentWhispers or ns.db.debug)) or ns.isSecret(sender) or ns.isSecret(text) then
        return false
    end
    local key = Whispers.find(quiet, sender)
    if key and GetTime() < quiet[key] then
        return true
    end
    if key then
        quiet[key] = nil
    end
    return false
end

-- Sends a whisper for the player; returns pcall's ok, err.
function Whispers.send(name, text)
    local send = C_ChatInfo.SendChatMessage or SendChatMessage
    prune()
    pending[#pending + 1] = { name = name, text = text, at = GetTime() }
    local ok, err = pcall(send, text, "WHISPER", nil, name)
    if not ok then
        table.remove(pending)
    end
    return ok, err
end

function Whispers.init()
    local add = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
    if type(add) ~= "function" then
        Log.debug("sent whispers stay visible: no chat filter")
        return
    end
    pcall(add, "CHAT_MSG_WHISPER_INFORM", hideEcho)
    pcall(add, "CHAT_MSG_WHISPER", hideReply)
end

ns.Whispers = Whispers
