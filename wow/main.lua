local addonName, ns = ...

local Engine = ns.Engine
local Config = ns.Config
local Log = ns.Log
local Comm = ns.Comm
local Popup = ns.Popup
local Group = ns.Group
local Party = ns.Party
local Window = ns.Window
local Filler = ns.Filler
local PartyStatus = ns.PartyStatus
local Status = ns.Status

ns.addonName = addonName

local function copyMembers(members)
    local copy = {}
    for i, member in ipairs(members) do
        copy[i] = { name = member.name, roles = member.roles, level = member.level }
    end
    return copy
end

local chosenDungeons
local parked

local function persistQueue()
    local entry = ns.engine and ns.engine.myEntry
    if entry then
        ns.charDb.queue = {
            members = copyMembers(entry.members),
            dungeons = chosenDungeons or entry.dungeons,
            joinedAt = entry.joinedAt,
            invited = Filler.pendingInvites(),
            savedAt = GetServerTime(),
        }
    else
        ns.charDb.queue = nil
    end
end

-- members: the player first, then party members, each { name, roles, level }.
function ns.join(members, dungeons, joinedAt)
    if not ns.engine then
        return false, "not connected to the channel yet, try again in a few seconds"
    end
    local ok, err = ns.engine:join(members, dungeons, joinedAt)
    if ok then
        chosenDungeons = dungeons
        parked = nil
        if not joinedAt then
            ns.Spec.checkRoles(members[1].roles)
        end
    end
    persistQueue()
    Window.refresh()
    return ok, err
end

local function partyMatchesEntry(entry)
    local party = Party.members()
    if party == nil then
        return true
    end
    if #party ~= #entry.members - 1 then
        return false
    end
    local names = {}
    for _, member in ipairs(party) do
        names[member.name] = true
    end
    for i = 2, #entry.members do
        if not names[entry.members[i].name] then
            return false
        end
    end
    return true
end

