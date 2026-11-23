local World = require("tests.helpers.wowmock")

local CONNECT = 12

local function name(client)
    return client.ns.Comm.CHANNEL
end

local function state(world, client)
    return world:channel(name(client), client.shard)
end

local function warnings(client, pattern)
    local count = 0
    for _, line in ipairs(client.ns.db.log or {}) do
        if line:find("%[WARN%]") and line:find(pattern) then
            count = count + 1
        end
    end
    return count
end

describe("the Forever Groups channel", function()
    it("is joined with its password; the first player owns it and the next gets in", function()
        local world = World.new()
        local first = world:addClient("First Player")
        local second = world:addClient("Second Player")
        world:advance(CONNECT)
        local channel = state(world, first)
        assert.are.equal(2, #channel.members)
        assert.are.equal("First Player", channel.owner)
        assert.is_not_nil(channel.password)
        assert.is_not_nil(second.channels[name(second)])
        assert.are.equal("Second Player", second.ns.selfName)
    end)

    it("keeps out a join without the password", function()
        local world = World.new()
        local first = world:addClient("First Player")
        world:advance(CONNECT)
        local stranger = world:addClient("Stranger Danger")
        stranger.env.JoinTemporaryChannel(name(first))
        assert.is_nil(stranger.channels[name(first)])
        world:advance(CONNECT)
        assert.is_not_nil(stranger.channels[name(first)])
    end)

    it("has a name and password that are not written plainly in the addon's files", function()
        local world = World.new()
        local client = world:addClient("First Player")
        world:advance(CONNECT)
        local secrets = { name(client), state(world, client).password }
        for _, dir in ipairs({ "wow", "core" }) do
            local list = io.popen('find ' .. dir .. ' -name "*.lua"')
            for path in list:lines() do
                local file = assert(io.open(path))
                local text = file:read("*a")
                file:close()
                for _, secret in ipairs(secrets) do
                    assert.is_nil(text:find(secret, 1, true), path)
                end
            end
            list:close()
        end
    end)

    it("says why it could not join, and tries again later, waiting longer each time", function()
        local world = World.new()
        local client = world:addClient("Banned Player")
        client.joinRefused = "BANNED"
        world:advance(7)
        assert.are.equal(1, client.joinAttempts)
        assert.are.equal(1, warnings(client, "Could not join the Forever Groups channel: you are banned from it%. "
            .. "Trying again in 0:30%. Until then Forever Groups works through WoW's Group Finder only%."))
        local connection = client.ns.Comm.connection()
        assert.are.equal("failed", connection.state)
        assert.truthy(connection.detail:find("could not join the channel: you are banned from it", 1, true))
        world:advance(31)
        assert.are.equal(2, client.joinAttempts)
        world:advance(57)
        assert.are.equal(2, client.joinAttempts)
        world:advance(3)
        assert.are.equal(3, client.joinAttempts)
        assert.are.equal(1, warnings(client, "you are banned from it"))
        client.joinRefused = nil
        world:advance(125)
        assert.is_not_nil(client.channels[name(client)])
        assert.is_true(client:said("Connected to the Forever Groups channel again%."))
        assert.are.equal("connected", client.ns.Comm.connection().state)
    end)

    it("tries again later when joining raises an error", function()
        local world = World.new()
        local client = world:addClient("Unlucky Player")
        local join = client.env.JoinTemporaryChannel
        client.env.JoinTemporaryChannel = function()
            client.env.JoinTemporaryChannel = join
            error("client hiccup")
        end
        world:advance(7)
        assert.is_nil(client.channels[name(client)])
        assert.are.equal(1, warnings(client, "Could not join the Forever Groups channel: joining the channel failed%."))
        world:advance(31)
        assert.is_not_nil(client.channels[name(client)])
    end)

    it("does not promise the Group Finder when it is turned off", function()
        local world = World.new()
        local client = world:addClient("Banned Player")
        client.ns.db.noGroupFinder = true
        client.joinRefused = "BANNED"
        world:advance(7)
        assert.are.equal(1, warnings(client, "Could not join the Forever Groups channel: you are banned from it%. "
            .. "Trying again in 0:30%.$"))
        assert.is_nil(client.ns.Comm.connection().detail:find("Group Finder", 1, true))
    end)

    it("calls a join WoW never answers 'WoW did not answer'", function()
        local world = World.new()
        local client = world:addClient("Silent Player")
        client.joinRefused = true
        world:advance(25)
        assert.are.equal(1, warnings(client, "Could not join the Forever Groups channel: WoW did not answer%."))
        assert.truthy(client.ns.Diagnostics.report():find("not joined after attempt 1 %(WoW did not answer%)"))
    end)

    it("joins again when WoW puts it out of the channel", function()
        local world = World.new()
        local client = world:addClient("Kicked Player")
        world:advance(CONNECT)
        local channel = name(client)
        client.env.LeaveChannelByName(channel)
        world:channelNotice({ client }, "CHAT_MSG_CHANNEL_NOTICE", channel, "YOU_LEFT")
        world:advance(1)
        assert.is_nil(client.channels[channel])
        world:advance(7)
        assert.is_not_nil(client.channels[channel])
    end)

    it("keeps WoW's notices about it and the old channel out of the chat, and only those", function()
        local world = World.new()
        local client = world:addClient("First Player")
        world:advance(CONNECT)
        for _, event in ipairs({ "CHAT_MSG_CHANNEL_NOTICE", "CHAT_MSG_CHANNEL_NOTICE_USER" }) do
            local filter = client.chatFilters[event] and client.chatFilters[event][1]
            assert.is_not_nil(filter, event)
            assert.is_true(filter(nil, event, "PASSWORD_CHANGED", "Bad Owner", "", "6. x", "", "", 0, 6,
                name(client)))
            assert.is_true(filter(nil, event, "YOU_CHANGED", "", "", "7. ForeverGroupsNet", "", "", 0, 7,
                "ForeverGroupsNet"))
            assert.is_false(filter(nil, event, "YOU_CHANGED", "", "", "1. General", "", "", 0, 1, "General"))
        end
    end)

    it("shows the attempts, WoW's answers and the owner in the bug report and self-test", function()
        local world = World.new()
        local client = world:addClient("First Player")
        world:advance(CONNECT)
        local report = client.ns.Diagnostics.report()
        assert.truthy(report:find("Channel " .. name(client) .. ": 1 join attempts", 1, true))
        assert.truthy(report:find("joined as /6 %(attempt 1%)"))
        assert.truthy(report:find("WoW: YOU_CHANGED", 1, true))
        assert.truthy(report:find("/6 as First Player, you own it", 1, true))
    end)
end)

describe("the channel's owner", function()
    local function two()
        local world = World.new()
        local owner = world:addClient("First Player")
        local member = world:addClient("Second Player")
        world:advance(CONNECT)
        return world, owner, member
    end

    it("is found also when WoW fills the roster late", function()
        local world = World.new()
        local owner = world:addClient("First Player")
        owner.rosterEmpty = 4
        world:advance(CONNECT + 10)
        assert.is_true(owner.ns.ChannelGuard.isOwner())
    end)

    it("follows a change of owner also while the demo runs", function()
        local world, owner, member = two()
        member.ns.db.tourSeen = true
        member.ns.Demo.start()
        assert.is_true(member.ns.Demo.isOn())
        owner.env.LeaveChannelByName(name(owner))
        world:advance(1)
        member.ns.Demo.stop()
        assert.is_true(member.ns.ChannelGuard.isOwner())
        world:foreignPassword(name(member), "open sesame", "Bad Owner")
        world:advance(11)
        assert.are_not.equal("open sesame", state(world, member).password)
    end)

    it("puts the password back when someone else changes it; another member leaves it", function()
        local world, owner, member = two()
        local password = state(world, owner).password
        local sets = owner.passwordSets
        world:foreignPassword(name(owner), "open sesame", "Bad Owner")
        world:advance(10)
        assert.are.equal(password, state(world, owner).password)
        assert.are.equal(sets + 1, owner.passwordSets)
        assert.is_nil(member.passwordSets)
        assert.is_true(owner:logged("channel: password set %(changed by Bad Owner%)"))
    end)

    it("puts it back too when the owner changes it by hand, at most once per 10 seconds", function()
        local world, owner = two()
        local password = state(world, owner).password
        world:advance(20)
        local sets = owner.passwordSets
        owner.env.SetChannelPassword(name(owner), "by hand")
        world:advance(1)
        assert.are.equal(password, state(world, owner).password)
        assert.are.equal(sets + 2, owner.passwordSets)
        world:foreignPassword(name(owner), "again", "Bad Owner")
        world:advance(1)
        assert.are.equal("again", state(world, owner).password)
        world:advance(10)
        assert.are.equal(password, state(world, owner).password)
    end)

    it("lifts a ban and takes moderator away from the others", function()
        local world, owner, member = two()
        world:foreignBan(name(owner), "Some Player", "Bad Owner")
        world:foreignModerator(name(owner), "Second Player")
        world:advance(4)
        assert.are.same({ "unban Some Player", "unmoderator Second Player" }, owner.channelCalls)
        assert.is_nil(member.channelCalls)
        assert.is_nil(state(world, owner).bans["Some Player"])
        assert.is_nil(state(world, owner).moderators["Second Player"])
    end)

    it("passes on to a member, who then guards the password", function()
        local world, owner, member = two()
        owner.env.LeaveChannelByName(name(owner))
        world:advance(1)
        assert.are.equal("Second Player", member.ns.ChannelGuard.owner())
        assert.is_true(member.ns.ChannelGuard.isOwner())
        assert.are.equal(1, member.passwordSets)
        world:foreignPassword(name(member), "open sesame", "Bad Owner")
        world:advance(11)
        assert.are.equal(2, member.passwordSets)
        assert.are.equal(state(world, owner).password, state(world, member).password)
    end)

    it("is no one at times; then nobody guards and nothing breaks", function()
        local world, owner, member = two()
        world.ownerStays = true
        owner.env.LeaveChannelByName(name(owner))
        world:advance(1)
        member.ns.ChannelGuard.onJoined()
        world:advance(3)
        assert.are.equal(false, member.ns.ChannelGuard.owner())
        world:foreignPassword(name(member), "open sesame", "Bad Owner")
        world:advance(11)
        assert.is_nil(member.passwordSets)
        assert.truthy(member.ns.Diagnostics.report():find("no owner", 1, true))
    end)
end)

describe("a party member on another channel", function()
    local function party(world, a, b)
        a.party, b.party = { b.name }, { a.name }
        a.isLeader = true
        a:fire("GROUP_ROSTER_UPDATE")
        b:fire("GROUP_ROSTER_UPDATE")
        world:advance(2)
    end

    it("is pointed out once: they can group, but not see each other in the queue", function()
        local world = World.new()
        local me = world:addClient("Roos Bieff")
        local other = world:addClient("Mexy Tem")
        other.shard = "2"
        world:advance(CONNECT)
        party(world, me, other)
        local members = me.ns.Party.members
        me.ns.Party.members = function()
            return nil
        end
        world:advance(61)
        me.ns.Party.members = members
        world:advance(359)
        assert.is_false(me:said("Mexy Tem uses Forever Groups"))
        world:advance(120)
        assert.is_true(me:said("Mexy Tem uses Forever Groups but is not on your channel: you can group, but you "
            .. "won't see each other in the queue%."))
        local count = 0
        for _, line in ipairs(me.chat) do
            count = count + (line:find("Mexy Tem uses Forever Groups", 1, true) and 1 or 0)
        end
        world:advance(600)
        local later = 0
        for _, line in ipairs(me.chat) do
            later = later + (line:find("Mexy Tem uses Forever Groups", 1, true) and 1 or 0)
        end
        assert.are.equal(count, later)
    end)

    it("is not pointed out when they went offline but stay in the party", function()
        local world = World.new()
        local me = world:addClient("Roos Bieff")
        local other = world:addClient("Kruugor Deathhowl")
        world:advance(CONNECT)
        party(world, me, other)
        world:advance(120)
        other.env.LeaveChannelByName(other.ns.Comm.CHANNEL)
        other:logout()
        me.offline["Kruugor Deathhowl"] = true
        world:advance(1200)
        assert.is_false(me:said("uses Forever Groups but is not on your channel"))
    end)

    it("is not pointed out when they share the channel", function()
        local world = World.new()
        local me = world:addClient("Roos Bieff")
        local other = world:addClient("Kruugor Deathhowl")
        world:advance(CONNECT)
        party(world, me, other)
        world:advance(900)
        assert.is_true(me.ns.Presence.isOnline("Kruugor Deathhowl"))
        assert.is_false(me:said("uses Forever Groups but is not on your channel"))
    end)
end)

describe("players of an older version", function()
    local function oldPlayer(world)
        local old = world:addClient("Old Player", { version = "0.32.0" })
        old.ns.Comm.CHANNEL = "ForeverGroupsNet"
        local join = old.env.JoinTemporaryChannel
        old.env.JoinTemporaryChannel = function(channel)
            return join(channel)
        end
        old.env.SetChannelPassword = function() end
        return old
    end

    local function newPlayer(world, playerName, released)
        local client = world:addClient(playerName, { version = "0.33.0" })
        if released then
            client.ns.Comm.isDevCopy = function()
                return false
            end
        end
        return client
    end

    it("hear from two released copies in their channel that a newer version runs", function()
        local world = World.new()
        local old = oldPlayer(world)
        world:advance(CONNECT)
        local first = newPlayer(world, "First Player", true)
        local second = newPlayer(world, "Second Player", true)
        world:advance(CONNECT)
        assert.is_true(old:said("Forever Groups 0%.33%.0 is out %(you have 0%.32%.0%)%. Please update"))
        world:advance(10)
        assert.is_nil(first.channels.ForeverGroupsNet)
        assert.is_nil(second.channels.ForeverGroupsNet)
        assert.is_not_nil(first.channels[first.ns.Comm.CHANNEL])
        assert.truthy(first.ns.Diagnostics.report():find("told ForeverGroupsNet that version 0.33.0 runs", 1, true))
    end)

    it("hear nothing from the developer copy", function()
        local world = World.new()
        local old = oldPlayer(world)
        world:advance(CONNECT)
        newPlayer(world, "First Player", false)
        newPlayer(world, "Second Player", false)
        world:advance(CONNECT + 10)
        assert.is_false(old:said("is out"))
        assert.are.equal(1, #world:channel("ForeverGroupsNet").members)
    end)

    it("leaves the old channel also when WoW lets it in only after it gave up", function()
        local world = World.new()
        local client = newPlayer(world, "First Player", true)
        local join = client.env.JoinTemporaryChannel
        client.env.JoinTemporaryChannel = function(channel, password)
            if channel == "ForeverGroupsNet" then
                world:schedule(client, 12, function()
                    join(channel, password)
                end)
                return 0
            end
            return join(channel, password)
        end
        world:advance(30)
        assert.is_not_nil(client.channels.ForeverGroupsNet)
        world:advance(30)
        assert.is_nil(client.channels.ForeverGroupsNet)
        assert.truthy(client.ns.Diagnostics.report():find("could not get into ForeverGroupsNet", 1, true))
    end)
end)
