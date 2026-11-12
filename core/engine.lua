local _, ns = ...
ns = ns or {}

local Config = ns.Config or require("core.config")
local Protocol = ns.Protocol or require("core.protocol")
local Queue = ns.Queue or require("core.queue")
local Matchmaker = ns.Matchmaker or require("core.matchmaker")
local Election = ns.Election or require("core.election")
local Proposal = ns.Proposal or require("core.proposal")
local Roles = ns.Roles or require("core.roles")
local Playstyles = ns.Playstyles or require("core.playstyles")

local Engine = {}
Engine.__index = Engine

-- opts.name    full player name ("Name-Realm"), must match incoming senders
-- opts.clock   function() -> seconds; server time, shared by all clients
-- opts.send    function(text) broadcasting on the shared channel
-- opts.emit    function(event, data) for the UI layer (optional)
-- opts.random  function() -> [0, 1) (optional)
-- opts.config  overrides for core.config (optional)
-- opts.playstyle  core/playstyles.lua id for the own entries (optional)
-- opts.space   Protocol.QUESTS for the questing queue (optional)
-- opts.lastSent  function() -> when this client last sent anything (optional);
--              a keep-alive is skipped while that is recent
-- opts.matchmaker  module with findGroups/findPartialGroup (optional)
function Engine.new(opts)
    assert(Protocol.isValidName(opts.name), "invalid name")
    local config = Config.with(opts.config)
    local self = setmetatable({
        name = opts.name,
        clock = opts.clock,
        sendText = opts.send,
        emitEvent = opts.emit or function() end,
        random = opts.random or math.random,
        config = config,
        queue = Queue.new(config.ENTRY_TIMEOUT),
        proposals = {},
        reservations = {},
        myEntry = nil,
        myProposalKey = nil,
        seqCounter = 0,
        fakes = {},
        fakeAnswers = {},
        playstyle = opts.playstyle or Playstyles.ANY,
        spec = opts.spec,
        lastSent = opts.lastSent,
        space = opts.space,
        matcher = opts.matchmaker or Matchmaker,
        held = false,
    }, Engine)
    self.startedAt = self.clock()
    self.lastMatchAt = -math.huge
    return self
end

function Engine:now()
    return self.clock()
end

function Engine:emit(event, data)
    self.emitEvent(event, data or {})
end

function Engine:send(msg)
    local text, err = Protocol.encode(msg, self.space)
    if not text then
        self:emit("error", { message = "encode " .. tostring(msg.kind) .. ": " .. tostring(err) })
        return false
    end
    self.sendText(text)
    return true
end

-- announce = false when the caller already broadcast a sync request.
function Engine:start(announce)
    self.startedAt = self:now()
    if announce ~= false then
        self:send({ kind = "sync" })
    end
end

local function copyMembers(members)
    local copy = {}
    for i, member in ipairs(members) do
        copy[i] = { name = member.name, roles = Roles.normalize(member.roles) or member.roles, level = member.level }
    end
    return copy
end

-- members: own player first, then premade party members.
local function heartbeatMessage(entry)
    return {
        kind = "queue", joinedAt = entry.joinedAt, dungeons = entry.dungeons, members = entry.members,
        reserved = entry.reserved, since = entry.since, playstyle = entry.playstyle, spec = entry.spec,
    }
end

-- joinedAt (optional) restores an earlier queue position, e.g. after /reload.
function Engine:join(members, dungeons, joinedAt)
    if self.myEntry then
        return false, "already queued"
    end
    local now = math.floor(self:now())
    if type(joinedAt) ~= "number" or joinedAt > now then
        joinedAt = now
    end
    local entry = {
        id = self.name,
        joinedAt = math.floor(joinedAt),
        since = math.floor(self.startedAt),
        dungeons = dungeons,
        members = copyMembers(members),
        playstyle = self.playstyle,
        spec = self.spec,
    }
    if not entry.members[1] or entry.members[1].name ~= self.name then
        return false, "first member must be the player"
    end
    local ok, err = Protocol.validateEntry(entry, self.space)
    if not ok then
        return false, err
    end
    local encoded, encodeErr = Protocol.encode(heartbeatMessage(entry), self.space)
    if not encoded then
        return false, encodeErr
    end
    self.myEntry = entry
    self:publish()
    self:emit("queueJoined", { joinedAt = entry.joinedAt })
    return true
