local World = require("tests.helpers.wowmock")

local CONNECT = 30

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, item in pairs(value) do
        result[key] = copy(item)
    end
    return result
end

local function withoutLog(db)
    local result = copy(db)
    result.log = nil
    return result
end

local function connected(name, opts)
    local world = World.new()
    local client = world:addClient(name or "Real Person", opts or { level = 20, class = "MAGE" })
    world:advance(CONNECT)
    return world, client
end

-- What the client sent anywhere: addon messages, chat, invites, searches.
local function outgoing(client)
    return { sent = #client.sent, whispers = #client.whispers, invites = #client.invites,
        searches = client.searches, blocked = client.blockedSearches, pushed = #client.pushed,
        roles = copy(client.groupFinderRoles) }
end

local function screenLabel(client)
    local label = client:findText("^%d/8  ·  ")
    return label and label.text
end

-- Next until the bar shows another screen (or the demo ended).
local function nextScreen(client)
    local before = screenLabel(client)
    for _ = 1, 10 do
        client:click("Button", "Next")
        if screenLabel(client) ~= before then
            return
        end
    end
end

local function startDemo(client)
    client:slash("/fg demo")
    client:click("Button", "Show me around")
end

local function anyTextWith(client, plain)
    for _, widget in ipairs(client.widgets) do
        local visible, w = true, widget
        while visible and w do
            visible = w.shown
            w = w.parent
        end
        if visible and widget.kind == "FontString" and type(widget.text) == "string"
            and widget.text:find(plain, 1, true) then
            return widget.text
        end
    end
    return nil
end

