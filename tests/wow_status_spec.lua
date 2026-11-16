local World = require("tests.helpers.wowmock")

local CONNECT = 8
local MATCH = 20

local function statusText(client)
    local bar = client:frame("ForeverGroupsStatusFrame")
    if not bar or not bar.shown then
        return nil
    end
    for _, widget in ipairs(client.widgets) do
        if widget.kind == "FontString" and widget.parent == bar then
            return widget.text
        end
    end
end

local PLAYERS = {
    { "Tanky Mctank", "tank" }, { "Heally Mcheal", "healer" }, { "Dps One", "dps" }, { "Dps Two", "dps" },
    { "Dps Three", "dps" },
}

-- Opens every table of Who is looking (by default only the half that fits
-- what the player does is open).
local function unfold(client)
    client.ns.db.queueFold = { players = false, groups = false }
end

describe("Status bar", function()
    it("is hidden while nothing happens and shows the queue time when queued", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(CONNECT)
        assert.is_nil(statusText(client))
        client.ns.db.noListing = true
        client:slash("/dq join tank,dps auto")
        world:advance(65)
        assert.truthy(statusText(client):find("^In queue 1:0%d as Tank/DPS$"))
        client.ns.db.debug = true
        client.ns.Status.refresh()
        assert.truthy(statusText(client):find(
            "^In queue 1:0%d as Tank/DPS  %-  Building your own group: looking for"))
        client.ns.db.debug = false
        assert.is_nil(statusText(client):find("click to search", 1, true))
        local bar = client:frame("ForeverGroupsStatusFrame")
        local searches = client.searches
        client.inClick, client.clickSearched = true, false
        bar.scripts.OnClick(bar)
        assert.are.equal(searches + 1, client.searches)
        assert.is_false(client:frame("ForeverGroupsFrame") ~= nil and client:frame("ForeverGroupsFrame").shown)
        client.clickSearched = false
        bar.scripts.OnClick(bar)
        client.inClick = false
        assert.is_true(client:frame("ForeverGroupsFrame").shown)
        assert.is_not_nil(client:findText("In queue 1:0%d as Tank/DPS"))
        assert.is_not_nil(client:findText("^You lead this group and are in the queue"))
        client:slash("/dq leave")
        world:advance(1)
        assert.is_nil(statusText(client))
    end)

    it("follows a group from proposal to complete, for the leader and a member", function()
        local world = World.new()
        local clients = {}
        for i, p in ipairs(PLAYERS) do
            clients[i] = world:addClient(p[1], { level = 20 })
            clients[i].ns.db.noAutoAccept = true
        end
        world:advance(CONNECT)
        for i, p in ipairs(PLAYERS) do
            clients[i]:slash("/dq join " .. p[2] .. " dm")
        end
        world:advance(MATCH)
        local tank, heal = clients[1], clients[2]
        assert.truthy(statusText(tank):find("^Group found! %d+ s to accept"))
        assert.truthy(statusText(heal):find("^Group found! %d+ s to accept"))
        tank:acceptPopup()
        world:advance(1)
        assert.truthy(statusText(tank):find("^Accepted, waiting for the others"))
        for i = 2, 5 do
            clients[i]:acceptPopup()
        end
        world:advance(3)
        assert.are.equal("Inviting your group: 0 of 4 joined", statusText(tank))
        assert.truthy(statusText(heal):find("^Accept the invite from Tanky Mctank"))

        heal.party = { "Tanky Mctank" }
        heal:fire("GROUP_ROSTER_UPDATE")
        world:advance(1)
        assert.are.equal("The Deadmines  ·  2/5  ·  open: DPS, DPS, DPS", statusText(heal))
        assert.are.equal(0.4, heal.ns.Status.progress())
        for i = 2, 4 do
            tank:joins(clients[i].name)
        end
        world:advance(1)
        assert.are.equal("Inviting your group: 3 of 4 joined", statusText(tank))
        assert.are.equal(0.75, tank.ns.Status.progress())
        assert.are.same({}, tank.notices)
        tank:joins(clients[5].name)
        world:advance(1)
        assert.are.equal("The Deadmines  ·  group complete", statusText(tank))
        assert.are.same({ "Group complete! The Deadmines" }, tank.notices)
        local partyMessages = 0
        for _, w in ipairs(tank.whispers) do
            if w.chatType == "PARTY" then
                partyMessages = partyMessages + 1
                assert.truthy(w.text:find("Group complete for The Deadmines", 1, true))
            end
        end
        assert.are.equal(1, partyMessages)
        world:advance(30)
        assert.are.equal("The Deadmines  ·  group complete", statusText(tank))
        tank.inInstance, tank.instanceName = true, "The Deadmines"
        tank:fire("PLAYER_ENTERING_WORLD")
        world:advance(1)
        assert.are.equal("The Deadmines  ·  0/8 bosses", statusText(tank))
        tank:fire("ENCOUNTER_END", 1, "Rhahk'Zor", 1, 5, 1)
        tank:fire("GROUP_ROSTER_UPDATE")
        world:advance(1)
        assert.are.equal("The Deadmines  ·  1/8 bosses", statusText(tank))
        assert.are.equal(1 / 8, tank.ns.Status.progress())
    end)
end)

describe("Party status for members", function()
    local function party()
        local world = World.new()
        local leader = world:addClient("Tanky Mctank", { level = 20 })
        local member = world:addClient("Friend Person", { level = 20 })
        leader.party, leader.isLeader = { "Friend Person" }, true
        member.party = { "Tanky Mctank" }
        world:advance(CONNECT)
        leader:slash("/dq")
        leader:click("CheckButton", "Tank")
        leader.roles["Friend Person"] = "DAMAGER"
        leader:click("Button", "Find group")
        world:advance(2)
        return world, leader, member
    end

    it("shows members that their leader queued the party, with their own role", function()
        local world, leader, member = party()
        assert.truthy(statusText(member):find("^Your party is queued by Tanky Mctank %(0:0%d%)  %-  You: DPS$"))
        assert.truthy(statusText(leader):find("^In queue 0:0%d as Tank %(party of 2%)$"))
        leader.ns.Window.show()
        leader.ns.Window.refresh()
        assert.is_not_nil(leader:findText("^You lead this group and are in the queue"))
        member:slash("/dq")
        assert.is_not_nil(member:findText("^Tanky Mctank leads your party and searches"))
        leader:slash("/dq leave")
        world:advance(1)
        assert.is_nil(statusText(member))
    end)

    it("stops showing the queue once its leader no longer leads the party", function()
        local _, leader, member = party()
        assert.truthy(statusText(member):find("^Your party is queued by Tanky Mctank"))
        leader.party, leader.isLeader = {}, false
        member.party = { "No Addon Lead" }
        member:fire("GROUP_ROSTER_UPDATE")
        assert.is_nil(statusText(member))
    end)

    it("tells members when the leader gets a proposal", function()
        local world, _, member = party()
        local others = {}
        for i, p in ipairs({ { "Heally Mcheal", "healer" }, { "Dps One", "dps" }, { "Dps Two", "dps" } }) do
            others[i] = world:addClient(p[1], { level = 20 })
            others[i].role = p[2]
        end
        world:advance(CONNECT)
        for _, client in ipairs(others) do
            client:slash("/dq join " .. client.role .. " auto")
        end
        world:advance(MATCH)
        assert.truthy(statusText(member):find("^Tanky Mctank is answering a group proposal"))
    end)

    it("catches up after a member reloads", function()
        local world, _, member = party()
        local saved = member:logout()
        local again = world:addClient("Friend Person", { level = 20, saved = saved })
        again.party = { "Tanky Mctank" }
        world:advance(CONNECT)
        assert.truthy(statusText(again):find("^Your party is queued by Tanky Mctank"))
    end)
end)

