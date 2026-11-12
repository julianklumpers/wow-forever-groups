local _, ns = ...

local Dungeons = ns.Dungeons
local Log = ns.Log
local Group = ns.Group
local Comm = ns.Comm

local Slash = {}

local Widgets = ns.Widgets
local Classes = ns.Classes
local Specs = ns.Specs
local Party = ns.Party

local ROLES = { t = "T", tank = "T", h = "H", heal = "H", healer = "H", d = "D", dps = "D" }

-- "dps", "tank,dps", "tank+heal" or letters like "td".
local function parseRoles(text)
    local roles
    for part in string.gmatch(string.lower(text or ""), "[^,+/]+") do
        if ROLES[part] then
            roles = Widgets.toggleRole(roles, ROLES[part], true)
        elseif string.find(part, "^[thd]+$") then
            for letter in string.gmatch(part, ".") do
                roles = Widgets.toggleRole(roles, ROLES[letter], true)
            end
        else
            return nil
        end
    end
    return roles
end

local function trim(text)
    return (string.gsub(text, "^%s*(.-)%s*$", "%1"))
end

local function parseDungeons(text)
    text = trim(text)
    local lower = string.lower(text)
    if text == "" or lower == "auto" or lower == "all" then
        local ids = {}
        for _, dungeon in ipairs(Dungeons.forLevel(UnitLevel("player"))) do
            ids[#ids + 1] = dungeon.id
        end
        if #ids == 0 then
            return nil, "No dungeons for your level. Name them: /fg join dps Deadmines, WC"
        end
        return ids
    end
    local ids, seen = {}, {}
    for part in string.gmatch(text, "[^,]+") do
        local dungeon = Dungeons.find(trim(part))
        if not dungeon then
            return nil, "Unknown dungeon '" .. trim(part) .. "'. See /fg dungeons."
        end
        if not seen[dungeon.id] then
            seen[dungeon.id] = true
            ids[#ids + 1] = dungeon.id
        end
    end
    return ids
end

local function dungeonNames(ids)
    local names = {}
    for i, id in ipairs(ids) do
        local dungeon = Dungeons.get(id)
        names[i] = dungeon and dungeon.short or id
    end
    return table.concat(names, ", ")
end

local function cmdJoin(rest)
    local roleText, dungeonText = string.match(rest, "^(%S*)%s*(.-)$")
    local roles = parseRoles(roleText)
    if not roles then
        Log.info("Usage: /fg join <tank|healer|dps|tank,dps|...> [all | dungeon, dungeon, ...]")
        return
    end
    local allowed = Classes.filter(roles, Party.playerClass())
    if allowed ~= roles then
        Log.warn("Your class can only play: %s.", Widgets.describeRoles(Classes.allowed(Party.playerClass())))
        return
    end
    if IsInGroup() then
        Log.warn("To queue as a party, use the window: type /fg")
        return
    end
    local ids, err = parseDungeons(dungeonText)
    if not ids then
        Log.warn(err)
        return
    end
    local ok, joinErr = ns.join({ { name = ns.selfName, roles = roles, level = UnitLevel("player") } }, ids)
    if not ok then
        Log.warn("Could not join: %s", tostring(joinErr))
        return
    end
    Log.info("Queued as %s for: %s", Widgets.describeRoles(roles), dungeonNames(ids))
    ns.LfgList.search()
end

local function cmdLeave()
    local filling = ns.Filler.isActive()
    ns.Filler.stop(true)
    ns.Apply.stopSeeking()
    ns.Listing.tick()
    ns.Input.run()
    if (not ns.engine or not ns.engine:leave()) and not filling then
        Log.info("You are not in the queue.")
    end
end

-- Answers the open proposal of either queue.
local function cmdRespond(accept)
    local answered = false
    for _, engine in ipairs({ ns.engine, ns.questEngine }) do
        answered = answered or engine:respond(accept) == true
    end
    if not answered then
        Log.info("There is no group proposal to answer.")
    end
end

local function cmdStatus()
    if not ns.engine then
        Log.info("Not connected yet (channel %s).", tostring(Comm.channelId()))
        return
    end
    local snap = ns.engine:snapshot()
    local connection = Comm.connection()
    Log.info("Channel: %s (%s). You are %s.", connection.text, connection.detail, ns.selfName)
    if snap.queued then
        local entry = ns.engine.myEntry
        local waited = GetServerTime() - snap.joinedAt
        Log.info("Queued as %s for %d:%02d, dungeons: %s", Widgets.describeRoles(entry.members[1].roles),
            math.floor(waited / 60), waited % 60, dungeonNames(entry.dungeons))
    else
        Log.info("Not queued.")
    end
    Log.info("Queue: %d entries (can tank %d, heal %d, DPS %d). Matchmaker: %s%s",
        #snap.entries, snap.roleCounts.T, snap.roleCounts.H, snap.roleCounts.D,
        tostring(snap.matchmaker), snap.isMatchmaker and " (you)" or "")
    if snap.proposal then
        Log.info("Open proposal: %s", snap.proposal)
    end
    local slots = ns.engine.config.SLOTS
    if slots.T ~= 1 or slots.H ~= 1 or slots.D ~= 3 then
        Log.warn("Test group size active: %d tank, %d healer, %d DPS (/fg slots reset).", slots.T, slots.H, slots.D)
    end
end

local function cmdDungeons(rest)
    local level = UnitLevel("player")
    local list = Dungeons.forLevel(level)
    if string.lower(trim(rest)) == "all" then
        list = Dungeons.list
        Log.info("All dungeons (use the short name or number with /fg join):")
    elseif #list == 0 then
        Log.info("No dungeons fit level %d. /fg dungeons all lists every dungeon; you can still join by name.", level)
        return
    else
        Log.info("Dungeons for level %d (use the short name or number with /fg join; /fg dungeons all):", level)
    end
    for _, dungeon in ipairs(list) do
        Log.info("  %s  %s - %s (%s)", dungeon.id, dungeon.short, dungeon.name, Dungeons.rangeText(dungeon))
    end
end

local function cmdDebug()
    ns.db.debug = not ns.db.debug
    Log.info("Debug logging %s.", ns.db.debug and "on" or "off")
end

local function cmdSlots(rest)
    if string.lower(trim(rest)) == "reset" then
        ns.db.slots = nil
    else
        local t, h, d = string.match(rest, "^%s*(%d)%s+(%d)%s+(%d)%s*$")
        if not t then
            Log.info("Usage: /fg slots <tanks> <healers> <dps>  or  /fg slots reset")
            return
        end
        t, h, d = tonumber(t), tonumber(h), tonumber(d)
        if t > 1 or h > 1 or d > 3 or t + h + d == 0 then
            Log.warn("Slots must be at most 1 tank, 1 healer and 3 DPS, and not all zero.")
            return
        end
        ns.db.slots = { T = t, H = h, D = d }
    end
    if ns.engine then
        ns.engine.config.SLOTS = ns.db.slots or ns.Config.SLOTS
    end
    local slots = ns.db.slots or ns.Config.SLOTS
    Log.info("Group size: %d tank, %d healer, %d DPS. Only the matchmaker's setting counts.", slots.T, slots.H,
        slots.D)
end

local FAKE_ROLES = { "T", "H", "D", "D", "D", "TD", "HD", "D", "THD", "D" }

-- Made-up names for fake players, first and last name like Forever's.
local FIRST_NAMES = {
    "Aldric", "Brynna", "Corvin", "Dagny", "Elowen", "Fenrik", "Gwyra", "Haldor", "Isolde", "Jorund",
    "Kaelis", "Liora", "Morwen", "Nyssa", "Orrin", "Perrin", "Quilla", "Rowan", "Sylas", "Talia",
    "Ulric", "Vesna", "Wren", "Xandra", "Yorick", "Zephyra", "Brom", "Ilsa", "Torvin", "Maren",
}
local LAST_NAMES = {
    "Ashvale", "Brightforge", "Coldbrook", "Duskwhisper", "Emberfall", "Frostmantle", "Grimbough",
    "Hollowmere", "Ironveil", "Juniperfall", "Kettleborn", "Lightwater", "Moonwhistle", "Nettlefield",
    "Oakhollow", "Pinecrest", "Quickbrook", "Ravenmoor", "Stormbanner", "Thornwick", "Umberfield",
    "Valecrest", "Willowbend", "Yarrowmere", "Zephyrdale", "Amberline", "Copperkettle", "Deepforge",
    "Silverbough", "Blackbriar", "Mistral",
}

-- A class and talent tree that can play every role of a fake player, a
-- different class in turn: "WARRIOR3" for a tank, "DRUID2" for Tank/DPS.
function Slash.fakeSpec(roles, n)
    local fitting = {}
    for _, token in ipairs({ "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK",
        "DRUID" }) do
        local playable = ""
        for _, tree in ipairs(Specs.TREES[token]) do
            playable = playable .. tree[2]
        end
        local all = true
        for role in string.gmatch(roles, ".") do
            all = all and string.find(playable, role, 1, true) ~= nil
        end
        if all then
            fitting[#fitting + 1] = token
        end
    end
    local token = fitting[(n - 1) % #fitting + 1]
    local first = string.sub(roles, 1, 1)
    for index, tree in ipairs(Specs.TREES[token]) do
        if string.find(tree[2], first, 1, true) then
            return Specs.encode(token, index)
        end
    end
    return Specs.encode(token)
end

-- The name of the n-th fake player: the lists have coprime lengths, so the
-- first 930 names are all different.
function Slash.fakeName(n)
    return FIRST_NAMES[(n * 7) % #FIRST_NAMES + 1] .. " " .. LAST_NAMES[(n * 11) % #LAST_NAMES + 1]
end

local function cmdFake(rest)
    local engine = ns.engine
    if not engine then
        Log.info("Not connected yet.")
        return
    end
    local word = string.lower(trim(rest))
    if word == "clear" then
        Log.info("Removed %d fake players.", engine:clearFakes())
        return
    elseif word == "decline" or word == "afk" then
        engine:setFakeBehavior(word)
        Log.info("The first fake player in the next proposal will %s.",
            word == "decline" and "decline" or "not answer")
        return
    end
    local count, roleText = string.match(word, "^(%d+)%s*(.-)$")
    count = tonumber(count)
    if not count or count < 1 or count > 100 then
        Log.info("Usage: /fg fake <1-100> [roles] | decline | afk | clear")
        return
    end
    local roles
    if roleText ~= "" then
        roles = parseRoles(roleText)
        if not roles then
            Log.warn("Unknown roles '%s'.", roleText)
            return
        end
    end
    -- The dungeons a real player of the same level would pick, and any the
    -- player chose or queued for themselves (also from "Other dungeons").
    local dungeons, listed = {}, {}
    local function add(id)
        if id and not listed[id] then
            listed[id] = true
            dungeons[#dungeons + 1] = id
        end
    end
    for _, dungeon in ipairs(Dungeons.forLevel(UnitLevel("player") or 1)) do
        add(dungeon.id)
    end
    for _, id in ipairs(engine.myEntry and engine.myEntry.dungeons or {}) do
        add(id)
    end
    for _, id in ipairs(ns.Window.selectedDungeonIds()) do
        add(id)
    end
    if #dungeons == 0 then
        for i, dungeon in ipairs(Dungeons.list) do
            dungeons[i] = dungeon.id
        end
    end
    local added = {}
    for _ = 1, count do
        ns.fakeCounter = (ns.fakeCounter or 0) + 1
        local fakeRoles = roles or FAKE_ROLES[(ns.fakeCounter - 1) % #FAKE_ROLES + 1]
        local name = Slash.fakeName(ns.fakeCounter)
        local ok = engine:addFake({ { name = name, roles = fakeRoles, level = UnitLevel("player") } }, dungeons,
            Slash.fakeSpec(fakeRoles, ns.fakeCounter))
        if ok then
            added[#added + 1] = name .. " (" .. Widgets.describeRoles(fakeRoles) .. ")"
        end
    end
    Log.info("Added %d fake players: %s", #added, table.concat(added, ", "))
    if not engine:snapshot().queued then
        Log.info("Fake players are only grouped with you: join the queue to get a proposal.")
    end
end

local function cmdQueue()
    if not ns.engine then
        Log.info("Not connected yet.")
        return
    end
    local engine = ns.engine
    local snap = engine:snapshot()
    Log.info("Queue (%d entries, matchmaker %s):", #snap.entries, tostring(snap.matchmaker))
    for _, entry in ipairs(snap.entries) do
        local parts = {}
        for _, member in ipairs(entry.members) do
            parts[#parts + 1] = member.name .. " " .. Widgets.describeRoles(member.roles)
        end
        local tags = {}
        if entry.id == ns.selfName then
            tags[#tags + 1] = "you"
        end
        if snap.fakes[entry.id] then
            tags[#tags + 1] = "fake"
        end
        if engine:isReserved(entry.id) then
            tags[#tags + 1] = "in a proposal"
        end
        Log.info("  %s  waiting %s  %s%s", table.concat(parts, " + "),
            Widgets.formatTime(GetServerTime() - entry.joinedAt), dungeonNames(entry.dungeons),
            #tags > 0 and ("  [" .. table.concat(tags, ", ") .. "]") or "")
    end
end

local function cmdFill(rest)
    if string.lower(trim(rest)) == "stop" then
        ns.Filler.stop()
        return
    end
    ns.Window.startFill()
end

local function cmdDryRun()
    ns.db.dryRun = not ns.db.dryRun
    Log.info("Dry run %s: Group Finder players are %s.", ns.db.dryRun and "on" or "off",
        ns.db.dryRun and "only listed in chat, not invited" or "whispered and invited")
end

local function cmdLog(rest)
    for _, line in ipairs(Log.lines(tonumber(string.match(rest, "%d+")) or 20)) do
        print(Log.escape(line))
    end
end

local COMMANDS = {
    { "help", "show this list", function() Slash.help() end },
    { "settings", "open the settings window", function() ns.Settings.toggle() end },
    { "messages", "edit the whispers and party messages Forever Groups sends", function()
        ns.MessagesWindow.toggle()
    end },
    { "join", "<roles, e.g. dps or tank,dps> [all | dungeon, ...]  queue up (all: every dungeon for your level)",
        cmdJoin },
    { "leave", "leave the queue", cmdLeave },
    { "online", "list the players with Forever Groups online right now", function()
        local others = ns.Presence.others()
        Log.info("Players with Forever Groups online: %d (you%s%s)", #others + 1, #others > 0 and ", " or "",
            table.concat(others, ", "))
    end },
    { "selftest", "check which game features Forever Groups can use in this client", function()
        ns.Diagnostics.printSelftest()
    end },
    { "bugreport", "open a report (version, self-test, errors, log) to copy and send", function()
        ns.Diagnostics.showReport()
    end },
    { "progress", "show or hide the quest progress of your questing group", function()
        ns.ProgressWindow.toggle()
    end },
    { "style", "[relaxed | learning | serious | expert]  your playstyle", function(rest)
        ns.Playstyle.command(rest)
    end },
    { "accept", "accept the group proposal", function() cmdRespond(true) end },
    { "decline", "decline the group proposal", function() cmdRespond(false) end },
    { "status", "show queue and connection status", cmdStatus },
    { "dungeons", "[all] list dungeons for your level", cmdDungeons },
    { "invite", "send the group invites again (leader)", Group.inviteAll },
    { "debug", "toggle logging of sent and received messages", cmdDebug },
    { "slots", "<t> <h> <d> | reset  test with a smaller group", cmdSlots },
    { "log", "[n] show the last n log lines", cmdLog },
    { "queue", "show who is looking (queue and Group Finder)", function() ns.QueueWindow.toggle() end },
    { "queuelist", "list the queue in chat", cmdQueue },
    { "fill", "[stop]  fill your group's open roles from WoW's Group Finder", cmdFill },
    { "dryrun", "toggle: show Group Finder picks without inviting", cmdDryRun },
    { "autosearch", "turn refreshing the Group Finder on your key presses on/off", function()
        Log.info("Automatic Group Finder refresh %s.", ns.KeySearch.toggle() and "on" or "off")
    end },
    { "minimap", "show or hide the minimap button", function()
        Log.info("Minimap button %s.", ns.MinimapButton.toggle() and "shown" or "hidden")
    end },
    { "fake", "<n> [roles] | decline | afk | clear  fake players for testing", cmdFake },
}

function Slash.help()
    Log.info("Commands:")
    for _, command in ipairs(COMMANDS) do
        print(string.format("  /fg %s %s", command[1], command[2]))
    end
end

function Slash.init()
    SLASH_FOREVERGROUPS1 = "/fg"
    SLASH_FOREVERGROUPS2 = "/forevergroups"
    SLASH_FOREVERGROUPS3 = "/dq"
    SlashCmdList.FOREVERGROUPS = function(input)
        local name, rest = string.match(input or "", "^%s*(%S*)%s*(.-)%s*$")
        name = string.lower(name or "")
        for _, command in ipairs(COMMANDS) do
            if command[1] == name then
                command[3](rest)
                return
            end
        end
        if name == "" then
            ns.Window.toggle()
        else
            Slash.help()
        end
    end
end

ns.Slash = Slash