describe("/fg demo", function()
    it("walks through every screen with example data", function()
        local world, client = connected()
        local ns = client.ns
        client:slash("/fg demo")
        assert.is_true(ns.Demo.isOn())
        assert.are.equal("Aldric Dawnmere", ns.selfName)
        assert.are.equal("PALADIN", ns.Party.playerClass())
        assert.are.equal(20, ns.Party.playerLevel())
        assert.is_not_nil(client:findText("^Welcome to Forever Groups$"))
        assert.is_not_nil(client:findText("^Pick your roles, press Find group"))
        assert.is_nil(client:find("Button", "Previous"))
        client:click("Button", "Show me around")

        assert.is_not_nil(client:findText("^1/8  ·  Choosing a dungeon$"))
        assert.is_not_nil(client:findText("^Step 1 of 7$"))
        assert.is_not_nil(client:findText("^Example$"))
        assert.is_not_nil(client:findText("^Tick every role you can play%."))
        client:click("Button", "Next")
        assert.is_not_nil(client:findText("^Step 2 of 7$"))
        assert.is_not_nil(client:findText("^Join a group, or lead one"))
        client:click("Button", "Previous")
        client:click("Button", "Previous")
        assert.is_not_nil(client:findText("^Welcome to Forever Groups$"))
        client:click("Button", "Show me around")
        assert.is_not_nil(client:findText("^Step 1 of 7$"))
        assert.is_not_nil(client:findText("^Dungeons for level 20$"))
        assert.is_true(ns.WindowParts.ui.headerLooking.shown)
        assert.is_true(client:frame("ForeverGroupsQueueFrame").shown)
        assert.is_not_nil(client:findText("^Perrin Quickbrook %+2$"))
        assert.is_not_nil(client:findText("^Haldor Stormbanner$"))
        assert.is_not_nil(client:findText("^Liora Thornwick %+1$"))

        nextScreen(client)
        assert.is_not_nil(client:findText("^2/8  ·  Leading your party$"))
        assert.is_not_nil(client:findText("^Your party: 2/5$"))
        assert.is_true(client:find("CheckButton", "Choose the classes in my party").checked)
        assert.is_true(client:find("CheckButton", "Limit levels").checked)
        assert.are.equal("Brynna Coldbrook", ns.WindowParts.composeCards[2].lines[1].text)
        assert.are.equal("Mage", ns.WindowParts.composeCards[3].lines[1].text)
        assert.are.equal("18", ns.WindowParts.ui.levelsMin.text)
        assert.are.equal("24", ns.WindowParts.ui.levelsMax.text)

        nextScreen(client)
        assert.is_not_nil(client:findText("^3/8  ·  Waiting in the queue$"))
        assert.is_not_nil(client:findText("^In queue 4:2%d as Tank$"))
        assert.is_not_nil(client:findText("^Searching 3 dungeons"))
        assert.are.equal("dungeons", ns.WindowParts.fixedTab())

        nextScreen(client)
        assert.is_not_nil(client:findText("^4/8  ·  Group found$"))
        assert.is_not_nil(client:findText("^Who was found: everyone's role and spec"))
        assert.is_true(client:proposalShown())
        assert.is_not_nil(client:findText("^Aldric Dawnmere %(you%)$"))
        assert.is_not_nil(client:findText("^Restoration Shaman$"))
        assert.is_not_nil(client:findText("^3/5 accepted$"))
        assert.is_not_nil(client:findText("^Group found! %d+ s to accept$"))
        client:acceptPopup()
        assert.is_true(client:proposalShown())
        assert.is_not_nil(client:findText("^Accepted%. Waiting for the others%.%.%.$"))
        assert.is_not_nil(client:findText("^4/5 accepted$"))

        nextScreen(client)
        assert.is_false(client:proposalShown())
        assert.is_not_nil(client:findText("^5/8  ·  In your group$"))
        assert.is_not_nil(client:findText("^Group complete  ·  Relaxed  ·  3 of 5 at the entrance$"))
        assert.is_not_nil(client:findText("^The Deadmines  ·  group complete$"))
        assert.is_not_nil(client:findText("^120 yd$"))
        assert.is_not_nil(client:findText("^no addon$"))
        assert.is_true(client:find("Button", "Share my quests").enabled)
        assert.is_true(client:find("Button", "Quest progress").enabled)

        nextScreen(client)
        assert.is_not_nil(client:findText("^6/8  ·  Group quests$"))
        assert.is_not_nil(client:findText("^Group and elite quests  ·  4 selected$"))
        assert.is_not_nil(client:findText("^Wanted: Gath'Ilzogg$"))
        assert.is_true(client:frame("ForeverGroupsQueueFrame").shown)
        assert.is_not_nil(client:findText("^Kaelis Hollowmere %+1$"))
        assert.is_not_nil(client:findText("^Redridge Mountains$"))

        nextScreen(client)
        assert.is_not_nil(client:findText("^7/8  ·  Questing group$"))
        assert.is_not_nil(client:findText("^Questing group: Wanted: Gath'Ilzogg, Wanted: Lieutenant Fangore$"))
        assert.is_not_nil(client:findText("^Questing: Wanted: Gath'Ilzogg"))
        assert.is_not_nil(client:findText("^Elowen Frostmantle$"))
        assert.is_not_nil(client:findText("^ready to turn in$"))

        nextScreen(client)
        assert.is_not_nil(client:findText("^8/8  ·  Battlegrounds$"))
        assert.is_not_nil(client:findText("^Battlegrounds for level 20  ·  2 selected$"))
        assert.is_not_nil(client:findText("^Zephyra Duskwhisper %+2$"))
        client:click("Button", "Next")
        client:click("Button", "Next")
        assert.is_not_nil(client:findText("^That's all"))
        assert.is_false(client:find("Button", "Next").enabled)
        assert.is_not_nil(client:find("Button", "Done"))

        for _ = 1, 3 do
            client:click("Button", "Previous")
        end
        assert.is_not_nil(client:findText("^7/8  ·  Questing group$"))
        world:advance(5)
        assert.is_not_nil(client:findText("^7/8  ·  Questing group$"))
        assert.is_nil(client:findText("Fake"))
        assert.is_nil(client:findText("Sample"))
        assert.is_nil(client:findText("fake"))
    end)

    it("never shows the real character's name, and sends nothing", function()
        local world, client = connected("Real Person", { level = 37, class = "MAGE" })
        client:slash("/fg")
        local before = outgoing(client)
        startDemo(client)
        for scene = 1, 8 do
            assert.is_nil(anyTextWith(client, "Real Person"), "scene " .. scene)
            if scene == 1 then
                client:click("CheckButton", "Healer")
                client:click("CheckButton", "Shadowfang Keep")
                client:click("Button", "Refresh")
                client:click("Button", "Find group")
            elseif scene == 4 then
                client:acceptPopup()
                client:slash("/fg decline")
                assert.is_false(client:proposalShown())
            elseif scene == 5 then
                client:click("Button", "Share my quests")
            elseif scene == 6 then
                client:click("Button", "Find questing group")
            elseif scene == 8 then
                client:click("Button", "Find group")
            end
            world:advance(3)
            if scene < 8 then
                nextScreen(client)
            end
        end
        world:advance(30)
        assert.are.same(before, outgoing(client))
        assert.is_nil(client.ns.engine.myEntry)
    end)

    it("leaves the addon as it was once it ends", function()
        local _, client = connected()
        local ns = client.ns
        local engine, questEngine, bgEngine = ns.engine, ns.questEngine, ns.bgEngine
        local db, charDb = withoutLog(client.env.ForeverGroupsDB), copy(client.env.ForeverGroupsCharDB)
        startDemo(client)
        for _ = 1, 7 do
            nextScreen(client)
        end
        client:click("Button", "End the demo")
        assert.is_false(ns.Demo.isOn())
        assert.is_true(rawequal(ns.charDb, client.env.ForeverGroupsCharDB))
        assert.is_true(rawequal(ns.db, client.env.ForeverGroupsDB))
        assert.are.same(db, withoutLog(client.env.ForeverGroupsDB))
        assert.are.same(charDb, client.env.ForeverGroupsCharDB)
        assert.are.equal("Real Person", ns.selfName)
        assert.are.equal("solo", ns.Party.state())
        assert.are.equal("MAGE", ns.Party.playerClass())
        assert.is_true(rawequal(engine, ns.engine))
        assert.is_true(rawequal(questEngine, ns.questEngine))
        assert.is_true(rawequal(bgEngine, ns.bgEngine))
        assert.are.equal("Real Person", engine.name)
        assert.is_nil(ns.QuestGroup.current())
        assert.is_false(ns.GroupView.isTracking())
        assert.is_false(client:proposalShown())
        assert.is_false(client:frame("ForeverGroupsFrame").shown)
        assert.is_nil(anyTextWith(client, "Aldric Dawnmere"))
        assert.is_true(client:said("Demo ended%."))
        client:slash("/dq join dps dm")
        assert.is_not_nil(ns.engine.myEntry)
        assert.are.equal("Real Person", ns.engine.myEntry.id)
    end)

    it("catches up with the queue after it ends", function()
        local world, client = connected()
        local other = world:addClient("Other Tank", { level = 20 })
        world:advance(CONNECT)
        local engine = client.ns.engine
        client:slash("/fg demo")
        other:slash("/dq join tank dm")
        world:advance(10)
        assert.is_nil(engine.queue:get("Other Tank"))
        client:slash("/fg demo")
        assert.is_nil(engine.queue:get("Other Tank"))
        assert.is_not_nil(client.sent[#client.sent]:find("^v%d+|S|"))
        world:advance(6)
        assert.is_not_nil(engine.queue:get("Other Tank"))
    end)

    it("only starts while nothing else is going on", function()
        local _, client = connected()
        client:slash("/dq join dps dm")
        client:slash("/fg demo")
        assert.is_false(client.ns.Demo.isOn())
        assert.is_true(client:said("The demo only starts while nothing else is going on"))
        assert.are.equal("Real Person", client.ns.selfName)

        local _, fighting = connected()
        fighting.inCombat = true
        fighting:slash("/fg demo")
        assert.is_false(fighting.ns.Demo.isOn())

        local _, member = connected()
        member:joinGroupOf("Some Leader")
        member:slash("/fg demo")
        assert.is_false(member.ns.Demo.isOn())
    end)

    it("ends on a fight, a loading screen or logging out", function()
        for _, event in ipairs({ "PLAYER_REGEN_DISABLED", "PLAYER_ENTERING_WORLD" }) do
            local _, client = connected()
            client:slash("/fg demo")
            client:fire(event)
            assert.is_false(client.ns.Demo.isOn(), event)
            assert.is_true(rawequal(client.ns.charDb, client.env.ForeverGroupsCharDB), event)
            assert.are.equal("Real Person", client.ns.selfName, event)
        end
        local _, client = connected()
        local before = copy(client.env.ForeverGroupsCharDB)
        client:slash("/fg demo")
        local saved = client:logout()
        assert.is_false(client.ns.Demo.isOn())
        assert.is_true(rawequal(saved.charDb, client.ns.charDb))
        assert.are.same(before, saved.charDb)
    end)

    it("ends with Done on the last step, or Skip at the welcome", function()
        local _, client = connected()
        startDemo(client)
        for _ = 1, 7 do
            nextScreen(client)
        end
        for _ = 1, 2 do
            client:click("Button", "Next")
        end
        client:click("Button", "Done")
        assert.is_false(client.ns.Demo.isOn())
        assert.are.equal("Real Person", client.ns.selfName)

        client:slash("/fg demo")
        client:click("Button", "Skip")
        assert.is_false(client.ns.Demo.isOn())
    end)

    it("ends cleanly when a screen fails", function()
        local _, client = connected()
        startDemo(client)
        client.ns.Popup.show = function()
            error("broken popup")
        end
        for _ = 1, 3 do
            nextScreen(client)
        end
        assert.is_false(client.ns.Demo.isOn())
        assert.is_true(client:said("The demo stopped after an error"))
        assert.are.equal("Real Person", client.ns.selfName)
        assert.is_true(rawequal(client.ns.charDb, client.env.ForeverGroupsCharDB))
        assert.are.equal("MAGE", client.ns.Party.playerClass())
    end)
end)

describe("the demo for a new player", function()
    local function fresh(opts)
        local world = World.new()
        opts = opts or {}
        opts.level, opts.fresh = 20, true
        return world, world:addClient("New Player", opts)
    end

    it("opens by itself the first time, once, and is marked seen right away", function()
        local world, client = fresh()
        world:advance(CONNECT)
        assert.is_true(client.ns.Window.isShown())
        assert.is_true(client.ns.Demo.isOn())
        assert.is_true(client.env.ForeverGroupsDB.tourSeen)
        assert.is_false(client:said("Not connected yet"))
        client:click("Button", "End the demo")
        client:slash("/fg")
        client:slash("/fg")
        world:advance(1)
        assert.is_false(client.ns.Demo.isOn())
        local saved = client:logout()
        local again = world:addClient("New Player", { level = 20, saved = saved })
        world:advance(CONNECT)
        assert.is_false(again.ns.Window.isShown())
        again:slash("/fg")
        world:advance(1)
        assert.is_false(again.ns.Demo.isOn())
    end)

    it("is not shown to a player who used Forever Groups before", function()
        local world = World.new()
        local client = world:addClient("Old Hand", { level = 20 })
        world:advance(CONNECT)
        assert.is_false(client.ns.Window.isShown())
        client:slash("/fg")
        world:advance(1)
        assert.is_false(client.ns.Demo.isOn())
    end)

    it("waits for a later opening while something is going on, without a word", function()
        local world, client = fresh()
        client.party, client.isLeader = { "Some Leader" }, false
        client:fire("GROUP_ROSTER_UPDATE")
        world:advance(CONNECT)
        assert.is_true(client.ns.Window.isShown())
        assert.is_false(client.ns.Demo.isOn())
        assert.is_false(client.ns.db.tourSeen)
        assert.is_false(client:said("The demo only starts"))
        assert.is_false(client:said("Not connected yet"))
        client.party = {}
        client:fire("GROUP_ROSTER_UPDATE")
        client:slash("/fg")
        client:slash("/fg")
        world:advance(1)
        assert.is_true(client.ns.Demo.isOn())
    end)

    it("opens the window after a fight at the first login", function()
        local world, client = fresh({ inCombat = true })
        world:advance(CONNECT)
        assert.is_false(client.ns.Window.isShown())
        assert.is_false(client.ns.Demo.isOn())
        client.inCombat = false
        client:fire("PLAYER_REGEN_ENABLED")
        world:advance(1)
        assert.is_true(client.ns.Window.isShown())
        assert.is_true(client.ns.Demo.isOn())
    end)

    it("starts from the settings", function()
        local world = World.new()
        local client = world:addClient("Old Hand", { level = 20 })
        world:advance(CONNECT)
        client:slash("/fg settings")
        client:click("Button", "Display")
        client:click("Button", "Show the demo")
        assert.is_true(client.ns.Demo.isOn())
    end)
end)
