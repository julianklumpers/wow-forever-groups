local _, ns = ...

local L = ns.L

local W = ns.WindowParts
local Widgets = ns.Widgets
local Battlegrounds = ns.Battlegrounds
local WIDTH = W.WIDTH
local PAD = W.PAD
local CHECK_INSET = W.CHECK_INSET
local ROW_WIDTH = W.ROW_WIDTH
local RANGE_X = W.RANGE_X
local ROW_HEIGHT = W.QUEST_ROW_HEIGHT
local ui = W.ui
local queueRows = W.queueRows

local GOLD = { 1, 0.82, 0 }
local GREY = { 0.6, 0.6, 0.6 }

-- The Battlegrounds tab: the battlegrounds for the player's level bracket,
-- with who is looking for them in WoW's Group Finder.

local rows = {}

-- Looking through the Group Finder, the Forever Groups queue, or both.
local function looking()
    return ns.BgFinder.isActive() or ns.BgQueue.isQueued()
end

local function names(ids)
    local list = {}
    for i, id in ipairs(ids) do
        list[i] = Battlegrounds.name(Battlegrounds.parseKey(id) or id)
    end
    return table.concat(list, ", ")
end

-- A battleground premade is a raid, so its leader leads here too.
local function leads(state)
    return state == "solo" or state == "leader" or (state == "raid" and UnitIsGroupLeader("player"))
end

function W.battlegroundUnticked()
    ns.charDb.battlegroundUnticked = ns.charDb.battlegroundUnticked or {}
    return ns.charDb.battlegroundUnticked
end

