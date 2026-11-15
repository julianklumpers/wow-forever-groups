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

local LANGUAGE_DROPPED = "Your languages do not fit in the queue message with this many dungeons; you queue "
    .. "without them and are grouped with players of any language."

local function persistQueue()
    local entry = ns.engine and ns.engine.myEntry
    if entry then
        ns.charDb.queue = {
            members = copyMembers(entry.members),
            dungeons = chosenDungeons or entry.dungeons,
            joinedAt = entry.joinedAt,
            filler = Filler.saved(),
            savedAt = GetServerTime(),
        }
    elseif parked and Filler.isActive() then
        ns.charDb.queue = {
            parked = true,
            dungeons = parked.dungeons,
            joinedAt = parked.joinedAt,
            filler = Filler.saved(),
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
    local engine = ns.engine
    engine:setCompose(ns.PartyCompose.wireText())
    engine:setLevels(ns.PartyLevels.wireText("dungeons", dungeons))
    engine:setLanguage(ns.MatchLanguages.wireText())
    local ok, err = engine:join(members, dungeons, joinedAt)
    engine.unfit = nil
    if not ok and err == "message too long" and (engine.compose or engine.levels) then
        -- Joining matters more than the wishes: queue without them, and don't
        -- try these again until they change.
        engine.unfit = { compose = engine.compose, levels = engine.levels }
        engine:setCompose(nil)
        engine:setLevels(nil)
        ok, err = engine:join(members, dungeons, joinedAt)
        if ok then
            Log.warn("Your class choices and level limit do not fit in the queue message with this many dungeons; "
                .. "you queue without them.")
        end
    end
    local language = engine.language
    if not ok and err == "message too long" and language then
        engine:setLanguage(nil)
        ok, err = engine:join(members, dungeons, joinedAt)
        if ok then
            engine:reportTooLong("languageDropped", language, LANGUAGE_DROPPED)
        else
            engine:setLanguage(language)
        end
    end
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
        name = ns.selfName, level = ns.Party.playerLevel(),
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
    if ns.BgFinder.isRecruiting() then
        -- Its recruits are for a battleground; Find group leaves this queue.
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
    -- The class wishes and level limit as they stand now go in the same
    -- update (one message), seated like the members and invites in it; while
    -- a name is still loading the entry keeps the ones it has.
    local compose, loading = ns.PartyCompose.wireText()
    local levels = ns.PartyLevels.wireText("dungeons", dungeons)
    local unfit = engine.unfit
    if unfit and unfit.compose == compose and unfit.levels == levels then
        -- These did not fit before: the entry goes on without them.
        compose, levels = nil, nil
    end
    local sameWishes = loading or (compose == engine.compose and levels == engine.levels)
    if sameMembers and sameWishes and reserved == (entry.reserved or "") and sameDungeons(dungeons, entry.dungeons) then
        syncPending = false
        return
    end
    local before = { compose = engine.compose, levels = engine.levels, language = engine.language }
    if not loading then
        engine.compose, engine.levels = compose, levels
    end
    local ok, err = engine:updateEntry(members, reserved, dungeons)
    if not ok and err == "proposal open" and not sameMembers then
        engine:withdrawFromProposal()
        ok, err = engine:updateEntry(members, reserved, dungeons)
    end
    if not ok and err == "message too long" and (engine.compose or engine.levels) then
        -- The party matters more than the wishes: update without them, and
        -- don't try these again until they change.
        engine.unfit = { compose = engine.compose, levels = engine.levels }
        engine.compose, engine.levels = nil, nil
        engine:reportTooLong("wishes", true, "Your class choices and level limit do not fit in the queue message "
            .. "with this many dungeons; you queue without them.")
        ok, err = engine:updateEntry(members, reserved, dungeons)
    end
    if not ok and err == "message too long" and engine.language then
        -- Without its language the entry is grouped with everyone; it is
        -- not set again until the next join.
        local language = engine.language
        engine.language = nil
        ok, err = engine:updateEntry(members, reserved, dungeons)
        if ok then
            engine:reportTooLong("languageDropped", language, LANGUAGE_DROPPED)
        else
            engine.language = language
        end
    end
    if not ok and err ~= "message too long" then
        engine.compose, engine.levels, engine.language = before.compose, before.levels, before.language
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
    ns.Queues.onEvent(ns.engine, event, data)
    Window.refresh()
    Status.refresh()
end

-- Out of the queue while the Group Finder filled the last places: it fills
-- on, and the queue is joined again (at the old place, when not away long)
-- once a place frees up.
local function restoreParked(saved, away)
    local state = Party.state()
    if state == "member" or state == "raid" or type(saved.dungeons) ~= "table" then
        return
    end
    if Filler.restore(saved.filler, away) then
        parked = { dungeons = saved.dungeons, joinedAt = away <= Config.ENTRY_TIMEOUT and saved.joinedAt or nil }
    end
end

local function restoreQueue()
    local saved = ns.charDb.queue
    ns.charDb.queue = nil
    local away = saved and GetServerTime() - (saved.savedAt or 0)
    if not saved or away > Config.RESTORE_WINDOW then
        return
    end
    if saved.parked then
        restoreParked(saved, away)
        return
    end
    if not saved.members or not saved.members[1].roles then
        return
    end
    local keepPlace = away <= Config.ENTRY_TIMEOUT
    saved.members[1].name = ns.selfName
    saved.members[1].roles = ns.Classes.filter(saved.members[1].roles, Party.playerClass())
    if not saved.members[1].roles then
        return
    end
    local state = Party.state()
    if state == "member" or state == "raid" or not partyMatchesEntry(saved) then
        return
    end
    if not keepPlace then
        if ns.join(saved.members, saved.dungeons) then
            Log.info("Back in the queue.")
        end
        return
    end
    if ns.join(saved.members, saved.dungeons, saved.joinedAt) then
        Filler.restore(saved.filler, away)
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
        playstyle = ns.Playstyle.mine(),
        spec = ns.Spec.code(),
        lead = ns.charDb.wantsLead,
        language = ns.MatchLanguages.wireText(),
        lastSent = Comm.lastSent,
    })
    ns.engine:start(false)
    ns.QuestQueue.start(selfName)
    ns.BgQueue.start(selfName)
    restoreQueue()
    ns.QuestQueue.restore()
    ns.BgQueue.restore()
    ns.QuestGroup.restore()
    ns.GroupView.restore()
    ns.RoleSync.apply()
    PartyStatus.onReady()
    ns.Version.onReady()
    ns.Presence.start()
    Window.refresh()
    ns.Demo.maybeStart()
