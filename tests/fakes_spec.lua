local Sim = require("tests.helpers.sim")
local Config = require("core.config")

local SETTLE = Config.WARMUP + Config.MATCH_INTERVAL

local function fake(engine, name, roles)
    assert(engine:addFake({ { name = name, roles = roles, level = 20 } }, { "DM" }))
end

local function addFour(engine)
    fake(engine, "Fake Tank", "T")
    fake(engine, "Fake Heal", "H")
    fake(engine, "Fake One", "D")
    fake(engine, "Fake Two", "D")
end

local function sentProposals(sim)
    local count = 0
    for _, msg in ipairs(sim.sent) do
        if msg.text:find("^v2|P|") then
            count = count + 1
        end
    end
    return count
end

local function names(view)
    local list = {}
    for _, member in ipairs(view.members) do
        list[#list + 1] = member.name
    end
    table.sort(list)
    return list
end

describe("Fake players", function()
    local sim, me

    before_each(function()
        sim = Sim.new()
        sim:add("Me-R")
        me = sim:engine("Me-R")
        sim:join("Me-R", "D")
        addFour(me)
    end)

    it("form a local group with you that is never sent to the channel", function()
        sim:advance(SETTLE)
        local proposal = sim:last("Me-R", "proposal")
        assert.are.same({ "Fake Heal", "Fake One", "Fake Tank", "Fake Two", "Me-R" }, names(proposal))
        assert.are.equal(0, sentProposals(sim))
        for _, msg in ipairs(sim.sent) do
            assert.is_nil(msg.text:find("^v2|A|"), msg.text)
        end
    end)

    it("accept after a short delay, after which you can complete the group", function()
        sim:advance(SETTLE)
        sim:advance(4)
        local update = sim:last("Me-R", "proposalUpdated")
        for _, member in ipairs(update.members) do
            if member.fake then
                assert.are.equal("Y", member.answer, member.name)
            end
        end
        sim:respond("Me-R", true)
        local formed = sim:last("Me-R", "groupFormed")
        assert.is_not_nil(formed)
        assert.are.equal("Fake Tank", formed.leader)
        assert.are.same({}, me.queue:ids())
    end)

    it("can be told to decline, which puts you back in the queue", function()
        me:setFakeBehavior("decline")
        sim:advance(SETTLE + 4)
        assert.are.equal("requeued", sim:last("Me-R", "proposalEnded").result)
        assert.are.equal(3, #me.queue:ids() - 1)
    end)

    it("can be told to go silent, which times the proposal out", function()
        me:setFakeBehavior("afk")
        sim:advance(SETTLE)
        sim:respond("Me-R", true)
        sim:advance(Config.PROPOSAL_TIMEOUT + Config.PROPOSAL_GRACE)
        assert.are.equal("timeout", sim:last("Me-R", "proposalEnded").reason)
        assert.is_true(me:snapshot().queued)
    end)

    it("never expire and never become matchmaker", function()
        fake(me, "Aaa Fake", "D")
        sim:advance(Config.ENTRY_TIMEOUT * 2)
        assert.are.equal("Me-R", me:matchmaker())
        assert.is_not_nil(me.queue:get("Aaa Fake"))
    end)

    it("are cleared on request", function()
        assert.are.equal(4, me:clearFakes())
        assert.are.same({ "Me-R" }, me.queue:ids())
    end)

    it("explain why no group forms", function()
        me:clearFakes()
        fake(me, "Fake Tank", "T")
        sim:advance(SETTLE)
        assert.are.equal("players: 1 waiting (can tank 0, heal 0, DPS 1) -> 0 group(s); "
            .. "you + fakes: 2 waiting (can tank 1, heal 0, DPS 1) -> 0 group(s)", sim:last("Me-R", "matchInfo").text)
    end)
end)

describe("Fake players next to real players", function()
    it("are only grouped with you, while real players are grouped among themselves", function()
        local sim = Sim.new()
        local real = { { "Tank-R", "T" }, { "Heal-R", "H" }, { "Dps1-R", "D" }, { "Dps2-R", "D" }, { "Dps3-R", "D" } }
        for _, p in ipairs(real) do
            sim:add(p[1])
        end
        sim:add("Me-R")
        for _, p in ipairs(real) do
            sim:join(p[1], p[2])
        end
        sim:join("Me-R", "D")
        local me = sim:engine("Me-R")
        addFour(me)
        sim:advance(SETTLE)

        local realProposal = sim:last("Tank-R", "proposal")
        assert.are.same({ "Dps1-R", "Dps2-R", "Dps3-R", "Heal-R", "Tank-R" }, names(realProposal))
        local mine = sim:last("Me-R", "proposal")
        assert.are.same({ "Fake Heal", "Fake One", "Fake Tank", "Fake Two", "Me-R" }, names(mine))
        assert.are.equal(1, sentProposals(sim))
    end)

    it("still give you a local group when someone else is matchmaker", function()
        local sim = Sim.new()
        sim:add("Aaa-R")
        sim:add("Me-R")
        sim:join("Aaa-R", "H")
        sim:join("Me-R", "D")
        local me = sim:engine("Me-R")
        assert.are.equal("Aaa-R", me:matchmaker())
        addFour(me)
        sim:advance(SETTLE)
        assert.is_not_nil(sim:last("Me-R", "proposal"))
        assert.is_nil(sim:last("Aaa-R", "proposal"))
    end)
end)
