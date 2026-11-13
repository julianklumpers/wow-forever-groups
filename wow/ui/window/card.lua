local _, ns = ...

local W = ns.WindowParts
local Widgets = ns.Widgets
local Dungeons = ns.Dungeons
local Party = ns.Party
local Roles = ns.Roles
local WIDTH = W.WIDTH
local PAD = W.PAD
local CARD_PADDING = W.CARD_PADDING
local SLOT_WIDTH = W.SLOT_WIDTH
local SLOT_GAP = W.SLOT_GAP
local GREEN = W.GREEN
local GOLD = W.GOLD
local CONNECTION_COLORS = W.CONNECTION_COLORS
local SLOT_ROLES = W.SLOT_ROLES
local ui = W.ui
local slots = W.slots
-- The group's dungeon as a banner behind the card's title: the picture of
-- the group-found popup (Dungeons.art, cropped there for 304 x 112), shaded
-- behind the text and fading into the card below.
local BANNER_HEIGHT, BANNER_FADE = 74, 30
-- The row of member places, and the banner with it, inside the card.
local SLOTS_LEFT = math.floor((WIDTH - 28 - (5 * SLOT_WIDTH + 4 * SLOT_GAP)) / 2)
local POPUP_ASPECT = 304 / 112

-- The status card under the tabs: what the queue, the group or the party is
-- doing, the group's places and links.

function W.shortNames(ids)
    local names = {}
    for i, id in ipairs(ids) do
        local dungeon = Dungeons.get(id)
        names[i] = dungeon and dungeon.short or id
    end
    return table.concat(names, ", ")
end

-- What the status card shows: { title, subtitle, detail, lead, color }.
function W.cardContent(state)
    local status = ns.Status.current("dungeons")
    if status and status.group then
        -- The dungeon as the title; refreshCard writes the line under it,
        -- which counts the players at the entrance.
        return { title = Dungeons.name(status.group.dungeon), group = status.group, lead = status.lead,
            color = status.done and GREEN or GOLD }
    end
    if status then
        local color = (status.done and GREEN) or GOLD
        return { title = status.text, subtitle = status.headline, detail = status.detail, lead = status.lead,
            color = color }
    end
    if not ns.engine then
        return { title = "Connecting...", subtitle = "Joining the Forever Groups channel.", color = GOLD }
    end
    if state == "raid" then
        return { title = "You are in a raid", subtitle = "Leave the raid to queue.", color = GOLD }
    end
    if state ~= "solo" then
        local size = ns.GroupView.partySize()
        local run = ns.Run.isInside() and ns.Run.current()
        if size >= 5 then
            return { title = "Your party is complete (5/5)", color = GREEN, lead = state == "leader",
                subtitle = run and (Dungeons.name(run.dungeon) .. ": " .. ns.Run.describe(run)) or "No need to queue." }
        end
        local subtitle = state == "leader" and "Queue your party below, or fill it from WoW's Group Finder."
            or "Your party leader queues for the group."
        if state == "raid" then
            subtitle = "You are in a raid: leave it to queue."
        end
        return { title = string.format("Your party: %d/5", size), subtitle = subtitle, color = GOLD,
            lead = state == "leader" }
    end
    return { color = GOLD }
end

