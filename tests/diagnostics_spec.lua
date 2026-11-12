local World = require("tests.helpers.wowmock")

describe("/dq selftest", function()
    it("tells per feature whether it works in this client", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20, class = "SHAMAN",
            talents = { { 5000, 5 } } })
        world:advance(12)
        client:slash("/dq selftest")
        assert.is_true(client:said("Self%-test %(version"))
        assert.is_true(client:said("works|r  Forever Groups channel"))
        assert.is_true(client:said("works|r  Talent tree %(spec%)  |cffaaaaaa%(Enhancement%)"))
        assert.is_true(client:said("not tried|r  Listing your group"))
    end)
end)

describe("/dq bugreport", function()
    it("shows the version, the self-test, the addon's errors and the log, ready to copy", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(12)
        client.ns.on("TEST_FAILURE", function()
            error("Interface/AddOns/ForeverGroups/wow/test.lua:1: boom", 0)
        end)
        for _ = 1, 2 do
            assert.has_error(function()
                client:fire("TEST_FAILURE")
            end)
        end
        client:slash("/dq bugreport")
        local text = client:frame("ForeverGroupsBugReportFrame").box:GetText()
        local version = client.ns.Version.mine()
        assert.truthy(text:find("Forever Groups " .. version .. " | WoW 1.60.1 (70888) | interface 16001 | enUS", 1,
            true))
        assert.truthy(text:find("Self-test:", 1, true))
        local line = "x2  [" .. version .. "]  Interface/AddOns/ForeverGroups/wow/test.lua:1: boom"
        assert.truthy(text:find(line, 1, true))
        assert.truthy(text:find("Log (last 40 lines):", 1, true))
    end)
end)

describe("the Quests & Zones activities", function()
    it("are read again when WoW has none ready at login", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20, beforeLogin = function(c)
            c.zonesLate = true
        end })
        world:advance(5)
        client.zonesLate = false
        world:advance(12)
        assert.are.equal(2, client.ns.LfgList.zoneCount())
        client:slash("/dq selftest")
        local logged = false
        for _, line in ipairs(client.ns.db.log) do
            logged = logged or line:find("selftest: works  Quests & Zones category  (2 zones)", 1, true) ~= nil
        end
        assert.is_true(logged)
    end)
end)

describe("who is online", function()
    it("lists the players with Forever Groups, also idle ones, and drops those who left", function()
        local world = World.new()
        local a = world:addClient("Aaa Player", { level = 20 })
        world:advance(30)
        local b = world:addClient("Bbb Player", { level = 20 })
        local c = world:addClient("Ccc Player", { level = 20 })
        world:advance(20)
        a:slash("/dq online")
        assert.is_true(a:said("Players with Forever Groups online: 3 %(you, Bbb Player, Ccc Player%)"))
        b:slash("/dq online")
        assert.is_true(b:said("Players with Forever Groups online: 3 %(you, Aaa Player, Ccc Player%)"))
        c:logout()
        world:advance(900)
        assert.are.same({ "Bbb Player" }, a.ns.Presence.others())
    end)
end)
