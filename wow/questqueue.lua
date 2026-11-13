local _, ns = ...

local Log = ns.Log

-- The questing queue: a second engine next to the dungeon one, with its own
-- messages (Protocol.QUESTS) and matchmaker (core/questmatch.lua); how it
-- goes along with the other queues is in wow/queues.lua.
local QuestQueue = {}

local function engine()
    return ns.questEngine
end

local handlers = {
    proposal = function(view)
        view.queue = "quests"
        ns.Popup.show(view, engine())
    end,
    proposalUpdated = function(view)
        ns.Popup.update(view)
    end,
    proposalEnded = function(data)
        ns.Popup.hide(engine())
        if data.result == "removed" and data.reason == "declined" then
            Log.info("You declined and left the questing queue.")
        elseif data.result == "removed" and data.reason == "timeout" then
            Log.info("You did not accept in time and left the questing queue.")
        elseif data.result == "requeued" or data.result == "superseded" then
            Log.info("Not everyone accepted. You keep your place in the questing queue.")
        end
    end,
    groupFormed = function(view)
        view.queue = "quests"
        ns.Filler.stop(true)
        ns.QuestGroup.start(view)
        ns.Group.formed(view)
    end,
    queueLeft = function(data)
        if data.reason == "left" then
            Log.info("You left the questing queue.")
        end
    end,
    error = function(data)
        Log.warn(data.message)
    end,
}

local PERSISTED = { queueJoined = true, queueLeft = true, groupFormed = true }

-- Saved per character so a /reload keeps the place in the questing queue.
function QuestQueue.persist()
    local entry = QuestQueue.entry()
    if entry then
        local members = {}
        for i, member in ipairs(entry.members) do
            members[i] = { name = member.name, roles = member.roles, level = member.level }
        end
        ns.charDb.questQueue = { members = members, keys = entry.dungeons, joinedAt = entry.joinedAt,
            savedAt = GetServerTime() }
    else
        ns.charDb.questQueue = nil
    end
end

local function onEvent(event, data)
    Log.debug("quest event %s", event)
    if handlers[event] then
        handlers[event](data)
    end
    ns.Queues.onEvent(engine(), event, data)
    if PERSISTED[event] then
        QuestQueue.persist()
    end
    ns.Window.refresh()
    ns.Status.refresh()
end

function QuestQueue.start(selfName)
    ns.questEngine = ns.Engine.new({
        name = selfName,
        clock = GetServerTime,
        send = ns.Comm.send,
        emit = onEvent,
        random = math.random,
        spec = ns.Spec.code(),
        lead = ns.charDb.wantsLeadQuests,
        lastSent = ns.Comm.lastSent,
        space = ns.Protocol.QUESTS,
        matchmaker = ns.QuestMatch,
        config = { PARTIAL_GROUPS = false },
    })
    ns.questEngine:start(false)
end

function QuestQueue.isQueued()
    return engine() ~= nil and engine().myEntry ~= nil
end

function QuestQueue.entry()
    return engine() and engine().myEntry
end

