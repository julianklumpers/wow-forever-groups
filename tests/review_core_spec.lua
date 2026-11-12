local Sim = require("tests.helpers.sim")
local Matchmaker = require("core.matchmaker")
local Config = require("core.config")

describe("matchmaker robustness", function()
    it("still finds a full group behind a crowd of DPS and one flexible player", function()
        for _, n in ipairs({ 22, 40 }) do
            local entries = {}
            for i = 1, n do
                entries[#entries + 1] = { id = string.format("D%02d", i), joinedAt = i, dungeons = { "1", "2", "3" },
                    members = { { name = string.format("D%02d", i), roles = "D" } } }
            end
            entries[#entries + 1] = { id = "TH", joinedAt = 100, dungeons = { "1", "2", "3" },
                members = { { name = "TH", roles = "TH" } } }
            for i, role in ipairs({ "T", "H", "D", "D", "D" }) do
                entries[#entries + 1] = { id = "X" .. i, joinedAt = 200 + i, dungeons = { "25" },
                    members = { { name = "X" .. i, roles = role } } }
            end
            local groups = Matchmaker.findGroups(entries, Config.SLOTS)
            assert.are.equal(1, #groups)
            assert.are.equal("25", groups[1].dungeon)
        end
    end)

    it("never puts a player who is in two entries into one group twice", function()
        local entries = {
            { id = "Tank", joinedAt = 1, dungeons = { "1" }, members = { { name = "Tank", roles = "T" } } },
            { id = "Heal", joinedAt = 2, dungeons = { "1" }, members = { { name = "Heal", roles = "H" } } },
            { id = "Dps3", joinedAt = 3, dungeons = { "1" }, members = { { name = "Dps3", roles = "D" } } },
            { id = "Dps2", joinedAt = 4, dungeons = { "1" },
                members = { { name = "Dps2", roles = "D" }, { name = "Dps3", roles = "D" } } },
            { id = "Dps4", joinedAt = 5, dungeons = { "1" }, members = { { name = "Dps4", roles = "D" } } },
        }
        local groups = Matchmaker.findGroups(entries, Config.SLOTS)
        assert.are.equal(1, #groups)
        local seen = {}
        for _, member in ipairs(groups[1].members) do
            assert.is_nil(seen[member.name])
            seen[member.name] = true
        end
        assert.are.equal(5, #groups[1].members)
    end)

    it("proposes a group even when a stale solo entry overlaps a party", function()
        local sim = Sim.new()
        for _, n in ipairs({ "Tank-R", "Heal-R", "Dps2-R", "Dps3-R", "Dps4-R" }) do
            sim:add(n)
        end
        sim:join("Tank-R", "T")
        sim:join("Heal-R", "H")
        sim:join("Dps3-R", "D")
        sim:join("Dps2-R", "D", nil, { { "Dps3-R", "D" } })
        sim:join("Dps4-R", "D")
        sim:advance(Config.WARMUP + Config.MATCH_INTERVAL * 3)
        local proposals = 0
        for _, m in ipairs(sim.sent) do
            if m.text:find("^v2|P") then
                proposals = proposals + 1
            end
        end
        assert.is_true(proposals > 0)
    end)
end)

describe("proposals from an old copy of an entry", function()
    it("are refused with a conflict, and nobody loses their place", function()
        local sim = Sim.new()
        local all = { "Tank-R", "Heal-R", "Dps1-R", "Dps2-R", "Zed-R" }
        for _, n in ipairs(all) do
            sim:add(n)
        end
        sim:join("Tank-R", "T")
        sim:join("Heal-R", "H")
        sim:join("Dps1-R", "D")
        sim:join("Dps2-R", "D")
        sim:join("Zed-R", "D")
        sim:advance(Config.WARMUP - 1)
        local zed = sim:engine("Zed-R")
        sim.blocked["Zed-R>Dps1-R"] = true
        assert.is_true(zed:updateEntry({ { name = "Zed-R", roles = "D", level = 60 },
            { name = "Friend-R", roles = "D", level = 60 } }))
        sim:flush()
        sim.blocked = {}
        sim:advance(2)
        sim:acceptAll(all)
        assert.is_nil(sim:last("Zed-R", "groupFormed"))
        assert.is_not_nil(zed.myEntry)
        assert.is_not_nil(sim:engine("Tank-R").myEntry)
    end)
end)

describe("a proposal that reaches the others late", function()
    it("ends the same way for every player", function()
        local sim = Sim.new()
        local all = { "Aa-R", "Heal-R", "Dps1-R", "Dps2-R", "Tank-R" }
        for _, n in ipairs(all) do
            sim:add(n)
        end
        sim:join("Aa-R", "D")
        sim:join("Heal-R", "H")
        sim:join("Dps1-R", "D")
        sim:join("Dps2-R", "D")
        sim:join("Tank-R", "T")
        for _, n in ipairs(all) do
            if n ~= "Aa-R" then
                sim.blocked["Aa-R>" .. n] = true
            end
        end
        local held
        for _ = 1, 20 do
            sim:advance(1)
            for _, m in ipairs(sim.sent) do
                if m.from == "Aa-R" and m.text:find("^v2|P") then
                    held = held or m.text
                end
            end
            if held then
                break
            end
        end
        local ready
        for _, m in ipairs(sim.sent) do
            if m.from == "Aa-R" and m.text:find("^v2|A") then
                ready = m.text
            end
        end
        sim:respond("Aa-R", true)
        local yes
        for _, m in ipairs(sim.sent) do
            if m.from == "Aa-R" and m.text:find("^v2|A|.*|Y$") then
                yes = m.text
            end
        end
        sim:advance(6)
        sim.blocked = {}
        for _, n in ipairs(all) do
            if n ~= "Aa-R" then
                sim:engine(n):receive("Aa-R", held)
                sim:engine(n):receive("Aa-R", ready)
                sim:engine(n):receive("Aa-R", yes)
            end
        end
        sim:flush()
        sim:advance(29)
        sim:acceptAll({ "Heal-R", "Dps1-R", "Dps2-R", "Tank-R" })
        sim:advance(3)
        local formed = 0
        for _, n in ipairs(all) do
            if sim:last(n, "groupFormed") then
                formed = formed + 1
            end
        end
        assert.is_true(formed == 0 or formed == #all, formed .. " of 5 formed")
    end)
end)

describe("picking Group Finder players", function()
    it("does not spend a flexible player on a role someone else could take", function()
        local Fill = require("core.fill")
        local listings = {
            { name = "X", roles = "TH", dungeons = { "5" }, solo = true, age = 100 },
            { name = "Y", roles = "TD", dungeons = { "5" }, solo = true, age = 10 },
        }
        local picks, open = Fill.pick(listings, { missing = "TH", dungeon = "5" })
        assert.are.equal("", open)
        local roles = {}
        for _, pick in ipairs(picks) do
            roles[pick.name] = pick.role
        end
        assert.are.same({ X = "H", Y = "T" }, roles)
    end)
end)

describe("joining with a long entry", function()
    it("refuses to join when the heartbeat would be too long to send", function()
        local Engine = require("core.engine")
        local names = { "Aaaaaaaaaaaä Bbbbbbbbbbbb", "Cccccccccccc Dddddddddddd", "Eeeeeeeeeeee Ffffffffffff",
            "Gggggggggggg Hhhhhhhhhhhh" }
        for n = 1, 35 do
            local sent = {}
            local engine = Engine.new({ name = names[1], clock = function() return 1762800000 end,
                send = function(text) sent[#sent + 1] = text end, emit = function() end })
            local dungeons, members = {}, {}
            for i = 1, n do
                dungeons[i] = tostring(i)
            end
            for i, name in ipairs(names) do
                members[i] = { name = name, roles = i == 1 and "THD" or "D", level = 60 }
            end
            if engine:join(members, dungeons) then
                assert.is_true(#sent > 0, n .. " dungeons: joined but no heartbeat")
            end
        end
    end)
end)
