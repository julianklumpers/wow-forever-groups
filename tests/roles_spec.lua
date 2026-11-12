local Roles = require("core.roles")
local Matchmaker = require("core.matchmaker")
local Protocol = require("core.protocol")
local Sim = require("tests.helpers.sim")
local Config = require("core.config")

local SLOTS = { T = 1, H = 1, D = 3 }

local function entry(id, joinedAt, roles, premade)
    local members = { { name = id, roles = roles, level = 60 } }
    for _, m in ipairs(premade or {}) do
        members[#members + 1] = { name = m[1], roles = m[2], level = 60 }
    end
    return { id = id, joinedAt = joinedAt, dungeons = { "DM" }, members = members }
end

local function rolesOf(group)
    local result = {}
    for _, member in ipairs(group.members) do
        result[member.name] = member.role
    end
    return result
end

describe("Roles", function()
    it("normalizes role strings and rejects invalid ones", function()
        assert.are.equal("TD", Roles.normalize("DT"))
        assert.are.equal("THD", Roles.normalize("HDT"))
        for _, bad in ipairs({ "", "TT", "X", "tD" }) do
            assert.is_nil(Roles.normalize(bad), bad)
        end
        assert.is_nil(Roles.normalize(nil))
    end)

    it("lists each distinct composition once, earliest member taking the earlier role", function()
        local options = Roles.options({ { roles = "TD" }, { roles = "TD" } }, SLOTS)
        assert.are.equal(2, #options)
        assert.are.same({ "T", "D" }, options[1].assignment)
        assert.are.same({ T = 0, H = 0, D = 2 }, options[2].counts)
    end)

    it("has no options when a party cannot fit a group", function()
        assert.are.same({}, Roles.options({ { roles = "H" }, { roles = "H" } }, SLOTS))
    end)
end)

describe("Matchmaker with several roles per player", function()
    it("uses a tank/DPS player as the tank when the group needs one", function()
        local entries = {
            entry("Flex", 1, "TD"), entry("Heal", 2, "H"), entry("Dps1", 3, "D"), entry("Dps2", 4, "D"),
            entry("Dps3", 5, "D"),
        }
        local group = Matchmaker.findGroups(entries)[1]
        assert.are.same({ Flex = "T", Heal = "H", Dps1 = "D", Dps2 = "D", Dps3 = "D" }, rolesOf(group))
        assert.are.equal("Flex", group.leader)
    end)

    it("plays a flexible player as DPS when that lets a waiting tank in too", function()
        local entries = {
            entry("Flex", 1, "TD"), entry("Tank", 2, "T"), entry("Heal", 3, "H"), entry("Dps1", 4, "D"),
            entry("Dps2", 5, "D"), entry("Dps3", 6, "D"),
        }
        local group = Matchmaker.findGroups(entries)[1]
        assert.are.same({ Flex = "D", Tank = "T", Heal = "H", Dps1 = "D", Dps2 = "D" }, rolesOf(group))
        assert.are.equal("Tank", group.leader)
    end)

    it("gives the scarce role to the longest-waiting flexible player", function()
        local entries = {
            entry("FlexA", 1, "TD"), entry("FlexB", 2, "TD"), entry("Heal", 3, "H"), entry("Dps1", 4, "D"),
            entry("Dps2", 5, "D"),
        }
        local roles = rolesOf(Matchmaker.findGroups(entries)[1])
        assert.are.equal("T", roles.FlexA)
        assert.are.equal("D", roles.FlexB)
    end)

    it("fills the healer slot with an all-roles player", function()
        local entries = {
            entry("Tank", 1, "T"), entry("Any", 2, "THD"), entry("Dps1", 3, "D"), entry("Dps2", 4, "D"),
            entry("Dps3", 5, "D"),
        }
        assert.are.equal("H", rolesOf(Matchmaker.findGroups(entries)[1]).Any)
    end)

    it("splits roles inside a flexible premade", function()
        local entries = {
            entry("Duo", 1, "TD", { { "DuoFriend", "TD" } }), entry("Heal", 2, "H"), entry("Dps1", 3, "D"),
            entry("Dps2", 4, "D"),
        }
        local roles = rolesOf(Matchmaker.findGroups(entries)[1])
        assert.are.equal("T", roles.Duo)
        assert.are.equal("D", roles.DuoFriend)
    end)

    it("stays fast with many flexible players and no healer", function()
        local entries = {}
        for i = 1, 300 do
            entries[i] = entry("P" .. i, i, "TD")
        end
        local started = os.clock()
        assert.are.same({}, Matchmaker.findGroups(entries))
        assert.is_true(os.clock() - started < 1)
    end)
end)

describe("Protocol with several roles", function()
    local function queueMsg(members)
        return { kind = "queue", joinedAt = 1, dungeons = { "DM" }, members = members }
    end

    it("round-trips multiple roles per member", function()
        local text = Protocol.encode(queueMsg({ { name = "A-R", roles = "TD", level = 20 } }))
        assert.are.equal("v2|Q|1|DM|A-R:TD:20", text)
        assert.are.equal("TD", Protocol.decode(text).members[1].roles)
    end)

    it("rejects unnormalized or repeated roles on the wire", function()
        assert.is_nil(Protocol.decode("v2|Q|1|DM|A-R:DT:20"))
        assert.is_nil(Protocol.decode("v2|Q|1|DM|A-R:TT:20"))
    end)

    it("accepts a premade only when some role split fits a group", function()
        assert.is_nil(Protocol.encode(queueMsg({
            { name = "A-R", roles = "T", level = 20 }, { name = "B-R", roles = "T", level = 20 },
        })))
        assert.is_not_nil(Protocol.encode(queueMsg({
            { name = "A-R", roles = "T", level = 20 }, { name = "B-R", roles = "TD", level = 20 },
        })))
    end)
end)

describe("Engine with several roles", function()
    it("proposes each player with the single role they will play", function()
        local sim = Sim.new()
        local players = {
            { "Flex-R", "DT" }, { "Heal-R", "H" }, { "Dps1-R", "D" }, { "Dps2-R", "D" }, { "Dps3-R", "D" },
        }
        for _, p in ipairs(players) do
            sim:add(p[1])
        end
        for _, p in ipairs(players) do
            sim:join(p[1], p[2])
        end
        assert.are.equal("TD", sim:engine("Flex-R").myEntry.members[1].roles)
        assert.are.equal(1, sim:engine("Heal-R"):snapshot().roleCounts.T)
        sim:advance(Config.WARMUP + Config.MATCH_INTERVAL)
        local proposal = sim:last("Heal-R", "proposal")
        assert.are.equal("Flex-R", proposal.leader)
        assert.are.equal("T", proposal.members[1].role)
    end)
end)
