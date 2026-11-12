-- Only on request (LOAD=1 or any LOAD_* setting): it takes seconds and only
-- prints figures, so the normal test run and CI leave it out.
if not (os.getenv("LOAD") or os.getenv("LOAD_CLIENTS") or os.getenv("LOAD_SECONDS") or os.getenv("LOAD_LOGINS")) then
    return
end

local Engine = require("core.engine")
local Protocol = require("core.protocol")
local Matchmaker = require("core.matchmaker")

-- Measures the channel load of many engines with players logging in and out,
-- reloading and queueing. Prints a report; LOAD_CLIENTS, LOAD_SECONDS,
-- LOAD_LOGINS (logins per second) and LOAD_SEED scale a run.
local CLIENTS = tonumber(os.getenv("LOAD_CLIENTS")) or 80
local SECONDS = tonumber(os.getenv("LOAD_SECONDS")) or 180
local SEED = tonumber(os.getenv("LOAD_SEED")) or 1
local BUSY_LOGINS = tonumber(os.getenv("LOAD_LOGINS")) or 0.7

local ROLES = { "D", "D", "D", "D", "D", "D", "D", "D", "T", "H", "TD", "HD" }
local DUNGEONS = 35

local function rng(seed)
    local state = seed
    return function()
        state = (state * 1103515245 + 12345) % 2147483648
        return state / 2147483648
    end
end

local World = {}
World.__index = World