-- The player and, for a party leader, the party with each member's roles;
-- nil and a reason when the party cannot be queued.
function QuestQueue.members(roles)
    local members = { { name = ns.selfName, roles = roles, level = UnitLevel("player") } }
    local state = ns.Party.state()
    if state == "member" or state == "raid" then
        return nil, "only your party leader can queue the party"
    end
    if state == "leader" then
        local party = ns.Party.members()
        if not party then
            return nil, "party member names are still loading; try again in a moment"
        end
        for _, member in ipairs(party) do
            members[#members + 1] = { name = member.name, roles = ns.PartyRoles.rolesOf(member), level = member.level }
        end
    end
    return members
end

-- The quest keys a party of this size still needs players for.
function QuestQueue.keysFor(keys, partySize)
    local fitting = {}
    for _, key in ipairs(keys) do
        local _, size = ns.QuestMatch.parse(key)
        if size and size > partySize then
            fitting[#fitting + 1] = key
        end
    end
    return fitting
end

-- keys: quest keys ("176-3"); joinedAt (optional) keeps an earlier place.
function QuestQueue.join(keys, members, joinedAt)
    local quests = engine()
    if not quests then
        return false, "not connected to the channel yet, try again in a few seconds"
    end
    if #keys == 0 then
        return false, "choose at least one quest"
    end
    keys = QuestQueue.keysFor(keys, #members)
    if #keys == 0 then
        return false, "your party is already big enough for these quests"
    end
    local ok, err = quests:join(members, keys, joinedAt)
    if ok and not joinedAt then
        Log.info("Looking for a questing group for: %s.", QuestQueue.describe(keys))
        ns.Spec.checkRoles(members[1].roles)
    end
    return ok, err
end

local RESTORE_TRIES, RESTORE_RETRY = 4, 3

-- After a /reload or disconnect: back in the queue if the party is still the
-- same; at the old place only after a short break.
-- While party member names are still loading it tries again shortly.
function QuestQueue.restore(attempt)
    attempt = attempt or 1
    local saved = ns.charDb.questQueue
    local away = saved and GetServerTime() - (saved.savedAt or 0)
    if not saved or not saved.members or away > ns.Config.RESTORE_WINDOW then
        ns.charDb.questQueue = nil
        return
    end
    saved.members[1].name = ns.selfName
    local now = QuestQueue.members(saved.members[1].roles)
    if not now and ns.Party.state() == "leader" and attempt < RESTORE_TRIES then
        C_Timer.After(RESTORE_RETRY, function()
            QuestQueue.restore(attempt + 1)
        end)
        return
    end
    ns.charDb.questQueue = nil
    if not now or #now ~= #saved.members then
        return
    end
    local names = {}
    for _, member in ipairs(now) do
        names[member.name] = true
    end
    for _, member in ipairs(saved.members) do
        if not names[member.name] then
            return
        end
    end
    if away > ns.Config.ENTRY_TIMEOUT then
        QuestQueue.join(saved.keys, saved.members)
    elseif QuestQueue.join(saved.keys, saved.members, saved.joinedAt) then
        Log.info("Back in the questing queue; your place was kept.")
    end
end

local function partyChanged()
    engine():leave("auto")
    Log.info("Your party changed, so you left the questing queue.")
end

-- Keeps the queue entry in step with the party: players invited from the
-- Group Finder who joined become members, and a party that reached the
-- quest's group size is complete. A stranger joining, or the player no longer
-- leading, ends the questing queue.
local function onRosterUpdate()
    local entry = QuestQueue.entry()
    if not entry or ns.BgFinder.isRecruiting() then
        return
    end
    local state = ns.Party.state()
    if state == "member" or state == "raid" then
        partyChanged()
        return
    end
    local party = ns.Party.members()
    if not party then
        return
    end
    local joined = ns.QuestFinder.takeJoined()
    local known = {}
    for _, member in ipairs(entry.members) do
        known[member.name] = member
    end
    local members, changed = { entry.members[1] }, #party ~= #entry.members - 1
    for _, member in ipairs(party) do
        if known[member.name] then
            members[#members + 1] = known[member.name]
        elseif joined[member.name] then
            members[#members + 1] = { name = member.name, roles = joined[member.name], level = member.level }
            changed = true
        else
            partyChanged()
            return
        end
    end
    if not changed then
        return
    end
    local key = ns.QuestFinder.focus()
    local _, size = ns.QuestMatch.parse(key or "")
    if size and #members >= size then
        engine():leave("auto")
        ns.Filler.stop(true)
        Log.info("Your group for %s is complete.", ns.Quests.nameOf(key))
        ns.QuestGroup.start({ dungeon = key })
        return
    end
    local reserved, keys = ns.QuestFinder.pendingRoles(), key and { key } or nil
    local ok, err = engine():updateEntry(members, reserved, keys)
    if not ok and err == "proposal open" then
        -- The proposal was made for the old party; step out of it so the
        -- group is not formed with someone who left.
        engine():withdrawFromProposal()
        ok, err = engine():updateEntry(members, reserved, keys)
    end
    if not ok then
        Log.debug("questing queue entry not updated: %s", tostring(err))
    end
end

function QuestQueue.init()
    ns.on("GROUP_ROSTER_UPDATE", onRosterUpdate)
end

function QuestQueue.leave()
    local quests = engine()
    if quests and quests.myEntry then
        quests:leave()
    end
end

-- How many other players wait for this quest key.
function QuestQueue.waitingFor(key)
    local quests = engine()
    local count = 0
    for _, entry in ipairs(quests and quests.queue:list() or {}) do
        if entry.id ~= ns.selfName then
            for _, wanted in ipairs(entry.dungeons) do
                if wanted == key then
                    count = count + #entry.members
                end
            end
        end
    end
    return count
end

function QuestQueue.describe(keys)
    local names = {}
    for i, key in ipairs(keys) do
        names[i] = ns.Quests.nameOf(key)
    end
    return table.concat(names, ", ")
end

function QuestQueue.tick()
    if engine() then
        engine():tick()
    end
    ns.QuestFinder.tick()
end

ns.QuestQueue = QuestQueue
