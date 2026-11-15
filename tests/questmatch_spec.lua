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

    it("takes any mix of roles, with a tank and a healer when the players allow it", function()
        local groups = QuestMatch.findGroups({
            entry("A", 1, "H", { HOGGER }), entry("B", 2, "H", { HOGGER }), entry("C", 3, "TD", { HOGGER }),
            entry("D", 4, "T", { HOGGER }), entry("E", 5, "D", { HOGGER }),
        })
        assert.are.same({ "A:H", "B:H", "C:T" }, names(groups[1]))
        local tanks = QuestMatch.findGroups({
            entry("A", 1, "T", { HOGGER }), entry("B", 2, "T", { HOGGER }), entry("C", 3, "T", { HOGGER }),
        })
        assert.are.same({ "A:T", "B:T", "C:T" }, names(tanks[1]))
    end)

    it("never puts two parties in one group", function()
        local function party(id, joinedAt, second)
            local group = entry(id, joinedAt, "D", { TOWER })
            group.members[2] = { name = second, roles = "D", level = 20 }
            return group
        end
        local groups = QuestMatch.findGroups({
            party("A", 1, "A2"), party("B", 2, "B2"), entry("C", 3, "D", { TOWER }), entry("D", 4, "D", { TOWER }),
            entry("E", 5, "D", { TOWER }),
        })
        assert.are.equal(1, #groups)
        assert.are.same({ "A2:D", "A:D", "C:D", "D:D", "E:D" }, names(groups[1]))
    end)

    it("tries a player's other quests when the first one can never fill", function()
        local entries = { entry("S", 1, "D", { TOWER, "200-2" }) }
        for i = 1, 60 do
            local party = entry("P" .. i, 1 + i, "D", { TOWER })
            party.members[2] = { name = "P" .. i .. "b", roles = "D", level = 20 }
            entries[#entries + 1] = party
        end
        entries[#entries + 1] = entry("T", 100, "D", { "200-2" })
        local groups = QuestMatch.findGroups(entries)
        assert.are.equal(1, #groups)
        assert.are.equal("200-2", groups[1].dungeon)
        assert.are.same({ "S:D", "T:D" }, names(groups[1]))
    end)

    it("passes over a player who would keep the group from filling", function()
        local function lang(group, language)
            group.language = language
            return group
        end
        local groups = QuestMatch.findGroups({
            lang(entry("E", 1, "D", { HOGGER }), "enUS:3"), lang(entry("A", 2, "D", { HOGGER }), "deDE:3"),
            lang(entry("B", 3, "D", { HOGGER }), "enUS:1"), lang(entry("C", 4, "D", { HOGGER }), "enUS:1"),
        })
        assert.are.equal(1, #groups)
        assert.are.same({ "B:D", "C:D", "E:D" }, names(groups[1]))

        local pair = entry("P", 2, "D", { "200-4", "300-2" })
        pair.members[2] = { name = "P2", roles = "D", level = 20 }
        local three = entry("Q", 3, "D", { "200-4" })
        three.members[2] = { name = "Q2", roles = "D", level = 20 }
        three.members[3] = { name = "Q3", roles = "D", level = 20 }
        groups = QuestMatch.findGroups({ entry("S", 1, "D", { "200-4", "300-2" }), pair, three })
        assert.are.equal(1, #groups)
        assert.are.equal("200-4", groups[1].dungeon)
        assert.are.same({ "Q2:D", "Q3:D", "Q:D", "S:D" }, names(groups[1]))
    end)

    it("stays fast when a large queue cannot fill a quest, and still forms the groups behind it", function()
        local list = { entry("Solo", 1, "D", { TOWER }) }
        for i = 1, 400 do
            local group = entry("P" .. i, i + 1, "D", { TOWER })
            group.members[2] = { name = "P" .. i .. "b", roles = "D", level = 20 }
            list[#list + 1] = group
        end
        for i, id in ipairs({ "X", "Y", "Z" }) do
            list[#list + 1] = entry(id, 1000 + i, "D", { HOGGER })
        end
        local started = os.clock()
        local groups = QuestMatch.findGroups(list)
        assert.is_true(os.clock() - started < 1)
        assert.are.equal(1, #groups)
        assert.are.same({ "X:D", "Y:D", "Z:D" }, names(groups[1]))
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