function World.new(opts)
    local self = setmetatable({
        now = 1000000,
        random = rng(opts.seed),
        clients = {},
        online = {},
        inbox = {},
        head = 1,
        sent = {},
        sentTotal = 0,
        matchTimes = {},
        waits = { T = {}, H = {}, D = {} },
        measuring = false,
        names = 0,
    }, World)
    local world = self
    self.matcher = {
        findGroups = function(entries, slots)
            local started = os.clock()
            local groups = Matchmaker.findGroups(entries, slots)
            world.matchTimes[#world.matchTimes + 1] = { seconds = os.clock() - started, entries = #entries }
            return groups
        end,
        findPartialGroup = Matchmaker.findPartialGroup,
    }
    return self
end

function World:pick(list)
    return list[math.floor(self.random() * #list) + 1]
end

function World:broadcast(from, text)
    local msg = Protocol.decode(text)
    local kind = msg and msg.kind or "?"
    self.sent[kind] = (self.sent[kind] or 0) + 1
    self.sentTotal = self.sentTotal + 1
    for _, name in ipairs(self.online) do
        if name ~= from then
            self.inbox[#self.inbox + 1] = { from = from, to = name, text = text }
        end
    end
end

function World:flush()
    while self.head <= #self.inbox do
        local msg = self.inbox[self.head]
        self.head = self.head + 1
        local client = self.clients[msg.to]
        if client.online then
            client.engine:receive(msg.from, msg.text)
        end
    end
    self.inbox, self.head = {}, 1
end

function World:refreshOnline()
    local online = {}
    for name, client in pairs(self.clients) do
        if client.online then
            online[#online + 1] = name
        end
    end
    table.sort(online)
    self.online = online
end

function World:start(name)
    local client = self.clients[name] or { name = name }
    self.clients[name] = client
    client.online = true
    client.answerAt = nil
    client.engine = Engine.new({
        name = name,
        clock = function()
            return self.now
        end,
        send = function(text)
            self:broadcast(name, text)
        end,
        emit = function(event)
            if event == "groupFormed" and self.measuring and client.joinedAt then
                local role = client.roles:sub(1, 1)
                self.waits[role][#self.waits[role] + 1] = self.now - client.joinedAt
            end
        end,
        random = self.random,
        matchmaker = self.matcher,
    })
    self:refreshOnline()
    client.engine:start()
    self:flush()
    return client
end

function World:newPlayer()
    self.names = self.names + 1
    return self:start(string.format("Player %04d", self.names))
end

function World:logout(name)
    local client = self.clients[name]
    if client.engine.myEntry then
        client.engine:leave()
        self:flush()
    end
    client.online = false
    client.joinedAt = nil
    self:refreshOnline()
end

-- A /reload: the leave from PLAYER_LOGOUT, a fresh engine, and the queue
-- entry restored at its old place.
function World:reload(name)
    local client = self.clients[name]
    local entry = client.engine.myEntry
    self:logout(name)
    self:start(name)
    if entry then
        client.engine:join(entry.members, entry.dungeons, entry.joinedAt)
        client.joinedAt = client.joinedAtFirst
        self:flush()
    end
end

function World:join(client)
    local dungeons, seen = {}, {}
    for _ = 1, math.floor(self.random() * 3) + 1 do
        local id = tostring(math.floor(self.random() * DUNGEONS) + 1)
        if not seen[id] then
            seen[id] = true
            dungeons[#dungeons + 1] = id
        end
    end
    local roles = self:pick(ROLES)
    local ok = client.engine:join({ { name = client.name, roles = roles, level = 60 } }, dungeons)
    if ok then
        client.roles = roles
        client.joinedAt = self.now
        client.joinedAtFirst = self.now
    end
    self:flush()
end

-- Who is in the queue right now, by the clients' own state.
function World:queued()
    local ids = {}
    for _, name in ipairs(self.online) do
        local engine = self.clients[name].engine
        if engine.myEntry and not engine.held then
            ids[#ids + 1] = name
        end
    end
    return ids
end

function World:matchmaker()
    for _, name in ipairs(self.online) do
        if self.clients[name].engine:isMatchmaker() then
            return name
        end
    end
end

function World:tick()
    self.now = self.now + 1
    for _, name in ipairs(self.online) do
        local client = self.clients[name]
        if client.online then
            local engine = client.engine
            local key = engine.myProposalKey
            local proposal = key and engine.proposals[key]
            if proposal and not proposal.outcome and proposal.answers[name] == "R" then
                client.answerAt = client.answerAt or self.now + 2 + math.floor(self.random() * 7)
                if self.now >= client.answerAt then
                    client.answerAt = nil
                    engine:respond(self.random() > 0.1)
                end
            end
            engine:tick()
            self:flush()
        end
    end
end

local function median(list)
    if #list == 0 then
        return nil
    end
    local sorted = { unpack(list) }
    table.sort(sorted)
    return sorted[math.ceil(#sorted / 2)]
end

local function maximum(list)
    local best
    for _, value in ipairs(list) do
        best = best and math.max(best, value) or value
    end
    return best
end

-- Starts a measurement of how long a client takes to see every entry that
-- was queued when it started.
local function watchView(world, name, label)
    local expected = {}
    for _, id in ipairs(world:queued()) do
        if id ~= name then
            expected[id] = true
        end
    end
    return { name = name, label = label, startedAt = world.now, expected = expected }
end

local function viewComplete(world, watch)
    local engine = world.clients[watch.name].engine
    for id in pairs(watch.expected) do
        local still = world.clients[id].online and world.clients[id].engine.myEntry
            and not world.clients[id].engine.held
        if still and not engine.queue:get(id) then
            return false
        end
    end
    return true
end

local function run(label, loginsPerSecond)
    local world = World.new({ seed = SEED })
    for _ = 1, CLIENTS do
        world:newPlayer()
    end
    for _, name in ipairs(world.online) do
        if world.random() < 0.6 then
            world:join(world.clients[name])
        end
    end

    local warmup = 60
    local stats = { queuedSum = 0, samples = 0, logins = 0, reloads = 0 }
    local waits = world.waits
    local views, watches = {}, {}
    local loginCredit = 0
    local matchmakerReloadAt = warmup + math.floor(SECONDS / 2)

    for second = 1, warmup + SECONDS do
        if second == warmup + 1 then
            world.sent, world.sentTotal, world.matchTimes = {}, 0, {}
            world.measuring = true
        end
        local measuring = second > warmup

        loginCredit = loginCredit + loginsPerSecond
        while loginCredit >= 1 do
            loginCredit = loginCredit - 1
            local name = world:pick(world.online)
            if world.random() < 0.3 and world.clients[name].engine.myEntry then
                world:reload(name)
                stats.reloads = stats.reloads + (measuring and 1 or 0)
            else
                world:logout(name)
                local client = world:newPlayer()
                stats.logins = stats.logins + (measuring and 1 or 0)
                if measuring then
                    watches[#watches + 1] = watchView(world, client.name, "newcomer")
                end
            end
        end
        if second == matchmakerReloadAt then
            local name = world:matchmaker()
            if name then
                world:reload(name)
                watches[#watches + 1] = watchView(world, name, "matchmaker")
            end
        end

        for _, name in ipairs(world.online) do
            local client = world.clients[name]
            local engine = client.engine
            if not engine.myEntry and world.random() < 1 / 90 then
                world:join(client)
            elseif engine.myEntry and not engine.myProposalKey and world.random() < 1 / 900 then
                engine:leave()
                world:flush()
            end
        end

        world:tick()

        local remaining = {}
        for _, watch in ipairs(watches) do
            if world.clients[watch.name].online and viewComplete(world, watch) then
                views[watch.label] = views[watch.label] or {}
                table.insert(views[watch.label], world.now - watch.startedAt)
            elseif world.clients[watch.name].online then
                remaining[#remaining + 1] = watch
            end
        end
        watches = remaining

        if measuring then
            stats.queuedSum = stats.queuedSum + #world:queued()
            stats.samples = stats.samples + 1
        end
    end

    stats.groups = #waits.T + #waits.H + #waits.D
    local queued = stats.queuedSum / stats.samples
    local perSecond = world.sentTotal / SECONDS
    local queueMsgs = (world.sent.queue or 0) / SECONDS
    local perQueuedPerMinute = queueMsgs / queued * 60
    local lines = {
        string.format("== %s: %d clients, %d s, %.2f logins+reloads/s (seed %d) ==", label, CLIENTS, SECONDS,
            loginsPerSecond, SEED),
        string.format("queued on average: %.0f; logins %d, reloads %d, players placed in a group %d", queued,
            stats.logins, stats.reloads, stats.groups),
        string.format("channel messages: %.1f/s total", perSecond),
    }
    local kinds = {}
    for kind in pairs(world.sent) do
        kinds[#kinds + 1] = kind
    end
    table.sort(kinds)
    for _, kind in ipairs(kinds) do
        lines[#lines + 1] = string.format("  %-8s %7.2f/s", kind, world.sent[kind] / SECONDS)
    end
    lines[#lines + 1] = string.format(
        "queue entries per queued player: %.2f/min (a heartbeat every 45 s alone is 1.33/min)", perQueuedPerMinute)
    lines[#lines + 1] = string.format("  -> with 1000 queued: ~%.0f queue messages/s", perQueuedPerMinute * 1000 / 60)
    for _, key in ipairs({ "newcomer", "matchmaker" }) do
        local list = views[key]
        if list then
            lines[#lines + 1] = string.format("%s sees the whole queue after: median %d s, max %d s (%d measured)",
                key, median(list), maximum(list), #list)
        end
    end
    for _, role in ipairs({ "T", "H", "D" }) do
        if #waits[role] > 0 then
            lines[#lines + 1] = string.format("wait until in a group, first role %s: median %d s, max %d s (%d)",
                role, median(waits[role]), maximum(waits[role]), #waits[role])
        end
    end
    local slowest = { seconds = 0, entries = 0 }
    local total = 0
    for _, t in ipairs(world.matchTimes) do
        total = total + t.seconds
        if t.seconds > slowest.seconds then
            slowest = t
        end
    end
    lines[#lines + 1] = string.format("findGroups: %d runs, average %.1f ms, slowest %.1f ms (%d entries)",
        #world.matchTimes, #world.matchTimes > 0 and total / #world.matchTimes * 1000 or 0,
        slowest.seconds * 1000, slowest.entries)
    print("\n" .. table.concat(lines, "\n"))
    return { perQueuedPerMinute = perQueuedPerMinute, groups = stats.groups, views = views }
end

local function matchmakerTime(size, roles)
    local random = rng(SEED)
    local entries = {}
    for i = 1, size do
        local dungeons = {}
        for k = 1, math.floor(random() * 4) + 1 do
            dungeons[k] = tostring(math.floor(random() * DUNGEONS) + 1)
        end
        entries[i] = {
            id = "P" .. i, joinedAt = math.floor(random() * 600), dungeons = dungeons, reserved = "",
            members = { { name = "P" .. i, roles = roles[math.floor(random() * #roles) + 1] } },
            playstyle = math.floor(random() * 4) + 1,
        }
    end
    local started = os.clock()
    local groups = Matchmaker.findGroups(entries)
    return os.clock() - started, #groups
end

describe("load", function()
    it("measures the matchmaker on large queues", function()
        local lines = { "", "== findGroups on one large queue ==" }
        local mixes = {
            { "mixed roles", { "D", "D", "D", "D", "D", "D", "T", "H", "TD", "HD", "D", "D" } },
            { "mostly DPS", { "D", "D", "D", "D", "D", "D", "D", "D", "D", "D", "D", "D", "D", "D", "D", "T", "H" } },
        }
        for _, mix in ipairs(mixes) do
            for _, size in ipairs({ 250, 500, 1000 }) do
                local seconds, groups = matchmakerTime(size, mix[2])
                lines[#lines + 1] = string.format("%-12s %5d queued: %7.1f ms, %d groups", mix[1], size,
                    seconds * 1000, groups)
            end
        end
        print(table.concat(lines, "\n"))
    end)

    it("measures a quiet realm", function()
        local result = run("quiet", 0.05)
        assert.is_true(result.groups > 0)
    end)

    it("measures a busy realm (logins as with ~5000 online)", function()
        local result = run("busy", BUSY_LOGINS)
        assert.is_true(result.groups > 0)
    end)
end)
