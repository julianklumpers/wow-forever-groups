local _, ns = ...

local Dungeons = ns.Dungeons
local Log = ns.Log
local Widgets = ns.Widgets

-- Forever's Group Finder has no applications: players who see our listed
-- group whisper the leader instead. While Forever Groups builds a dungeon
-- group, or has a questing group listed in its zone, a whisper that names a
-- role the group still needs gets an invite; a whisper that asks to join
-- without a role gets one question back.
local WhisperInvite = {}

local ROLE_WORDS = {
    T = { "tank", "tanking", "prot", "protection", "bear", "guardian" },
    H = { "heal", "healer", "healing", "heals", "resto", "restoration", "holy", "disc", "discipline" },
    D = { "dps", "dd", "damage", "dmg", "deeps" },
}
local JOIN_WORDS = { "inv", "invite", "join", "spot", "room", "lfg", "lf", "group", "grp" }

-- Whisperers asked which role they play: { needed, count, at }. A whisper
-- without a role a little after the question is asked again, at most
-- MAX_ASKS times; a quick second line ("inv?") is not an answer yet.
local asked = {}
local MAX_ASKS, ANSWER_AFTER = 3, 3
-- Whisperers a role was found for while every party place was held by an
-- open invite: { roles, class, at }. They are invited when a place frees up,
-- which happens within an invite's lifetime or not at all.
local waiting = {}

local function readable(value)
    if canaccessvalue ~= nil then
        return canaccessvalue(value)
    end
    return not (issecretvalue ~= nil and issecretvalue(value))
end

local function words(text)
    local set = {}
    for word in string.gmatch(string.lower(text), "[%a]+") do
        set[word] = true
    end
    return set
end

-- A whisper as it goes into the saved log: short, and safe to print.
local function quote(text)
    return Log.escape(string.sub(text, 1, 80))
end

-- The roles a whisper names, in T, H, D order: "heal or dps" -> "HD".
function WhisperInvite.rolesIn(text)
    local set = words(text)
    local roles = ""
    for _, role in ipairs(Widgets.ROLES) do
        for _, word in ipairs(ROLE_WORDS[role]) do
            if set[word] then
                roles = roles .. role
                break
            end
        end
    end
    return roles
end

function WhisperInvite.asksToJoin(text)
    local set = words(text)
    for _, word in ipairs(JOIN_WORDS) do
        if set[word] then
            return true
        end
    end
    return false
end

local function reply(name, text)
    if not text or (C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown()) then
        return
    end
    ns.Whispers.send(name, text)
end