describe("Complete parties", function()
    it("keeps showing a tracked group after a /reload, without announcing it again", function()
        local world = World.new()
        local leader = world:addClient("Tanky Mctank", { level = 20 })
        for i, name in ipairs({ "Heal", "Dps A", "Dps B", "Dps C" }) do
            world:list(name, i == 1 and "H" or "D", 799, 20, 100 + i)
        end
        world:advance(CONNECT)
        leader:slash("/dq")
        leader:click("CheckButton", "Tank")
        leader:click("Button", "None")
        leader:click("CheckButton", "The Deadmines")
        leader:slash("/dq fill")
        world:advance(2)
        for _, name in ipairs({ "Heal", "Dps A", "Dps B", "Dps C" }) do
            leader:joins(name)
        end
        world:advance(1)
        assert.are.equal(1, #leader.notices)

        local party = leader.party
        local saved = leader:logout()
        local again = world:addClient("Tanky Mctank", { level = 20, saved = saved })
        again.party, again.isLeader = party, true
        world:advance(CONNECT)
        assert.are.equal("The Deadmines  ·  group complete", statusText(again))
        assert.are.same({}, again.notices)
    end)

    it("shows any full party in the window and does not offer to queue it", function()
        local world = World.new()
        local leader = world:addClient("Tanky Mctank", { level = 20 })
        leader.party, leader.isLeader = { "A One", "B Two", "C Three", "D Four" }, true
        world:advance(CONNECT)
        leader:slash("/dq")
        assert.is_not_nil(leader:findText("^Your party is complete %(5/5%)$"))
        assert.is_not_nil(leader:findText("^No need to queue%.$"))
        assert.is_nil(leader:find("Button", "Find group"))
        assert.is_nil(leader:find("Button", "Fill from Group Finder"))
        assert.is_nil(statusText(leader))
        leader.party = { "A One", "B Two" }
        leader:fire("GROUP_ROSTER_UPDATE")
        world:advance(1)
        assert.is_not_nil(leader:findText("^Your party: 3/5"))
        assert.is_not_nil(leader:find("Button", "Find group"))
    end)
end)

describe("Channel connection", function()
    local function connection(client)
        client:frame("ForeverGroupsFrame")
        return client.ns.Comm.connection()
    end

    it("shows connecting, then connected with the channel number", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        client:slash("/dq")
        assert.are.equal("connecting", connection(client).state)
        assert.is_not_nil(client:findText("^Connecting%.%.%.$"))
        world:advance(CONNECT)
        assert.are.equal("Connected", connection(client).text)
        assert.are.equal("Channel /6 (ForeverGroupsNet)", connection(client).detail)
        assert.are.equal("connected", client.ns.WindowParts.ui.connectionBar.info.state)
        assert.are.equal("", client.ns.WindowParts.ui.connectionBar.label.text)
    end)

    it("shows no connecting screen, also in a party while connecting", function()
        local world = World.new()
        local client = world:addClient("Party Leader", { level = 20 })
        client.party = { "Party Friend" }
        client.isLeader = true
        client:slash("/dq")
        assert.is_nil(client:findText("^Joining the Forever Groups channel%.$"))
        assert.is_not_nil(client:find("Button", "Dungeons"))
        assert.is_not_nil(client:find("Button", "Quests"))
        assert.is_not_nil(client:findText("^Your party: 2/5$"))
        local solo = world:addClient("Solo Player", { level = 20 })
        solo:slash("/dq")
        assert.is_nil(solo:findText("^Joining the Forever Groups channel%.$"))
        assert.is_not_nil(solo:find("Button", "Dungeons"))
        local bar = solo.ns.WindowParts.ui.connectionBar
        assert.is_not_nil(solo:find("Button", "Connecting..."))
        assert.is_true(bar.pulsing)
        world:advance(CONNECT)
        assert.is_nil(solo:find("Button", "Connecting..."))
        assert.is_not_nil(solo:find("Button", "Find group"))
        assert.is_false(bar.pulsing)
    end)

    it("shows paused while WoW blocks addon messages", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(CONNECT)
        client.lockdown = true
        assert.are.equal("paused", connection(client).state)
        client.lockdown = false
        assert.are.equal("connected", connection(client).state)
    end)

    it("shows not connected when the channel cannot be joined", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        client.env.JoinTemporaryChannel = function() end
        world:advance(30)
        assert.are.equal("failed", connection(client).state)
        assert.truthy(connection(client).detail:find("too many chat channels", 1, true))
    end)
end)

describe("Minimap button", function()
    local BUTTON = "LibDBIcon10_ForeverGroups"

    it("opens the window and the settings, always shows the logo and can be hidden", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(CONNECT)
        local button = client:frame(BUTTON)
        assert.is_true(button.shown)
        assert.are.equal(client.ns.Widgets.ICON, button.icon.texture)
        assert.is_true(button.icon.texCoord[1] > 0.1 and button.icon.texCoord[2] < 0.9)
        button.scripts.OnClick(button, "LeftButton")
        assert.is_true(client:frame("ForeverGroupsFrame").shown)
        button.scripts.OnClick(button, "RightButton")
        assert.is_true(client:frame("ForeverGroupsSettingsFrame").shown)

        client:slash("/dq join tank,dps auto")
        world:advance(1)
        assert.are.equal(client.ns.Widgets.ICON, button.icon.texture)
        button.scripts.OnEnter(button)
        local tip = table.concat(client:frame("LibDBIconTooltip").lines, "\n")
        assert.is_truthy(tip:find("left click:", 1, true))
        assert.is_truthy(tip:find("open the window", 1, true))

        client:slash("/dq minimap")
        world:advance(1)
        assert.is_false(button.shown)
        client:slash("/dq minimap")
        world:advance(1)
        assert.is_true(button.shown)
    end)

    it("moves around the minimap when dragged and remembers where", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(CONNECT)
        local button = client:frame(BUTTON)
        button.scripts.OnDragStart(button)
        client.cursorX, client.cursorY = 500, 600
        button.scripts.OnUpdate(button)
        button.scripts.OnDragStop(button)
        assert.are.equal(90, client.env.ForeverGroupsDB.minimapIcon.minimapPos)
    end)
end)

describe("Settings window", function()
    local function setup()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(CONNECT)
        client:slash("/dq settings")
        assert.is_true(client:frame("ForeverGroupsSettingsFrame").shown)
        return world, client
    end

    it("shows every option with its current state", function()
        local _, client = setup()
        assert.is_true(client:find("CheckButton", "Refresh WoW's Group Finder while I play").checked)
        assert.is_nil(client:find("CheckButton", "Show the minimap button"))
        client:click("Button", "Display")
        assert.is_true(client:find("CheckButton", "Show the minimap button").checked)
        assert.is_false(client:find("CheckButton", "Debug messages in chat").checked)
        assert.is_nil(client:find("CheckButton", "Refresh WoW's Group Finder while I play"))
    end)

    it("changes the addon right away", function()
        local world, client = setup()
        client:click("CheckButton", "Refresh WoW's Group Finder while I play")
        assert.is_true(client.env.ForeverGroupsDB.autoSearchOff)
        client:click("Button", "Display")
        client:click("CheckButton", "Show the minimap button")
        assert.is_false(client:frame("LibDBIcon10_ForeverGroups").shown)
        client:click("CheckButton", "Show the status bar")
        client:slash("/dq join tank dm")
        world:advance(1)
        assert.is_false(client:frame("ForeverGroupsStatusFrame").shown)
        client:click("Button", "Messages")
        client:click("CheckButton", "Whisper players before inviting them")
        assert.is_true(client.env.ForeverGroupsDB.noWhisper)
        client:click("Button", "Display")
        client:click("CheckButton", "Debug messages in chat")
        assert.is_true(client.env.ForeverGroupsDB.debug)
    end)

    it("does not whisper or announce when those are off", function()
        local world = World.new()
        local leader = world:addClient("Tanky Mctank", { level = 20 })
        leader.env.ForeverGroupsDB.noWhisper = true
        leader.env.ForeverGroupsDB.noPartyAnnounce = true
        for i, name in ipairs({ "Heal", "Dps A", "Dps B", "Dps C" }) do
            world:list(name, i == 1 and "H" or "D", 799, 20, 100 + i)
        end
        world:advance(CONNECT)
        leader:slash("/dq")
        leader:click("CheckButton", "Tank")
        leader:click("Button", "None")
        leader:click("CheckButton", "The Deadmines")
        leader:slash("/dq fill")
        world:advance(2)
        for _, name in ipairs({ "Heal", "Dps A", "Dps B", "Dps C" }) do
            leader:joins(name)
        end
        world:advance(1)
        assert.are.equal(4, #leader.invites)
        assert.are.same({}, leader.whispers)
    end)
end)

describe("Queue window", function()
    local function addFake(client, name)
        assert(client.ns.engine:addFake({ { name = name, roles = "D", level = 20 } },
            client.ns.engine.myEntry.dungeons, "MAGE3"))
    end

    it("lists Forever Groups players and Group Finder players for your dungeons", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        unfold(client)
        local other = world:addClient("Other Healer", { level = 20 })
        world:list("Listed Tank", "TD", 799, 21, 300)
        world:list("Wrong Dungeon", "H", 800, 25, 100)
        world:advance(CONNECT)
        other:slash("/dq join healer dm")
        client:slash("/dq join dps dm")
        addFake(client, "Fake Mage")
        addFake(client, "Fake Rogue")
        world:advance(3)

        client:slash("/dq queue")
        assert.is_true(client:frame("ForeverGroupsQueueFrame").shown)
        assert.is_not_nil(client:findText("^Solo Player$"))
        assert.is_not_nil(client:findText("^Other Healer$"))
        assert.is_not_nil(client:findText("^Fake Mage$"))
        assert.is_not_nil(client:findText("^%[you%]  DM$"))
        assert.is_not_nil(client:findText("^%[fake%]  %a"))
        assert.is_not_nil(client:findText("^0:0%d$"))
        assert.is_not_nil(client:findText("^20$"))
        for _, header in ipairs({ "Roles", "Name", "Lvl", "Dungeons", "Time" }) do
            assert.is_not_nil(client:find("Button", header), header)
        end
        assert.is_nil(client:find("Button", "Needs"))
        assert.is_not_nil(client:findText("^Listed Tank$"))
        assert.is_not_nil(client:findText("^21$"))
        assert.is_not_nil(client:findText("^5:0%d$"))
        assert.is_nil(client:findText("^Wrong Dungeon$"))
        assert.is_not_nil(client:findText("^Players %(5  ·  4 in Forever Groups%)$"))
        assert.are.equal("Interface\\LFGFrame\\LFG-Eye", client:findText("^Listed Tank$").parent.source.texture)
        assert.are.equal(client.ns.Widgets.ICON, client:findText("^Other Healer$").parent.source.texture)
        assert.is_not_nil(client:findText("^searched 0:0%d ago$"))
        assert.are.same({ [799] = true }, client.searchFilter)
    end)

    it("opens docked to the main window and closes with it", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(CONNECT)
        client:slash("/dq queue")
        local queue, main = client:frame("ForeverGroupsQueueFrame"), client:frame("ForeverGroupsFrame")
        assert.is_true(queue.shown)
        assert.is_true(main.shown)
        assert.are.same({ "TOPLEFT", main, "TOPRIGHT", 20, 0 }, queue.point)
        main:Hide()
        assert.is_false(queue.shown)
    end)

    it("shares WoW's panel layer, and comes to the front together with the main window", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(CONNECT)
        client:slash("/dq")
        local queue, main = client:frame("ForeverGroupsQueueFrame"), client:frame("ForeverGroupsFrame")
        assert.are.equal("MEDIUM", main.strata)
        assert.are.equal("MEDIUM", queue.strata)
        client:fire("GLOBAL_MOUSE_DOWN")
        assert.is_nil(main.raisedAt)
        queue.mouseOver = true
        client:fire("GLOBAL_MOUSE_DOWN")
        assert.is_true(queue.raisedAt > main.raisedAt)
        queue.mouseOver, main.mouseOver = false, true
        client:fire("GLOBAL_MOUSE_DOWN")
        assert.is_true(main.raisedAt > 2 and queue.raisedAt > 2)
    end)

    it("is a drawer of the main window: open by default, its tab opens and closes it, and it remembers", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(CONNECT)
        client:slash("/dq")
        local queue, main = client:frame("ForeverGroupsQueueFrame"), client:frame("ForeverGroupsFrame")
        local tab = client.ns.QueueWindow.tab()
        assert.is_true(queue.shown)
        assert.are.equal(main, tab.parent)
        tab.scripts.OnClick(tab)
        assert.is_false(queue.shown)
        main:Hide()
        client:slash("/dq")
        assert.is_false(queue.shown)
        tab.scripts.OnClick(tab)
        assert.is_true(queue.shown)
        main:Hide()
        client:slash("/dq")
        assert.is_true(queue.shown)
        client.env.UIParent.shown = false
        queue:Hide()
        client.env.UIParent.shown = true
        assert.is_nil(client.ns.db.whoClosed)
        tab.scripts.OnClick(tab)
        assert.is_true(queue.shown)
        queue:Hide()
        main:Hide()
        client:slash("/dq")
        assert.is_false(queue.shown)
    end)

    it("searches at once for a dungeon you tick that the last search did not cover", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 13 })
        world:listGroup("Deadmines Group", 799, { T = 0, H = 0, D = 2 }, 60)
        world:advance(CONNECT)
        client.ns.db.queueFold = { groups = false }
        client:slash("/dq")
        world:advance(1)
        client:click("Button", "Other dungeons")
        local before = client.searches
        assert.is_nil(client:findText("^Deadmines Group %+2$"))
        client:click("CheckButton", "The Deadmines")
        assert.are.equal(before + 1, client.searches)
        assert.is_true(client.searchFilter[799])
        world:advance(1)
        assert.is_not_nil(client:findText("^Deadmines Group %+2$"))
        client:click("CheckButton", "The Deadmines")
        assert.are.equal(before + 1, client.searches)
        assert.is_nil(client:findText("^Deadmines Group %+2$"))
    end)

    it("whispers or invites a player from the right-click menu", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        unfold(client)
        world:list("Listed Tank", "TD", 799, 21, 300)
        world:advance(CONNECT)
        client:slash("/dq join dps dm")
        addFake(client, "Fake Mage")
        world:advance(3)
        client:slash("/dq queue")
        local function rightClick(name)
            for _, widget in ipairs(client.widgets) do
                local row = widget.parent
                if widget.kind == "FontString" and widget.text == name and row and row.item and row.shown then
                    return row.scripts.OnMouseUp(row, "RightButton")
                end
            end
            error("no row for " .. name)
        end
        rightClick("Solo Player")
        assert.is_nil(client:find("Button", "Whisper"))
        rightClick("Fake Mage")
        assert.is_nil(client:find("Button", "Whisper"))

        rightClick("Listed Tank")
        assert.is_true(client:frame("ForeverGroupsPlayerMenu").shown)
        client:click("Button", "Whisper")
        assert.are.equal("Listed Tank", client.tellTarget)
        assert.is_false(client:frame("ForeverGroupsPlayerMenu").shown)
        rightClick("Listed Tank")
        client:click("Button", "Invite to group")
        local invited = false
        for _, name in ipairs(client.invites) do
            invited = invited or name == "Listed Tank"
        end
        assert.is_true(invited)
    end)

    it("lists groups in their own table with what they need, and asks a leader to invite you", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        unfold(client)
        world:list("Listed Dps", "D", 799, 20, 60)
        world:listGroup("Needs Heal", 799, { T = 0, H = 1, D = 0 }, 120)
        world:listGroup("Needs Dps", 799, { T = 0, H = 0, D = 2 }, 30)
        world:listGroup("Other Dungeon", 800, { T = 0, H = 0, D = 1 }, 30)
        world:advance(CONNECT)
        client:slash("/dq")
        client:click("CheckButton", "DPS")
        client:click("Button", "None")
        client:click("CheckButton", "The Deadmines")
        world:advance(1)
        assert.is_nil(client:find("Button", "Groups"))
        assert.is_not_nil(client:findText("^Groups %(2%)$"))
        assert.is_not_nil(client:findText("^Needs Heal %+3$"))
        assert.is_not_nil(client:findText("^Needs Dps %+2$"))
        assert.is_nil(client:findText("^Other Dungeon"))
        local soloRow = client:findText("^Listed Dps$").parent
        local groupRow = client:findText("^Needs Dps %+2$").parent
        assert.are_not.equal(soloRow.parent, groupRow.parent)
        assert.is_true(groupRow.needs[1].shown)
        assert.are.equal("2", groupRow.needs[1].count.text)
        assert.are.equal("", groupRow.icons[3].count.text)
        local healRow = client:findText("^Needs Heal %+3$").parent
        assert.are.equal("", healRow.icons[2].count.text)
        assert.are.equal("", healRow.needs[1].count.text)
        local needsHeaders = 0
        for _, widget in ipairs(client.widgets) do
            if widget.kind == "Button" and widget.label and widget.label.text == "Needs" and widget.shown then
                needsHeaders = needsHeaders + 1
            end
        end
        assert.are.equal(1, needsHeaders)
        assert.is_false(soloRow.needs[1].shown == true)

        groupRow.scripts.OnMouseUp(groupRow, "RightButton")
        assert.is_nil(client:find("Button", "Invite to group"))
        client:click("Button", "Request to join")
        local asked
        for _, w in ipairs(client.whispers) do
            if w.target == "Needs Dps" then
                asked = w.text
            end
        end
        assert.is_truthy(asked and asked:find("could you invite me for The Deadmines", 1, true))
        assert.is_truthy(asked:find("Level 20 DPS here", 1, true))
        client:click("Button", "Find group")
        world:advance(2)
        client:click("Button", "Stop")
        world:advance(20)
        client.ns.db.noAutoAcceptAsked = true
        client:fire("PARTY_INVITE_REQUEST", "Needs Dps")
        world:advance(1)
        assert.is_true(client:said("Needs Dps invited you for The Deadmines%. Accept the invite!"))

        local needs
        for _, widget in ipairs(client.widgets) do
            needs = needs or (widget.filterBox == "needs" and widget)
        end
        client:pickMenu(needs, "DPS")
        assert.is_nil(client:findText("^Needs Heal %+3$"))
    end)

    it("opens both tables by default and keeps a fold, also when switching between joining and leading", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:list("Listed Dps", "D", 799, 20, 60)
        world:listGroup("Needs Dps", 799, { T = 0, H = 0, D = 2 }, 30)
        world:advance(CONNECT)
        client:slash("/dq")
        client:click("CheckButton", "DPS")
        client:click("Button", "None")
        client:click("CheckButton", "The Deadmines")
        world:advance(1)
        assert.is_not_nil(client:findText("^Listed Dps$"))
        assert.is_not_nil(client:findText("^Needs Dps %+2$"))
        local caption = client:findText("^Players %(1%)$").parent
        caption.scripts.OnClick(caption)
        assert.is_nil(client:findText("^Listed Dps$"))
        assert.is_not_nil(client:findText("^·  1 DPS$"))
        local lead = "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:16:16|t Lead a group"
        client:click("Button", lead)
        assert.is_nil(client:findText("^Listed Dps$"))
        assert.is_not_nil(client:findText("^Needs Dps %+2$"))
        client:click("Button", "Join a group")
        assert.is_nil(client:findText("^Listed Dps$"))
        caption.scripts.OnClick(caption)
        assert.is_not_nil(client:findText("^Listed Dps$"))
    end)

    it("shows what a Forever Groups party still needs", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(CONNECT)
        local engine = client.ns.engine
        client:slash("/dq queue")
        assert.is_not_nil(client:findText("^No groups listed for your dungeons%.$"))
        engine.queue:upsert({ id = "Party Lead", joinedAt = 1, dungeons = { "5" }, reserved = "", members = {
            { name = "Party Lead", roles = "H", level = 20 }, { name = "Friend One", roles = "T", level = 20 },
        } }, engine:now())
        client.ns.QueueWindow.refresh()
        assert.is_not_nil(client:findText("^Groups %(1  ·  1 in Forever Groups%)$"))
        local row = client:findText("^Party Lead %+1$").parent
        assert.is_true(row.needs[1].shown)
        assert.is_nil(row.needs[2].shown == true and row.needs[2] or nil)
    end)

    it("shows how many listed groups need one of your roles, per dungeon and in Looking now", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:listGroup("Needs Dps", 799, { T = 0, H = 0, D = 1 }, 30)
        world:listGroup("Needs Dps Too", 799, { T = 1, H = 0, D = 2 }, 60)
        world:listGroup("Needs Heal", 799, { T = 0, H = 1, D = 0 }, 30)
        world:advance(CONNECT)
        client:slash("/dq")
        client:click("CheckButton", "DPS")
        client:click("Button", "None")
        client:click("CheckButton", "The Deadmines")
        client:press("W")
        world:advance(1)
        assert.is_not_nil(client:findText("^2 groups"))
        assert.is_not_nil(client:findText("^·  2 groups need you$"))
        client:click("CheckButton", "Healer")
        assert.is_not_nil(client:findText("^3 groups"))
        client:click("Button", "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:16:16|t Lead a group")
        assert.is_nil(client:findText("^3 groups"))
        assert.is_nil(client:findText("groups need you$"))
        client:click("Button", "Join a group")
        assert.is_not_nil(client:findText("^3 groups"))
        client.ns.db.noApply = true
        client.ns.Window.refresh()
        assert.is_nil(client:findText("^3 groups"))
        assert.is_nil(client:findText("groups need you$"))
    end)

    it("says per searched dungeon when your role is needed, or that nobody looks", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:list("Listed Heal", "H", 799)
        world:list("Listed Dps", "D", 799)
        world:list("Caverns Tank", "T", 796)
        world:advance(CONNECT)
        client:slash("/dq")
        client:click("CheckButton", "Tank")
        client:click("Button", "None")
        client:click("CheckButton", "The Deadmines")
        client:press("W")
        world:advance(1)
        assert.is_not_nil(client:findText("^Tank needed$"))
        local caverns = client:findText("^Wailing Caverns$").parent
        assert.is_false(caverns.checked)
        assert.are.equal("", caverns.groups.text)
        client:click("CheckButton", "Healer")
        assert.are.equal("Healer needed", caverns.groups.text)
        client:click("CheckButton", "Healer")
        client:click("CheckButton", "Tank")
        client:click("CheckButton", "DPS")
        assert.is_nil(client:findText("^Tank needed$"))
        assert.is_not_nil(client:findText("^DPS needed$"))

        world:listGroup("Needs Dps", 799, { T = 0, H = 0, D = 1 }, 30)
        client:press("W")
        world:advance(11)
        client:press("W")
        world:advance(1)
        assert.is_not_nil(client:findText("^1 group  ·  |cff66ff66DPS needed|r$"))

        client.ns.db.noGroupFinder = true
        client.ns.Window.refresh()
        assert.is_nil(client:findText("DPS needed"))
        assert.is_not_nil(client:findText("^quiet$"))
    end)

    it("marks no role needed most for a class with one role", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20, class = "WARLOCK" })
        world:list("Listed Tank", "T", 799)
        world:list("Listed Heal", "H", 799)
        world:advance(CONNECT)
        client:slash("/dq")
        client:click("Button", "None")
        client:click("CheckButton", "The Deadmines")
        client:press("W")
        world:advance(1)
        assert.is_false(client:find("CheckButton", "DPS").needed.shown == true)
    end)

    it("marks the role needed most among those the class can play", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20, class = "PRIEST" })
        world:list("Listed Tank", "T", 799)
        world:list("Listed Dps", "D", 799)
        world:advance(CONNECT)
        client:slash("/dq")
        client:click("Button", "None")
        client:click("CheckButton", "The Deadmines")
        client:press("W")
        world:advance(1)
        local healer = client:find("CheckButton", "Healer")
        assert.is_true(healer.needed.shown)
        assert.is_false(client:find("CheckButton", "DPS").needed.shown == true)
        assert.is_truthy(healer.neededTip:find("1 tank, 0 healers, 1 DPS", 1, true))

        world:list("Listed Heal", "H", 799)
        client:press("W")
        world:advance(11)
        client:press("W")
        world:advance(1)
        assert.is_true(client:find("CheckButton", "DPS").needed.shown)
        assert.is_false(healer.needed.shown == true)
        assert.is_false(client:find("CheckButton", "Tank").needed.shown == true)
    end)

    it("adds the Group Finder numbers to the counts in the main window", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:list("Listed Tank", "TD", 799)
        world:list("Listed Heal", "H", 799)
        world:advance(CONNECT)
        client:slash("/dq join dps dm")
        world:advance(2)
        client.ns.Window.show()
        client.ns.Window.refresh()
        local W = client.ns.WindowParts
        assert.is_true(W.ui.headerLooking.shown)
        assert.are.equal("1", W.ui.headerLooking.texts.T.text)
        assert.are.same({ T = 1, H = 1, D = 1 },
            client.ns.QueueWindow.lookingCounts(client.ns.QueueWindow.wantedDungeons()))
        assert.is_true(client:frame("ForeverGroupsQueueFrame").shown)
    end)
