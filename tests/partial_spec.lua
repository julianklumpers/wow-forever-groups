local Matchmaker = require("core.matchmaker")
local Protocol = require("core.protocol")
local Sim = require("tests.helpers.sim")

local SLOTS = { T = 1, H = 1, D = 3 }
local NOW = 1000

local function entry(id, joinedAt, roles, dungeons, premade)
    local members = { { name = id, roles = roles, level = 20 } }
    for _, m in ipairs(premade or {}) do
        members[#members + 1] = { name = m[1], roles = m[2], level = 20 }
    end
    return { id = id, joinedAt = joinedAt, dungeons = dungeons or { "5" }, members = members }
end

local function names(group)
    local list = {}
    for _, member in ipairs(group.members) do
        list[#list + 1] = member.name .. ":" .. member.role
    end
    table.sort(list)
    return list
end

describe("Partial groups", function()
    local function partial(entries, minPlayers)
        return Matchmaker.findPartialGroup(entries, SLOTS, NOW, 120, minPlayers or 2)
    end

    it("leaves the missing roles open after the wait", function()
        local group = partial({ entry("Tank", 800, "T"), entry("Dps1", 850, "D"), entry("Dps2", 870, "D") })
        assert.are.same({ "Dps1:D", "Dps2:D", "Tank:T" }, names(group))
        assert.are.equal("HD", group.missing)
        assert.are.equal("Tank", group.leader)
        assert.are.equal("5", group.dungeon)
    end)

    it("waits until the longest-waiting player has waited long enough", function()
        assert.is_nil(partial({ entry("Tank", 900, "T"), entry("Dps1", 950, "D") }))
    end)

    it("needs at least two queue entries", function()
        assert.is_nil(partial({ entry("Tank", 800, "T") }, 1))
        assert.is_nil(partial({ entry("Duo", 800, "T", nil, { { "DuoFriend", "D" } }) }, 1))
        assert.is_not_nil(partial({ entry("Tank", 800, "T"), entry("Dps", 810, "D") }))
    end)

    it("fills the scarce roles itself and leaves DPS open", function()
        local group = partial({ entry("Flex", 800, "TD"), entry("Dps1", 850, "D") })
        assert.are.same({ "Dps1:D", "Flex:T" }, names(group))
        assert.are.equal("HDD", group.missing)
    end)

    it("picks the dungeon with the most players", function()
        local group = partial({
            entry("Tank", 800, "T", { "5", "6" }), entry("Dps1", 850, "D", { "5" }),
            entry("Heal", 860, "H", { "6" }), entry("Dps2", 870, "D", { "6" }),
        })
        assert.are.equal("6", group.dungeon)
        assert.are.equal("DD", group.missing)
    end)

    it("takes at most one premade", function()
        local group = partial({
            entry("DuoA", 800, "T", nil, { { "DuoAFriend", "D" } }),
            entry("DuoB", 850, "H", nil, { { "DuoBFriend", "D" } }),
            entry("Dps", 860, "D"),
        })
        assert.are.same({ "Dps:D", "DuoA:T", "DuoAFriend:D" }, names(group))
        assert.are.equal("HD", group.missing)
    end)
end)

describe("Protocol for partial groups", function()
    local entries = { { { name = "Tank-R", role = "T" } }, { { name = "Dps-R", role = "D" } } }

    it("carries the missing roles in the proposal", function()
        local text = Protocol.encode({ kind = "propose", seq = 1, dungeon = "5", entries = entries, missing = "HDD" })
        assert.are.equal("v2|P|1|5|Tank-R:T;Dps-R:D|HDD", text)
        assert.are.equal("HDD", Protocol.decode(text).missing)
    end)

    it("refuses missing roles that overfill the group", function()
        assert.is_nil(Protocol.encode({ kind = "propose", seq = 1, dungeon = "5", entries = entries, missing = "T" }))
        assert.is_nil(Protocol.decode("v2|P|1|5|Tank-R:T;Dps-R:D|HDDD"))
        assert.is_nil(Protocol.decode("v2|P|1|5|Tank-R:T;Dps-R:D|X"))
    end)
end)

describe("Engine with partial groups", function()
    local WAIT = 120

    local function threePlayers(config)
        config = config or {}
        config.PARTIAL_GROUPS = config.PARTIAL_GROUPS ~= false
        config.PARTIAL_AFTER = WAIT
        local sim = Sim.new(config)
        for _, name in ipairs({ "Tank-R", "Dps1-R", "Dps2-R" }) do
            sim:add(name)
        end
        sim:join("Tank-R", "T")
        sim:join("Dps1-R", "D")
        sim:join("Dps2-R", "D")
        return sim
    end

    it("proposes a partial group once players have waited long enough", function()
        local sim = threePlayers()
        sim:advance(WAIT - 5)
        assert.is_nil(sim:last("Tank-R", "proposal"))
        sim:advance(10)
        local proposal = sim:last("Tank-R", "proposal")
        assert.are.equal("HD", proposal.missing)
        sim:acceptAll({ "Tank-R", "Dps1-R", "Dps2-R" })
        local formed = sim:last("Tank-R", "groupFormed")
        assert.is_true(formed.isLeader)
        assert.are.equal("HD", formed.missing)
    end)

    it("can be switched off", function()
        local sim = threePlayers({ PARTIAL_GROUPS = false })
        assert.is_false(sim.config.PARTIAL_GROUPS)
        sim:advance(WAIT * 2)
        assert.is_nil(sim:last("Tank-R", "proposal"))
    end)

    it("prefers a full group over a partial one", function()
        local sim = threePlayers()
        sim:advance(WAIT - 20)
        for _, p in ipairs({ { "Heal-R", "H" }, { "Dps3-R", "D" } }) do
            sim:add(p[1])
            sim:join(p[1], p[2])
        end
        sim:advance(30)
        assert.are.equal("", sim:last("Tank-R", "proposal").missing)
    end)
end)