end

-- Changes the party or the roles reserved for Group Finder players while
-- keeping the place in the queue. Refused while a proposal is open.
function Engine:updateEntry(members, reserved, dungeons)
    local current = self.myEntry
    if not current then
        return false, "not queued"
    end
    local proposal = self.myProposalKey and self.proposals[self.myProposalKey]
    if proposal and not proposal.outcome then
        return false, "proposal open"
    end
    local entry = {
        id = self.name, joinedAt = current.joinedAt, dungeons = dungeons or current.dungeons,
        members = copyMembers(members), reserved = reserved or "", since = current.since,
        playstyle = self.playstyle, spec = self.spec,
    }
    if not entry.members[1] or entry.members[1].name ~= self.name then
        return false, "first member must be the player"
    end
    local ok, err = Protocol.validateEntry(entry, self.space)
    if not ok then
        return false, err
    end
    if not Protocol.encode(heartbeatMessage(entry), self.space) then
        return false, "message too long"
    end
    self.myEntry = entry
    self:publish()
    return true
end

-- The playstyle for the next queue entry; a queued entry changes right away.
function Engine:setPlaystyle(playstyle)
    self.playstyle = playstyle
    local entry = self.myEntry
    if entry and entry.playstyle ~= playstyle then
        local before = entry.playstyle
        entry.playstyle = playstyle
        if not Protocol.encode(heartbeatMessage(entry), self.space) then
            entry.playstyle = before
            self:emit("error", {
                message = "the new playstyle does not fit in the queue message; it applies next time",
            })
            return
        end
        self:publish()
    end
end

-- The player's spec code for the queue entry ("SHAMAN2"); a queued entry
-- changes right away when it still fits in the message.
function Engine:setSpec(spec)
    self.spec = spec
    local entry = self.myEntry
    if entry and entry.spec ~= spec then
        local before = entry.spec
        entry.spec = spec
        if not Protocol.encode(heartbeatMessage(entry), self.space) then
            entry.spec = before
            return
        end
        self:publish()
    end
end

-- Puts the own entry in the local queue and tells the others, unless held.
function Engine:publish()
    if self.held then
        return
    end
    self.queue:upsert(self.myEntry, self:now())
    self:sendHeartbeat()
end

-- While the player's other queue has a group proposal for them, this queue
-- steps out (the others see a leave) and keeps the entry, so it comes back
-- at the same place if that proposal fails.
function Engine:setHeld(held)
    if self.held == held then
        return
    end
    self.held = held
    if not self.myEntry then
        return
    end
    if held then
        self:withdrawFromProposal()
        self.queue:remove(self.name)
        self:send({ kind = "leave" })
    else
        self:publish()
    end
end

function Engine:sendHeartbeat()
    local entry = self.myEntry
    self.nextHeartbeatAt = self:now() + self.config.HEARTBEAT_INTERVAL
    self.queue:touch(entry.id, self:now())
    self.nextAliveAt = self:now() + self.config.ALIVE_INTERVAL
    self:send(heartbeatMessage(entry))
end

function Engine:clearMyEntry(reason)
    if not self.myEntry then
        return
    end
    self.myEntry = nil
    self.myProposalKey = nil
    self.queue:remove(self.name)
    self:emit("queueLeft", { reason = reason })
end

-- reason: "left" when the player chose to leave (the default), anything
-- else when the addon took them out (their party changed, for example).
function Engine:leave(reason)
    if not self.myEntry then
        return false
    end
    local proposal = self.myProposalKey and self.proposals[self.myProposalKey]
    if proposal and not proposal.outcome then
        self:sendAnswer(proposal, "N")
        self.myProposalKey = nil
        self:emit("proposalEnded", { key = proposal.key, result = "left" })
    end
    self:send({ kind = "leave" })
    self:clearMyEntry(reason or "left")
    self:resolveProposals()
    return true
end

