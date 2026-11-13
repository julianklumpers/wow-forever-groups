local _, ns = ...

local Widgets = ns.Widgets
local Dungeons = ns.Dungeons

-- One status for the whole addon, shown in a small bar that is visible
-- whenever something is going on, and in the main window.
local Status = {}

local COMPLETE_SHOWN = 10
local GOLD = { 1, 0.82, 0 }
local WHITE = { 1, 1, 1 }
local GREEN = { 0.25, 1, 0.25 }

local completeText
local completeUntil = 0
local frame
local shownProgress
local ui = {}

function Status.complete(text)
    completeText = text
    completeUntil = GetServerTime() + COMPLETE_SHOWN
    Status.refresh()
end

local function openProposal(engine)
    local key = engine.myProposalKey
    local proposal = key and engine.proposals[key]
    if proposal and not proposal.outcome then
        return proposal
    end
end

local LEAD = "You lead this group: you invite the players."
local WAITING = "You are in the queue: a group will be found for you."

local function lead(text, detail, extra)
    local status = { text = text, detail = detail, lead = true, headline = LEAD }
    for key, value in pairs(extra or {}) do
        status[key] = value
    end
    return status
end

local function waiting(text, detail, extra)
    local status = { text = text, detail = detail, lead = false, headline = WAITING }
    for key, value in pairs(extra or {}) do
        status[key] = value
    end
    return status
end

