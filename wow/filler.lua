local _, ns = ...

local Fill = ns.Fill
local Roles = ns.Roles
local Dungeons = ns.Dungeons
local Party = ns.Party
local LfgList = ns.LfgList
local Widgets = ns.Widgets
local Log = ns.Log

-- Fills a group's open roles from WoW's Group Finder: whispers and invites
-- the best listed players, replaces anyone who declines or does not join in
-- time, and asks for a click when the results are used up or too old.
local Filler = {}

local INVITE_TIMEOUT = 30
-- How long a role is left to a waiting Forever Groups player before the
-- Group Finder fills it after all (the matchmaker may not group them, e.g.
-- when their level does not fit the dungeon).
local ADDON_GRACE = 20
-- Results stay usable this long: delisted players drop out of them as WoW
-- reports it, only new listings need a search (which needs player input).
local STALE_RESULTS = 300
local DECLINE_MESSAGES = { "ERR_DECLINE_GROUP_S", "ERR_ALREADY_IN_GROUP_S", "ERR_BAD_PLAYER_NAME_S" }

local state
local frame
local ui = {}
local changeListeners = {}

local function changed()
    for _, listener in ipairs(changeListeners) do
        listener()
    end
end

local function removeLetter(letters, role)
    local i = string.find(letters, role, 1, true)
    if not i then
        return letters
    end
    return string.sub(letters, 1, i - 1) .. string.sub(letters, i + 1)
end

