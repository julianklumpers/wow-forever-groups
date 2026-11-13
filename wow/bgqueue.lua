local _, ns = ...

local Log = ns.Log
local Battlegrounds = ns.Battlegrounds

-- The battleground queue: a third engine next to the dungeon and questing
-- ones, with its own messages (Protocol.BATTLEGROUNDS) and matchmaker
-- (core/bgmatch.lua). Forever Groups players waiting for the same
-- battleground in the same bracket form a party; its leader then fills it
-- from WoW's Group Finder (wow/bgfinder.lua) up to the chosen size. A party
-- leader waits with the party, up to five players; past that (a raid) the
-- Group Finder alone fills it.
local BgQueue = {}


local function engine()
    return ns.bgEngine
end

local handlers = {
    proposal = function(view)
        view.queue = "battlegrounds"
        ns.Popup.show(view, engine())
    end,
    proposalUpdated = function(view)
        ns.Popup.update(view)
    end,
    proposalEnded = function(data)
        ns.Popup.hide(engine())
        if data.result == "removed" and data.reason == "declined" then
            Log.info("You declined and left the battleground queue.")
        elseif data.result == "removed" and data.reason == "timeout" then
            Log.info("You did not accept in time and left the battleground queue.")
        elseif data.result == "requeued" or data.result == "superseded" then
            Log.info("Not everyone accepted. You keep your place in the battleground queue.")
        end
    end,
    groupFormed = function(view)
        view.queue = "battlegrounds"
        ns.Group.formed(view)
        ns.BgFinder.onFormed(view)
    end,
    queueLeft = function(data)
        if data.reason == "left" then
            Log.info("You left the battleground queue.")
        end
    end,
    error = function(data)
        Log.warn(data.message)
    end,
}

local PERSISTED = { queueJoined = true, queueLeft = true, groupFormed = true }

-- Saved per character so a /reload keeps the place in the queue.
function BgQueue.persist()
    local entry = BgQueue.entry()
    if entry then
        local members = {}
        for i, member in ipairs(entry.members) do
            members[i] = { name = member.name, roles = member.roles, level = member.level }
        end
        ns.charDb.bgQueue = { members = members, keys = entry.dungeons, joinedAt = entry.joinedAt,
            savedAt = GetServerTime() }
    else
        ns.charDb.bgQueue = nil
    end
end

local function onEvent(event, data)
    Log.debug("battleground event %s", event)
    if handlers[event] then
        handlers[event](data)
    end
    ns.Queues.onEvent(engine(), event, data)
    if PERSISTED[event] then
        BgQueue.persist()
    end
    ns.Window.refresh()
    ns.Status.refresh()
end

function BgQueue.start(selfName)
    ns.bgEngine = ns.Engine.new({
        name = selfName,
        clock = GetServerTime,
        send = ns.Comm.send,
        emit = onEvent,
        random = math.random,
        spec = ns.Spec.code(),
        lead = ns.charDb.wantsLeadBattlegrounds,
        lastSent = ns.Comm.lastSent,
        space = ns.Protocol.BATTLEGROUNDS,
        matchmaker = ns.BgMatch,
        config = { PARTIAL_GROUPS = false },
    })
    ns.bgEngine:start(false)
end

function BgQueue.isQueued()
    return engine() ~= nil and engine().myEntry ~= nil
end

function BgQueue.entry()
    return engine() and engine().myEntry
end