end)

describe("Group Finder numbers before queueing", function()
    it("search when the windows open and say so before the first search", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:list("Listed Heal", "H", 799)
        world:advance(CONNECT)
        client.ns.Window.show()
        client.ns.Window.refresh()
        assert.is_true(client.ns.WindowParts.ui.headerLooking.shown)
        client.ns.Window.show()
        client:frame("ForeverGroupsFrame"):Hide()
        client:slash("/dq")
        world:advance(1)
        assert.are.equal(1, client.searches)
        client.ns.Window.refresh()
        assert.are.same({ T = 0, H = 1, D = 0 },
            client.ns.QueueWindow.lookingCounts(client.ns.QueueWindow.wantedDungeons()))

        world:advance(11)
        client:click("Button", "Refresh")
        assert.are.equal(2, client.searches)
        client:click("CheckButton", "The Deadmines")
        assert.are.equal(2, client.searches)
        world:advance(6)
        client:click("CheckButton", "The Deadmines")
        assert.are.equal(3, client.searches)
    end)

    it("refreshes on key presses while a window is open", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(CONNECT)
        client:slash("/dq")
        local searches = client.searches
        world:advance(31)
        client:press("W")
        assert.are.equal(searches + 1, client.searches)
        client:slash("/dq")
        world:advance(31)
        client:press("W")
        assert.are.equal(searches + 1, client.searches)
    end)
end)

