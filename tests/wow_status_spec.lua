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
    local open = { addonPlayers = false, addonParties = false, finderPlayers = false, finderGroups = false }
    client.ns.db.queueFold = { join = open, lead = open }
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
        assert.truthy(statusText(client):find(
            "^In queue 1:0%d as Tank/DPS  %-  Building your own group: looking for"))
        assert.is_nil(statusText(client):find("click to search", 1, true))
        local bar = client:frame("ForeverGroupsStatusFrame")
        local searches = client.searches
        client.inClick = true
        bar.scripts.OnClick(bar)
        assert.are.equal(searches + 1, client.searches)
        assert.is_false(client:frame("ForeverGroupsFrame") ~= nil and client:frame("ForeverGroupsFrame").shown)
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
        assert.is_not_nil(client:findText("^Connected$"))
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
    it("opens the window, shows a role badge while queued and can be hidden", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(CONNECT)
        local button = client:frame("ForeverGroupsMinimapButton")
        assert.is_true(button.shown)
        assert.is_false(button.badge.shown)
        button.scripts.OnClick(button, "LeftButton")
        assert.is_true(client:frame("ForeverGroupsFrame").shown)
        button.scripts.OnClick(button, "RightButton")
        assert.is_true(client:frame("ForeverGroupsSettingsFrame").shown)

        client:slash("/dq join tank,dps auto")
        world:advance(1)
        assert.is_true(button.badge.shown)

        client:slash("/dq minimap")
        world:advance(1)
        assert.is_false(button.shown)
        client:slash("/dq minimap")
        world:advance(1)
        assert.is_true(button.shown)
    end)

    it("moves around the minimap when dragged and remembers the angle", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(CONNECT)
        local button = client:frame("ForeverGroupsMinimapButton")
        button.scripts.OnDragStart(button)
        client.cursorX, client.cursorY = 500, 600
        button.scripts.OnUpdate(button)
        button.scripts.OnDragStop(button)
        assert.are.equal(90, client.env.ForeverGroupsDB.minimapAngle)
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
        assert.is_false(client:find("CheckButton", "Dry run: only list Group Finder picks, do not invite").checked)
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
        assert.is_false(client:frame("ForeverGroupsMinimapButton").shown)
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
    it("lists Forever Groups players and Group Finder players for your dungeons", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        unfold(client)
        local other = world:addClient("Other Healer", { level = 20 })
        world:list("Listed Tank", "TD", 799, 21, 300)
        world:list("Wrong Dungeon", "H", 800, 25, 100)
        world:advance(CONNECT)
        other:slash("/dq join healer dm")
        client:slash("/dq dryrun")
        client:slash("/dq join dps dm")
        client:slash("/dq fake 2 dps")
        world:advance(3)

        client:slash("/dq queue")
        assert.is_true(client:frame("ForeverGroupsQueueFrame").shown)
        assert.is_not_nil(client:findText("^Solo Player$"))
        assert.is_not_nil(client:findText("^Other Healer$"))
        assert.is_not_nil(client:findText("^" .. client.ns.Slash.fakeName(1) .. "$"))
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
        assert.is_not_nil(client:findText("^WoW Group Finder$"))
        assert.is_not_nil(client:findText("^Players %(1%)$"))
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
        assert.are.same({ "TOPLEFT", main, "TOPRIGHT", 2, 0 }, queue.point)
        main:Hide()
        assert.is_false(queue.shown)
    end)

    it("whispers or invites a player from the right-click menu", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        unfold(client)
        world:list("Listed Tank", "TD", 799, 21, 300)
        world:advance(CONNECT)
        client:slash("/dq join dps dm")
        client:slash("/dq fake 1 dps")
        world:advance(3)
        client:slash("/dq queue")
        local function rightClick(name)
            local row = client:findText("^" .. name .. "$").parent
            row.scripts.OnMouseUp(row, "RightButton")
        end
        rightClick("Solo Player")
        assert.is_nil(client:find("Button", "Whisper"))
        rightClick(client.ns.Slash.fakeName(1))
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
        client:click("Button", "Who is looking »")
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
        client:fire("PARTY_INVITE_REQUEST", "Needs Dps")
        world:advance(1)
        assert.is_true(client:said("Needs Dps invited you for The Deadmines%. Accept the invite!"))

        client:click("CheckButton", "Healer", client:frame("ForeverGroupsQueueFrame"))
        client:click("CheckButton", "DPS", client:frame("ForeverGroupsQueueFrame"))
        assert.is_nil(client:findText("^Needs Heal %+3$"))
    end)

    it("opens the groups by default, the players when leading, and keeps a fold until you switch", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:list("Listed Dps", "D", 799, 20, 60)
        world:listGroup("Needs Dps", 799, { T = 0, H = 0, D = 2 }, 30)
        world:advance(CONNECT)
        client:slash("/dq")
        client:click("CheckButton", "DPS")
        client:click("Button", "None")
        client:click("CheckButton", "The Deadmines")
        client:click("Button", "Who is looking »")
        world:advance(1)
        assert.is_nil(client:findText("^Listed Dps$"))
        assert.is_not_nil(client:findText("^·  1 DPS$"))
        assert.is_not_nil(client:findText("^Needs Dps %+2$"))
        local lead = "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:16:16|t I'd like to lead"
        client:click("CheckButton", lead)
        assert.is_not_nil(client:findText("^Listed Dps$"))
        assert.is_nil(client:findText("^Needs Dps %+2$"))
        assert.is_not_nil(client:findText("^·  1 need DPS$"))
        local groupsCaption = client:findText("^Groups %(1%)$").parent
        groupsCaption.scripts.OnClick(groupsCaption)
        assert.is_not_nil(client:findText("^Needs Dps %+2$"))
        local caption = client:findText("^Players %(1%)$").parent
        caption.scripts.OnClick(caption)
        assert.is_nil(client:findText("^Listed Dps$"))
        client.ns.QueueWindow.refresh()
        assert.is_nil(client:findText("^Listed Dps$"))
        client:click("CheckButton", lead)
        assert.is_not_nil(client:findText("^Needs Dps %+2$"))
        assert.is_nil(client:findText("^Listed Dps$"))
        client:click("CheckButton", lead)
        assert.is_not_nil(client:findText("^Listed Dps$"))
        assert.is_nil(client:findText("^Needs Dps %+2$"))
    end)

    it("shows what a Forever Groups party still needs", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(CONNECT)
        local engine = client.ns.engine
        client:slash("/dq queue")
        assert.is_not_nil(client:findText("^No Forever Groups party is queued right now%.$"))
        engine.queue:upsert({ id = "Party Lead", joinedAt = 1, dungeons = { "5" }, reserved = "", members = {
            { name = "Party Lead", roles = "H", level = 20 }, { name = "Friend One", roles = "T", level = 20 },
        } }, engine:now())
        client.ns.QueueWindow.refresh()
        assert.is_not_nil(client:findText("^Parties %(1%)$"))
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
        assert.is_not_nil(client:findText("^2 groups$"))
        assert.is_not_nil(client:findText("^·  2 groups need you$"))
        client:click("CheckButton", "Healer")
        assert.is_not_nil(client:findText("^3 groups$"))
        client:click("CheckButton", "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:16:16|t I'd like to lead")
        assert.is_nil(client:findText("^3 groups$"))
        assert.is_nil(client:findText("groups need you$"))
    end)

    it("adds the Group Finder numbers to the counts in the main window", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:list("Listed Tank", "TD", 799)
        world:list("Listed Heal", "H", 799)
        world:advance(CONNECT)
        client:slash("/dq dryrun")
        client:slash("/dq join dps dm")
        world:advance(2)
        client.ns.Window.show()
        client.ns.Window.refresh()
        assert.is_not_nil(client:findText("^Looking now:$"))
        assert.are.same({ T = 1, H = 1, D = 1 },
            client.ns.QueueWindow.lookingCounts(client.ns.QueueWindow.wantedDungeons()))
        client:click("Button", "Who is looking »")
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
        assert.is_not_nil(client:findText("^Looking now:$"))
        client.ns.Window.show()
        client:frame("ForeverGroupsFrame"):Hide()
        client:slash("/dq")
        world:advance(1)
        assert.are.equal(1, client.searches)
        client.ns.Window.refresh()
        assert.are.same({ T = 0, H = 1, D = 0 },
            client.ns.QueueWindow.lookingCounts(client.ns.QueueWindow.wantedDungeons()))

        world:advance(11)
        client:click("Button", "Who is looking »")
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
        client:click("Button", "Who is looking »")
        world:advance(1)
        assert.is_not_nil(client:findText("^Listed 01$"))
        assert.is_nil(client:findText("^Listed 09$"))
        assert.is_not_nil(client:findText("^1%-8 of 30, scroll for more$"))

        local area
        for _, widget in ipairs(client.widgets) do
            if widget.scripts.OnMouseWheel and widget.shown then
                area = area or (client:findText("^Listed 01$").parent.parent == widget and widget) or nil
            end
        end
        area.scripts.OnMouseWheel(area, -1)
        assert.is_nil(client:findText("^Listed 01$"))
        assert.is_not_nil(client:findText("^Listed 04$"))
        assert.is_not_nil(client:findText("^4%-11 of 30, scroll for more$"))
        for _ = 1, 10 do
            area.scripts.OnMouseWheel(area, -1)
        end
        assert.is_not_nil(client:findText("^Listed 30$"))
        assert.is_not_nil(client:findText("^23%-30 of 30, scroll for more$"))
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
        client:click("Button", "Who is looking »")
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
        client:click("Button", "Who is looking »")
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
        assert.are.equal("waiting", client.env.ForeverGroupsDB.queueSorts.finderPlayers.key)
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
        client:click("Button", "Who is looking »")
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
        local playersHeader, groupsHeader = headers[1], headers[2]
        playersHeader.scripts.OnClick(playersHeader)
        assert.are.same({ "Alpha", "Bravo" }, order(false))
        assert.are.same({ "Zed +2", "Abe +2" }, order(true))
        groupsHeader.scripts.OnClick(groupsHeader)
        assert.are.same({ "Abe +2", "Zed +2" }, order(true))
        assert.are.same({ "Alpha", "Bravo" }, order(false))
    end)
end)

