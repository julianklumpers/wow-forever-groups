local Engine = require("core.engine")

local Sim = {}
Sim.__index = Sim

-- Partial groups are off unless a test asks for them, so tests about full
-- groups are not affected by them.
-- extra: more Engine.new options for every client (space, matchmaker).
function Sim.new(config, extra)
    config = config or {}
    if config.PARTIAL_GROUPS == nil then
        config.PARTIAL_GROUPS = false
    end
    return setmetatable({
        now = 1000000,
        clients = {},
        order = {},
        pending = {},
        blocked = {},
        sent = {},
        config = config,
        extra = extra or {},
    }, Sim)
end

function Sim:add(name)
    local client = { name = name, online = true, events = {} }
    client.engine = Engine.new({
        name = name,
        clock = function()
            return self.now
        end,
        send = function(text)
            self:broadcast(name, text)
        end,
        emit = function(event, data)
            client.events[#client.events + 1] = { event = event, data = data }
        end,
        random = function()
            return 0.5
        end,
        config = self.config,
        space = self.extra.space,
        matchmaker = self.extra.matchmaker,
    })
    self.clients[name] = client
    self.order[#self.order + 1] = name
    client.engine:start()
    self:flush()
    return client
end

function Sim:engine(name)
    return self.clients[name].engine
end

function Sim:broadcast(from, text)
    self.sent[#self.sent + 1] = { from = from, text = text, at = self.now }
    for _, name in ipairs(self.order) do
        if name ~= from and not self.blocked[from .. ">" .. name] then
            self.pending[#self.pending + 1] = { from = from, to = name, text = text }
        end
    end
end

function Sim:flush()
    local delivered = 0
    while #self.pending > 0 do
        delivered = delivered + 1
        assert(delivered < 100000, "message storm")
        local msg = table.remove(self.pending, 1)
        local target = self.clients[msg.to]
        if target.online then
            target.engine:receive(msg.from, msg.text)
        end
    end
end

function Sim:advance(seconds)
    for _ = 1, seconds do
        self.now = self.now + 1
        for _, name in ipairs(self.order) do
            local client = self.clients[name]
            if client.online then
                client.engine:tick()
                self:flush()
            end
        end
    end
end

function Sim:join(name, role, dungeons, premade)
    local members = { { name = name, roles = role, level = 60 } }
    for _, member in ipairs(premade or {}) do
        members[#members + 1] = { name = member[1], roles = member[2], level = 60 }
    end
    local ok, err = self:engine(name):join(members, dungeons or { "DM" })
    assert(ok, err)
    self:flush()
end

function Sim:respond(name, accept)
    assert(self:engine(name):respond(accept), name .. " has no open proposal")
    self:flush()
end

function Sim:kill(name)
    self.clients[name].online = false
end

function Sim:partition(a, b)
    self.blocked[a .. ">" .. b] = true
    self.blocked[b .. ">" .. a] = true
end

function Sim:events(name, kind)
    local found = {}
    for _, event in ipairs(self.clients[name].events) do
        if event.event == kind then
            found[#found + 1] = event.data
        end
    end
    return found
end

function Sim:last(name, kind)
    local found = self:events(name, kind)
    return found[#found]
end

function Sim:openProposal(name)
    local engine = self:engine(name)
    local key = engine.myProposalKey
    return key and engine.proposals[key]
end

function Sim.memberNames(_, proposalView)
    local names = {}
    for _, member in ipairs(proposalView.members) do
        names[#names + 1] = member.name
    end
    table.sort(names)
    return names
end

function Sim:acceptAll(names)
    for _, name in ipairs(names) do
        if self:openProposal(name) then
            self:respond(name, true)
        end
    end
end

return Sim