-- The party as it should be queued: known members keep their roles, players
-- who joined from the Group Finder get the role they were invited for.
-- nil when someone else joined or names are still loading.
-- The party as it should be queued: known members keep their roles, players
-- who joined from the Group Finder get the role they were invited for, and
-- players still on their way from a formed group stay in. nil when a
-- stranger joined or names are still loading.
local function queuedParty(entry)
    local party = Party.members()
    if party == nil then
        return nil, "loading"
    end
    local inParty = {}
    for _, member in ipairs(party) do
        inParty[member.name] = member
    end
    local members, known = { entry.members[1] }, {}
    for i = 2, #entry.members do
        local member = entry.members[i]
        known[member.name] = true
        if inParty[member.name] then
            local roles = ns.PartyRoles.rolesOf(inParty[member.name])
            members[#members + 1] = { name = member.name, roles = roles, level = inParty[member.name].level }
        elseif Group.isExpected(member.name) then
            members[#members + 1] = member
        end
    end
    for _, member in ipairs(party) do
        if not known[member.name] then
            if not Filler.roleOf(member.name) and not ns.RoleSync.expected(member.name) then
                return nil, "stranger"
            end
            members[#members + 1] = { name = member.name, roles = ns.PartyRoles.rolesOf(member), level = member.level }
        end
    end
    return members
end

local syncPending = false

local function leaveQueue(text)
    ns.engine:leave("auto")
    Log.info(text)
end

local function sameDungeons(a, b)
    if #a ~= #b then
        return false
    end
    for i, id in ipairs(a) do
        if b[i] ~= id then
            return false
        end
    end
    return true
end

-- Back into the queue, at the old place, once a Group Finder invite that
-- made the group "full" was declined or timed out.
local function unpark()
    local engine = ns.engine
    if not parked or not engine or engine.myEntry then
        return
    end
    local state = Party.state()
    if not Filler.isActive() or (state ~= "solo" and state ~= "leader") then
        parked = nil
        return
    end
    local me = {
        name = ns.selfName, level = UnitLevel("player"),
        roles = ns.RoleSync.expected(ns.selfName) or ns.charDb.lastRoles or "D",
    }
    local members = queuedParty({ members = { me } })
    if not members or #members + #Filler.reservedRoles() >= 5 then
        return
    end
    local saved = parked
    if ns.join(members, saved.dungeons, saved.joinedAt) then
        Log.info("A spot opened up again; you are back in the queue at your old place.")
    end
end

-- Keeps the queue entry in step with the party and the Group Finder invites,
-- so the matchmaker never fills a role that is already taken.
local function syncEntry()
    local engine = ns.engine
    local entry = engine and engine.myEntry
    if not entry then
        syncPending = false
        unpark()
        return
    end
    local state = Party.state()
    if state == "member" or state == "raid" then
        leaveQueue("You are no longer the party leader, so you left the queue.")
        return
    end
    local members, why = queuedParty(entry)
    if not members then
        if why == "stranger" then
            leaveQueue("Your group changed, so you left the queue.")
        end
        return
    end
    local reserved = Filler.reservedRoles()
    if #members + #reserved >= 5 then
        parked = { dungeons = chosenDungeons or entry.dungeons, joinedAt = entry.joinedAt }
        leaveQueue("The Group Finder is filling the last spots, so you left the queue for now.")
        return
    end
    local dungeon = Filler.dungeon()
    local dungeons = dungeon and { dungeon } or chosenDungeons or entry.dungeons
    local sameMembers = #members == #entry.members
    for i = 1, #members do
        sameMembers = sameMembers and entry.members[i] and entry.members[i].name == members[i].name
            and entry.members[i].roles == members[i].roles
    end
    if sameMembers and reserved == (entry.reserved or "") and sameDungeons(dungeons, entry.dungeons) then
        syncPending = false
        return
    end
    local ok, err = engine:updateEntry(members, reserved, dungeons)
    if not ok and err == "proposal open" and not sameMembers then
        engine:withdrawFromProposal()
        ok, err = engine:updateEntry(members, reserved, dungeons)
    end
    syncPending = not ok and err == "proposal open"
    if ok then
        persistQueue()
        PartyStatus.sendState()
        if #members < #entry.members then
            Log.info("Your group changed; you stay in the queue as a group of %d.", #members)
        end
    elseif not syncPending then
        Log.debug("queue update refused: %s", tostring(err))
    end
end

local function onRosterUpdate()
    syncEntry()
    Window.refresh()
end

local PROPOSAL_RESULTS = {
    requeued = "Not everyone accepted. You keep your place in the queue.",
    removed = "You did not accept in time and left the queue.",
}

local eventHandlers = {
    queueJoined = function()
        persistQueue()
        PartyStatus.sendState()
    end,
    queueLeft = function(data)
        persistQueue()
        PartyStatus.sendState()
        if data.reason == "left" then
            Log.info("You left the queue.")
        end
    end,
    proposal = function(data)
        Popup.show(data)
        PartyStatus.sendProposal(data)
    end,
    proposalUpdated = function(data)
        Popup.update(data)
    end,
    proposalEnded = function(data)
        Popup.hide(ns.engine)
        if data.result == "requeued" then
            PartyStatus.sendState(true)
        end
        if data.result == "removed" and data.reason == "declined" then
            Log.info("You declined and left the queue.")
        elseif PROPOSAL_RESULTS[data.result] then
            Log.info(PROPOSAL_RESULTS[data.result])
        end
    end,
    groupFormed = function(data)
        persistQueue()
        PartyStatus.sendFormed(data)
        Group.formed(data)
        ns.AutoFill.afterGroupFormed(data)
    end,
    error = function(data)
        Log.warn(data.message)
    end,
    matchInfo = function(data)
        Log.debug("match %s", data.text)
    end,
}

local function onEngineEvent(event, data)
    Log.debug("event %s", event)
    local handler = eventHandlers[event]
    if handler then
        handler(data)
    end
    ns.QuestQueue.onDungeonEvent(event, data)
    Window.refresh()
    Status.refresh()
end

local function restoreQueue()
    local saved = ns.charDb.queue
    ns.charDb.queue = nil
    if not saved or not saved.members or not saved.members[1].roles
        or GetServerTime() - saved.savedAt > Config.ENTRY_TIMEOUT then
        return
    end
    saved.members[1].name = ns.selfName
    saved.members[1].roles = ns.Classes.filter(saved.members[1].roles, Party.playerClass())
    if not saved.members[1].roles then
        return
    end
    local state = Party.state()
    if state == "member" or state == "raid" or not partyMatchesEntry(saved) then
        return
    end
    for name, role in pairs(saved.invited or {}) do
        ns.RoleSync.expect(name, role)
    end
    if ns.join(saved.members, saved.dungeons, saved.joinedAt) then
        Log.info("Back in the queue; your place was kept.")
    end
end

local function onReady(selfName)
    ns.selfName = selfName
    local derived = Party.unitName("player")
    if derived ~= selfName then
        Log.debug("name check: server says '%s', UnitFullName gives '%s'", selfName, tostring(derived))
    end
    ns.engine = Engine.new({
        name = selfName,
        clock = GetServerTime,
        send = Comm.send,
        emit = onEngineEvent,
        random = math.random,
        config = ns.db.slots and { SLOTS = ns.db.slots } or nil,
        playstyle = ns.Playstyle.mine(),
        spec = ns.Spec.code(),
        lead = ns.charDb.wantsLead,
        lastSent = Comm.lastSent,
    })
    ns.engine:start(false)
    ns.QuestQueue.start(selfName)
    restoreQueue()
    ns.QuestQueue.restore()
    ns.QuestGroup.restore()
    ns.GroupView.restore()
    PartyStatus.onReady()
    ns.Version.onReady()
    ns.Presence.start()
    Window.refresh()
end

-- Any message of a player shows it is alive, in both queues: a player in
-- both sends one stream of keep-alives, not two.
local function onMessage(sender, text)
    ns.Presence.seen(sender)
    if string.find(text, "^v%d+|S|") then
        ns.Presence.newcomer()
    end
    for _, engine in ipairs({ ns.engine, ns.questEngine }) do
        engine.queue:touch(sender, engine:now())
    end
    if ns.Version.onMessage(sender, text) or ns.Entrances.onMessage(sender, text) then
        return
    end
    if ns.engine then
        ns.engine:receive(sender, text)
    end
    if ns.questEngine then
        ns.questEngine:receive(sender, text)
    end
end

local ticks = 0

local function tick()
    if ns.engine then
        ns.engine:tick()
    end
    ns.QuestQueue.tick()
    if syncPending then
        syncEntry()
    end
    Comm.flush()
    Filler.tick()
    ns.Apply.tick()
    ns.AutoFill.tick()
    ns.Listing.tick()
    ns.GroupView.check()
    ns.Entrances.tick()
    ns.GroupPlaces.tick()
    ns.InspectSpec.tick()
    Status.refresh()
    ns.MinimapButton.refresh()
    ns.QueueWindow.refresh()
    ticks = ticks + 1
    if ticks % 5 == 0 then
        ns.RoleSync.apply()
        syncEntry()
        Filler.recompute()
    end
    Window.refresh()
end

-- The addon used to be called DungeonQueue. While that folder is still
-- installed it loads too: its settings come along once, and it is turned off
-- for the next /reload.
local function takeOverOldAddon()
    local api = C_AddOns
    if type(api) ~= "table" or type(api.IsAddOnLoaded) ~= "function" then
        return
    end
    local ok, loaded = pcall(api.IsAddOnLoaded, "DungeonQueue")
    if not ok or not loaded then
        return
    end
    if ForeverGroupsDB == nil and type(DungeonQueueDB) == "table" then
        ForeverGroupsDB = DungeonQueueDB
    end
    if ForeverGroupsCharDB == nil and type(DungeonQueueCharDB) == "table" then
        ForeverGroupsCharDB = DungeonQueueCharDB
    end
    if type(api.DisableAddOn) == "function" then
        pcall(api.DisableAddOn, "DungeonQueue")
    end
    C_Timer.After(5, function()
        Log.warn("DungeonQueue is now called Forever Groups and took over its settings. The old DungeonQueue "
            .. "addon is turned off: type /reload, and you can delete its folder.")
    end)
end

ns.on("ADDON_LOADED", function(name)
    if name ~= addonName then
        return
    end
    takeOverOldAddon()
    ForeverGroupsDB = ForeverGroupsDB or {}
    ForeverGroupsCharDB = ForeverGroupsCharDB or {}
    ns.db = ForeverGroupsDB
    ns.charDb = ForeverGroupsCharDB
    Comm.init(onReady, onMessage, function(sender, text)
        ns.Presence.seen(sender)
        if not ns.QuestShare.onMessage(sender, text) and not ns.QuestGroup.onMessage(sender, text)
            and not ns.GroupPlaces.onMessage(sender, text) then
            PartyStatus.onMessage(sender, text)
        end
    end, function(sender)
        if ns.engine then
            ns.engine:forget(sender)
        end
        if ns.questEngine then
            ns.questEngine:forget(sender)
        end
    end)
    Group.init()
    ns.LfgList.init()
    Filler.init()
    Filler.onChange(syncEntry)
    ns.RoleSync.init()
    local function rolesChanged()
        syncEntry()
        Filler.recompute()
        Window.refresh()
    end
    ns.RoleSync.onChange(rolesChanged)
    ns.on("PLAYER_ROLES_ASSIGNED", rolesChanged)
    ns.on("ROLE_CHANGED_INFORM", rolesChanged)
    PartyStatus.init()
    ns.GroupView.init()
    ns.on("GROUP_ROSTER_UPDATE", onRosterUpdate)
    ns.Apply.init()
    ns.Listing.init()
    ns.WhisperInvite.init()
    ns.Quests.init()
    ns.QuestShare.init()
    ns.QuestQueue.init()
    ns.QuestFinder.init()
    ns.Spec.init()
    ns.Diagnostics.init()
    ns.QuestGroup.init()
    ns.Entrances.init()
    ns.GroupPlaces.init()
    ns.InspectSpec.init()
    ns.Run.init()
    ns.Slash.init()
end)

ns.on("PLAYER_LOGIN", function()
    ns.LfgList.loadLevelRanges()
    ns.LfgList.loadZones()
    ns.Entrances.loadFromWoW()
    ns.KeySearch.init()
    ns.Settings.register()
    ns.MinimapButton.refresh()
    Comm.start()
    C_Timer.NewTicker(1, tick)
end)

ns.on("PLAYER_LOGOUT", function()
    persistQueue()
    ns.QuestQueue.persist()
    if ns.engine and ns.engine.myEntry then
        Comm.sendNow(ns.Protocol.encode({ kind = "leave" }))
    end
    if ns.questEngine and ns.questEngine.myEntry then
        Comm.sendNow(ns.Protocol.encode({ kind = "leave" }, ns.Protocol.QUESTS))
    end
end)

function ForeverGroups_OnAddonCompartmentClick()
    Window.toggle()
end

ForeverGroups = ns