local function neededNames(needed)
    local names, seen = {}, {}
    for letter in string.gmatch(needed, ".") do
        if not seen[letter] then
            seen[letter] = true
            names[#names + 1] = Widgets.ROLE_NAMES[letter]
        end
    end
    return table.concat(names, ", ")
end

-- The whisperer's class: from their Group Finder listing, else from the
-- whisper's GUID; nil when neither tells.
local function classOf(name, guid)
    local listings = ns.LfgList.listings()
    for _, listing in ipairs(listings or {}) do
        local class = listing.classToken
        if type(class) == "string" and readable(class) and ns.Whispers.find({ [listing.name] = true }, name) then
            return class
        end
    end
    local playerInfo = _G.GetPlayerInfoByGUID
    if type(playerInfo) ~= "function" or type(guid) ~= "string" or not readable(guid) or guid == "" then
        return nil
    end
    local ok, _, class = pcall(playerInfo, guid)
    if ok and type(class) == "string" and readable(class) then
        for _, known in ipairs(ns.Compose.CLASSES) do
            if known == class then
                return class
            end
        end
    end
    return nil
end

-- Whether a player of this class (nil: not known, then only a place open to
-- any class) fits a free place under the leader's class wishes, next to the
-- invites still out.
local function fits(role, class)
    return ns.PartyCompose.fits({ { role = role, class = class } })
end

-- The first role the player named that is needed and has a place for them:
-- "heal or dps" still gets the DPS place when the healer place wants a class.
local function pickRole(roles, needed, class)
    for _, role in ipairs({ "T", "H", "D" }) do
        if string.find(roles, role, 1, true) and string.find(needed, role, 1, true) and fits(role, class) then
            return role
        end
    end
    for _, role in ipairs({ "T", "H", "D" }) do
        if string.find(roles, role, 1, true) and string.find(needed, role, 1, true) then
            return role
        end
    end
end

local function inviteForDungeon(name, role, class, roles)
    if not fits(role, class) then
        Log.detail("Not inviting %s, who whispered you: the open %s places want other classes.", name,
            Widgets.ROLE_NAMES[role])
        return false
    end
    if ns.Filler.room() <= 0 then
        if not waiting[name] then
            Log.detail("%s whispered you for a %s place, but every place is held by an open invite; inviting "
                .. "them when one frees up.", name, Widgets.ROLE_NAMES[role])
        end
        waiting[name] = { roles = roles or role, class = class, at = GetTime() }
        return false
    end
    local dungeonId = ns.Filler.dungeon() or ns.Filler.dungeonIds()[1]
    local dungeon = dungeonId and Dungeons.englishName(dungeonId) or "our dungeon"
    local roleName = Widgets.ROLE_NAMES[role]
    if not ns.Filler.trackInvite(name, role, class) then
        return false
    end
    if not ns.Invites.send(name, "filler") then
        return
    end
    reply(name, ns.Messages.text("whisperYes", { role = string.lower(roleName), dungeon = dungeon }))
    Log.detail("Invited %s, who whispered you, as %s.", name, roleName)
    return true
end

local function inviteForQuest(name, role)
    local roleName = Widgets.ROLE_NAMES[role]
    if not ns.QuestFinder.inviteWhisperer(name, role) then
        return false
    end
    Log.detail("Invited %s, who whispered you, as %s.", name, roleName)
    return true
end

-- What a whisper can get an invite for right now: the dungeon group being
-- filled, else the questing group listed in its zone; nil when neither.
local function target()
    local state = ns.Party.state()
    if not ns.Features.whisperInvite() or state == "member" or state == "raid" then
        return nil
    end
    if ns.Filler.isActive() then
        local needed = ns.Filler.stillNeeded()
        return needed ~= "" and { needed = needed, excluded = ns.Filler.excluded(), invite = inviteForDungeon } or nil
    end
    if ns.Listing.listedFor() == "quest" then
        local needed = ns.QuestFinder.openRoles()
        return needed ~= "" and { needed = needed, excluded = {}, invite = inviteForQuest } or nil
    end
    return nil
end

function WhisperInvite.onWhisper(text, sender, ...)
    if not readable(text) or not readable(sender) or type(text) ~= "string" or type(sender) ~= "string" then
        return
    end
    local guid = select(10, ...)
    local goal = target()
    if not goal or sender == ns.selfName or goal.excluded[sender] then
        return
    end
    -- A leader we asked to invite us is answering that, not asking to join.
    if ns.Apply.wasAsked(sender) or ns.QuestFinder.wasAsked(sender) or ns.BgFinder.wasAsked(sender) then
        return
    end
    if string.find(text, "^%[Forever Groups%]") or string.find(text, "^%[DungeonQueue%]") then
        return
    end
    local needed = goal.needed
    local roles = WhisperInvite.rolesIn(text)
    if roles ~= "" then
        local class = goal.invite == inviteForDungeon and classOf(sender, guid) or nil
        local role = pickRole(roles, needed, class)
        if role then
            if goal.invite(sender, role, class, roles) then
                asked[sender] = nil
            end
        elseif not asked[sender] or asked[sender].needed ~= needed then
            asked[sender] = { needed = needed, count = 0, at = GetTime() }
            Log.detail("%s whispered \"%s\" (%s), a role no longer needed; told them what is.", sender, quote(text),
                roles)
            reply(sender, ns.Messages.text("whisperNo", { roles = neededNames(needed) }))
        end
        return
    end
    local question = asked[sender]
    if not question then
        if WhisperInvite.asksToJoin(text) then
            asked[sender] = { needed = needed, count = 1, at = GetTime() }
            Log.detail("%s whispered \"%s\" without a role; asked which role they play.", sender, quote(text))
            reply(sender, ns.Messages.text("whisperWhich", { roles = neededNames(needed) }))
        end
        return
    end
    if question.count >= MAX_ASKS then
        Log.detail("No role found in %s's whisper \"%s\"; asked %d times, not asking again.", sender, quote(text),
            MAX_ASKS)
        return
    end
    if GetTime() - question.at < ANSWER_AFTER then
        return
    end
    question.count, question.at, question.needed = question.count + 1, GetTime(), needed
    Log.detail("No role found in %s's whisper \"%s\"; asked again (%d of %d).", sender, quote(text),
        question.count, MAX_ASKS)
    reply(sender, ns.Messages.text("whisperWhich", { roles = neededNames(needed) }))
end

-- Invites a waiting whisperer once a place is free, for a role still needed.
function WhisperInvite.tick()
    if next(waiting) == nil then
        return
    end
    local goal = target()
    local now = GetTime()
    for name, wait in pairs(waiting) do
        if not goal or goal.invite ~= inviteForDungeon or goal.excluded[name]
            or now - wait.at >= ns.Invites.LIFETIME then
            waiting[name] = nil
        elseif ns.Filler.room() > 0 then
            local role = pickRole(wait.roles, goal.needed, wait.class)
            if not role or not fits(role, wait.class) then
                waiting[name] = nil
            elseif inviteForDungeon(name, role, wait.class) then
                waiting[name] = nil
                asked[name] = nil
            end
            goal = target()
            if not goal then
                return
            end
        end
    end
end

function WhisperInvite.init()
    ns.on("CHAT_MSG_WHISPER", WhisperInvite.onWhisper)
end

ns.WhisperInvite = WhisperInvite