-- Our party changed while a proposal was open: answer it with a conflict so
-- nobody loses their place, and the group is not formed with the old party.
function Engine:withdrawFromProposal()
    local proposal = self.myProposalKey and self.proposals[self.myProposalKey]
    if not proposal or proposal.outcome then
        return false
    end
    self:sendAnswer(proposal, "C")
    self:resolveProposals()
    return true
end

function Engine:sendAnswer(proposal, answer)
    if not proposal.isLocal then
        self:send({ kind = "answer", matchmaker = proposal.matchmaker, seq = proposal.seq, answer = answer })
    end
    proposal:answer(self.name, answer)
    self:notifyProposal(proposal)
end

function Engine:respond(accept)
    local proposal = self.myProposalKey and self.proposals[self.myProposalKey]
    if not proposal or proposal.outcome then
        return false
    end
    self:sendAnswer(proposal, accept and "Y" or "N")
    self:resolveProposals()
    return true
end

function Engine:isReserved(id)
    local keys = self.reservations[id]
    return keys ~= nil and next(keys) ~= nil
end

function Engine:reserve(proposal)
    for _, entry in ipairs(proposal.entries) do
        self.reservations[entry.id] = self.reservations[entry.id] or {}
        self.reservations[entry.id][proposal.key] = true
    end
end

function Engine:release(proposal)
    for _, entry in ipairs(proposal.entries) do
        local keys = self.reservations[entry.id]
        if keys then
            keys[proposal.key] = nil
            if next(keys) == nil then
                self.reservations[entry.id] = nil
            end
        end
    end
end

local function proposalView(proposal, fakes)
    local members = {}
    for _, entry in ipairs(proposal.entries) do
        for _, member in ipairs(entry.members) do
            members[#members + 1] = {
                name = member.name, role = member.role, owner = entry.id, answer = proposal.answers[entry.id],
                fake = fakes[entry.id] == true,
                spec = member.name == entry.id and proposal.specs[entry.id] or nil,
            }
        end
    end
    return {
        key = proposal.key,
        dungeon = proposal.dungeon,
        leader = proposal.leader,
        matchmaker = proposal.matchmaker,
        members = members,
        missing = proposal.missing,
        playstyles = proposal.playstyles,
        deadline = proposal.answerDeadline,
    }
end

function Engine:notifyProposal(proposal)
    if proposal.key == self.myProposalKey and not proposal.outcome then
        self:emit("proposalUpdated", proposalView(proposal, self.fakes))
    end
end

function Engine:acceptProposalForMe(proposal)
    self.myProposalKey = proposal.key
    self:sendAnswer(proposal, "R")
    self:emit("proposal", proposalView(proposal, self.fakes))
end

-- Whether the proposal was built from the current version of our entry:
-- the same players, each in a role they can play, and room for the roles we
-- reserved for Group Finder invites.
function Engine:proposalFitsMyEntry(proposal)
    local mine = self.myEntry
    local listed
    for _, entry in ipairs(proposal.entries) do
        if entry.id == self.name then
            listed = entry.members
        end
    end
    if not listed or #listed ~= #mine.members then
        return false
    end
    local roles = {}
    for _, member in ipairs(mine.members) do
        roles[member.name] = member.roles
    end
    for _, member in ipairs(listed) do
        if not roles[member.name] or not Roles.has(roles[member.name], member.role) then
            return false
        end
    end
    for _, style in ipairs(proposal.playstyles) do
        if not Playstyles.compatible(style, mine.playstyle) then
            return false
        end
    end
    for _, entry in ipairs(proposal.entries) do
        local known = self.queue:get(entry.id)
        if known and not Playstyles.compatible(known.playstyle, mine.playstyle) then
            return false
        end
    end
    local missing = proposal.missing or ""
    for letter in string.gmatch(mine.reserved or "", ".") do
        local at = string.find(missing, letter, 1, true)
        if not at then
            return false
        end
        missing = string.sub(missing, 1, at - 1) .. string.sub(missing, at + 1)
    end
    return true
end

