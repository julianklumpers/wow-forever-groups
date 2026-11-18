local _, ns = ...

local Dungeons = ns.Dungeons
local Log = ns.Log
local Group = ns.Group
local Comm = ns.Comm

local Slash = {}

local Widgets = ns.Widgets
local Classes = ns.Classes
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
    ns.PartyLevels.noteStart("dungeons")
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
    ns.GroupView.stopBuilding()
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
    for _, engine in ipairs(ns.Queues.engines()) do
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

local function cmdDebug(rest)
    local word = string.lower(trim(rest or ""))
    if word == "on" then
        ns.db.debug = true
    elseif word == "off" then
        ns.db.debug = false
    else
        ns.db.debug = not ns.db.debug
    end
    if ns.db.debug then
        Log.info("Debug on: what Forever Groups does (asking, inviting, whispers) shows in chat.")
    else
        Log.info("Debug off: only the results show.")
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
        ns.GroupView.stopBuilding()
        return
    end
    ns.Window.startFill()
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
    { "style", "[any | relaxed | learning | serious | expert]  your playstyle", function(rest)
        ns.Playstyle.command(rest)
    end },
    { "accept", "accept the group proposal", function() cmdRespond(true) end },
    { "decline", "decline the group proposal", function() cmdRespond(false) end },
    { "status", "show queue and connection status", cmdStatus },
    { "dungeons", "[all] list dungeons for your level", cmdDungeons },
    { "invite", "send the group invites again (leader)", Group.inviteAll },
    { "debug", "[on | off]  show what Forever Groups does (asking, inviting, whispers, messages)", cmdDebug },
    { "log", "[n] show the last n log lines", cmdLog },
    { "queue", "show who is looking (queue and Group Finder)", function() ns.QueueWindow.show() end },
    { "queuelist", "list the queue in chat", cmdQueue },
    { "fill", "[stop]  fill your group's open roles from WoW's Group Finder", cmdFill },
    { "autosearch", "turn refreshing the Group Finder on your key presses on/off", function()
        if ns.KeySearch.toggle() then
            Log.info("Automatic Group Finder refresh on.")
        else
            Log.info("Automatic Group Finder refresh off.")
        end
    end },
    { "minimap", "show or hide the minimap button", function()
        if ns.MinimapButton.toggle() then
            Log.info("Minimap button shown.")
        else
            Log.info("Minimap button hidden.")
        end
    end },
    { "demo", "walk through every screen with example data (for screenshots)", function() ns.Demo.toggle() end },
}

function Slash.help()
    Log.info("Commands:")
    for _, command in ipairs(COMMANDS) do
        print(string.format("  /fg %s %s", command[1], ns.L[command[2]]))
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
