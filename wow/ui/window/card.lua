local _, ns = ...

local L = ns.L

local W = ns.WindowParts
local Widgets = ns.Widgets
local Dungeons = ns.Dungeons
local Party = ns.Party
local Roles = ns.Roles
local PAD = W.PAD
local GREEN = W.GREEN
local GOLD = W.GOLD
local CONNECTION_COLORS = W.CONNECTION_COLORS
local SLOT_ROLES = W.SLOT_ROLES
local SLOT_GAP = W.SPACE.s
local ACTION_HEIGHT = 24
local ui = W.ui
local slots = W.slots

-- What the queue, the group or the party is doing, under the roles on every
-- tab: a title line with a line or two under it and, on the Dungeons tab,
-- the group's five places where the class choices sit while choosing. Once
-- there is a group, its actions take the place of the dungeon list.

-- What the status shows: { title, subtitle, detail, lead, color }, or
-- { group, lead, color } for a group Forever Groups follows.
function W.dungeonStatus(state)
    local status = ns.Status.current("dungeons")
    if status and status.group then
        return { group = status.group, lead = status.lead, color = status.done and GREEN or GOLD }
    end
    if status then
        local color = (status.done and GREEN) or GOLD
        return { title = status.text, subtitle = status.headline, detail = status.detail, lead = status.lead,
            color = color }
    end
    if state == "raid" then
        return { title = "You are in a raid", subtitle = "Leave the raid to queue.", color = GOLD }
    end
    if state ~= "solo" then
        local size = #ns.GroupView.composition().members
        local run = ns.Run.isInside() and ns.Run.current()
        if size >= 5 then
            return { title = "Your party is complete (5/5)", color = GREEN, lead = state == "leader",
                subtitle = run and (Dungeons.name(run.dungeon) .. ": " .. ns.Run.describe(run)) or "No need to queue." }
        end
        local subtitle = state ~= "leader" and "Your party leader queues for the group." or nil
        return { title = string.format(L["Your party: %d/5"], size), subtitle = subtitle, color = GOLD,
            lead = state == "leader" }
    end
    return { color = GOLD }
end

