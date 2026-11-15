local Compose = require("core.compose")
local Matchmaker = require("core.matchmaker")
local Protocol = require("core.protocol")
local Config = require("core.config")

local NOW = 1000000
local MAGE = Compose.maskOf({ "MAGE" })
local WARRIOR_TANK = Compose.maskOf({ "WARRIOR" })

local function rules(masks, untilAt)
    return Compose.encode({ untilAt = untilAt or 0, masks = masks })
end

local function entry(id, joinedAt, roles, class, extra)
    local e = { id = id, joinedAt = joinedAt, dungeons = { "5" }, spec = class,
        members = { { name = id, roles = roles, level = 20 } } }
    for key, value in pairs(extra or {}) do
        e[key] = value
    end
    return e
end

local function roleOf(group, name)
    for _, member in ipairs(group.members) do
        if member.name == name then
            return member.role
        end
    end
end

describe("class wishes", function()
    it("travel in a queue entry and come back the same", function()
        local text = rules({ 0, 0, MAGE, 0, 0 }, NOW + 180)
        assert.are.equal("1000180:0.0.64.0.0", text)
        local decoded = Compose.decode(text)
        assert.are.same({ 0, 0, 64, 0, 0 }, decoded.masks)
        assert.is_nil(Compose.encode({ untilAt = 0, masks = { 0, 0, 0, 0, 0 } }))
        assert.is_nil(Compose.decode("12:1.2"))
        local msg = { kind = "queue", joinedAt = 5, dungeons = { "5" }, members = { { name = "Lead-R", roles = "T",
            level = 20 } }, lead = true, compose = text }
        local back = Protocol.decode(Protocol.encode(msg))
        assert.are.equal(text, back.compose)
        assert.is_nil(Protocol.decode("v2|Q|5|5|Lead-R:T:20||||||1|junk").compose)
    end)

    it("end at their time in prefer mode, and hold for good otherwise", function()
        assert.is_not_nil(Compose.active(rules({ 0, 0, MAGE, 0, 0 }, NOW + 10), NOW))
        assert.is_nil(Compose.active(rules({ 0, 0, MAGE, 0, 0 }, NOW - 1), NOW))
        assert.is_not_nil(Compose.active(rules({ 0, 0, MAGE, 0, 0 }, 0), NOW))
    end)

    it("give each player a place of their own", function()
        local r = Compose.decode(rules({ 0, 0, MAGE, MAGE, 0 }))
        assert.is_true(Compose.fits(r, { { role = "D", class = "MAGE" }, { role = "D", class = "MAGE" } }))
        r = Compose.decode(rules({ 0, 0, MAGE, Compose.maskOf({ "ROGUE" }), Compose.maskOf({ "ROGUE" }) }))
        assert.is_false(Compose.fits(r, { { role = "D", class = "MAGE" }, { role = "D", class = "MAGE" } }))
        assert.is_false(Compose.fits(r, { { role = "D" } }))
        assert.are.same({ "WARRIOR", "PALADIN", "SHAMAN", "DRUID" }, Compose.classesFor("T"))
    end)
end)

