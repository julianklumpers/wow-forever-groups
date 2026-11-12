local World = require("tests.helpers.wowmock")
local Config = require("core.config")

local CONNECT = 8

local function invitedOnly(client, names)
    local set = {}
    for _, name in ipairs(client.invites) do
        set[name] = true
    end
    for _, name in ipairs(names) do
        assert.is_true(set[name] == true, "expected invite for " .. name)
    end
end

describe("Filling from WoW's Group Finder", function()
    it("fills a partial queue group: search on Accept, whisper and invite, replace a decliner", function()
        local world = World.new()
        local tank = world:addClient("Tanky Mctank", { level = 20 })
        local dps1 = world:addClient("Dps One", { level = 20 })
        local dps2 = world:addClient("Dps Two", { level = 20 })
        world:list("Old Heal", "H", 799, 20, 400)
        world:list("Low Dps", "D", 799, 10, 900)
        world:list("Good Dps", "D", 799, 21, 300)
        world:list("Next Dps", "D", 799, 22, 100)
        world:list("Other Dungeon", "D", 800, 20, 999)
        world:advance(CONNECT)
        tank:slash("/dq join tank dm")
        dps1:slash("/dq join dps dm")
        dps2:slash("/dq join dps dm")
        world:advance(Config.PARTIAL_AFTER + 10)

        assert.is_true(tank:proposalShown())
        assert.are.equal("HD", tank:openPlaces())
        local searches = tank.searches
        tank:acceptPopup()
        assert.are.equal(searches + 1, tank.searches)
        dps1:acceptPopup()
        dps2:acceptPopup()
        world:advance(3)

        invitedOnly(tank, { "Dps One", "Dps Two", "Old Heal", "Good Dps" })
        assert.are.equal(0, tank.blockedSearches)
        local whispered = {}
        for _, w in ipairs(tank.whispers) do
            whispered[w.target] = w.text
        end
        assert.truthy(whispered["Old Heal"]:find("needs a healer", 1, true))

        tank:joins("Old Heal")
        tank:system("Good Dps declines your group invitation.")
        assert.is_true(tank:said("Good Dps did not join"))
        invitedOnly(tank, { "Next Dps" })
        tank:joins("Next Dps")
        assert.is_true(tank:said("Group complete!"))
        assert.are.equal("HEALER", tank.roles["Old Heal"])
        assert.are.equal("DAMAGER", tank.roles["Next Dps"])
        assert.are.equal("TANK", tank.roles["Tanky Mctank"])
        for _, name in ipairs(tank.invites) do
            assert.are_not.equal("Low Dps", name)
            assert.are_not.equal("Other Dungeon", name)
        end
    end)

    it("gives a freed role to a Forever Groups player in the queue before the Group Finder", function()
        local world = World.new()
        local tank = world:addClient("Tanky Mctank", { level = 20 })
        local addon = world:addClient("Addon Dps", { level = 20 })
        world:list("Listed Heal", "H", 799, 20, 300)
        for _, name in ipairs({ "Dps A", "Dps B", "Dps C", "Dps D" }) do
            world:list(name, "D", 799, 20, 200)
        end
        world:advance(CONNECT)
        tank:slash("/dq join tank dm")
        tank:slash("/dq fill")
        world:advance(2)
        assert.are.equal(4, #tank.invites)
        tank:joins("Listed Heal")
        addon:slash("/dq join dps dm")
        world:advance(2)
        local declined = tank.invites[#tank.invites]
        tank:system(declined .. " declines your group invitation.")
        world:advance(1)
        assert.are.equal(4, #tank.invites)
        assert.is_not_nil(tank:findText("Leaving DPS to Forever Groups players in the queue"))
        world:advance(10)
        assert.is_true(addon:proposalShown())
        assert.is_true(tank:proposalShown())
    end)

    it("does not wait for a Forever Groups player who is building a group of their own", function()
        local world = World.new()
        local tank = world:addClient("Tanky Mctank", { level = 20 })
        local builder = world:addClient("Builder Dps", { level = 20 })
        world:list("Listed Heal", "H", 799, 20, 300)
        for _, name in ipairs({ "Dps A", "Dps B", "Dps C", "Dps D" }) do
            world:list(name, "D", 799, 20, 200)
        end
        world:advance(CONNECT)
        tank:slash("/dq join tank dm")
        tank:slash("/dq fill")
        world:advance(2)
        tank:joins("Listed Heal")
        builder:slash("/dq join dps dm")
        builder.ns.engine:updateEntry(builder.ns.engine.myEntry.members, "HD")
        world:advance(2)
        tank:system(tank.invites[#tank.invites] .. " declines your group invitation.")
        world:advance(1)
        assert.are.equal(5, #tank.invites)
    end)

    it("does not wait for Forever Groups players when the own group is not queued", function()
        local world = World.new()
        local tank = world:addClient("Tanky Mctank", { level = 20 })
        local addon = world:addClient("Addon Dps", { level = 20 })
        world:list("Listed Heal", "H", 799, 20, 300)
        for _, name in ipairs({ "Dps A", "Dps B", "Dps C" }) do
            world:list(name, "D", 799, 20, 200)
        end
        world:advance(CONNECT)
        addon:slash("/dq join dps dm")
        world:advance(2)
        tank:slash("/dq")
        tank:click("CheckButton", "Tank")
        tank:slash("/dq fill")
        world:advance(2)
        assert.is_nil(tank.ns.engine.myEntry)
        assert.are.equal(4, #tank.invites)
    end)

    it("fills a role from the Group Finder after all when the Forever Groups player is not grouped", function()
        local world = World.new()
        local tank = world:addClient("Tanky Mctank", { level = 20 })
        local addon = world:addClient("Addon Dps", { level = 20 })
        world:list("Listed Heal", "H", 799, 20, 300)
        for _, name in ipairs({ "Dps A", "Dps B", "Dps C", "Dps D" }) do
            world:list(name, "D", 799, 20, 200)
        end
        world:advance(CONNECT)
        tank:slash("/dq join tank dm")
        tank:slash("/dq fill")
        world:advance(2)
        tank:joins("Listed Heal")
        addon:slash("/dq join dps dm")
        world:advance(2)
        for _, client in ipairs({ tank, addon }) do
            client.ns.engine.matcher = { findGroups = function() return {} end, findPartialGroup = function() end }
        end
        local declined = tank.invites[#tank.invites]
        tank:system(declined .. " declines your group invitation.")
        world:advance(25)
        assert.are.equal(5, #tank.invites)
        assert.are.equal("Dps D", tank.invites[5])
    end)

    it("keeps replacing from results up to 5 minutes old without a new search", function()
        local world = World.new()
        local tank = world:addClient("Tanky Mctank", { level = 20 })
        world:list("Listed Heal", "H", 799, 20, 300)
        for i = 1, 7 do
            world:list("Dps " .. i, "D", 799, 20, 400 - i)
        end
        world:advance(CONNECT)
        tank:slash("/dq")
        tank:click("CheckButton", "Tank")
        tank:slash("/dq fill")
        world:advance(2)
        local searches = tank.searches
        tank:joins("Listed Heal")
        tank:joins("Dps 1")
        tank:joins("Dps 2")
        world:advance(130)
        assert.are.equal(searches, tank.searches)
        invitedOnly(tank, { "Dps 7" })
    end)

    it("keeps the results fresh on key presses while filling, also when every role is invited", function()
        local world = World.new()
        local tank = world:addClient("Tanky Mctank", { level = 20 })
        tank.ns.db.noListing = true
        world:list("Listed Heal", "H", 799, 20, 300)
        for i = 1, 5 do
            world:list("Dps " .. i, "D", 799, 20, 300 - i)
        end
        world:advance(CONNECT)
        tank:slash("/dq")
        tank:click("CheckButton", "Tank")
        tank:slash("/dq fill")
        tank.ns.Window.toggle()
        assert.is_false(tank.ns.Window.isShown())
        world:advance(2)
        tank:joins("Listed Heal")
        tank:joins("Dps 1")
        tank:joins("Dps 2")
        local searches = tank.searches
        world:advance(20)
        tank:press("W")
        assert.are.equal(searches, tank.searches)
        world:advance(11)
        invitedOnly(tank, { "Dps 4" })
        assert.are.equal("", tank.ns.Filler.stillNeeded())
        tank:press("W")
        assert.are.equal(searches + 1, tank.searches)
    end)

    it("replaces a listed player who ignores the invite", function()
        local world = World.new()
        local client = world:addClient("Tanky Mctank", { level = 20 })
        world:list("Slow Heal", "H", 799, 20, 500)
        world:list("Quick Heal", "H", 799, 20, 100)
        world:list("Dps A", "D", 799)
        world:list("Dps B", "D", 799)
        world:list("Dps C", "D", 799)
        world:advance(CONNECT)
        client:slash("/dq")
        client:click("CheckButton", "Tank")
        client:slash("/dq fill")
        world:advance(2)
        invitedOnly(client, { "Slow Heal", "Dps A", "Dps B", "Dps C" })
        client:joins("Dps A")
        assert.are.equal("DAMAGER", client.roles["Dps A"])
        assert.are.equal("TANK", client.roles["Tanky Mctank"])
        world:advance(25)
        assert.is_false(client:said("Slow Heal did not answer"))
        world:advance(8)
        assert.is_true(client:said("Slow Heal did not answer"))
        invitedOnly(client, { "Quick Heal" })
    end)

    it("only lists the picks in a dry run", function()
        local world = World.new()
        local client = world:addClient("Tanky Mctank", { level = 20 })
        world:list("Heal", "H", 799)
        world:list("Dps A", "D", 799)
        world:advance(CONNECT)
        client:slash("/dq dryrun")
        client:slash("/dq")
        client:click("CheckButton", "Tank")
        client:slash("/dq fill")
        world:advance(2)
        assert.are.same({}, client.invites)
        assert.is_true(client:said("%[dry run%] Would invite Heal as Healer"))
        assert.is_not_nil(client:findText("Nobody listed for: DPS, DPS"))
    end)

    it("asks for another search when nobody fits, and searches only on clicks", function()
        local world = World.new()
        local client = world:addClient("Tanky Mctank", { level = 20 })
        world:advance(CONNECT)
        client:slash("/dq")
        local opened = client.searches
        client:click("CheckButton", "Tank")
        client:slash("/dq fill")
        world:advance(2)
        assert.is_not_nil(client:findText("Nobody listed for: Healer, DPS, DPS, DPS"))
        world:list("Late Heal", "H", 799)
        client:slash("/dq fill")
        world:advance(2)
        invitedOnly(client, { "Late Heal" })
        assert.are.equal(opened + 2, client.searches)
        assert.are.equal(0, client.blockedSearches)
        client:slash("/dq fill stop")
        assert.is_true(client:said("Stopped filling"))
    end)

    it("waits for the server to apply a role instead of inviting a second healer", function()
        local world = World.new()
        local tank = world:addClient("Tanky Mctank", { level = 20 })
        world:list("Listed Heal", "H", 799, 20, 300)
        world:list("Spare Heal", "H", 799, 20, 200)
        world:advance(CONNECT)
        tank:slash("/dq join tank dm")
        tank:slash("/dq fill")
        world:advance(2)
        invitedOnly(tank, { "Listed Heal" })
        tank.roleDelay = 1.5
        tank.roles["Listed Heal"] = "DAMAGER"
        tank:joins("Listed Heal")
        for _ = 1, 4 do
            tank:fire("GROUP_ROSTER_UPDATE")
        end
        world:advance(6)
        assert.are.equal("HEALER", tank.roles["Listed Heal"])
        for _, name in ipairs(tank.invites) do
            assert.are_not.equal("Spare Heal", name)
        end
    end)

    it("fills from the Group Finder while queued, reserving the invited roles", function()
        local world = World.new()
        local tank = world:addClient("Tanky Mctank", { level = 20 })
        local other = world:addClient("Other Player", { level = 20 })
        world:list("Listed Heal", "H", 799, 20, 300)
        world:advance(CONNECT)
        tank:slash("/dq")
        tank:click("CheckButton", "Tank")
        tank:click("Button", "None")
        tank:click("CheckButton", "The Deadmines")
        tank:click("CheckButton", "Wailing Caverns")
        tank:click("Button", "Find group")
        local joinedAt = tank.ns.engine.myEntry.joinedAt
        tank:slash("/dq fill")
        world:advance(2)

        invitedOnly(tank, { "Listed Heal" })
        local seen = other.ns.engine.queue:get("Tanky Mctank")
        assert.are.equal("H", seen.reserved)
        assert.are.same({ "5" }, seen.dungeons)

        tank:joins("Listed Heal")
        world:advance(1)
        local entry = tank.ns.engine.myEntry
        assert.are.equal(joinedAt, entry.joinedAt)
        assert.are.equal(2, #entry.members)
        assert.are.equal("H", entry.members[2].roles)
        assert.are.equal("", entry.reserved)
    end)

    it("pauses while a queue proposal is open and stops when the queue fills the group", function()
        local world = World.new()
        local tank = world:addClient("Tanky Mctank", { level = 20 })
        local others = {}
        for i, p in ipairs({ { "Heally Mcheal", "healer" }, { "Dps One", "dps" }, { "Dps Two", "dps" },
            { "Dps Three", "dps" } }) do
            others[i] = world:addClient(p[1], { level = 20 })
            others[i].role = p[2]
        end
        world:advance(CONNECT)
        tank:slash("/dq join tank dm")
        tank:slash("/dq fill")
        world:advance(2)
        assert.are.same({}, tank.invites)

        for _, client in ipairs(others) do
            client:slash("/dq join " .. client.role .. " dm")
        end
        world:advance(Config.MATCH_INTERVAL + 2)
        assert.is_true(tank:proposalShown())
        world:list("Listed Dps", "D", 799)
        tank:slash("/dq fill")
        world:advance(2)
        assert.are.same({}, tank.invites)

        tank:acceptPopup()
        for _, client in ipairs(others) do
            client:acceptPopup()
        end
        world:advance(3)
        for _, name in ipairs(tank.invites) do
            assert.are_not.equal("Listed Dps", name)
        end
        assert.is_true(tank:said("Group complete!"))
    end)

    it("lets addon players fill the rest and keeps inviting only for reserved roles", function()
        local world = World.new()
        local tank = world:addClient("Tanky Mctank", { level = 20 })
        local dps = {}
        for i, name in ipairs({ "Dps One", "Dps Two", "Dps Three" }) do
            dps[i] = world:addClient(name, { level = 20 })
        end
        world:list("Listed Heal", "H", 799, 20, 300)
        world:advance(CONNECT)
        tank:slash("/dq join tank dm")
        tank:slash("/dq fill")
        world:advance(2)
        invitedOnly(tank, { "Listed Heal" })
        for _, client in ipairs(dps) do
            client:slash("/dq join dps dm")
        end
        world:advance(Config.MATCH_INTERVAL + 2)

        assert.is_true(tank:proposalShown())
        assert.are.equal("H", tank:openPlaces())
        for _, client in ipairs({ tank, dps[1], dps[2], dps[3] }) do
            client:acceptPopup()
        end
        world:advance(3)
        invitedOnly(tank, { "Dps One", "Dps Two", "Dps Three" })
        local listed = 0
        for _, name in ipairs(tank.invites) do
            if name == "Listed Heal" then
                listed = listed + 1
            end
        end
        assert.are.equal(1, listed)
        tank:joins("Listed Heal")
        assert.is_true(tank:said("Listed Heal joined as Healer"))
    end)
end)

describe("A group filled to five", function()
    it("is announced once, shown as complete, and offers to remove the own listing", function()
        local world = World.new()
        local leader = world:addClient("Tanky Mctank", { level = 20 })
        leader.listed = true
        for i, p in ipairs({ { "Heal", "H" }, { "Dps A", "D" }, { "Dps B", "D" }, { "Dps C", "D" } }) do
            world:list(p[1], p[2], 799, 20, 100 + i)
        end
        world:advance(CONNECT)
        leader:slash("/dq")
        leader:click("CheckButton", "Tank")
        leader:click("Button", "None")
        leader:click("CheckButton", "The Deadmines")
        leader:slash("/dq fill")
        world:advance(2)
        for _, name in ipairs({ "Heal", "Dps A", "Dps B" }) do
            leader:joins(name)
        end
        world:advance(1)
        assert.is_not_nil(leader:findText("4/5  ·  open: DPS"))
        leader:joins("Dps C")
        world:advance(1)
        assert.are.same({ "Group complete! The Deadmines" }, leader.notices)
        assert.is_not_nil(leader:findText("^Group complete  ·  you lead"))
        assert.is_not_nil(leader:findText("^The Deadmines$"))
        for _, name in ipairs({ "Tanky Mctank", "Heal", "Dps A", "Dps B", "Dps C" }) do
            assert.is_not_nil(leader:findText("^" .. name .. "$"), name)
        end
        assert.is_nil(leader:findText("^open$"))
        assert.is_true(leader:said("still listed in WoW's Group Finder"))
        leader:click("Button", "Remove LFG listing")
        assert.is_false(leader.listed)
        world:advance(5)
        assert.are.equal(1, #leader.notices)
    end)
end)

describe("A player who switches roles after joining", function()
    it("is followed: the addon looks for the role that became free", function()
        local world = World.new()
        local leader = world:addClient("Tanky Mctank", { level = 20 })
        world:list("Listed Heal", "H", 799, 20, 300)
        world:list("Dps A", "D", 799, 20, 200)
        world:list("Dps B", "D", 799, 20, 100)
        world:advance(CONNECT)
        leader:slash("/dq")
        leader:click("CheckButton", "Tank")
        leader:click("Button", "None")
        leader:click("CheckButton", "The Deadmines")
        leader:slash("/dq fill")
        world:advance(2)
        leader:joins("Listed Heal")
        world:advance(6)
        assert.are.equal("HEALER", leader.roles["Listed Heal"])

        world:list("Second Heal", "H", 799, 20, 50)
        leader.roles["Listed Heal"] = "DAMAGER"
        leader:fire("ROLE_CHANGED_INFORM")
        world:advance(1)
        assert.are.equal("DAMAGER", leader.roles["Listed Heal"])
        assert.is_true(leader:said("Roles changed; now looking for: Healer"))
        leader:slash("/dq fill")
        world:advance(2)
        invitedOnly(leader, { "Second Heal" })
        world:advance(10)
        assert.are.equal("DAMAGER", leader.roles["Listed Heal"])
    end)
end)