-- { text, detail, headline, lead, alert, roles } or nil when nothing is going
-- on. lead says whether this player is the one inviting players (party
-- leader, group leader, or filling from the Group Finder) or the one waiting
-- to be found.
-- scope "dungeons" leaves the questing queue out (the window's Dungeons tab);
-- without it, the status bar shows both.
function Status.current(scope)
    local dungeonsOnly = scope == "dungeons"
    local engine = ns.engine
    if not engine then
        return nil
    end
    local now = GetServerTime()
    local leadsParty = ns.Party.state() == "leader"
    local proposal = openProposal(engine) or (not dungeonsOnly and ns.questEngine and openProposal(ns.questEngine))
    if proposal then
        local left = math.max(0, proposal.answerDeadline - now)
        local make = (proposal.leader == ns.selfName) and lead or waiting
        if proposal.answers[ns.selfName] == "Y" then
            return make(string.format("Accepted, waiting for the others (%d s)", left))
        end
        return make(string.format("Group found! %d s to accept", left), nil, { alert = true })
    end

    local view = ns.GroupView.status()
    local slots = view and view.slots
    local group = ns.Group.status()
    if group and dungeonsOnly and ns.QuestMatch.parse(group.dungeon) then
        group = nil
    end
    if group and group.role == "member" then
        return {
            text = "Accept the invite from " .. group.leader, detail = "Group for " .. ns.Quests.nameOf(group.dungeon),
            alert = true, lead = false,
            headline = "A group was found: accept the WoW invite from " .. group.leader .. ".",
        }
    end
    -- How the group comes about (asking leaders, inviting from the Group
    -- Finder) shows only with /fg debug on; otherwise it simply happens.
    local details = ns.db and ns.db.debug
    local applied = ns.Apply.summary()
    if applied and applied.invitedBy and (details or ns.db.noAutoAcceptAsked) then
        return {
            text = "Accept the invite from " .. applied.invitedBy,
            detail = "Group for " .. Dungeons.name(applied.dungeon), alert = true, lead = false,
            headline = applied.invitedBy .. " invited you from WoW's Group Finder: accept the invite.",
        }
    end
    local fill = ns.Filler.summary()
    local detail = details and fill and ("Building your own group: " .. fill) or nil
    if details and applied and applied.asked then
        detail = string.format("Asking groups to invite you (%d asked)  ·  own group in %s", applied.asked,
            Widgets.formatTime(applied.left))
    end
    if group and group.role == "leader" then
        return lead(string.format("Inviting your group: %d of %d joined", group.joined, group.total), detail,
            { slots = slots, progress = group.total > 0 and group.joined / group.total or nil })
    end

    local entry = engine.myEntry
    local questEntry = not dungeonsOnly and ns.QuestQueue.entry() or nil
    if entry and questEntry then
        detail = (detail and (detail .. "  ·  ") or "") .. "Also looking for a questing group"
    end
    if entry then
        local roles = entry.members[1].roles
        local text = string.format("In queue %s as %s", Widgets.formatTime(now - entry.joinedAt),
            Widgets.describeRoles(roles))
        if #entry.members > 1 then
            text = text .. string.format(" (party of %d)", #entry.members)
        end
        if leadsParty or fill then
            local status = lead(text, detail, { roles = roles })
            status.headline = "You lead this group and are in the queue: the queue and you both look for players."
            return status
        end
        return waiting(text, detail, { roles = roles })
    end
    if questEntry then
        local roles = questEntry.members[1].roles
        local finder = ns.QuestFinder.summary()
        local parts = { ns.QuestQueue.describe(questEntry.dungeons) }
        if details and finder.invited > 0 then
            parts[#parts + 1] = string.format("invited %d from the Group Finder", finder.invited)
        end
        if details and finder.asked > 0 then
            parts[#parts + 1] = string.format("asked %d group%s", finder.asked, finder.asked == 1 and "" or "s")
        end
        if details and ns.Listing.isOurs() then
            parts[#parts + 1] = "listed in the Group Finder"
        end
        return waiting(string.format("Looking for a questing group %s as %s",
            Widgets.formatTime(now - questEntry.joinedAt), Widgets.describeRoles(roles)),
            table.concat(parts, "  ·  "), { roles = roles })
    end
    if fill then
        return lead(details and ("Group Finder: " .. fill) or "Group forming", view and view.text, { slots = slots })
    end

    if view then
        local headline = view.complete and (view.inside and "Your group is in the dungeon. Have fun!"
            or "Your group is complete. Have fun!")
            or (leadsParty and LEAD or "The leader is completing your group.")
        return { text = view.text, slots = slots, lead = leadsParty, headline = headline, done = view.complete,
            group = view, progress = view.progress }
    end

    if not dungeonsOnly and IsInGroup() and ns.QuestGroup.isQuesting() then
        local titles = {}
        for i, id in ipairs(ns.QuestGroup.current().quests) do
            titles[i] = ns.Quests.titleOf(id)
        end
        return { text = "Questing: " .. table.concat(titles, ", "), lead = leadsParty, done = true,
            headline = "Your questing group." }
    end

    local party = ns.PartyStatus.current()
    if party then
        local headline = party.leader .. " leads your party and searches; you don't need to do anything."
        if party.phase == "proposal" then
            return { text = party.leader .. " is answering a group proposal", alert = true, lead = false,
                headline = headline, detail = "For " .. Dungeons.name(party.dungeon) }
        elseif party.phase == "formed" then
            return { text = "Group formed for " .. Dungeons.name(party.dungeon), lead = false, headline = headline,
                detail = "Leader: " .. party.leader }
        end
        local text = string.format("Your party is queued by %s (%s)", party.leader,
            Widgets.formatTime(now - party.joinedAt))
        return { text = text, lead = false, headline = headline, roles = party.roles,
            detail = party.roles and ("You: " .. Widgets.describeRoles(party.roles)) or nil }
    end

    if completeText and now <= completeUntil then
        return { text = completeText, lead = leadsParty }
    end
    return nil
end

local function savePosition()
    local point, _, relativePoint, x, y = frame:GetPoint(1)
    ns.db.statusPosition = { point = point, relativePoint = relativePoint, x = x, y = y }
end

function Status.resetPosition()
    if not frame then
        return
    end
    frame:ClearAllPoints()
    local position = ns.db.statusPosition
    if position then
        frame:SetPoint(position.point, UIParent, position.relativePoint, position.x, position.y)
    elseif Minimap then
        frame:SetPoint("TOP", Minimap, "BOTTOM", 0, -24)
    else
        frame:SetPoint("TOP", UIParent, "TOP", 0, -200)
    end
end

-- share: WoW's yellow "!" of a quest to pick up; progress: a quest book.
local ICONS = {
    share = { atlas = "QuestNormal", texture = "Interface\\GossipFrame\\AvailableQuestIcon" },
    progress = { texture = "Interface\\Icons\\INV_Misc_Book_09", round = true },
}

local function iconButton(key, title, onClick, describe)
    local button = CreateFrame("Button", nil, frame)
    button:SetSize(18, 18)
    local icon = ICONS[key]
    if icon.round then
        local round = Widgets.roundIcon(button, icon.texture, 16)
        round:SetPoint("CENTER")
    else
        local texture = button:CreateTexture(nil, "ARTWORK")
        texture:SetAllPoints()
        if Widgets.atlasExists(icon.atlas) then
            texture:SetAtlas(icon.atlas)
        else
            texture:SetTexture(icon.texture)
        end
    end
    button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    button:SetScript("OnClick", onClick)
    button:SetScript("OnEnter", function(self)
        if GameTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:SetText(title, 1, 0.82, 0)
            GameTooltip:AddLine(describe(), 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    button:SetScript("OnLeave", function()
        if GameTooltip then
            GameTooltip:Hide()
        end
    end)
    button.iconLabel = title
    button:Hide()
    return button
end

local function build()
    frame = CreateFrame("Button", "ForeverGroupsStatusFrame", UIParent)
    frame:SetSize(420, 26)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        savePosition()
    end)
    frame:SetScript("OnClick", function()
        if not ns.Input.run() and not ns.Filler.searchIfUseful(30) then
            ns.Window.toggle()
        end
    end)
    Status.resetPosition()
    local background = frame:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(0, 0, 0, 0.7)
    ui.logo = Widgets.roundIcon(frame, Widgets.ICON, 16)
    ui.logo:SetPoint("LEFT", 5, 1)
    ui.crown = frame:CreateTexture(nil, "ARTWORK")
    ui.crown:SetSize(16, 16)
    ui.crown:SetTexture("Interface\\GroupFrame\\UI-Group-LeaderIcon")
    ui.icon = Widgets.roleIcon(frame, "D", 18)
    ui.track = frame:CreateTexture(nil, "BORDER")
    ui.track:SetPoint("BOTTOMLEFT", 1, 1)
    ui.track:SetPoint("BOTTOMRIGHT", -1, 1)
    ui.track:SetHeight(3)
    ui.track:SetColorTexture(1, 1, 1, 0.08)
    ui.fill = frame:CreateTexture(nil, "ARTWORK")
    ui.fill:SetPoint("BOTTOMLEFT", 1, 1)
    ui.fill:SetHeight(3)
    ui.slots = {}
    for i = 5, 1, -1 do
        local slot = Widgets.roleIcon(frame, "D", 14)
        slot:SetPoint("RIGHT", -6 - (5 - i) * 16, 0)
        ui.slots[i] = slot
    end
    ui.share = iconButton("share", "Share my quests", function()
        ns.QuestShare.shareMine(ns.GroupView.trackedDungeon())
    end, function()
        local info = ns.QuestShare.summary(ns.GroupView.trackedDungeon())
        local lines = { "Shares your quests for this dungeon with the group, one at a time." }
        if info and #info.theyHave > 0 then
            lines[#lines + 1] = "Others have, you don't: " .. table.concat(info.theyHave, ", ")
        end
        return table.concat(lines, "\n")
    end)
    ui.progress = iconButton("progress", "Quest progress", function()
        ns.ProgressWindow.toggle()
    end, function()
        return ns.ProgressWindow.isExpanded() and "Click to fold the quest progress in."
            or "Click to fold out how far everyone is with the group's quests."
    end)
    ui.text = Widgets.text(frame, "GameFontHighlightSmall")
    ui.text:SetWordWrap(false)
    frame:SetScript("OnEnter", function(self)
        local status = Status.current()
        if status and GameTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:SetText("Forever Groups")
            if status.headline then
                GameTooltip:AddLine(status.headline, 1, 0.82, 0, true)
            end
            GameTooltip:AddLine(status.text, 1, 1, 1, true)
            if status.detail then
                GameTooltip:AddLine(status.detail, 0.8, 0.8, 0.8, true)
            end
            local connection = ns.Comm.connection()
            GameTooltip:AddLine("Channel: " .. connection.text .. " - " .. connection.detail, 0.6, 0.8, 1, true)
            if ns.Filler.wantsSearch(30) then
                GameTooltip:AddLine("Click to search the Group Finder for more players.", 0.3, 1, 0.3)
            else
                GameTooltip:AddLine("Click to open, drag to move.", 0.5, 0.5, 0.5)
            end
            GameTooltip:Show()
        end
    end)
    frame:SetScript("OnLeave", function()
        if GameTooltip then
            GameTooltip:Hide()
        end
    end)
    frame:Hide()
end

function Status.refresh()
    if not ns.db then
        return
    end
    if not frame then
        build()
    end
    local status = Status.current()
    if not status or ns.db.statusHidden then
        frame:Hide()
        ns.ProgressWindow.refresh()
        return
    end
    local text = status.detail and (status.text .. "  -  " .. status.detail) or status.text
    if ns.Filler.wantsSearch(30) and not ns.KeySearch.isReady() then
        text = text .. "  (click to search)"
    end
    ui.text:SetText(text)
    local color = (status.done and GREEN) or (status.alert and GOLD) or WHITE
    -- The addon's icon, then the crown when this player leads, then the
    -- role queued as, then the text.
    local x = 25
    ui.crown:SetShown(status.lead == true)
    if status.lead then
        ui.crown:ClearAllPoints()
        ui.crown:SetPoint("LEFT", x, 1)
        x = x + 19
    end
    local firstRole = status.roles and string.sub(status.roles, 1, 1)
    if firstRole and firstRole ~= "" then
        Widgets.setRoleIcon(ui.icon, firstRole)
        ui.icon:ClearAllPoints()
        ui.icon:SetPoint("LEFT", x, 1)
        ui.icon:Show()
        x = x + 21
    else
        ui.icon:Hide()
    end
    -- The quest icons sit left of the group's places.
    local right = status.slots and -92 or -6
    local dungeon = ns.GroupView.trackedDungeon()
    local quests = dungeon and ns.QuestShare.summary(dungeon)
    local hasProgress = ns.QuestGroup.current() ~= nil and #ns.QuestGroup.rows() > 0
    for _, entry in ipairs({ { ui.progress, hasProgress }, { ui.share, quests ~= nil and quests.mine > 0 } }) do
        local button, shown = entry[1], entry[2]
        button:SetShown(shown)
        if shown then
            button:ClearAllPoints()
            button:SetPoint("RIGHT", right - 2, 1)
            right = right - 22
        end
    end
    ui.progress:SetAlpha(ns.ProgressWindow.isExpanded() and 1 or 0.75)
    ui.text:ClearAllPoints()
    ui.text:SetPoint("LEFT", x + 2, 1)
    ui.text:SetPoint("RIGHT", right - 4, 1)
    shownProgress = status.progress
    ui.track:SetShown(shownProgress ~= nil)
    ui.fill:SetShown(shownProgress ~= nil and shownProgress > 0)
    if shownProgress and shownProgress > 0 then
        local width = frame:GetWidth()
        ui.fill:SetWidth(math.max(1, ((type(width) == "number" and width or 380) - 2) * shownProgress))
        ui.fill:SetColorTexture(GREEN[1], GREEN[2], GREEN[3], 0.9)
    end
    for i, icon in ipairs(ui.slots) do
        local slot = status.slots and status.slots[i]
        if slot then
            Widgets.setRoleIcon(icon, slot.role)
            icon:SetAlpha(slot.name and 1 or 0.25)
            icon:Show()
        else
            icon:Hide()
        end
    end
    ui.text:SetTextColor(color[1], color[2], color[3])
    frame:Show()
    ns.ProgressWindow.refresh()
end

function Status.frame()
    if not frame and ns.db then
        build()
    end
    return frame
end

-- How full the bar's progress line is (0..1), or nil without one.
function Status.progress()
    return frame and frame:IsShown() and shownProgress or nil
end

function Status.isShown()
    return frame ~= nil and frame:IsShown()
end

ns.Status = Status
