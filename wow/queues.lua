local _, ns = ...

local Log = ns.Log

-- The three queues (dungeons, questing, battlegrounds) side by side. A player
-- can wait in all of them; while one has a group proposal for the player
-- the others step out, and once a group forms the others are left.
local Queues = {}

-- A proposal that ended this way leaves the other queues held: accepted
-- means a group follows, superseded means another proposal follows.
local KEEPS_HOLD = { accepted = true, superseded = true }

local function all()
    return {
        { engine = ns.engine, label = ns.Locale.mark("dungeon") },
        { engine = ns.questEngine, label = ns.Locale.mark("questing") },
        { engine = ns.bgEngine, label = ns.Locale.mark("battleground") },
    }
end

-- The queues that are running, for loops over all of them.
function Queues.engines()
    local list = {}
    for _, queue in ipairs(all()) do
        if queue.engine then
            list[#list + 1] = queue.engine
        end
    end
    return list
end

-- Whether this queue has a group proposal for the player that is not
-- settled yet.
function Queues.proposalOpen(engine)
    local key = engine and engine.myProposalKey
    local proposal = key and engine.proposals[key]
    return proposal ~= nil and not proposal.outcome
end

function Queues.anyProposalOpen()
    for _, engine in ipairs(Queues.engines()) do
        if Queues.proposalOpen(engine) then
            return true
        end
    end
    return false
end

local function labelOf(source)
    for _, queue in ipairs(all()) do
        if queue.engine == source then
            return queue.label
        end
    end
    return nil
end

-- A group formed for the player through source's queue, or for a
-- battleground group Find group builds from the Group Finder (source
-- ns.bgEngine): every other queue is left.
function Queues.leaveOthers(source)
    local label = labelOf(source)
    for _, queue in ipairs(all()) do
        local other = queue.engine
        if other and other ~= source then
            if other.myEntry then
                other:leave("auto")
                Log.info("A %s group formed, so you left the %s queue.", ns.L[label], ns.L[queue.label])
            end
            other:setHeld(false)
        end
    end
    if source ~= ns.bgEngine then
        ns.BgFinder.cancel()
    end
end

-- Called with every event of a queue's engine.
function Queues.onEvent(source, event, data)
    if event == "groupFormed" then
        Queues.leaveOthers(source)
        return
    end
    for _, queue in ipairs(all()) do
        local other = queue.engine
        if other and other ~= source then
            if event == "proposal" then
                other:setHeld(true)
            elseif event == "proposalEnded" and not KEEPS_HOLD[data.result] then
                other:setHeld(false)
            end
        end
    end
end

ns.Queues = Queues