-- The Quests tab's status: the questing queue, a proposal, or the group.
function W.questStatus(state)
    -- Still connecting: the window simply shows what it can (the title
    -- bar's dot says it is connecting).
    if not ns.questEngine then
        return { color = GOLD }
    end
    local proposal = ns.questEngine.myProposalKey and ns.questEngine.proposals[ns.questEngine.myProposalKey]
    if proposal and not proposal.outcome then
        local left = math.max(0, proposal.answerDeadline - GetServerTime())
        return { title = string.format(L["Group found for %s! %d s to accept"], ns.Quests.nameOf(proposal.dungeon),
            left), color = GREEN, lead = proposal.leader == ns.selfName }
    end
    local invites = ns.Group.status()
    if invites and ns.QuestMatch.parse(invites.dungeon) then
        local name = ns.Quests.nameOf(invites.dungeon)
        if invites.role == "member" then
            return { title = string.format(L["Accept the invite from %s"], invites.leader), color = GREEN,
                subtitle = string.format(L["A questing group for %s was found."], name) }
        end
        return { title = string.format(L["Inviting your group: %d of %d joined"], invites.joined, invites.total),
            color = GREEN, lead = true, subtitle = string.format(L["Questing group for %s"], name) }
    end
    local group = ns.QuestGroup.isQuesting() and ns.QuestGroup.current()
    if group and state ~= "solo" then
        local titles = {}
        for i, id in ipairs(group.quests) do
            titles[i] = ns.Quests.titleOf(id)
        end
        return { title = string.format(L["Questing group: %s"], table.concat(titles, ", ")), color = GREEN,
            lead = state == "leader",
            subtitle = "Everyone's progress folds out under the status bar (/fg progress)." }
    end
    local entry = ns.QuestQueue.entry()
    if entry then
        local parts = { ns.QuestQueue.describe(entry.dungeons) }
        local invitees, since = ns.QuestFinder.waiting()
        if invitees then
            parts[#parts + 1] = string.format(L["waiting for %s to accept (%s of 1:00)"], table.concat(invitees, ", "),
                Widgets.formatTime(since))
        end
        if ns.Listing.isOurs() then
            parts[#parts + 1] = L["listed in the Group Finder"]
        end
        return {
            title = string.format(L["Looking for a questing group %s as %s"],
                Widgets.formatTime(GetServerTime() - entry.joinedAt), Widgets.describeRoles(entry.members[1].roles)),
            subtitle = table.concat(parts, "  ·  "), color = GOLD, lead = #entry.members > 1,
        }
    end
    return { color = GOLD }
end

function W.refreshConnection()
    local bar = ui.connectionBar
    local connection = ns.Comm.connection()
    local newer = ns.Version.newer()
    if newer then
        connection.text = L[connection.text] .. " · " .. L["update available"]
        connection.detail = L[connection.detail] .. "\n"
            .. string.format(L["Forever Groups %s is out; you have %s. Please update."], newer.version,
                tostring(ns.Version.mine()))
    end
    local color = CONNECTION_COLORS[connection.state]
    Widgets.paintDot(bar.dot, color)
    local plain = connection.state == "connected" and not newer
    bar.label:SetText(plain and "" or L[connection.text])
    bar.label:SetTextColor(color[1], color[2], color[3])
    bar.info = connection
    -- The dot pulses while connecting, so the window shows it is on its way.
    if connection.state == "connecting" then
        if not bar.pulsing then
            bar.pulsing = true
            bar:SetScript("OnUpdate", function()
                bar.dot:SetAlpha(0.35 + 0.65 * math.abs(math.sin(GetTime() * 2.5)))
            end)
        end
    elseif bar.pulsing then
        bar.pulsing = false
        bar:SetScript("OnUpdate", nil)
        bar.dot:SetAlpha(1)
    end
end

-- The five places of the group being searched for, solo or not yet in a
-- party: the queued members in the role they will most likely play, players
-- invited from the Group Finder, and the places still open.
function W.queuedComposition(entry)
    local members = Roles.withReserved(entry.members, entry.reserved)
    local _, assignment = ns.Filler.missingFor(members)
    local places = {}
    for i, role in ipairs(SLOT_ROLES) do
        places[i] = { role = role }
    end
    for i, member in ipairs(members) do
        local role = assignment and assignment[i] or string.sub(member.roles, 1, 1)
        for _, slot in ipairs(places) do
            if slot.role == role and not slot.taken then
                slot.taken = true
                if member.reserved then
                    slot.reserved = true
                else
                    slot.name = member.name
                    slot.classToken = member.name == ns.selfName and Party.playerClass() or nil
                end
                break
            end
        end
    end
    return { slots = places }
end

-- The places on the Dungeons tab: the party or group, else the queue
-- entry's; nil when there is neither.
local function composition()
    if Party.inGroup() or ns.GroupView.isTracking() then
        return ns.GroupView.composition()
    elseif ns.engine and ns.engine.myEntry then
        return W.queuedComposition(ns.engine.myEntry)
    end
    return nil
end

-- The roles a party member is queued for and where they come from, for
-- their tooltip; nil for anyone else.
function W.memberRoleInfo(name, members)
    for _, member in ipairs(members or Party.members()) do
        if member.name == name then
            return Widgets.describeRoles(ns.PartyRoles.rolesOf(member)) .. "  ("
                .. L[ns.PartyRoles.sourceOf(member)] .. ")"
        end
    end
    return nil
end

-- OnEnter of a place showing a party member: self.roleInfo, under
-- self.roleName.
function W.showRoleInfo(self)
    if not self.roleInfo or not GameTooltip then
        return
    end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText(self.roleName or "", 1, 0.82, 0)
    GameTooltip:AddLine(self.roleInfo, 1, 1, 1)
    GameTooltip:AddLine(L["Roles follow each member's role in WoW."], 0.75, 0.75, 0.75, true)
    GameTooltip:Show()
end

-- The data W.paintPlace draws the places with, the extra lines they share,
-- and how many members are at the entrance and inside.
-- roleInfo: the roles each party member is queued for go in their tooltip.
-- choosing: the leader of a run may pick the classes for its open places
-- (the party's class choices, wow/partycompose.lua) before Find replacement.
local function placeRows(places, roleInfo, choosing)
    local groupDungeon = ns.GroupView.trackedDungeon()
    local quests = groupDungeon and ns.QuestShare.summary(groupDungeon)
    local inside = IsInInstance() and true or false
    local distances = groupDungeon and (inside or ns.Entrances.get(groupDungeon) ~= nil)
    local counts = {}
    if quests then
        -- The own name comes with the channel handshake, a few seconds
        -- after login; the window may open before.
        if ns.selfName then
            counts[ns.selfName] = quests.mine
        end
        for _, member in ipairs(quests.members) do
            counts[member.name] = member.count or (ns.Presence.isOnline(member.name) and "?" or "none")
        end
    end
    local partyMembers = roleInfo and Party.members() or {}
    local rows, layout = {}, { distance = distances and true or false, quests = quests and true }
    local facts = { atEntrance = 0, inside = 0, insideAll = inside, distances = distances }
    local invites = ns.Filler.invites()
    for i, data in ipairs(places.slots) do
        local row = { role = data.role, name = data.name, classToken = data.classToken }
        row.roleInfo = W.memberRoleInfo(data.name, partyMembers)
        if not data.name then
            for n, invite in ipairs(invites) do
                if invite.role == data.role then
                    row.invite = table.remove(invites, n)
                    break
                end
            end
            if data.reserved and not row.invite then
                row.invite = {}
            end
        end
        if data.name then
            row.specIndex = data.specIndex or ns.Spec.indexOf(data.name)
            row.quests = counts[data.name]
            local offline = false
            if data.unit and type(UnitIsConnected) == "function" then
                local ok, connected = pcall(UnitIsConnected, data.unit)
                offline = ok and connected == false
            end
            if offline then
                row.distance = "offline"
            elseif distances then
                local place = ns.GroupPlaces.of(data.name, data.unit, groupDungeon)
                if place == nil and not inside then
                    place = false
                elseif place == nil then
                    place = counts[data.name] == "none" and "none" or "?"
                end
                row.distance = place
                if place == "in" then
                    facts.inside = facts.inside + 1
                elseif type(place) == "number" and ns.Entrances.isAt(place) then
                    facts.atEntrance = facts.atEntrance + 1
                end
            end
        end
        rows[i] = row
    end
    -- An open place the class choices keep for some classes shows them.
    local free = not choosing and ns.PartyCompose.freePlaces()
    if choosing then
        local fixed = ns.PartyCompose.fixed()
        local masks = ns.PartyCompose.settings().masks
        local openByRole = {}
        for slot, role in ipairs(ns.Compose.SLOT_ROLES) do
            if not fixed[slot] then
                openByRole[role] = openByRole[role] or {}
                table.insert(openByRole[role], slot)
            end
        end
        for _, row in ipairs(rows) do
            local slot = not row.name and not row.invite and table.remove(openByRole[row.role] or {}, 1)
            if slot then
                row.wishSlot = slot
                local mask = masks[slot] or 0
                row.classes = mask ~= 0 and ns.Compose.classesOf(mask) or nil
            end
        end
    elseif free then
        local byRole = {}
        for _, place in ipairs(free) do
            byRole[place.role] = byRole[place.role] or {}
            table.insert(byRole[place.role], place)
        end
        for _, row in ipairs(rows) do
            local place = not row.name and not row.invite and table.remove(byRole[row.role] or {}, 1)
            if place and place.mask ~= 0 then
                row.classes = ns.Compose.classesOf(place.mask)
            end
        end
    end
    -- Everyone inside: the title line says so, the places leave it out.
    if inside and places.members and facts.inside == #places.members then
        layout.distance = false
    end
    -- A member who went offline says so where the distance goes, also while
    -- the row shows no distances.
    for _, row in ipairs(rows) do
        if row.distance == "offline" then
            layout.distance = true
        end
    end
    return rows, layout, facts
end

-- "Group complete  ·  Relaxed  ·  you lead  ·  3 of 5 at the entrance",
-- after the group's dungeon on the title line.
local function groupLine(content, facts)
    local group = content.group
    local parts = { group.complete and L["Group complete"]
        or string.format(L["%d/5, open: %s"], group.count, group.openText) }
    local styles = ns.Playstyle.describe(group.playstyles, " / ")
    if styles then
        parts[#parts + 1] = styles
    end
    if content.lead then
        parts[#parts + 1] = L["you lead"]
    end
    if facts.insideAll then
        parts[#parts + 1] = string.format(L["%d of %d inside"], facts.inside, group.count)
    elseif facts.distances then
        parts[#parts + 1] = string.format(L["%d of %d at the entrance"], facts.atEntrance, group.count)
        if facts.inside > 0 then
            parts[#parts + 1] = string.format(L["%d inside"], facts.inside)
        end
    end
    if group.run then
        parts[#parts + 1] = group.run
    end
    return table.concat(parts, "  ·  ")
end

function W.hideStatus()
    for _, widget in ipairs({ ui.statusCrown, ui.statusTitle, ui.statusLine, ui.statusInfo, ui.statusSubtitle,
        ui.statusDetail, ui.progressLink }) do
        widget:Hide()
    end
    for _, slot in ipairs(slots) do
        slot:Hide()
        W.closeClassCard(slot)
    end
end

-- Places the status from y down; returns the new y. tab: "dungeons",
-- "quests" or "battlegrounds". options.places: show the group's places
-- (Dungeons tab); options.roleInfo: a leader setting up the party sees each
-- member's queued roles on hovering their place.
function W.layoutStatus(y, tab, state, options)
    options = options or {}
    local content = (tab == "quests" and W.questStatus(state))
        or (tab == "battlegrounds" and W.battlegroundStatus(state)) or W.dungeonStatus(state)
    local places = tab == "dungeons" and options.places and composition() or nil
    local rows, layout, facts
    if places then
        rows, layout, facts = placeRows(places, options.roleInfo, options.chooseReplacements)
    end
    local hasTitle = content.title ~= nil or content.group ~= nil
    if not hasTitle and not places then
        W.hideStatus()
        return y
    end
    local x = PAD
    ui.statusCrown:SetShown(hasTitle and content.lead == true)
    if hasTitle and content.lead then
        ui.statusCrown:ClearAllPoints()
        ui.statusCrown:SetPoint("RIGHT", ui.statusTitle, "LEFT", -4, 0)
        x = PAD + 20
    end
    local progress = hasTitle and tab == "quests" and ns.QuestGroup.current() ~= nil and #ns.QuestGroup.rows() > 0
    ui.progressLink:SetShown(progress)
    if progress then
        ui.progressLink:ClearAllPoints()
        ui.progressLink:SetPoint("TOPRIGHT", W.frame, "TOPRIGHT", W.RIGHT_OFFSET, y - 3)
    end
    local title, info = ui.statusTitle, ui.statusInfo
    title:SetShown(hasTitle)
    ui.statusLine:SetShown(hasTitle)
    info:SetShown(hasTitle and content.group ~= nil)
    ui.statusSubtitle:Hide()
    ui.statusDetail:Hide()
    if hasTitle then
        title:SetTextColor(content.color[1], content.color[2], content.color[3])
        W.place(title, x, y)
        if content.group then
            title:SetText(Dungeons.name(content.group.dungeon))
            local width = math.ceil(title:GetStringWidth() or 0)
            title:SetWidth(width + 2)
            info:SetText(groupLine(content, facts or { atEntrance = 0, inside = 0 }))
            info:SetWidth(math.max(40, W.RIGHT - x - width - 12))
            info:ClearAllPoints()
            info:SetPoint("LEFT", title, "RIGHT", 10, 0)
        else
            title:SetText(L[content.title])
            title:SetWidth(W.RIGHT - x - (progress and 130 or 0) - (options.rightRoom or 0))
        end
        -- Underlined like the section headers ("Dungeons for level 20").
        ui.statusLine:ClearAllPoints()
        ui.statusLine:SetPoint("TOPLEFT", title, "BOTTOMLEFT", PAD - x, -W.HEADER_GAP)
        ui.statusLine:SetPoint("RIGHT", W.frame, "RIGHT", -PAD, 0)
        y = y - W.HEADER_STEP
        for _, field in ipairs({ "subtitle", "detail" }) do
            local text = field == "subtitle" and ui.statusSubtitle or ui.statusDetail
            if not content.group and content[field] then
                text:SetText(L[content[field]])
                W.place(text, PAD, y)
                text:Show()
                local height = text:GetStringHeight()
                y = y - math.max(16, (type(height) == "number" and height or 0) + 3)
            end
        end
    end
    if places then
        y = y - W.SPACE.xs
        for i, column in ipairs(W.columns(#slots, SLOT_GAP)) do
            local slot = slots[i]
            W.paintPlace(slot, rows[i], { width = column.width, layout = layout, editable = rows[i].wishSlot ~= nil })
            slot.roleInfo = rows[i].roleInfo
            slot.wishSlot = rows[i].wishSlot
            slot.arrow:SetShown(slot.wishSlot ~= nil)
            Widgets.setEnabled(slot, slot.wishSlot ~= nil)
            if not slot.wishSlot then
                W.closeClassCard(slot)
            end
            W.place(slot, column.x, y)
            slot:Show()
        end
        y = y - W.PLACE_HEIGHT - W.SPACE.m
    else
        for _, slot in ipairs(slots) do
            slot:Hide()
            W.closeClassCard(slot)
        end
    end
    return y - W.SPACE.s
end

-- While searching the list makes way: who is looking for what the tab
-- searches follows the status title instead of the list's header.
function W.layoutLookingAfterStatus(subject)
    local title = ui.statusTitle
    if not title:IsShown() then
        W.hideHeaderLooking()
        return
    end
    title:SetWidth(math.ceil(title:GetStringWidth() or 0) + 2)
    W.layoutHeaderLooking(title, subject)
end

function W.hideActions()
    for _, button in ipairs(ui.actions) do
        button:Hide()
    end
end

-- The group's actions as one row of buttons, where the dungeon list is
-- while choosing; returns the new y.
function W.layoutActions(y)
    local actions = ui.actions
    local groupDungeon = ns.GroupView.trackedDungeon()
    if not groupDungeon then
        W.hideActions()
        return y
    end
    local entranceFor = ns.GroupView.dungeon()
    local entrance = entranceFor and not IsInInstance() and ns.Entrances.get(entranceFor)
    local quests = ns.QuestShare.summary(groupDungeon)
    local shown = {}
    for _, button in ipairs(actions) do
        local visible = button ~= actions.waypoint or entranceFor ~= nil
        button:SetShown(visible)
        if visible then
            shown[#shown + 1] = button
        end
    end
    Widgets.setEnabled(actions.waypoint, entrance and true or false)
    Widgets.setEnabled(actions.share, quests ~= nil and quests.mine > 0)
    Widgets.setEnabled(actions.progress, ns.QuestGroup.current() ~= nil and #ns.QuestGroup.rows() > 0)
    actions.questsInfo = quests
    for i, column in ipairs(W.columns(#shown, W.SPACE.m)) do
        local button = shown[i]
        button:SetWidth(column.width)
        W.place(button, column.x, y)
    end
    return y - ACTION_HEIGHT - W.SPACE.l
end

-- The channel connection in the title bar, left of the close button: a dot
-- in the state's colour, with its word only while it is not simply
-- connected (connecting, a problem, an update out); details on hover.
local function buildConnection()
    local bar = CreateFrame("Frame", nil, W.frame)
    bar:SetSize(1, 16)
    if W.frame.CloseButton then
        bar:SetPoint("RIGHT", W.frame.CloseButton, "LEFT", -4, 0)
        -- The panel's title bar and border are frames of their own; on the
        -- close button's level the dot is drawn above them.
        local level = W.frame.CloseButton.GetFrameLevel and W.frame.CloseButton:GetFrameLevel()
        if type(level) == "number" then
            bar:SetFrameLevel(level)
        end
    else
        bar:SetPoint("TOPRIGHT", W.frame, "TOPRIGHT", -32, -4)
    end
    ui.connectionBar = bar
    bar.label = Widgets.text(bar, "GameFontNormalSmall", "RIGHT")
    bar.label:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
    bar.dot = Widgets.dot(bar)
    bar.dot:SetPoint("RIGHT", bar.label, "LEFT", -5, 0)
    local hover = CreateFrame("Frame", nil, bar)
    hover:SetPoint("TOPLEFT", bar.dot, "TOPLEFT", -6, 6)
    hover:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 4, -2)
    hover:EnableMouse(true)
    hover:SetScript("OnEnter", function(self)
        local info = bar.info
        if info and GameTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
            GameTooltip:SetText(string.format(L["Forever Groups channel: %s"], L[info.text]))
            GameTooltip:AddLine(L[info.detail], 1, 1, 1, true)
            if ns.engine then
                local others = ns.Presence.others()
                GameTooltip:AddLine(string.format(L["Players with Forever Groups online: %d"], #others + 1), 1, 0.82,
                    0)
                local shown = { L["you"] }
                for i = 1, math.min(8, #others) do
                    shown[#shown + 1] = others[i]
                end
                if #others > 8 then
                    shown[#shown + 1] = string.format(L["and %d more"], #others - 8)
                end
                GameTooltip:AddLine(table.concat(shown, ", "), 1, 1, 1, true)
                local quests = ns.questEngine and #ns.questEngine:snapshot().entries or 0
                GameTooltip:AddLine(string.format(L["In the dungeon queue: %d  ·  questing queue: %d"],
                    #ns.engine:snapshot().entries, quests), 0.8, 0.8, 0.8)
                local matchmaker = ns.engine:snapshot().matchmaker
                if matchmaker then
                    GameTooltip:AddLine(string.format(L["Matchmaker: %s"], matchmaker), 0.8, 0.8, 0.8)
                end
            end
            GameTooltip:Show()
        end
    end)
    hover:SetScript("OnLeave", function()
        if GameTooltip then
            GameTooltip:Hide()
        end
    end)
end

local function hideTooltip()
    if GameTooltip then
        GameTooltip:Hide()
    end
end

function W.buildStatus()
    buildConnection()
    local frame = W.frame
    ui.statusCrown = frame:CreateTexture(nil, "ARTWORK")
    ui.statusCrown:SetSize(16, 16)
    ui.statusCrown:SetTexture("Interface\\GroupFrame\\UI-Group-LeaderIcon")
    ui.statusTitle = Widgets.text(frame, "GameFontNormal")
    ui.statusTitle:SetWordWrap(false)
    ui.statusLine = frame:CreateTexture(nil, "ARTWORK")
    ui.statusLine:SetHeight(1)
    ui.statusLine:SetColorTexture(1, 0.82, 0, 0.25)
    ui.statusInfo = Widgets.text(frame, "GameFontHighlight")
    ui.statusInfo:SetWordWrap(false)
    ui.statusSubtitle = Widgets.text(frame, "GameFontHighlight")
    ui.statusSubtitle:SetWidth(W.CONTENT)
    ui.statusDetail = Widgets.text(frame, "GameFontHighlightSmall")
    ui.statusDetail:SetWidth(W.CONTENT)
    ui.statusDetail:SetTextColor(0.8, 0.8, 0.8)
    ui.progressLink = Widgets.link(frame, "Quest progress »", function()
        ns.ProgressWindow.toggle()
    end)
    ui.takeLead = Widgets.button(frame, "Make me leader", 150)
    ui.takeLead:SetScript("OnClick", function()
        ns.TakeLead.ask()
        ns.Window.refresh()
    end)
    Widgets.tooltip(ui.takeLead, "Make me leader", "Your leader has no Forever Groups. This whispers them to "
        .. "make you leader; once you lead, Forever Groups fills the open places.")
    ui.takeLead:Hide()
    local actions = {}
    ui.actions = actions
    local function action(key, label, onClick, tip)
        local button = Widgets.button(frame, label, 160)
        button:SetHeight(ACTION_HEIGHT)
        button:SetScript("OnClick", onClick)
        if tip then
            button:SetScript("OnEnter", tip)
            button:SetScript("OnLeave", hideTooltip)
        end
        button:Hide()
        actions[#actions + 1] = button
        actions[key] = button
    end
    action("waypoint", "Waypoint to entrance", function()
        local dungeon = ns.GroupView.dungeon()
        if dungeon and not ns.Entrances.setWaypoint(dungeon) then
            ns.Log.info("The entrance of %s is not known yet.", Dungeons.name(dungeon))
        end
    end)
    action("share", "Share my quests", function()
        ns.QuestShare.shareMine(ns.GroupView.trackedDungeon())
    end, function(self)
        local info = actions.questsInfo
        if not info or not GameTooltip then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText(L["Share my quests"], 1, 0.82, 0)
        GameTooltip:AddLine(L["Shares your quests for this dungeon with the group, one at a time. Under each "
            .. "player with Forever Groups: their quests for it."], 1, 1, 1, true)
        if #info.theyHave > 0 then
            GameTooltip:AddLine(L["Others have, you don't:"], 1, 0.82, 0)
            for _, title in ipairs(info.theyHave) do
                GameTooltip:AddLine("  " .. title, 1, 1, 1)
            end
        end
        GameTooltip:Show()
    end)
    action("progress", "Quest progress", function()
        ns.ProgressWindow.toggle()
    end)
    -- While the leader sets up the party: the roles each member is queued
    -- for, and where they come from.
    for i = 1, #SLOT_ROLES do
        -- An open place of a run its leader may fill again: the classes for
        -- the replacement, kept as the party's class choices.
        local slot = W.newClassCard(frame, function(self)
            return self.wishSlot
        end, function(place, classes)
            ns.PartyCompose.setClasses(place, classes)
            ns.PartyLevels.noteStart("dungeons")
            ns.Window.refresh()
        end)
        slot.arrow:Hide()
        slot:HookScript("OnEnter", function(self)
            self.roleName = self.name:GetText()
            W.showRoleInfo(self)
        end)
        slot:HookScript("OnLeave", hideTooltip)
        slot:Hide()
        slots[i] = slot
    end
    W.hideStatus()
end