-- The queue keys for these battleground ids at the player's level.
function BgQueue.keysFor(ids)
    local keys = {}
    for _, id in ipairs(ids) do
        local key = Battlegrounds.key(id, UnitLevel("player"))
        if key then
            keys[#keys + 1] = key
        end
    end
    return keys
end

-- The player and, for a party leader, the party; nil and a reason when it
-- cannot wait in the queue (a member, or a raid: the Group Finder fills it).
-- known: roles by name for players the Group Finder brought in.
function BgQueue.members(roles, known)
    local members = { { name = ns.selfName, roles = roles, level = UnitLevel("player") } }
    local state = ns.Party.state()
    if state == "member" then
        return nil, "only your group's leader can look for players"
    elseif state == "raid" then
        return nil, "a raid fills from the Group Finder only"
    end
    if state == "leader" then
        local party = ns.Party.members()
        if not party then
            return nil, "party member names are still loading; try again in a moment"
        end
        for _, member in ipairs(party) do
            members[#members + 1] = { name = member.name, level = member.level,
                roles = (known and known[member.name]) or ns.PartyRoles.rolesOf(member) or "D" }
        end
    end
    if #members > ns.Config.MAX_PREMADE then
        return nil, "your party is full"
    end
    return members
end

-- ids: battleground ids; joinedAt (optional) keeps an earlier place.
function BgQueue.join(ids, members, joinedAt)
    local bg = engine()
    if not bg then
        return false, "not connected to the channel yet, try again in a few seconds"
    end
    local keys = BgQueue.keysFor(ids)
    if #keys == 0 then
        return false, "choose a battleground for your level"
    end
    return bg:join(members, keys, joinedAt)
end

-- reason "auto" leaves without a word.
function BgQueue.leave(reason)
    local bg = engine()
    if bg and bg.myEntry then
        bg:leave(reason)
    end
end

local RESTORE_TRIES, RESTORE_RETRY = 4, 3

-- After a /reload or disconnect: back in the queue if the party is still the
-- same; at the old place only after a short break.
function BgQueue.restore(attempt)
    attempt = attempt or 1
    local saved = ns.charDb.bgQueue
    local away = saved and GetServerTime() - (saved.savedAt or 0)
    if not saved or not saved.members or away > ns.Config.RESTORE_WINDOW then
        ns.charDb.bgQueue = nil
        return
    end
    saved.members[1].name = ns.selfName
    local now = BgQueue.members(saved.members[1].roles)
    if not now and ns.Party.state() == "leader" and attempt < RESTORE_TRIES then
        C_Timer.After(RESTORE_RETRY, function()
            BgQueue.restore(attempt + 1)
        end)
        return
    end
    ns.charDb.bgQueue = nil
    if not now or #now ~= #saved.members then
        return
    end
    local ids = {}
    for _, key in ipairs(saved.keys or {}) do
        ids[#ids + 1] = Battlegrounds.parseKey(key)
    end
    if away > ns.Config.ENTRY_TIMEOUT then
        BgQueue.join(ids, saved.members)
    elseif BgQueue.join(ids, saved.members, saved.joinedAt) then
        Log.info("Back in the battleground queue; your place was kept.")
    end
end

-- How many other players wait for this battleground key.
function BgQueue.waitingFor(key)
    local bg = engine()
    local count = 0
    for _, entry in ipairs(bg and bg.queue:list() or {}) do
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

-- Solo Forever Groups players waiting for a battleground the player waits
-- for: the Group Finder leaves their places open.
function BgQueue.soloWaiting()
    local mine = BgQueue.entry()
    if not mine then
        return 0
    end
    local wanted, count = {}, 0
    for _, key in ipairs(mine.dungeons) do
        wanted[key] = true
    end
    for _, entry in ipairs(engine().queue:list()) do
        local shares = false
        for _, key in ipairs(entry.dungeons) do
            shares = shares or wanted[key] == true
        end
        if entry.id ~= ns.selfName and shares and #entry.members == 1 and (entry.reserved or "") == "" then
            count = count + 1
        end
    end
    return count
end

-- The entry follows the party: players the Group Finder brought in become
-- members, its invites on the way keep places; joining someone else's group,
-- a raid or a full party ends it.
function BgQueue.sync()
    local entry = BgQueue.entry()
    if not entry then
        return
    end
    local members, why = BgQueue.members(entry.members[1].roles, ns.BgFinder.joinedRoles())
    local reserved = ns.BgFinder.pendingRoles()
    if members and #members + #reserved > ns.Config.MAX_PREMADE then
        members, why = nil, "your party is full"
    end
    if not members then
        engine():leave("auto")
        Log.detail("Left the battleground queue: %s.", why)
        return
    end
    local same = #members == #entry.members and reserved == (entry.reserved or "")
    for i, member in ipairs(members) do
        same = same and entry.members[i] ~= nil and entry.members[i].name == member.name
    end
    if same then
        return
    end
    local ok, err = engine():updateEntry(members, reserved, entry.dungeons)
    if not ok and err == "proposal open" then
        engine():withdrawFromProposal()
        ok, err = engine():updateEntry(members, reserved, entry.dungeons)
    end
    if not ok then
        Log.debug("battleground queue entry not updated: %s", tostring(err))
    end
end

function BgQueue.init()
    ns.on("GROUP_ROSTER_UPDATE", BgQueue.sync)
end

function BgQueue.tick()
    if engine() then
        engine():tick()
    end
end

ns.BgQueue = BgQueue
