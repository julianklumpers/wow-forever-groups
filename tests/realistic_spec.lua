local World = require("tests.helpers.wowmock")

-- A leader builds a group from WoW's Group Finder among players who behave as
-- seen in the game: invitees who accept, decline, are already in a group or
-- never answer; members whose Deadly Boss Mods sets their role from their
-- spec after joining and after their /reloads (first DAMAGER, then the
-- spec's role); whisperers of any class who chat ("got ya", ":)"); and the
-- leader's own /reloads. After every second a set of rules must hold.
-- Seeded, so a failure repeats; REALISTIC_SEEDS and REALISTIC_STEPS run more.
local LEADER = "Lay Ohands"
local WOW = { T = "TANK", H = "HEALER", D = "DAMAGER" }
-- Per class: the roles it can list and the role its spec makes it.
local CLASSES = {
    { "WARRIOR", "TD", "T" }, { "PALADIN", "THD", "H" }, { "DRUID", "THD", "T" }, { "SHAMAN", "HD", "H" },
    { "PRIEST", "HD", "H" }, { "HUNTER", "D", "D" }, { "ROGUE", "D", "D" }, { "MAGE", "D", "D" },
    { "WARLOCK", "D", "D" },
}
local CHAT = { "can i join", "dps here! can i join?", "heal?", "tank lf group", "got ya", ":)", "inv pls", "ok" }

local function rng(seed)
    local state = seed
    return function(n)
        state = (state * 1103515245 + 12345) % 2147483648
        return math.floor(state / 65536) % n + 1
    end
end

local function newLeader(world, saved)
    return world:addClient(LEADER, { level = 22, class = "PALADIN", classVariety = true, saved = saved })
end

-- What a reply to a whisperer is: "invite", "no" (role not needed), "class"
-- (class not wanted) or "which" (asks the role).
local function replyKind(text)
    if text:find("Which role do you play", 1, true) then
        return "which"
    elseif text:find("we are not looking for a", 1, true) then
        return "class"
    elseif text:find("we only need", 1, true) then
        return "no"
    end
    return "invite"
end

local function run(seed, steps)
    local roll = rng(seed)
    local world = World.new()
    local listed = {}
    for i = 1, 24 do
        local class = CLASSES[roll(#CLASSES)]
        local roles = roll(3) == 1 and class[2] or class[3]
        local name = string.format("Listed %02d", i)
        world:list(name, roles, 796, 18 + roll(8), roll(900))
        world.listings[#world.listings].class = class[1]
        listed[name] = { class = class[1], spec = class[3], dbm = roll(3) ~= 1 }
    end
    local leader = newLeader(world)
    world:advance(12)
    leader:slash("/dq join tank wc")
    world:advance(2)

    local seen, invitedAs, flips, chats = {}, {}, {}, {}
    local sessionStart = 0
    local whisperers = {}
    for i = 1, 6 do
        whisperers[i] = CLASSES[roll(#CLASSES)][1]
    end
    local function check(step)
        local where = "seed " .. seed .. ", step " .. step .. ": "
        assert(#leader.refusedInvites == 0,
            where .. "invited into a full party: " .. tostring(leader.refusedInvites[1]))
        local now = world.time
        for _, name in ipairs(leader.party) do
            local want = invitedAs[name]
            if want and now - (flips[name] or 0) > 1.5 then
                assert(leader.roles[name] == WOW[want], where .. name .. " was invited as " .. WOW[want]
                    .. " but plays " .. tostring(leader.roles[name]))
            end
        end
        -- Per session: a /reload forgets the conversations, and may ask again.
        local byTarget = {}
        for i = sessionStart + 1, #leader.whispers do
            local w = leader.whispers[i]
            if chats[w.target] then
                byTarget[w.target] = byTarget[w.target] or {}
                table.insert(byTarget[w.target], replyKind(w.text))
            end
        end
        for target, kinds in pairs(byTarget) do
            local told, which, class = false, 0, 0
            for _, kind in ipairs(kinds) do
                if kind == "which" then
                    assert(not told, where .. target .. " was asked their role after being told no")
                    which = which + 1
                elseif kind == "no" then
                    told = true
                elseif kind == "class" then
                    -- A place may open for their class later: then they are
                    -- talked to again.
                    class = class + 1
                end
            end
            assert(which <= 3, where .. target .. " was asked their role " .. which .. " times")
            assert(class <= 3, where .. target .. " was told " .. class .. " times their class is not wanted")
        end
    end

    for step = 1, steps do
        for _, name in ipairs(leader.invites) do
            local player = listed[name]
            if player and not seen[name] then
                seen[name] = true
                invitedAs[name] = leader.ns.Filler.roleOf(name)
                local fate = roll(20)
                local at = 1 + roll(4)
                world:schedule(leader, at, function()
                    if fate <= 10 and #leader.party < 4 then
                        leader.partyClasses[name] = player.class
                        leader:joins(name)
                        if player.dbm then
                            world:schedule(leader, 2, function()
                                flips[name] = world.time
                                leader.roles[name] = "DAMAGER"
                                leader:fire("ROLE_CHANGED_INFORM")
                            end)
                            world:schedule(leader, 2.3, function()
                                flips[name] = world.time
                                leader.roles[name] = WOW[player.spec]
                                leader:fire("ROLE_CHANGED_INFORM")
                            end)
                        end
                    elseif fate <= 13 then
                        leader:system(string.format(leader.env.ERR_DECLINE_GROUP_S, name))
                    elseif fate <= 15 then
                        leader:system(string.format(leader.env.ERR_ALREADY_IN_GROUP_S, name))
                    end
                end)
            end
        end
        local event = roll(30)
        if event <= 3 then
            local number = roll(6)
            local name = "Whisperer " .. number
            chats[name] = true
            leader:whisperFrom(name, CHAT[roll(#CHAT)], whisperers[number])
        elseif event == 4 and #leader.party > 0 then
            local name = leader.party[roll(#leader.party)]
            local player = listed[name]
            if player and player.dbm then
                flips[name] = world.time
                leader.roles[name] = "DAMAGER"
                leader:fire("ROLE_CHANGED_INFORM")
                world:schedule(leader, 0.3, function()
                    flips[name] = world.time
                    leader.roles[name] = WOW[player.spec]
                    leader:fire("ROLE_CHANGED_INFORM")
                end)
            end
        elseif event == 5 and roll(4) == 1 then
            local saved = leader:logout()
            local old = leader
            leader = newLeader(world, saved)
            for _, field in ipairs({ "party", "roles", "partyClasses", "invites", "heldInvites", "answeredInvites",
                "refusedInvites", "whispers" }) do
                leader[field] = old[field]
            end
            leader.isLeader = old.isLeader
            sessionStart = #leader.whispers
            world:advance(8)
            for _, name in ipairs(leader.party) do
                assert(invitedAs[name] == nil or leader.ns.RoleSync.expected(name) == invitedAs[name],
                    "seed " .. seed .. ": " .. name .. "'s role was lost over the leader's /reload")
            end
        end
        world:advance(1)
        check(step)
    end
end

describe("a leader among realistic players", function()
    it("keeps invited roles, never overfills the party and answers whispers sensibly", function()
        local seeds = tonumber(os.getenv("REALISTIC_SEEDS")) or 4
        local steps = tonumber(os.getenv("REALISTIC_STEPS")) or 240
        for seed = 1, seeds do
            run(20261117 + seed, steps)
        end
    end)
end)
