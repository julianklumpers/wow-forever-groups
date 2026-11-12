local _, ns = ...

local Roles = ns.Roles
local Dungeons = ns.Dungeons
local Log = ns.Log

-- Makes "Find group" use every source at once: other Forever Groups players
-- through the matchmaker, and WoW's Group Finder for whatever they cannot
-- fill. A player with no Forever Groups partner in sight starts filling from
-- the Group Finder right away; a group that formed but is not complete stays
-- in the queue so later Forever Groups players can still join it.
local AutoFill = {}

local function sharesDungeon(a, b)
    for _, x in ipairs(a.dungeons) do
        for _, y in ipairs(b.dungeons) do
            if x == y then
                return true
            end
        end
    end
    return false
end

-- Another queued entry the matchmaker could put in one group with ours.
local function hasPartner(engine, entry)
    local mine = Roles.withReserved(entry.members, entry.reserved)
    local now = engine:now()
    for _, other in ipairs(engine.queue:list()) do
        local recent = now - (other.lastSeen or now) <= engine.config.HEARTBEAT_INTERVAL + 15
        local active = recent and not engine.fakes[other.id]
        if other.id ~= entry.id and active and not engine:isReserved(other.id) and sharesDungeon(entry, other) then
            local theirs = Roles.withReserved(other.members, other.reserved)
            if not (#mine > 1 and #theirs > 1) and #mine + #theirs <= 5 then
                local together = {}
                for _, member in ipairs(mine) do
                    together[#together + 1] = member
                end
                for _, member in ipairs(theirs) do
                    together[#together + 1] = member
                end
                if #Roles.options(together, ns.Config.SLOTS) > 0 then
                    return true
                end
            end
        end
    end
    return false
end

local function proposalOpen(engine)
    local key = engine and engine.myProposalKey
    local proposal = key and engine.proposals[key]
    return proposal ~= nil and not proposal.outcome
end

function AutoFill.tick()
    if not ns.Features.fill() then
        return
    end
    local engine = ns.engine
    local entry = engine and engine.myEntry
    if not entry or ns.Filler.isActive() or proposalOpen(engine) or engine.held or proposalOpen(ns.questEngine)
        or engine:isReserved(entry.id) then
        return
    end
    if GetServerTime() - engine.startedAt < ns.Config.WARMUP or hasPartner(engine, entry) then
        return
    end
    if not ns.Apply.wantsToBuild() then
        return
    end
    local missing, assignment = ns.Filler.missingFor(Roles.withReserved(entry.members, entry.reserved))
    if not missing or missing == "" then
        return
    end
    local names = {}
    for i, member in ipairs(entry.members) do
        names[i] = member.name
        ns.RoleSync.expect(member.name, assignment[i])
    end
    Log.debug("no Forever Groups partner in sight; filling from the Group Finder")
    ns.Filler.start({ dungeons = entry.dungeons, missing = missing, members = names })
end

-- A group formed around us but is not complete: stay in the queue with it, at
-- the same place, while the Group Finder fills the rest.
function AutoFill.afterGroupFormed(view)
    if not view.isLeader or not view.missing or view.missing == "" then
        return
    end
    local members = {}
    for _, member in ipairs(view.members) do
        if member.fake then
            return
        end
        local entryMember = { name = member.name, roles = member.role, level = UnitLevel("player") }
        if member.name == ns.selfName then
            table.insert(members, 1, entryMember)
        else
            members[#members + 1] = entryMember
        end
    end
    local ok, err = ns.join(members, { view.dungeon }, view.joinedAt)
    if ok then
        Log.info("Still looking for %s for %s.", ns.Widgets.describeRoles(view.missing), Dungeons.name(view.dungeon))
    else
        Log.debug("could not stay in the queue with the group: %s", tostring(err))
    end
end

ns.AutoFill = AutoFill
