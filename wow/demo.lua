local _, ns = ...

local L = ns.L

local Log = ns.Log
local Widgets = ns.Widgets

-- /fg demo: every screen of the addon in turn, filled with example data, for
-- screenshots and as the introduction a new player gets the first time the
-- window opens. The player is a fixed character; a bar on top of the window
-- welcomes them, then explains each screen step by step, outlining the part
-- it explains and darkening the rest. While it runs nothing goes out: events
-- and the addon's every-second work are held (wow/events.lua, wow/main.lua),
-- sending and searching do nothing, and the data the screens read comes from
-- here. Saved settings are never written: the demo works on copies.
local Demo = {}

local NAME = "Aldric Dawnmere"
local LEVEL = 20
local CLASS = "PALADIN"
local SPEC = { index = 2, name = "Protection", roles = "T", class = CLASS }
local SPEC_CODE = "PALADIN2"
local RELAXED = 2
local FALLBACK_DUNGEONS = { "4", "5", "6", "7" }

local TITLES = ns.Locale.mark({
    "Choosing a dungeon", "Leading your party", "Waiting in the queue", "Group found", "In your group",
    "Group quests", "Questing group", "Battlegrounds",
})

local function shown(frame)
    return frame ~= nil and frame:IsVisible() and frame or nil
end

-- The first and the last of the frames on screen: the part a step outlines.
local function span(list)
    local first, last
    for _, frame in ipairs(list) do
        if shown(frame) then
            first = first or frame
            last = frame
        end
    end
    return first, last
end

local function hasText(frame)
    local text = frame and frame:GetText()
    return type(text) == "string" and #text > 0
end

local function parts()
    return ns.WindowParts, ns.WindowParts.ui
end

local function drawer()
    local frame = ns.QueueWindow.frame()
    return shown(frame), frame
end

local function joinButton()
    local _, ui = parts()
    return shown(ui.join), ui.join
end

local function cardSlots()
    return span(ns.WindowParts.slots)
end