end

-- Any message of a player shows it is alive, in both queues: a player in
-- both sends one stream of keep-alives, not two.
local function onMessage(sender, text)
    ns.Presence.seen(sender)
    if string.find(text, "^v%d+|S|") then
        ns.Presence.newcomer()
    end
    for _, engine in ipairs(ns.Queues.engines()) do
        engine.queue:touch(sender, engine:now())
    end
    if ns.Version.onMessage(sender, text) or ns.Entrances.onMessage(sender, text) then
        return
    end
    for _, engine in ipairs(ns.Queues.engines()) do
        engine:receive(sender, text)
    end
end

local ticks = 0

-- One failing step must not stop the steps after it every second; the
-- error still goes to WoW's error handler.
local function step(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        geterrorhandler()(err)
    end
end

local function tick()
    if ns.Demo.isOn() then
        step(Status.refresh)
        step(Window.refresh)
        return
    end
    if ns.engine then
        step(ns.engine.tick, ns.engine)
    end
    step(ns.QuestQueue.tick)
    step(ns.BgQueue.tick)
    step(ns.BgFinder.tick)
    if syncPending then
        step(syncEntry)
    end
    step(Comm.flush)
    step(ns.WhisperInvite.tick)
    step(Filler.tick)
    step(ns.Apply.tick)
    step(ns.AutoFill.tick)
    step(ns.Listing.tick)
    step(ns.GroupView.check)
    step(ns.Entrances.tick)
    step(ns.GroupPlaces.tick)
    step(ns.InspectSpec.tick)
    step(Status.refresh)
    step(ns.MinimapButton.refresh)
    ticks = ticks + 1
    if ticks % 5 == 0 then
        step(ns.RoleSync.apply)
        step(syncEntry)
        step(Filler.recompute)
    end
    step(Window.refresh)
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
    local fresh = ForeverGroupsDB == nil
    ForeverGroupsDB = ForeverGroupsDB or {}
    ForeverGroupsCharDB = ForeverGroupsCharDB or {}
    ns.db = ForeverGroupsDB
    ns.charDb = ForeverGroupsCharDB
    -- The first-time demo is for new players: one who used Forever Groups
    -- before (saved settings exist) can start it from the settings or /fg demo.
    if ns.db.tourSeen == nil then
        if fresh then
            ns.db.tourSeen = false
        else
            ns.db.tourSeen = true
        end
    end
    ns.db.queueSort, ns.db.queueSortReverse, ns.db.queueSorts, ns.db.queueTab = nil, nil, nil, nil
    ns.db.dryRun, ns.db.slots, ns.db.ownLanguageOnly = nil, nil, nil
    Comm.init(onReady, onMessage, function(sender, text)
        ns.Presence.seen(sender)
        if not ns.QuestShare.onMessage(sender, text) and not ns.QuestGroup.onMessage(sender, text)
            and not ns.GroupPlaces.onMessage(sender, text) then
            PartyStatus.onMessage(sender, text)
        end
    end, function(sender)
        for _, engine in ipairs(ns.Queues.engines()) do
            engine:forget(sender)
        end
    end)
    ns.Whispers.init()
    ns.FinderTab.init()
    Group.init()
    ns.LfgList.init()
    ns.Invites.init()
    Filler.init()
    ns.PartyCompose.init()
    ns.PartyLevels.init()
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
    ns.BgQueue.init()
    ns.QuestFinder.init()
    ns.BgFinder.init()
    ns.Spec.init()
    ns.Diagnostics.init()
    ns.QuestGroup.init()
    ns.Entrances.init()
    ns.GroupPlaces.init()
    ns.InspectSpec.init()
    ns.Run.init()
    ns.TakeLead.init()
    ns.Slash.init()
end)

