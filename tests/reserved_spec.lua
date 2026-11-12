local Matchmaker = require("core.matchmaker")
local Sim = require("tests.helpers.sim")
local Config = require("core.config")

local function entry(id, joinedAt, roles, reserved)
    return {
        id = id, joinedAt = joinedAt, dungeons = { "5" }, reserved = reserved,
        members = { { name = id, roles = roles, level = 20 } },
    }
end

local function roles(group)
    local result = {}
    for _, member in ipairs(group.members) do
        result[member.name] = member.role
    end
    return result
end

describe("Reserved roles in the matchmaker", function()
    it("count as taken and come back as missing roles for the leader", function()
        local group = Matchmaker.findGroups({
            entry("Tank", 1, "T", "H"), entry("Heal", 2, "H"), entry("Dps1", 3, "D"), entry("Dps2", 4, "D"),
            entry("Dps3", 5, "D"),
        })[1]
        assert.are.same({ Tank = "T", Dps1 = "D", Dps2 = "D", Dps3 = "D" }, roles(group))
        assert.are.equal("H", group.missing)
        assert.are.equal("Tank", group.leader)
    end)

    it("make the entry a premade, so two of them never meet", function()
        local groups = Matchmaker.findGroups({
            entry("A", 1, "T", "D"), entry("B", 2, "H", "D"), entry("Dps1", 3, "D"), entry("Heal", 4, "H"),
            entry("Dps2", 5, "D"),
        })
        assert.are.equal(1, #groups)
        assert.are.same({ A = "T", Dps1 = "D", Heal = "H", Dps2 = "D" }, roles(groups[1]))
        assert.are.equal("D", groups[1].missing)
    end)

    it("can fill the group up to five on their own with addon players", function()
        local group = Matchmaker.findGroups({
            entry("Dps", 1, "D", "THD"), entry("Last", 2, "D"),
        })[1]
        assert.are.same({ Dps = "D", Last = "D" }, roles(group))
        assert.are.equal("THD", group.missing)
    end)
end)

describe("Updating a queue entry", function()
    local sim, me

    before_each(function()
        sim = Sim.new({ PARTIAL_GROUPS = false })
        sim:add("Me-R")
        sim:add("Other-R")
        sim:join("Me-R", "T")
        me = sim:engine("Me-R")
    end)

    it("keeps the place in the queue and tells everyone", function()
        local joinedAt = me.myEntry.joinedAt
        sim:advance(30)
        assert.is_true((me:updateEntry({
            { name = "Me-R", roles = "T", level = 20 }, { name = "Friend-R", roles = "D", level = 20 },
        }, "H")))
        sim:flush()
        assert.are.equal(joinedAt, me.myEntry.joinedAt)
        local seen = sim:engine("Other-R").queue:get("Me-R")
        assert.are.equal("H", seen.reserved)
        assert.are.equal(2, #seen.members)
    end)

    it("refuses a party that no longer fits", function()
        local ok, err = me:updateEntry({ { name = "Me-R", roles = "T", level = 20 } }, "TD")
        assert.is_false(ok)
        assert.are.equal("role composition does not fit a group", err)
    end)

    it("waits while a proposal is open", function()
        for _, p in ipairs({ { "Heal-R", "H" }, { "Dps1-R", "D" }, { "Dps2-R", "D" }, { "Dps3-R", "D" } }) do
            sim:add(p[1])
            sim:join(p[1], p[2])
        end
        sim:advance(Config.WARMUP + Config.MATCH_INTERVAL)
        assert.is_not_nil(me.myProposalKey)
        local ok, err = me:updateEntry({ { name = "Me-R", roles = "T", level = 20 } }, "H")
        assert.is_false(ok)
        assert.are.equal("proposal open", err)
    end)

    it("lets the matchmaker leave the reserved role open", function()
        assert.is_true((me:updateEntry({ { name = "Me-R", roles = "T", level = 20 } }, "H")))
        for _, p in ipairs({ { "Dps1-R", "D" }, { "Dps2-R", "D" }, { "Dps3-R", "D" } }) do
            sim:add(p[1])
            sim:join(p[1], p[2])
        end
        sim:advance(Config.WARMUP + Config.MATCH_INTERVAL)
        local proposal = sim:last("Me-R", "proposal")
        assert.are.equal("H", proposal.missing)
        assert.are.equal("Me-R", proposal.leader)
    end)
end)
