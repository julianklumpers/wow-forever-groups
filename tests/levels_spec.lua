local World = require("tests.helpers.wowmock")
local Levels = require("core.levels")
local Matchmaker = require("core.matchmaker")
local QuestMatch = require("core.questmatch")
local Protocol = require("core.protocol")
local Config = require("core.config")

local NOW = 1000000
local CONNECT = 30
local LEAD = "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:16:16|t Lead a group"

local function entry(id, joinedAt, roles, level, extra)
    local e = { id = id, joinedAt = joinedAt, dungeons = { "5" },
        members = { { name = id, roles = roles, level = level } } }
    for key, value in pairs(extra or {}) do
        e[key] = value
    end
    return e
end

local function names(group)
    local list = {}
    for _, member in ipairs(group.members) do
        list[#list + 1] = member.name
    end
    table.sort(list)
    return list
end

describe("a level limit", function()
    it("travels in a queue entry, with an open side as 0", function()
        local text = Levels.encode({ untilAt = NOW + 180, min = 18, max = 0 })
        assert.are.equal("1000180:18:0", text)
        assert.are.same({ untilAt = NOW + 180, min = 18, max = 0 }, Levels.decode(text))
        assert.is_nil(Levels.decode("5:20:18"))
        assert.is_nil(Levels.encode({ min = 0, max = 0 }))
        local msg = { kind = "queue", joinedAt = 5, dungeons = { "5" }, members = { { name = "Lead-R", roles = "T",
            level = 20 } }, levels = text }
        assert.are.equal(text, Protocol.decode(Protocol.encode(msg)).levels)
    end)

    it("lets in only levels within it, an unknown one not", function()
        local range = { min = 15, max = 20, untilAt = 0 }
        assert.is_true(Levels.fits(range, 15))
        assert.is_false(Levels.fits(range, 21))
        assert.is_false(Levels.fits(range, nil))
        assert.is_true(Levels.fits({ min = 18, max = 0 }, 60))
        assert.is_false(Levels.overlaps(range, 22, 30))
        assert.is_true(Levels.overlaps(range, 13, 18))
    end)
end)

describe("matchmaking with a level limit", function()
    local limit = Levels.encode({ untilAt = NOW + 60, min = 18, max = 22 })

    it("takes only players within it, until the limit ends", function()
        local list = {
            entry("Lead", 1, "T", 20, { lead = true, levels = limit }),
            entry("Heal", 2, "H", 19),
            entry("Low", 3, "D", 15),
            entry("Dps1", 4, "D", 20),
            entry("Dps2", 5, "D", 21),
            entry("Dps3", 6, "D", 22),
        }
        local groups = Matchmaker.findGroups(list, Config.SLOTS, NOW)
        assert.are.same({ "Dps1", "Dps2", "Dps3", "Heal", "Lead" }, names(groups[1]))
        assert.are.equal("Lead", groups[1].leader)
        table.remove(list, 6)
        assert.are.same({}, Matchmaker.findGroups(list, Config.SLOTS, NOW))
        assert.are.equal(1, #Matchmaker.findGroups(list, Config.SLOTS, NOW + 61))
    end)

    it("holds for questing groups too", function()
        local key = "176-3"
        local list = {
            { id = "Lead", joinedAt = 1, dungeons = { key }, levels = limit, lead = true,
                members = { { name = "Lead", roles = "T", level = 20 } } },
            { id = "Low", joinedAt = 2, dungeons = { key }, members = { { name = "Low", roles = "D", level = 12 } } },
            { id = "Fit", joinedAt = 3, dungeons = { key }, members = { { name = "Fit", roles = "D", level = 19 } } },
            { id = "Fit2", joinedAt = 4, dungeons = { key }, members = { { name = "Fit2", roles = "H", level = 21 } } },
        }
        local groups = QuestMatch.findGroups(list, nil, NOW)
        assert.are.equal(1, #groups)
        assert.are.same({ "Fit", "Fit2", "Lead" }, names(groups[1]))
    end)

    it("takes players who queued before the leader too", function()
        local list = {
            entry("Heal", 1, "H", 19),
            entry("Lead", 2, "T", 20, { lead = true, levels = limit }),
            entry("Dps1", 3, "D", 20),
            entry("Dps2", 4, "D", 21),
            entry("Dps3", 5, "D", 22),
        }
        local groups = Matchmaker.findGroups(list, Config.SLOTS, NOW)
        assert.are.equal(1, #groups)
        assert.are.equal("Lead", groups[1].leader)
        local key = "176-3"
        local quests = {
            { id = "Fit", joinedAt = 1, dungeons = { key }, members = { { name = "Fit", roles = "D", level = 19 } } },
            { id = "Lead", joinedAt = 2, dungeons = { key }, levels = limit, lead = true,
                members = { { name = "Lead", roles = "T", level = 20 } } },
            { id = "Fit2", joinedAt = 3, dungeons = { key }, members = { { name = "Fit2", roles = "H", level = 21 } } },
        }
        assert.are.equal(1, #QuestMatch.findGroups(quests, nil, NOW))
    end)
end)

describe("limiting levels in the window", function()
    local function leader(world)
        local client = world:addClient("Lead Player", { level = 20 })
        world:advance(CONNECT)
        client:slash("/dq")
        client:click("CheckButton", "Tank")
        client:click("Button", LEAD)
        return client
    end

    local function tickedRange(client)
        local low, high
        for _, id in ipairs(client.ns.WindowParts.selectedVisibleIds()) do
            local dungeon = client.ns.Dungeons.get(id)
            low = math.min(low or dungeon.min, dungeon.min)
            high = math.max(high or dungeon.max, dungeon.max)
        end
        return tostring(low), tostring(high)
    end

    it("starts at the ticked dungeons' levels, keeps what is typed, warns about a dungeon outside it", function()
        local world = World.new()
        local client = leader(world)
        assert.is_nil(client:findText("^from$"))
        client:click("CheckButton", "Limit levels")
        local ui = client.ns.WindowParts.ui
        local low, high = tickedRange(client)
        assert.are.same({ low, high }, { ui.levelsMin.text, ui.levelsMax.text })
        ui.levelsMin.scripts.OnEditFocusLost(ui.levelsMin)
        assert.are.same({}, client.ns.charDb.levelLimit)
        ui.levelsMax:SetText("25")
        ui.levelsMax.scripts.OnEditFocusLost(ui.levelsMax)
        assert.are.same({ max = 25 }, client.ns.charDb.levelLimit)
        client:click("Button", "None")
        assert.are.same({ "17", "25" }, { ui.levelsMin.text, ui.levelsMax.text })
        client:click("Button", "All")
        assert.are.equal("25", ui.levelsMax.text)
        ui.levelsMin:SetText("27")
        ui.levelsMin.scripts.OnEditFocusLost(ui.levelsMin)
        assert.are.same({ min = 27, max = 27 }, client.ns.charDb.levelLimit)
        assert.is_not_nil(client:findText("^Nobody fits your level limit for: .*The Deadmines %(17%-26%)"))
        ui.levelsMin:SetText("")
        ui.levelsMin.scripts.OnEditFocusLost(ui.levelsMin)
        assert.are.same({ max = 27 }, client.ns.charDb.levelLimit)
        ui.levelsMin:SetText("27")
        ui.levelsMin.scripts.OnEditFocusLost(ui.levelsMin)
        client:click("CheckButton", "Limit levels")
        assert.is_nil(client:findText("^Nobody fits"))
        assert.are.same({ min = 27, max = 27 }, client.ns.charDb.levelLimit)
        client:click("Button", "Quests")
        assert.is_nil(client:find("CheckButton", "Limit levels"))
        client:click("Button", LEAD)
        assert.is_not_nil(client:find("CheckButton", "Limit levels"))
    end)

    it("keeps three levels around the player on the Quests tab, a typed level staying put", function()
        local world = World.new()
        local client = world:addClient("Lead Player", { level = 10 })
        client.ns.charDb.levelLimit = { min = 6, max = 12, at = 10 }
        world:advance(CONNECT)
        local PartyLevels = client.ns.PartyLevels
        assert.are.same({ min = 7, max = 13 }, (PartyLevels.limit("quests")))
        assert.are.same({}, client.ns.charDb.levelLimit)
        PartyLevels.set("max", "12")
        client:fire("PLAYER_LEVEL_UP", 11)
        assert.are.same({ min = 8, max = 12 }, (PartyLevels.limit("quests")))
        client.level = 11
        assert.are.same({ max = 12 }, client.ns.charDb.levelLimit)
    end)

    it("points out the first player to join a leader alone who is outside the limit", function()
        local world = World.new()
        local client = leader(world)
        client.ns.charDb.levelLimit = { min = 18, max = 22 }
        client:click("CheckButton", "Limit levels")
        client:slash("/dq join tank dm")
        client.partyLevels = { ["Low Whisperer"] = 12, ["Fit Friend"] = 20 }
        client:joins("Low Whisperer")
        assert.is_true(client:logged("Low Whisperer is level 12, outside your level limit%."))
        client:joins("Fit Friend")
        assert.is_false(client:logged("Fit Friend is level"))
    end)

    it("does not point out a party that was there before a /reload", function()
        local world = World.new()
        local client = world:addClient("Lead Player", { level = 20 })
        client.ns.charDb.levelsOn = true
        client.ns.charDb.levelLimit = { min = 18, max = 22 }
        client.party, client.isLeader = { "Low Friend" }, true
        client.partyLevels = { ["Low Friend"] = 12, ["Low Stranger"] = 13 }
        world:advance(CONNECT)
        client:fire("GROUP_ROSTER_UPDATE")
        assert.is_false(client:logged("Low Friend is level"))
        client:joins("Low Stranger")
        assert.is_true(client:logged("Low Stranger is level 13, outside your level limit%."))
    end)

    it("takes its default from the dungeons being joined, not from the ones ticked in the window", function()
        local world = World.new()
        local client = leader(world)
        client:click("CheckButton", "Limit levels")
        client:click("Button", "None")
        client.ns.join({ { name = "Lead Player", roles = "T", level = 20 } }, { "5" })
        local dungeon = client.ns.Dungeons.get("5")
        assert.are.equal(string.format("0:%d:%d", dungeon.min, dungeon.max), client.ns.engine.myEntry.levels)
    end)

    it("sends the limit with the queue entry and lets the filler invite only levels within it", function()
        local world = World.new()
        world:list("Heal Low", "H", 799, 15, 500)
        world:list("Heal Fit", "H", 799, 20, 100)
        local client = leader(world)
        client.ns.charDb.levelLimit = { min = 18, max = 22 }
        client:click("CheckButton", "Limit levels")
        client:slash("/dq join tank dm")
        local mine = client.ns.engine.myEntry
        assert.are.equal("0:18:22", mine.levels)
        client:slash("/dq fill")
        world:advance(3)
        assert.are.same({ "Heal Fit" }, client.invites)
    end)

    it("fades players outside the limit in Who is looking", function()
        local world = World.new()
        world:list("Dps Low", "D", 799, 15, 300)
        world:list("Dps Fit", "D", 799, 20, 200)
        local client = leader(world)
        client.ns.charDb.levelLimit = { min = 18, max = 22 }
        client:click("CheckButton", "Limit levels")
        client:press("W")
        world:advance(1)
        client.ns.QueueWindow.refresh()
        local low = client:findText("^Dps Low$").parent
        assert.are.equal(0.4, low.alpha)
        assert.are.equal(1, client:findText("^Dps Fit$").parent.alpha)
        assert.is_not_nil(client:findText("faded: outside your limits$"))
        assert.are.equal("Outside your level limit (18-22).", low.item.unwanted)
    end)
end)
