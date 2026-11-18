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
-- Whisperers a role was found for while its place was held by an open
-- invite: { roles, class, at }. They are invited when that place frees up
-- (the invite declined, refused or expired), told when their role is taken
-- after all, and told the group is full when it fills.
local waiting = {}
-- The roles each whisperer named, for this group: { roles, class }; a later
-- whisper without a role ("didn't get inv") is taken as the same roles.
local known = {}

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
        for _, token in ipairs(ns.Compose.CLASSES) do
            if token == class then
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

-- Of the needed roles, those a player of this class can play and has a free
-- place for under the leader's class wishes; with the class unknown, all.
local function openFor(needed, class)
    if not class then
        return needed
    end
    local open = ""
    for role in string.gmatch(needed, ".") do
        if not string.find(open, role, 1, true) and ns.Classes.canPlay(class, role) and fits(role, class) then
            open = open .. role
        end
    end
    return open
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

-- Waits a whisperer for a place an open invite holds, and tells them so.
local function hold(name, role, roles, class)
    if not waiting[name] then
        Log.detail("%s whispered you for a %s place, but it is held by an open invite; inviting them when it "
            .. "frees up.", name, Widgets.ROLE_NAMES[role])
    end
    waiting[name] = { roles = roles or role, class = class, at = GetTime() }
    reply(name, ns.Messages.text("whisperWait"))
end

local function inviteForDungeon(name, role, class, roles)
    if not fits(role, class) then
        Log.detail("Not inviting %s, who whispered you: the open %s places want other classes.", name,
            Widgets.ROLE_NAMES[role])
        return false
    end
    if ns.Fill.avoided(ns.Filler.avoidClasses(), {}, class, role) then
        if not (waiting[name] and waiting[name].variety) then
            Log.detail("%s whispered you for a %s place, but your group has a %s in that role or two already; "
                .. "inviting them in %d s if no other class came by then.", name, Widgets.ROLE_NAMES[role],
                ns.Spec.className(class), ns.Filler.varietyLeft())
        end
        waiting[name] = { roles = roles or role, class = class, at = GetTime(), variety = true }
        return false
    end
    if ns.Filler.room() <= 0 then
        hold(name, role, roles, class)
        return false
    end
    local dungeonId = ns.Filler.dungeon() or ns.Filler.dungeonIds()[1]
    local dungeon = dungeonId and Dungeons.englishName(dungeonId) or "our dungeon"
    local roleName = Widgets.ROLE_NAMES[role]
    if not ns.Filler.trackInvite(name, role, class) then
        -- A queue proposal is open: invited once it is over.
        waiting[name] = waiting[name] or { roles = roles or role, class = class, at = GetTime() }
        return false
    end
    if not ns.Invites.send(name, "filler") then
        ns.Filler.untrackInvite(name)
        return false
    end
    -- Said once, and only once WoW confirms the invite went out (one it turns
    -- down, "Your party is full", is sent again later).
    known[name] = known[name] or { roles = roles or role, class = class }
    if not known[name].told then
        known[name].reply = ns.Messages.inviteText(dungeonId, string.lower(roleName), "whisperYes",
            { role = string.lower(roleName), dungeon = dungeon })
        if not ns.Invites.confirms() then
            WhisperInvite.sent(name)
        end
    end
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
        -- held: the roles open invites hold, in case one goes unanswered.
        local needed, held = ns.Filler.stillNeeded(), ns.Filler.pendingRoles()
        return (needed ~= "" or held ~= "")
            and { needed = needed, held = held, excluded = ns.Filler.excluded(), invite = inviteForDungeon } or nil
    end
    if ns.Listing.listedFor() == "quest" then
        local needed = ns.QuestFinder.openRoles()
        return needed ~= "" and { needed = needed, held = "", excluded = {}, invite = inviteForQuest } or nil
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
    local class = goal.invite == inviteForDungeon and classOf(sender, guid) or nil
    -- A class no open place takes (the class wishes, or what it can play):
    -- told so once when they ask to join, name a role or answer our role
    -- question, as nothing they say would get an invite; other chat is left
    -- alone.
    local needed, heldFor = openFor(goal.needed, class), openFor(goal.held, class)
    if needed == "" and heldFor == "" then
        local aboutJoining = WhisperInvite.rolesIn(text) ~= "" or WhisperInvite.asksToJoin(text)
            or (asked[sender] ~= nil and not asked[sender].silent and not asked[sender].told)
        if aboutJoining and not (asked[sender] and asked[sender].silent) then
            asked[sender] = { needed = needed, count = MAX_ASKS, at = GetTime(), silent = true }
            Log.detail("%s whispered you, but no open place takes a %s; told them so.", sender,
                ns.Spec.className(class))
            reply(sender, ns.Messages.text("whisperClass", { class = ns.Spec.englishClass(class) }))
        end
        return
    end
    if asked[sender] and asked[sender].silent then
        asked[sender] = nil
    end
    local roles = WhisperInvite.rolesIn(text)
    if roles ~= "" then
        known[sender] = { roles = roles, class = class }
    elseif known[sender] then
        -- Chat from someone waiting ("ok", "ty") is not asked anything new.
        if waiting[sender] and not WhisperInvite.asksToJoin(text) then
            return
        end
        roles = known[sender].roles
    end
    if roles ~= "" then
        local role = pickRole(roles, needed, class)
        local heldRole = not role and pickRole(roles, heldFor, class)
        if role then
            if goal.invite(sender, role, class, roles) then
                asked[sender] = nil
            end
        elseif heldRole then
            asked[sender] = nil
            hold(sender, heldRole, roles, class)
        elseif not asked[sender] or asked[sender].needed ~= needed then
            -- Told, not asked: what they say next without a role is no answer.
            asked[sender] = { needed = needed, count = MAX_ASKS, at = GetTime(), told = true }
            Log.detail("%s whispered \"%s\" (%s), a role no longer needed; told them what is.", sender, quote(text),
                roles)
            reply(sender, ns.Messages.text("whisperNo", { roles = neededNames(needed) }))
        end
        return
    end
    local question = asked[sender]
    -- A class that plays one role only (a Rogue: DPS) asking to join needs
    -- no question: it is invited for that role when a place takes it.
    local only = class and ns.Classes.allowed(class)
    if only and #only == 1 and not (question and question.told) and (question or WhisperInvite.asksToJoin(text)) then
        if string.find(needed, only, 1, true) then
            if goal.invite(sender, only, class, only) then
                asked[sender] = nil
            end
            return
        elseif string.find(heldFor, only, 1, true) then
            asked[sender] = nil
            hold(sender, only, only, class)
            return
        end
    end
    if not question then
        if WhisperInvite.asksToJoin(text) then
            asked[sender] = { needed = needed, count = 1, at = GetTime() }
            Log.detail("%s whispered \"%s\" without a role; asked which role they play.", sender, quote(text))
            reply(sender, ns.Messages.text("whisperWhich",
                { roles = neededNames(needed ~= "" and needed or heldFor) }))
        end
        return
    end
    if question.told or question.silent then
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

