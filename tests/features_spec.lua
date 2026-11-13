local World = require("tests.helpers.wowmock")

describe("getting the player's attention", function()
    it("flashes the taskbar icon when an asked leader invites, unless turned off", function()
        local world = World.new()
        local solo = world:addClient("Solo Dps", { level = 20 })
        world:advance(30)
        world:listGroup("Group Lead", 799, { T = 0, H = 0, D = 2 })
        world:listGroup("Other Lead", 799, { T = 0, H = 0, D = 2 })
        solo.ns.db.noAutoAcceptAsked = true
        solo:slash("/dq join dps dm")
        world:advance(4)
        local before = solo.flashes or 0
        solo:invitedBy("Group Lead")
        assert.are.equal(before + 1, solo.flashes)
        solo.ns.db.noFlash = true
        solo:invitedBy("Other Lead")
        assert.are.equal(before + 1, solo.flashes)
    end)
end)

describe("dungeon quests", function()
    it("counts the quests in the quest log for each dungeon", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20, questLog = {
            { "Westfall", true }, { "The Defias Brotherhood" },
            { "The Deadmines", true }, { "Red Silk Bandanas" }, { "Oh Brother..." },
            { "Wailing Caverns", true }, { "Deviate Hides" },
            { "Scarlet Monastery", true }, { "In the Name of the Light" },
        } })
        world:advance(12)
        assert.are.same({ "Red Silk Bandanas", "Oh Brother..." }, client.ns.Quests.forDungeon("5"))
        assert.are.equal(1, #client.ns.Quests.forDungeon("13"))
        assert.are.equal(1, #client.ns.Quests.forDungeon("17"))
        client:slash("/dq")
        assert.are.equal("2 quests", client:find("CheckButton", "The Deadmines").quests.text)
        assert.are.equal("1 quest", client:find("CheckButton", "Wailing Caverns").quests.text)
        assert.is_false(client:find("CheckButton", "Ruins of Lordaeron").quests.shown)
    end)
end)

describe("dungeon entrances", function()
    it("learns an entrance when a player walks in, and shares it on the channel", function()
        local world = World.new()
        local walker = world:addClient("Walker Player", { level = 20 })
        local other = world:addClient("Other Player", { level = 20 })
        for _, client in ipairs({ walker, other }) do
            client.ns.Dungeons.knownEntrance = function() end
        end
        world:advance(12)
        walker.positions.player = { 1413, 0.4612, 0.3655 }
        world:advance(1)
        walker.inInstance, walker.instanceName = true, "Wailing Caverns"
        walker:fire("PLAYER_ENTERING_WORLD")
        world:advance(1)
        local learned = walker.ns.Entrances.get("4")
        assert.is_true(learned.learned)
        assert.are.equal(1413, learned.map)
        local shared = other.ns.Entrances.get("4")
        assert.is_true(shared.learned)
        assert.are.equal(0.461, shared.x)
    end)

    it("answers another player's question for an entrance", function()
        local world = World.new()
        local knows = world:addClient("Knows Way", { level = 20 })
        local asks = world:addClient("Asks Way", { level = 20 })
        for _, client in ipairs({ knows, asks }) do
            client.ns.Dungeons.knownEntrance = function() end
        end
        world:advance(12)
        knows.ns.db.entrances = { ["2"] = { map = 1429, x = 0.5, y = 0.25 } }
        assert.is_nil(asks.ns.Entrances.get("2"))
        asks.ns.Entrances.request("2")
        world:advance(6)
        assert.are.same({ map = 1429, x = 0.5, y = 0.25, learned = true }, asks.ns.Entrances.get("2"))
    end)

    it("sets a waypoint when the group is complete and shows how far everyone is", function()
        local world = World.new()
        local leader = world:addClient("Tanky Mctank", { level = 20, journalEntrances = {
            [1436] = { { name = "The Deadmines", position = { GetXY = function()
                return 0.425, 0.717
            end }, journalInstanceID = 63 } },
        } })
        world:list("Heal", "H", 799, 20, 300)
        world:list("Dps A", "D", 799, 20, 300)
        world:list("Dps B", "D", 799, 20, 300)
        world:list("Dps C", "D", 799, 20, 300)
        world:advance(30)
        leader.positions.player = { 1436, 0.426, 0.700 }
        leader.positions.party1 = { 1436, 0.425, 0.717 }
        leader:slash("/dq join tank dm")
        world:advance(2)
        for _, name in ipairs({ "Heal", "Dps A", "Dps B", "Dps C" }) do
            leader:joins(name)
        end
        world:advance(2)
        assert.are.same({ map = 1436, x = 0.425, y = 0.717 }, leader.waypoint)
        assert.is_true(leader:said("Waypoint set to the entrance of The Deadmines%."))
        leader:slash("/dq")
        assert.is_not_nil(leader:findText("^18%d? yd$") or leader:findText("^20 yd$")
            or leader:findText("^at entrance$"))
        assert.is_not_nil(leader:findText("^far away$"))
        assert.is_not_nil(leader:findText("of 5 at the entrance"))
        assert.is_not_nil(leader:find("Button", "Waypoint to entrance"))
    end)
end)