function Engine:handleOwnInvolvement(proposal)
    if not self.myEntry then
        self:sendAnswer(proposal, "N")
        return
    end
    if self.held then
        self:sendAnswer(proposal, "C")
        return
    end
    if not self:proposalFitsMyEntry(proposal) then
        self:sendAnswer(proposal, "C")
        self:sendHeartbeat()
        return
    end
    local current = self.myProposalKey and self.proposals[self.myProposalKey]
    if not current or current.outcome then
        self:acceptProposalForMe(proposal)
        return
    end
    local wins = Election.proposalWins(proposal, current, self:sinceOf(proposal.matchmaker),
        self:sinceOf(current.matchmaker))
    if wins then
        self:sendAnswer(current, "C")
        self:emit("proposalEnded", { key = current.key, result = "superseded" })
        self:acceptProposalForMe(proposal)
    else
        self:sendAnswer(proposal, "C")
    end
end

-- Fakes confirm at once and answer after 1-3 s; the next-behaviour switch set
-- by setFakeBehavior applies to the first fake of the next proposal only.
function Engine:scheduleFakeAnswers(proposal)
    local now = self:now()
    for _, entry in ipairs(proposal.entries) do
        if self.fakes[entry.id] then
            proposal:answer(entry.id, "R")
            local behavior = self.fakeNext or "accept"
            self.fakeNext = nil
            if behavior ~= "afk" then
                self.fakeAnswers[#self.fakeAnswers + 1] = {
                    key = proposal.key, id = entry.id, at = now + 1 + self.random() * 2,
                    answer = behavior == "decline" and "N" or "Y",
                }
            end
        end
    end
    self:notifyProposal(proposal)
end

function Engine:addProposal(matchmaker, msg, isLocal)
    local key = Proposal.key(matchmaker, msg.seq)
    if self.proposals[key] then
        return
    end
    local now = self:now()
    local proposal = Proposal.new({
        matchmaker = matchmaker, seq = msg.seq, dungeon = msg.dungeon, entries = msg.entries, missing = msg.missing,
        playstyles = msg.playstyles, now = now, createdAt = Engine.createdAt(msg.seq, now, self.config),
    }, self.config)
    proposal.isLocal = isLocal == true
    proposal.msg = msg
    -- The specs the entry owners sent with their entries, kept for the popup
    -- and the formed group (the entries leave the queue once it forms).
    proposal.specs = {}
    for _, entry in ipairs(proposal.entries) do
        local queued = self.queue:get(entry.id)
        proposal.specs[entry.id] = queued and queued.spec or (entry.id == self.name and self.spec) or nil
    end
    self.proposals[key] = proposal
    self:reserve(proposal)
    if proposal:includes(self.name) then
        self:handleOwnInvolvement(proposal)
    end
    if proposal.isLocal then
        self:scheduleFakeAnswers(proposal)
    end
    self:resolveProposals()
end

function Engine:finishProposal(proposal, outcome)
    self:release(proposal)
    local mine = self.myProposalKey == proposal.key
    if outcome.status == "accepted" then
        for _, entry in ipairs(proposal.entries) do
            self.queue:remove(entry.id)
        end
        if mine then
            local joinedAt = self.myEntry and self.myEntry.joinedAt
            self.myEntry = nil
            self.myProposalKey = nil
            self:send({ kind = "leave" })
            self:emit("proposalEnded", { key = proposal.key, result = "accepted" })
            local view = proposalView(proposal, self.fakes)
            view.isLeader = proposal.leader == self.name
            view.joinedAt = joinedAt
            self:emit("groupFormed", view)
        end
        return
    end

    local removedMe = false
    for _, id in ipairs(outcome.removed) do
        if id == self.name then
            removedMe = true
        else
            self.queue:remove(id)
        end
    end
    if mine then
        self.myProposalKey = nil
        if removedMe and self.myEntry then
            local reason = proposal.timedOut and "timeout" or outcome.reason
            self:send({ kind = "leave" })
            self:emit("proposalEnded", { key = proposal.key, result = "removed", reason = reason })
            self:clearMyEntry(reason)
        elseif self.myEntry then
            self:emit("proposalEnded", { key = proposal.key, result = "requeued", reason = outcome.reason })
        end
    end
end