describe("Queue window scrolling", function()
    it("scrolls long lists with the mouse wheel", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        unfold(client)
        for i = 1, 30 do
            world:list(string.format("Listed %02d", i), "D", 799, 20, 1000 - i)
        end
        world:advance(CONNECT)
        client:slash("/dq")
        client:click("Button", "None")
        client:click("CheckButton", "The Deadmines")
        world:advance(6)
        world:advance(1)
        assert.is_not_nil(client:findText("^Listed 01$"))
        assert.is_nil(client:findText("^Listed 11$"))
        assert.is_not_nil(client:findText("^1%-10 of 30, scroll for more$"))

        local area
        for _, widget in ipairs(client.widgets) do
            if widget.scripts.OnMouseWheel and widget.shown then
                area = area or (client:findText("^Listed 01$").parent.parent == widget and widget) or nil
            end
        end
        area.scripts.OnMouseWheel(area, -1)
        assert.is_nil(client:findText("^Listed 01$"))
        assert.is_not_nil(client:findText("^Listed 04$"))
        assert.is_not_nil(client:findText("^4%-13 of 30, scroll for more$"))
        for _ = 1, 10 do
            area.scripts.OnMouseWheel(area, -1)
        end
        assert.is_not_nil(client:findText("^Listed 30$"))
        assert.is_not_nil(client:findText("^21%-30 of 30, scroll for more$"))

        local bar
        for _, widget in ipairs(client.widgets) do
            if widget.callbacks and widget.callbacks.OnScroll and widget.parent == area then
                bar = widget
            end
        end
        assert.is_true(bar.shown)
        assert.are.equal(1, bar.scrollPercentage)
        assert.are.equal(10 / 30, bar.visibleExtent)
        bar.callbacks.OnScroll.fn(bar.callbacks.OnScroll.owner, 0.5)
        assert.is_not_nil(client:findText("^11%-20 of 30, scroll for more$"))
        bar.callbacks.OnScroll.fn(bar.callbacks.OnScroll.owner, 0)
        assert.is_not_nil(client:findText("^Listed 01$"))
    end)
end)

