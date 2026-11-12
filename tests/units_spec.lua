local Election = require("core.election")
local Queue = require("core.queue")
local Proposal = require("core.proposal")
local Config = require("core.config")

describe("Election", function()
    it("picks the alphabetically first name", function()
        assert.are.equal("Anna-R", Election.pick({ "Bob-R", "Anna-R", "Cees-R" }))
    end)

    it("picks nobody from an empty list", function()
        assert.is_nil(Election.pick({}))
    end)

    it("lets the lower matchmaker win, then the older proposal", function()
        assert.is_true(Election.proposalWins({ matchmaker = "A", seq = 9 }, { matchmaker = "B", seq = 1 }))
        assert.is_false(Election.proposalWins({ matchmaker = "B", seq = 1 }, { matchmaker = "A", seq = 9 }))
        assert.is_true(Election.proposalWins({ matchmaker = "A", seq = 1 }, { matchmaker = "A", seq = 2 }))
    end)
end)

describe("Queue", function()
    local function e(id, joinedAt)
        return { id = id, joinedAt = joinedAt, dungeons = { "DM" }, members = { { name = id, role = "D" } } }
    end

    it("lists entries by priority", function()
        local q = Queue.new(120)
        q:upsert(e("C", 3), 0)
        q:upsert(e("A", 5), 0)
        q:upsert(e("B", 3), 0)
        local order = {}
        for _, entry in ipairs(q:list()) do
            order[#order + 1] = entry.id
        end
        assert.are.same({ "B", "C", "A" }, order)
    end)

    it("expires silent entries but keeps the given id", function()
        local q = Queue.new(120)
        q:upsert(e("Old", 1), 0)
        q:upsert(e("Me", 1), 0)
        q:upsert(e("Fresh", 1), 100)
        assert.are.same({ "Old" }, q:expire(121, "Me"))
        assert.are.same({ "Fresh", "Me" }, q:ids())
    end)

    it("refreshes lastSeen on touch", function()
        local q = Queue.new(120)
        q:upsert(e("A", 1), 0)
        q:touch("A", 100)
        assert.are.same({}, q:expire(200))
    end)
end)

describe("Proposal", function()
    local config = Config.with()

    local function newProposal()
        return Proposal.new({
            matchmaker = "Mm", seq = 1, dungeon = "DM", now = 0,
            entries = {
                { { name = "T", role = "T" }, { name = "TFriend", role = "D" } },
                { { name = "H", role = "H" } }, { { name = "D1", role = "D" } }, { { name = "D2", role = "D" } },
            },
        }, config)
    end

    local function answerAll(p, answer, except)
        for _, id in ipairs({ "T", "H", "D1", "D2" }) do
            if id ~= except then
                p:answer(id, answer)
            end
        end
    end

    it("leads with the first entry's owner and lists all members", function()
        local p = newProposal()
        assert.are.equal("T", p.leader)
        assert.are.equal(5, #p.members)
        assert.are.equal("Mm#1", p.key)
    end)

    it("is accepted when every entry says yes", function()
        local p = newProposal()
        answerAll(p, "Y")
        assert.are.equal("accepted", p:evaluate(1).status)
    end)

    it("stays pending while answers are outstanding", function()
        local p = newProposal()
        answerAll(p, "R")
        p:answer("T", "Y")
        assert.is_nil(p:evaluate(5))
    end)

    it("removes a decliner and returns the others", function()
        local p = newProposal()
        answerAll(p, "Y", "H")
        p:answer("H", "N")
        local outcome = p:evaluate(1)
        assert.are.same({ status = "failed", reason = "declined", removed = { "H" }, returned = { "T", "D1", "D2" } },
            outcome)
    end)

    it("returns everyone on a conflict", function()
        local p = newProposal()
        answerAll(p, "R", "D1")
        p:answer("D1", "C")
        local outcome = p:evaluate(1)
        assert.are.equal("conflict", outcome.reason)
        assert.are.same({}, outcome.removed)
    end)

    it("removes entries that never confirmed the reservation", function()
        local p = newProposal()
        answerAll(p, "R", "D2")
        assert.is_nil(p:evaluate(config.ACK_TIMEOUT - 1))
        local outcome = p:evaluate(config.ACK_TIMEOUT)
        assert.are.equal("unresponsive", outcome.reason)
        assert.are.same({ "D2" }, outcome.removed)
    end)

    it("times out and returns only those who accepted", function()
        local p = newProposal()
        answerAll(p, "R")
        p:answer("T", "Y")
        p:answer("D1", "Y")
        assert.is_nil(p:evaluate(config.PROPOSAL_TIMEOUT + config.PROPOSAL_GRACE - 1))
        local outcome = p:evaluate(config.PROPOSAL_TIMEOUT + config.PROPOSAL_GRACE)
        assert.are.equal("timeout", outcome.reason)
        assert.are.same({ "H", "D2" }, outcome.removed)
        assert.are.same({ "T", "D1" }, outcome.returned)
    end)

    it("ignores answers from outsiders, downgrades, and answers after the outcome", function()
        local p = newProposal()
        assert.is_false(p:answer("TFriend", "Y"))
        assert.is_false(p:answer("Stranger", "Y"))
        p:answer("T", "Y")
        assert.is_false(p:answer("T", "R"))
        answerAll(p, "Y")
        p:evaluate(1)
        assert.is_false(p:answer("H", "N"))
        assert.are.equal("accepted", p.outcome.status)
    end)
end)
