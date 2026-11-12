local World = {}
World.__index = World

local ADDON = "ForeverGroups"
local SERVER_TIME_BASE = 1794387000
local STEP = 0.1

local function tocVersion()
    for line in io.lines(ADDON .. ".toc") do
        local version = line:match("^## Version: (%S+)")
        if version then
            return version
        end
    end
end

local function tocFiles()
    local files = {}
    for line in io.lines(ADDON .. ".toc") do
        if line:match("%.lua$") then
            files[#files + 1] = (line:gsub("\\", "/"))
        end
    end
    return files
end

-- A value WoW hides during chat-messaging lockdown (Midnight's secret
-- values): using it (compare, concatenate, index) raises an error, as in
-- the game. Group Finder results are secret while client.lockdown is set.
World.SECRET = setmetatable({}, {
    __tostring = function()
        error("attempt to perform string conversion on a secret string value", 2)
    end,
    __index = function()
        error("attempt to index a secret value", 2)
    end,
    __lt = function()
        error("attempt to compare a secret value", 2)
    end,
    __le = function()
        error("attempt to compare a secret value", 2)
    end,
    __concat = function()
        error("attempt to concatenate a secret value", 2)
    end,
})

local function secretCopy(fields)
    local copy = {}
    for key in pairs(fields) do
        copy[key] = World.SECRET
    end
    return copy
end

-- The "Quests & Zones" activities of the Group Finder in the tests.
World.ZONE_ACTIVITIES = { [9001] = "Elwynn Forest", [9002] = "Westfall" }

World.QUEST_TAG_NAMES = { [1] = "Elite", [41] = "PvP", [81] = "Dungeon" }

World.QUEST_TITLES = { [101] = "Red Silk Bandanas", [102] = "Oh Brother...", [103] = "The Defias Brotherhood" }

-- Level ranges WoW's Group Finder gives in the tests, per activity id.
World.ACTIVITY_LEVELS = {
    [798] = { 13, 18 }, [1984] = { 13, 20 }, [1982] = { 15, 22 }, [796] = { 15, 24 }, [799] = { 17, 26 },
    [800] = { 20, 30 }, [801] = { 24, 32 }, [1981] = { 26, 33 }, [1983] = { 28, 33 }, [803] = { 29, 38 },
    [804] = { 29, 38 }, [805] = { 30, 38 }, [829] = { 33, 41 }, [827] = { 34, 42 }, [1985] = { 35, 40 },
    [828] = { 36, 45 }, [806] = { 37, 46 }, [807] = { 38, 48 }, [1986] = { 40, 45 }, [808] = { 43, 50 },
    [809] = { 45, 52 }, [1980] = { 48, 53 }, [810] = { 49, 56 }, [811] = { 52, 60 }, [1979] = { 55, 60 },
    [813] = { 55, 60 }, [812] = { 55, 60 }, [837] = { 55, 60 }, [815] = { 57, 60 }, [814] = { 57, 60 },
    [797] = { 58, 60 }, [1978] = { 58, 60 }, [816] = { 58, 60 }, [1603] = { 58, 60 },
}

function World.new()
    return setmetatable({ time = 0, timers = {}, clients = {}, inbox = {}, channelIds = {}, listings = {} }, World)
end

-- Enum.LFGEntryGeneralPlaystyle values, deliberately unlike Forever Groups's
-- own ids so a missing translation shows.
World.PLAYSTYLE = { Learning = 11, FunRelaxed = 12, FunSerious = 13, Expert = 14 }

-- A solo player in WoW's Group Finder. roles: "TD" etc.; playstyle: a key
-- of World.PLAYSTYLE.
function World:list(name, roles, activity, level, age, playstyle)
    local lfgRoles = {
        TANK = roles:find("T") ~= nil, HEALER = roles:find("H") ~= nil, DAMAGER = roles:find("D") ~= nil,
    }
    self.listings[#self.listings + 1] = {
        id = #self.listings + 1, leaderName = name, numMembers = 1, activityIDs = { activity or 799 },
        age = age or 60, level = level or 20, lfgRoles = lfgRoles, generalPlaystyle = World.PLAYSTYLE[playstyle],
        assignedRole = ({ T = "TANK", H = "HEALER", D = "DAMAGER" })[roles:sub(1, 1)],
    }
end

-- A group in WoW's Group Finder. remaining: { T = 0, H = 1, D = 1 }.
function World:listGroup(leader, activity, remaining, age, playstyle)
    local open = remaining.T + remaining.H + remaining.D
    self.listings[#self.listings + 1] = {
        id = #self.listings + 1, leaderName = leader, numMembers = 5 - open, activityIDs = { activity or 799 },
        age = age or 60, level = 20, lfgRoles = { TANK = true }, assignedRole = "TANK", remaining = remaining,
        generalPlaystyle = World.PLAYSTYLE[playstyle],
    }
    return #self.listings
end

function World:serverTime()
    return SERVER_TIME_BASE + math.floor(self.time)
end

function World:schedule(client, delay, fn, interval)
    self.timers[#self.timers + 1] = { client = client, at = self.time + delay, fn = fn, interval = interval }
end

function World:deliver()
    while #self.inbox > 0 do
        local msg = table.remove(self.inbox, 1)
        if msg.to.online then
            msg.to:fire(msg.event, unpack(msg.args, 1, msg.args.n))
        end
    end
end

function World:advance(seconds)
    local target = self.time + seconds
    while self.time < target - 1e-9 do
        self.time = self.time + STEP
        local due = {}
        for i = #self.timers, 1, -1 do
            local timer = self.timers[i]
            if timer.at <= self.time + 1e-9 then
                table.remove(self.timers, i)
                due[#due + 1] = timer
            end
        end
        table.sort(due, function(a, b)
            return a.at < b.at
        end)
        for _, timer in ipairs(due) do
            if timer.client.online then
                timer.fn()
                if timer.interval then
                    self:schedule(timer.client, timer.interval, timer.fn, timer.interval)
                end
            end
            self:deliver()
        end
    end
end

local function inParty(a, b)
    for _, name in ipairs(a.party) do
        if name == b.name then
            return true
        end
    end
    return false
end

function World:route(from, prefix, text, chatType, target)
    assert(#text <= 255, "addon message over 255 bytes: " .. text)
    if chatType == "PARTY" then
        for _, client in ipairs(self.clients) do
            if client.online and (client == from or inParty(from, client) or inParty(client, from)) then
                self.inbox[#self.inbox + 1] = {
                    to = client, event = "CHAT_MSG_ADDON", args = { prefix, text, "PARTY", from.name, n = 4 },
                }
            end
        end
        return
    end
    if chatType ~= "CHANNEL" then
        return
    end
    local channelName
    for name, id in pairs(from.channels) do
        if tostring(id) == tostring(target) then
            channelName = name
        end
    end
    assert(channelName, "sent to a channel the client is not in")
    for _, client in ipairs(self.clients) do
        if client.online and client.channels[channelName] then
            self.inbox[#self.inbox + 1] = {
                to = client, event = "CHAT_MSG_ADDON",
                args = { prefix, text, "CHANNEL", from.name, "", 0, client.channels[channelName], channelName, 0,
                    n = 9 },
            }
        end
    end
end

function World:findClient(name)
    for _, client in ipairs(self.clients) do
        if client.name == name and client.online then
            return client
        end
    end
end

local Client = {}
Client.__index = Client

function Client:fire(event, ...)
    for _, frame in ipairs(self.frames) do
        if frame.events[event] and frame.scripts.OnEvent then
            frame.scripts.OnEvent(frame, event, ...)
        end
    end
end

local function isVisible(widget)
    while widget do
        if not widget.shown then
            return false
        end
        widget = widget.parent
    end
    return true
end

local function isInside(widget, root)
    while widget do
        if widget == root then
            return true
        end
        widget = widget.parent
    end
    return false
end

function Client:find(kind, text, root)
    for _, widget in ipairs(self.widgets) do
        if widget.kind == kind and isVisible(widget) and (not root or isInside(widget, root)) then
            local label = widget.label and widget.label.text or widget.text or widget.iconLabel
            if label == text then
                return widget
            end
        end
    end
    return nil
end

-- The party row in the main window for a member (not the group slot).
function Client:findRow(name)
    for _, widget in ipairs(self.widgets) do
        if widget.kind == "FontString" and widget.text == name and widget.parent and widget.parent.partyRow
            and isVisible(widget) then
            return widget.parent
        end
    end
    error(self.name .. ": no party row for " .. name)
end

function Client:findText(pattern)
    for _, widget in ipairs(self.widgets) do
        if widget.kind == "FontString" and isVisible(widget) and widget.text and widget.text:find(pattern) then
            return widget
        end
    end
    return nil
end

function Client:click(kind, text, root)
    local widget = assert(self:find(kind, text, root), self.name .. ": no visible " .. kind .. " '" .. text .. "'")
    assert(widget.enabled, self.name .. ": " .. kind .. " '" .. text .. "' is disabled")
    if kind == "CheckButton" then
        widget.checked = not widget.checked
    end
    self.inClick = true
    widget.scripts.OnClick(widget)
    self.inClick = false
end

function Client:frame(name)
    return self.env[name]
end

function Client:proposalShown()
    local frame = self.env.ForeverGroupsProposalFrame
    return frame ~= nil and frame.shown
end

function Client:slash(text)
    local command, rest = text:match("^(/%S+)%s*(.-)$")
    for key, fn in pairs(self.env.SlashCmdList) do
        for i = 1, 5 do
            if self.env["SLASH_" .. key .. i] == command then
                self.inClick = true
                fn(rest)
                self.inClick = false
                return
            end
        end
    end
    error("unknown slash command " .. command)
end

function Client:acceptPopup()
    assert(self:proposalShown(), self.name .. " has no proposal popup")
    self:click("Button", "Accept")
end

function Client:declinePopup()
    assert(self:proposalShown(), self.name .. " has no proposal popup")
    self:click("Button", "Decline")
end

function Client:said(pattern)
    for _, line in ipairs(self.chat) do
        if line:find(pattern) then
            return true
        end
    end
    return false
end

-- The player presses a key while playing.
-- A mouse click on the 3D world (not on a window): player input, like a key.
function Client:clickWorld(button)
    local frame = self.env.WorldFrame
    self.inClick = true
    for _, fn in ipairs(frame.hooks and frame.hooks.OnMouseDown or {}) do
        fn(frame, button or "LeftButton")
    end
    self.inClick = false
end

function Client:press(key)
    local frame = self.env.ForeverGroupsKeySearchFrame
    if frame and frame.keyboard and frame.scripts.OnKeyDown then
        self.inClick = true
        frame.scripts.OnKeyDown(frame, key)
        self.inClick = false
    end
end

-- Answers the last StaticPopup this client showed.
function Client:acceptStaticPopup()
    local which = assert(self.popups[#self.popups], self.name .. " has no popup")
    self.inClick = true
    self.env.StaticPopupDialogs[which].OnAccept()
    self.inClick = false
end

function Client:leaves(name)
    for i, n in ipairs(self.party) do
        if n == name then
            table.remove(self.party, i)
        end
    end
    self:fire("GROUP_ROSTER_UPDATE")
end

function Client:whisperFrom(name, text)
    self:fire("CHAT_MSG_WHISPER", text, name)
end

function Client:invitedBy(leader)
    self:fire("PARTY_INVITE_REQUEST", leader)
end

-- Accepts the pending invite and becomes a member of leader's group.
function Client:joinGroupOf(leader)
    self.party[#self.party + 1] = leader
    self.isLeader = false
    self:fire("GROUP_ROSTER_UPDATE")
end

-- A solo player applies to this client's listing.
function Client:applicant(name, roles, level)
    local id = #self.applicants + 1
    self.applicants[id] = {
        name = name, level = level or 20, status = "applied",
        tank = roles:find("T") ~= nil, healer = roles:find("H") ~= nil, damage = roles:find("D") ~= nil,
    }
    self:fire("LFG_LIST_APPLICANT_LIST_UPDATED")
    return id
end

function Client:joins(name)
    self.party[#self.party + 1] = name
    self.isLeader = true
    self:fire("GROUP_ROSTER_UPDATE")
end

function Client:system(text)
    self:fire("CHAT_MSG_SYSTEM", text)
end

function Client:logout()
    self:fire("PLAYER_LOGOUT")
    self.online = false
    return { db = self.env.ForeverGroupsDB, charDb = self.env.ForeverGroupsCharDB }
end

local function buildEnv(world, client)
    local env = setmetatable({}, { __index = _G })
    -- A secret string is still a string to type(), as in the game.
    env.type = function(value)
        if rawequal(value, World.SECRET) then
            return "string"
        end
        return type(value)
    end
    env._G = env
    -- WoW has no require: every module must come after the ones it uses in
    -- the TOC.
    env.require = function(module)
        error("WoW has no require (" .. tostring(module) .. "): fix the TOC order", 2)
    end
    env.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[#parts + 1] = tostring((select(i, ...)))
        end
        client.chat[#client.chat + 1] = table.concat(parts, " ")
    end
    env.date = os.date
    env.time = function()
        return world:serverTime()
    end
    env.GetTime = function()
        return world.time
    end
    env.GetServerTime = function()
        return world:serverTime()
    end
    local function unitName(unit)
        if unit == "player" then
            return client.name
        end
        local index = tonumber(string.match(unit, "^party(%d)$"))
        return index and client.party[index]
    end
    env.UnitLevel = function()
        return client.level
    end
    env.UnitFullName = function(unit)
        local name = unitName(unit)
        if not name then
            return nil
        end
        local first, second = string.match(name, "^(%S+) (.+)$")
        if first then
            return first, second
        end
        return name, nil
    end
    env.UnitClass = function(unit)
        local name = unitName(unit)
        local token = name and (unit == "player" and client.class or client.partyClasses[name])
        if token then
            return token:sub(1, 1) .. token:sub(2):lower(), token
        end
        return nil, nil
    end
    env.UnitExists = function(unit)
        return unitName(unit) ~= nil
    end
    env.GetNormalizedRealmName = function()
        return "CAMWOWEU5Realm6PvP"
    end
    env.IsInGroup = function()
        return client.inGroup or #client.party > 0
    end
    env.InCombatLockdown = function()
        return client.inCombat == true
    end
    env.UnitIsVisible = function(unit)
        return client.visible[unit] == true
    end
    env.IsInInstance = function()
        return client.inInstance == true, client.inInstance and (client.instanceType or "party") or "none"
    end
    env.GetInstanceInfo = function()
        return client.instanceName
    end
    local function vector(x, y)
        return { GetXY = function()
            return x, y
        end }
    end
    env.C_Map = {
        GetBestMapForUnit = function(unit)
            local p = client.positions[unit]
            return p and p[1]
        end,
        GetPlayerMapPosition = function(map, unit)
            local p = client.positions[unit]
            if p and p[1] == map then
                return vector(p[2], p[3])
            end
        end,
        GetMapWorldSize = function()
            return 1000, 1000
        end,
        GetMapChildrenInfo = function(root)
            if root ~= 946 then
                return {}
            end
            local children = {}
            for map in pairs(client.journalEntrances) do
                children[#children + 1] = { mapID = map }
            end
            return children
        end,
        SetUserWaypoint = function(point)
            client.waypoint = point
        end,
    }
    env.UiMapPoint = {
        CreateFromCoordinates = function(map, x, y)
            return { map = map, x = x, y = y }
        end,
    }
    env.C_SuperTrack = { SetSuperTrackedUserWaypoint = function() end }
    env.RaidWarningFrame = {}
    env.ChatTypeInfo = { RAID_WARNING = {} }
    env.RaidNotice_AddMessage = function(_, text)
        client.notices[#client.notices + 1] = text
    end
    env.C_QuestLog = {
        GetNumQuestLogEntries = function()
            return #client.questLog
        end,
        GetInfo = function(i)
            local entry = client.questLog[i]
            return entry and { title = entry[1], isHeader = entry[2] == true, questID = entry[3],
                suggestedGroup = entry[5] or 0 }
        end,
        GetQuestObjectives = function(id)
            for _, entry in ipairs(client.questLog) do
                if entry[3] == id then
                    return entry[6] or {}
                end
            end
        end,
        IsComplete = function(id)
            for _, entry in ipairs(client.questLog) do
                if entry[3] == id then
                    return entry[7] == true
                end
            end
            return false
        end,
        IsQuestFlaggedCompleted = function(id)
            return client.completedQuests ~= nil and client.completedQuests[id] == true
        end,
        GetQuestTagInfo = function(id)
            for _, entry in ipairs(client.questLog) do
                if entry[3] == id and entry[4] then
                    return { tagID = entry[4], tagName = World.QUEST_TAG_NAMES[entry[4]] }
                end
            end
        end,
        IsPushableQuest = function(id)
            return id ~= 999
        end,
        SetSelectedQuest = function(id)
            client.selectedQuest = id
        end,
        GetTitleForQuestID = function(id)
            if World.QUEST_TITLES[id] then
                return World.QUEST_TITLES[id]
            end
            for _, entry in ipairs(client.questLog) do
                if entry[3] == id then
                    return entry[1]
                end
            end
        end,
    }
    env.QuestLogPushQuest = function()
        client.pushed[#client.pushed + 1] = client.selectedQuest
    end
    env.C_EncounterJournal = {
        GetDungeonEntrancesForMap = function(map)
            return client.journalEntrances[map]
        end,
    }
    env.EJ_GetInstanceForMap = function(map)
        return client.journalMaps[map]
    end
    env.EJ_GetEncounterInfoByIndex = function(index, journal)
        local count = client.journalBosses[journal] or 0
        if index <= count then
            return "Boss " .. index
        end
    end
    env.StaticPopupDialogs = {}
    env.StaticPopup_Show = function(which)
        client.popups[#client.popups + 1] = which
    end
    local errorHandler = function(err)
        error(err, 0)
    end
    env.geterrorhandler = function()
        return errorHandler
    end
    env.seterrorhandler = function(handler)
        errorHandler = handler
    end
    env.GetBuildInfo = function()
        return "1.60.1", "70888", "Nov 1 2026", 16001
    end
    env.GetLocale = function()
        return "enUS"
    end
    env.IsInRaid = function()
        return client.inRaid == true
    end
    env.UnitIsGroupLeader = function(unit)
        if unit == nil or unit == "player" then
            return client.isLeader
        end
        local name = unitName(unit)
        if client.leaderName then
            return name == client.leaderName
        end
        local other = name and world:findClient(name)
        return other ~= nil and other.isLeader == true
    end
    env.UnitGroupRolesAssigned = function(unit)
        local name = unitName(unit)
        return name and client.roles[name] or "NONE"
    end
    env.UnitSetRole = function(unit, role)
        local name = unitName(unit)
        if unit ~= "player" and not client.isLeader then
            error("only the leader can set other roles")
        end
        client.roles[name] = role
        client.roleSets[#client.roleSets + 1] = name .. "=" .. role
    end
    env.UnitInParty = function()
        return false
    end
    local function noop() end
    local methods = {}
    local function newWidget(kind, name, parent)
        local widget = setmetatable({
            kind = kind, parent = parent, shown = true, enabled = true, checked = false, events = {}, scripts = {},
        }, { __index = function(_, key)
            if methods[key] then
                return methods[key]
            end
            if type(key) == "string" and key:match("^%u") then
                return noop
            end
        end })
        client.widgets[#client.widgets + 1] = widget
        if name then
            env[name] = widget
        end
        return widget
    end
    function methods.RegisterEvent(widget, event)
        widget.events[event] = true
    end
    function methods.SetPoint(widget, ...)
        widget.point = { ... }
    end
    function methods.SetScript(widget, script, fn)
        widget.scripts[script] = fn
    end
    function methods.HookScript(widget, script, fn)
        widget.hooks = widget.hooks or {}
        widget.hooks[script] = widget.hooks[script] or {}
        table.insert(widget.hooks[script], fn)
    end
    function methods.Show(widget)
        local wasShown = widget.shown
        widget.shown = true
        if not wasShown and widget.scripts.OnShow then
            widget.scripts.OnShow(widget)
        end
    end
    function methods.Hide(widget)
        local wasShown = widget.shown
        widget.shown = false
        if wasShown then
            for _, fn in ipairs(widget.hooks and widget.hooks.OnHide or {}) do
                fn(widget)
            end
        end
    end
    function methods.SetShown(widget, shown)
        if shown then
            widget:Show()
        else
            widget:Hide()
        end
    end
    function methods.IsShown(widget)
        return widget.shown
    end
    function methods.SetText(widget, text)
        widget.text = text
    end
    function methods.GetText(widget)
        return widget.text
    end
    function methods.SetChecked(widget, checked)
        widget.checked = checked and true or false
    end
    function methods.GetChecked(widget)
        return widget.checked
    end
    function methods.Enable(widget)
        widget.enabled = true
    end
    function methods.Disable(widget)
        widget.enabled = false
    end
    function methods.IsEnabled(widget)
        return widget.enabled
    end
    function methods.GetStringWidth(widget)
        return #(widget.text or "") * 7
    end
    function methods.SetPropagateKeyboardInput(widget, value)
        widget.propagate = value
    end
    function methods.GetPropagateKeyboardInput(widget)
        return widget.propagate
    end
    function methods.EnableKeyboard(widget, value)
        widget.keyboard = value
    end
    function methods.SetHitRectInsets(widget, left, right, top, bottom)
        widget.hitInsets = { left, right, top, bottom }
    end
    function methods.SetHeight(widget, height)
        widget.height = height
    end
    function methods.SetTexture(widget, texture)
        widget.texture, widget.atlas = texture, nil
    end
    function methods.SetAlpha(widget, value)
        widget.alpha = value
    end
    function methods.SetTexCoord(widget, ...)
        widget.texCoord = { ... }
    end
    function methods.SetDesaturated(widget, value)
        widget.desaturated = value
    end
    function methods.SetAtlas(widget, atlas)
        widget.atlas, widget.texture = atlas, nil
    end
    function methods.SetValue(widget, value)
        widget.value = value
    end
    function methods.CreateFontString(widget)
        return newWidget("FontString", nil, widget)
    end
    function methods.CreateTexture(widget)
        return newWidget("Texture", nil, widget)
    end
    function methods.StartSearchingAnimation(widget)
        widget.animating = true
    end
    function methods.StopAnimating(widget)
        widget.animating = false
    end
    env.CreateFrame = function(kind, name, parent, template)
        if template == "EyeTemplate" and client.noEyeTemplate then
            error("Couldn't find inherited node \"EyeTemplate\"")
        end
        local frame = newWidget(kind, name, parent)
        frame.template = template
        client.frames[#client.frames + 1] = frame
        if template == "BasicFrameTemplateWithInset" or template == "ButtonFrameTemplate" then
            -- Blizzard's close button hides through HideUIPanel, which does
            -- nothing in combat for an addon frame.
            local close = newWidget("Button", nil, frame)
            close.scripts.OnClick = function()
                if not client.inCombat then
                    frame:Hide()
                end
            end
            client.frames[#client.frames + 1] = close
            frame.CloseButton = close
        end
        return frame
    end
    env.C_Texture = {
        GetAtlasInfo = function(atlas)
            if client.atlases[atlas] then
                return { width = 64, height = 64 }
            end
        end,
    }
    env.UIParent = newWidget("Frame")
    env.WorldFrame = newWidget("Frame")
    env.Minimap = newWidget("Frame")
    env.Minimap.GetWidth = function()
        return 140
    end
    env.Minimap.GetCenter = function()
        return 500, 500
    end
    env.Minimap.GetEffectiveScale = function()
        return 1
    end
    env.ChatFrame_SendTell = function(name)
        client.tellTarget = name
    end
    env.GetCursorPosition = function()
        return client.cursorX or 500, client.cursorY or 500
    end
    env.GameTooltip = newWidget("GameTooltip")
    env.UISpecialFrames = {}
    env.C_Timer = {
        After = function(delay, fn)
            world:schedule(client, delay, fn)
        end,
        NewTicker = function(interval, fn)
            world:schedule(client, interval, fn, interval)
        end,
    }
    env.Enum = {
        SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3, InvalidChannel = 7, ChannelThrottle = 8,
            AddOnMessageLockdown = 11 },
        LFGEntryGeneralPlaystyle = World.PLAYSTYLE,
        QuestTag = { Group = 1, PvP = 41, Raid = 62, Dungeon = 81 },
    }
    -- talents: { { x, ranks } }, nodes of Forever's talent tree.
    env.C_ClassTalents = {
        GetActiveConfigID = function()
            return client.talents and 1 or nil
        end,
    }
    -- inspectTalents: { [name] = talents } of party members; inspecting
    -- answers half a second later, out of range or in combat never.
    local function talentsOf(configID)
        if configID == -1 then
            return client.inspectTalents[client.inspected or ""] or {}
        end
        return client.talents or {}
    end
    env.Constants = { TraitConsts = { INSPECT_TRAIT_CONFIG_ID = -1 } }
    env.C_Traits = {
        GetConfigInfo = function(configID)
            return { treeIDs = { configID == -1 and 2 or 1 } }
        end,
        GetTreeNodes = function(treeID)
            local ids = {}
            for i in ipairs(talentsOf(treeID == 2 and -1 or 1)) do
                ids[i] = i
            end
            return ids
        end,
        GetNodeInfo = function(configID, id)
            local node = talentsOf(configID)[id]
            return { ID = id, posX = node[1], posY = 0, ranksPurchased = node[2] }
        end,
    }
    env.UnitGUID = function(unit)
        local name = unitName(unit)
        return name and ("Player-" .. name)
    end
    env.CanInspect = function(unit)
        return unitName(unit) ~= nil
    end
    env.CheckInteractDistance = function(unit)
        return unitName(unit) ~= nil and not client.farAway[unitName(unit)]
    end
    env.NotifyInspect = function(unit)
        local name = unitName(unit)
        client.inspects[#client.inspects + 1] = name
        world:schedule(client, 0.5, function()
            client.inspected = name
            client:fire("INSPECT_READY", "Player-" .. name)
        end)
    end
    env.ClearInspectPlayer = function()
        client.inspected = nil
    end
    env.C_AddOns = {
        IsAddOnLoaded = function(name)
            return client.oldAddon ~= nil and name == "DungeonQueue"
        end,
        DisableAddOn = function(name)
            client.disabledAddOns[#client.disabledAddOns + 1] = name
        end,
        GetAddOnMetadata = function(name, field)
            if name == ADDON and field == "Version" then
                return client.version or tocVersion()
            end
        end,
    }
    env.C_ChatInfo = {
        RegisterAddonMessagePrefix = function()
            return 0
        end,
        SendAddonMessage = function(prefix, text, chatType, target)
            local forced = table.remove(client.sendResults, 1)
            if forced then
                return forced
            end
            world:route(client, prefix, text, chatType, target)
            client.sent[#client.sent + 1] = text
            return 0
        end,
        InChatMessagingLockdown = function()
            return client.lockdown == true
        end,
        SendChatMessage = function(text, chatType, _, target)
            client.whispers[#client.whispers + 1] = { chatType = chatType, target = target, text = text }
        end,
    }
    env.C_PartyInfo = {
        LeaveParty = function()
            client.party = {}
            client.leftParty = true
        end,
        InviteUnit = function(name)
            client.invites[#client.invites + 1] = name
            local target = world:findClient(name)
            if target then
                world.inbox[#world.inbox + 1] = { to = target, event = "PARTY_INVITE_REQUEST",
                    args = { client.name, n = 1 } }
            end
        end,
    }
    env.C_LFGList = {
        Search = function(_, _, _, languages, _, _, activities)
            client.searchLanguages = languages
            if not client.inClick then
                client.blockedSearches = client.blockedSearches + 1
                client:fire("ADDON_ACTION_BLOCKED", "ForeverGroups", "UNKNOWN()")
                return
            end
            if activities and client.rejectFilter then
                error("bad argument #7 to 'Search'")
            end
            client.searches = client.searches + 1
            client.searchFilter = nil
            if activities then
                client.searchFilter = {}
                for _, id in ipairs(activities) do
                    client.searchFilter[id] = true
                end
            end
            world:schedule(client, 0.5, function()
                client:fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
            end)
        end,
        HasActiveEntryInfo = function()
            return client.listed == true
        end,
        RemoveListing = function()
            assert(client.inClick, "RemoveListing outside a click")
            client.listed = false
        end,
        CreateListing = function(...)
            assert(client.inClick, "CreateListing outside a click")
            local first = ...
            if client.listingShape and client.listingShape ~= (type(first) == "table" and first.activityIDs
                and "table" or "positional") then
                error("bad argument #1 to 'CreateListing'")
            end
            client.listed = true
            client.listingArgs = { ... }
            client:fire("LFG_LIST_ACTIVE_ENTRY_UPDATE")
        end,
        GetAvailableLanguageSearchFilter = function()
            return { "enUS", "deDE", "frFR" }
        end,
        GetApplicants = function()
            local ids = {}
            for id in ipairs(client.applicants) do
                ids[#ids + 1] = id
            end
            return ids
        end,
        GetApplicantInfo = function(id)
            return { applicantID = id, applicationStatus = client.applicants[id].status, numMembers = 1 }
        end,
        GetApplicantMemberInfo = function(id)
            local a = client.applicants[id]
            return a.name, "WARRIOR", "Warrior", a.level, 100, 0, a.tank, a.healer, a.damage
        end,
        InviteApplicant = function(id)
            assert(client.inClick, "InviteApplicant outside a click")
            client.applicants[id].status = "invited"
            client.applicantInvites[#client.applicantInvites + 1] = client.applicants[id].name
        end,
        GetAvailableCategories = function()
            return { 2, 116 }
        end,
        GetLfgCategoryInfo = function(id)
            return { name = id == 116 and "Quests & Zones" or "Dungeons" }
        end,
        GetAvailableActivities = function(category)
            local ids = {}
            if category == 116 and not client.zonesLate then
                for id in pairs(World.ZONE_ACTIVITIES) do
                    ids[#ids + 1] = id
                end
                table.sort(ids)
            end
            return ids
        end,
        GetActivityInfoTable = function(activity)
            if World.ZONE_ACTIVITIES[activity] then
                return { fullName = World.ZONE_ACTIVITIES[activity] }
            end
            local levels = client.activityLevels[activity]
            if levels then
                return { minLevelSuggestion = levels[1], maxLevelSuggestion = levels[2] }
            end
        end,
        GetSearchResultMemberCounts = function(id)
            local r = world.listings[id].remaining
            if r then
                return { TANK = 1 - r.T, HEALER = 1 - r.H, DAMAGER = 3 - r.D }
            end
        end,
        GetSearchResults = function()
            local ids = {}
            for _, listing in ipairs(world.listings) do
                local wanted = not client.searchFilter
                for _, activity in ipairs(listing.activityIDs) do
                    wanted = wanted or client.searchFilter[activity]
                end
                if wanted then
                    ids[#ids + 1] = listing.id
                end
            end
            return #ids, ids
        end,
        GetSearchResultInfo = function(id)
            local l = world.listings[id]
            local info = { leaderName = l.leaderName, numMembers = l.numMembers, activityIDs = l.activityIDs,
                age = l.age, isDelisted = l.isDelisted == true, generalPlaystyle = l.generalPlaystyle or 0 }
            return client.lockdown and secretCopy(info) or info
        end,
        GetSearchResultLeaderInfo = function(id)
            local l = world.listings[id]
            local info = { name = l.leaderName, level = l.level, lfgRoles = l.lfgRoles, classFilename = "WARRIOR",
                assignedRole = l.assignedRole or "NONE" }
            return client.lockdown and secretCopy(info) or info
        end,
    }
    env.ERR_DECLINE_GROUP_S = "%s declines your group invitation."
    env.ERR_ALREADY_IN_GROUP_S = "%s is already in a group."
    env.ERR_BAD_PLAYER_NAME_S = "Cannot find player '%s'."
    env.JoinTemporaryChannel = function(name)
        world.channelIds[name] = world.channelIds[name] or 6
        client.channels[name] = world.channelIds[name]
        return 0
    end
    env.GetChannelName = function(name)
        return client.channels[name] or 0
    end
    env.LeaveChannelByName = function(name)
        client.channels[name] = nil
    end
    env.NUM_CHAT_WINDOWS = 1
    env.ChatFrame1 = {}
    env.ChatFrame_RemoveChannel = function() end
    env.ChatFrame_AddMessageEventFilter = function() end
    env.PlaySound = function() end
    env.FlashClientIcon = function()
        client.flashes = (client.flashes or 0) + 1
    end
    env.SOUNDKIT = { READY_CHECK = 8960 }
    env.ACCEPT, env.DECLINE = "Accept", "Decline"
    env.SlashCmdList = {}
    env.issecretvalue = function(value)
        return rawequal(value, World.SECRET)
    end
    env.canaccessvalue = function(value)
        return not rawequal(value, World.SECRET)
    end
    return env
end

function World:addClient(name, opts)
    opts = opts or {}
    local client = setmetatable({
        name = name, level = opts.level or 18, inGroup = false, online = true,
        frames = {}, chat = {}, sent = {}, whispers = {}, invites = {}, channels = {}, sendResults = {},
        widgets = {}, party = {}, partyClasses = {}, isLeader = false, class = opts.class,
        searches = 0, blockedSearches = 0, roles = {}, roleSets = {}, notices = {},
        applicants = {}, applicantInvites = {},
        noEyeTemplate = opts.noEyeTemplate, version = opts.version, talents = opts.talents,
        questLog = opts.questLog or {}, positions = {}, visible = {}, popups = {}, pushed = {},
        inspectTalents = {}, inspects = {}, farAway = {},
        activityLevels = opts.activityLevels or World.ACTIVITY_LEVELS, journalEntrances = opts.journalEntrances or {},
        journalBosses = opts.journalBosses or {}, journalMaps = opts.journalMaps or {},
        atlases = opts.atlases or {
            ["groupfinder-icon-role-large-tank"] = true, ["UI-LFG-RoleIcon-Tank"] = true,
        },
    }, Client)
    client.env = buildEnv(self, client)
    if opts.saved then
        client.env.ForeverGroupsDB = opts.saved.db
        client.env.ForeverGroupsCharDB = opts.saved.charDb
    end
    client.disabledAddOns, client.oldAddon = {}, opts.oldAddon
    if opts.oldAddon then
        client.env.DungeonQueueDB = opts.oldAddon.db
        client.env.DungeonQueueCharDB = opts.oldAddon.charDb
    end
    client.ns = {}
    for _, path in ipairs(tocFiles()) do
        local chunk = assert(loadfile(path))
        setfenv(chunk, client.env)
        chunk(ADDON, client.ns)
    end
    self.clients[#self.clients + 1] = client
    if opts.beforeLogin then
        opts.beforeLogin(client)
    end
    client:fire("ADDON_LOADED", ADDON)
    client:fire("PLAYER_LOGIN")
    return client
end

return World