function Engine:resolveProposals()
    local now = self:now()
    local keys = {}
    for key in pairs(self.proposals) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local proposal = self.proposals[key]
        if not proposal.outcome then
            local outcome = proposal:evaluate(now)
            if outcome then
                self:finishProposal(proposal, outcome)
            end
        elseif now - proposal.finishedAt > self.config.FINISHED_RETENTION then
            self.proposals[key] = nil
        end
    end
end

local handlers = {}

function handlers.queue(self, sender, msg)
    if msg.members[1].name ~= sender then
        return
    end
    local since = msg.since
    if not since or since > self:now() then
        since = msg.joinedAt
    end
    self.queue:upsert({
        id = sender, joinedAt = msg.joinedAt, dungeons = msg.dungeons, members = msg.members, reserved = msg.reserved,
        since = since, playstyle = msg.playstyle, spec = msg.spec,
    }, self:now())
end

function handlers.alive(self, sender)
    self.queue:touch(sender, self:now())
end

function handlers.leave(self, sender)
    self.queue:remove(sender)
    for _, proposal in pairs(self.proposals) do
        if not proposal.outcome then
            proposal:answer(sender, "N")
        end
    end
    self:resolveProposals()
end

-- A newcomer asked for the state: re-send the own entry, and the open
-- proposals this client made or answered, so the newcomer knows who is
-- already reserved.
function handlers.sync(self)
    if self.myEntry and not self.held then
        local at = self:now() + self.random() * self.config.SYNC_JITTER
        if not self.nextHeartbeatAt or at < self.nextHeartbeatAt then
            self.nextHeartbeatAt = at
        end
        self.resyncAt = at
    end
end

function Engine:resendOpenProposals()
    for _, proposal in pairs(self.proposals) do
        if not proposal.outcome and not proposal.isLocal then
            if proposal.matchmaker == self.name and proposal.msg then
                self:send(proposal.msg)
            end
            local answer = proposal.answers[self.name]
            if answer then
                self:send({ kind = "answer", matchmaker = proposal.matchmaker, seq = proposal.seq, answer = answer })
            end
        end
    end
end

function handlers.propose(self, sender, msg)
    self.queue:touch(sender, self:now())
    self:addProposal(sender, msg)
end

function handlers.answer(self, sender, msg)
    self.queue:touch(sender, self:now())
    local proposal = self.proposals[Proposal.key(msg.matchmaker, msg.seq)]
    if proposal and proposal:answer(sender, msg.answer) then
        self:notifyProposal(proposal)
        self:resolveProposals()
    end
end

-- Drops everything a sender put in: its queue entry, and its place in open
-- proposals (as if it left).
function Engine:forget(sender)
    if sender ~= self.name then
        handlers.leave(self, sender)
    end
end

-- sender must be normalized to the same "Name-Realm" form as opts.name.
function Engine:receive(sender, text)
    if sender == self.name then
        return
    end
    local msg = Protocol.decode(text, self.space)
    if not msg or not Protocol.isValidName(sender) or not handlers[msg.kind] then
        return
    end
    handlers[msg.kind](self, sender, msg)
end

function Engine:sinceOf(id)
    local entry = self.queue:get(id)
    return entry and entry.since
end