-- The Quests tab's card: the questing queue, a proposal, or the group.
function W.questCardContent(state)
    if not ns.questEngine then
        return { title = "Connecting...", subtitle = "Joining the Forever Groups channel.", color = GOLD }
    end
    local proposal = ns.questEngine.myProposalKey and ns.questEngine.proposals[ns.questEngine.myProposalKey]
    if proposal and not proposal.outcome then
        local left = math.max(0, proposal.answerDeadline - GetServerTime())
        return { title = string.format("Group found for %s! %d s to accept", ns.Quests.nameOf(proposal.dungeon),
            left), color = GREEN, lead = proposal.leader == ns.selfName }
    end
    local invites = ns.Group.status()
    if invites and ns.QuestMatch.parse(invites.dungeon) then
        local name = ns.Quests.nameOf(invites.dungeon)
        if invites.role == "member" then
            return { title = "Accept the invite from " .. invites.leader, color = GREEN,
                subtitle = "A questing group for " .. name .. " was found." }
        end
        return { title = string.format("Inviting your group: %d of %d joined", invites.joined, invites.total),
            color = GREEN, lead = true, subtitle = "Questing group for " .. name }
    end
    local group = ns.QuestGroup.isQuesting() and ns.QuestGroup.current()
    if group and state ~= "solo" then
        local titles = {}
        for i, id in ipairs(group.quests) do
            titles[i] = ns.Quests.titleOf(id)
        end
        return { title = "Questing group: " .. table.concat(titles, ", "), color = GREEN, lead = state == "leader",
            subtitle = "Everyone's progress folds out under the status bar (/fg progress)." }
    end
    local entry = ns.QuestQueue.entry()
    if entry then
        local finder = ns.QuestFinder.summary()
        local parts = { ns.QuestQueue.describe(entry.dungeons) }
        if finder.invited > 0 then
            parts[#parts + 1] = string.format("invited %d from the Group Finder", finder.invited)
        end
        if finder.asked > 0 then
            parts[#parts + 1] = string.format("asked %d group%s", finder.asked, finder.asked == 1 and "" or "s")
        end
        if ns.Listing.isOurs() then
            parts[#parts + 1] = "listed in the Group Finder"
        end
        return {
            title = string.format("Looking for a questing group %s as %s",
                Widgets.formatTime(GetServerTime() - entry.joinedAt), Widgets.describeRoles(entry.members[1].roles)),
            subtitle = table.concat(parts, "  ·  "), color = GOLD, lead = #entry.members > 1,
        }
    end
    if state == "member" or state == "raid" then
        return { title = "Your party leader looks for questing groups", color = GOLD }
    end
    return { color = GOLD }
end

function W.refreshConnection()
    local card = ui.card
    local connection = ns.Comm.connection()
    local newer = ns.Version.newer()
    if newer then
        connection.text = connection.text .. " · update available"
        connection.detail = connection.detail .. "\nForever Groups " .. newer.version .. " is out; you have "
            .. tostring(ns.Version.mine()) .. ". Please update."
    end
    local color = CONNECTION_COLORS[connection.state]
    Widgets.paintDot(card.dot, color)
    local plain = connection.state == "connected" and not newer
    card.connection:SetText(plain and "" or connection.text)
    card.connection:SetTextColor(color[1], color[2], color[3])
    card.connectionInfo = connection
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
                slot.name = member.reserved and "invited" or member.name
                slot.classToken = member.name == ns.selfName and Party.playerClass() or nil
                break
            end
        end
    end
    return { slots = places }
end

-- Fills the card and returns its height. full: the party is complete, so the
-- queue numbers are left out.
-- tab: "dungeons" or "quests"; the card shows that tab's status.
function W.refreshCard(state, full, tab)
    local card = ui.card
    W.refreshConnection()
    local questTab = tab == "quests"
    local content = questTab and W.questCardContent(state) or W.cardContent(state)
    local y = -10
    card.crown:SetShown(content.lead == true)
    card.progressLink:SetShown(questTab and ns.QuestGroup.current() ~= nil and #ns.QuestGroup.rows() > 0)
    local x = content.lead and 32 or 12
    card.title:SetShown(content.title ~= nil)
    if content.title then
        card.title:ClearAllPoints()
        card.title:SetPoint("TOPLEFT", card, "TOPLEFT", x, y)
        card.title:SetText(content.title)
        card.title:SetTextColor(content.color[1], content.color[2], content.color[3])
        y = y - 22
    end
    for _, field in ipairs({ "subtitle", "detail" }) do
        local text = card[field]
        if content.group then
            text:Hide()
        elseif content[field] then
            text:ClearAllPoints()
            text:SetPoint("TOPLEFT", card, "TOPLEFT", 12, y)
            text:SetText(content[field])
            text:Show()
            local height = text:GetStringHeight()
            y = y - math.max(16, (type(height) == "number" and height or 0) + 3)
        else
            text:Hide()
        end
    end
    local banner = W.paintBanner(content.group and not questTab and ns.GroupView.trackedDungeon())
    local composition
    if questTab then
        composition = nil
    elseif IsInGroup() or ns.GroupView.isTracking() then
        composition = ns.GroupView.composition()
    elseif ns.engine and ns.engine.myEntry then
        composition = W.queuedComposition(ns.engine.myEntry)
    end
    local groupDungeon = not questTab and ns.GroupView.trackedDungeon()
    local entranceFor = not questTab and ns.GroupView.dungeon()
    local entrance = entranceFor and not IsInInstance() and ns.Entrances.get(entranceFor)
    local quests = groupDungeon and ns.QuestShare.summary(groupDungeon)
    local inside = IsInInstance() and true or false
    local places = groupDungeon and (inside or ns.Entrances.get(groupDungeon) ~= nil)
    local atEntrance, insideCount = 0, 0
    if composition then
        local counts = {}
        if quests then
            counts[ns.selfName] = quests.mine
            for _, member in ipairs(quests.members) do
                counts[member.name] = member.count or (ns.Presence.isOnline(member.name) and "?" or "none")
            end
        end
        local rows, layout = {}, { spec = false, distance = places and true or false, quests = quests and true }
        for i, data in ipairs(composition.slots) do
            local row = { role = data.role, name = data.name, classToken = data.classToken }
            if data.name then
                row.spec = ns.Spec.treeOf(data.name)
                row.quests = counts[data.name]
                if places then
                    local place = ns.GroupPlaces.of(data.name, data.unit, groupDungeon)
                    if place == nil and not inside then
                        place = false
                    elseif place == nil then
                        place = counts[data.name] == "none" and "none" or "?"
                    end
                    row.distance = place
                    if place == "in" then
                        insideCount = insideCount + 1
                    elseif type(place) == "number" and ns.Entrances.isAt(place) then
                        atEntrance = atEntrance + 1
                    end
                end
            end
            layout.spec = layout.spec or row.spec ~= nil
            rows[i] = row
        end
        -- Everyone inside: the line under the title says so, the places
        -- leave it out.
        if inside and composition.members and insideCount == #composition.members then
            layout.distance = false
        end
        if content.group then
            local parts = { content.group.complete and "Group complete"
                or string.format("%d/5, open: %s", content.group.count, content.group.openText) }
            local styles = ns.Playstyle.describe(content.group.playstyles, " / ")
            if styles then
                parts[#parts + 1] = styles
            end
            if content.lead then
                parts[#parts + 1] = "you lead"
            end
            if inside then
                parts[#parts + 1] = string.format("%d of %d inside", insideCount, content.group.count)
            elseif places then
                parts[#parts + 1] = string.format("%d of %d at the entrance", atEntrance, content.group.count)
                if insideCount > 0 then
                    parts[#parts + 1] = string.format("%d inside", insideCount)
                end
            end
            if content.group.run then
                parts[#parts + 1] = content.group.run
            end
            card.subtitle:ClearAllPoints()
            card.subtitle:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -32)
            card.subtitle:SetText(table.concat(parts, "  ·  "))
            card.subtitle:Show()
            y = -52
        end
        -- Under the banner's fade, not in it.
        y = banner and -(BANNER_HEIGHT + 4) or (y - 4)
        local left = SLOTS_LEFT
        local tallest = 0
        for i, slot in ipairs(slots) do
            tallest = math.max(tallest, Widgets.paintSlot(slot, rows[i], layout))
            slot:ClearAllPoints()
            slot:SetPoint("TOPLEFT", card, "TOPLEFT", left + (i - 1) * (SLOT_WIDTH + SLOT_GAP), y)
            slot:Show()
        end
        y = y - tallest - 8
    else
        for _, slot in ipairs(slots) do
            slot:Hide()
        end
    end
    for _, widget in ipairs({ card.lookingLabel, card.looking, card.lookingGroups }) do
        widget:SetShown(not full)
    end
    -- The group's actions, as one row of buttons.
    local actions = card.actions
    local showActions = groupDungeon and true or false
    local shown = {}
    for _, button in ipairs(actions) do
        local visible = showActions and (button ~= actions.waypoint or entranceFor ~= nil)
        button:SetShown(visible)
        if visible then
            shown[#shown + 1] = button
        end
    end
    if showActions then
        Widgets.setEnabled(actions.waypoint, entrance and true or false)
        Widgets.setEnabled(actions.share, quests ~= nil and quests.mine > 0)
        Widgets.setEnabled(actions.progress, ns.QuestGroup.current() ~= nil and #ns.QuestGroup.rows() > 0)
        card.questsInfo = quests
        local width = math.floor((WIDTH - 2 * PAD - 2 * 8) / 3)
        for i, button in ipairs(shown) do
            button:SetWidth(width)
            button:ClearAllPoints()
            button:SetPoint("TOPLEFT", card, "TOPLEFT", 12 + (i - 1) * (width + 8), y)
        end
        y = y - 30
    end
    if not full then
        y = y - 4
        card.lookingLabel:ClearAllPoints()
        card.lookingLabel:SetPoint("TOPLEFT", card, "TOPLEFT", 12, y - 2)
        card.looking:ClearAllPoints()
        card.looking:SetPoint("LEFT", card.lookingLabel, "RIGHT", 10, 0)
        local subject = questTab and "quests" or "dungeons"
        local wanted = questTab and ns.QueueWindow.wantedQuests() or ns.QueueWindow.wantedDungeons()
        local known = questTab and ns.QueueWindow.questCountsKnown() or (not questTab and ns.Features.countsKnown())
        Widgets.setRoleCounts(card.looking, known and ns.QueueWindow.lookingCounts(wanted, subject))
        local needing = #ns.QueueWindow.groupsNeedingMe(wanted, subject)
        card.lookingGroups:ClearAllPoints()
        card.lookingGroups:SetPoint("LEFT", card.looking, "RIGHT", 6, 0)
        local plural = needing ~= 1
        card.lookingGroups:SetText(needing > 0
            and string.format("·  %d group%s need%s you", needing, plural and "s" or "", plural and "" or "s") or "")
        y = y - 20
    end
    local height = -(y - 6)
    card:SetHeight(height)
    return height
end

-- dungeon: the group's dungeon id, or nil for no banner.
function W.paintBanner(dungeon)
    local card = ui.card
    local art, crop = nil, nil
    if dungeon then
        art, crop = Dungeons.art(dungeon)
    end
    for _, part in ipairs({ card.bannerTop, card.bannerFade, card.bannerShade }) do
        part:SetShown(art ~= nil)
    end
    if not art then
        return false
    end
    -- The popup's crop, its height narrowed to this wider banner around the
    -- same middle; the faded part continues the picture downwards.
    local aspect = (5 * SLOT_WIDTH + 4 * SLOT_GAP) / BANNER_HEIGHT
    local middle = (crop[3] + crop[4]) / 2
    local half = (crop[4] - crop[3]) / 2 * POPUP_ASPECT / aspect
    local top, bottom = middle - half, middle + half
    local split = top + (bottom - top) * (BANNER_HEIGHT - BANNER_FADE) / BANNER_HEIGHT
    card.bannerTop:SetTexture(art)
    card.bannerTop:SetTexCoord(crop[1], crop[2], top, split)
    card.bannerFade:SetTexture(art)
    card.bannerFade:SetTexCoord(crop[1], crop[2], split, bottom)
    if not (card.bannerFaded and pcall(card.bannerFade.SetGradient, card.bannerFade, "VERTICAL",
        CreateColor(1, 1, 1, 0), CreateColor(1, 1, 1, 1))) then
        card.bannerFade:SetAlpha(0.5)
    end
    return true
end

function W.buildCard()
    local card = CreateFrame("Frame", nil, W.frame)
    card:SetSize(WIDTH - 2 * (PAD - CARD_PADDING), 100)
    local background = card:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(0, 0, 0, 0.35)
    card.bannerTop = card:CreateTexture(nil, "BACKGROUND", nil, 1)
    card.bannerTop:SetPoint("TOPLEFT", SLOTS_LEFT, 0)
    card.bannerTop:SetPoint("TOPRIGHT", -SLOTS_LEFT, 0)
    card.bannerTop:SetHeight(BANNER_HEIGHT - BANNER_FADE)
    card.bannerFade = card:CreateTexture(nil, "BACKGROUND", nil, 1)
    card.bannerFade:SetPoint("TOPLEFT", card.bannerTop, "BOTTOMLEFT")
    card.bannerFade:SetPoint("TOPRIGHT", card.bannerTop, "BOTTOMRIGHT")
    card.bannerFade:SetHeight(BANNER_FADE)
    card.bannerShade = card:CreateTexture(nil, "BACKGROUND", nil, 2)
    card.bannerShade:SetPoint("TOPLEFT", card.bannerTop, "TOPLEFT")
    card.bannerShade:SetPoint("TOPRIGHT", card.bannerTop, "TOPRIGHT")
    card.bannerShade:SetHeight(BANNER_HEIGHT)
    card.bannerShade:SetColorTexture(1, 1, 1, 1)
    local hasGradient = type(CreateColor) == "function"
    -- Dark behind the title on the left, clear on the right.
    if not (hasGradient and pcall(card.bannerShade.SetGradient, card.bannerShade, "HORIZONTAL",
        CreateColor(0, 0, 0, 0.75), CreateColor(0, 0, 0, 0.1))) then
        card.bannerShade:SetColorTexture(0, 0, 0, 0.45)
    end
    card.bannerFaded = hasGradient
    card.crown = card:CreateTexture(nil, "ARTWORK")
    card.crown:SetSize(16, 16)
    card.crown:SetPoint("TOPLEFT", 12, -11)
    card.crown:SetTexture("Interface\\GroupFrame\\UI-Group-LeaderIcon")
    card.progressLink = Widgets.link(card, "Quest progress »", function()
        ns.ProgressWindow.toggle()
    end)
    card.progressLink:SetPoint("TOPRIGHT", -12, -13)
    -- The channel connection in the title bar, left of the close button: a
    -- dot in the state's colour, with its word only while it is not simply
    -- connected (connecting, a problem, an update out); details on hover.
    local bar = CreateFrame("Frame", nil, W.frame)
    bar:SetSize(1, 16)
    if W.frame.CloseButton then
        bar:SetPoint("RIGHT", W.frame.CloseButton, "LEFT", -4, 0)
    else
        bar:SetPoint("TOPRIGHT", W.frame, "TOPRIGHT", -32, -4)
    end
    ui.connectionBar = bar
    card.connection = Widgets.text(bar, "GameFontNormalSmall", "RIGHT")
    card.connection:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
    card.dot = Widgets.dot(bar)
    card.dot:SetPoint("RIGHT", card.connection, "LEFT", -5, 0)
    local hover = CreateFrame("Frame", nil, bar)
    hover:SetPoint("TOPLEFT", card.dot, "TOPLEFT", -6, 6)
    hover:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 4, -2)
    hover:EnableMouse(true)
    hover:SetScript("OnEnter", function(self)
        local info = card.connectionInfo
        if info and GameTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
            GameTooltip:SetText("Forever Groups channel: " .. info.text)
            GameTooltip:AddLine(info.detail, 1, 1, 1, true)
            if ns.engine then
                local others = ns.Presence.others()
                GameTooltip:AddLine(string.format("Players with Forever Groups online: %d", #others + 1), 1, 0.82, 0)
                local shown = { "you" }
                for i = 1, math.min(8, #others) do
                    shown[#shown + 1] = others[i]
                end
                if #others > 8 then
                    shown[#shown + 1] = string.format("and %d more", #others - 8)
                end
                GameTooltip:AddLine(table.concat(shown, ", "), 1, 1, 1, true)
                local quests = ns.questEngine and #ns.questEngine:snapshot().entries or 0
                GameTooltip:AddLine(string.format("In the dungeon queue: %d  ·  questing queue: %d",
                    #ns.engine:snapshot().entries, quests), 0.8, 0.8, 0.8)
                local matchmaker = ns.engine:snapshot().matchmaker
                if matchmaker then
                    GameTooltip:AddLine("Matchmaker: " .. matchmaker, 0.8, 0.8, 0.8)
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
    card.title = Widgets.text(card, "GameFontNormalLarge")
    card.title:SetWidth(WIDTH - 200)
    card.title:SetWordWrap(false)
    card.subtitle = Widgets.text(card, "GameFontHighlight")
    card.subtitle:SetWidth(WIDTH - 52)
    card.detail = Widgets.text(card, "GameFontHighlightSmall")
    card.detail:SetWidth(WIDTH - 52)
    card.detail:SetTextColor(0.8, 0.8, 0.8)
    card.lookingLabel = Widgets.text(card, "GameFontNormalSmall")
    card.lookingLabel:SetText("Looking now:")
    card.looking = Widgets.roleCounts(card, 14)
    card.looking:EnableMouse(true)
    card.lookingGroups = Widgets.text(card, "GameFontNormalSmall")
    Widgets.tooltip(card.looking, "Looking now", "Tanks, healers and DPS looking for your dungeons: other "
        .. "Forever Groups players and solo players in WoW's Group Finder. Someone who can play more roles counts "
        .. "for each.")
    local function action(key, label, onClick, tip)
        local button = Widgets.button(card, label, 160)
        button:SetHeight(22)
        button:SetScript("OnClick", onClick)
        if tip then
            button:SetScript("OnEnter", tip)
            button:SetScript("OnLeave", function()
                if GameTooltip then
                    GameTooltip:Hide()
                end
            end)
        end
        card.actions[#card.actions + 1] = button
        card.actions[key] = button
    end
    card.actions = {}
    action("waypoint", "Waypoint to entrance", function()
        local dungeon = ns.GroupView.dungeon()
        if dungeon and not ns.Entrances.setWaypoint(dungeon) then
            ns.Log.info("The entrance of %s is not known yet.", Dungeons.name(dungeon))
        end
    end)
    action("share", "Share my quests", function()
        ns.QuestShare.shareMine(ns.GroupView.trackedDungeon())
    end, function(self)
        local info = card.questsInfo
        if not info or not GameTooltip then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Share my quests", 1, 0.82, 0)
        GameTooltip:AddLine("Shares your quests for this dungeon with the group, one at a time. Under each "
            .. "player: their quests for it (? without Forever Groups).", 1, 1, 1, true)
        if #info.theyHave > 0 then
            GameTooltip:AddLine("Others have, you don't:", 1, 0.82, 0)
            for _, title in ipairs(info.theyHave) do
                GameTooltip:AddLine("  " .. title, 1, 1, 1)
            end
        end
        GameTooltip:Show()
    end)
    action("progress", "Quest progress", function()
        ns.ProgressWindow.toggle()
    end)
    for i = 1, 5 do
        slots[i] = Widgets.slot(card)
    end
    ui.card = card
end