ns.on("PLAYER_LOGIN", function()
    -- After a /reload the group is already there: follow it and hold the
    -- player's role right away, before WoW's role from the spec sticks.
    ns.GroupView.restore(true)
    ns.RoleSync.apply()
    ns.LfgList.loadLevelRanges()
    ns.LfgList.loadZones()
    ns.Entrances.loadFromWoW()
    ns.KeySearch.init()
    -- Since Forever 1.60.1 trial accounts can't send addon messages.
    local trial = (type(IsTrialAccount) == "function" and IsTrialAccount())
        or (type(IsVeteranTrialAccount) == "function" and IsVeteranTrialAccount())
    if trial then
        Log.warn("On a trial account WoW doesn't let addons talk to each other, so other Forever Groups players "
            .. "can't see you in the queue. Finding a group through WoW's Group Finder still works.")
    end
    ns.Settings.register()
    ns.MinimapButton.refresh()
    ns.Demo.welcome()
    Comm.start()
    C_Timer.NewTicker(1, tick)
end)

ns.on("PLAYER_LOGOUT", function()
    persistQueue()
    ns.QuestQueue.persist()
    ns.BgQueue.persist()
    if ns.engine and ns.engine.myEntry then
        Comm.sendNow(ns.Protocol.encode({ kind = "leave" }))
    end
    if ns.questEngine and ns.questEngine.myEntry then
        Comm.sendNow(ns.Protocol.encode({ kind = "leave" }, ns.Protocol.QUESTS))
    end
    if ns.bgEngine and ns.bgEngine.myEntry then
        Comm.sendNow(ns.Protocol.encode({ kind = "leave" }, ns.Protocol.BATTLEGROUNDS))
    end
end)

function ForeverGroups_OnAddonCompartmentClick()
    Window.toggle()
end

ForeverGroups = ns
