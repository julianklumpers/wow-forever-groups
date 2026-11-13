local World = require("tests.helpers.wowmock")
local BgMatch = require("core.bgmatch")
local Battlegrounds = require("core.battlegrounds")

local CONNECT = 30

local function entry(id, joinedAt, roles, keys, extra)
    local members = { { name = id, roles = roles, level = 25 } }
    for i, name in ipairs(extra or {}) do
        members[i + 1] = { name = name, roles = "D", level = 25 }
    end
    return { id = id, joinedAt = joinedAt, dungeons = keys, members = members }
end

local function names(group)
    local list = {}
    for _, member in ipairs(group.members) do
        list[#list + 1] = member.name .. ":" .. member.role
    end
    table.sort(list)
    return list
end

describe("battleground keys", function()
    it("join a battleground and its level bracket", function()
        assert.are.equal("wsg-20", Battlegrounds.key("wsg", 25))
        assert.are.equal("ab-20", Battlegrounds.key("ab", 20))
        assert.is_nil(Battlegrounds.key("ab", 9))
        assert.are.same({ "dsi", 30 }, { Battlegrounds.parseKey("dsi-30") })
        assert.is_nil(Battlegrounds.parseKey("dsi-20"))
        assert.is_nil(Battlegrounds.parseKey("xyz-20"))
    end)

    it("open Arathi Basin at 20 and Darkspear Islands at 30", function()
        local function ids(level)
            local list = {}
            for i, battleground in ipairs(Battlegrounds.forLevel(level)) do
                list[i] = battleground.id
            end
            return list
        end
        assert.are.same({ "wsg" }, ids(19))
        assert.are.same({ "wsg", "ab" }, ids(29))
        assert.are.same({ "wsg", "ab", "dsi" }, ids(30))
    end)
end)

describe("battleground groups", function()
    it("form from two players waiting for the same battleground and bracket", function()
        assert.are.same({}, BgMatch.findGroups({ entry("A", 1, "D", { "wsg-20" }) }))
        assert.are.same({}, BgMatch.findGroups({ entry("A", 1, "D", { "wsg-20" }), entry("B", 2, "D", { "wsg-10" }) }))
        local groups = BgMatch.findGroups({ entry("A", 1, "D", { "wsg-20" }), entry("B", 2, "HD", { "wsg-20" }) })
        assert.are.equal(1, #groups)
        assert.are.equal("wsg-20", groups[1].dungeon)
        assert.are.same({ "A:D", "B:H" }, names(groups[1]))
    end)

    it("take up to five players, one healer and DPS where they can", function()
        local list = {}
        for i, id in ipairs({ "A", "B", "C", "D", "E", "F" }) do
            list[i] = entry(id, i, i <= 2 and "HD" or "D", { "ab-20" })
        end
        local groups = BgMatch.findGroups(list)
        assert.are.equal(1, #groups)
        assert.are.same({ "A:H", "B:D", "C:D", "D:D", "E:D" }, names(groups[1]))
    end)

    it("never merge two parties, and a party leads", function()
        local parties = BgMatch.findGroups({
            entry("A", 1, "D", { "wsg-20" }, { "A2" }), entry("B", 2, "D", { "wsg-20" }, { "B2" }),
        })
        assert.are.same({}, parties)
        local groups = BgMatch.findGroups({
            entry("A", 1, "D", { "wsg-20" }), entry("B", 2, "D", { "wsg-20" }, { "B2" }),
        })
        assert.are.equal("B", groups[1].leader)
    end)

    it("are led by the player who would like to lead", function()
        local wants = entry("B", 2, "D", { "wsg-20" })
        wants.lead = true
        local groups = BgMatch.findGroups({ entry("A", 1, "D", { "wsg-20" }), wants })
        assert.are.equal("B", groups[1].leader)
    end)
end)

describe("the battleground queue", function()
    local function ready(world, client, roles, untick)
        client:slash("/dq")
        client:click("Button", "Battlegrounds")
        for _, role in ipairs(roles) do
            client:click("CheckButton", role)
        end
        for _, name in ipairs(untick or {}) do
            client:click("CheckButton", name)
        end
        world:advance(1)
    end

    local function leaderOf(clients)
        for _, client in ipairs(clients) do
            if #client.invites > 0 then
                return client
            end
        end
    end

    it("puts Forever Groups players together and the leader invites", function()
        local world = World.new()
        local a = world:addClient("Aaa Player", { level = 25 })
        local b = world:addClient("Bbb Player", { level = 27 })
        world:advance(CONNECT)
        ready(world, a, { "DPS" }, { "Warsong Gulch" })
        ready(world, b, { "Healer" }, { "Warsong Gulch" })
        a:click("Button", "Find group")
        b:click("Button", "Find group")
        assert.is_false(a.ns.BgFinder.isActive())
        assert.are.same({ "ab-20" }, a.ns.BgQueue.entry().dungeons)
        assert.is_not_nil(a:findText("^Looking for a Arathi Basin group$"))
        world:advance(15)
        for _, client in ipairs({ a, b }) do
            assert.is_true(client:proposalShown(), client.name)
            assert.is_not_nil(client:findText("^Arathi Basin$"), client.name)
            client:acceptPopup()
        end
        world:advance(1)
        local leader = leaderOf({ a, b })
        assert.is_not_nil(leader)
        assert.are.equal(1, #leader.invites)
        assert.is_true(leader:said("Group formed for Arathi Basin"))
        assert.is_true(leader:said("Sign your Arathi Basin group up at a battlemaster"))
        assert.is_false(leader.ns.GroupView.isTracking())
        for _, client in ipairs({ a, b }) do
            assert.is_nil(client.ns.bgEngine.myEntry)
        end
    end)

    it("sends its own messages, and Who is looking counts its players", function()
        local world = World.new()
        local a = world:addClient("Aaa Player", { level = 25 })
        local b = world:addClient("Bbb Player", { level = 25 })
        world:advance(CONNECT)
        ready(world, a, { "Healer" }, { "Warsong Gulch" })
        a:click("Button", "Find group")
        world:advance(2)
        local sent = 0
        for _, text in ipairs(a.sent) do
            if text:find("^b1|") then
                sent = sent + 1
            end
        end
        assert.is_true(sent > 0)
        assert.is_nil(b.ns.engine.queue:get("Aaa Player"))
        assert.is_nil(b.ns.questEngine.queue:get("Aaa Player"))
        assert.is_not_nil(b.ns.bgEngine.queue:get("Aaa Player"))
        local counts = b.ns.QueueWindow.lookingCounts({ ab = true }, "battlegrounds")
        assert.are.equal(1, counts.H)
    end)

    it("lets the leader fill the group from the Group Finder", function()
        local world = World.new()
        for i = 1, 8 do
            world:list("Bg Player" .. i, i == 1 and "H" or "D", 919, 22)
        end
        local a = world:addClient("Aaa Player", { level = 25 })
        local b = world:addClient("Bbb Player", { level = 25 })
        world:advance(CONNECT)
        ready(world, a, { "DPS" }, { "Arathi Basin" })
        ready(world, b, { "DPS" }, { "Arathi Basin" })
        a:click("CheckButton", "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:16:16|t I'd like to lead")
        world:advance(6)
        a:click("Button", "Find players")
        b:click("Button", "Find group")
        world:advance(15)
        a:acceptPopup()
        b:acceptPopup()
        world:advance(1)
        assert.is_true(a:said("Group formed for Warsong Gulch"))
        local invited = table.concat(a.invites, ",")
        assert.is_truthy(invited:find("Bbb Player", 1, true), invited)
        assert.is_true(a.ns.BgFinder.isActive())
        assert.are.equal("build", a.ns.BgFinder.summary().phase)
        assert.is_false(b.ns.BgFinder.isActive())
        assert.are.equal(4, #a.invites)
        assert.are.equal("Bg Player1", a.invites[1])
    end)

    it("is offered from the dungeon queue's page, and waiting in both brings the tabs back", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 25 })
        world:advance(CONNECT)
        client:slash("/dq join dps dm")
        client:slash("/dq")
        world:advance(1)
        assert.is_nil(client:find("Button", "Battlegrounds"))
        client:click("Button", "Also find a battleground group »")
        assert.are.equal("battlegrounds", client.ns.charDb.tab)
        client:click("CheckButton", "DPS")
        client:click("CheckButton", "Warsong Gulch")
        client:click("Button", "Find group")
        world:advance(1)
        assert.is_not_nil(client.ns.bgEngine.myEntry)
        assert.is_not_nil(client.ns.engine.myEntry)
        assert.is_not_nil(client:find("Button", "Dungeons"))
        assert.is_nil(client:find("Button", "Also find a dungeon group »"))
    end)

    it("is left when a dungeon group forms", function()
        local world = World.new()
        local both = world:addClient("Both Queues", { level = 25 })
        local other = world:addClient("Bg Only", { level = 25 })
        local dungeoners = {}
        for i, name in ipairs({ "Heal Er", "Dps One", "Dps Two", "Dps Three" }) do
            dungeoners[i] = world:addClient(name, { level = 20 })
        end
        world:advance(CONNECT)
        ready(world, both, { "Tank" }, { "Warsong Gulch" })
        both:click("Button", "Find group")
        world:advance(1)
        assert.is_not_nil(other.ns.bgEngine.queue:get("Both Queues"))
        both:slash("/dq join tank dm")
        for i, role in ipairs({ "healer", "dps", "dps", "dps" }) do
            dungeoners[i]:slash("/dq join " .. role .. " dm")
        end
        world:advance(15)
        assert.is_true(both:proposalShown())
        assert.is_nil(other.ns.bgEngine.queue:get("Both Queues"))
        both:acceptPopup()
        for _, client in ipairs(dungeoners) do
            client:acceptPopup()
        end
        world:advance(5)
        assert.is_nil(both.ns.bgEngine.myEntry)
        assert.is_true(both:said("A dungeon group formed, so you left the battleground queue"))
    end)
end)

describe("the battleground queue after a /reload", function()
    it("keeps the place", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 25 })
        world:advance(CONNECT)
        client:slash("/dq")
        client:click("Button", "Battlegrounds")
        client:click("CheckButton", "DPS")
        client:click("CheckButton", "Warsong Gulch")
        client:click("Button", "Find group")
        local joinedAt = client.ns.bgEngine.myEntry.joinedAt
        world:advance(150)
        local saved = client:logout()
        local again = world:addClient("Solo Player", { level = 25, saved = saved })
        world:advance(12)
        assert.are.equal(joinedAt, again.ns.bgEngine.myEntry.joinedAt)
        assert.are.same({ "ab-20" }, again.ns.bgEngine.myEntry.dungeons)
        assert.is_true(again:said("Back in the battleground queue; your place was kept"))
    end)
end)
