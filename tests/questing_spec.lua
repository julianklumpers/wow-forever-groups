local World = require("tests.helpers.wowmock")

local GROUP, PVP, DUNGEON = 1, 41, 81

local function questLog()
    return {
        { "Elwynn Forest", true }, { "Hogger", false, 176, GROUP }, { "Princess Must Die!", false, 88 },
        { "Westfall", true }, { "The Big Four", false, 300, nil, 4 }, { "Battle Plans", false, 301, PVP, 5 },
        { "Into the Mines", false, 302, DUNGEON, 5 },
        { "The Deadmines", true }, { "Red Silk Bandanas", false, 101, DUNGEON }, { "Mine Boss", false, 303, GROUP },
    }
end

local function questers(world, names, roles)
    local clients = {}
    for i, name in ipairs(names) do
        clients[i] = world:addClient(name, { level = 20, questLog = questLog() })
    end
    world:advance(12)
    for i, client in ipairs(clients) do
        client:slash("/dq")
        client:click("Button", "Quests")
        client:click("CheckButton", roles and roles[i] or "DPS")
        client:click("Button", "Find questing group")
    end
    return clients
end

describe("group and elite quests", function()
    it("are the quests WoW tags Group or suggests a group for, outside dungeons", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20, questLog = questLog() })
        world:advance(12)
        local found = {}
        for _, quest in ipairs(client.ns.Quests.groupQuests()) do
            found[#found + 1] = quest.title .. " " .. quest.key .. " " .. quest.zone
        end
        assert.are.same({ "Hogger 176-3 Elwynn Forest", "The Big Four 300-4 Westfall" }, found)
    end)

    it("are listed in the Quests tab, ticked until unticked", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20, questLog = questLog() })
        world:advance(12)
        client:slash("/dq")
        assert.is_true(client:find("Button", "Dungeons").chosen)
        client:click("Button", "Quests")
        assert.is_true(client:find("Button", "Quests").chosen)
        local dungeons = client:find("Button", "Dungeons")
        assert.is_false(dungeons.chosen)
        assert.is_false(dungeons.outline[1].shown)
        dungeons.scripts.OnEnter(dungeons)
        assert.is_true(dungeons.outline[1].shown)
        dungeons.scripts.OnLeave(dungeons)
        assert.is_false(dungeons.outline[1].shown)
        assert.is_not_nil(client:findText("^Group and elite quests  ·  2 selected$"))
        assert.is_not_nil(client:findText("^Elite · group of 3$"))
        client:click("CheckButton", "The Big Four")
        assert.is_not_nil(client:findText("^Group and elite quests  ·  1 selected$"))
        assert.is_nil(client:find("CheckButton", "Red Silk Bandanas"))
        client:click("Button", "Dungeons")
        assert.is_nil(client:findText("^Group and elite quests"))
        assert.is_not_nil(client:find("CheckButton", "The Deadmines"))
    end)
end)

