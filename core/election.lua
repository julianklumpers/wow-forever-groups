local _, ns = ...
ns = ns or {}

local Election = {}

-- Every client applies the same rule to its own view, so clients with the
-- same view agree. Candidates are the owners of live queue entries.
function Election.pick(names)
    local best
    for _, name in ipairs(names) do
        if best == nil or name < best then
            best = name
        end
    end
    return best
end

-- Candidates { id, since }: whoever has been online longest comes first, so
-- the matchmaker role stays with a stable client; ties go by name.
function Election.before(a, b)
    if (a.since or 0) ~= (b.since or 0) then
        return (a.since or 0) < (b.since or 0)
    end
    return a.id < b.id
end

-- A proposal from the matchmaker that ranks first wins; for the same
-- matchmaker the older proposal (lower seq) wins. sinceA/sinceB: when each
-- matchmaker came online, if known.
function Election.proposalWins(a, b, sinceA, sinceB)
    if a.matchmaker ~= b.matchmaker then
        return Election.before({ id = a.matchmaker, since = sinceA }, { id = b.matchmaker, since = sinceB })
    end
    return a.seq < b.seq
end

ns.Election = Election
return Election
