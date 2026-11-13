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

local asked = {}

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

local function pickRole(roles, needed)
    for _, role in ipairs({ "T", "H", "D" }) do
        if string.find(roles, role, 1, true) and string.find(needed, role, 1, true) then
            return role
        end
    end
end

local function inviteForDungeon(name, role)
    local dungeonId = ns.Filler.dungeon() or ns.Filler.dungeonIds()[1]
    local dungeon = dungeonId and Dungeons.name(dungeonId) or "our dungeon"
    local roleName = Widgets.ROLE_NAMES[role]
    if ns.db.dryRun then
        Log.info("[dry run] Would invite %s, who whispered you, as %s.", name, roleName)
        return true
    end
    if not ns.Filler.trackInvite(name, role) then
        return false
    end
    local ok, err = pcall(C_PartyInfo.InviteUnit, name)
    if not ok then
        Log.debug("invite %s failed: %s", name, tostring(err))
        return
    end
    reply(name, ns.Messages.text("whisperYes", { role = string.lower(roleName), dungeon = dungeon }))
    Log.detail("Invited %s, who whispered you, as %s.", name, roleName)
    return true
end

local function inviteForQuest(name, role)
    local roleName = Widgets.ROLE_NAMES[role]
    if ns.db.dryRun then
        Log.info("[dry run] Would invite %s, who whispered you, as %s.", name, roleName)
        return true
    end
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

function WhisperInvite.onWhisper(text, sender)
    if not readable(text) or not readable(sender) or type(text) ~= "string" or type(sender) ~= "string" then
        return
    end
    local goal = target()
    if not goal or sender == ns.selfName or goal.excluded[sender] then
        return
    end
    -- A leader we asked to invite us is answering that, not asking to join.
    if ns.Apply.wasAsked(sender) or ns.QuestFinder.wasAsked(sender) then
        return
    end
    if string.find(text, "^%[Forever Groups%]") or string.find(text, "^%[DungeonQueue%]") then
        return
    end
    local needed = goal.needed
    local roles = WhisperInvite.rolesIn(text)
    if roles ~= "" then
        local role = pickRole(roles, needed)
        if role then
            if goal.invite(sender, role) then
                asked[sender] = nil
            end
        elseif not asked[sender] or asked[sender] ~= needed then
            asked[sender] = needed
            reply(sender, ns.Messages.text("whisperNo", { roles = neededNames(needed) }))
        end
        return
    end
    if WhisperInvite.asksToJoin(text) and not asked[sender] then
        asked[sender] = needed
        reply(sender, ns.Messages.text("whisperWhich", { roles = neededNames(needed) }))
    end
end

function WhisperInvite.init()
    ns.on("CHAT_MSG_WHISPER", WhisperInvite.onWhisper)
end

ns.WhisperInvite = WhisperInvite
