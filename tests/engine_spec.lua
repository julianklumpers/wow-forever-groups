local Sim = require("tests.helpers.sim")
local Config = require("core.config")

local SETTLE = Config.WARMUP + Config.MATCH_INTERVAL

local NO_PARTIAL = { PARTIAL_GROUPS = false }

local function setup(players, config)
    local sim = Sim.new(config)
    for _, p in ipairs(players) do
        sim:add(p[1])
    end
    for _, p in ipairs(players) do
        sim:join(p[1], p[2], p.dungeons, p.premade)
    end
    return sim
end

local function standardGroup()
    return setup({ { "Tank-R", "T" }, { "Heal-R", "H" }, { "Dps1-R", "D" }, { "Dps2-R", "D" }, { "Dps3-R", "D" } })
end

local GROUP = { "Dps1-R", "Dps2-R", "Dps3-R", "Heal-R", "Tank-R" }

local function queuedIds(sim, name)
    return sim:engine(name).queue:ids()
end

describe("Engine", function()
    describe("happy path", function()
        it("forms a group, makes the tank leader and empties the queue", function()
            local sim = standardGroup()
            sim:advance(SETTLE)
            for _, name in ipairs(GROUP) do
                local proposal = sim:last(name, "proposal")
                assert.is_not_nil(proposal, name)
                assert.are.same(GROUP, sim:memberNames(proposal))
                assert.are.equal("Tank-R", proposal.leader)
            end

            sim:acceptAll(GROUP)
            for _, name in ipairs(GROUP) do
                local formed = sim:last(name, "groupFormed")
                assert.is_not_nil(formed, name)
                assert.are.equal(name == "Tank-R", formed.isLeader)
                assert.is_false(sim:engine(name):snapshot().queued)
                assert.are.same({}, queuedIds(sim, name))
            end
        end)

        it("does not propose players again while their proposal is open", function()
            local sim = standardGroup()
            sim:advance(SETTLE + Config.MATCH_INTERVAL * 4)
            local proposals = 0
            for _, msg in ipairs(sim.sent) do
                if msg.text:find("^v2|P|") then
                    proposals = proposals + 1
                end
            end
            assert.are.equal(1, proposals)
            assert.are.equal(1, #sim:events("Tank-R", "proposal"))
        end)

        it("reports each answer on the open proposal to its members", function()
            local sim = standardGroup()
            sim:advance(SETTLE)
            sim:respond("Tank-R", true)
            local update = sim:last("Heal-R", "proposalUpdated")
            local answers = {}
            for _, member in ipairs(update.members) do
                answers[member.name] = member.answer
            end
            assert.are.equal("Y", answers["Tank-R"])
            assert.are.equal("R", answers["Heal-R"])
            assert.are.equal("Tank-R", update.members[1].owner)
        end)

        it("does not form a group before every entry has accepted", function()
            local sim = standardGroup()
            sim:advance(SETTLE)
            sim:respond("Tank-R", true)
            sim:respond("Heal-R", true)
            assert.is_nil(sim:last("Tank-R", "groupFormed"))
        end)

        it("2 tanks, 1 healer, 6 DPS: the longest-waiting tank and DPS are proposed", function()
            local order = {
                { "Tank1-R", "T" }, { "Dps1-R", "D" }, { "Dps2-R", "D" }, { "Dps3-R", "D" }, { "Tank2-R", "T" },
                { "Dps4-R", "D" }, { "Dps5-R", "D" }, { "Dps6-R", "D" }, { "Heal-R", "H" },
            }
            local sim = Sim.new()
            for _, p in ipairs(order) do
                sim:add(p[1])
            end
            for _, p in ipairs(order) do
                sim:join(p[1], p[2])
                sim:advance(1)
            end
            sim:advance(SETTLE)

            local expected = { "Dps1-R", "Dps2-R", "Dps3-R", "Heal-R", "Tank1-R" }
            assert.are.same(expected, sim:memberNames(sim:last("Heal-R", "proposal")))
            for _, name in ipairs({ "Tank2-R", "Dps4-R", "Dps5-R", "Dps6-R" }) do
                assert.is_nil(sim:last(name, "proposal"), name)
            end
        end)
    end)

    describe("declining", function()
        it("removes the decliner and puts the others back with priority over newer players", function()
            local sim = setup({
                { "Tank-R", "T" }, { "Heal-R", "H" }, { "Dps1-R", "D" }, { "Dps2-R", "D" }, { "Dps3-R", "D" },
            })
            sim:advance(2)
            sim:add("Dps4-R")
            sim:join("Dps4-R", "D")
            sim:advance(2)
            sim:add("Dps5-R")
            sim:join("Dps5-R", "D")
            local tankJoinedAt = sim:engine("Tank-R"):snapshot().joinedAt

            sim:advance(SETTLE)
            assert.are.same(GROUP, sim:memberNames(sim:last("Tank-R", "proposal")))
            sim:respond("Tank-R", true)
            sim:respond("Dps2-R", false)

            assert.are.equal("declined", sim:last("Dps2-R", "queueLeft").reason)
            assert.is_false(sim:engine("Dps2-R"):snapshot().queued)
            for _, name in ipairs({ "Tank-R", "Heal-R", "Dps1-R", "Dps3-R" }) do
                assert.are.equal("requeued", sim:last(name, "proposalEnded").result, name)
                assert.is_nil(sim:engine(name).queue:get("Dps2-R"), name)
            end
            assert.are.equal(tankJoinedAt, sim:engine("Tank-R"):snapshot().joinedAt)

            sim:advance(Config.MATCH_INTERVAL + 1)
            assert.are.same({ "Dps1-R", "Dps3-R", "Dps4-R", "Heal-R", "Tank-R" },
                sim:memberNames(sim:last("Tank-R", "proposal")))
            assert.is_nil(sim:last("Dps5-R", "proposal"))
        end)

        it("treats not answering within 30 seconds as declining", function()
            local sim = standardGroup()
            sim:advance(SETTLE)
            sim:acceptAll({ "Tank-R", "Dps1-R", "Dps2-R", "Dps3-R" })
            sim:advance(Config.PROPOSAL_TIMEOUT)

            assert.are.equal("removed", sim:last("Heal-R", "proposalEnded").result)
            assert.is_false(sim:engine("Heal-R"):snapshot().queued)
            for _, name in ipairs({ "Tank-R", "Dps1-R", "Dps2-R", "Dps3-R" }) do
                assert.are.equal("requeued", sim:last(name, "proposalEnded").result, name)
                assert.is_true(sim:engine(name):snapshot().queued, name)
            end
        end)

        it("treats leaving the queue during a proposal as declining", function()
            local sim = standardGroup()
            sim:advance(SETTLE)
            assert.is_true(sim:engine("Dps3-R"):leave())
            sim:flush()
            assert.are.equal("requeued", sim:last("Tank-R", "proposalEnded").result)
            assert.is_nil(sim:engine("Tank-R").queue:get("Dps3-R"))
        end)

        it("drops a player who never confirms the reservation", function()
            local sim = standardGroup()
            sim:kill("Dps3-R")
            sim:advance(SETTLE + Config.ACK_TIMEOUT)
            assert.are.equal("unresponsive", sim:last("Tank-R", "proposalEnded").reason)
            assert.is_nil(sim:engine("Tank-R").queue:get("Dps3-R"))
        end)
    end)

    describe("matchmaker", function()
        it("is the alphabetically first queued player", function()
            local sim = standardGroup()
            sim:add("Aaa-R")
            for _, name in ipairs(GROUP) do
                assert.are.equal("Dps1-R", sim:engine(name):matchmaker())
            end
            assert.is_true(sim:engine("Dps1-R"):isMatchmaker())
            assert.is_false(sim:engine("Aaa-R"):isMatchmaker())
        end)

        it("hands over to the next player when the matchmaker leaves", function()
            local sim = setup({ { "Heal-R", "H" }, { "Dps1-R", "D" }, { "Dps2-R", "D" } })
            sim:engine("Dps1-R"):leave()
            sim:flush()
            assert.are.equal("Dps2-R", sim:engine("Heal-R"):matchmaker())
            assert.is_true(sim:engine("Dps2-R"):isMatchmaker())
        end)

        it("stays with the player who has been online longest when someone new arrives", function()
            local sim = setup({ { "Tank-R", "T" }, { "Heal-R", "H" }, { "Dps1-R", "D" }, { "Dps2-R", "D" } })
            sim:advance(SETTLE)
            sim:add("Aaa-R")
            sim:join("Aaa-R", "D")
            assert.are.equal("Dps1-R", sim:engine("Tank-R"):matchmaker())
            sim:advance(Config.SYNC_JITTER)
            assert.are.equal("Dps1-R", sim:engine("Aaa-R"):matchmaker())
            sim:advance(Config.MATCH_INTERVAL)
            local proposal = sim:last("Tank-R", "proposal")
            assert.is_not_nil(proposal)
            assert.are.equal("Dps1-R", proposal.matchmaker)
        end)

        it("waits for its warm-up before matching", function()
            local sim = standardGroup()
            sim:advance(Config.WARMUP - 1)
            assert.is_nil(sim:last("Tank-R", "proposal"))
            sim:advance(Config.MATCH_INTERVAL)
            assert.is_not_nil(sim:last("Tank-R", "proposal"))
        end)

        it("still forms the group when a matchmaker outside the group disappears mid-proposal", function()
            local sim = Sim.new()
            sim:add("Zed-R")
            sim:advance(5)
            for _, name in ipairs(GROUP) do
                sim:add(name)
            end
            sim:join("Tank-R", "T")
            sim:join("Heal-R", "H")
            sim:join("Dps1-R", "D")
            sim:join("Dps2-R", "D")
            sim:join("Dps3-R", "D")
            sim:advance(1)
            sim:join("Zed-R", "T")
            sim:advance(SETTLE)
            local proposal = sim:last("Tank-R", "proposal")
            assert.are.equal("Zed-R", proposal.matchmaker)
            assert.are.same(GROUP, sim:memberNames(proposal))

            sim:kill("Zed-R")
            sim:acceptAll(GROUP)
            for _, name in ipairs(GROUP) do
                assert.is_not_nil(sim:last(name, "groupFormed"), name)
            end
        end)

        it("resolves a proposal when the matchmaker inside the group disappears; the next takes over", function()
            local sim = standardGroup()
            sim:advance(1)
            sim:add("Dps4-R")
            sim:join("Dps4-R", "D")
            sim:advance(SETTLE)
            assert.are.equal("Dps1-R", sim:last("Tank-R", "proposal").matchmaker)

            sim:kill("Dps1-R")
            sim:acceptAll({ "Tank-R", "Heal-R", "Dps2-R", "Dps3-R" })
            sim:advance(Config.PROPOSAL_TIMEOUT + Config.PROPOSAL_GRACE)
            assert.are.equal("requeued", sim:last("Tank-R", "proposalEnded").result)
            assert.is_nil(sim:engine("Tank-R").queue:get("Dps1-R"))

            sim:advance(Config.MATCH_INTERVAL)
            local next = sim:last("Tank-R", "proposal")
            assert.are.equal("Dps2-R", next.matchmaker)
            assert.are.same({ "Dps2-R", "Dps3-R", "Dps4-R", "Heal-R", "Tank-R" }, sim:memberNames(next))
        end)

        it("is replaced within seconds after it goes silent, and its entry is skipped", function()
            local sim = setup({ { "Aaa-R", "T" }, { "Heal-R", "H" }, { "Dps1-R", "D" }, { "Dps2-R", "D" } })
            sim:add("Tank-R")
            sim:add("Dps3-R")
            sim:advance(SETTLE)
            sim:kill("Aaa-R")
            sim:join("Tank-R", "T")
            sim:join("Dps3-R", "D")

            sim:advance(Config.ALIVE_TIMEOUT - Config.ALIVE_INTERVAL)
            assert.is_nil(sim:last("Tank-R", "proposal"))
            sim:advance(Config.ALIVE_INTERVAL + Config.MATCH_INTERVAL + 1)
            local proposal = sim:last("Tank-R", "proposal")
            assert.is_not_nil(proposal)
            assert.are.equal("Dps1-R", proposal.matchmaker)
            assert.are.same({ "Dps1-R", "Dps2-R", "Dps3-R", "Heal-R", "Tank-R" }, sim:memberNames(proposal))
        end)

        it("keeps a live matchmaker that only sends keep-alives", function()
            local sim = setup({ { "Aaa-R", "D" }, { "Heal-R", "H" } })
            sim:advance(Config.HEARTBEAT_INTERVAL * 3)
            for _, name in ipairs({ "Aaa-R", "Heal-R" }) do
                assert.are.equal("Aaa-R", sim:engine(name):matchmaker(), name)
            end
            local alive = 0
            for _, msg in ipairs(sim.sent) do
                if msg.text == "v2|K" then
                    alive = alive + 1
                end
            end
            assert.is_true(alive > 0)
        end)

        it("tells a newcomer which players are already in an open proposal", function()
            local sim = standardGroup()
            sim:advance(SETTLE)
            sim:add("Late-R")
            sim:advance(Config.SYNC_JITTER)
            local late = sim:engine("Late-R")
            for _, name in ipairs(GROUP) do
                assert.is_true(late:isReserved(name), name)
            end
        end)
    end)

    describe("two clients that both think they are matchmaker", function()
        it("lets the alphabetically first one win and never puts a player in two groups", function()
            local sim = Sim.new()
            local players = {
                { "Ab-R", "T" }, { "Aa-R", "T" }, { "Heal-R", "H" }, { "Dps1-R", "D" }, { "Dps2-R", "D" },
                { "Dps3-R", "D" },
            }
            for _, p in ipairs(players) do
                sim:add(p[1])
            end
            sim:partition("Aa-R", "Ab-R")
            for _, p in ipairs(players) do
                sim:join(p[1], p[2])
            end
            assert.is_true(sim:engine("Aa-R"):isMatchmaker())
            assert.is_true(sim:engine("Ab-R"):isMatchmaker())

            sim:advance(SETTLE)
            assert.are.equal("conflict", sim:last("Ab-R", "proposalEnded").reason)
            local winners = { "Aa-R", "Heal-R", "Dps1-R", "Dps2-R", "Dps3-R" }
            sim:acceptAll(winners)
            sim:advance(60)

            for _, name in ipairs(winners) do
                local formed = sim:events(name, "groupFormed")
                assert.are.equal(1, #formed, name)
                assert.are.equal("Aa-R", formed[1].matchmaker)
            end
            assert.are.same({}, sim:events("Ab-R", "groupFormed"))
            assert.is_true(sim:engine("Ab-R"):snapshot().queued)
            assert.are.same({ "Ab-R" }, queuedIds(sim, "Ab-R"))
        end)
    end)

    describe("premades", function()
        it("treats a premade of 2 as one block led by its owner", function()
            local sim = setup({
                { "Duo-R", "T", premade = { { "Friend-R", "D" } } }, { "Heal-R", "H" }, { "Dps1-R", "D" },
                { "Dps2-R", "D" },
            })
            sim:advance(SETTLE)
            local proposal = sim:last("Duo-R", "proposal")
            assert.are.same({ "Dps1-R", "Dps2-R", "Duo-R", "Friend-R", "Heal-R" }, sim:memberNames(proposal))
            assert.are.equal("Duo-R", proposal.leader)

            sim:acceptAll({ "Duo-R", "Heal-R", "Dps1-R", "Dps2-R" })
            assert.is_true(sim:last("Duo-R", "groupFormed").isLeader)
        end)
    end)

    describe("sync and heartbeats", function()
        it("learns the existing queue shortly after starting", function()
            local sim = standardGroup()
            sim:add("Late-R")
            assert.are.same({}, queuedIds(sim, "Late-R"))
            sim:advance(Config.SYNC_JITTER)
            assert.are.same(GROUP, queuedIds(sim, "Late-R"))
        end)

        it("keeps live entries and expires silent ones", function()
            local sim = setup({ { "Heal-R", "H" }, { "Dps1-R", "D" } }, NO_PARTIAL)
            sim:advance(Config.ENTRY_TIMEOUT * 3)
            assert.are.same({ "Dps1-R", "Heal-R" }, queuedIds(sim, "Heal-R"))

            sim:kill("Dps1-R")
            sim:advance(Config.ENTRY_TIMEOUT + Config.HEARTBEAT_INTERVAL)
            assert.are.same({ "Heal-R" }, queuedIds(sim, "Heal-R"))
            assert.are.equal("Dps1-R", sim:last("Heal-R", "entryExpired").id)
        end)
    end)

    describe("input handling", function()
        it("ignores a queue entry sent on behalf of someone else", function()
            local sim = setup({ { "Heal-R", "H" } })
            sim:engine("Heal-R"):receive("Evil-R", "v2|Q|1|DM|Tank-R:T:60")
            assert.are.same({ "Heal-R" }, queuedIds(sim, "Heal-R"))
        end)

        it("ignores malformed and foreign-version messages", function()
            local sim = setup({ { "Heal-R", "H" } })
            local engine = sim:engine("Heal-R")
            for _, text in ipairs({ "garbage", "v2|L", "v2|Q|x", "v2|A|Mm-R|1|Y", "v2|G|L" }) do
                engine:receive("Other-R", text)
            end
            assert.are.same({ "Heal-R" }, queuedIds(sim, "Heal-R"))
        end)

        it("declines a proposal that arrives after the player stopped queueing", function()
            local sim = Sim.new()
            sim:add("Heal-R")
            sim:engine("Heal-R"):receive("Mm-R", "v2|P|7|DM|Tank-R:T;Heal-R:H;D1-R:D;D2-R:D;D3-R:D")
            sim:flush()
            local proposal = sim:engine("Heal-R").proposals["Mm-R#7"]
            assert.are.equal("N", proposal.answers["Heal-R"])
            assert.are.same({}, sim:events("Heal-R", "proposal"))
        end)

        it("treats a leave message as declining even when the answer was lost", function()
            local sim = standardGroup()
            sim:advance(SETTLE)
            sim:engine("Tank-R"):receive("Dps3-R", "v2|L")
            assert.are.equal("requeued", sim:last("Tank-R", "proposalEnded").result)
        end)

        it("forgets finished proposals after a while", function()
            local sim = setup({ { "Tank-R", "T" }, { "Heal-R", "H" }, { "Dps1-R", "D" }, { "Dps2-R", "D" },
                { "Dps3-R", "D" } }, NO_PARTIAL)
            sim:advance(SETTLE)
            sim:respond("Dps3-R", false)
            assert.is_not_nil(next(sim:engine("Tank-R").proposals))
            sim:advance(Config.FINISHED_RETENTION + 1)
            assert.is_nil(next(sim:engine("Tank-R").proposals))
        end)

        it("refuses to join when the entry would not fit in one message", function()
            local sim = Sim.new()
            sim:add("Heal-R")
            local dungeons = {}
            for i = 1, 60 do
                dungeons[i] = "DUNGEON" .. i
            end
            local ok, err = sim:engine("Heal-R"):join({ { name = "Heal-R", roles = "H", level = 60 } }, dungeons)
            assert.is_false(ok)
            assert.are.equal("message too long", err)
            assert.is_false(sim:engine("Heal-R"):snapshot().queued)
        end)

        it("restores an earlier queue position but never one in the future", function()
            local sim = Sim.new()
            sim:add("Heal-R")
            sim:add("Dps-R")
            local member = function(name) return { { name = name, roles = "D", level = 60 } } end
            assert.is_true((sim:engine("Heal-R"):join(member("Heal-R"), { "DM" }, sim.now - 300)))
            assert.is_true((sim:engine("Dps-R"):join(member("Dps-R"), { "DM" }, sim.now + 300)))
            assert.are.equal(sim.now - 300, sim:engine("Heal-R"):snapshot().joinedAt)
            assert.are.equal(sim.now, sim:engine("Dps-R"):snapshot().joinedAt)
        end)

        it("rejects joining with an invalid party", function()
            local sim = Sim.new()
            sim:add("Heal-R")
            local engine = sim:engine("Heal-R")
            assert.is_false((engine:join({ { name = "Other-R", roles = "H", level = 60 } }, { "DM" })))
            assert.is_false((engine:join({ { name = "Heal-R", roles = "H", level = 60 } }, {})))
            assert.is_true((engine:join({ { name = "Heal-R", roles = "H", level = 60 } }, { "DM" })))
            assert.is_false((engine:join({ { name = "Heal-R", roles = "H", level = 60 } }, { "DM" })))
        end)
    end)
end)