-- The battlegrounds ticked in the tab; every one is ticked until the player
-- unticks it.
function W.tickedBattlegroundIds()
    local ids = {}
    for _, battleground in ipairs(Battlegrounds.forLevel(UnitLevel("player"))) do
        if not W.battlegroundUnticked()[battleground.id] then
            ids[#ids + 1] = battleground.id
        end
    end
    return ids
end

local GREEN = { 0.3, 1, 0.3 }
local SIZES = { 5, 10 }
local SIZE_LABELS = ns.Locale.mark({ [5] = "Party (5)", [10] = "Premade (10)" })

function W.battlegroundSize()
    return ns.BgFinder.chosenSize()
end

local function queueText(queue)
    if queue.status == "confirm" then
        return string.format(L["%s is ready: enter now!"], queue.name or L["The battleground"]), GREEN
    elseif queue.status == "active" then
        return string.format(L["In %s"], queue.name or L["the battleground"]), GREEN
    end
    local title = string.format(L["Signed up for %s"], queue.name or L["a battleground"])
    if queue.wait then
        title = title .. ", " .. string.format(L["about %s"], Widgets.formatTime(queue.wait))
    end
    return title, GOLD
end

function W.battlegroundCardContent(state)
    local queue = ns.BgFinder.queueStatus()
    if queue then
        local title, color = queueText(queue)
        return { title = title, color = color, lead = (state ~= "solo" and leads(state)) or nil }
    end
    local finding = ns.BgFinder.summary()
    local entry = ns.BgQueue.entry()
    local waiting = 0
    for _, key in ipairs(entry and entry.dungeons or {}) do
        waiting = waiting + ns.BgQueue.waitingFor(key)
    end
    local others = entry and (waiting > 0
        and ns.Locale.count(waiting, "%d Forever Groups player waiting with you.",
            "%d Forever Groups players waiting with you.")
        or L["Waiting for Forever Groups players too."])
    if finding then
        local name = Battlegrounds.name(finding.battleground)
        if finding.phase == "ask" then
            return { title = string.format(L["Looking for a %s group"], name), subtitle = others, color = GOLD }
        end
        local short = finding.healersShort or 0
        return { title = string.format(L["Building your %s group: %d/%d"], name, finding.members, finding.size),
            subtitle = short > 0
                and ns.Locale.count(short, "Still looking for %d healer.", "Still looking for %d healers.") or others,
            color = GOLD, lead = true }
    end
    if entry then
        return { title = string.format(L["Looking for a %s group"], names(entry.dungeons)), subtitle = others,
            color = GOLD,
            lead = state ~= "solo" and leads(state) or nil }
    end
    if state == "solo" then
        return { color = GOLD }
    end
    return { title = string.format(L["Your group: %d players"], math.max(1, GetNumGroupMembers() or 1)),
        subtitle = "To play, the leader talks to a battlemaster and chooses to join as a group.", color = GOLD,
        lead = state ~= "solo" and leads(state) }
end

-- The group size, as two small boxes on the line under the role tiles.
function W.placeBattlegroundSize(x, y)
    local shown = W.currentTab() == "battlegrounds" and not looking()
    ui.battlegroundSizeLabel:SetShown(shown)
    for _, size in ipairs(SIZES) do
        ui.battlegroundSizes[size]:SetShown(shown)
    end
    if not shown then
        return
    end
    W.place(ui.battlegroundSizeLabel, x, y - 5)
    x = x + (ui.battlegroundSizeLabel:GetStringWidth() or 40) + 8
    for _, size in ipairs(SIZES) do
        local box = ui.battlegroundSizes[size]
        local chosen = W.battlegroundSize() == size
        Widgets.paintOutline(box, { 1, 1, 1, chosen and 0.08 or 0.03 },
            chosen and { 1, 0.82, 0, 1 } or { 1, 1, 1, 0.3 })
        box.label:SetTextColor(chosen and 1 or 0.8, chosen and 0.82 or 0.8, chosen and 0 or 0.8)
        local width = (box.label:GetStringWidth() or 60) + 16
        box:SetWidth(width)
        W.place(box, x, y)
        x = x + width + 6
    end
end

-- "Find group" on this tab: at once in the Forever Groups queue (all ticked
-- battlegrounds) and through the Group Finder (the first ticked one it
-- lists), whichever finds a group first; while either runs the button stops
-- both.
function W.onBattlegroundJoinClicked()
    if looking() then
        ns.BgQueue.leave(ns.BgFinder.isActive() and "auto" or nil)
        ns.BgFinder.stop()
        W.setHint("")
        ns.Window.refresh()
        return
    end
    local roles = W.selectedRoles()
    local ids = W.tickedBattlegroundIds()
    if not roles or #ids == 0 then
        W.setHint("Choose a role and a battleground.")
        return
    end
    local queued, err = false
    local members, why = ns.BgQueue.members(roles, ns.BgFinder.joinedRoles())
    if members then
        queued, err = ns.BgQueue.join(ids, members)
    else
        err = why
    end
    local listed
    for _, id in ipairs(ids) do
        listed = listed or (Battlegrounds.get(id).lfg and id)
    end
    local found = false
    if listed then
        local findErr
        found, findErr = ns.BgFinder.start({ battleground = listed, size = W.battlegroundSize(), roles = roles,
            lead = W.wantsLead("battlegrounds") })
        err = err or findErr
    elseif queued then
        ns.Log.info("Looking for a %s group.", names(ids))
    end
    W.setHint((queued or found) and "" or string.format(L["Could not start: %s"], L[tostring(err)]))
    ns.Window.refresh()
end

function W.hideBattlegroundWidgets()
    ui.battlegroundHeader:Hide()
    ui.battlegroundHeader.line:Hide()
    ui.battlegroundEmpty:Hide()
    for _, row in ipairs(rows) do
        row:Hide()
    end
end

-- The groups in the Group Finder that still have room, or "quiet" when
-- nobody looks for it in the player's bracket.
local function paintDemand(row, wanted, known)
    local groups = #ns.QueueWindow.groupsNeedingMe(wanted, "battlegrounds")
    if groups > 0 then
        row.groups:SetText(ns.Locale.count(groups, "%d group", "%d groups"))
        row.groups:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
        return
    end
    local counts = known and ns.QueueWindow.lookingCounts(wanted, "battlegrounds")
    local quiet = counts and counts.T + counts.H + counts.D == 0
    row.groups:SetText(quiet and L["quiet"] or "")
    row.groups:SetTextColor(GREY[1], GREY[2], GREY[3])
end

local function showRow(row, battleground, y)
    local level = UnitLevel("player")
    row.id = battleground.id
    row.label:SetText(Battlegrounds.name(battleground.id))
    row.range:SetText(string.format(L["%s · %d players"], Battlegrounds.bracketText(level), battleground.size))
    local wanted = { [battleground.id] = true }
    local known = ns.LfgList.battlegroundsSearched()
    Widgets.setRoleCounts(row.counts, known and ns.QueueWindow.lookingCounts(wanted, "battlegrounds"))
    paintDemand(row, wanted, known)
    row:SetChecked(not W.battlegroundUnticked()[battleground.id])
    Widgets.setEnabled(row, not looking())
    W.place(row, PAD - CHECK_INSET, y)
    row:Show()
end

-- The tab below the card; returns the new y.
local function layout(y, state)
    W.hideBattlegroundWidgets()
    if not leads(state) then
        ui.battlegroundEmpty:SetText(L["Your group's leader signs the group up at a battlemaster."])
        W.place(ui.battlegroundEmpty, PAD, y)
        ui.battlegroundEmpty:Show()
        return y - 30
    end
    W.refreshRoles(looking())
    y = W.layoutChoices(y, false)
    if W.cardBelowRoles then
        y = W.cardBelowRoles(y)
    end
    local level = UnitLevel("player")
    local list = Battlegrounds.forLevel(level)
    ui.battlegroundHeader:SetText(string.format(L["Battlegrounds for level %d  ·  %d selected"], level,
        #W.tickedBattlegroundIds()))
    W.place(ui.battlegroundHeader, PAD, y)
    ui.battlegroundHeader:Show()
    ui.battlegroundHeader.line:Show()
    y = y - W.HEADER_STEP
    for i, row in ipairs(rows) do
        if list[i] then
            showRow(row, list[i], y)
            y = y - ROW_HEIGHT
        end
    end
    if #list == 0 then
        ui.battlegroundEmpty:SetText(string.format(L["Battlegrounds open at level %d."],
            Battlegrounds.list[1].minLevel))
        W.place(ui.battlegroundEmpty, PAD, y - 4)
        ui.battlegroundEmpty:Show()
        y = y - 26
    end
    return y - 8
end

function W.refreshBattlegroundsTab(y, state)
    W.setSetupShown(false)
    ui.queueHeader:Hide()
    ui.queueHeader.line:Hide()
    for _, row in ipairs(queueRows) do
        row:Hide()
    end
    ui.queueMore:Hide()
    y = layout(y, state)
    y = W.placeOtherQueueLink(y, state)
    local active = looking()
    local setup = not active and leads(state)
    local ready = W.selectedRoles() ~= nil and #W.tickedBattlegroundIds() > 0
    ui.join:SetText(L[active and "Stop" or (W.leadWord("battlegrounds") and "Find players" or "Find group")])
    ui.join:SetShown(active or setup)
    ui.joinSummary:SetShown(setup and ready)
    if setup and ready then
        local parts = { Widgets.describeRoles(W.selectedRoles()), L[SIZE_LABELS[W.battlegroundSize()]],
            names(W.tickedBattlegroundIds()) }
        ui.joinSummary:SetText(table.concat(parts, "  ·  "))
    end
    Widgets.setEnabled(ui.join, active or ready)
    ui.ready:SetText(L["Choose a role and a battleground."])
    ui.ready:SetShown(setup and not ready and (ui.hint:GetText() or "") == "")
    ui.fill:Hide()
    ui.delist:Hide()
    return y
end

function W.buildBattlegrounds()
    ui.battlegroundSizeLabel = Widgets.text(W.frame, "GameFontNormalSmall")
    ui.battlegroundSizeLabel:SetText(L["Group:"])
    ui.battlegroundSizes = {}
    for _, size in ipairs(SIZES) do
        local box = Widgets.backdropFrame("Button", W.frame)
        box:SetHeight(22)
        Widgets.addOutline(box)
        box.label = Widgets.text(box, "GameFontHighlightSmall", "CENTER")
        box.label:SetPoint("CENTER")
        box.label:SetText(L[SIZE_LABELS[size]])
        box:SetScript("OnClick", function()
            ns.charDb.bgSize = size
            ns.Window.refresh()
        end)
        Widgets.tooltip(box, SIZE_LABELS[size], size == 5
            and "A party of five: signs up together at the battlemaster."
            or "A full premade of ten: past five players the group becomes a raid.")
        box:Hide()
        ui.battlegroundSizes[size] = box
    end
    ui.battlegroundSizeLabel:Hide()
    ui.battlegroundHeader = Widgets.header(W.frame, "Battlegrounds", PAD, W.HEADER_GAP)
    ui.battlegroundEmpty = Widgets.text(W.frame, "GameFontDisableSmall")
    ui.battlegroundEmpty:SetWidth(WIDTH - 2 * PAD)
    for i = 1, #Battlegrounds.list do
        local row = Widgets.check(W.frame, "", function(self)
            W.battlegroundUnticked()[self.id] = not self:GetChecked() or nil
            W.setHint("")
            if self:GetChecked() and not ns.Input.run() then
                ns.QueueWindow.searchIfStale(10, "battlegrounds")
            end
            ns.Window.refresh()
        end)
        row.range = Widgets.text(row, "GameFontDisableSmall")
        row.range:SetPoint("LEFT", row, "LEFT", RANGE_X, 0)
        row.counts = Widgets.roleCounts(row, W.COUNT_SIZE)
        row.counts:SetPoint("LEFT", row, "LEFT", W.COUNTS_X, 0)
        row.groups = Widgets.text(row, "GameFontNormalSmall", "RIGHT")
        row.groups:SetPoint("RIGHT", row.counts, "LEFT", -14, 0)
        row:SetHitRectInsets(0, -(ROW_WIDTH - 22), 0, 0)
        row:HookScript("OnEnter", function(self)
            local battleground = self.id and Battlegrounds.get(self.id)
            if GameTooltip and battleground then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(Battlegrounds.name(battleground.id))
                GameTooltip:AddLine(string.format(L["Level bracket %s, %d players a side"],
                    Battlegrounds.bracketText(UnitLevel("player")), battleground.size), 1, 1, 1)
                GameTooltip:AddLine(L["Sign up at a battlemaster; a group leader can sign the whole group up."],
                    1, 1, 1, true)
                GameTooltip:Show()
            end
        end)
        row:HookScript("OnLeave", function()
            if GameTooltip then
                GameTooltip:Hide()
            end
        end)
        rows[i] = row
    end
end
