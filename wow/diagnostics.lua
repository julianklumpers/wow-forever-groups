local _, ns = ...

local Log = ns.Log

-- /fg selftest: which of the things Forever Groups leans on work in this
-- client. /fg bugreport: a window with the version, the self-test, the last
-- errors and log lines, ready to copy. Errors of this addon are kept as they
-- happen (the error handler is chained, so other error addons still see them).
local Diagnostics = {}

local MAX_ERRORS = 10
local REPORT_LOG_LINES = 40

local function has(path)
    local node = _G
    for part in string.gmatch(path, "[^%.]+") do
        if type(node) ~= "table" then
            return false
        end
        node = node[part]
    end
    return type(node) == "function"
end

local function all(...)
    for i = 1, select("#", ...) do
        if not has((select(i, ...))) then
            return false
        end
    end
    return true
end

-- { { name, state = "works" | "missing" | "not tried", detail } }
function Diagnostics.selftest()
    local results = {}
    local function add(name, state, detail)
        results[#results + 1] = { name = name, state = state, detail = detail }
    end
    local function check(name, ok, detail)
        add(name, ok and "works" or "missing", detail)
    end

    local channel = ns.Comm.channelId()
    check("Forever Groups channel", channel ~= nil and ns.Comm.selfName ~= nil,
        channel and ("/" .. channel .. " as " .. tostring(ns.Comm.selfName)) or "not joined")
    if not ns.Features.groupFinder() then
        add("Group Finder search", "not tried", "turned off in the settings")
    elseif not all("C_LFGList.Search", "C_LFGList.GetSearchResultInfo") then
        add("Group Finder search", "missing")
    elseif ns.LfgList.hasSearched() then
        add("Group Finder search", "works", "results received")
    else
        add("Group Finder search", "not tried", "no search yet: open the window")
    end
    local ranges = 0
    for _, dungeon in ipairs(ns.Dungeons.list) do
        if dungeon.min then
            ranges = ranges + 1
        end
    end
    check("Dungeon levels from the Group Finder", ranges > 0, ranges .. " of " .. #ns.Dungeons.list .. " dungeons")
    local zones = ns.LfgList.zoneCount()
    check("Quests & Zones category", zones > 0, zones .. " zones")
    local listing = ns.Listing.status()
    add("Listing your group", listing == "listed" and "works" or listing == "refused" and "missing" or "not tried",
        listing)
    check("Playstyles", type(Enum) == "table" and Enum.LFGEntryGeneralPlaystyle ~= nil
        and has("GetGeneralPlaystyleString"), ns.Playstyle.word(ns.Playstyle.mine()))
    local spec = ns.Spec.current()
    check("Talent tree (spec)", ns.Spec.points() ~= nil, spec and spec.name or "no spec yet")
    check("Party specs (inspect)", all("NotifyInspect", "CanInspect", "C_Traits.GetConfigInfo")
        and type(Constants) == "table" and type(Constants.TraitConsts) == "table"
        and Constants.TraitConsts.INSPECT_TRAIT_CONFIG_ID ~= nil)
    check("Quest labels (group, elite)", has("C_QuestLog.GetQuestTagInfo"),
        #ns.Quests.groupQuests() .. " group quests in the log")
    check("Sharing quests", all("C_QuestLog.SetSelectedQuest", "QuestLogPushQuest", "C_QuestLog.IsPushableQuest"))
    check("Turned in quests", has("C_QuestLog.IsQuestFlaggedCompleted"))
    check("Waypoints", all("C_Map.SetUserWaypoint", "UiMapPoint.CreateFromCoordinates"))
    check("Party distances", all("C_Map.GetPlayerMapPosition", "C_Map.GetMapWorldSize"))
    check("Inviting and leaving", all("C_PartyInfo.InviteUnit", "C_PartyInfo.LeaveParty"))
    local journalDungeons = 0
    for _ in pairs(ns.db.journalBossCounts or {}) do
        journalDungeons = journalDungeons + 1
    end
    check("Boss counts (Adventure Guide)", all("EJ_GetInstanceForMap", "EJ_GetEncounterInfoByIndex"),
        journalDungeons .. " dungeons seen inside")
    check("Version check", ns.Version.mine() ~= nil, ns.Version.mine())
    local style = ns.Widgets.frameStyles.ForeverGroupsFrame
    if style then
        check("Gold window frame", style == "gold")
    else
        add("Gold window frame", "not tried", "window not opened yet")
    end
    check("Red window buttons", ns.Widgets.atlasExists("RedButton-Condense"))
    return results
end

local COLORS = { works = "|cff33ff33", missing = "|cffff4040", ["not tried"] = "|cffaaaaaa" }

function Diagnostics.printSelftest()
    Log.info("Self-test (version %s):", tostring(ns.Version.mine()))
    for _, result in ipairs(Diagnostics.selftest()) do
        print(string.format("  %s%s|r  %s%s", COLORS[result.state], result.state, result.name,
            result.detail and ("  |cffaaaaaa(" .. tostring(result.detail) .. ")|r") or ""))
        Log.record("INFO", "selftest: %s  %s%s", result.state, result.name,
            result.detail and ("  (" .. tostring(result.detail) .. ")") or "")
    end
end

local function errors()
    ns.db.errors = ns.db.errors or {}
    return ns.db.errors
end

-- Keeps an error of this addon: the newest last, the same message counted.
function Diagnostics.recordError(message)
    message = tostring(message)
    local list = errors()
    for _, item in ipairs(list) do
        if item.message == message then
            item.count = item.count + 1
            item.at = date("%Y-%m-%d %H:%M:%S")
            item.version = ns.Version.mine()
            return
        end
    end
    list[#list + 1] = { message = message, count = 1, at = date("%Y-%m-%d %H:%M:%S"),
        version = ns.Version.mine() }
    while #list > MAX_ERRORS do
        table.remove(list, 1)
    end
end

function Diagnostics.report()
    local lines = {}
    local function add(fmt, ...)
        lines[#lines + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    end
    local version, build, _, toc = "?", "?", nil, "?"
    if GetBuildInfo then
        version, build, _, toc = GetBuildInfo()
    end
    add("Forever Groups %s | WoW %s (%s) | interface %s | %s", tostring(ns.Version.mine()), tostring(version),
        tostring(build), tostring(toc), GetLocale and GetLocale() or "?")
    local _, class = UnitClass("player")
    local spec = ns.Spec.current()
    add("Character: level %s %s%s | %s | debug %s", tostring(UnitLevel("player")), tostring(class),
        spec and (", " .. spec.name) or "", ns.Party.state(), ns.db.debug and "on" or "off")
    local dungeons = ns.engine and ns.engine.myEntry
    local quests = ns.questEngine and ns.questEngine.myEntry
    add("Queues: dungeons %s | quests %s", dungeons and table.concat(dungeons.dungeons, ",") or "no",
        quests and table.concat(quests.dungeons, ",") or "no")
    add("")
    add("Self-test:")
    for _, result in ipairs(Diagnostics.selftest()) do
        add("  %-9s %s%s", result.state, result.name, result.detail and (" (" .. tostring(result.detail) .. ")") or "")
    end
    add("")
    local list = errors()
    add("Errors (%d):", #list)
    for _, item in ipairs(list) do
        add("  %s  x%d  [%s]  %s", item.at, item.count, tostring(item.version), item.message)
    end
    add("")
    add("Log (last %d lines):", REPORT_LOG_LINES)
    for _, line in ipairs(Log.lines(REPORT_LOG_LINES)) do
        add("  %s", line)
    end
    return table.concat(lines, "\n")
end

local frame

local function build()
    frame = ns.Widgets.window("ForeverGroupsBugReportFrame", "Forever Groups bug report", 620, 460)
    local hint = ns.Widgets.text(frame, "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 20, -32)
    hint:SetText("Press Ctrl+C to copy (the text is selected), then paste it where you report the problem.")
    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 20, -54)
    scroll:SetPoint("BOTTOMRIGHT", -40, 20)
    local box = CreateFrame("EditBox", nil, scroll)
    box:SetMultiLine(true)
    box:SetAutoFocus(false)
    box:SetFontObject(ChatFontNormal)
    box:SetWidth(540)
    box:SetScript("OnEscapePressed", function()
        frame:Hide()
    end)
    scroll:SetScrollChild(box)
    frame.box = box
end

function Diagnostics.showReport()
    if not frame then
        build()
    end
    frame.box:SetText(Diagnostics.report())
    frame:Show()
    frame.box:SetFocus()
    frame.box:HighlightText()
end

function Diagnostics.init()
    if type(geterrorhandler) ~= "function" or type(seterrorhandler) ~= "function" then
        return
    end
    local previous = geterrorhandler()
    seterrorhandler(function(message, ...)
        if type(message) == "string" and string.find(message, "ForeverGroups", 1, true) then
            pcall(Diagnostics.recordError, message)
        end
        return previous(message, ...)
    end)
end

ns.Diagnostics = Diagnostics
