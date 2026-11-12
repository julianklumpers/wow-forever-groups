local QuestMatch = require("core.questmatch")
local Protocol = require("core.protocol")
local Sim = require("tests.helpers.sim")

local HOGGER, GOLD, TOWER = "176-3", "123-2", "184-5"

local function entry(id, joinedAt, roles, quests)
    return { id = id, joinedAt = joinedAt, dungeons = quests, members = { { name = id, roles = roles, level = 20 } } }
end

local function names(group)
    local list = {}
    for _, member in ipairs(group.members) do
        list[#list + 1] = member.name .. ":" .. member.role
    end
    table.sort(list)
    return list
end

describe("questing groups", function()
    it("forms a group of the quest's size from the longest waiting players", function()
        local groups = QuestMatch.findGroups({
            entry("A", 1, "D", { HOGGER }), entry("B", 2, "D", { HOGGER }), entry("C", 3, "D", { HOGGER }),
            entry("D", 4, "D", { HOGGER }),
        })
        assert.are.equal(1, #groups)
        assert.are.equal(HOGGER, groups[1].dungeon)
        assert.are.same({ "A:D", "B:D", "C:D" }, names(groups[1]))
    end)

    it("waits until the quest's group size is reached", function()
        assert.are.same({}, QuestMatch.findGroups({ entry("A", 1, "D", { HOGGER }), entry("B", 2, "D", { HOGGER }) }))
        assert.are.equal(1, #QuestMatch.findGroups({ entry("A", 1, "D", { GOLD }), entry("B", 2, "D", { GOLD }) }))
    end)

    it("takes players who share more quests first, then healers", function()
        local groups = QuestMatch.findGroups({
            entry("A", 1, "D", { HOGGER, GOLD }), entry("B", 2, "D", { HOGGER }), entry("C", 3, "H", { HOGGER }),
            entry("D", 4, "D", { HOGGER, GOLD }),
        })
        assert.are.same({ "A:D", "C:H", "D:D" }, names(groups[1]))
    end)

    it("has at most one tank and one healer, and fills those places when it can", function()
        local groups = QuestMatch.findGroups({
            entry("A", 1, "H", { HOGGER }), entry("B", 2, "H", { HOGGER }), entry("C", 3, "TD", { HOGGER }),
            entry("D", 4, "T", { HOGGER }), entry("E", 5, "D", { HOGGER }),
        })
        assert.are.same({ "A:H", "C:D", "D:T" }, names(groups[1]))
    end)

    it("reads quest keys", function()
        assert.are.same({ "176", 3 }, { QuestMatch.parse("176-3") })
        assert.is_nil(QuestMatch.parse("176-1"))
        assert.is_nil(QuestMatch.parse("176-6"))
        assert.is_nil(QuestMatch.parse("5"))
        assert.are.equal("184-5", QuestMatch.key(184, 5))
        assert.is_not_nil(TOWER)
    end)
end)

describe("the questing queue on the network", function()
    local function questSim()
        return Sim.new({ WARMUP = 0 }, { space = Protocol.QUESTS, matchmaker = QuestMatch })
    end

    it("uses its own messages, and a group of five may be all DPS", function()
        local sim = questSim()
        local names5 = { "Aa", "Bb", "Cc", "Dd", "Ee" }
        for _, name in ipairs(names5) do
            sim:add(name)
        end
        for _, name in ipairs(names5) do
            sim:join(name, "D", { TOWER })
        end
        sim:advance(10)
        local proposal = sim:openProposal("Aa")
        assert.is_not_nil(proposal)
        assert.are.equal(TOWER, proposal.dungeon)
        for _, sent in ipairs(sim.sent) do
            assert.is_truthy(sent.text:find("^q1|"), sent.text)
        end
        assert.is_nil(Protocol.decode(sim.sent[#sim.sent].text))
    end)

    it("steps out while the other queue has a proposal, and comes back at the same place", function()
        local sim = questSim()
        sim:add("Aa")
        sim:add("Bb")
        sim:join("Aa", "D", { HOGGER })
        sim:join("Bb", "D", { HOGGER })
        sim:advance(1)
        local joinedAt = sim:engine("Aa").myEntry.joinedAt
        assert.is_not_nil(sim:engine("Bb").queue:get("Aa"))
        sim:engine("Aa"):setHeld(true)
        sim:flush()
        assert.is_nil(sim:engine("Bb").queue:get("Aa"))
        sim:advance(60)
        assert.is_nil(sim:engine("Bb").queue:get("Aa"))
        sim:engine("Aa"):setHeld(false)
        sim:flush()
        assert.are.equal(joinedAt, sim:engine("Bb").queue:get("Aa").joinedAt)
    end)

    it("lets a player with invited Group Finder players lead, like in a dungeon group", function()
        local groups = QuestMatch.findGroups({
            { id = "B", joinedAt = 1, dungeons = { HOGGER }, members = { { name = "B", roles = "D", level = 20 } } },
            { id = "A", joinedAt = 2, dungeons = { HOGGER }, reserved = "D",
                members = { { name = "A", roles = "D", level = 20 } } },
        })
        assert.are.equal("A", groups[1].leader)
    end)
end)