describe("Queue window role filter", function()
    it("shows only the chosen roles, keeping flexible players who can play one of them", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        unfold(client)
        world:list("Only Dps", "D", 799)
        world:list("Only Heal", "H", 799)
        world:list("Tank Or Dps", "TD", 799)
        world:advance(CONNECT)
        client:slash("/dq")
        client:click("Button", "None")
        client:click("CheckButton", "The Deadmines")
        world:advance(6)
        client:click("Button", "Who is looking »")
        world:advance(1)
        local window = client:frame("ForeverGroupsQueueFrame")
        client:click("CheckButton", "DPS", window)
        assert.is_nil(client:findText("^Only Dps$"))
        assert.is_not_nil(client:findText("^Only Heal$"))
        assert.is_not_nil(client:findText("^Tank Or Dps$"))
        assert.is_not_nil(client:findText("filtered$"))
        client:click("CheckButton", "Healer", window)
        assert.is_nil(client:findText("^Only Heal$"))
        assert.is_not_nil(client:findText("^Tank Or Dps$"))
        client:click("CheckButton", "Tank", window)
        assert.is_true(client:find("CheckButton", "Tank", window).checked)
        assert.are.equal("T", client.env.ForeverGroupsDB.queueRoles)
        client:click("CheckButton", "DPS", window)
        client:click("CheckButton", "Healer", window)
        assert.is_nil(client.env.ForeverGroupsDB.queueRoles)
        assert.is_not_nil(client:findText("^Only Dps$"))
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
        client:click("Button", "Who is looking »")
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
        client:click("Button", "Who is looking »")
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
        assert.are.equal(searches + 1, client.searches)
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
        client:click("Button", "Who is looking »")
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
    local function atlasOf(client)
        return client:frame("ForeverGroupsMinimapButton").badge
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

describe("Minimap eye", function()
    local function eyeOf(client)
        for _, widget in ipairs(client.widgets) do
            if widget.parent == client:frame("ForeverGroupsMinimapButton")
                and (widget.template == "EyeTemplate" or widget.texture == "Interface\\LFGFrame\\LFG-Eye") then
                return widget
            end
        end
    end

    it("shows WoW's animated eye while searching and the normal icon otherwise", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(CONNECT)
        local button = client:frame("ForeverGroupsMinimapButton")
        assert.is_nil(eyeOf(client))
        client:slash("/dq join tank dm")
        world:advance(2)
        local eye = eyeOf(client)
        assert.are.equal("EyeTemplate", eye.template)
        assert.is_true(eye.shown)
        assert.is_true(eye.animating)
        assert.is_false(button.icon.shown)

        client:slash("/dq leave")
        world:advance(2)
        assert.is_false(eye.shown)
        assert.is_false(eye.animating)
        assert.is_true(button.icon.shown)
    end)

    it("animates the eye picture itself when the client has no eye template", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20, noEyeTemplate = true })
        world:advance(CONNECT)
        client:slash("/dq join tank dm")
        world:advance(2)
        local eye = eyeOf(client)
        assert.are.equal("Interface\\LFGFrame\\LFG-Eye", eye.texture)
        assert.is_true(eye.shown)
        local button = client:frame("ForeverGroupsMinimapButton")
        button.scripts.OnUpdate(button, 0.1)
        assert.are.same({ 1 / 8, 2 / 8, 0, 1 / 4 }, eye.texCoord)
    end)
end)
