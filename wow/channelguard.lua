local _, ns = ...

local Log = ns.Log

-- Keeps the channel open to Forever Groups players. Only its owner (and
-- moderators) can set a password, ban or appoint moderators, and the password
-- keeps everyone else out, so the owner is a Forever Groups player. While this
-- player owns it: a password changed by anyone (also typed by hand) is put
-- back, a ban is lifted, and moderators lose that role. With another owner, or
-- none (WoW does not always pass ownership on), it only logs what happens.
-- Several notices name a player by the first name only; the roster has the
-- full names.
local ChannelGuard = {}

-- At most one password reset per RESTORE_GAP, so two clients can never take
-- turns forever.
local RESTORE_GAP = 10
-- A password change by this player this soon after its own reset was that reset.
local OWN_CHANGE_WINDOW = 5
local ROSTER_WAIT = 2
local ROSTER_TRIES = 5

-- Full name, false while the roster shows none, nil while unknown.
local owner
local restoredAt = -math.huge
local ownChangeAt = -math.huge
local restorePending = false

local function me()
    return ns.Comm.selfName
end

function ChannelGuard.owner()
    return owner
end

function ChannelGuard.isOwner()
    return owner ~= nil and owner ~= false and owner == me()
end

local function restorePassword(why)
    if not ChannelGuard.isOwner() then
        return
    end
    local wait = restoredAt + RESTORE_GAP - GetTime()
    if wait > 0 then
        if not restorePending then
            restorePending = true
            C_Timer.After(wait, function()
                restorePending = false
                restorePassword(why)
            end)
        end
        return
    end
    restoredAt, ownChangeAt = GetTime(), GetTime()
    if ns.Comm.setPassword() then
        Log.debug("channel: password set (%s)", why)
    end
end

local function setOwner(name)
    if name == owner then
        return
    end
    local was = ChannelGuard.isOwner()
    owner = name
    Log.debug("channel: owner %s", name or "none")
    if ChannelGuard.isOwner() and not was then
        restorePassword("you own the channel")
    end
end

local function displayIndex()
    for i = 1, (GetNumDisplayChannels and GetNumDisplayChannels() or 0) do
        local name = GetChannelDisplayInfo(i)
        if type(name) == "string" and string.lower(name) == string.lower(ns.Comm.CHANNEL) then
            return i
        end
    end
end

local function call(label, fn, target)
    local ok, err = pcall(fn, ns.Comm.CHANNEL, target)
    Log.debug("channel: %s %s%s", label, tostring(target), ok and "" or (" raised " .. tostring(err)))
end

-- Reads the owner from the roster; as owner, also takes moderator away from
-- the others. WoW fills the roster a moment after it is asked for, so an
-- empty one is read again rather than taken for "no owner".
local function readRoster(attempt)
    attempt = attempt or 1
    local index = displayIndex()
    if not index or not (C_ChatInfo and C_ChatInfo.GetChannelRosterInfo) then
        return
    end
    pcall(SetSelectedDisplayChannel, index)
    C_Timer.After(ROSTER_WAIT, function()
        index = displayIndex()
        if not index then
            return
        end
        local found, moderators, read = false, {}, 0
        for i = 1, (GetNumChannelMembers and GetNumChannelMembers(index) or 0) do
            local ok, name, isOwner, isModerator = pcall(C_ChatInfo.GetChannelRosterInfo, index, i)
            if ok and type(name) == "string" then
                read = read + 1
                if isOwner then
                    found = name
                elseif isModerator then
                    moderators[#moderators + 1] = name
                end
            end
        end
        if read == 0 then
            if attempt < ROSTER_TRIES then
                readRoster(attempt + 1)
            end
            return
        end
        setOwner(found)
        if ChannelGuard.isOwner() then
            for _, name in ipairs(moderators) do
                call("took moderator away from", ChannelUnmoderator, name)
            end
        end
    end)
end

function ChannelGuard.onJoined()
    owner = nil
    readRoster()
end

-- player as WoW sends it with the notice.
function ChannelGuard.onNotice(code, player)
    if code == "OWNER_CHANGED" then
        setOwner(player)
    elseif code == "PASSWORD_CHANGED" then
        local ours = player == me() and GetTime() - ownChangeAt < OWN_CHANGE_WINDOW
        if not ours then
            restorePassword("changed by " .. tostring(player))
        end
    elseif code == "PLAYER_BANNED" then
        if ChannelGuard.isOwner() then
            call("lifted the ban on", ChannelUnban, player)
        end
    elseif code == "SET_MODERATOR" then
        if ChannelGuard.isOwner() and player ~= me() then
            readRoster()
        end
    end
end

ns.ChannelGuard = ChannelGuard