describe("finding a replacement", function()
    local function inDungeon()
        local world = World.new()
        local leader = world:addClient("Tanky Mctank", { level = 20 })
        for _, listing in ipairs({ { "Heal", "H" }, { "Dps A", "D" }, { "Dps B", "D" }, { "Dps C", "D" },
            { "Dps D", "D" } }) do
            world:list(listing[1], listing[2], 799, 20, 300)
        end
        world:advance(30)
        leader:slash("/dq join tank dm")
        world:advance(2)
        for _, name in ipairs({ "Heal", "Dps A", "Dps B", "Dps C" }) do
            leader:joins(name)
        end
        world:advance(2)
        assert.is_false(leader.ns.Filler.isActive())
        leader.inInstance, leader.instanceName = true, "The Deadmines"
        leader:fire("PLAYER_ENTERING_WORLD")
        world:advance(1)
        return world, leader
    end

    it("keeps the group card, its quest buttons and the status bar inside", function()
        local world, leader = inDungeon()
        leader:fire("ENCOUNTER_END", 1, "Rhahk'Zor", 1, 5, 1)
        world:advance(1)
        leader:slash("/dq")
        assert.is_nil(leader:find("Button", "Dungeons"))
        assert.is_not_nil(leader:findText("^The Deadmines$"))
        assert.is_not_nil(leader:findText("^Group complete  ·  you lead  ·  1 of 5 inside  ·  1/8 bosses$"))
        assert.is_not_nil(leader:find("Button", "Share my quests"))
        assert.is_not_nil(leader:find("Button", "Quest progress"))
        assert.is_nil(leader:find("Button", "Waypoint to entrance"))
        assert.is_nil(leader:findText("^Your party is complete"))
    end)

    it("shows the group's dungeon as a banner behind the card's title, and none without a group", function()
        local world, leader = inDungeon()
        leader:slash("/dq")
        local card = leader.ns.WindowParts.ui.card
        assert.is_true(card.bannerTop.shown)
        assert.are.equal("Interface\\Glues\\LoadingScreens\\LoadScreenDeadmines", card.bannerTop.texture)
        assert.are.equal(card.bannerTop.texture, card.bannerFade.texture)
        local slot = leader.ns.WindowParts.slots[1]
        assert.is_true(slot.point[5] <= -(card.bannerTop.height + card.bannerFade.height))
        assert.are.equal(slot.point[4], -card.bannerTop.point[2])
        leader.party = {}
        leader:fire("GROUP_ROSTER_UPDATE")
        world:advance(1)
        leader.ns.Window.refresh()
        assert.is_false(card.bannerTop.shown)
    end)

    it("starts over for a new group, and after the same boss is killed again", function()
        local world, leader = inDungeon()
        for i = 1, 8 do
            leader:fire("ENCOUNTER_END", i, "Boss " .. i, 1, 5, 1)
        end
        leader.party = {}
        leader:fire("GROUP_ROSTER_UPDATE")
        leader.inInstance = false
        leader:fire("PLAYER_ENTERING_WORLD")
        world:advance(1)
        assert.is_nil(leader.ns.Run.current())
        assert.are.equal(8, leader.ns.db.bossCounts["5"])

        leader.party = { "Other Heal" }
        leader.inInstance = true
        leader:fire("PLAYER_ENTERING_WORLD")
        assert.are.equal(0, leader.ns.Run.current().kills)
        leader:fire("ENCOUNTER_END", 1, "Boss 1", 1, 5, 1)
        leader:fire("ENCOUNTER_END", 2, "Boss 2", 1, 5, 1)
        leader:fire("ENCOUNTER_END", 1, "Boss 1", 1, 5, 1)
        assert.are.equal(1, leader.ns.Run.current().kills)
    end)

    it("leaves kills in other instances out of the run", function()
        local world, leader = inDungeon()
        leader:fire("ENCOUNTER_END", 1, "Rhahk'Zor", 1, 5, 1)
        leader.instanceName, leader.instanceType = "Some Delve", "scenario"
        leader:fire("PLAYER_ENTERING_WORLD")
        for i = 2, 14 do
            leader:fire("ENCOUNTER_END", i, "Delve Boss", 1, 5, 1)
        end
        leader.party = {}
        leader.inInstance = false
        leader:fire("GROUP_ROSTER_UPDATE")
        world:advance(1)
        assert.are.equal(1, leader.ns.db.bossCounts["5"])
        assert.are.equal(8, leader.ns.Run.bossTotal("5"))
    end)

    it("shows the tabs again once the group came back out of the dungeon", function()
        local world, leader = inDungeon()
        leader.ns.Window.show()
        assert.is_true(leader.ns.Window.isShown())
        assert.is_nil(leader:find("Button", "Quests"))
        leader.inInstance = false
        leader:fire("PLAYER_ENTERING_WORLD")
        world:advance(1)
        assert.is_not_nil(leader:find("Button", "Quests"))
    end)

    it("counts a boss whose name WoW keeps secret", function()
        local world, leader = inDungeon()
        leader:fire("ENCOUNTER_END", 1, World.SECRET, 1, 5, 1)
        world:advance(1)
        assert.are.equal(1, leader.ns.Run.current().kills)
        assert.is_true(leader.ns.charDb.run.kills["1"] == true)
    end)

    it("asks the leader when someone leaves before every boss is down", function()
        local world, leader = inDungeon()
        leader:fire("ENCOUNTER_END", 1, "Rhahk'Zor", 1, 5, 1)
        leader:fire("ENCOUNTER_END", 2, "Sneed", 1, 5, 1)
        leader:fire("ENCOUNTER_END", 3, "Gilnid", 1, 5, 0)
        leader:leaves("Dps A")
        world:advance(1)
        assert.are.equal(1, #leader.popups)
        local text = leader.env.StaticPopupDialogs[leader.popups[1]].text
        assert.are.equal("Dps A left the group. 2/8 bosses down. Queue the group to find a replacement DPS?", text)

        leader:acceptStaticPopup()
        assert.is_true(leader.ns.Filler.isActive())
        assert.are.equal("Dps D", leader.invites[#leader.invites])
        assert.is_true(leader:said("Looking for a replacement DPS for The Deadmines"))
        assert.is_true(leader:said("filling the last spots, so you left the queue for now"))
        leader:system(string.format(leader.env.ERR_DECLINE_GROUP_S, "Dps D"))
        world:advance(6)
        assert.is_not_nil(leader.ns.engine.myEntry)
        assert.are.equal(4, #leader.ns.engine.myEntry.members)
    end)

    it("counts the bosses against the Adventure Guide's list, found by the map inside", function()
        local world, leader = inDungeon()
        leader.journalMaps[291], leader.journalBosses[63] = 63, 6
        leader.positions.player = { 291, 0.5, 0.5 }
        leader:fire("PLAYER_ENTERING_WORLD")
        leader:fire("ENCOUNTER_END", 1, "Rhahk'Zor", 1, 5, 1)
        leader:leaves("Heal")
        world:advance(1)
        local text = leader.env.StaticPopupDialogs[leader.popups[1]].text
        assert.truthy(text:find("1/6 bosses down", 1, true))
        leader.inInstance = false
        assert.are.equal(6, leader.ns.Run.bossTotal("5"))
        assert.truthy(text:find("replacement Healer", 1, true))
    end)

    it("does not ask once every boss is down", function()
        local world, leader = inDungeon()
        for i = 1, 8 do
            leader:fire("ENCOUNTER_END", i, "Boss " .. i, 1, 5, 1)
        end
        leader:leaves("Dps B")
        world:advance(1)
        assert.are.equal(0, #leader.popups)
        assert.is_true(leader:said("every boss is down"))
    end)

    it("learns how many bosses a dungeon has when the run is over", function()
        local world, leader = inDungeon()
        for i = 1, 4 do
            leader:fire("ENCOUNTER_END", i, "Boss " .. i, 1, 5, 1)
        end
        leader.inInstance = false
        leader.party = {}
        leader:fire("GROUP_ROSTER_UPDATE")
        world:advance(1)
        assert.are.equal(4, leader.ns.db.bossCounts["5"])
    end)
end)

describe("dungeon level ranges", function()
    it("come from WoW's Group Finder when the addon loads", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20,
            activityLevels = { [1984] = { 15, 21 }, [799] = { 18, 23 } } })
        world:advance(12)
        assert.are.equal("15-21", client.ns.Dungeons.rangeText(client.ns.Dungeons.get("2")))
        assert.are.equal("18-23", client.ns.Dungeons.rangeText(client.ns.Dungeons.get("5")))
        assert.are.equal("?", client.ns.Dungeons.rangeText(client.ns.Dungeons.get("3")))
    end)
end)

describe("data from WoW itself", function()
    local function vector(x, y)
        return { GetXY = function()
            return x, y
        end }
    end

    it("takes dungeon entrances and boss lists from WoW", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20,
            journalEntrances = {
                [1436] = { { name = "The Deadmines", position = vector(0.43, 0.70), journalInstanceID = 63 } },
            },
            journalBosses = { [63] = 6 } })
        world:advance(12)
        local entrance = client.ns.Entrances.get("5")
        assert.are.equal(0.43, entrance.x)
        assert.are.equal("Under Moonbrook", entrance.detail)
        assert.are.equal(6, client.ns.Run.bossTotal("5"))
        local builtIn = client.ns.Entrances.get("4")
        assert.are.equal(0.46, builtIn.x)
        assert.are.equal("A cave at Lushwater Oasis", builtIn.detail)
        assert.are.equal(8, client.ns.Run.bossTotal("4"))
        client.ns.db.bossCounts = { ["4"] = 9 }
        assert.are.equal(9, client.ns.Run.bossTotal("4"))
    end)
end)

describe("sharing dungeon quests in a new group", function()
    local function party()
        local world = World.new()
        local leader = world:addClient("Tanky Mctank", { level = 20, questLog = {
            { "The Deadmines", true }, { "Red Silk Bandanas", false, 101 }, { "Oh Brother...", false, 102 },
            { "Secret Quest", false, 999 },
        } })
        local heal = world:addClient("Heally Mcheal", { level = 20, questLog = {
            { "The Deadmines", true }, { "The Defias Brotherhood", false, 103 },
        } })
        world:advance(12)
        leader.party, leader.isLeader = { "Heally Mcheal", "No Addon" }, true
        heal.party = { "Tanky Mctank", "No Addon" }
        leader.ns.GroupView.track("5")
        leader:fire("GROUP_ROSTER_UPDATE")
        heal:fire("GROUP_ROSTER_UPDATE")
        world:advance(3)
        return world, leader, heal
    end

    it("shows who has which quests for the dungeon", function()
        local _, leader = party()
        local summary = leader.ns.QuestShare.summary("5")
        assert.are.equal(3, summary.mine)
        local counts = {}
        for _, member in ipairs(summary.members) do
            counts[member.name] = member.count or "?"
        end
        assert.are.same({ ["Heally Mcheal"] = 1, ["No Addon"] = "?" }, counts)
        assert.are.same({ "The Defias Brotherhood" }, summary.theyHave)
        leader:slash("/dq")
        assert.is_not_nil(leader:findText("^3 quests$"))
        assert.is_not_nil(leader:findText("^1 quest$"))
        assert.is_not_nil(leader:findText("^no addon$"))
    end)

    it("shares from the status bar's quest icon and folds the progress out under the bar", function()
        local world, leader = party()
        assert.is_false(leader.ns.Window.isShown())
        leader:click("Button", "Share my quests")
        world:advance(5)
        assert.are.same({ 101, 102 }, leader.pushed)
        assert.is_true(leader.ns.ProgressWindow.isShown())
        assert.is_not_nil(leader:findText("^Red Silk Bandanas$"))
        leader:click("Button", "Quest progress")
        assert.is_nil(leader:findText("^Red Silk Bandanas$"))
    end)

    it("shares every shareable quest with one click, one at a time", function()
        local world, leader = party()
        leader:slash("/dq")
        leader:click("Button", "Share my quests")
        world:advance(5)
        assert.are.same({ 101, 102 }, leader.pushed)
        assert.is_true(leader:said("Sharing 2 quests for The Deadmines with your group"))
    end)
end)

describe("the group card", function()
    it("shows the spec of members without the addon by inspecting them out of combat", function()
        local world = World.new()
        local leader = world:addClient("Tanky Mctank", { level = 20 })
        world:advance(12)
        leader.party, leader.isLeader = { "Vaielia Poisonblade", "Far Mage" }, true
        leader.partyClasses = { ["Vaielia Poisonblade"] = "ROGUE", ["Far Mage"] = "MAGE" }
        leader.inspectTalents["Vaielia Poisonblade"] = { { 1000, 4 }, { 5000, 8 } }
        leader.farAway["Far Mage"] = true
        leader.inCombat = true
        leader.ns.GroupView.track("5")
        leader:fire("GROUP_ROSTER_UPDATE")
        world:advance(5)
        assert.are.same({}, leader.inspects)
        leader.inCombat = false
        world:advance(5)
        assert.are.same({ "Vaielia Poisonblade" }, leader.inspects)
        assert.is_nil(leader.inspected)
        leader:slash("/dq")
        assert.is_not_nil(leader:findText("^Combat$"))
        world:advance(30)
        assert.are.same({ "Vaielia Poisonblade" }, leader.inspects)
    end)

    it("shows where the others are once you are inside", function()
        local world = World.new()
        local leader = world:addClient("Tanky Mctank", { level = 20 })
        local member = world:addClient("Heally Mcheal", { level = 20 })
        world:advance(12)
        leader.party, leader.isLeader = { "Heally Mcheal", "No Addon" }, true
        member.party = { "Tanky Mctank", "No Addon" }
        leader.ns.GroupView.track("5")
        member.ns.GroupView.track("5")
        member.positions.player = { 1436, 0.426, 0.900 }
        leader:fire("GROUP_ROSTER_UPDATE")
        member:fire("GROUP_ROSTER_UPDATE")
        leader.inInstance, leader.instanceName = true, "The Deadmines"
        leader:fire("PLAYER_ENTERING_WORLD")
        world:advance(10)
        leader:slash("/dq")
        assert.is_not_nil(leader:findText("^inside$"))
        assert.is_not_nil(leader:findText("^%d+ yd$"))
        assert.is_not_nil(leader:findText("^no addon$"))
        assert.is_nil(leader:findText("^unknown$"))
        assert.is_not_nil(leader:findText("1 of 3 inside"))

        member.inInstance, member.instanceName = true, "The Deadmines"
        member:fire("PLAYER_ENTERING_WORLD")
        world:advance(10)
        assert.is_not_nil(leader:findText("2 of 3 inside"))
        assert.is_nil(leader:findText("^%d+ yd$"))
        assert.is_not_nil(leader:findText("^inside$"))

        leader.visible.party2 = true
        world:advance(1)
        assert.is_not_nil(leader:findText("3 of 3 inside"))
        assert.is_nil(leader:findText("^inside$"))
        leader.visible.party2 = nil
        leader.positions.player, leader.positions.party2 = { 310, 0.5, 0.5 }, { 310, 0.6, 0.4 }
        world:advance(1)
        assert.is_not_nil(leader:findText("3 of 3 inside"))
    end)

    it("has equal places, the line under the title, and the actions as buttons", function()
        local world = World.new()
        local leader = world:addClient("Tanky Mctank", { level = 20, class = "WARRIOR",
            talents = { { 9500, 5 } } })
        for _, listing in ipairs({ { "Heal", "H" }, { "Dps A", "D" }, { "Dps B", "D" }, { "Dps C", "D" } }) do
            world:list(listing[1], listing[2], 799, 20, 300)
        end
        world:advance(30)
        leader.positions.player = { 1436, 0.426, 0.700 }
        leader:slash("/dq join tank dm")
        world:advance(2)
        for _, name in ipairs({ "Heal", "Dps A", "Dps B", "Dps C" }) do
            leader:joins(name)
        end
        world:advance(2)
        leader:slash("/dq")
        assert.is_nil(leader:find("Button", "Dungeons"))
        assert.is_nil(leader:find("Button", "Quests"))
        assert.are.equal("connected", leader.ns.WindowParts.ui.card.connectionInfo.state)
        assert.are.equal("", leader.ns.WindowParts.ui.card.connection.text)
        assert.is_not_nil(leader:findText("^The Deadmines$"))
        assert.is_not_nil(leader:findText("^Group complete  ·  you lead  ·  %d of 5 at the entrance$"))
        assert.is_not_nil(leader:findText("^Protection$"))
        local heights = {}
        for _, slot in ipairs(leader.ns.WindowParts.slots) do
            heights[slot.height] = true
        end
        assert.are.equal(1, #(function()
            local list = {}
            for h in pairs(heights) do
                list[#list + 1] = h
            end
            return list
        end)())
        assert.is_true(leader:find("Button", "Waypoint to entrance").enabled)
        assert.is_false(leader:find("Button", "Share my quests").enabled)
        assert.is_false(leader:find("Button", "Quest progress").enabled)
    end)
end)
