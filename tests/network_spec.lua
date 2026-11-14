local Sim = require("tests.helpers.sim")
local Config = require("core.config")

local GROUP = { "Dps1-R", "Dps2-R", "Dps3-R", "Heal-R", "Tank-R" }
local ROLES = { ["Tank-R"] = "T", ["Heal-R"] = "H", ["Dps1-R"] = "D", ["Dps2-R"] = "D", ["Dps3-R"] = "D" }

local function group(sim)
    for _, name in ipairs(GROUP) do
        sim:add(name)
    end
    for _, name in ipairs(GROUP) do
        sim:join(name, ROLES[name])
    end
end

local function untilProposal(sim, name, limit)
    for _ = 1, limit or 30 do
        if sim:openProposal(name) then
            return sim:openProposal(name)
        end
        sim:advance(1)
    end
    return sim:openProposal(name)
end

local function formed(sim)
    local list = {}
    for _, name in ipairs(GROUP) do
        if sim:last(name, "groupFormed") then
            list[#list + 1] = name
        end
    end
    return list
end

local function isAnswer(answer)
    return function(_, _, text)
        return text:find("^v2|A|.*|" .. answer .. "$") ~= nil
    end
end

describe("on a network that loses or delays messages", function()
    it("forms the group for everyone when the leader misses the last Yes", function()
        local sim = Sim.new()
        group(sim)
        local proposal = untilProposal(sim, "Tank-R")
        assert.are.equal("Tank-R", proposal.leader)
        sim:acceptAll({ "Tank-R", "Heal-R", "Dps1-R", "Dps2-R" })
        sim:drop(function(from, to, text)
            return from == "Dps3-R" and to == "Tank-R" and isAnswer("Y")(from, to, text)
        end)
        sim:respond("Dps3-R", true)
        sim:advance(2)
        assert.are.same(GROUP, formed(sim))
    end)

    it("still counts an answer that arrives before its proposal", function()
        local sim = Sim.new()
        group(sim)
        local release = sim:drop(function(_, to, text)
            return to == "Heal-R" and text:find("^v2|P|") ~= nil
        end, true)
        untilProposal(sim, "Tank-R")
        release()
        assert.is_nil(sim:openProposal("Heal-R"))
        sim:acceptAll({ "Tank-R", "Dps1-R", "Dps2-R", "Dps3-R" })
        sim:releaseHeld()
        sim:respond("Heal-R", true)
        sim:advance(2)
        assert.are.same(GROUP, formed(sim))
    end)

    it("forms the group when a reservation got lost, by sending the answer again", function()
        local sim = Sim.new()
        group(sim)
        local release = sim:drop(isAnswer("R"))
        untilProposal(sim, "Tank-R")
        release()
        sim:advance(Config.ANSWER_RESEND)
        sim:acceptAll(GROUP)
        sim:advance(2)
        assert.are.same(GROUP, formed(sim))
    end)

    it("steps out of a proposal that reached the player too late, and keeps the place", function()
        local sim = Sim.new()
        group(sim)
        local release = sim:drop(function(_, to, text)
            return to == "Dps2-R" and text:find("^v2|P|") ~= nil
        end, true)
        untilProposal(sim, "Tank-R")
        release()
        local joinedAt = sim:engine("Dps2-R").myEntry.joinedAt
        sim:advance(Config.ACK_TIMEOUT + 2)
        sim:releaseHeld()
        assert.are.same({}, sim:events("Dps2-R", "proposal"))
        assert.are.equal(joinedAt, sim:engine("Dps2-R").myEntry.joinedAt)
        assert.is_not_nil(sim:engine("Tank-R").queue:get("Dps2-R"))
        sim:advance(Config.MATCH_INTERVAL * 2)
        assert.is_not_nil(sim:openProposal("Dps2-R"))
    end)

    it("ignores a proposal its matchmaker has long given up on", function()
        local sim = Sim.new()
        group(sim)
        local seq = (sim.now - Config.PROPOSAL_TIMEOUT - 5) * 1000 + 1
        sim:engine("Heal-R"):receive("Tank-R", "v2|P|" .. seq .. "|DM|Tank-R:T;Heal-R:H;Dps1-R:D;Dps2-R:D;Dps3-R:D")
        assert.is_nil(sim:engine("Heal-R").proposals["Tank-R#" .. seq])
        assert.are.same({}, sim:events("Heal-R", "proposal"))
    end)

    it("lets a queue entry expire when only the player's other messages still arrive", function()
        local sim = Sim.new()
        sim:add("Stay-R")
        sim:add("Gone-R")
        sim:join("Stay-R", "D")
        sim:join("Gone-R", "D")
        sim:drop(function(from, _, text)
            return from == "Gone-R" and text == "v2|L"
        end)
        sim:engine("Gone-R"):leave()
        for _ = 1, Config.ENTRY_TIMEOUT + Config.ALIVE_INTERVAL, Config.ALIVE_INTERVAL do
            sim:engine("Stay-R"):receive("Gone-R", "v2|K")
            sim:advance(Config.ALIVE_INTERVAL)
        end
        assert.is_nil(sim:engine("Stay-R").queue:get("Gone-R"))
    end)

    it("does not propose an entry again right after it answered with a conflict", function()
        local sim = Sim.new()
        group(sim)
        sim:advance(Config.WARMUP - 1)
        sim:drop(function(from, _, text)
            return from == "Heal-R" and text:find("^v2|Q|") ~= nil
        end)
        sim:engine("Heal-R"):updateEntry({ { name = "Heal-R", roles = "H", level = 60 },
            { name = "Friend-R", roles = "D", level = 60 } })
        sim:advance(Config.MATCH_INTERVAL * 2)
        local proposals = 0
        for _, msg in ipairs(sim.sent) do
            if msg.text:find("^v2|P|") then
                proposals = proposals + 1
            end
        end
        assert.are.equal(1, proposals)
    end)

    it("never leaves a player out of the queue without a group, nor two clients with different groups", function()
        for seed = 1, tonumber(os.getenv("SEEDS") or 25) do
            local sim = Sim.new()
            group(sim)
            sim:lossy(tonumber(os.getenv("LOSS") or 0.15), seed)
            for _ = 1, 90 do
                sim:advance(1)
                for _, name in ipairs(GROUP) do
                    if sim:openProposal(name) and sim:openProposal(name).answers[name] ~= "Y" then
                        sim:respond(name, true)
                    end
                end
            end
            local leaders = {}
            for _, name in ipairs(GROUP) do
                local view = sim:last(name, "groupFormed")
                assert.is_true(view ~= nil or sim:engine(name).myEntry ~= nil, "seed " .. seed .. ": " .. name)
                if view then
                    leaders[view.leader] = leaders[view.leader] or {}
                    leaders[view.leader][view.key] = true
                end
            end
            for leader, keys in pairs(leaders) do
                local own = sim:last(leader, "groupFormed")
                assert.is_true(own ~= nil and keys[own.key] == true, "seed " .. seed .. ": leader " .. leader)
            end
        end
    end)
end)