describe("Queue window order", function()
    it("lists tanks first, then healers, then DPS, longest waiting first within a role", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        unfold(client)
        world:list("Old Dps", "D", 799, 20, 900)
        world:list("New Heal", "H", 799, 20, 100)
        world:list("Old Heal", "H", 799, 20, 800)
        world:list("Flex Tank", "TD", 799, 20, 50)
        world:advance(CONNECT)
        client:slash("/dq")
        client:click("Button", "None")
        client:click("CheckButton", "The Deadmines")
        world:advance(6)
        world:advance(1)
        local order = {}
        for _, widget in ipairs(client.widgets) do
            if widget.kind == "FontString" and widget.shown and widget.parent and widget.parent.icons
                and widget.parent.shown and widget.text and widget.text ~= "" and widget == widget.parent.name then
                order[#order + 1] = widget.text
            end
        end
        assert.are.same({ "Flex Tank", "Old Heal", "New Heal", "Old Dps" }, order)
    end)

    it("sorts by the chosen column and reverses on a second click", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        unfold(client)
        world:list("Bravo", "D", 799, 25, 100)
        world:list("Alpha", "H", 799, 18, 300)
        world:list("Charlie", "T", 799, 22, 200)
        world:advance(CONNECT)
        client:slash("/dq")
        client:click("Button", "None")
        client:click("CheckButton", "The Deadmines")
        world:advance(6)
        world:advance(1)
        local function order()
            local names = {}
            for _, widget in ipairs(client.widgets) do
                if widget.kind == "FontString" and widget.parent and widget.parent.icons and widget.parent.shown
                    and widget == widget.parent.name then
                    names[#names + 1] = widget.text
                end
            end
            return names
        end
        local function arrow(label)
            local header = client:find("Button", label)
            return header.arrow.shown and header.arrow.texture:match("Arrow%-(%a+)%-Up") or nil
        end
        assert.are.same({ "Charlie", "Alpha", "Bravo" }, order())
        assert.are.equal("Up", arrow("Roles"))
        assert.is_nil(arrow("Name"))
        client:click("Button", "Name")
        assert.are.same({ "Alpha", "Bravo", "Charlie" }, order())
        assert.are.equal("Up", arrow("Name"))
        assert.is_nil(arrow("Roles"))
        client:click("Button", "Name")
        assert.are.same({ "Charlie", "Bravo", "Alpha" }, order())
        assert.are.equal("Down", arrow("Name"))
        client:click("Button", "Lvl")
        assert.are.same({ "Bravo", "Charlie", "Alpha" }, order())
        assert.are.equal("Down", arrow("Lvl"))
        client:click("Button", "Time")
        assert.are.same({ "Alpha", "Charlie", "Bravo" }, order())
        assert.are.equal("Down", arrow("Time"))
        assert.is_nil(client.env.ForeverGroupsDB.queueSorts)
    end)

    it("sorts each table on its own", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        unfold(client)
        world:list("Bravo", "D", 799, 25, 300)
        world:list("Alpha", "D", 799, 18, 100)
        world:listGroup("Zed", 799, { T = 0, H = 0, D = 2 }, 300)
        world:listGroup("Abe", 799, { T = 0, H = 0, D = 2 }, 100)
        world:advance(CONNECT)
        client:slash("/dq")
        client:click("Button", "None")
        client:click("CheckButton", "The Deadmines")
        world:advance(6)
        world:advance(1)
        local function order(groups)
            local names = {}
            for _, widget in ipairs(client.widgets) do
                if widget.kind == "FontString" and widget.parent and widget.parent.icons and widget.parent.shown
                    and widget == widget.parent.name and (widget.text:find("+", 1, true) ~= nil) == groups then
                    names[#names + 1] = widget.text
                end
            end
            return names
        end
        local function nameHeaders()
            local headers = {}
            for _, widget in ipairs(client.widgets) do
                if widget.kind == "Button" and widget.shown and widget.label and widget.label.text == "Name" then
                    headers[#headers + 1] = widget
                end
            end
            return headers
        end
        assert.are.same({ "Zed +2", "Abe +2" }, order(true))
        assert.are.same({ "Bravo", "Alpha" }, order(false))
        local headers = nameHeaders()
        assert.are.equal(2, #headers)
        local groupsHeader, playersHeader = headers[1], headers[2]
        playersHeader.scripts.OnClick(playersHeader)
        assert.are.same({ "Alpha", "Bravo" }, order(false))
        assert.are.same({ "Zed +2", "Abe +2" }, order(true))
        groupsHeader.scripts.OnClick(groupsHeader)
        assert.are.same({ "Abe +2", "Zed +2" }, order(true))
        assert.are.same({ "Alpha", "Bravo" }, order(false))
    end)
end)

describe("Queue window filters", function()
    local function setup()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        unfold(client)
        return world, client
    end

    local function open(world, client)
        world:advance(CONNECT)
        client:slash("/dq")
        client:click("Button", "None")
        client:click("CheckButton", "The Deadmines")
        world:advance(6)
        world:advance(1)
        local boxes = {}
        for _, widget in ipairs(client.widgets) do
            if widget.filterBox and widget.shown then
                boxes[widget.filterBox] = widget
            end
        end
        return boxes
    end

    it("has a box per filter on the window's top line", function()
        local world, client = setup()
        local boxes = open(world, client)
        assert.are.equal("All roles", boxes.roles.label.text)
        assert.are.equal("All classes", boxes.classes.label.text)
        assert.are.equal("All groups", boxes.needs.label.text)
        assert.are.equal("All levels", boxes.level.label.text)
        local first = client:dropdownItems(boxes.roles)[1]
        assert.are.equal("All roles", first.text)
        assert.is_true(first.selected)
        assert.are.equal(boxes.roles, boxes.classes.point[2])
        assert.are.equal(boxes.classes, boxes.needs.point[2])
        assert.are.equal(boxes.needs, boxes.level.point[2])
    end)

    it("shows only players of the chosen roles, keeping flexible players who can play one of them", function()
        local world, client = setup()
        world:list("Only Dps", "D", 799)
        world:list("Only Heal", "H", 799)
        world:list("Tank Or Dps", "TD", 799)
        local boxes = open(world, client)
        client:pickMenu(boxes.roles, "Tank")
        client:pickMenu(boxes.roles, "Healer")
        assert.is_nil(client:findText("^Only Dps$"))
        assert.is_not_nil(client:findText("^Only Heal$"))
        assert.is_not_nil(client:findText("^Tank Or Dps$"))
        assert.is_not_nil(client:findText("^Players %(2%)$"))
        assert.are.equal("Roles: Tank/Healer", boxes.roles.label.text)
        assert.is_false(client:dropdownItems(boxes.roles)[1].selected)
        client:pickMenu(boxes.roles, "Healer")
        assert.is_nil(client:findText("^Only Heal$"))
        assert.is_not_nil(client:findText("^Tank Or Dps$"))
        client:pickMenu(boxes.roles, "All roles")
        assert.is_not_nil(client:findText("^Only Dps$"))
        assert.are.equal("All roles", boxes.roles.label.text)
    end)

    it("shows only players of the chosen classes", function()
        local world, client = setup()
        world:list("Paladin Dps", "D", 799)
        world:list("Mage Dps", "D", 799)
        world.listings[#world.listings].class = "MAGE"
        local boxes = open(world, client)
        client:pickMenu(boxes.classes, "Mage")
        assert.is_nil(client:findText("^Paladin Dps$"))
        assert.is_not_nil(client:findText("^Mage Dps$"))
        assert.is_truthy(boxes.classes.label.text:find("^Classes: "))
    end)

    it("shows only players and groups near your level", function()
        local world, client = setup()
        world:list("Same Level", "D", 799, 21)
        world:list("Far Above", "D", 799, 26)
        world:listGroup("Near Group", 799, { T = 0, H = 1, D = 0 })
        world:listGroup("Far Group", 799, { T = 0, H = 1, D = 0 })
        world.listings[#world.listings].level = 15
        local boxes = open(world, client)
        client:pickMenu(boxes.level, "Players near my level (17-23)")
        assert.is_nil(client:findText("^Far Above$"))
        assert.is_not_nil(client:findText("^Same Level$"))
        assert.is_not_nil(client:findText("^Far Group %+3$"))
        assert.are.equal("Level: 17-23", boxes.level.label.text)
        client:pickMenu(boxes.level, "Groups near my level (17-23)")
        assert.is_nil(client:findText("^Far Group %+3$"))
        assert.is_not_nil(client:findText("^Near Group %+3$"))
        client:pickMenu(boxes.level, "All levels")
        assert.is_not_nil(client:findText("^Far Above$"))
        assert.is_not_nil(client:findText("^Far Group %+3$"))
        assert.are.equal("All levels", boxes.level.label.text)
    end)

    it("shows only groups with a place your class can take", function()
        local world, client = setup()
        world:listGroup("Needs Tank", 799, { T = 1, H = 0, D = 0 })
        world:listGroup("Needs Dps", 799, { T = 0, H = 0, D = 1 })
        client.class = "MAGE"
        local boxes = open(world, client)
        client:pickMenu(boxes.needs, "Room for my class (Mage)")
        assert.is_nil(client:findText("^Needs Tank %+3$"))
        assert.is_not_nil(client:findText("^Needs Dps %+3$"))
        assert.is_truthy(boxes.needs.label.text:find("^Needs: "))
        client:pickMenu(boxes.needs, "All groups")
        assert.is_not_nil(client:findText("^Needs Tank %+3$"))
    end)

    it("takes over the roles chosen with the old role buttons", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        unfold(client)
        client.ns.db.queueRoles, client.ns.db.whoFilter = "H", nil
        world:list("Only Dps", "D", 799)
        world:list("Only Heal", "H", 799)
        local boxes = open(world, client)
        assert.is_nil(client:findText("^Only Dps$"))
        assert.is_not_nil(client:findText("^Only Heal$"))
        assert.are.equal("Roles: Healer", boxes.roles.label.text)
        assert.are.equal("Needs: Healer", boxes.needs.label.text)
        assert.is_nil(client.env.ForeverGroupsDB.queueRoles)
    end)
end)

describe("Group Finder updates between searches", function()
    it("drops players who delisted or joined a group, and refreshes faster with the queue window open", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        unfold(client)
        world:list("Stays", "H", 799)
        world:list("Leaves", "D", 799)
        world:list("Groups Up", "T", 799)
        world:advance(CONNECT)
        client:slash("/dq")
        client:click("Button", "None")
        client:click("CheckButton", "The Deadmines")
        world:advance(6)
        world:advance(1)
        assert.is_not_nil(client:findText("^Leaves$"))

        world.listings[2].isDelisted = true
        client:fire("LFG_LIST_SEARCH_RESULT_UPDATED", 2)
        world.listings[3].numMembers = 2
        client:fire("LFG_LIST_SEARCH_RESULT_UPDATED", 3)
        world:advance(1)
        assert.is_nil(client:findText("^Leaves$"))
        assert.is_nil(client:findText("^Groups Up$"))
        assert.is_not_nil(client:findText("^Stays$"))

        local searches = client.searches
        world:advance(11)
        client:press("W")
        assert.are.equal(searches + 1, client.searches)
    end)
end)

describe("Queue window refresh", function()
    local function openQueue()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        unfold(client)
        for i = 1, 20 do
            world:list(string.format("Listed %02d", i), "D", 799, 20, 1000 - i)
        end
        world:advance(CONNECT)
        client:slash("/dq")
        client:click("Button", "None")
        client:click("CheckButton", "The Deadmines")
        world:advance(6)
        world:advance(1)
        return world, client
    end

    local function wheelArea(client)
        return client:findText("^Listed 01$").parent.parent
    end

    it("searches again from the Refresh button and shows that it is searching", function()
        local world, client = openQueue()
        local searches = client.searches
        world:advance(4)
        client:click("Button", "Refresh")
        assert.are.equal(searches + 1, client.searches)
        client.ns.QueueWindow.refresh()
        assert.is_not_nil(client:findText("^searching%.%.%.$"))
        world:advance(1)
        assert.is_not_nil(client:findText("^Players %(20%)$"))
        client:click("Button", "Refresh")
        local after = client.searches
        assert.is_true(after <= searches + 2)
        client:click("Button", "Refresh")
        assert.are.equal(after, client.searches)
    end)

    it("refreshes stale results when you click a column header to sort", function()
        local world, client = openQueue()
        local searches = client.searches
        world:advance(11)
        client:click("Button", "Name")
        assert.are.equal(searches + 1, client.searches)
    end)

    it("stops searching on scroll once WoW blocks it", function()
        local world, client = openQueue()
        local area = wheelArea(client)
        world:advance(11)
        area.scripts.OnMouseWheel(area, -1)
        assert.are.equal(1, client.blockedSearches)
        world:advance(11)
        area.scripts.OnMouseWheel(area, -1)
        assert.are.equal(1, client.blockedSearches)
    end)
end)

describe("Group Finder names that arrive late", function()
    it("adds a listing once WoW sends its leader's name", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        unfold(client)
        world:list("Late Name", "H", 799)
        world.listings[1].leaderName = nil
        world:advance(CONNECT)
        client:slash("/dq")
        client:click("Button", "None")
        client:click("CheckButton", "The Deadmines")
        world:advance(6)
        world:advance(1)
        assert.is_nil(client:findText("^Late Name$"))

        world.listings[1].leaderName = "Late Name"
        client:fire("LFG_LIST_SEARCH_RESULT_UPDATED", 1)
        world:advance(1)
        assert.is_not_nil(client:findText("^Late Name$"))

        world:list("Not Searched Yet", "D", 799)
        client:fire("LFG_LIST_SEARCH_RESULT_UPDATED", 2)
        assert.are.equal(1, #client.ns.LfgList.listings())
    end)
end)

describe("Role icon style", function()
    local icons = {}
    local function atlasOf(client)
        icons[client] = icons[client] or client.ns.Widgets.roleIcon(client.env.UIParent, "T", 14)
        return icons[client]
    end

    it("uses the large flat icons first and lets you pick another style in the settings", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(CONNECT)
        client:slash("/dq join tank dm")
        world:advance(2)
        assert.are.equal("groupfinder-icon-role-large-tank", atlasOf(client).atlas)

        client:slash("/dq settings")
        client:click("Button", "Display")
        assert.is_not_nil(client:findText("^Round %(atlas%)$"))
        assert.is_nil(client:findText("^Tiny$"))
        client:findText("^Round %(classic file%)$").parent.scripts.OnClick()
        assert.are.equal("sheet", client.ns.db.roleIcons)
        assert.are.equal("Interface\\LFGFrame\\UI-LFG-ICON-ROLES", atlasOf(client).texture)
    end)

    it("falls back when the chosen style is missing in this client", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20, atlases = {} })
        client.ns.db.roleIcons = "large"
        world:advance(CONNECT)
        client:slash("/dq join tank dm")
        world:advance(2)
        assert.are.equal("Interface\\LFGFrame\\UI-LFG-ICON-ROLES", atlasOf(client).texture)
    end)
end)