-- Once a dungeon group is full, whisperers left without a place get one
-- "sorry, full": those still asked for their role and those waiting for a
-- place. Not those already told no place takes them, nor anyone in the party.
local function tellFull()
    local dungeonId = ns.GroupView.trackedDungeon()
    if not dungeonId or not IsInGroup() or GetNumGroupMembers() < 5 then
        return
    end
    local skip = {}
    for _, member in ipairs(ns.Party.members() or {}) do
        skip[member.name] = true
    end
    local function tell(name)
        if skip[name] then
            return
        end
        skip[name] = true
        Log.detail("Told %s, who whispered you, that the group is full.", name)
        reply(name, ns.Messages.text("whisperFull", { dungeon = Dungeons.englishName(dungeonId) }))
    end
    for name, question in pairs(asked) do
        if not question.told and not question.silent then
            tell(name)
        end
    end
    for name in pairs(waiting) do
        tell(name)
    end
end

-- Invites a waiting whisperer once a place is free, for a role still needed;
-- one whose role was taken after all (neither open nor held by an invite)
-- is told what is still needed. What was asked and told is for this group
-- only: forgotten once no group is being built.
function WhisperInvite.tick()
    if (next(asked) ~= nil or next(waiting) ~= nil or next(known) ~= nil) and not ns.Filler.isActive()
        and ns.Listing.listedFor() ~= "quest" then
        tellFull()
        asked, waiting, known = {}, {}, {}
        return
    end
    if next(waiting) == nil then
        return
    end
    local goal = target()
    for name, wait in pairs(waiting) do
        if not goal or goal.invite ~= inviteForDungeon or goal.excluded[name] then
            waiting[name] = nil
        else
            local role = pickRole(wait.roles, goal.needed, wait.class)
            if role and ns.Filler.room() > 0 then
                if not fits(role, wait.class) then
                    waiting[name] = nil
                elseif inviteForDungeon(name, role, wait.class, wait.roles) then
                    waiting[name] = nil
                    asked[name] = nil
                end
            elseif not role and not pickRole(wait.roles, goal.held, wait.class) then
                waiting[name] = nil
                asked[name] = { needed = goal.needed, count = MAX_ASKS, at = GetTime(), told = true }
                Log.detail("%s, who waited for a place, plays a role no longer needed; told them what is.", name)
                local still = goal.needed ~= "" and goal.needed or goal.held
                reply(name, ns.Messages.text("whisperNo", { roles = neededNames(still) }))
            end
            goal = target()
            if not goal then
                return
            end
        end
    end
end

-- WoW confirmed an invite went out: a whisperer it was for hears so now.
function WhisperInvite.sent(name)
    local key = ns.Whispers.find(known, name)
    local whisperer = key and known[key]
    if whisperer and whisperer.reply and not whisperer.told then
        whisperer.told = true
        reply(key, whisperer.reply)
        whisperer.reply = nil
    end
end

-- An invite to a whisperer that WoW turned down ("Your party is full"): they
-- wait for a place again.
function WhisperInvite.refused(name)
    local whisperer = known[name]
    if whisperer and not waiting[name] then
        waiting[name] = { roles = whisperer.roles, class = whisperer.class, at = GetTime() }
        Log.detail("%s, who whispered you, waits for a place again: WoW turned the invite down.", name)
    end
end

function WhisperInvite.init()
    ns.on("CHAT_MSG_WHISPER", WhisperInvite.onWhisper)
    ns.Invites.onSent(WhisperInvite.sent)
end

ns.WhisperInvite = WhisperInvite