describe("matchmaking with a leader's class wishes", function()
    local wishes = rules({ 0, 0, MAGE, 0, 0 })

    it("puts the wished class in its place and passes over a second one", function()
        local groups = Matchmaker.findGroups({
            entry("Lead", 1, "T", "WARRIOR", { lead = true, compose = wishes }),
            entry("Heal", 2, "H", "PRIEST"),
            entry("Rogue1", 3, "D", "ROGUE"),
            entry("Rogue2", 4, "D", "ROGUE"),
            entry("Rogue3", 5, "D", "ROGUE"),
            entry("Mage", 6, "D", "MAGE"),
        }, Config.SLOTS, NOW)
        assert.are.equal(1, #groups)
        assert.are.equal("Lead", groups[1].leader)
        assert.are.equal("D", roleOf(groups[1], "Mage"))
        assert.is_nil(roleOf(groups[1], "Rogue3"))
    end)

    it("takes players who queued before the leader too, who cannot take the leader in", function()
        local groups = Matchmaker.findGroups({
            entry("Heal", 1, "H", "PRIEST"),
            entry("Lead", 2, "T", "WARRIOR", { lead = true, compose = wishes }),
            entry("Mage", 3, "D", "MAGE"),
            entry("Rogue1", 4, "D", "ROGUE"),
            entry("Rogue2", 5, "D", "ROGUE"),
        }, Config.SLOTS, NOW)
        assert.are.equal(1, #groups)
        assert.are.equal("Lead", groups[1].leader)
        assert.are.equal("H", roleOf(groups[1], "Heal"))
        local partial = Matchmaker.findPartialGroup({
            entry("Heal", 1, "H", "PRIEST", { lead = true, compose = rules({ WARRIOR_TANK, 0, 0, 0, 0 }) }),
            entry("Rogue1", 0, "D", "ROGUE"),
        }, Config.SLOTS, NOW + 100, 0, 2)
        assert.are.equal("Heal", partial.leader)
        assert.are.equal(2, #partial.members)
    end)

    it("never seats the leader's own players in a wished place, which the leader keeps for others", function()
        local groups = Matchmaker.findGroups({
            entry("Lead", 1, "D", "MAGE", { lead = true, compose = rules({ 0, 0, MAGE, 0, 0 }) }),
            entry("Tank", 2, "T", "WARRIOR"),
            entry("Heal", 3, "H", "PRIEST"),
            entry("Rogue1", 4, "D", "ROGUE"),
            entry("Rogue2", 5, "D", "ROGUE"),
            entry("Mage", 6, "D", "MAGE"),
        }, Config.SLOTS, NOW)
        assert.are.equal(1, #groups)
        assert.are.equal("D", roleOf(groups[1], "Mage"))
        assert.is_nil(roleOf(groups[1], "Rogue2"))
    end)

    it("keeps forming other groups while leaders wait for a class nobody plays", function()
        local list = {}
        for i = 1, 5 do
            list[#list + 1] = entry("Lead" .. i, i, "T", "WARRIOR", { lead = true,
                compose = rules({ 0, 0, MAGE, MAGE, 0 }) })
        end
        list[#list + 1] = entry("Heal1", 10, "H", "PRIEST")
        list[#list + 1] = entry("Heal2", 11, "H", "PRIEST")
        for i = 1, 40 do
            list[#list + 1] = entry(string.format("Rogue%02d", i), 20 + i, "D", "ROGUE")
        end
        list[#list + 1] = entry("Tank", 100, "T", "WARRIOR")
        local groups = Matchmaker.findGroups(list, Config.SLOTS, NOW)
        assert.are.equal(1, #groups)
        assert.are.equal("Tank", groups[1].leader)
    end)

    it("keeps forming everyone else's groups, quickly, however many leaders wait for a class nobody plays", function()
        local WARLOCK = Compose.maskOf({ "WARLOCK" })
        local function queue(composers)
            local list = {}
            for i = 1, composers do
                list[#list + 1] = entry("Wisher" .. i, i, "D", "ROGUE", { lead = true,
                    compose = rules({ 0, 0, 0, MAGE, WARLOCK }) })
            end
            for i = 1, 20 do
                list[#list + 1] = entry(string.format("Tank%02d", i), 100 + i, "T", "WARRIOR")
                list[#list + 1] = entry(string.format("Heal%02d", i), 200 + i, "H", "PRIEST")
            end
            for i = 1, 40 do
                list[#list + 1] = entry(string.format("Mage%02d", i), 300 + i, "D", "MAGE")
            end
            return list
        end
        for _, composers in ipairs({ 0, 5, 6 }) do
            local started = os.clock()
            local groups = Matchmaker.findGroups(queue(composers), Config.SLOTS, NOW)
            local took = os.clock() - started
            assert.are.equal(13, #groups, composers .. " composers")
            assert.is_true(took < 0.1, string.format("%d composers took %.3f s", composers, took))
        end
    end)

    it("seats the player and the party off the wished places, a player on their way on theirs", function()
        local ROGUE = Compose.maskOf({ "ROGUE" })
        local mageLeader = Compose.seat({ 0, 0, 0, MAGE, 0 }, { { role = "D", class = "MAGE", self = true } }, {})
        assert.are.same({ 0, 0, 0, MAGE, 0 }, mageLeader.wire)
        local invited = Compose.seat({ 0, 0, MAGE, 0, ROGUE }, { { role = "T" } }, { { role = "D", class = "ROGUE" } })
        assert.are.equal(5, invited.coming[1])
        local people = { { role = "T" }, { role = "D", class = "ROGUE", slot = 5 } }
        local joined = Compose.seat({ 0, 0, MAGE, 0, ROGUE }, people, {})
        assert.are.same({ 0, 0, MAGE, 0, 0 }, joined.wire)
    end)

    it("tells whether every place can get a player at all, moving players between places to find out", function()
        local open = { masks = { 0, 0, 0, 0, 0 } }
        assert.is_false(Compose.canFill(open, { { roles = "TH" }, { roles = "TD" }, { roles = "D" },
            { roles = "D" } }))
        assert.is_true(Compose.canFill(open, { { roles = "TH" }, { roles = "TD" }, { roles = "D" },
            { roles = "D" }, { roles = "D" } }))
        assert.is_false(Compose.canFill({ masks = { 0, 0, MAGE, 0, 0 } }, { { roles = "T" }, { roles = "H" },
            { roles = "D", class = "ROGUE" }, { roles = "D", class = "ROGUE" }, { roles = "D", class = "ROGUE" } }))
    end)

    it("finds the wished players behind a long line of others", function()
        local list = { entry("Lead", 1, "T", "WARRIOR", { lead = true, compose = rules({ 0, 0, MAGE, MAGE, 0 }) }),
            entry("Heal", 2, "H", "PRIEST") }
        for i = 1, 100 do
            list[#list + 1] = entry(string.format("Rogue%03d", i), 10 + i, "D", "ROGUE")
        end
        list[#list + 1] = entry("Mage1", 200, "D", "MAGE")
        list[#list + 1] = entry("Mage2", 201, "D", "MAGE")
        local groups = Matchmaker.findGroups(list, Config.SLOTS, NOW)
        assert.are.equal(1, #groups)
        assert.are.equal("D", roleOf(groups[1], "Mage1"))
        assert.are.equal("D", roleOf(groups[1], "Mage2"))
    end)

    it("seats a leader's own players and invites the same way whatever their order", function()
        local ROGUE = Compose.maskOf({ "ROGUE" })
        local masks = { 0, 0, MAGE + ROGUE, ROGUE, 0 }
        local people = { { role = "T" } }
        local one = Compose.seat(masks, people, { { role = "D", class = "MAGE" }, { role = "D", class = "ROGUE" } })
        local other = Compose.seat(masks, people, { { role = "D", class = "ROGUE" }, { role = "D", class = "MAGE" } })
        assert.are.same({ 0, 0, 0, 0, 0 }, one.wire)
        assert.are.same(one.wire, other.wire)
        assert.are.same(one.free, other.free)
        assert.are.same({ { slot = 2, role = "H", mask = 0 }, { slot = 5, role = "D", mask = 0 } }, one.free)
    end)

    it("forms no group without the wished class until the wish ends", function()
        local list = {
            entry("Lead", 1, "T", "WARRIOR", { lead = true, compose = rules({ 0, 0, MAGE, 0, 0 }, NOW + 60) }),
            entry("Heal", 2, "H", "PRIEST"),
            entry("Rogue1", 3, "D", "ROGUE"),
            entry("Rogue2", 4, "D", "ROGUE"),
            entry("Rogue3", 5, "D", "ROGUE"),
        }
        assert.are.same({}, Matchmaker.findGroups(list, Config.SLOTS, NOW))
        assert.are.equal(1, #Matchmaker.findGroups(list, Config.SLOTS, NOW + 61))
    end)

    it("keeps players whose class is not known out of a place with a wish", function()
        local groups = Matchmaker.findGroups({
            entry("Lead", 1, "T", "WARRIOR", { lead = true, compose = wishes }),
            entry("Heal", 2, "H", "PRIEST"),
            entry("Rogue1", 3, "D", "ROGUE"),
            entry("Rogue2", 4, "D", "ROGUE"),
            entry("Unknown", 5, "D", nil),
        }, Config.SLOTS, NOW)
        assert.are.same({}, groups)
    end)

    it("never puts a leader with wishes into another group", function()
        local groups = Matchmaker.findGroups({
            entry("First", 1, "T", "WARRIOR"),
            entry("Lead", 2, "H", "PRIEST", { lead = true, compose = rules({ MAGE, 0, 0, 0, 0 }) }),
            entry("Dps1", 3, "D", "ROGUE"),
            entry("Dps2", 4, "D", "ROGUE"),
            entry("Dps3", 5, "D", "ROGUE"),
        }, Config.SLOTS, NOW)
        assert.are.same({}, groups)
    end)

    it("fits a place held for an open invite into the place its leader sent without a wish", function()
        local list = {
            entry("Lead", 1, "T", "WARRIOR", { lead = true, reserved = "D",
                compose = rules({ 0, 0, 0, MAGE, MAGE }) }),
            entry("Heal", 2, "H", "PRIEST"),
            entry("Mage1", 3, "D", "MAGE"),
            entry("Mage2", 4, "D", "MAGE"),
        }
        local groups = Matchmaker.findGroups(list, Config.SLOTS, NOW)
        assert.are.equal(1, #groups)
        assert.are.equal("Lead", groups[1].leader)
        list[3] = entry("Rogue", 3, "D", "ROGUE")
        assert.are.same({}, Matchmaker.findGroups(list, Config.SLOTS, NOW))
    end)

    it("keeps the wishes in a partial group too", function()
        local list = {
            entry("Lead", 1, "T", "WARRIOR", { lead = true, compose = wishes }),
            entry("Rogue1", 2, "D", "ROGUE"),
            entry("Rogue2", 3, "D", "ROGUE"),
            entry("Rogue3", 4, "D", "ROGUE"),
        }
        local group = Matchmaker.findPartialGroup(list, Config.SLOTS, NOW + 100, 0, 2)
        assert.are.equal("Lead", group.leader)
        assert.are.equal(3, #group.members)
        assert.are.equal("HD", group.missing)
    end)
end)