-- Per screen, its steps: what the bar says and the part of the screen it
-- outlines. A step whose part is not on screen is left out.
local STEPS = ns.Locale.mark({
    {
        {
            text = "Tick every role you can play. Forever Groups gives you the one a group needs most.",
            target = function()
                local toggles = ns.WindowParts.roleToggles
                return span({ toggles.T, toggles.H, toggles.D })
            end,
        },
        {
            text = "Join a group, or lead one and the group forms around you. A playstyle groups you with "
                .. "like-minded players only; Any groups you with everyone.",
            target = function()
                local _, ui = parts()
                return span({ ui.joinChoice, ui.leadChoice, ui.playstyleButton })
            end,
        },
        {
            text = "These numbers count the tanks, healers and DPS looking for the dungeons you ticked, "
                .. "in Forever Groups and in WoW's Group Finder, and how many listed groups have a place for you.",
            target = function()
                local _, ui = parts()
                local groups = ui.headerLookingGroups
                return span({ ui.headerLooking, hasText(groups) and groups or nil })
            end,
        },
        {
            text = "Tick the dungeons you would like to run. Those for your level are ticked already; "
                .. "Other dungeons has the rest.",
            target = function()
                local W, ui = parts()
                local list = { ui.dungeonHeader }
                for _, cell in ipairs(W.dungeonCells) do
                    list[#list + 1] = cell
                end
                return span(list)
            end,
        },
        {
            text = "Each row shows the dungeon's level range, your quests there, the listed groups with room for "
                .. "you, and how many players look per role. Hover a row to see those groups.",
            target = function()
                local cell = span(ns.WindowParts.dungeonCells)
                return cell, cell
            end,
        },
        {
            text = "Who is looking: the tab with the eye opens a list beside this window of everyone looking for "
                .. "your dungeons or group quests right now, from Forever Groups and WoW's Group Finder. "
                .. "Right-click a player to whisper or invite, a group to ask to join.",
            target = drawer,
        },
        {
            text = "Find group puts you in the queue, and Forever Groups does the rest by itself: it "
                .. "matches you with other players who have the addon and fills open places from WoW's Group Finder. "
                .. "When your group is ready, accept the popup and the invites arrive on their own.",
            target = joinButton,
        },
    },
    {
        {
            text = "Leading, you can choose the classes for your party's open places, such as a Mage for water. "
                .. "Only those classes join you.",
            target = function()
                local W, ui = parts()
                local list = { ui.composeToggle }
                for _, card in ipairs(W.composeCards) do
                    list[#list + 1] = card
                end
                return span(list)
            end,
        },
        {
            text = "Limit levels: only players between these levels join you.",
            target = function()
                local _, ui = parts()
                return span({ ui.levelsToggle, ui.levelsMax })
            end,
        },
    },
    {
        {
            text = "You are in the queue. The open places fill as players are found; you don't need to do anything.",
            target = cardSlots,
        },
        {
            text = "While you wait your choices are locked; to change them, press Stop and find a group again.",
            target = joinButton,
        },
        {
            text = "While you wait, just keep playing: your key presses and clicks refresh WoW's Group Finder. /fg "
                .. "or the minimap button opens this window again.",
            target = joinButton,
        },
    },
    {
        {
            text = "Who was found: everyone's role and spec, and who has accepted already.",
            target = function()
                local _, rows = ns.Popup.parts()
                return span(rows or {})
            end,
        },
        {
            text = "A group was found: accept before the time runs out. Once everyone has accepted, the invites "
                .. "arrive on their own.",
            target = function()
                local _, _, ui = ns.Popup.parts()
                return span({ ui.count, ui.accept, ui.decline })
            end,
        },
    },
    {
        {
            text = "The places show everyone's role and spec, how far they are from the entrance and how many "
                .. "quests they have for the dungeon.",
            target = cardSlots,
        },
        {
            text = "Set a waypoint to the entrance, share your quests with whoever lacks them, or follow everyone's "
                .. "quest progress.",
            target = function()
                return span(ns.WindowParts.ui.actions or {})
            end,
        },
    },
    {
        {
            text = "The group and elite quests in your quest log show here. Tick the ones you want help with, and "
                .. "Forever Groups finds players for them.",
            target = function()
                return span(ns.WindowParts.questRows)
            end,
        },
        {
            text = "Who is looking shows the players and groups in the zones of the quests you ticked.",
            target = drawer,
        },
        {
            text = "Find questing group first asks the groups already listed for your quests, and starts a group of "
                .. "its own when there is none.",
            target = joinButton,
        },
    },
    {
        {
            text = "Everyone's progress on the group's quests folds out under the status bar. Once they are turned "
                .. "in, Forever Groups asks whether you want to leave the group.",
            target = function()
                return span({ ns.Status.frame(), ns.ProgressWindow.panel() })
            end,
        },
    },
    {
        {
            text = "Questing and battleground groups have their own tabs. You can wait for all of them at once.",
            target = function()
                local tabs = ns.WindowParts.ui.tabs or {}
                return span({ tabs.dungeons, tabs.quests, tabs.battlegrounds })
            end,
        },
        {
            text = { "Choose a party of five or a premade of ten.",
                "A battleground group is signed up by its leader at a battlemaster." },
            target = function()
                local _, ui = parts()
                local sizes = ui.battlegroundSizes or {}
                return span({ ui.battlegroundSizeLabel, sizes[5], sizes[10] })
            end,
        },
        {
            text = "That's all: close this demo, tick your roles and press Find group. /fg or the minimap button "
                .. "opens this window.",
            target = joinButton,
        },
    },
})

local DB_DEFAULTS = {
    noGroupFinder = false, noApply = false, whoClosed = false, statusHidden = false, progressExpanded = false,
    tourSeen = true, debug = false, noSound = true, noFlash = true, autoSearchOff = true,
}
-- Kept as they are: what goes wrong during the demo belongs in the real log.
local SHARED = { log = true, errors = true }

-- { questID, title, zone, size, label }
local QUESTS = {
    { 169, "Wanted: Gath'Ilzogg", "Redridge Mountains", 3, "Group" },
    { 180, "Wanted: Lieutenant Fangore", "Redridge Mountains", 3, "Group" },
    { 314, "Protecting the Herd", "Loch Modan", 3, "Group" },
    { 1388, "Rhapsody's Tale", "Wetlands", 2, "Group" },
}

local DUNGEON_QUESTS = {
    ["4"] = { "Deviate Hides", "Trouble at the Docks" },
    ["5"] = { "Red Silk Bandanas", "The Defias Brotherhood", "Underground Assault" },
    ["6"] = { "The Book of Ur" },
    ["7"] = { "Knowledge in the Deeps", "Twilight Falls" },
}

local on = false
local current = 1
local builds = 0
local saved
local world
local specs = {}
local patches = {}
local bar

function Demo.isOn()
    return on
end

local function copy(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return seen[value]
    end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do
        result[key] = copy(item, seen)
    end
    return result
end

local function demoDb(real)
    local db = {}
    for key, value in pairs(real) do
        db[key] = SHARED[key] and value or copy(value)
    end
    for key, value in pairs(DB_DEFAULTS) do
        db[key] = value
    end
    db.queueRoles, db.newestVersion = nil, nil
    return db
end

local function patch(module, key, fn)
    patches[#patches + 1] = { module, key, module[key] }
    module[key] = fn
end

local function unpatchAll()
    for i = #patches, 1, -1 do
        local item = patches[i]
        item[1][item[2]] = item[3]
    end
    patches = {}
end

local function dungeonIds()
    local ids = {}
    for _, dungeon in ipairs(ns.Dungeons.forLevel(LEVEL)) do
        ids[#ids + 1] = dungeon.id
    end
    return #ids > 0 and ids or FALLBACK_DUNGEONS
end

local function questList()
    local list = {}
    for i, quest in ipairs(QUESTS) do
        list[i] = { questID = quest[1], title = quest[2], zone = quest[3], size = quest[4], label = quest[5],
            key = ns.QuestMatch.key(quest[1], quest[4]) }
    end
    return list
end

local function questKey(index)
    return ns.QuestMatch.key(QUESTS[index][1], QUESTS[index][4])
end

local function bgKey(id)
    return ns.Battlegrounds.key(id, LEVEL)
end

-- Answering in the popup shows there, as it does for real.
local function onEngineEvent(event, data)
    if event == "proposalUpdated" then
        ns.Popup.update(data)
    elseif event == "proposalEnded" then
        ns.Popup.hide()
    end
end

local function newEngine(space, matchmaker)
    return ns.Engine.new({
        name = NAME, clock = GetServerTime, send = function() end, emit = onEngineEvent, random = math.random,
        playstyle = RELAXED, spec = SPEC_CODE, space = space, matchmaker = matchmaker,
        config = space and { PARTIAL_GROUPS = false } or nil,
    })
end

-- players: { { name, roles, level, spec } }, the first one leading.
local function enqueue(engine, now, players, dungeons, waited, compose)
    local members = {}
    for i, player in ipairs(players) do
        members[i] = { name = player[1], roles = player[2], level = player[3] }
        specs[player[1]] = player[4]
    end
    return engine.queue:upsert({
        id = players[1][1], joinedAt = now - waited, dungeons = dungeons, members = members, playstyle = RELAXED,
        spec = players[1][4], compose = compose,
    }, now)
end

local function dungeonEngine(now, ids)
    local engine = newEngine()
    local a, b, c, d = ids[1], ids[2] or ids[1], ids[3] or ids[1], ids[4] or ids[1]
    enqueue(engine, now, { { "Haldor Stormbanner", "T", 22, "WARRIOR3" } }, { b, c }, 95)
    enqueue(engine, now, { { "Morwen Valecrest", "H", 21, "SHAMAN3" } }, { a, b, c, d }, 410)
    enqueue(engine, now, { { "Corvin Ashvale", "D", 20, "MAGE3" } }, { b }, 180)
    enqueue(engine, now, { { "Dagny Ironveil", "D", 19, "ROGUE2" } }, { a, b }, 55)
    enqueue(engine, now, { { "Vesna Willowbend", "TD", 20, "DRUID2" } }, { c, d }, 30)
    local Compose = ns.Compose
    enqueue(engine, now, { { "Liora Thornwick", "D", 21, "WARLOCK1" }, { "Fenrik Grimbough", "D", 20, "HUNTER1" } },
        { b, c }, 240, Compose.encode({ untilAt = 0, masks = { Compose.maskOf({ "WARRIOR", "PALADIN" }),
            Compose.maskOf({ "PRIEST", "DRUID" }), 0, 0, 0 } }))
    return engine
end

local function soloListing(n, name, class, roles, level, field, areas, age)
    specs[name] = specs[name] or class
    return { id = -n, name = name, leader = name, level = level, classToken = class, roles = roles,
        [field] = areas, age = age, solo = true, members = 1, playstyle = RELAXED }
end

-- members: { { class, role, level } }, the leader first.
local function groupListing(n, leader, field, areas, age, members, remaining)
    local info = {}
    for i, member in ipairs(members) do
        info[i] = { leader = i == 1, classToken = member[1], role = member[2], level = member[3] }
    end
    return { id = -n, name = leader, leader = leader, level = members[1][3], classToken = members[1][1],
        roles = members[1][2], [field] = areas, age = age, solo = false, members = #members,
        remaining = remaining, memberInfo = info, playstyle = RELAXED }
end

local function dungeonListings(ids)
    local a, b, c, d = ids[1], ids[2] or ids[1], ids[3] or ids[1], ids[4] or ids[1]
    return {
        soloListing(1, "Xandra Yarrowmere", "WARLOCK", "D", 20, "dungeons", { a, b }, 260),
        soloListing(2, "Ulric Copperkettle", "PRIEST", "H", 22, "dungeons", { c }, 140),
        soloListing(3, "Yorick Emberfall", "PALADIN", "H", 21, "dungeons", { b }, 75),
        soloListing(4, "Sylas Ravenmoor", "HUNTER", "D", 19, "dungeons", { d }, 610),
        groupListing(5, "Perrin Quickbrook", "dungeons", { b }, 320,
            { { "PALADIN", "T", 21 }, { "MAGE", "D", 20 }, { "WARLOCK", "D", 22 } }, { T = 0, H = 1, D = 1 }),
        groupListing(6, "Nyssa Juniperfall", "dungeons", { c }, 190,
            { { "DRUID", "H", 19 }, { "ROGUE", "D", 20 }, { "MAGE", "D", 21 }, { "HUNTER", "D", 19 } },
            { T = 1, H = 0, D = 0 }),
    }
end

-- The party's members as Party.members gives them.
local function member(name, class, wowRole, level, spec)
    specs[name] = spec
    return { name = name, classToken = class, wowRole = wowRole, level = level }
end

local function charDb(tab, extra)
    local lastDungeons = {}
    for _, id in ipairs(dungeonIds()) do
        lastDungeons[id] = true
    end
    local db = { tab = tab, lastRoles = "TD", lastDungeons = lastDungeons, playstyle = RELAXED, bgSize = 10,
        questUnticked = {}, battlegroundUnticked = {} }
    for key, value in pairs(extra or {}) do
        db[key] = value
    end
    return db
end

local function baseWorld(now, state, tab, extra)
    local ids = dungeonIds()
    local searchedAt = GetTime() - 15
    return {
        state = state, members = {}, charDb = charDb(tab, extra), engine = dungeonEngine(now, ids),
        questEngine = newEngine(ns.Protocol.QUESTS, ns.QuestMatch),
        bgEngine = newEngine(ns.Protocol.BATTLEGROUNDS, ns.BgMatch),
        listings = dungeonListings(ids), zoneListings = {}, bgListings = {}, searchedAt = searchedAt,
        places = {}, drawer = false,
    }
end

local function queued(now)
    local w = baseWorld(now, "solo", "dungeons")
    local ids = dungeonIds()
    local entry = w.engine.queue:upsert({
        id = NAME, joinedAt = now - 263, dungeons = { ids[1], ids[2] or ids[1], ids[3] or ids[1] },
        members = { { name = NAME, roles = "T", level = LEVEL } }, playstyle = RELAXED, spec = SPEC_CODE,
    }, now)
    w.engine.myEntry = entry
    return w
end

local SCENES = {}

SCENES[1] = function(now)
    local w = baseWorld(now, "solo", "dungeons")
    w.drawer = true
    return w
end

SCENES[2] = function(now)
    local Compose = ns.Compose
    local w = baseWorld(now, "leader", "dungeons", {
        lastRoles = "T", composeOn = true, levelsOn = true, levelLimit = { min = 18, max = 24 },
        compose = { masks = { 0, 0, Compose.maskOf({ "MAGE" }), Compose.maskOf({ "ROGUE", "WARRIOR" }), 0 } },
    })
    w.members = { member("Brynna Coldbrook", "PRIEST", "H", 21, "PRIEST2") }
    return w
end

SCENES[3] = queued

SCENES[4] = function(now)
    local w = queued(now)
    local players = {
        { NAME, "T", SPEC_CODE }, { "Morwen Valecrest", "H", "SHAMAN3", "Y" }, { "Corvin Ashvale", "D", "MAGE3", "Y" },
        { "Dagny Ironveil", "D", "ROGUE2" }, { "Jorund Deepforge", "D", "HUNTER2", "Y" },
    }
    local entries = {}
    for i, player in ipairs(players) do
        entries[i] = { { name = player[1], role = player[2] } }
    end
    local engine = w.engine
    local proposal = ns.Proposal.new({ matchmaker = "Morwen Valecrest", seq = 1, dungeon = "5", missing = "",
        playstyles = { RELAXED }, entries = entries, now = now - 2 }, engine.config)
    proposal.isLocal = true
    proposal.specs = {}
    local members = {}
    for i, player in ipairs(players) do
        proposal.specs[player[1]] = player[3]
        proposal.answers[player[1]] = player[4]
        members[i] = { name = player[1], role = player[2], owner = player[1], answer = player[4], spec = player[3] }
    end
    engine.proposals[proposal.key] = proposal
    engine.myProposalKey = proposal.key
    w.proposal = { key = proposal.key, dungeon = "5", leader = NAME, matchmaker = proposal.matchmaker,
        members = members, missing = "", playstyles = { RELAXED }, deadline = proposal.answerDeadline }
    return w
end

SCENES[5] = function(now)
    local w = baseWorld(now, "member", "dungeons")
    w.members = {
        member("Brynna Coldbrook", "PRIEST", "H", 21, "PRIEST2"),
        member("Corvin Ashvale", "MAGE", "D", 20, "MAGE3"),
        member("Dagny Ironveil", "ROGUE", "D", 19, "ROGUE2"),
        member("Jorund Deepforge", "HUNTER", "D", 21, "HUNTER2"),
    }
    w.context = { dungeon = "5", playstyles = { RELAXED }, startedAt = now - 300, joined = true, announced = true }
    w.places = { [NAME] = 6, ["Brynna Coldbrook"] = 12, ["Corvin Ashvale"] = 25, ["Dagny Ironveil"] = 120,
        ["Jorund Deepforge"] = false }
    w.share = { dungeon = "5", summary = {
        mine = 3, theyHave = { "Collecting Memories" },
        members = { { name = "Brynna Coldbrook", count = 2 }, { name = "Corvin Ashvale", count = 3 },
            { name = "Dagny Ironveil", count = 1 }, { name = "Jorund Deepforge" } },
    } }
    w.questGroup = { dungeon = "5", quests = { 214, 166, 168 }, turnedIn = {}, seen = {}, startedAt = now - 300 }
    local titles = DUNGEON_QUESTS["5"]
    w.questRows = {
        { title = titles[1], lines = { { name = L["You"], text = "6/10" }, { name = "Brynna Coldbrook", text = "4/10" },
            { name = "Corvin Ashvale", text = L["ready to turn in"] }, { name = "Dagny Ironveil", text = "2/10" } } },
        { title = titles[2], lines = { { name = L["You"], text = "0/1" }, { name = "Brynna Coldbrook", text = "0/1" },
            { name = "Corvin Ashvale", text = "0/1" }, { name = "Dagny Ironveil", text = "-" } } },
        { title = titles[3], lines = { { name = L["You"], text = "1/2" }, { name = "Brynna Coldbrook", text = "-" },
            { name = "Corvin Ashvale", text = "1/2" }, { name = "Dagny Ironveil", text = "1/2" } } },
    }
    w.without = { "Jorund Deepforge" }
    return w
end

SCENES[6] = function(now)
    local w = baseWorld(now, "solo", "quests")
    local quests = w.questEngine
    enqueue(quests, now, { { "Haldor Stormbanner", "T", 22, "WARRIOR3" } }, { questKey(1) }, 120)
    enqueue(quests, now, { { "Isolde Moonwhistle", "H", 20, "DRUID3" } }, { questKey(1), questKey(2) }, 300)
    enqueue(quests, now, { { "Talia Brightforge", "D", 23, "MAGE2" } }, { questKey(2) }, 45)
    enqueue(quests, now, { { "Orrin Pinecrest", "D", 19, "WARRIOR2" } }, { questKey(3) }, 200)
    w.zoneListings = {
        soloListing(11, "Rowan Oakhollow", "ROGUE", "D", 21, "zones", { "Redridge Mountains" }, 180),
        soloListing(12, "Gwyra Lightwater", "PRIEST", "H", 20, "zones", { "Loch Modan" }, 420),
        groupListing(13, "Kaelis Hollowmere", "zones", { "Redridge Mountains" }, 260,
            { { "WARRIOR", "T", 22 }, { "SHAMAN", "D", 21 } }, { T = 0, H = 1, D = 2 }),
    }
    w.drawer = true
    return w
end

SCENES[7] = function(now)
    local w = baseWorld(now, "leader", "quests")
    w.members = {
        member("Haldor Stormbanner", "WARRIOR", "T", 22, "WARRIOR3"),
        member("Elowen Frostmantle", "PRIEST", "H", 21, "PRIEST1"),
    }
    w.questGroup = { quests = { QUESTS[1][1], QUESTS[2][1] }, core = { QUESTS[1][1] }, turnedIn = {}, seen = {},
        startedAt = now - 900 }
    w.questRows = {
        { title = QUESTS[1][2], lines = { { name = L["You"], text = "0/1" },
            { name = "Haldor Stormbanner", text = "0/1" }, { name = "Elowen Frostmantle", text = "0/1" } } },
        { title = QUESTS[2][2], lines = { { name = L["You"], text = L["ready to turn in"] },
            { name = "Haldor Stormbanner", text = L["ready to turn in"] },
            { name = "Elowen Frostmantle", text = "-" } } },
    }
    w.progress = true
    return w
end

SCENES[8] = function(now)
    local w = baseWorld(now, "solo", "battlegrounds")
    local bg = w.bgEngine
    enqueue(bg, now, { { "Brom Kettleborn", "D", 24, "WARRIOR2" } }, { bgKey("wsg") }, 140)
    enqueue(bg, now, { { "Ilsa Amberline", "H", 22, "PRIEST2" } }, { bgKey("wsg"), bgKey("ab") }, 380)
    enqueue(bg, now, { { "Torvin Blackbriar", "D", 27, "ROGUE1" }, { "Maren Silverbough", "H", 26, "DRUID3" } },
        { bgKey("ab") }, 95)
    local wren = soloListing(21, "Wren Umberfield", "HUNTER", "D", 21, "battlegrounds", { "wsg" }, 230)
    local zephyra = groupListing(22, "Zephyra Duskwhisper", "battlegrounds", { "wsg" }, 410,
        { { "MAGE", "D", 24 }, { "PRIEST", "H", 23 }, { "WARRIOR", "T", 25 } })
    zephyra.open = 7
    w.bgListings = { wren, zephyra }
    w.drawer = true
    return w
end

-- The player's party as GroupView sees it: the player first.
local function groupMembers()
    local list = { { name = NAME, role = SPEC.roles, classToken = CLASS } }
    for _, item in ipairs(world.members) do
        list[#list + 1] = { name = item.name, role = item.wowRole, classToken = item.classToken }
    end
    return list
end

local function treeOf(name)
    if name == NAME then
        return SPEC.index, SPEC.name
    end
    local token, index = ns.Specs.decode(specs[name])
    local tree = token and ns.Specs.tree(token, index)
    return index, tree and tree.name
end

local function patchAll()
    local Party, LfgList = ns.Party, ns.LfgList
    patch(Party, "playerClass", function()
        return CLASS
    end)
    patch(Party, "playerLevel", function()
        return LEVEL
    end)
    patch(Party, "state", function()
        return world.state
    end)
    patch(Party, "inGroup", function()
        return world.state ~= "solo"
    end)
    patch(Party, "members", function()
        local list = {}
        for i, item in ipairs(world.members) do
            list[i] = { name = item.name, classToken = item.classToken, wowRole = item.wowRole, level = item.level }
        end
        return list
    end)
    patch(ns.Spec, "current", function()
        return SPEC
    end)
    patch(ns.Spec, "treesOf", function()
        return nil
    end)
    patch(ns.Spec, "treeOf", function(name)
        return select(2, treeOf(name))
    end)
    patch(ns.Spec, "indexOf", function(name)
        return (treeOf(name))
    end)
    patch(ns.Spec, "remember", function(view)
        for _, item in ipairs(view and view.members or {}) do
            specs[item.name] = item.spec or specs[item.name]
        end
    end)
    patch(ns.GroupView, "members", groupMembers)
    patch(ns.GroupView, "isListed", function()
        return false
    end)
    patch(ns.QuestGroup, "current", function()
        return world.questGroup
    end)
    patch(ns.QuestGroup, "rows", function()
        return world.questRows or {}, world.without or {}
    end)
    patch(ns.Quests, "groupQuests", function()
        return world.quests
    end)
    patch(ns.Quests, "forDungeon", function(id)
        return DUNGEON_QUESTS[id] or {}
    end)
    patch(ns.Quests, "entriesFor", function()
        return {}
    end)
    patch(ns.Quests, "has", function()
        return false
    end)
    patch(ns.QuestShare, "summary", function(dungeon)
        return world.share and world.share.dungeon == dungeon and world.share.summary or nil
    end)
    patch(ns.GroupPlaces, "of", function(name)
        return world.places[name]
    end)
    patch(ns.Presence, "others", function()
        return { "Brynna Coldbrook", "Corvin Ashvale", "Haldor Stormbanner", "Morwen Valecrest" }
    end)
    patch(ns.BgFinder, "queueStatus", function()
        return nil
    end)
    patch(LfgList, "listings", function()
        return world.listings, world.searchedAt
    end)
    patch(LfgList, "zoneListings", function()
        return world.zoneListings, world.searchedAt
    end)
    patch(LfgList, "battlegroundListings", function()
        return world.bgListings, world.searchedAt
    end)
    patch(LfgList, "version", function()
        return world.version
    end)
    for _, key in ipairs({ "hasSearched", "isSearched", "zoneSearched", "battlegroundsSearched" }) do
        patch(LfgList, key, function()
            return true
        end)
    end
    patch(LfgList, "isSearching", function()
        return false
    end)
    patch(LfgList, "zoneActivity", function()
        return 1
    end)
    patch(LfgList, "zonesForLevel", function()
        return { "Redridge Mountains", "Loch Modan", "Wetlands" }
    end)
end

local BAR_TOP = 38
local BUTTON_ROW = 30
local STRATA = "FULLSCREEN_DIALOG"
local GOLD = { 1, 0.82, 0, 1 }
local DIM = { 0, 0, 0, 0.6 }
local WELCOME = ns.Locale.mark("Pick your roles, press Find group, and your group forms itself, for dungeons, group "
    .. "quests and battlegrounds. This short demo shows how, with example players; nothing is sent.")

-- The steps of the screen shown that have their part on screen, and the
-- one shown; before the first screen's steps comes the welcome.
local steps = {}
local stepIndex = 1
local welcoming = false
local highlight
local dims = {}

local function scaleOf(frame)
    local scale = frame and frame:GetEffectiveScale()
    return type(scale) == "number" and scale > 0 and scale or 1
end

-- A frame's edges in screen pixels, or nil while it has no place yet.
local function rect(frame)
    local left, right, top, bottom = frame:GetLeft(), frame:GetRight(), frame:GetTop(), frame:GetBottom()
    if type(left) ~= "number" or type(right) ~= "number" or type(top) ~= "number" or type(bottom) ~= "number" then
        return nil
    end
    local scale = scaleOf(frame)
    return { left = left * scale, right = right * scale, top = top * scale, bottom = bottom * scale }
end

local function newDim()
    local dim = CreateFrame("Frame", nil, UIParent)
    dim:SetAllPoints(UIParent)
    dim:SetFrameStrata(STRATA)
    dim:SetFrameLevel(1)
    dim.bands = {}
    for i = 1, 4 do
        local band = dim:CreateTexture(nil, "BACKGROUND")
        band:SetColorTexture(DIM[1], DIM[2], DIM[3], DIM[4])
        dim.bands[i] = band
    end
    return dim
end

-- A window darkened all over, or around the outlined part where it lies on
-- the window: four bands above, below, left and right of it.
local function placeDim(dim, host, spot)
    local area = rect(host)
    local bands = dim.bands
    for _, band in ipairs(bands) do
        band:ClearAllPoints()
        band:Hide()
    end
    if not area then
        return
    end
    local top, bottom, left, right = bands[1], bands[2], bands[3], bands[4]
    local inside = spot and {
        left = math.max(spot.left, area.left), right = math.min(spot.right, area.right),
        top = math.min(spot.top, area.top), bottom = math.max(spot.bottom, area.bottom),
    }
    if not inside or inside.left >= inside.right or inside.bottom >= inside.top then
        top:SetAllPoints(host)
        top:Show()
        return
    end
    local unit = scaleOf(UIParent)
    local upper, lower = (inside.top - area.top) / unit, (inside.bottom - area.top) / unit
    top:SetPoint("TOPLEFT", host, "TOPLEFT")
    top:SetPoint("BOTTOMRIGHT", host, "TOPRIGHT", 0, upper)
    bottom:SetPoint("TOPLEFT", host, "TOPLEFT", 0, lower)
    bottom:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT")
    left:SetPoint("TOPLEFT", host, "TOPLEFT", 0, upper)
    left:SetPoint("BOTTOMRIGHT", host, "TOPLEFT", (inside.left - area.left) / unit, lower)
    right:SetPoint("TOPLEFT", host, "TOPLEFT", (inside.right - area.left) / unit, upper)
    right:SetPoint("BOTTOMRIGHT", host, "TOPRIGHT", 0, lower)
    for _, band in ipairs(bands) do
        band:Show()
    end
end

-- The main window, Who is looking and the group popup: all darkened during
-- the welcome, and around the outlined part during a step.
local function placeOverlay()
    local outlined = highlight ~= nil and highlight:IsShown()
    local spot = outlined and rect(highlight) or nil
    local popup = ns.Popup.parts()
    local hosts = { ns.WindowParts.frame, ns.QueueWindow.frame(), popup }
    for i = 1, 3 do
        dims[i] = dims[i] or newDim()
        local host = hosts[i]
        if host and host:IsVisible() and (welcoming or outlined) then
            dims[i]:Show()
            placeDim(dims[i], host, not welcoming and spot or nil)
        else
            dims[i]:Hide()
        end
    end
end

-- On top of the main window (or the group popup while the window steps
-- aside), moving with it; under it when the window is too close to the top
-- of the screen.
local function placeBar()
    local window = ns.WindowParts.frame
    local popup = ns.Popup.parts()
    local host = (window and window:IsVisible() and window) or (popup and popup:IsVisible() and popup) or nil
    bar:ClearAllPoints()
    if not host then
        bar:SetScale(1)
        bar:SetPoint("TOP", UIParent, "TOP", 0, -12)
        return
    end
    bar:SetScale(scaleOf(host) / scaleOf(UIParent))
    local area, screen = rect(host), rect(UIParent)
    local height = (bar:GetHeight() or 0) * scaleOf(bar)
    if area and screen and screen.top - area.top < height + 4 then
        bar:SetPoint("TOP", host, "BOTTOM", 0, -2)
    else
        bar:SetPoint("BOTTOM", host, "TOP", 0, 2)
    end
end

local function textOf(step)
    if type(step.text) == "table" then
        local list = {}
        for i, text in ipairs(step.text) do
            list[i] = L[text]
        end
        return table.concat(list, " ")
    end
    return L[step.text]
end

local function atEnd()
    return current == #SCENES and stepIndex == #steps
end

local function paintBar()
    local step = steps[stepIndex]
    if welcoming then
        bar.label:SetText(L["Welcome to Forever Groups"])
        bar.text:SetText(L[WELCOME])
        bar.count:SetText("")
    else
        bar.label:SetText(string.format("%d/%d  ·  %s", current, #SCENES, L[TITLES[current]]))
        bar.text:SetText(step and textOf(step) or "")
        bar.count:SetText(#steps > 1 and string.format(L["Step %d of %d"], stepIndex, #steps) or "")
    end
    local last = not welcoming and atEnd()
    bar.prev:SetShown(not welcoming)
    bar.next:SetShown(not welcoming)
    Widgets.setEnabled(bar.next, not last)
    bar.start:SetShown(welcoming)
    bar.skip:SetShown(welcoming)
    bar.done:SetShown(last)
    local height = bar.text:GetStringHeight()
    bar:SetHeight(BAR_TOP + math.ceil(type(height) == "number" and height or 28) + 10
        + ((welcoming or last) and BUTTON_ROW or 0))
end

local function showStep()
    local step = not welcoming and steps[stepIndex]
    local first, last
    if step and step.target then
        first, last = step.target()
    end
    if first then
        highlight:ClearAllPoints()
        highlight:SetPoint("TOPLEFT", first, "TOPLEFT", -5, 5)
        highlight:SetPoint("BOTTOMRIGHT", last or first, "BOTTOMRIGHT", 5, -5)
        highlight:Show()
    else
        highlight:Hide()
    end
    paintBar()
    placeBar()
    placeOverlay()
end

local function visibleSteps(index)
    local list = {}
    for _, step in ipairs(STEPS[index]) do
        if step.target() then
            list[#list + 1] = step
        end
    end
    if #list == 0 then
        list[1] = { text = STEPS[index][1].text }
    end
    return list
end

-- at: "last" to land on the screen's last step (going back).
local function showScene(index, at)
    current = index
    ns.Popup.hide()
    builds = builds + 1
    local now = GetServerTime()
    world = SCENES[index](now)
    world.quests = questList()
    world.version = 1000000 + builds
    ns.charDb = world.charDb
    ns.engine, ns.questEngine, ns.bgEngine = world.engine, world.questEngine, world.bgEngine
    ns.GroupView.swapContext(world.context)
    ns.db.progressExpanded = world.progress == true
    local W = ns.WindowParts
    W.showOthers, W.lastGroupTab = false, nil
    ns.Window.show()
    ns.QueueWindow.setShown(world.drawer)
    ns.Window.refresh()
    ns.Status.refresh()
    if world.proposal then
        ns.Popup.show(world.proposal, world.engine)
    end
    steps = visibleSteps(index)
    stepIndex = at == "last" and #steps or 1
    showStep()
end

-- Next and Previous go through the steps of a screen, then on to the next
-- screen or back to the last step of the one before; back from the first
-- step is the welcome, on from the last ends the demo.
local function move(delta)
    if welcoming then
        if delta > 0 then
            welcoming = false
            showStep()
        end
        return
    end
    local index = stepIndex + delta
    if index < 1 then
        if current == 1 then
            welcoming = true
            showStep()
        else
            showScene(current - 1, "last")
        end
    elseif index > #steps then
        if current < #SCENES then
            showScene(current + 1)
        else
            Demo.stop()
        end
    else
        stepIndex = index
        showStep()
    end
end

local function guarded(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        Demo.stop()
        Log.warn("The demo stopped after an error: %s", tostring(err))
    end
end

function Demo.show(index)
    if on then
        welcoming = false
        guarded(showScene, math.max(1, math.min(#SCENES, index)))
    end
end

function Demo.step(delta)
    if on then
        guarded(move, delta)
    end
end

local function arrow(direction, label, delta)
    local button = CreateFrame("Button", nil, bar)
    button:SetSize(26, 26)
    local base = "Interface\\Buttons\\UI-SpellbookIcon-" .. direction .. "Page-"
    button:SetNormalTexture(base .. "Up")
    button:SetPushedTexture(base .. "Down")
    button:SetDisabledTexture(base .. "Disabled")
    button:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    button:SetScript("OnClick", function()
        Demo.step(delta)
    end)
    Widgets.tooltip(button, label)
    button.iconLabel = label
    return button
end

local function buildHighlight()
    highlight = Widgets.backdropFrame("Frame", UIParent)
    highlight:SetFrameStrata(STRATA)
    highlight:SetFrameLevel(20)
    Widgets.addOutline(highlight)
    Widgets.paintOutline(highlight, { 1, 0.82, 0, 0.05 }, GOLD)
    highlight:SetScript("OnUpdate", function(self)
        self:SetAlpha(0.55 + 0.45 * math.abs(math.sin(GetTime() * 3)))
    end)
    highlight:Hide()
end

local function buildBar()
    local width = ns.WindowParts.WIDTH
    bar = Widgets.backdropFrame("Frame", UIParent)
    bar:SetSize(width, 80)
    bar:SetPoint("TOP", UIParent, "TOP", 0, -12)
    bar:SetFrameStrata(STRATA)
    bar:SetFrameLevel(30)
    bar:SetClampedToScreen(true)
    bar:EnableMouse(true)
    Widgets.addOutline(bar)
    Widgets.paintOutline(bar, { 0.06, 0.06, 0.07, 0.97 }, { 1, 0.82, 0, 0.6 })
    local logo = Widgets.roundIcon(bar, Widgets.ICON, 18)
    logo:SetPoint("TOPLEFT", 10, -10)
    -- So a new player never takes a screen of the demo for a real group.
    local tag = Widgets.backdropFrame("Frame", bar)
    Widgets.addOutline(tag)
    Widgets.paintOutline(tag, { 1, 0.5, 0.1, 0.25 }, { 1, 0.5, 0.1, 1 })
    tag.label = Widgets.text(tag, "GameFontNormalSmall", "CENTER")
    tag.label:SetPoint("CENTER")
    tag.label:SetText(L["Example"])
    tag.label:SetTextColor(1, 0.6, 0.2)
    tag:SetSize(math.max(60, math.ceil(tag.label:GetStringWidth() or 50) + 16), 18)
    tag:SetPoint("LEFT", logo, "RIGHT", 8, 0)
    bar.tag = tag
    bar.prev = arrow("Prev", ns.Locale.mark("Previous"), -1)
    bar.prev:SetPoint("LEFT", tag, "RIGHT", 6, 0)
    bar.close = CreateFrame("Button", nil, bar, "UIPanelCloseButton")
    bar.close:SetPoint("TOPRIGHT", -4, -4)
    bar.close:SetScript("OnClick", function()
        Demo.stop()
    end)
    Widgets.tooltip(bar.close, "End the demo")
    bar.close.iconLabel = "End the demo"
    bar.next = arrow("Next", ns.Locale.mark("Next"), 1)
    bar.next:SetPoint("RIGHT", bar.close, "LEFT", -6, 0)
    bar.count = Widgets.text(bar, "GameFontDisableSmall", "RIGHT")
    bar.count:SetPoint("RIGHT", bar.next, "LEFT", -6, 0)
    bar.label = Widgets.text(bar, "GameFontNormal", "CENTER")
    bar.label:SetPoint("LEFT", bar.prev, "RIGHT", 6, 0)
    bar.label:SetPoint("RIGHT", bar.count, "LEFT", -6, 0)
    bar.label:SetWordWrap(false)
    bar.text = Widgets.text(bar, "GameFontHighlightSmall")
    bar.text:SetPoint("TOPLEFT", 14, -BAR_TOP)
    bar.text:SetWidth(width - 28)
    bar.text:SetJustifyH("LEFT")
    bar.skip = Widgets.button(bar, "Skip", 100)
    bar.skip:SetPoint("BOTTOMRIGHT", -14, 10)
    bar.skip:SetScript("OnClick", function()
        Demo.stop()
    end)
    bar.start = Widgets.button(bar, "Show me around", 150)
    bar.start:SetPoint("RIGHT", bar.skip, "LEFT", -8, 0)
    bar.start:SetScript("OnClick", function()
        Demo.step(1)
    end)
    bar.done = Widgets.button(bar, "Done", 100)
    bar.done:SetPoint("BOTTOMRIGHT", -14, 10)
    bar.done:SetScript("OnClick", function()
        Demo.stop()
    end)
    -- The window may move, grow or step aside for the popup: the bar and the
    -- darkening follow it a few times a second.
    local elapsed = 0
    bar:SetScript("OnUpdate", function(_, delta)
        elapsed = elapsed + (delta or 0)
        if elapsed >= 0.2 and on then
            elapsed = 0
            placeBar()
            placeOverlay()
        end
    end)
    buildHighlight()
end

local function isIdle()
    for _, engine in ipairs(ns.Queues.engines()) do
        if engine.myEntry then
            return false
        end
    end
    return not ns.Queues.anyProposalOpen() and not ns.Filler.isActive() and not ns.BgFinder.isActive()
        and not ns.Apply.isSeeker() and ns.Group.status() == nil and ns.Party.state() == "solo"
        and not IsInInstance() and not InCombatLockdown()
end

-- auto: the first-time start, which says nothing when it cannot start yet.
function Demo.start(auto)
    if on then
        return false
    end
    if not ns.engine then
        if not auto then
            Log.info("Not connected yet.")
        end
        return false
    end
    if not isIdle() then
        if not auto then
            Log.info("The demo only starts while nothing else is going on: not in a queue, a group, an instance or "
                .. "a fight.")
        end
        return false
    end
    -- Before ns.db becomes the demo's copy, so a crash or /reload during it
    -- can't bring it back.
    ns.db.tourSeen = true
    if not bar then
        buildBar()
    end
    local W = ns.WindowParts
    saved = {
        selfName = ns.selfName, db = ns.db, charDb = ns.charDb, engine = ns.engine, questEngine = ns.questEngine,
        bgEngine = ns.bgEngine, windowShown = ns.Window.isShown(), drawerShown = ns.QueueWindow.isShown(),
        showOthers = W.showOthers, lastGroupTab = W.lastGroupTab,
    }
    on = true
    saved.context = ns.GroupView.swapContext(nil)
    ns.selfName = NAME
    ns.db = demoDb(saved.db)
    patchAll()
    bar:Show()
    Log.info("Demo: every screen with example data; nothing is sent. Step through with the bar at the top; "
        .. "/fg demo again ends it.")
    welcoming = true
    guarded(showScene, 1)
    return true
end

-- Runs every step even when one fails, so the addon is always back to
-- itself afterwards.
function Demo.stop()
    if not on then
        return
    end
    local function try(fn)
        local ok, err = pcall(fn)
        if not ok then
            geterrorhandler()(err)
        end
    end
    try(function()
        ns.Popup.hide()
    end)
    try(function()
        if saved.windowShown then
            ns.Window.show()
            ns.QueueWindow.setShown(saved.drawerShown)
        elseif ns.Window.isShown() then
            ns.Window.toggle()
        end
    end)
    unpatchAll()
    ns.GroupView.swapContext(saved.context)
    ns.selfName, ns.db, ns.charDb = saved.selfName, saved.db, saved.charDb
    ns.engine, ns.questEngine, ns.bgEngine = saved.engine, saved.questEngine, saved.bgEngine
    local W = ns.WindowParts
    W.showOthers, W.lastGroupTab = saved.showOthers, saved.lastGroupTab
    world, saved, specs = nil, nil, {}
    on = false
    welcoming = false
    if bar then
        bar:Hide()
        highlight:Hide()
    end
    for _, dim in ipairs(dims) do
        dim:Hide()
    end
    try(ns.Window.refresh)
    try(ns.Status.refresh)
    -- Channel messages were not read while it ran: the queues ask for
    -- everyone's entries again.
    try(ns.Comm.resync)
    Log.info("Demo ended.")
end

function Demo.toggle()
    if on then
        Demo.stop()
    else
        Demo.start()
    end
end

-- The first time a new player opens the window (db.tourSeen false), once
-- the window has its layout; tried again on each opening, and once
-- connected, until it could start.
function Demo.maybeStart()
    if on or ns.db.tourSeen ~= false then
        return
    end
    C_Timer.After(0.3, function()
        if not on and ns.db.tourSeen == false and ns.Window.isShown() then
            Demo.start(true)
        end
    end)
end

local WELCOME_DELAY = 5

local function openForWelcome()
    if InCombatLockdown() then
        ns.on("PLAYER_REGEN_ENABLED", function()
            if not ns.db.welcomed then
                openForWelcome()
            end
        end)
        return
    end
    ns.db.welcomed = true
    ns.Window.show()
end

-- At a new player's first login the window opens by itself a few seconds in
-- (after a fight, if one is going on), and the demo with it.
function Demo.welcome()
    if ns.db.tourSeen ~= false or ns.db.welcomed then
        return
    end
    C_Timer.After(WELCOME_DELAY, function()
        if not ns.db.welcomed then
            openForWelcome()
        end
    end)
end

local STOPS = { PLAYER_REGEN_DISABLED = true, PLAYER_ENTERING_WORLD = true, PLAYER_LOGOUT = true }
local PASSES = { CHAT_MSG_CHANNEL_NOTICE = true }

-- While it runs: whether an event still reaches the handlers. Fighting,
-- loading, logging out or joining a group ends the demo first.
function Demo.passes(event)
    if STOPS[event] or (event == "GROUP_ROSTER_UPDATE" and IsInGroup()) then
        Demo.stop()
        return true
    end
    return PASSES[event] == true
end

ns.on("PLAYER_REGEN_DISABLED", Demo.stop)

ns.Demo = Demo
