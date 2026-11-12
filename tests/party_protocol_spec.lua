local Protocol = require("core.protocol")

describe("Party status messages", function()
    local function roundtrip(msg)
        local text = assert(Protocol.encode(msg))
        return assert(Protocol.decode(text)), text
    end

    it("describe a queued party with everyone's roles", function()
        local msg, text = roundtrip({
            kind = "party", phase = "Q", joinedAt = 1794393930, dungeons = { "4", "5" },
            members = { { name = "Roos Bief", roles = "TD" }, { name = "Friend Person", roles = "H" } },
        })
        assert.are.equal("v2|G|Q|1794393930|4,5|Roos Bief:TD,Friend Person:H", text)
        assert.are.equal("H", msg.members[2].roles)
    end)

    it("describe a proposal, a formed group and leaving", function()
        assert.are.same({ kind = "party", phase = "P", dungeon = "5", secondsLeft = 24 },
            (roundtrip({ kind = "party", phase = "P", dungeon = "5", secondsLeft = 24 })))
        assert.are.same({ kind = "party", phase = "F", dungeon = "5", leader = "Tanky Mctank" },
            (roundtrip({ kind = "party", phase = "F", dungeon = "5", leader = "Tanky Mctank" })))
        assert.are.same({ kind = "party", phase = "L" }, (roundtrip({ kind = "party", phase = "L" })))
        assert.are.same({ kind = "party", phase = "R" }, (roundtrip({ kind = "party", phase = "R" })))
    end)

    it("rejects malformed party messages", function()
        for _, text in ipairs({ "v2|G", "v2|G|X", "v2|G|Q|x|5|A:T", "v2|G|Q|1|5|A:TT", "v2|G|P|5|x", "v2|G|F|5|" }) do
            local ok, msg = pcall(Protocol.decode, text)
            assert.is_true(ok, text)
            assert.is_nil(msg, text)
        end
        assert.is_nil(Protocol.encode({ kind = "party", phase = "Z" }))
    end)
end)