local function describeLetters(letters)
    local names = {}
    for letter in string.gmatch(letters, ".") do
        names[#names + 1] = Widgets.ROLE_NAMES[letter]
    end
    return table.concat(names, ", ")
end

local function rangeOf(id)
    local dungeon = Dungeons.get(id)
    return dungeon and dungeon.min and { min = dungeon.min, max = dungeon.max } or nil
end

local function stillNeeded()
    local needed = state.open
    for _, pending in pairs(state.pending) do
        needed = removeLetter(needed, pending.role)
    end
    return needed
end

local function render()
    if not frame then
        return
    end
    if not state then
        frame:Hide()
        return
    end
    local lines = {}
    lines[#lines + 1] = state.dungeon and ("For " .. Dungeons.name(state.dungeon)) or "Choosing a dungeon..."
    lines[#lines + 1] = "Still open: " .. (state.open ~= "" and describeLetters(state.open) or "nothing")
    for name, pending in pairs(state.pending) do
        lines[#lines + 1] = string.format("Invited %s as %s, waiting...", name, Widgets.ROLE_NAMES[pending.role])
    end
    if state.message then
        lines[#lines + 1] = state.message
    end
    ui.text:SetText(table.concat(lines, "\n"))
    frame:Show()
end

local function build()
    frame = Widgets.window("ForeverGroupsFillFrame", "Filling from the Group Finder", 340, 170, false)
    frame:ClearAllPoints()
    frame:SetPoint("TOPRIGHT", -40, -200)
    ui.text = Widgets.text(frame, "GameFontHighlightSmall")
    ui.text:SetPoint("TOPLEFT", 16, -30)
    ui.text:SetWidth(308)
    ui.search = Widgets.button(frame, "Search again", 130)
    ui.search:SetPoint("BOTTOMLEFT", 16, 12)
    ui.search:SetScript("OnClick", function()
        Filler.searchAgain()
    end)
    ui.stop = Widgets.button(frame, "Stop", 100)
    ui.stop:SetPoint("BOTTOMRIGHT", -16, 12)
    ui.stop:SetScript("OnClick", function()
        Filler.stop()
    end)
end

local function whisper(name, text)
    if not text or ns.db.noWhisper then
        return
    end
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
        return
    end
    ns.Whispers.send(name, text)
end

local function invite(pick)
    state.exclude[pick.name] = true
    local role = Widgets.ROLE_NAMES[pick.role]
    if ns.db.dryRun then
        Log.info("[dry run] Would invite %s as %s for %s.", pick.name, role, Dungeons.name(state.dungeon))
        state.open = removeLetter(state.open, pick.role)
        return
    end
    state.pending[pick.name] = { role = pick.role, at = GetTime() }
    state.invited[pick.name] = pick.role
    ns.RoleSync.expect(pick.name, pick.role)
    whisper(pick.name, ns.Messages.text("fillInvite", {
        dungeon = Dungeons.name(state.dungeon), role = string.lower(role), spec = ns.Spec.myLabel(),
    }))
    local ok, err = pcall(C_PartyInfo.InviteUnit, pick.name)
    if not ok then
        Log.debug("invite %s failed: %s", pick.name, tostring(err))
    end
    Log.detail("Invited %s from the Group Finder as %s.", pick.name, role)
end

local function finish(text)
    if text then
        Log.detail(text)
    end
    state = nil
    render()
    changed()
end

local function proposalOpen(engine)
    local key = engine and engine.myProposalKey
    local proposal = key and engine.proposals[key]
    return proposal ~= nil and not proposal.outcome
end

-- A group proposal in either queue (or the dungeon queue held for one in
-- the questing queue): no inviting until it is answered.
local function queueProposalOpen()
    return proposalOpen(ns.engine) or proposalOpen(ns.questEngine) or (ns.engine ~= nil and ns.engine.held == true)
end

local function wantsDungeon(entry, dungeons)
    for _, id in ipairs(entry.dungeons or {}) do
        for _, wanted in ipairs(dungeons) do
            if id == wanted then
                return true
            end
        end
    end
    return false
end

-- The roles of `needed` that solo Forever Groups players waiting in the
-- queue for this dungeon can play: those go to them, through the matchmaker.
-- Only while our own group is in the queue (else the matchmaker cannot pair
-- us), and only players who are not building a group of their own.
local function addonRoles(needed)
    local engine = ns.engine
    if not engine or not engine.myEntry or needed == "" then
        return ""
    end
    local dungeons = state.dungeon and { state.dungeon } or state.dungeons or {}
    local style = ns.Playstyle.forGroup()
    local now, left, covered = engine:now(), needed, ""
    for _, other in ipairs(engine.queue:list()) do
        local recent = now - (other.lastSeen or now) <= engine.config.HEARTBEAT_INTERVAL + 15
        if other.id ~= engine.name and recent and not engine.fakes[other.id] and not engine:isReserved(other.id)
            and #other.members == 1 and (other.reserved or "") == "" and not state.exclude[other.id]
            and wantsDungeon(other, dungeons)
            and ns.Playstyles.compatible(style, other.playstyle) then
            for _, role in ipairs({ "T", "H", "D" }) do
                if string.find(other.members[1].roles, role, 1, true) and string.find(left, role, 1, true) then
                    left = removeLetter(left, role)
                    covered = covered .. role
                    break
                end
            end
        end
    end
    return covered
end

function Filler.step()
    if not state then
        return
    end
    local partyState = Party.state()
    if partyState == "member" or partyState == "raid" then
        finish("You joined another group, so Forever Groups stopped inviting players.")
        return
    end
    if state.open == "" and next(state.pending) == nil then
        finish(ns.db.dryRun and "[dry run] Every open role has a candidate." or "Group complete!")
        return
    end
    local needed = stillNeeded()
    if needed == "" then
        render()
        return
    end
    -- Forever Groups players first: their roles wait for the matchmaker.
    local forAddon = addonRoles(needed)
    local leaving
    if forAddon == "" then
        state.addonSince = nil
    else
        state.addonSince = state.addonSince or GetTime()
        if GetTime() - state.addonSince < ADDON_GRACE then
            for letter in string.gmatch(forAddon, ".") do
                needed = removeLetter(needed, letter)
            end
            leaving = "Leaving " .. describeLetters(forAddon) .. " to Forever Groups players in the queue."
            state.message = leaving
            if needed == "" then
                render()
                return
            end
        end
    end
    if queueProposalOpen() then
        state.message = "Waiting for the queue's group proposal before inviting more."
        render()
        return
    end
    if ns.QuestFinder.summary().invited > 0 then
        state.message = "Waiting for the players invited for your questing group."
        render()
        return
    end
    local listings, updatedAt = LfgList.listings()
    listings = ns.Playstyle.filter(listings, ns.Playstyle.forGroup())
    if not updatedAt or GetTime() - updatedAt > STALE_RESULTS then
        state.message = ns.KeySearch.isReady() and "Refreshing the Group Finder while you play..."
            or "Group Finder results are too old. Click the Forever Groups bar to search again."
        state.needSearch = true
        render()
        return
    end
    local picks, open
    if state.dungeon then
        picks, open = Fill.pick(listings, {
            missing = needed, dungeon = state.dungeon, exclude = state.exclude, range = rangeOf(state.dungeon),
        })
    else
        local ranges = {}
        for _, id in ipairs(state.dungeons) do
            ranges[id] = rangeOf(id)
        end
        local plan = Fill.plan(listings, {
            missing = needed, dungeons = state.dungeons, exclude = state.exclude, ranges = ranges,
        })
        picks, open = plan.picks, plan.open
        if #picks > 0 then
            state.dungeon = plan.dungeon
            ns.GroupView.track(plan.dungeon)
        end
    end
    for _, pick in ipairs(picks) do
        invite(pick)
    end
    if #picks > 0 then
        changed()
    end
    state.message = open ~= "" and ("Nobody listed for: " .. describeLetters(open) .. ". Searching again soon.")
        or leaving
    state.needSearch = open ~= ""
    if state.open == "" and next(state.pending) == nil then
        Filler.step()
        return
    end
    render()
end

-- opts: missing ("HD"), dungeon (fixed) or dungeons (to choose from),
-- members (names already in or joining the group).
function Filler.start(opts)
    if not frame then
        build()
    end
    local exclude = { [ns.selfName] = true }
    for _, name in ipairs(opts.members or {}) do
        exclude[name] = true
    end
    local dungeons = opts.dungeons or { opts.dungeon }
    local dungeon = opts.dungeon or (#dungeons == 1 and dungeons[1] or nil)
    state = {
        open = opts.missing, dungeon = dungeon, dungeons = dungeons,
        pending = {}, late = {}, exclude = exclude, invited = {},
    }
    if dungeon then
        ns.GroupView.track(dungeon)
    end
    Log.detail("Looking in the Group Finder for: %s.", describeLetters(opts.missing))
    Filler.step()
end

-- Only from a click or typed command (the Group Finder search is protected).
function Filler.searchAgain()
    if not LfgList.search() then
        Log.warn("WoW did not allow the Group Finder search.")
    end
end

function Filler.stop(quiet)
    if state then
        finish(not quiet and "Stopped filling from the Group Finder." or nil)
    end
end

function Filler.isActive()
    return state ~= nil
end

function Filler.stillNeeded()
    return state and stillNeeded() or ""
end

function Filler.excluded()
    return state and state.exclude or {}
end

-- An invite sent another way (an applicant to our listing) counts like one of
-- ours: its role is reserved, and joining or not is followed the same way.
function Filler.trackInvite(name, role)
    if not state or queueProposalOpen() then
        return false
    end
    state.exclude[name] = true
    state.pending[name] = { role = role, at = GetTime() }
    state.invited[name] = role
    ns.RoleSync.expect(name, role)
    changed()
    render()
    return true
end

-- Whether a fresh Group Finder search would help: roles are still open and
-- the results are used up or older than `age` seconds.
function Filler.wantsSearch(age)
    if not state or stillNeeded() == "" or LfgList.secondsSinceSearch() < 10 then
        return false
    end
    local _, updatedAt = LfgList.listings()
    return state.needSearch or not updatedAt or GetTime() - updatedAt > (age or STALE_RESULTS)
end

-- Searches if that would help; only from a click or key press.
function Filler.searchIfUseful(age)
    if Filler.wantsSearch(age) then
        state.needSearch = false
        LfgList.search()
        return true
    end
    return false
end

-- A party member switched roles: the roles still open follow the party as it
-- is now (invites that are still out keep their role).
function Filler.recompute()
    local party = Party.members()
    if not state or ns.db.dryRun or party == nil then
        return
    end
    local me = ns.RoleSync.expected(ns.selfName) or (ns.engine and ns.engine.myEntry
        and ns.engine.myEntry.members[1].roles) or ns.charDb.lastRoles or "D"
    local members, counted = { { name = ns.selfName, roles = me } }, { [ns.selfName] = true }
    local inParty = {}
    for _, member in ipairs(party) do
        inParty[member.name] = true
    end
    for name, role in pairs(ns.RoleSync.all()) do
        local present = inParty[name] or ns.Group.isExpected(name)
        if present and not counted[name] and not state.pending[name] then
            counted[name] = true
            members[#members + 1] = { name = name, roles = role }
        end
    end
    for _, member in ipairs(party) do
        if not counted[member.name] then
            counted[member.name] = true
            members[#members + 1] = { name = member.name, roles = ns.PartyRoles.rolesOf(member) }
        end
    end
    local missing = Filler.missingFor(members)
    if missing and missing ~= state.open then
        Log.detail("Roles changed; now looking for: %s.", missing ~= "" and describeLetters(missing) or "nobody")
        state.open = missing
        changed()
        Filler.step()
    end
end

-- One line for the status bar: who is invited, or what is still sought.
function Filler.summary()
    if not state then
        return nil
    end
    local invited = {}
    for name, pending in pairs(state.pending) do
        invited[#invited + 1] = name .. " (" .. Widgets.ROLE_NAMES[pending.role] .. ")"
    end
    table.sort(invited)
    if #invited > 0 then
        return "inviting " .. table.concat(invited, ", ")
    end
    if state.open ~= "" then
        return "looking for " .. describeLetters(state.open)
    end
    return nil
end

-- Roles of invites that are still out, e.g. "HD".
function Filler.reservedRoles()
    if not state then
        return ""
    end
    local counts = { T = 0, H = 0, D = 0 }
    for _, pending in pairs(state.pending) do
        counts[pending.role] = counts[pending.role] + 1
    end
    return Roles.fromCounts(counts)
end

-- Invites still out, { name = role }, so they survive a /reload.
function Filler.pendingInvites()
    local invites = {}
    for name, pending in pairs(state and state.pending or {}) do
        invites[name] = pending.role
    end
    return invites
end

-- The role a player was invited for from the Group Finder, if any.
function Filler.roleOf(name)
    return state and state.invited[name]
end

function Filler.dungeon()
    return state and state.dungeon
end

-- The dungeon(s) this fill is for; empty when not filling.
function Filler.dungeonIds()
    if not state then
        return {}
    end
    return state.dungeon and { state.dungeon } or state.dungeons
end

function Filler.onChange(listener)
    changeListeners[#changeListeners + 1] = listener
end

-- A queue group formed around this party: from now on only the roles the
-- queue left open (`missing`) are filled from the Group Finder.
function Filler.adopt(view)
    if not state then
        return false
    end
    state.open = view.missing
    state.dungeon = view.dungeon
    for _, member in ipairs(view.members) do
        state.exclude[member.name] = true
    end
    state.message = nil
    Filler.step()
    return true
end

-- nil while a party member's name is still loading.
local function partyNames()
    local members = Party.members()
    if not members then
        return nil
    end
    local names = {}
    for _, member in ipairs(members) do
        names[member.name] = true
    end
    return names
end

-- Who of the invited players joined. Runs on roster changes and every tick,
-- so a join seen while names were still loading is picked up later.
local function checkJoins()
    if not state then
        return false
    end
    local partyState = Party.state()
    if partyState == "member" or partyState == "raid" then
        finish("You joined another group, so Forever Groups stopped inviting players.")
        return true
    end
    local inParty = partyNames()
    if not inParty then
        return false
    end
    local found = false
    for name, pending in pairs(state.pending) do
        if inParty[name] then
            state.pending[name] = nil
            state.open = removeLetter(state.open, pending.role)
            found = true
            Log.detail("%s joined as %s.", name, Widgets.ROLE_NAMES[pending.role])
        end
    end
    for name, role in pairs(state.late) do
        if inParty[name] then
            state.late[name] = nil
            found = true
            ns.RoleSync.expect(name, role)
            if string.find(state.open, role, 1, true) then
                state.open = removeLetter(state.open, role)
                Log.detail("%s joined after all, as %s.", name, Widgets.ROLE_NAMES[role])
            else
                Log.warn("%s joined after all, but the %s spot was given to someone else.", name,
                    Widgets.ROLE_NAMES[role])
            end
        end
    end
    return found
end

local function onRosterUpdate()
    if not state then
        return
    end
    checkJoins()
    if state then
        changed()
        Filler.step()
    end
end

local declinePatterns
local function patterns()
    if not declinePatterns then
        declinePatterns = {}
        for _, key in ipairs(DECLINE_MESSAGES) do
            local format = _G[key]
            if type(format) == "string" then
                local pattern = string.gsub(format, "([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
                pattern = string.gsub(pattern, "%%s", "(.+)")
                declinePatterns[#declinePatterns + 1] = "^" .. pattern .. "$"
            end
        end
    end
    return declinePatterns
end

-- The player named in a "declines your invitation" (or similar) message.
function Filler.declinedName(text)
    if type(text) ~= "string" then
        return nil
    end
    for _, pattern in ipairs(patterns()) do
        local name = string.match(text, pattern)
        if name then
            return name
        end
    end
    return nil
end

local function onSystemMessage(text)
    if not state or type(text) ~= "string" then
        return
    end
    for _, pattern in ipairs(patterns()) do
        local name = string.match(text, pattern)
        if name and state.pending[name] then
            state.pending[name] = nil
            ns.RoleSync.forget(name)
            Log.detail("%s did not join; trying someone else.", name)
            changed()
            Filler.step()
            return
        end
    end
end

function Filler.tick()
    if not state then
        return
    end
    if checkJoins() then
        if state then
            changed()
            Filler.step()
        end
        return
    end
    local now, expired = GetTime(), false
    for name, pending in pairs(state.pending) do
        if now - pending.at > INVITE_TIMEOUT then
            state.pending[name] = nil
            state.late[name] = pending.role
            ns.RoleSync.forget(name)
            expired = true
            Log.detail("%s did not answer the invite; trying someone else.", name)
        end
    end
    if expired then
        changed()
        Filler.step()
    elseif state.message and not queueProposalOpen() and stillNeeded() ~= "" then
        Filler.step()
    end
end

-- The open roles a party could still need, leaving DPS open rather than a
-- tank or healer when its flexible players allow either. Also returns the
-- role each member then plays.
function Filler.missingFor(members)
    local best
    for _, option in ipairs(Roles.options(members, ns.Config.SLOTS)) do
        local open = {
            T = ns.Config.SLOTS.T - option.counts.T, H = ns.Config.SLOTS.H - option.counts.H,
            D = ns.Config.SLOTS.D - option.counts.D,
        }
        local score = open.T * 100 + open.H * 10 + open.D
        if not best or score < best.score then
            best = { score = score, letters = Roles.fromCounts(open), assignment = option.assignment }
        end
    end
    if best then
        return best.letters, best.assignment
    end
end

function Filler.init()
    ns.on("GROUP_ROSTER_UPDATE", onRosterUpdate)
    ns.on("CHAT_MSG_SYSTEM", onSystemMessage)
    LfgList.onUpdate(Filler.step)
end

ns.Filler = Filler
