local _, ns = ...
ns = ns or {}

local Proposal = {}
Proposal.__index = Proposal

function Proposal.key(matchmaker, seq)
    return matchmaker .. "#" .. seq
end

-- entries: list of member lists as sent in the proposal; the first member of
-- each list owns that entry and answers for it.
function Proposal.new(args, config)
    local entries, members = {}, {}
    for i, list in ipairs(args.entries) do
        entries[i] = { id = list[1].name, members = list }
        for _, member in ipairs(list) do
            members[#members + 1] = member
        end
    end
    return setmetatable({
        key = Proposal.key(args.matchmaker, args.seq),
        matchmaker = args.matchmaker,
        seq = args.seq,
        dungeon = args.dungeon,
        missing = args.missing or "",
        playstyles = args.playstyles or {},
        entries = entries,
        members = members,
        leader = entries[1].id,
        answers = {},
        createdAt = args.createdAt or args.now,
        ackDeadline = args.now + config.ACK_TIMEOUT,
        answerDeadline = (args.createdAt or args.now) + config.PROPOSAL_TIMEOUT,
        finalDeadline = (args.createdAt or args.now) + config.PROPOSAL_TIMEOUT + config.PROPOSAL_GRACE,
    }, Proposal)
end

function Proposal:includes(id)
    for _, entry in ipairs(self.entries) do
        if entry.id == id then
            return true
        end
    end
    return false
end

function Proposal:answer(id, answer)
    if self.outcome or not self:includes(id) then
        return false
    end
    local current = self.answers[id]
    if current == "N" or current == "C" or current == answer then
        return false
    end
    if answer == "R" and current == "Y" then
        return false
    end
    self.answers[id] = answer
    return true
end

local function split(self, inRemoved)
    local removed, returned = {}, {}
    for _, entry in ipairs(self.entries) do
        if inRemoved(self.answers[entry.id]) then
            removed[#removed + 1] = entry.id
        else
            returned[#returned + 1] = entry.id
        end
    end
    return removed, returned
end

local function decide(self, now)
    local hasNo, hasConflict, allYes, anySilent = false, false, true, false
    for _, entry in ipairs(self.entries) do
        local answer = self.answers[entry.id]
        hasNo = hasNo or answer == "N"
        hasConflict = hasConflict or answer == "C"
        allYes = allYes and answer == "Y"
        anySilent = anySilent or answer == nil
    end

    if hasNo or hasConflict then
        local removed, returned = split(self, function(a) return a == "N" end)
        return { status = "failed", reason = hasConflict and "conflict" or "declined",
            removed = removed, returned = returned }
    end
    if allYes then
        return { status = "accepted", removed = {}, returned = {} }
    end
    if anySilent and now >= self.ackDeadline then
        local removed, returned = split(self, function(a) return a == nil end)
        return { status = "failed", reason = "unresponsive", removed = removed, returned = returned }
    end
    if now >= self.finalDeadline then
        local removed, returned = split(self, function(a) return a ~= "Y" end)
        return { status = "failed", reason = "timeout", removed = removed, returned = returned }
    end
    return nil
end

-- Returns the outcome once the proposal is decided, nil while pending. Every
-- client evaluates proposals itself, so they resolve without the matchmaker.
function Proposal:evaluate(now)
    if not self.outcome then
        self.outcome = decide(self, now)
        if self.outcome then
            self.finishedAt = now
        end
    end
    return self.outcome
end

ns.Proposal = Proposal
return Proposal
