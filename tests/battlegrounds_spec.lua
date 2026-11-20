local World = require("tests.helpers.wowmock")
local Battlegrounds = require("core.battlegrounds")

local CONNECT = 30

describe("battleground level brackets", function()
    it("put players together by tens from level 10", function()
        assert.are.equal(20, Battlegrounds.bracket(25))
        assert.are.equal("10-19", Battlegrounds.bracketText(17))
        assert.is_nil(Battlegrounds.bracket(9))
        assert.is_true(Battlegrounds.sameBracket(21, 29))
        assert.is_false(Battlegrounds.sameBracket(19, 20))
        assert.are.equal(0, #Battlegrounds.forLevel(9))
        assert.are.equal("wsg", Battlegrounds.forLevel(10)[1].id)
    end)
end)

describe("the Battlegrounds tab", function()
    local function setup()
        local world = World.new()
        world:list("Bg Heal", "H", 920, 22)
        world:list("Bg Dps", "D", 920, 24)
        world:list("Low Dps", "D", 919, 15)
        world:listGroup("Bg Lead", 920, { T = 0, H = 0, D = 2 })
        world:list("Dungeon Dps", "D", 799, 25)
        local client = world:addClient("Solo Player", { level = 25 })
        world:advance(CONNECT)
        client:slash("/dq")
        client:click("Button", "Battlegrounds")
        world:advance(1)
        return world, client
    end

    it("lists the battlegrounds for the player's bracket with who looks for them in the Group Finder", function()
        local _, client = setup()
        assert.are.equal("battlegrounds", client.ns.charDb.tab)
        local row = client:findText("^Warsong Gulch$").parent
        assert.are.equal("20-29 · 10 players", row.range.text)
        assert.are.equal("1", row.counts.texts.H.text)
        assert.are.equal("1", row.counts.texts.D.text)
        assert.are.equal("1 group", row.groups.text)
        assert.is_not_nil(client:findText("^Battlegrounds for level 25  ·  2 selected$"))
        assert.are.equal("20-29 · 15 players", client:findText("^Arathi Basin$").parent.range.text)
        assert.is_nil(client:findText("^Darkspear Islands$"))
        assert.is_not_nil(client:findText("^·  1 group needs you$"))
        assert.is_nil(client:findText("^Dungeons for level"))
        assert.is_true(client.ns.WindowParts.ui.join.shown)
        client:click("CheckButton", "DPS")
        assert.are.equal("DPS  ·  Premade (10)  ·  2 battlegrounds", client.ns.WindowParts.ui.joinSummary.text)
        assert.is_not_nil(client:find("Button", "Premade (10)"))
    end)

    it("says when the battlegrounds were searched", function()
        local _, client = setup()
        assert.is_not_nil(select(2, client.ns.LfgList.battlegroundListings()))
        assert.is_nil(client:findText("^not searched yet$"))
        assert.is_not_nil(client:findText("^searched "))
    end)

    it("finds the listings under the Group Finder's activities for the player's bracket", function()
        local world = World.new()
        world:list("Wsg Dps", "D", 920, 22)
        world:list("Ab Heal", "H", 926, 23)
        local client = world:addClient("Solo Player", { level = 25 })
        world:advance(CONNECT)
        client:slash("/dq")
        client:click("Button", "Battlegrounds")
        world:advance(1)
        local found = {}
        for _, listing in ipairs(client.ns.LfgList.battlegroundListings()) do
            found[listing.name] = listing.battlegrounds[1]
        end
        assert.are.same({ ["Wsg Dps"] = "wsg", ["Ab Heal"] = "ab" }, found)
    end)

    it("shows a listed battleground group of more than five in Who is looking", function()
        local world = World.new()
        local id = world:listGroup("Ab Lead", 926, { T = 0, H = 0, D = 0 })
        world.listings[id].numMembers = 11
        local client = world:addClient("Solo Player", { level = 25 })
        world:advance(CONNECT)
        client:slash("/dq")
        client:click("Button", "Battlegrounds")
        world:advance(1)
        local groups = client.ns.QueueWindow.groupFinderGroups("battlegrounds")
        assert.are.equal(1, #groups)
        assert.are.equal(4, groups[1].open)
    end)

    it("searches under the new bracket's activities after a level up", function()
        local world = World.new()
        world:list("Wsg Dps", "D", 920, 22)
        local client = world:addClient("Solo Player", { level = 19 })
        world:advance(CONNECT)
        client:slash("/dq")
        client:click("Button", "Battlegrounds")
        world:advance(6)
        assert.are.equal(0, #client.ns.LfgList.battlegroundListings())
        client.level = 20
        client:click("Button", "Dungeons")
        world:advance(6)
        client:click("Button", "Battlegrounds")
        world:advance(1)
        assert.are.equal("Wsg Dps", client.ns.LfgList.battlegroundListings()[1].name)
    end)

    it("keeps no activity of the old bracket when the new one has none", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 29 })
        world:advance(CONNECT)
        assert.are.equal(920, client.ns.LfgList.battlegroundActivity("wsg"))
        client.level = 30
        assert.is_nil(client.ns.LfgList.battlegroundActivity("wsg"))
    end)

    it("searches again on every switch to the tab", function()
        local world, client = setup()
        world:advance(2)
        client:click("Button", "Dungeons")
        world:advance(4)
        client:click("Button", "Battlegrounds")
        assert.is_true(client.ns.LfgList.secondsSinceBattlegroundSearch() < 1)
    end)

    it("knows each listed battleground group's open places", function()
        local _, client = setup()
        local listings = client.ns.LfgList.battlegroundListings()
        local lead
        for _, listing in ipairs(listings) do
            if listing.leader == "Bg Lead" then
                lead = listing
            end
        end
        assert.are.equal(7, lead.open)
        assert.are.same({ "wsg" }, lead.battlegrounds)
        assert.are.equal(2, #client.ns.QueueWindow.groupFinderPlayers("battlegrounds"))
        assert.are.equal(1, #client.ns.QueueWindow.groupFinderGroups("battlegrounds"))
    end)

    it("keeps the dungeon results apart", function()
        local world, client = setup()
        world:advance(6)
        client:click("Button", "Dungeons")
        client:click("Button", "None")
        world:advance(6)
        client:click("CheckButton", "The Deadmines")
        world:advance(1)
        local names = {}
        for _, listing in ipairs(client.ns.LfgList.listings()) do
            names[#names + 1] = listing.name
        end
        assert.are.same({ "Dungeon Dps" }, names)
        assert.are.equal(3, #client.ns.LfgList.battlegroundListings())
    end)

    it("remembers the wish to lead apart from the other tabs", function()
        local _, client = setup()
        client:click("Button", "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:16:16|t Lead a group")
        assert.is_true(client.ns.charDb.wantsLeadBattlegrounds)
        assert.is_nil(client.ns.charDb.wantsLead)
    end)
end)

describe("Find group on the Battlegrounds tab", function()
    local function ready(world, client, roles)
        world:advance(CONNECT)
        client:slash("/dq")
        client:click("Button", "Battlegrounds")
        for _, role in ipairs(roles) do
            client:click("CheckButton", role)
        end
        world:advance(1)
    end

    it("marks the tab as beta, with a tooltip that says why", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 25 })
        world:advance(CONNECT)
        client:slash("/dq")
        local tab = client:find("Button", "Battlegrounds", client:frame("ForeverGroupsFrame"))
        assert.are.equal("Beta", tab.beta.text)
        assert.is_true(tab.beta.shown)
        for _, hook in ipairs(tab.hooks.OnEnter) do
            hook(tab)
        end
        assert.are.equal("Battlegrounds (Beta)", client.env.GameTooltip.text)
        assert.is_truthy(client.env.GameTooltip.lines[1]:find("not fully tested", 1, true))
    end)

    it("asks a listed group's leader in the player's bracket and joins when invited", function()
        local world = World.new()
        world:listGroup("Bg Lead", 920, { T = 0, H = 0, D = 1 })
        world:listGroup("Dungeon Lead", 799, { T = 0, H = 1, D = 1 })
        local client = world:addClient("Solo Player", { level = 25 })
        ready(world, client, { "Healer" })
        client:click("Button", "Find group")
        world:advance(2)
        local asked = client.whispers[#client.whispers]
        assert.are.equal("Bg Lead", asked.target)
        assert.is_truthy(asked.text:find("could you invite me for Warsong Gulch", 1, true), asked.text)
        assert.is_not_nil(client:findText("^Looking for a Warsong Gulch group$"))
        client:invitedBy("Bg Lead")
        world:advance(1)
        assert.are.same({ "Bg Lead" }, client.party)
        assert.is_false(client.ns.BgFinder.isActive())
        assert.is_true(client:said("Joined Bg Lead's battleground group"))
    end)

    it("does not count a leader as asked when the whisper could not go out", function()
        local world = World.new()
        world:listGroup("Bg Lead", 920, { T = 0, H = 0, D = 1 })
        local client = world:addClient("Solo Player", { level = 25 })
        ready(world, client, { "Healer" })
        client.ns.db.noWhisper = true
        client:click("Button", "Find group")
        world:advance(2)
        assert.is_false(client.ns.BgFinder.wasAsked("Bg Lead"))
        client.ns.db.noWhisper = false
        client.ns.BgFinder.onResults()
        assert.is_true(client.ns.BgFinder.wasAsked("Bg Lead"))
    end)

    it("builds a premade of ten from listed players, becoming a raid past five", function()
        local world = World.new()
        for i = 1, 9 do
            world:list("Bg Player" .. i, i <= 2 and "H" or "D", 920, 22, 100 + i)
        end
        world:list("Low Player", "D", 919, 15)
        local client = world:addClient("Solo Player", { level = 25 })
        ready(world, client, { "Tank" })
        client:click("Button", "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:16:16|t Lead a group")
        client:click("Button", "Find players")
        world:advance(2)
        assert.are.equal(4, #client.invites)
        assert.are.equal("Bg Player2", client.invites[1])
        for _, name in ipairs(client.invites) do
            client:joins(name)
        end
        world:advance(3)
        assert.are.equal(1, client.raidConversions)
        assert.is_true(client.inRaid)
        world:advance(2)
        assert.are.equal(9, #client.invites)
        assert.is_false(table.concat(client.invites, ","):find("Low Player", 1, true) ~= nil)
        for i = 5, 9 do
            client:joins(client.invites[i])
        end
        world:advance(2)
        assert.is_false(client.ns.BgFinder.isActive())
        assert.is_true(client:said("group is complete %(10 players%)"))
    end)

    it("keeps places in a premade for two healers when none are listed", function()
        local world = World.new()
        for i = 1, 12 do
            world:list("Bg Player" .. i, "D", 920, 22)
        end
        local client = world:addClient("Solo Player", { level = 25 })
        ready(world, client, { "DPS" })
        client:click("Button", "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:16:16|t Lead a group")
        client:click("Button", "Find players")
        world:advance(2)
        for _, name in ipairs(client.invites) do
            client:joins(name)
        end
        world:advance(5)
        for i = 5, #client.invites do
            client:joins(client.invites[i])
        end
        world:advance(5)
        assert.are.equal(7, #client.invites)
        assert.is_true(client.ns.BgFinder.isActive())
        assert.is_truthy(client:findText("Still looking for 2 healers"))
        world:list("Late Healer", "H", 920, 22)
        client.inClick, client.clickSearched = true, false
        client.ns.LfgList.searchBattlegrounds()
        client.inClick = false
        world:advance(2)
        assert.are.equal("Late Healer", client.invites[8])
    end)

    it("counts a healer already in the leader's party", function()
        local world = World.new()
        for i = 1, 12 do
            world:list("Bg Player" .. i, "D", 920, 22)
        end
        local client = world:addClient("Solo Player", { level = 25 })
        client.party, client.isLeader = { "Friend Heal" }, true
        client.roles["Friend Heal"] = "HEALER"
        ready(world, client, { "DPS" })
        client:click("Button", "Find group")
        world:advance(2)
        for _, name in ipairs(client.invites) do
            client:joins(name)
        end
        world:advance(5)
        for i = 4, #client.invites do
            client:joins(client.invites[i])
        end
        world:advance(5)
        assert.are.equal(7, #client.invites)
        assert.is_truthy(client:findText("Still looking for 1 healer"))
    end)

    it("stops looking once the player joins someone else's raid", function()
        local world = World.new()
        world:listGroup("Bg Lead", 920, { T = 0, H = 0, D = 1 })
        local client = world:addClient("Solo Player", { level = 25 })
        ready(world, client, { "DPS" })
        client:click("Button", "Find group")
        world:advance(2)
        assert.is_true(client.ns.BgFinder.isActive())
        client.party, client.inRaid, client.isLeader = { "Raid Lead", "Raid Two", "Raid Three" }, true, false
        client:fire("GROUP_ROSTER_UPDATE")
        world:advance(2)
        assert.is_false(client.ns.BgFinder.isActive())
    end)

    it("counts the player as a healer when they ticked Healer", function()
        local world = World.new()
        for i = 1, 6 do
            world:list("Bg Player" .. i, "D", 920, 22)
        end
        local client = world:addClient("Solo Player", { level = 25 })
        ready(world, client, { "Healer" })
        client:click("Button", "Party (5)")
        client:click("Button", "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:16:16|t Lead a group")
        client:click("Button", "Find players")
        world:advance(2)
        assert.are.equal(4, #client.invites)
    end)

    it("waits for an unanswered invite's place instead of inviting into a full party", function()
        local world = World.new()
        for i = 1, 8 do
            world:list("Bg Player" .. i, "D", 920, 22)
        end
        local client = world:addClient("Solo Player", { level = 25 })
        ready(world, client, { "Healer" })
        client:click("Button", "Party (5)")
        client:click("Button", "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:16:16|t Lead a group")
        client:click("Button", "Find players")
        world:advance(2)
        assert.are.equal(4, #client.invites)
        for i = 1, 3 do
            client:joins(client.invites[i])
        end
        world:advance(40)
        assert.are.same({}, client.refusedInvites)
        assert.are.equal(4, #client.invites)
        assert.is_false(client:logged("did not answer the invite"))
        world:advance(25)
        assert.are.equal(5, #client.invites)
        assert.are.same({}, client.refusedInvites)
    end)

    it("stops building when the player leaves the group", function()
        local world = World.new()
        for i = 1, 9 do
            world:list("Bg Player" .. i, "D", 920, 22)
        end
        local client = world:addClient("Solo Player", { level = 25 })
        ready(world, client, { "Tank" })
        client:click("Button", "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:16:16|t Lead a group")
        client:click("Button", "Find players")
        world:advance(2)
        client:joins(client.invites[1])
        world:advance(1)
        local invited = #client.invites
        client.party = {}
        client:fire("GROUP_ROSTER_UPDATE")
        world:advance(5)
        assert.is_false(client.ns.BgFinder.isActive())
        assert.are.equal(invited, #client.invites)
        assert.is_true(client:said("You left your Warsong Gulch group"))
    end)

    it("answers a leader's question with the one role it offered", function()
        local world = World.new()
        world:listGroup("Bg Lead", 920, { T = 0, H = 0, D = 1 })
        local client = world:addClient("Solo Player", { level = 25 })
        ready(world, client, { "Healer", "DPS" })
        client:click("Button", "Find group")
        world:advance(2)
        assert.is_truthy(client.whispers[#client.whispers].text:find("Level 25 Healer here", 1, true))
        client:whisperFrom("Bg Lead", "what spec?")
        local answer = client.whispers[#client.whispers]
        assert.are.equal("Bg Lead", answer.target)
        assert.is_truthy(answer.text:find(", Healer.", 1, true), answer.text)
    end)

    it("frees the place of a player who declines, in WoW's own words", function()
        local world = World.new()
        for i = 1, 6 do
            world:list("Bg Player" .. i, "D", 920, 22, 100 + i)
        end
        local client = world:addClient("Solo Player", { level = 25 })
        ready(world, client, { "Healer" })
        client:click("Button", "Party (5)")
        client:click("Button", "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:16:16|t Lead a group")
        client:click("Button", "Find players")
        world:advance(2)
        assert.are.equal(4, #client.invites)
        client:system(client.invites[1] .. " declines your group invitation.")
        world:advance(2)
        assert.are.equal(5, #client.invites)
    end)

    it("leaves the dungeon queue once a player it invited joins", function()
        local world = World.new()
        for i = 1, 4 do
            world:list("Bg Player" .. i, "D", 920, 22)
        end
        local client = world:addClient("Solo Player", { level = 25 })
        world:advance(CONNECT)
        client:slash("/dq join tank dm")
        client:slash("/dq")
        client:click("Button", "Battlegrounds")
        client:click("CheckButton", "Tank")
        client:click("Button", "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:16:16|t Lead a group")
        client:click("Button", "Find players")
        world:advance(2)
        assert.is_not_nil(client.ns.engine.myEntry)
        client:joins(client.invites[1])
        world:advance(1)
        assert.is_nil(client.ns.engine.myEntry)
        assert.is_true(client:said("A battleground group formed, so you left the dungeon queue"))
    end)

    it("locks the roles and hides the list while it looks, until Stop", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 25 })
        ready(world, client, { "Healer" })
        client:click("Button", "Find group")
        world:advance(5)
        local W = client.ns.WindowParts
        assert.is_not_nil(client:find("Button", "Dungeons", client:frame("ForeverGroupsFrame")))
        assert.is_false(W.roleToggles.T.shown)
        assert.is_nil(client:findText("^Battlegrounds for level 25"))
        assert.is_nil(client:find("CheckButton", "Warsong Gulch"))
        assert.is_true(W.ui.headerLooking.shown)
        assert.are.equal(W.ui.statusTitle, W.ui.headerLookingDot.point[2])
        assert.are.equal("Stop", W.ui.join.text)
        client:click("Button", "Stop")
        world:advance(1)
        assert.is_true(client:find("CheckButton", "Tank").enabled)
        assert.is_true(client:find("CheckButton", "Warsong Gulch").enabled)
    end)

    it("forgets a leader asked by hand after five minutes", function()
        local world = World.new()
        world:listGroup("Bg Lead", 920, { T = 0, H = 0, D = 1 })
        local client = world:addClient("Solo Player", { level = 25 })
        ready(world, client, { "DPS" })
        client.ns.LfgList.searchBattlegrounds()
        world:advance(1)
        local listing
        for _, found in ipairs(client.ns.LfgList.battlegroundListings()) do
            listing = found.leader == "Bg Lead" and found or listing
        end
        client.ns.BgFinder.request(listing)
        assert.is_true(client.ns.BgFinder.wasAsked("Bg Lead"))
        world:advance(301)
        assert.is_false(client.ns.BgFinder.wasAsked("Bg Lead"))
        client:invitedBy("Bg Lead")
        assert.is_nil(client.acceptedFrom)
    end)

    it("keeps to a party of five when chosen", function()
        local world = World.new()
        for i = 1, 6 do
            world:list("Bg Player" .. i, "D", 920, 22)
        end
        local client = world:addClient("Solo Player", { level = 25 })
        ready(world, client, { "Healer" })
        client:click("Button", "Party (5)")
        client:click("Button", "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:16:16|t Lead a group")
        client:click("Button", "Find players")
        world:advance(2)
        for _, name in ipairs(client.invites) do
            client:joins(name)
        end
        world:advance(3)
        assert.are.equal(4, #client.invites)
        assert.is_nil(client.raidConversions)
        assert.is_true(client:said("group is complete %(5 players%)"))
    end)
end)