-- Queued real players, longest online first.
function Engine:candidates()
    local list = {}
    for _, id in ipairs(self.queue:ids()) do
        if not self.fakes[id] then
            list[#list + 1] = { id = id, since = self:sinceOf(id) }
        end
    end
    table.sort(list, Election.before)
    local names = {}
    for i, candidate in ipairs(list) do
        names[i] = candidate.id
    end
    return names
end

-- The first few candidates send keep-alives; one of them that went silent is
-- presumed gone long before its queue entry expires, so the next one takes
-- over within ALIVE_TIMEOUT seconds.
function Engine:isSilent(id, rank, now)
    if id == self.name or rank > self.config.ALIVE_RANKS then
        return false
    end
    local entry = self.queue:get(id)
    return entry ~= nil and now - entry.lastSeen > self.config.ALIVE_TIMEOUT
end

function Engine:matchmaker()
    local now = self:now()
    for rank, id in ipairs(self:candidates()) do
        if not self:isSilent(id, rank, now) then
            return id
        end
    end
    return nil
end

function Engine:myRank()
    for rank, id in ipairs(self:candidates()) do
        if id == self.name then
            return rank
        end
    end
end

function Engine:isMatchmaker()
    return self.myEntry ~= nil and self:matchmaker() == self.name
end

-- The matchmaker's clock when it made the proposal, read from the sequence
-- number (seconds * 1000 + counter), so every client counts the 30 s from the
-- same moment even when the proposal reached them late. Ignored when it
-- does not look like a recent server time.
function Engine.createdAt(seq, now, config)
    local created = math.floor((tonumber(seq) or 0) / 1000)
    if created <= now and now - created <= config.PROPOSAL_TIMEOUT then
        return created
    end
    return nil
end

function Engine:nextSeq()
    self.seqCounter = (self.seqCounter + 1) % 1000
    return math.floor(self:now()) * 1000 + self.seqCounter
end

function Engine:proposeGroup(group, isLocal)
    local msg = {
        kind = "propose", seq = self:nextSeq(), dungeon = group.dungeon, entries = group.assigned,
        missing = group.missing, playstyles = group.playstyles,
    }
    if isLocal then
        if Protocol.encode(msg, self.space) then
            self:addProposal(self.name, msg, true)
        end
    elseif self:send(msg) then
        self:addProposal(self.name, msg)
    end
end

local function summarize(label, available, groups)
    local supply = { T = 0, H = 0, D = 0 }
    for _, entry in ipairs(available) do
        local s = Roles.supply(entry.members)
        supply.T, supply.H, supply.D = supply.T + s.T, supply.H + s.H, supply.D + s.D
    end
    return string.format("%s: %d waiting (can tank %d, heal %d, DPS %d) -> %d group(s)",
        label, #available, supply.T, supply.H, supply.D, #groups)
end

-- Real players are matched by the matchmaker only. Fake test players are
-- matched locally, and only into a group with this player, so a proposal
-- never mixes them with real players who would not know them.
function Engine:runMatchmaking()
    local summaries = {}
    if self:isMatchmaker() then
        local real, silent = {}, {}
        local now = self:now()
        for rank, id in ipairs(self:candidates()) do
            silent[id] = self:isSilent(id, rank, now)
        end
        for _, entry in ipairs(self.queue:list()) do
            if not self:isReserved(entry.id) and not self.fakes[entry.id] and not silent[entry.id] then
                real[#real + 1] = entry
            end
        end
        local groups = self.matcher.findGroups(real, self.config.SLOTS)
        for _, group in ipairs(groups) do
            self:proposeGroup(group, false)
        end
        if #groups == 0 then
            local partial = self:findPartial(real)
            if partial then
                self:proposeGroup(partial, false)
                groups = { partial }
            end
        end
        summaries[#summaries + 1] = summarize("players", real, groups)
    end
    if self.myEntry and next(self.fakes) and not self:isReserved(self.name) then
        -- The player anchors the search: fakes added earlier waited longer
        -- and would otherwise fill groups among themselves first.
        local own = {}
        for key, value in pairs(self.queue:get(self.name) or self.myEntry) do
            own[key] = value
        end
        own.joinedAt = 0
        local pool = { own }
        for _, entry in ipairs(self.queue:list()) do
            if self.fakes[entry.id] and not self:isReserved(entry.id) then
                pool[#pool + 1] = entry
            end
        end
        local mine = {}
        for _, group in ipairs(self.matcher.findGroups(pool, self.config.SLOTS)) do
            if self:groupIncludesMe(group) then
                mine[#mine + 1] = group
            end
        end
        if not mine[1] then
            local partial = self:findPartial(pool)
            if partial and partial.entries[1] and self:groupIncludesMe(partial) then
                mine[1] = partial
            end
        end
        if mine[1] then
            self:proposeGroup(mine[1], true)
        end
        summaries[#summaries + 1] = summarize("you + fakes", pool, mine)
    end
    local text = table.concat(summaries, "; ")
    if text ~= "" and text ~= self.lastMatchSummary then
        self.lastMatchSummary = text
        self:emit("matchInfo", { text = text })
    end
end

function Engine:findPartial(entries)
    local config = self.config
    if not config.PARTIAL_GROUPS then
        return nil
    end
    return self.matcher.findPartialGroup(entries, config.SLOTS, self:now(), config.PARTIAL_AFTER,
        config.PARTIAL_MIN_PLAYERS)
end

function Engine:groupIncludesMe(group)
    for _, entry in ipairs(group.entries) do
        if entry.id == self.name then
            return true
        end
    end
    return false
end

function Engine:addFake(members, dungeons)
    local entry = {
        id = members[1].name, joinedAt = math.floor(self:now()), dungeons = dungeons, members = copyMembers(members),
    }
    if self.queue:get(entry.id) then
        return false, "name already in the queue"
    end
    local ok, err = Protocol.validateEntry(entry, self.space)
    if not ok then
        return false, err
    end
    self.queue:upsert(entry, self:now())
    self.fakes[entry.id] = true
    return true
end

function Engine:clearFakes()
    local count = 0
    for id in pairs(self.fakes) do
        self.queue:remove(id)
        count = count + 1
    end
    self.fakes = {}
    return count
end

-- "decline" or "afk" for the first fake in the next proposal.
function Engine:setFakeBehavior(behavior)
    self.fakeNext = behavior
end

function Engine:processFakes(now)
    for id in pairs(self.fakes) do
        if self.queue:get(id) then
            self.queue:touch(id, now)
        else
            self.fakes[id] = nil
        end
    end
    local pending = {}
    for _, item in ipairs(self.fakeAnswers) do
        if now >= item.at then
            local proposal = self.proposals[item.key]
            if proposal and proposal:answer(item.id, item.answer) then
                self:notifyProposal(proposal)
            end
        else
            pending[#pending + 1] = item
        end
    end
    self.fakeAnswers = pending
end

function Engine:tick()
    local now = self:now()
    local active = self.myEntry and not self.held
    if active and now >= self.nextHeartbeatAt then
        self:sendHeartbeat()
    elseif active and now >= (self.nextAliveAt or 0)
        and (self:myRank() or math.huge) <= self.config.ALIVE_RANKS then
        self.queue:touch(self.name, now)
        local last = self.lastSent and self.lastSent()
        if last and now - last < self.config.ALIVE_INTERVAL then
            -- Any message of this client (the other queue's too) already
            -- told the others it is alive.
            self.nextAliveAt = last + self.config.ALIVE_INTERVAL
        else
            self.nextAliveAt = now + self.config.ALIVE_INTERVAL
            self:send({ kind = "alive" })
        end
    end
    if self.resyncAt and now >= self.resyncAt then
        self.resyncAt = nil
        self:resendOpenProposals()
    end
    for _, id in ipairs(self.queue:expire(now, self.myEntry and self.name)) do
        self:emit("entryExpired", { id = id })
    end

    self:processFakes(now)
    local proposal = self.myProposalKey and self.proposals[self.myProposalKey]
    if proposal and not proposal.outcome and now >= proposal.answerDeadline
        and proposal.answers[self.name] ~= "Y" then
        proposal.timedOut = true
        self:respond(false)
    end
    self:resolveProposals()

    if (self:isMatchmaker() or (self.myEntry and next(self.fakes)))
        and now - self.startedAt >= self.config.WARMUP
        and now - self.lastMatchAt >= self.config.MATCH_INTERVAL then
        self.lastMatchAt = now
        self:runMatchmaking()
    end
end

function Engine:snapshot()
    local counts = { T = 0, H = 0, D = 0 }
    local entries = self.queue:list()
    for _, entry in ipairs(entries) do
        local supply = Roles.supply(entry.members)
        for role, n in pairs(supply) do
            counts[role] = counts[role] + n
        end
    end
    return {
        queued = self.myEntry ~= nil,
        joinedAt = self.myEntry and self.myEntry.joinedAt,
        matchmaker = self:matchmaker(),
        isMatchmaker = self:isMatchmaker(),
        proposal = self.myProposalKey,
        roleCounts = counts,
        fakes = self.fakes,
        entries = entries,
    }
end

ns.Engine = Engine
return Engine
