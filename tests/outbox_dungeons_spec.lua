local Outbox = require("core.outbox")
local Dungeons = require("core.dungeons")
local Protocol = require("core.protocol")

describe("Outbox", function()
    local now, sent, results, dropped

    local function newOutbox(opts)
        now, sent, results, dropped = 0, {}, {}, {}
        opts = opts or {}
        opts.clock = function()
            return now
        end
        opts.transmit = function(text)
            local result = table.remove(results, 1) or "ok"
            if result == "ok" then
                sent[#sent + 1] = text
            end
            return result
        end
        opts.onDrop = function(text, reason)
            dropped[#dropped + 1] = text .. ":" .. reason
        end
        return Outbox.new(opts)
    end

    it("sends a burst up to capacity, then one per second", function()
        local outbox = newOutbox({ capacity = 3 })
        for i = 1, 5 do
            outbox:push("m" .. i)
        end
        assert.are.equal(3, outbox:flush())
        assert.are.equal(0, outbox:flush())
        now = 1
        assert.are.equal(1, outbox:flush())
        now = 2
        outbox:flush()
        assert.are.same({ "m1", "m2", "m3", "m4", "m5" }, sent)
    end)

    it("sends higher priority first, in order within a priority", function()
        local outbox = newOutbox({ capacity = 1 })
        outbox:push("heartbeat", Outbox.LOW)
        outbox:push("proposal", Outbox.NORMAL)
        outbox:push("answer1", Outbox.HIGH)
        outbox:push("answer2", Outbox.HIGH)
        for t = 0, 3 do
            now = t
            outbox:flush()
        end
        assert.are.same({ "answer1", "answer2", "proposal", "heartbeat" }, sent)
    end)

    it("replaces a queued message with the same key", function()
        local outbox = newOutbox({ capacity = 0 })
        outbox:push("Q old", Outbox.LOW, "heartbeat")
        outbox:push("Q new", Outbox.LOW, "heartbeat")
        assert.are.equal(1, outbox:size())
        outbox.capacity, outbox.tokens = 1, 1
        outbox:flush()
        assert.are.same({ "Q new" }, sent)
    end)

    it("backs off and retries after a server throttle", function()
        local outbox = newOutbox()
        results = { "throttled" }
        outbox:push("m1")
        assert.are.equal(0, outbox:flush())
        now = 1
        assert.are.equal(0, outbox:flush())
        now = 2
        assert.are.equal(1, outbox:flush())
        assert.are.same({ "m1" }, sent)
    end)

    it("keeps messages while messaging is blocked", function()
        local outbox = newOutbox()
        results = { "blocked" }
        outbox:push("m1")
        outbox:flush()
        now = 4
        outbox:flush()
        assert.are.same({}, sent)
        now = 5
        outbox:flush()
        assert.are.same({ "m1" }, sent)
    end)

    it("drops messages that can never be sent and when the queue overflows", function()
        local outbox = newOutbox({ capacity = 0, maxQueued = 2 })
        outbox:push("keep1", Outbox.HIGH)
        outbox:push("low", Outbox.LOW)
        outbox:push("keep2", Outbox.HIGH)
        assert.are.same({ "low:queue full" }, dropped)
        outbox.capacity, outbox.tokens = 5, 5
        results = { "error" }
        outbox:flush()
        assert.are.same({ "low:queue full", "keep1:error" }, dropped)
        assert.are.same({ "keep2" }, sent)
    end)
end)

describe("Dungeons", function()
    it("has unique ids that are valid on the wire", function()
        local seen = {}
        for _, dungeon in ipairs(Dungeons.list) do
            assert.is_nil(seen[dungeon.id], dungeon.id)
            seen[dungeon.id] = true
            assert.is_true(Protocol.isValidDungeon(dungeon.id))
        end
    end)

    it("fits every dungeon plus a premade of four into one queue message", function()
        local ids = {}
        for i, dungeon in ipairs(Dungeons.list) do
            ids[i] = dungeon.id
        end
        local members = {}
        for i = 1, 4 do
            members[i] = { name = string.rep("N", 11) .. i .. " " .. string.rep("S", 12),
                roles = i == 1 and "T" or "D", level = 60 }
        end
        assert.is_not_nil(Protocol.encode({ kind = "queue", joinedAt = 1794387388, dungeons = ids, members = members }))
    end)

    it("maps Group Finder activities to dungeons one to one", function()
        local count = 0
        for activity, dungeon in pairs(Dungeons.byActivity) do
            assert.are.equal(activity, dungeon.lfg)
            count = count + 1
        end
        assert.are.equal(34, count)
        assert.are.equal("The Deadmines", Dungeons.byActivity[799].name)
        assert.are.equal("Stratholme: Undead", Dungeons.byActivity[1603].name)
    end)

    it("finds dungeons by id, short name or full name", function()
        assert.are.equal("The Deadmines", Dungeons.find("5").name)
        assert.are.equal("The Deadmines", Dungeons.find("dm").name)
        assert.are.equal("Scarlet Monastery: Graveyard", Dungeons.find("SM GY").name)
        assert.are.equal("Wailing Caverns", Dungeons.find("wailing caverns").name)
        assert.are.equal("The Deadmines", Dungeons.find("Deadmines").name)
        assert.are.equal("Zul'Farrak", Dungeons.find("farrak").name)
        assert.is_nil(Dungeons.find("scarlet"))
        assert.is_nil(Dungeons.find("nope"))
        assert.is_nil(Dungeons.find("all"))
        assert.are.equal("dungeon 99", Dungeons.name("99"))
    end)

    it("lists dungeons for a level", function()
        for id, range in pairs({ ["1"] = { 13, 18 }, ["2"] = { 13, 20 }, ["3"] = { 15, 22 }, ["4"] = { 15, 24 },
            ["5"] = { 17, 26 } }) do
            Dungeons.setRange(id, range[1], range[2])
        end
        local names = {}
        for _, dungeon in ipairs(Dungeons.forLevel(16)) do
            names[#names + 1] = dungeon.short
        end
        assert.are.same({ "RFC", "HoT", "RoL", "WC" }, names)
        assert.is_true(Dungeons.setRange("2", 14, 21))
        assert.is_false(Dungeons.setRange("2", 21, 14))
        assert.are.equal("14-21", Dungeons.rangeText(Dungeons.get("2")))
        Dungeons.setRange("2", 13, 20)
    end)
end)
