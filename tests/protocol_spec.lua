local Protocol = require("core.protocol")

local function member(name, role, level)
    return { name = name, roles = role, level = level or 60 }
end

local function roundtrip(msg)
    local text = assert(Protocol.encode(msg))
    return assert(Protocol.decode(text)), text
end

describe("Protocol", function()
    describe("roundtrip", function()
        it("encodes and decodes a queue entry", function()
            local msg, text = roundtrip({
                kind = "queue",
                joinedAt = 1700000000,
                dungeons = { "DM", "WC" },
                members = { member("Tank-Forever", "T", 60), member("Friend-Forever", "D", 58) },
            })
            assert.are.equal("v2|Q|1700000000|DM,WC|Tank-Forever:T:60,Friend-Forever:D:58", text)
            assert.are.same({
                kind = "queue",
                joinedAt = 1700000000,
                dungeons = { "DM", "WC" },
                members = { member("Tank-Forever", "T", 60), member("Friend-Forever", "D", 58) },
                reserved = "",
                playstyle = 0,
            }, msg)
        end)

        it("carries roles reserved for Group Finder players", function()
            local msg, text = roundtrip({
                kind = "queue", joinedAt = 1, dungeons = { "5" }, members = { member("Tank-R", "T", 20) },
                reserved = "HD",
            })
            assert.are.equal("v2|Q|1|5|Tank-R:T:20|HD", text)
            assert.are.equal("HD", msg.reserved)
            assert.is_nil(Protocol.encode({
                kind = "queue", joinedAt = 1, dungeons = { "5" }, members = { member("Tank-R", "T", 20) },
                reserved = "TH",
            }))
            assert.is_nil(Protocol.decode("v2|Q|1|5|Tank-R:T:20|HDDD"))
        end)

        it("encodes and decodes leave and sync", function()
            assert.are.same({ kind = "leave" }, (roundtrip({ kind = "leave" })))
            assert.are.same({ kind = "sync" }, (roundtrip({ kind = "sync" })))
        end)

        it("carries an optional nonce on sync", function()
            local msg, text = roundtrip({ kind = "sync", nonce = "a1B2" })
            assert.are.equal("v2|S|a1B2", text)
            assert.are.same({ kind = "sync", nonce = "a1B2" }, msg)
            assert.is_nil(Protocol.encode({ kind = "sync", nonce = "no spaces" }))
            assert.are.same({ kind = "sync" }, Protocol.decode("v2|S|bad nonce"))
        end)

        it("encodes and decodes a proposal with a premade", function()
            local entries = {
                { { name = "Tank-R", role = "T" }, { name = "Pal-R", role = "D" } },
                { { name = "Heal-R", role = "H" } },
                { { name = "Dps1-R", role = "D" } },
                { { name = "Dps2-R", role = "D" } },
            }
            local msg, text = roundtrip({ kind = "propose", seq = 1700000000001, dungeon = "DM", entries = entries })
            assert.are.equal("v2|P|1700000000001|DM|Tank-R:T,Pal-R:D;Heal-R:H;Dps1-R:D;Dps2-R:D", text)
            assert.are.same({ kind = "propose", seq = 1700000000001, dungeon = "DM", entries = entries, missing = "",
                playstyles = {} }, msg)
        end)

        it("carries the playstyle of an entry and of a proposed group", function()
            local msg, text = roundtrip({
                kind = "queue", joinedAt = 1, dungeons = { "5" }, members = { member("Tank-R", "T", 20) },
                since = 0, playstyle = 2,
            })
            assert.are.equal("v2|Q|1|5|Tank-R:T:20||0|2", text)
            assert.are.equal(2, msg.playstyle)
            assert.is_nil(Protocol.decode("v2|Q|1|5|Tank-R:T:20||0|7"))
            assert.is_nil(Protocol.decode("v2|Q|1|5|Tank-R:T:20||0|x"))
            local entries = { { { name = "Tank-R", role = "T" } }, { { name = "Heal-R", role = "H" } } }
            local proposal, proposalText = roundtrip({
                kind = "propose", seq = 5, dungeon = "DM", entries = entries, missing = "DDD", playstyles = { 2, 1 },
            })
            assert.are.equal("v2|P|5|DM|Tank-R:T;Heal-R:H|DDD|21", proposalText)
            assert.are.same({ 2, 1 }, proposal.playstyles)
            assert.is_nil(Protocol.encode({ kind = "propose", seq = 5, dungeon = "DM", entries = entries,
                playstyles = { 2, 4 } }))
            assert.is_nil(Protocol.decode("v2|P|5|DM|Tank-R:T;Heal-R:H||22"))
        end)

        it("encodes and decodes an answer", function()
            for _, answer in ipairs({ "R", "Y", "N", "C" }) do
                local msg = roundtrip({ kind = "answer", matchmaker = "Mm-R", seq = 42, answer = answer })
                assert.are.same({ kind = "answer", matchmaker = "Mm-R", seq = 42, answer = answer }, msg)
            end
        end)
    end)

    describe("versioning", function()
        it("ignores messages from another protocol version", function()
            local msg, err = Protocol.decode("v1|L")
            assert.is_nil(msg)
            assert.are.equal("unsupported version", err)
        end)

        it("ignores unknown trailing fields", function()
            local msg = Protocol.decode("v2|A|Mm-R|42|Y|future-field")
            assert.are.same({ kind = "answer", matchmaker = "Mm-R", seq = 42, answer = "Y" }, msg)
        end)

        it("ignores unknown message types", function()
            assert.is_nil(Protocol.decode("v2|Z|whatever"))
        end)
    end)

    describe("validation", function()
        local function queueMsg(members, dungeons)
            return { kind = "queue", joinedAt = 1, dungeons = dungeons or { "DM" }, members = members }
        end

        it("rejects an invalid role", function()
            assert.is_nil(Protocol.encode(queueMsg({ member("A-R", "X") })))
            assert.is_nil(Protocol.decode("v2|Q|1|DM|A-R:X:60"))
        end)

        it("rejects names containing separators or surrounding whitespace", function()
            for _, name in ipairs({ "A|B", "A,B", "A;B", "A:B", "", " A", "A ", "A\nB" }) do
                assert.is_nil(Protocol.encode(queueMsg({ member(name, "D") })), name)
            end
        end)

        it("accepts Forever names with a space and names with a realm", function()
            local msg = roundtrip(queueMsg({ member("Roos Bieff", "D"), member("Makatia Choko", "H") }))
            assert.are.equal("Roos Bieff", msg.members[1].name)
            assert.is_true(Protocol.isValidName("Tank-Forever"))
        end)

        it("rejects a premade that cannot fit in one group", function()
            local _, err = Protocol.encode(queueMsg({ member("A-R", "T"), member("B-R", "T") }))
            assert.are.equal("role composition does not fit a group", err)
        end)

        it("rejects a premade of five", function()
            local members = {
                member("A-R", "T"), member("B-R", "H"), member("C-R", "D"), member("D-R", "D"), member("E-R", "D"),
            }
            local _, err = Protocol.encode(queueMsg(members))
            assert.are.equal("too many members", err)
        end)

        it("rejects duplicate members", function()
            local _, err = Protocol.encode(queueMsg({ member("A-R", "D"), member("A-R", "D") }))
            assert.are.equal("duplicate member", err)
        end)

        it("refuses to encode a message over 255 bytes", function()
            local dungeons = {}
            for i = 1, 60 do
                dungeons[i] = "DUNGEON" .. i
            end
            local _, err = Protocol.encode(queueMsg({ member("A-R", "D") }, dungeons))
            assert.are.equal("message too long", err)
        end)

        it("fits a full proposal with maximum-length names", function()
            local function long(i)
                return string.rep("N", 11) .. i .. "-" .. string.rep("R", 20)
            end
            local entries = {
                { { name = long(1), role = "T" } }, { { name = long(2), role = "H" } },
                { { name = long(3), role = "D" } }, { { name = long(4), role = "D" } },
                { { name = long(5), role = "D" } },
            }
            local text = Protocol.encode({
                kind = "propose", seq = 1700000000999, dungeon = "DUNGEON12", entries = entries,
            })
            assert.is_not_nil(text)
            assert.is_true(#text <= 255)
        end)

        it("refuses to encode invalid messages", function()
            local entries = { { { name = "A-R", role = "T" } } }
            local cases = {
                { { kind = "nope" }, "unknown kind" },
                { { kind = "queue", joinedAt = 1.5, dungeons = { "DM" }, members = { member("A-R", "D") } },
                    "invalid joinedAt" },
                { { kind = "queue", joinedAt = 1, dungeons = { "DM" }, members = {} }, "no members" },
                { { kind = "propose", seq = -1, dungeon = "DM", entries = entries }, "invalid seq" },
                { { kind = "propose", seq = 1, dungeon = "D M", entries = entries }, "invalid dungeon" },
                { { kind = "propose", seq = 1, dungeon = "DM", entries = {} }, "no entries" },
                { { kind = "propose", seq = 1, dungeon = "DM", entries = { { { name = "A-R", role = "X" } } } },
                    "invalid role" },
                { { kind = "answer", matchmaker = "A|B", seq = 1, answer = "Y" }, "invalid matchmaker" },
                { { kind = "answer", matchmaker = "A-R", seq = "x", answer = "Y" }, "invalid seq" },
                { { kind = "answer", matchmaker = "A-R", seq = 1, answer = "Q" }, "invalid answer" },
            }
            for _, case in ipairs(cases) do
                local text, err = Protocol.encode(case[1])
                assert.is_nil(text, case[2])
                assert.are.equal(case[2], err)
            end
        end)

        it("returns nil instead of erroring on malformed input", function()
            local samples = {
                "", "v1", "v1|", "v2|Q", "v2|Q|x|DM|A-R:D:60", "v2|Q|1|DM|", "v2|Q|1||A-R:D:60",
                "v2|Q|1|DM|A-R:D", "v2|Q|1|DM|A-R", "v2|P", "v2|P|1|DM|", "v2|P|1|DM|A-R:Q",
                "v2|P|x|DM|A-R:T", "v2|A|Mm-R|x|Y", "v2|A|Mm-R|1|Q", "v2|A||1|Y", "|||", "v2|Q|-1|DM|A-R:D:60",
                "v2|Q|1.5|DM|A-R:D:60", string.rep("x", 300),
            }
            for _, sample in ipairs(samples) do
                local ok, msg = pcall(Protocol.decode, sample)
                assert.is_true(ok, sample)
                assert.is_nil(msg, sample)
            end
        end)
    end)
end)
