local World = require("tests.helpers.wowmock")
local Sim = require("tests.helpers.sim")
local QuestMatch = require("core.questmatch")
local Matchmaker = require("core.matchmaker")
local RateLimit = require("core.ratelimit")

local GROUP = 1
local ELWYNN = 9001

local function member(name, roles)
    return { name = name, roles = roles, level = 20 }
end

describe("leaving and holding a queue", function()
    it("ends the open proposal for the leaver", function()
        local sim = Sim.new({ WARMUP = 0 })
        for _, name in ipairs({ "Aa", "Bb", "Cc", "Dd", "Ee" }) do
            sim:add(name)
        end
        for name, role in pairs({ Aa = "T", Bb = "H", Cc = "D", Dd = "D", Ee = "D" }) do
            sim:join(name, role)
        end
        sim:advance(6)
        assert.is_not_nil(sim:openProposal("Cc"))
        sim:engine("Cc"):leave()
        sim:flush()
        local ended = sim:last("Cc", "proposalEnded")
        assert.is_not_nil(ended)
        assert.are.equal("left", ended.result)
    end)

    it("joins while held and answers a sync without an error", function()
        local sim = Sim.new({ WARMUP = 0 })
        sim:add("Aa")
        sim:add("Bb")
        local engine = sim:engine("Aa")
        engine:setHeld(true)
        assert.is_true(engine:join({ member("Aa", "D") }, { "DM" }))
        engine:receive("Bb", "v2|S")
        engine:tick()
        assert.is_nil(sim:engine("Bb").queue:get("Aa"))
    end)

    it("keeps the playstyle when the new one would not fit in the message", function()
        local sim = Sim.new({ WARMUP = 0 })
        sim:add("Aa")
        local engine = sim:engine("Aa")
        local dungeons = { "a" }
        assert.is_true(engine:join({ member("Aa", "D") }, dungeons))
        local function fill(make)
            for i = 1, 100 do
                dungeons[#dungeons + 1] = make(i)
                if not engine:updateEntry(engine.myEntry.members, "", dungeons) then
                    table.remove(dungeons)
                    return
                end
            end
        end
        fill(function(i)
            return string.format("long%05d", i)
        end)
        fill(function(i)
            return string.sub("bcdefghijklmnopqrstuvwxyz", i, i)
        end)
        engine:setPlaystyle(4)
        assert.are_not.equal(4, engine.myEntry.playstyle)
        assert.is_not_nil(sim:last("Aa", "error"))
    end)
end)

describe("quest matchmaking edge cases", function()
    local function entry(id, joinedAt, members, keys, reserved)
        return { id = id, joinedAt = joinedAt, dungeons = keys, members = members, reserved = reserved or "" }
    end

    it("counts the places a party reserved for its invitees, and lists them as missing", function()
        local groups = QuestMatch.findGroups({
            entry("Aa", 1, { member("Aa", "D"), member("Pp", "D") }, { "176-4" }, "H"),
            entry("Bb", 2, { member("Bb", "H") }, { "176-4" }),
            entry("Cc", 3, { member("Cc", "D") }, { "176-4" }),
        })
        assert.are.equal(1, #groups)
        assert.are.equal("H", groups[1].missing)
        local names = {}
        for _, m in ipairs(groups[1].members) do
            names[#names + 1] = m.name
        end
        table.sort(names)
        assert.are.same({ "Aa", "Cc", "Pp" }, names)
    end)

    it("leaves a party alone that is already big enough, without an error", function()
        local groups = QuestMatch.findGroups({
            entry("Aa", 1, { member("Aa", "D"), member("Pp", "D"), member("Qq", "D") }, { "123-2" }),
            entry("Bb", 2, { member("Bb", "D") }, { "123-2" }),
            entry("Cc", 3, { member("Cc", "D") }, { "123-2" }),
        })
        assert.are.equal(1, #groups)
        assert.are.equal("Bb", groups[1].leader)
    end)

    it("never puts the same player twice in a dungeon group that leaves places open", function()
        local group = Matchmaker.findPartialGroup({
            { id = "Aa", joinedAt = 1, dungeons = { "DM" }, members = { member("Aa", "T") } },
            { id = "Bb", joinedAt = 2, dungeons = { "DM" }, members = { member("Bb", "H"), member("Aa", "D") } },
            { id = "Cc", joinedAt = 3, dungeons = { "DM" }, members = { member("Cc", "D") } },
        }, nil, 1000, 0, 2)
        local seen = {}
        for _, m in ipairs(group.members) do
            assert.is_nil(seen[m.name], m.name)
            seen[m.name] = true
        end
    end)

    it("does not mute a client that sends at its own send queue's highest steady rate", function()
        local now = 0
        local limit = RateLimit.new({ clock = function()
            return now
        end })
        for _ = 1, 6 do
            assert.is_true((limit:allow("Busy")))
        end
        for _ = 1, 300 do
            now = now + 1
            assert.is_true((limit:allow("Busy")))
        end
    end)
end)

describe("questing in the Group Finder, reviewed", function()
    local function queued(world, settings)
        local client = world:addClient("Solo Quester", { level = 20, questLog = {
            { "Elwynn Forest", true }, { "Hogger", false, 176, GROUP },
        } })
        world:advance(30)
        for key, value in pairs(settings or {}) do
            client.ns.db[key] = value
        end
        client:slash("/dq")
        client:click("Button", "Quests")
        client:click("CheckButton", "DPS")
        client:click("Button", "Find questing group")
        world:advance(1)
        return client
    end

    it("does not invite a player again whose invite ran out", function()
        local world = World.new()
        world:list("Zone Dps", "D", ELWYNN, 20, 300)
        local client = queued(world)
        assert.are.same({ "Zone Dps" }, client.invites)
        world:advance(80)
        client:press("W")
        world:advance(1)
        world:advance(30)
        client:press("W")
        world:advance(1)
        assert.are.same({ "Zone Dps" }, client.invites)
    end)

    it("replaces the zone listing when a dungeon group needs the listing", function()
        local world = World.new()
        local client = queued(world)
        world:advance(2)
        client:press("W")
        assert.are.same({ ELWYNN }, client.listingArgs[1].activityIDs)
        world:list("Listed Heal", "H", 799, 20, 300)
        client:click("Button", "Also find a dungeon group »")
        world:advance(6)
        client:slash("/dq join tank dm")
        world:advance(2)
        assert.is_true(client.ns.Filler.isActive())
        for _ = 1, 3 do
            client:press("W")
            world:advance(2)
        end
        assert.is_true(client.listed)
        assert.are.same({ 799 }, client.listingArgs[1].activityIDs)
    end)

    it("leaves out the whisper when whispers are turned off", function()
        local world = World.new()
        world:list("Zone Dps", "D", ELWYNN, 20, 300)
        local client = queued(world, { noWhisper = true })
        assert.are.same({ "Zone Dps" }, client.invites)
        assert.are.same({}, client.whispers)
    end)

    it("files a dungeon search after a zone search under dungeons", function()
        local world = World.new()
        world:list("Dungeon Dps", "D", 799, 20, 500)
        world:list("Zone Tank", "T", ELWYNN, 20, 300)
        local client = queued(world)
        assert.are.equal(1, #client.ns.LfgList.zoneListings())
        client.inClick = true
        client.env.C_LFGList.Search(2, 0, 0, nil, false, nil, { 799 })
        client.inClick = false
        world:advance(1)
        assert.are.equal("Dungeon Dps", client.ns.LfgList.listings()[1].name)
        assert.are.equal(1, #client.ns.LfgList.zoneListings())
    end)
end)

describe("the window, reviewed", function()
    it("hides the party header outside the dungeon setup", function()
        local world = World.new()
        local client = world:addClient("Lead Player", { level = 20 })
        world:advance(12)
        client.party, client.isLeader = { "Pal Player" }, true
        client:slash("/dq")
        assert.is_not_nil(client:findText("^Party: roles follow"))
        client:click("Button", "Quests")
        assert.is_nil(client:findText("^Party: roles follow"))
    end)

    it("answers a questing proposal with /dq accept", function()
        local world = World.new()
        local clients = {}
        for i, name in ipairs({ "Aaa Player", "Bbb Player" }) do
            clients[i] = world:addClient(name, { level = 20, questLog = {
                { "Elwynn Forest", true }, { "Gold Run", false, 123, nil, 2 },
            } })
        end
        world:advance(12)
        for _, client in ipairs(clients) do
            client:slash("/dq")
            client:click("Button", "Quests")
            client:click("CheckButton", "DPS")
            client:click("Button", "Find questing group")
        end
        world:advance(15)
        assert.is_true(clients[1]:proposalShown())
        clients[1]:slash("/dq accept")
        assert.is_false(clients[1]:said("There is no group proposal to answer"))
    end)

    it("only queues the group quests it shows", function()
        local world = World.new()
        local log = { { "Elwynn Forest", true } }
        for i = 1, 12 do
            log[#log + 1] = { "Group Quest " .. i, false, 500 + i, GROUP }
        end
        local client = world:addClient("Solo Player", { level = 20, questLog = log })
        world:advance(12)
        client:slash("/dq")
        client:click("Button", "Quests")
        assert.is_not_nil(client:findText("^Group and elite quests  ·  10 selected$"))
    end)
end)

describe("the looking counts", function()
    it("are counted again only when the Group Finder results or the queue change", function()
        local world = World.new()
        world:list("Listed Heal", "H", 799, 20, 300)
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(30)
        client.inClick = true
        client.ns.LfgList.search()
        client.inClick = false
        world:advance(1)
        local QueueWindow = client.ns.QueueWindow
        local lists = 0
        local queue = client.ns.engine.queue
        local list = queue.list
        queue.list = function(self)
            lists = lists + 1
            return list(self)
        end
        assert.are.same({ T = 0, H = 1, D = 0 }, QueueWindow.lookingCounts({ ["5"] = true }))
        QueueWindow.lookingCounts({ ["5"] = true })
        assert.are.equal(1, lists)
        queue:upsert({ id = "Other Tank", joinedAt = 1, dungeons = { "5" },
            members = { { name = "Other Tank", roles = "T", level = 20 } } }, 1)
        assert.are.same({ T = 1, H = 1, D = 0 }, QueueWindow.lookingCounts({ ["5"] = true }))
        assert.are.equal(2, lists)
    end)
end)

describe("keep-alives with both queues", function()
    it("go out once per interval for both queues, and both see the player alive", function()
        local world = World.new()
        local log = { { "Elwynn Forest", true }, { "Hogger", false, 176, GROUP } }
        local a = world:addClient("Aaa Player", { level = 20, questLog = log })
        local b = world:addClient("Bbb Player", { level = 20, questLog = log })
        world:advance(12)
        for i, client in ipairs({ a, b }) do
            client:slash("/dq join dps " .. (i == 1 and "dm" or "wc"))
            client:slash("/dq")
            client:click("Button", "Also find a questing group »")
            if not client.ns.charDb.lastRoles then
                client:click("CheckButton", "DPS")
            end
            client:click("Button", "Find questing group")
        end
        world:advance(5)
        assert.is_not_nil(a.ns.questEngine.myEntry)
        assert.is_not_nil(a.ns.engine.myEntry)
        local before = #a.sent
        for _ = 1, 6 do
            world:advance(10)
            local now = b.env.GetServerTime()
            assert.is_false(b.ns.engine:isSilent("Aaa Player", 1, now))
            assert.is_false(b.ns.questEngine:isSilent("Aaa Player", 1, now))
        end
        assert.is_not_nil(a.ns.engine.myEntry)
        local alive = 0
        for i = before + 1, #a.sent do
            if a.sent[i]:find("^%w%d|K$") then
                alive = alive + 1
            end
        end
        assert.is_true(alive <= 7, alive)
    end)
end)

describe("with inviting Group Finder players turned off", function()
    it("never builds a group from the Group Finder by itself", function()
        local world = World.new()
        world:list("Listed Heal", "H", 799, 20, 300)
        world:list("Listed Dps", "D", 799, 20, 300)
        local client = world:addClient("Solo Tank", { level = 20 })
        world:advance(30)
        client.ns.db.noFill, client.ns.db.noApply = true, true
        client:slash("/dq join tank dm")
        world:advance(90)
        assert.is_false(client.ns.Filler.isActive())
        assert.are.same({}, client.invites)
        assert.are.same({}, client.whispers)
        assert.is_not_nil(client.ns.engine.myEntry)
    end)

    it("invites nobody from a quest's zone", function()
        local world = World.new()
        world:list("Zone Tank", "T", ELWYNN, 20, 300)
        local client = world:addClient("Solo Quester", { level = 20, questLog = {
            { "Elwynn Forest", true }, { "Hogger", false, 176, GROUP },
        } })
        world:advance(30)
        client.ns.db.noFill = true
        client:slash("/dq")
        client:click("Button", "Quests")
        client:click("CheckButton", "DPS")
        client:click("Button", "Find questing group")
        world:advance(30)
        assert.are.same({}, client.invites)
    end)
end)
