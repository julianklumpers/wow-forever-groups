local _, ns = ...

local Log = ns.Log

-- Every party invite the addon sends, whichever part sends it (the filler,
-- the battleground and quest finders, a formed queue group). WoW holds a
-- party place for an invite until it is answered or expires after 60 s, so
-- the free places count all of them. "Your party is full." names nobody: it
-- answers the invite sent last.
local Invites = {}

Invites.LIFETIME = 60
local FULL_WINDOW = 1

local open = {}
local count = 0
local refusedHandlers = {}

-- The names in the player's party or raid.
local function groupNames()
    local names = {}
    local prefix, size = "party", 4
    if IsInRaid() then
        prefix, size = "raid", 40
    end
    for i = 1, size do
        local name = ns.Party.unitName(prefix .. i)
        if name then
            names[name] = true
        end
    end
    return names
end

local function prune()
    if next(open) == nil then
        return
    end
    local now, names = GetTime(), groupNames()
    for name, invite in pairs(open) do
        if ns.Whispers.find(names, name) or now - invite.at >= Invites.LIFETIME then
            open[name] = nil
        end
    end
end

-- owner: who sent it ("filler", "battlegrounds", "quests", "group"); told
-- through onRefused when WoW turns it down. Returns whether the call went
-- through.
function Invites.send(name, owner)
    if ns.Demo.isOn() then
        return false, "demo"
    end
    count = count + 1
    open[name] = { at = GetTime(), owner = owner, order = count }
    local ok, err = pcall(C_PartyInfo.InviteUnit, name)
    if not ok then
        open[name] = nil
        Log.debug("invite %s failed: %s", name, tostring(err))
    end
    return ok, err
end

-- Party places that invites still hold.
function Invites.held()
    prune()
    local held = 0
    for _ in pairs(open) do
        held = held + 1
    end
    return held
end

function Invites.isOpen(name)
    prune()
    return open[name] ~= nil
end

-- Seconds until the invite to name expires, or nil.
function Invites.left(name)
    prune()
    local invite = open[name]
    return invite and Invites.LIFETIME - (GetTime() - invite.at) or nil
end

function Invites.onRefused(owner, handler)
    refusedHandlers[owner] = handler
end

local function refused(name, invite)
    open[name] = nil
    local handler = refusedHandlers[invite.owner]
    if handler then
        handler(name)
    end
end

local function onSystem(text)
    if type(text) ~= "string" then
        return
    end
    if type(ERR_GROUP_FULL) == "string" and text == ERR_GROUP_FULL then
        local lastName, last
        for name, invite in pairs(open) do
            if GetTime() - invite.at < FULL_WINDOW and (not last or invite.order > last.order) then
                lastName, last = name, invite
            end
        end
        if lastName then
            refused(lastName, last)
        end
        return
    end
    local declined = ns.Filler.declinedName(text)
    local name = declined and ns.Whispers.find(open, declined)
    if name then
        open[name] = nil
    end
end

function Invites.reset()
    open = {}
end

-- WoW keeps the invites open over a /reload, so the places they hold are
-- kept too (with their ages: GetTime is not kept over a relog).
local function persist()
    prune()
    local now, saved = GetTime(), {}
    for name, invite in pairs(open) do
        saved[name] = { owner = invite.owner, age = now - invite.at }
    end
    ns.charDb.invites = next(saved) and { list = saved, savedAt = GetServerTime() } or nil
end

local function restore()
    local saved = ns.charDb.invites
    ns.charDb.invites = nil
    if type(saved) ~= "table" or type(saved.list) ~= "table" then
        return
    end
    local away = math.max(0, GetServerTime() - (tonumber(saved.savedAt) or 0))
    local now = GetTime()
    for name, invite in pairs(saved.list) do
        local age = type(invite) == "table" and tonumber(invite.age)
        if type(name) == "string" and age and age + away < Invites.LIFETIME then
            count = count + 1
            open[name] = { at = now - age - away, owner = invite.owner, order = count }
        end
    end
end

function Invites.init()
    restore()
    ns.on("CHAT_MSG_SYSTEM", onSystem)
    ns.on("GROUP_ROSTER_UPDATE", prune)
    ns.on("PLAYER_LOGOUT", persist)
end

ns.Invites = Invites