describe("the questing queue", function()
    it("forms a group of the quest's size and the leader invites", function()
        local world = World.new()
        local clients = questers(world, { "Aaa Player", "Bbb Player", "Ccc Player" }, { "Tank", "Healer", "DPS" })
        assert.are.equal(2, #clients[1].ns.questEngine.myEntry.dungeons)
        world:advance(15)
        for _, client in ipairs(clients) do
            assert.is_true(client:proposalShown(), client.name)
            assert.is_not_nil(client:findText("^Hogger$"), client.name)
        end
        for _, client in ipairs(clients) do
            client:acceptPopup()
        end
        world:advance(5)
        local leader
        for _, client in ipairs(clients) do
            if #client.invites > 0 then
                leader = client
            end
        end
        assert.is_not_nil(leader)
        assert.are.equal(2, #leader.invites)
        assert.is_false(leader.ns.GroupView.isTracking())
        assert.is_true(leader:said("Group formed for Hogger"))
        for _, client in ipairs(clients) do
            assert.is_nil(client.ns.questEngine.myEntry)
        end
    end)

    it("sends its own messages, which the dungeon queue ignores", function()
        local world = World.new()
        local clients = questers(world, { "Aaa Player", "Bbb Player" })
        world:advance(2)
        local quest = 0
        for _, text in ipairs(clients[1].sent) do
            if text:find("^q1|") then
                quest = quest + 1
            end
        end
        assert.is_true(quest > 0)
        assert.is_nil(clients[2].ns.engine.queue:get("Aaa Player"))
        assert.is_not_nil(clients[2].ns.questEngine.queue:get("Aaa Player"))
        clients[2].ns.Window.refresh()
        assert.is_not_nil(clients[2]:findText("^1 waiting$"))
    end)

    it("steps out while a dungeon group is proposed, and a formed group ends the other queue", function()
        local world = World.new()
        local both = world:addClient("Both Queues", { level = 20, questLog = questLog() })
        local quester = world:addClient("Quest Only", { level = 20, questLog = questLog() })
        local dungeoners = {}
        for i, p in ipairs({ { "Heal Er", "healer" }, { "Dps One", "dps" }, { "Dps Two", "dps" },
            { "Dps Three", "dps" } }) do
            dungeoners[i] = world:addClient(p[1], { level = 20 })
        end
        world:advance(12)
        both:slash("/dq")
        both:click("Button", "Quests")
        both:click("CheckButton", "Tank")
        both:click("Button", "Find questing group")
        quester:slash("/dq")
        quester:click("Button", "Quests")
        quester:click("CheckButton", "DPS")
        quester:click("CheckButton", "Hogger")
        quester:click("Button", "Find questing group")
        world:advance(2)
        assert.is_not_nil(quester.ns.questEngine.queue:get("Both Queues"))
        both:slash("/dq join tank dm")
        for i, p in ipairs({ "healer", "dps", "dps", "dps" }) do
            dungeoners[i]:slash("/dq join " .. p .. " dm")
        end
        world:advance(15)
        assert.is_true(both:proposalShown())
        assert.is_not_nil(both:findText("^The Deadmines  "))
        assert.are.equal("found", both:find("Button", "Dungeons").statusKind)
        assert.are.equal("paused", both:find("Button", "Quests").statusKind)
        assert.is_nil(quester.ns.questEngine.queue:get("Both Queues"))
        both:acceptPopup()
        for _, client in ipairs(dungeoners) do
            client:acceptPopup()
        end
        world:advance(5)
        assert.is_nil(both.ns.questEngine.myEntry)
        assert.is_true(both:said("A dungeon group formed, so you left the questing queue"))
    end)
end)

describe("questing with a party", function()
    it("lets the party leader queue the party, which leads the group", function()
        local world = World.new()
        local leader = world:addClient("Lead Player", { level = 20, questLog = questLog() })
        local solo = world:addClient("Solo Player", { level = 20, questLog = questLog() })
        world:advance(12)
        leader.party, leader.isLeader = { "Pal Player" }, true
        leader.roles["Pal Player"] = "HEALER"
        for _, client in ipairs({ leader, solo }) do
            client:slash("/dq")
            client:click("Button", "Quests")
            client:click("CheckButton", client == leader and "Tank" or "DPS")
            assert.is_nil(client:findText("^Playstyle$"))
            client:click("Button", "Find questing group")
        end
        assert.are.equal(2, #leader.ns.questEngine.myEntry.members)
        assert.are.same({ "176-3" }, leader.ns.QuestQueue.keysFor({ "304-2", "176-3" }, 2))
        world:advance(15)
        assert.is_true(leader:proposalShown())
        leader:acceptPopup()
        solo:acceptPopup()
        world:advance(5)
        assert.are.same({ "Solo Player" }, leader.invites)
    end)

    it("steps out of a proposal made for the old party when someone leaves", function()
        local world = World.new()
        local leader = world:addClient("Lead Player", { level = 20, questLog = questLog() })
        local solo = world:addClient("Solo Player", { level = 20, questLog = questLog() })
        world:advance(12)
        leader.party, leader.isLeader = { "Pal Player" }, true
        leader.roles["Pal Player"] = "HEALER"
        for _, client in ipairs({ leader, solo }) do
            client:slash("/dq")
            client:click("Button", "Quests")
            client:click("CheckButton", client == leader and "Tank" or "DPS")
            client:click("Button", "Find questing group")
        end
        world:advance(15)
        assert.is_true(leader:proposalShown())
        leader:leaves("Pal Player")
        world:advance(1)
        assert.is_false(leader:proposalShown())
        assert.are.equal(1, #leader.ns.questEngine.myEntry.members)
        world:advance(5)
        assert.are.same({}, leader.invites)
    end)

    it("leaves the questing queue when the party changes", function()
        local world = World.new()
        local leader = world:addClient("Lead Player", { level = 20, questLog = questLog() })
        world:advance(12)
        leader.party, leader.isLeader = { "Pal Player" }, true
        leader:slash("/dq")
        leader:click("Button", "Quests")
        leader:click("CheckButton", "Tank")
        leader:click("Button", "Find questing group")
        assert.is_not_nil(leader.ns.questEngine.myEntry)
        leader.party = { "Pal Player", "Stranger Player" }
        leader:fire("GROUP_ROSTER_UPDATE")
        assert.is_nil(leader.ns.questEngine.myEntry)
        assert.is_true(leader:said("Your party changed, so you left the questing queue"))
    end)
end)

describe("the questing queue after a /reload", function()
    it("keeps the place", function()
        local world = World.new()
        local client = questers(world, { "Solo Player" })[1]
        local joinedAt = client.ns.questEngine.myEntry.joinedAt
        world:advance(150)
        local saved = client:logout()
        local again = world:addClient("Solo Player", { level = 20, questLog = questLog(), saved = saved })
        world:advance(12)
        assert.are.equal(joinedAt, again.ns.questEngine.myEntry.joinedAt)
        assert.is_true(again:said("Back in the questing queue; your place was kept"))
    end)
end)

describe("a formed questing group", function()
    local function formed()
        local world = World.new()
        local clients = questers(world, { "Aaa Player", "Bbb Player", "Ccc Player" }, { "Tank", "Healer", "DPS" })
        world:advance(15)
        for _, client in ipairs(clients) do
            client:acceptPopup()
        end
        world:advance(5)
        for _, client in ipairs(clients) do
            client.party = {}
            for _, other in ipairs(clients) do
                if other ~= client then
                    client.party[#client.party + 1] = other.name
                end
            end
        end
        clients[1].isLeader = true
        return world, clients
    end

    it("shows everyone's progress in its own window", function()
        local world, clients = formed()
        local a, b = clients[1], clients[2]
        a.questLog[2][6] = { { numFulfilled = 1, numRequired = 1 } }
        a.questLog[2][7] = true
        b.questLog[2][6] = { { numFulfilled = 0, numRequired = 1 } }
        for _, client in ipairs(clients) do
            client:fire("GROUP_ROSTER_UPDATE")
            client:fire("QUEST_LOG_UPDATE")
        end
        world:advance(3)
        assert.is_true(a.ns.ProgressWindow.isShown())
        local rows = a.ns.QuestGroup.rows()
        assert.are.equal("Hogger", rows[1].title)
        local lines = {}
        for _, line in ipairs(rows[1].lines) do
            lines[line.name] = line.text
        end
        assert.are.same({ You = "ready to turn in", ["Bbb Player"] = "0/1", ["Ccc Player"] = "started" }, lines)
        assert.is_not_nil(a:findText("^ready to turn in$"))
        assert.is_not_nil(a:findText("^Questing group: Hogger"))
        assert.is_nil(a:find("Button", "Dungeons"))

        assert.is_not_nil(a:findText("^Questing: Hogger"))
        a:click("Button", "Quest progress")
        assert.is_false(a.ns.ProgressWindow.isShown())
        assert.is_nil(a:findText("^ready to turn in$"))
        assert.is_false(a.ns.db.progressExpanded)
        a:click("Button", "Quest progress")
        assert.is_not_nil(a:findText("^ready to turn in$"))
        a:click("Button", "Quest progress »")
        assert.is_false(a.ns.ProgressWindow.isShown())
        a:click("Button", "Quest progress »")
        assert.is_true(a.ns.ProgressWindow.isShown())
    end)

    it("does not ask when a shared quest is abandoned", function()
        local world, clients = formed()
        local a = clients[1]
        a:fire("QUEST_LOG_UPDATE")
        world:advance(1)
        table.remove(a.questLog, 2)
        a:fire("QUEST_LOG_UPDATE")
        world:advance(1)
        assert.are.equal(0, #a.popups)
    end)

    it("asks to leave the group once the shared quests are turned in", function()
        local world, clients = formed()
        local a = clients[1]
        a:fire("QUEST_LOG_UPDATE")
        world:advance(1)
        table.remove(a.questLog, 2)
        a.completedQuests = { [176] = true }
        a:fire("QUEST_LOG_UPDATE")
        world:advance(1)
        assert.are.equal("DUNGEONQUEUE_QUESTS_DONE", a.popups[#a.popups])
        local asked = #a.popups
        a:fire("QUEST_LOG_UPDATE")
        assert.are.equal(asked, #a.popups)
        assert.are.equal("Your shared quests are done. Leave the group?",
            a.env.StaticPopupDialogs.DUNGEONQUEUE_QUESTS_DONE.text)
        a:acceptStaticPopup()
        assert.is_true(a.leftParty)
        assert.is_false(a.ns.ProgressWindow.isShown())
    end)

    it("asks once the group's own quest is done, though members share other quests too", function()
        local world, clients = formed()
        for _, client in ipairs(clients) do
            client:fire("GROUP_ROSTER_UPDATE")
            client:fire("QUEST_LOG_UPDATE")
        end
        world:advance(3)
        local a = clients[1]
        assert.is_true(#a.ns.QuestGroup.current().quests > 1)
        a.ns.Window.show()
        assert.is_true(a.ns.Window.isShown())
        assert.is_nil(a:find("Button", "Dungeons"))
        table.remove(a.questLog, 2)
        a.completedQuests = { [176] = true }
        a:fire("QUEST_LOG_UPDATE")
        world:advance(1)
        assert.are.equal("DUNGEONQUEUE_QUESTS_DONE", a.popups[#a.popups])
        assert.is_not_nil(a:find("Button", "Dungeons"))
    end)
end)

describe("quest progress in a dungeon group", function()
    it("shows the dungeon quests of everyone with the addon, without asking to leave", function()
        local world = World.new()
        local leader = world:addClient("Tanky Mctank", { level = 20, questLog = {
            { "The Deadmines", true },
            { "Red Silk Bandanas", false, 101, nil, nil, { { numFulfilled = 4, numRequired = 10 } } },
            { "Oh Brother...", false, 102 },
        } })
        local heal = world:addClient("Heally Mcheal", { level = 20, questLog = {
            { "The Deadmines", true },
            { "Red Silk Bandanas", false, 101, nil, nil, { { numFulfilled = 10, numRequired = 10 } }, true },
        } })
        world:advance(12)
        leader.party, leader.isLeader = { "Heally Mcheal", "No Addon" }, true
        heal.party = { "Tanky Mctank", "No Addon" }
        leader.ns.GroupView.track("5")
        heal.ns.GroupView.track("5")
        leader:fire("GROUP_ROSTER_UPDATE")
        heal:fire("GROUP_ROSTER_UPDATE")
        world:advance(3)
        assert.is_true(leader.ns.ProgressWindow.isShown())
        local rows = {}
        local list, without = leader.ns.QuestGroup.rows()
        assert.are.same({ "No Addon" }, without)
        for _, row in ipairs(list) do
            local lines = {}
            for _, line in ipairs(row.lines) do
                lines[line.name] = line.text
            end
            rows[row.title] = lines
        end
        assert.are.same({
            ["Red Silk Bandanas"] = { You = "4/10", ["Heally Mcheal"] = "ready to turn in" },
            ["Oh Brother..."] = { You = "started", ["Heally Mcheal"] = "-" },
        }, rows)
        assert.is_not_nil(leader:findText("^Without Forever Groups: No Addon$"))
        leader:slash("/dq")
        assert.is_nil(leader:findText("^Questing group:"))
        leader:fire("QUEST_LOG_UPDATE")
        table.remove(leader.questLog, 3)
        table.remove(leader.questLog, 2)
        leader:fire("QUEST_LOG_UPDATE")
        world:advance(1)
        assert.are.equal(0, #leader.popups)
    end)
end)

describe("the questing queue and WoW's Group Finder", function()
    local ELWYNN, WESTFALL = 9001, 9002

    local function queued(world)
        local client = world:addClient("Solo Quester", { level = 20, questLog = {
            { "Elwynn Forest", true }, { "Hogger", false, 176, GROUP },
            { "Westfall", true }, { "The Big Four", false, 300, nil, 4 },
        } })
        world:advance(30)
        client:slash("/dq")
        client:click("Button", "Quests")
        client:click("CheckButton", "DPS")
        client:click("Button", "Find questing group")
        world:advance(1)
        return client
    end

    local function whispered(client, pattern)
        local names = {}
        for _, w in ipairs(client.whispers) do
            if w.text:find(pattern) then
                names[#names + 1] = w.target
            end
        end
        table.sort(names)
        return names
    end

    it("invites players listed in the quest's zone, with a whisper that says what for", function()
        local world = World.new()
        world:list("Zone Tank", "T", ELWYNN, 20, 300)
        world:list("Zone Dps", "D", ELWYNN, 20, 200)
        world:list("Late Dps", "D", ELWYNN, 20, 100)
        world:list("Other Zone", "D", WESTFALL, 20, 400)
        world:list("Dungeon Dps", "D", 799, 20, 500)
        local client = queued(world)
        assert.are.same({ "Zone Dps", "Zone Tank" }, whispered(client,
            "^%[Forever Groups%] Inviting you for Hogger %(Elwynn Forest, group of 3%)%. I can share the quest%.$"))
        local invites = { unpack(client.invites) }
        table.sort(invites)
        assert.are.same({ "Zone Dps", "Zone Tank" }, invites)
        assert.are.same({ "176-3" }, client.ns.questEngine.myEntry.dungeons)
        assert.are.equal("TD", client.ns.questEngine.myEntry.reserved)

        client.party, client.isLeader = { "Zone Tank" }, true
        client:fire("GROUP_ROSTER_UPDATE")
        assert.are.equal(2, #client.ns.questEngine.myEntry.members)
        assert.are.equal("D", client.ns.questEngine.myEntry.reserved)
        client.party = { "Zone Tank", "Zone Dps" }
        client:fire("GROUP_ROSTER_UPDATE")
        assert.is_nil(client.ns.questEngine.myEntry)
        assert.is_true(client:said("Your group for Hogger is complete"))
        assert.is_true(client.ns.ProgressWindow.isShown())
    end)

    it("asks the leader of a group in the zone when nobody is listed alone", function()
        local world = World.new()
        world:listGroup("Full Lead", ELWYNN, { T = 0, H = 0, D = 2 }, 300)
        world:listGroup("Group Lead", ELWYNN, { T = 0, H = 1, D = 2 }, 200)
        local client = queued(world)
        assert.are.same({ "Group Lead" }, whispered(client, "could you invite me for Hogger%?$"))
        assert.are.same({}, client.invites)
    end)

    it("invites players who whisper about the listed group, while their role is still open", function()
        local world = World.new()
        local client = queued(world)
        client:whisperFrom("Early Heal", "heal?")
        assert.are.same({}, client.invites)
        world:advance(2)
        client:press("W")
        assert.is_true(client.listed)
        client:whisperFrom("Whisper Tank", "tank lf group")
        assert.are.same({ "Whisper Tank" }, client.invites)
        assert.are.same({ "Whisper Tank" }, whispered(client, "^%[Forever Groups%] Inviting you for Hogger"))
        assert.are.equal("T", client.ns.questEngine.myEntry.reserved)
        client:whisperFrom("Second Tank", "tank")
        assert.are.same({ "Second Tank" }, whispered(client, "Sorry, we only need Healer, DPS"))
        client:whisperFrom("Some One", "can I join?")
        assert.are.same({ "Some One" }, whispered(client, "Which role do you play"))
        client:whisperFrom("Some One", "heal")
        assert.are.same({ "Whisper Tank", "Some One" }, client.invites)
        client:whisperFrom("Late Dps", "dps")
        assert.are.same({ "Whisper Tank", "Some One" }, client.invites)
    end)

    it("lists the group in its zone on the next key press, unlisted when it leaves", function()
        local world = World.new()
        local client = queued(world)
        world:advance(2)
        client:press("W")
        assert.is_true(client.listed)
        assert.are.same({ ELWYNN }, client.listingArgs[1].activityIDs)
        assert.is_true(client:said("listed in WoW's Group Finder for Hogger %(Elwynn Forest%)"))
        client:click("Button", "Stop")
        world:advance(2)
        client:press("W")
        assert.is_false(client.listed)
    end)

    it("keeps the dungeon results when it searches the zones", function()
        local world = World.new()
        world:list("Dungeon Dps", "D", 799, 20, 500)
        world:list("Zone Tank", "T", ELWYNN, 20, 300)
        local client = world:addClient("Solo Quester", { level = 20, questLog = {
            { "Elwynn Forest", true }, { "Hogger", false, 176, GROUP },
        } })
        world:advance(30)
        client:slash("/dq")
        world:advance(1)
        assert.are.equal(1, #client.ns.LfgList.listings())
        client:click("Button", "Quests")
        client:click("CheckButton", "DPS")
        client:click("Button", "Find questing group")
        world:advance(1)
        assert.are.equal(1, #client.ns.LfgList.zoneListings())
        assert.are.equal("Dungeon Dps", client.ns.LfgList.listings()[1].name)
    end)
end)

describe("the window's status card", function()
    it("shows the status of the chosen tab, under the connection line and the tabs", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20, questLog = questLog() })
        world:advance(12)
        client:slash("/dq")
        assert.is_not_nil(client:findText("^Not in the queue$"))
        assert.is_not_nil(client:findText("^Looking now:"))
        client:click("Button", "Quests")
        assert.is_not_nil(client:findText("^Not looking for a questing group$"))
        assert.is_nil(client:findText("^Looking now:"))
        client:click("CheckButton", "DPS")
        assert.is_nil(client:find("Button", "Quests").statusKind)
        client:click("Button", "Find questing group")
        assert.is_not_nil(client:findText("^Looking for a questing group 0:00 as DPS$"))
        world:advance(65)
        assert.are.equal("queued", client:find("Button", "Quests").statusKind)
        assert.is_not_nil(client:findText("^1:05$"))
        assert.is_nil(client:find("Button", "Dungeons").statusKind)
        client:click("Button", "Dungeons")
        assert.is_not_nil(client:findText("^Not in the queue$"))
        assert.is_nil(client:findText("^Looking for a questing group 0:00 as DPS$"))
        assert.is_not_nil(client:findText("^Connected$"))
    end)
end)

describe("two proposals that cross", function()
    it("leave the first one standing: the other queue has stepped out and answers a conflict", function()
        local world = World.new()
        local client = world:addClient("Both Queues", { level = 20, questLog = questLog() })
        world:advance(12)
        client:slash("/dq join dps dm")
        client.ns.QuestQueue.join({ "176-3" }, { { name = "Both Queues", roles = "D", level = 20 } })
        world:advance(1)
        client.ns.questEngine:addProposal("Quest Leader", {
            seq = 1, dungeon = "176-3", entries = { { { name = "Quest Leader", role = "T" } },
                { { name = "Both Queues", role = "D" } } }, missing = "", playstyles = {},
        })
        assert.is_true(client:proposalShown())
        client.ns.engine:addProposal("Dungeon Leader", {
            seq = 2, dungeon = "5", entries = { { { name = "Dungeon Leader", role = "T" } },
                { { name = "Both Queues", role = "D" } } }, missing = "HDD", playstyles = {},
        })
        assert.is_true(client:proposalShown())
        assert.is_not_nil(client:findText("^Hogger$"))
        local dungeon = client.ns.engine.proposals["Dungeon Leader#2"]
        assert.are.equal("C", dungeon.answers["Both Queues"])
    end)
end)
