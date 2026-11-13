local ADDON_NAME = ...

local PREFIX = "FGProbe"
local DEFAULT_CHANNEL = "FGProbeChan"
local MAX_LOG_LINES = 1500
local SYSTEM_WATCH_SECONDS = 6

local db
local channelName = DEFAULT_CHANNEL
local pendingPings = {}
local pingSeq = 0
local recvCounts = {}
local recvSummaryScheduled = false
local watchSystemUntil = 0
local unknownEvents = {}
local lastGroupSize

local COLORS = {
    PASS = "ff40ff40",
    FAIL = "ffff4040",
    WARN = "ffffd040",
    INFO = "ffa0c8ff",
    RECV = "ffd0a0ff",
    EVENT = "ffc0c0c0",
}

local API_PATHS = {
    "C_ChatInfo.RegisterAddonMessagePrefix",
    "C_ChatInfo.IsAddonMessagePrefixRegistered",
    "C_ChatInfo.SendAddonMessage",
    "C_ChatInfo.SendAddonMessageLogged",
    "C_ChatInfo.InChatMessagingLockdown",
    "C_ChatInfo.SendChatMessage",
    "SendChatMessage",
    "Enum.SendAddonMessageResult",
    "Enum.RegisterAddonMessagePrefixResult",
    "JoinTemporaryChannel",
    "JoinChannelByName",
    "JoinPermanentChannel",
    "LeaveChannelByName",
    "GetChannelName",
    "GetChannelList",
    "GetChatWindowChannels",
    "RemoveChatWindowChannel",
    "ChatFrame_RemoveChannel",
    "ChatFrameUtil.RemoveChannel",
    "ChatFrame_AddMessageEventFilter",
    "ChatFrameUtil.AddMessageEventFilter",
    "C_PartyInfo.InviteUnit",
    "C_PartyInfo.ConfirmInviteUnit",
    "C_PartyInfo.LeaveParty",
    "InviteUnit",
    "AcceptGroup",
    "DeclineGroup",
    "UninviteUnit",
    "PromoteToLeader",
    "UnitIsGroupLeader",
    "IsInGroup",
    "GetNumGroupMembers",
    "StaticPopup_Show",
    "StaticPopup_Hide",
    "StaticPopupDialogs",
    "FlashClientIcon",
    "PlaySound",
    "C_Timer.After",
    "C_Timer.NewTicker",
    "GetServerTime",
    "GetTime",
    "UnitFullName",
    "GetNormalizedRealmName",
    "Ambiguate",
    "issecretvalue",
    "canaccessvalue",
    "InCombatLockdown",
    "IsInInstance",
    "C_GameRules.IsGameRuleActive",
    "C_LFGList.GetActiveEntryInfo",
    "C_AddOns.GetAddOnMetadata",
    "ChatThrottleLib",
}

local function resolve(path)
    local node = _G
    for part in string.gmatch(path, "[^%.]+") do
        if type(node) ~= "table" then
            return nil
        end
        node = node[part]
    end
    return node
end

local function isSecret(value)
    return issecretvalue ~= nil and issecretvalue(value) == true
end

local function show(value)
    if isSecret(value) then
        return "<secret>"
    end
    if type(value) == "string" then
        return (value:gsub("|", "||"))
    end
    return tostring(value)
end

local function showAll(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = show((select(i, ...)))
    end
    if #parts == 0 then
        return "(no returns)"
    end
    return table.concat(parts, ", ")
end

local function format(fmt, ...)
    if select("#", ...) > 0 then
        return string.format(fmt, ...)
    end
    return fmt
end

local function store(tag, fmt, ...)
    if not db then
        return
    end
    local lines = db.lines
    lines[#lines + 1] = string.format("%s [%s] %s", date("%Y-%m-%d %H:%M:%S"), tag, format(fmt, ...))
    while #lines > MAX_LOG_LINES do
        table.remove(lines, 1)
    end
end

local function log(tag, fmt, ...)
    local msg = format(fmt, ...)
    print(string.format("|c%s[DQP %s]|r %s", COLORS[tag] or "ffffffff", tag, msg))
    store(tag, "%s", msg)
end

local function myFullName()
    local name, realm = UnitFullName("player")
    if not realm or realm == "" then
        realm = GetNormalizedRealmName and GetNormalizedRealmName()
    end
    if realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

local function isMe(sender)
    return sender == myFullName() or sender == UnitName("player")
end

local function resultName(ret)
    if ret == nil then
        return "nil", nil
    end
    if type(ret) == "boolean" then
        return tostring(ret), ret
    end
    local enum = Enum and Enum.SendAddonMessageResult
    if enum then
        for key, value in pairs(enum) do
            if value == ret then
                return string.format("%s(%s)", key, tostring(ret)), ret == enum.Success
            end
        end
    end
    return tostring(ret), ret == 0
end

local function sendAddon(text, chatType, target, quiet)
    local ok, ret = pcall(C_ChatInfo.SendAddonMessage, PREFIX, text, chatType, target)
    if not ok then
        log("FAIL", "SendAddonMessage %s raised an error: %s", chatType, show(ret))
        return false
    end
    local name, success = resultName(ret)
    if not quiet then
        local tag = (success == true and "PASS") or (success == nil and "WARN") or "FAIL"
        log(tag, "SendAddonMessage %s target=%s (%d bytes) -> %s", chatType, show(target), #text, name)
    end
    return success, name
end

local function channelId()
    local id = GetChannelName(channelName)
    if type(id) == "number" and id > 0 then
        return id
    end
    return nil
end

local function chatFramesShowingChannel()
    local frames = {}
    if not GetChatWindowChannels then
        return frames, false
    end
    local wanted = channelName:lower()
    for i = 1, NUM_CHAT_WINDOWS or 10 do
        local list = { GetChatWindowChannels(i) }
        for j = 1, #list, 2 do
            if type(list[j]) == "string" and list[j]:lower() == wanted then
                frames[#frames + 1] = i
            end
        end
    end
    return frames, true
end

local function tryRemoveFromFrame(index, frame)
    local attempts = {
        { "ChatFrame_RemoveChannel", ChatFrame_RemoveChannel, function(f) f(frame, channelName) end },
        { "ChatFrameUtil.RemoveChannel", resolve("ChatFrameUtil.RemoveChannel"),
            function(f) f(frame, channelName) end },
        { "frame:RemoveChannel", frame.RemoveChannel, function(f) f(frame, channelName) end },
        { "RemoveChatWindowChannel", RemoveChatWindowChannel, function(f) f(index, channelName) end },
    }
    for _, attempt in ipairs(attempts) do
        local label, fn, call = attempt[1], attempt[2], attempt[3]
        if type(fn) == "function" then
            local ok, err = pcall(call, fn)
            if ok then
                return label
            end
            store("WARN", "%s on ChatFrame%d raised: %s", label, index, show(err))
        end
    end
    return nil
end

local function hideChannel()
    local methods = {}
    for i = 1, NUM_CHAT_WINDOWS or 10 do
        local frame = _G["ChatFrame" .. i]
        if frame then
            local method = tryRemoveFromFrame(i, frame)
            if method then
                methods[method] = true
            end
        end
    end
    local used = {}
    for method in pairs(methods) do
        used[#used + 1] = method
    end
    log("INFO", "hide: removal methods used: %s", #used > 0 and table.concat(used, ", ") or "none worked")

    local frames, checkable = chatFramesShowingChannel()
    if not checkable then
        log("WARN", "hide: GetChatWindowChannels missing, cannot verify; check chat windows visually")
    elseif #frames == 0 then
        log("PASS", "hide: channel '%s' is not listed in any chat window", channelName)
    else
        log("FAIL", "hide: channel still listed in chat window(s): %s", table.concat(frames, ", "))
    end
end

local function checkJoined()
    local id = channelId()
    if id then
        log("PASS", "join: GetChannelName('%s') -> id %d", channelName, id)
        hideChannel()
    else
        log("FAIL", "join: not in channel '%s' after waiting (GetChannelName -> 0)", channelName)
    end
end

local function cmdJoin(name)
    if name and name ~= "" then
        channelName = name
    end
    if channelId() then
        log("INFO", "join: already in '%s' (id %d)", channelName, channelId())
        hideChannel()
        return
    end
    local joinFn, label = JoinTemporaryChannel, "JoinTemporaryChannel"
    if type(joinFn) ~= "function" then
        joinFn, label = JoinChannelByName, "JoinChannelByName"
    end
    if type(joinFn) ~= "function" then
        log("FAIL", "join: neither JoinTemporaryChannel nor JoinChannelByName exists")
        return
    end
    local ok, a, b = pcall(joinFn, channelName)
    if not ok then
        log("FAIL", "join: %s('%s') raised: %s", label, channelName, show(a))
        return
    end
    log("INFO", "join: %s('%s') returned %s; checking in 3s", label, channelName, showAll(a, b))
    C_Timer.After(3, checkJoined)
end

local function cmdLeave()
    if not channelId() then
        log("INFO", "leave: not in '%s'", channelName)
        return
    end
    local ok, err = pcall(LeaveChannelByName, channelName)
    log(ok and "INFO" or "FAIL", "leave: LeaveChannelByName('%s') %s", channelName, ok and "called" or show(err))
end

local function cmdChannel(text)
    local id = channelId()
    if not id then
        log("FAIL", "chan: not in '%s', run /fgp join first", channelName)
        return
    end
    sendAddon("HELLO|" .. (text ~= "" and text or "channel test"), "CHANNEL", tostring(id))
end

local function cmdWhisper(rest)
    local target, text = rest:match("^(%S*)%s*(.-)$")
    if not target or target == "" then
        target = myFullName()
    end
    sendAddon("HELLO|" .. (text ~= "" and text or "whisper test"), "WHISPER", target)
end

local function cmdParty()
    if not IsInGroup() then
        log("WARN", "party: not in a group")
        return
    end
    sendAddon("HELLO|party test", "PARTY")
end

local function cmdPing()
    local id = channelId()
    if not id then
        log("FAIL", "ping: not in '%s', run /fgp join first", channelName)
        return
    end
    pingSeq = pingSeq + 1
    local key = tostring(pingSeq)
    pendingPings[key] = GetTime()
    sendAddon("PING|" .. key, "CHANNEL", tostring(id))
    log("INFO", "ping: sent PING %s; other probe clients answer with a WHISPER PONG", key)
end

local function cmdBig()
    local target = myFullName()
    for _, size in ipairs({ 255, 256 }) do
        local body = "BIG|"
        body = body .. string.rep("x", size - #body)
        sendAddon(body, "WHISPER", target)
    end
end

local function cmdBurst(rest)
    local n = tonumber(rest:match("^(%d+)")) or 30
    local id = channelId()
    local chatType, target = "WHISPER", myFullName()
    if id then
        chatType, target = "CHANNEL", tostring(id)
    end
    C_Timer.After(0.1, function()
        local counts, order = {}, {}
        for i = 1, n do
            local _, name = sendAddon("BURST|" .. i, chatType, target, true)
            name = name or "error"
            if not counts[name] then
                counts[name] = 0
                order[#order + 1] = name
            end
            counts[name] = counts[name] + 1
        end
        local parts = {}
        for _, name in ipairs(order) do
            parts[#parts + 1] = name .. "=" .. counts[name]
        end
        log("INFO", "burst: sent %d via %s from a timer: %s", n, chatType, table.concat(parts, ", "))
    end)
end

local function invite(name, context)
    local fn = resolve("C_PartyInfo.InviteUnit") or InviteUnit
    if type(fn) ~= "function" then
        log("FAIL", "invite: no InviteUnit function")
        return
    end
    watchSystemUntil = GetTime() + SYSTEM_WATCH_SECONDS
    local ok, err = pcall(fn, name)
    if ok then
        log("INFO", "invite: InviteUnit('%s') from %s raised no error; watch for system message,"
            .. " ADDON_ACTION_* events and the invite popup on the target", name, context)
    else
        log("FAIL", "invite: InviteUnit('%s') from %s raised: %s", name, context, show(err))
    end
end

local function cmdInvite(rest, defaultDelay)
    local name, delay = rest:match("^(.-)%s*(%d*)$")
    if name == "" then
        name = nil
    end
    if not name then
        log("WARN", "usage: /fgp invite <Name> | /fgp invitelater <Name> [seconds]")
        return
    end
    delay = tonumber(delay) or defaultDelay
    if delay and delay > 0 then
        log("INFO", "invite: inviting '%s' in %ds from a timer (no hardware event)", name, delay)
        C_Timer.After(delay, function()
            invite(name, "timer")
        end)
    else
        invite(name, "slash command")
    end
end

local function cmdTell(rest)
    local name, text = rest:match("^([^:]+):?%s*(.-)$")
    name = name and name:match("^%s*(.-)%s*$")
    if not name then
        log("WARN", "usage: /fgp tell <Name>[: message]")
        return
    end
    if text == "" then
        text = "Forever Groups probe whisper test"
    end
    local fn, label = resolve("C_ChatInfo.SendChatMessage"), "C_ChatInfo.SendChatMessage"
    if type(fn) ~= "function" then
        fn, label = SendChatMessage, "SendChatMessage"
    end
    if type(fn) ~= "function" then
        log("FAIL", "tell: no SendChatMessage function")
        return
    end
    log("INFO", "tell: whispering '%s' in 2s from a timer via %s", name, label)
    C_Timer.After(2, function()
        watchSystemUntil = GetTime() + SYSTEM_WATCH_SECONDS
        local ok, err = pcall(fn, text, "WHISPER", nil, name)
        log(ok and "INFO" or "FAIL", "tell: %s %s", label, ok and "raised no error; check that the whisper arrived"
            or ("raised: " .. show(err)))
    end)
end

StaticPopupDialogs.DQPROBE_PROPOSAL = {
    text = "Forever Groups probe: group found for %s. Accept?",
    button1 = ACCEPT or "Accept",
    button2 = DECLINE or "Decline",
    timeout = 30,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
    OnShow = function()
        log("PASS", "popup: shown")
    end,
    OnAccept = function(_, data)
        log("PASS", "popup: Accept clicked")
        if type(data) == "table" and data.inviteName then
            invite(data.inviteName, "popup Accept click")
        end
    end,
    OnCancel = function(_, _, reason)
        log("INFO", "popup: cancelled, reason=%s", show(reason))
    end,
}

local function cmdPopup(rest)
    local inviteName = rest:match("^(%S+)")
    log("INFO", "popup: showing in 2s from a timer%s", inviteName and (", Accept invites " .. inviteName) or "")
    C_Timer.After(2, function()
        local ok, dialog = pcall(StaticPopup_Show, "DQPROBE_PROPOSAL", "Probe Dungeon", nil,
            { inviteName = inviteName })
        if not ok then
            log("FAIL", "popup: StaticPopup_Show raised: %s", show(dialog))
            return
        end
        if not dialog then
            log("FAIL", "popup: StaticPopup_Show returned nil")
        end
        local soundOk = pcall(PlaySound, SOUNDKIT and SOUNDKIT.READY_CHECK or 8960)
        local flashOk = pcall(FlashClientIcon)
        log("INFO", "popup: PlaySound %s, FlashClientIcon %s", soundOk and "ok" or "error", flashOk and "ok" or "error")
    end)
end

local function cmdApi()
    local present, missing = 0, {}
    for _, path in ipairs(API_PATHS) do
        local value = resolve(path)
        if value == nil then
            missing[#missing + 1] = path
            store("WARN", "api missing: %s", path)
        else
            present = present + 1
            store("PASS", "api present: %s (%s)", path, type(value))
        end
    end
    log("INFO", "api: %d of %d present", present, #API_PATHS)
    for _, path in ipairs(missing) do
        log("WARN", "api missing: %s", path)
    end
end

local function cmdInfo()
    log("INFO", "GetBuildInfo: %s", showAll(GetBuildInfo()))
    log("INFO", "UnitFullName: %s | GetNormalizedRealmName: %s | myFullName: %s",
        showAll(UnitFullName("player")), show(GetNormalizedRealmName and GetNormalizedRealmName()), myFullName())
    log("INFO", "GetServerTime=%s time()=%s GetTime=%.3f", show(GetServerTime()), show(time()), GetTime())
    local lockdown = resolve("C_ChatInfo.InChatMessagingLockdown")
    log("INFO", "InChatMessagingLockdown: %s | InCombatLockdown: %s | IsInInstance: %s",
        type(lockdown) == "function" and showAll(lockdown()) or "missing",
        show(InCombatLockdown()), showAll(IsInInstance()))
    log("INFO", "IsInGroup: %s | GetNumGroupMembers: %s | leader: %s",
        show(IsInGroup()), show(GetNumGroupMembers()), show(UnitIsGroupLeader("player")))
    local registered = resolve("C_ChatInfo.IsAddonMessagePrefixRegistered")
    log("INFO", "prefix '%s' registered: %s", PREFIX,
        type(registered) == "function" and show(registered(PREFIX)) or "unknown")
    local enum = Enum and Enum.SendAddonMessageResult
    if enum then
        local keys = {}
        for key, value in pairs(enum) do
            keys[#keys + 1] = key .. "=" .. tostring(value)
        end
        table.sort(keys)
        log("INFO", "Enum.SendAddonMessageResult: %s", table.concat(keys, ", "))
    else
        log("WARN", "Enum.SendAddonMessageResult missing")
    end
    if #unknownEvents > 0 then
        log("WARN", "events that could not be registered: %s", table.concat(unknownEvents, ", "))
    else
        log("PASS", "all probe events registered")
    end
    log("INFO", "channel '%s' id: %s", channelName, show(channelId()))
end

local function cmdAll()
    log("INFO", "all: running info, api, join, then chan/whisper/big/ping/popup over ~12s")
    cmdInfo()
    cmdApi()
    cmdJoin()
    C_Timer.After(5, function()
        cmdChannel("")
        cmdWhisper("")
        cmdBig()
    end)
    C_Timer.After(7, cmdPing)
    C_Timer.After(9, function()
        cmdPopup("")
    end)
end

local function cmdLog(rest)
    local n = tonumber(rest:match("^(%d+)")) or 20
    local lines = db.lines
    for i = math.max(1, #lines - n + 1), #lines do
        print(show(lines[i]))
    end
end

local function cmdClear()
    db.lines = {}
    log("INFO", "log cleared")
end

local LFG_FUNCTIONS = {
    "Search", "GetSearchResults", "GetFilteredSearchResults", "GetSearchResultInfo", "GetSearchResultPlayerInfo",
    "GetSearchResultLeaderInfo", "GetSearchResultMemberCounts", "GetSearchResultMemberInfo",
    "GetAvailableCategories", "GetLfgCategoryInfo", "GetAvailableActivities", "GetActivityInfoTable",
    "CreateListing", "RemoveListing", "GetActiveEntryInfo", "HasActiveEntryInfo", "ApplyToGroup",
}
local LFG_MAX_RESULTS = 8

local lfgCategory

local function dumpValue(value)
    if isSecret(value) then
        return "<secret>"
    elseif type(value) == "table" then
        local n, items = 0, {}
        for _ in pairs(value) do
            n = n + 1
        end
        if n == #value and n <= 10 then
            for i = 1, n do
                items[i] = type(value[i]) == "table" and "{...}" or show(value[i])
            end
            return "[" .. table.concat(items, ",") .. "]"
        end
        return "{" .. n .. " keys}"
    elseif type(value) == "string" and #value > 60 then
        return show(value:sub(1, 60)) .. "..."
    end
    return show(value)
end

local function dumpTable(t)
    if type(t) ~= "table" then
        return dumpValue(t)
    end
    local keys = {}
    for key in pairs(t) do
        keys[#keys + 1] = tostring(key)
    end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        local value = t[key]
        if value == nil then
            value = t[tonumber(key)]
        end
        parts[#parts + 1] = key .. "=" .. dumpValue(value)
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function lfgCall(name, ...)
    local fn = resolve("C_LFGList." .. name)
    if type(fn) ~= "function" then
        return false, "missing"
    end
    return pcall(fn, ...)
end

local function lfgInfo()
    local present, missing = {}, {}
    for _, name in ipairs(LFG_FUNCTIONS) do
        if type(resolve("C_LFGList." .. name)) == "function" then
            present[#present + 1] = name
        else
            missing[#missing + 1] = name
        end
    end
    log("INFO", "lfg: present: %s", table.concat(present, ", "))
    log(#missing > 0 and "WARN" or "PASS", "lfg: missing: %s", #missing > 0 and table.concat(missing, ", ") or "none")

    local ok, categories = lfgCall("GetAvailableCategories")
    if not ok or type(categories) ~= "table" then
        log("FAIL", "lfg: GetAvailableCategories -> %s", show(categories))
        return
    end
    for _, id in ipairs(categories) do
        local infoOk, info = lfgCall("GetLfgCategoryInfo", id)
        local name = infoOk and type(info) == "table" and info.name or (infoOk and info) or "?"
        log("INFO", "lfg: category %s = %s %s", show(id), dumpValue(name), infoOk and dumpTable(info) or "")
        if not lfgCategory and type(name) == "string" and not isSecret(name) and name:lower():find("dungeon") then
            lfgCategory = id
        end
    end
    lfgCategory = lfgCategory or categories[1]
    log("INFO", "lfg: using category %s for search", show(lfgCategory))

    local actOk, activities = lfgCall("GetAvailableActivities", lfgCategory)
    if not actOk or type(activities) ~= "table" then
        log("FAIL", "lfg: GetAvailableActivities(%s) -> %s", show(lfgCategory), show(activities))
        return
    end
    log("INFO", "lfg: %d activities in category %s", #activities, show(lfgCategory))
    for _, id in ipairs(activities) do
        local infoOk, info = lfgCall("GetActivityInfoTable", id)
        if infoOk and type(info) == "table" then
            store("INFO", "lfg: activity %s: %s", show(id), dumpTable(info))
            print(string.format("  %s  %s (%s-%s)", show(id), dumpValue(info.fullName or info.shortName),
                dumpValue(info.minLevel), dumpValue(info.maxLevel or info.maxLevelSuggestion)))
        else
            log("WARN", "lfg: GetActivityInfoTable(%s) -> %s", show(id), show(info))
        end
    end
    local entryOk, entry = lfgCall("GetActiveEntryInfo")
    log("INFO", "lfg: GetActiveEntryInfo -> %s", entryOk and dumpTable(entry) or show(entry))
end

local function lfgSearch(context)
    if not lfgCategory then
        lfgInfo()
    end
    local ok, a, b = lfgCall("Search", lfgCategory)
    log(ok and "INFO" or "FAIL", "lfg: Search(%s) from %s -> %s", show(lfgCategory), context,
        ok and showAll(a, b) or show(a))
end

local function lfgDumpResults()
    local ok, count, results = lfgCall("GetFilteredSearchResults")
    if not ok or type(results) ~= "table" then
        ok, count, results = lfgCall("GetSearchResults")
    end
    if not ok or type(results) ~= "table" then
        log("FAIL", "lfg: no search results table (%s)", show(count))
        return
    end
    log("PASS", "lfg: %s results", show(count))
    for i = 1, math.min(#results, LFG_MAX_RESULTS) do
        local id = results[i]
        local _, info = lfgCall("GetSearchResultInfo", id)
        log("RECV", "lfg: result %s info %s", show(id), dumpTable(info))
        local countsOk, counts = lfgCall("GetSearchResultMemberCounts", id)
        if countsOk then
            store("RECV", "lfg: result %s counts %s", show(id), dumpTable(counts))
        end
        local leaderOk, leader = lfgCall("GetSearchResultLeaderInfo", id)
        if leaderOk then
            store("RECV", "lfg: result %s leader %s", show(id), dumpTable(leader))
        end
        local playerOk, player = lfgCall("GetSearchResultPlayerInfo", id, 1)
        if playerOk then
            store("RECV", "lfg: result %s player1 %s", show(id), dumpTable(player))
        end
        local memberOk, a, b, c = lfgCall("GetSearchResultMemberInfo", id, 1)
        if memberOk then
            store("RECV", "lfg: result %s member1 %s", show(id), showAll(a, b, c))
        end
    end
end

-- Search from the player's own key presses: a keyboard frame that lets every
-- key through, searching at most every 10 s while the test runs.
local keyFrame
local pendingKeyAction
local keySearch = { on = false, last = 0, tries = 0, blocked = 0 }

local function onKeyDown(_, key)
    if pendingKeyAction then
        local action = pendingKeyAction
        pendingKeyAction = nil
        action()
        if not keySearch.on then
            keyFrame:EnableKeyboard(false)
        end
        return
    end
    if not keySearch.on or GetTime() - keySearch.last < 10 then
        return
    end
    keySearch.last = GetTime()
    keySearch.tries = keySearch.tries + 1
    keySearch.pending = true
    local ok, err = lfgCall("Search", lfgCategory or 2)
    log(ok and "INFO" or "FAIL", "keysearch: Search after key %s (try %d) -> %s", show(key), keySearch.tries,
        ok and "called" or show(err))
    C_Timer.After(1, function()
        if keySearch.pending then
            keySearch.pending = false
            log("PASS", "keysearch: no ADDON_ACTION_BLOCKED within 1 s after try %d", keySearch.tries)
        end
    end)
end

local function cmdKeySearch(rest)
    if not keyFrame then
        keyFrame = CreateFrame("Frame", "ForeverGroupsProbeKeyFrame", UIParent)
        keyFrame:SetScript("OnKeyDown", onKeyDown)
    end
    keySearch.on = rest:match("^%s*off") == nil
    local ok, err = pcall(function()
        keyFrame:EnableKeyboard(keySearch.on)
        keyFrame:SetPropagateKeyboardInput(true)
    end)
    log(ok and "INFO" or "FAIL", "keysearch: %s %s", keySearch.on and "on" or "off", ok and "" or show(err))
    if keySearch.on then
        log("INFO", "keysearch: walk around or press keys for 30 s, then /fgp lfg keysearch off")
    end
end

-- Search from mouse actions in the 3D world: which of them WoW counts as the
-- player's own action (a hardware event) for a Group Finder search. Tries at
-- most every 5 s, never in combat.
local clickSearch = { on = false, hooked = false, last = 0, results = {} }

local function clickResult(source, field)
    local result = clickSearch.results[source] or { ok = 0, blocked = 0 }
    result[field] = result[field] + 1
    clickSearch.results[source] = result
end

local function clickTry(source)
    if not clickSearch.on or GetTime() - clickSearch.last < 5 or InCombatLockdown() then
        return
    end
    -- One action can fire several of these; a source with a verdict leaves
    -- the try to one without, so each is tested on its own.
    local known = clickSearch.results[source]
    if known and known.ok + known.blocked > 0 then
        return
    end
    clickSearch.last = GetTime()
    clickSearch.pending = source
    local ok, err = lfgCall("Search", lfgCategory or 2)
    log(ok and "INFO" or "FAIL", "clicksearch: Search from %s -> %s", source, ok and "called" or show(err))
    C_Timer.After(1, function()
        if clickSearch.pending == source then
            clickSearch.pending = nil
            clickResult(source, "ok")
            log("PASS", "clicksearch: %s allowed (no ADDON_ACTION_BLOCKED within 1 s)", source)
        end
    end)
end

local function hookClicks()
    if clickSearch.hooked then
        return
    end
    clickSearch.hooked = true
    if WorldFrame and WorldFrame.HookScript then
        WorldFrame:HookScript("OnMouseDown", function(_, button)
            clickTry("WorldFrame OnMouseDown " .. tostring(button))
        end)
    end
    local mouse = CreateFrame("Frame")
    local registered = pcall(mouse.RegisterEvent, mouse, "GLOBAL_MOUSE_DOWN")
    mouse:SetScript("OnEvent", function(_, _, button)
        clickTry("GLOBAL_MOUSE_DOWN " .. tostring(button))
    end)
    log("INFO", "clicksearch: GLOBAL_MOUSE_DOWN %s", registered and "registered" or "missing")
    local window = _G.ForeverGroupsFrame
    if window and window.HookScript then
        window:HookScript("OnEnter", function()
            clickTry("Forever Groups window OnEnter (hover)")
        end)
        if not window:IsMouseEnabled() then
            window:EnableMouse(true)
        end
    end
    for _, name in ipairs({ "CameraOrSelectOrMoveStart", "TurnOrActionStart", "CameraZoomIn", "CameraZoomOut",
        "UseAction", "ActionButtonDown", "InteractUnit" }) do
        if type(_G[name]) == "function" then
            hooksecurefunc(name, function()
                clickTry(name)
            end)
        else
            log("INFO", "clicksearch: %s missing", name)
        end
    end
end

local function cmdClickSearch(rest)
    clickSearch.on = rest:match("^%s*off") == nil
    if clickSearch.on then
        hookClicks()
        log("INFO", "clicksearch: on. About 5 s apart, a few times each: left-click and right-click the world, "
            .. "turn the camera with a mouse button held, scroll to zoom, click a spell on your action bar, "
            .. "right-click an NPC, click on a WoW window (bags, map), move the mouse onto the open Forever Groups "
            .. "window without clicking. Then /fgp clicksearch off")
        return
    end
    local parts = {}
    for source, result in pairs(clickSearch.results) do
        parts[#parts + 1] = source .. " ok=" .. result.ok .. " blocked=" .. result.blocked
    end
    log("INFO", "clicksearch: off. %s", #parts > 0 and table.concat(parts, "; ") or "no tries")
end

-- Searching filtered on one dungeon (activity). Two call shapes are tried,
-- because retail and classic pass the activity list in different places.
local filterTest

local function cmdSearchFor(rest)
    local variant, activity = rest:match("^%s*(%a)%s+(%d+)")
    activity = tonumber(activity)
    if not variant or not activity then
        log("WARN", "usage: /fgp lfg searchfor A|B <activityID>   (Deadmines = 799, Wailing Caverns = 796)")
        return
    end
    variant = variant:upper()
    local category = lfgCategory or 2
    local ok, err
    if variant == "A" then
        ok, err = lfgCall("Search", category, { activity })
    else
        ok, err = lfgCall("Search", category, nil, nil, nil, nil, nil, { activity })
    end
    filterTest = { variant = variant, activity = activity }
    log(ok and "INFO" or "FAIL", "searchfor %s: Search with activity %d -> %s", variant, activity,
        ok and "called" or show(err))
end

local function checkFilterTest()
    if not filterTest then
        return
    end
    local _, count, results = pcall(C_LFGList.GetSearchResults)
    if type(results) ~= "table" then
        return
    end
    local matching = 0
    for _, id in ipairs(results) do
        local _, info = lfgCall("GetSearchResultInfo", id)
        for _, activity in ipairs(type(info) == "table" and info.activityIDs or {}) do
            if activity == filterTest.activity then
                matching = matching + 1
                break
            end
        end
    end
    log(matching == #results and "PASS" or "WARN",
        "searchfor %s: %s results, %d of them for activity %d", filterTest.variant, show(count), matching,
        filterTest.activity)
    filterTest = nil
end

-- Applying to listed groups and listing yourself. Both have real effects, so
-- every test undoes itself: an application is cancelled after 5 s, a listing
-- removed after 10 s. "key" variants run on the next key press instead of the
-- command itself, to see whether a key press counts as player input.

local function lastResults()
    local _, _, results = pcall(C_LFGList.GetSearchResults)
    return type(results) == "table" and results or {}
end

local function cmdGroups()
    local shown = 0
    for _, id in ipairs(lastResults()) do
        local _, info = lfgCall("GetSearchResultInfo", id)
        local _, counts = lfgCall("GetSearchResultMemberCounts", id)
        if type(info) == "table" and (info.numMembers or 0) > 1 and type(counts) == "table" then
            shown = shown + 1
            log("INFO", "group %s: leader %s, %s members, activity %s, still needs T%s H%s D%s",
                show(id), show(info.leaderName), show(info.numMembers), dumpValue(info.activityIDs),
                show(counts.TANK_REMAINING), show(counts.HEALER_REMAINING), show(counts.DAMAGER_REMAINING))
            if shown >= 8 then
                break
            end
        end
    end
    if shown == 0 then
        log("WARN", "groups: no groups in the last search; search first (/fgp lfg searchfor B <activity>)")
    end
end

local function apply(id, context)
    local variants = {
        { "id, tank, healer, dps", function() return lfgCall("ApplyToGroup", id, false, false, true) end },
        { "id, comment, tank, healer, dps", function() return lfgCall("ApplyToGroup", id, "", false, false, true) end },
    }
    for _, variant in ipairs(variants) do
        local ok, err = variant[2]()
        log(ok and "INFO" or "WARN", "apply %s (%s) from %s -> %s", show(id), variant[1], context,
            ok and "called" or show(err))
        if ok then
            C_Timer.After(3, function()
                local _, a, b, c, d, e = lfgCall("GetApplicationInfo", id)
                log("INFO", "apply %s: application info after 3 s: %s", show(id), showAll(a, b, c, d, e))
                log("INFO", "apply %s: press any key to withdraw it again", show(id))
                pendingKeyAction = function()
                    local cancelOk, cancelErr = lfgCall("CancelApplication", id)
                    log(cancelOk and "INFO" or "FAIL", "apply %s: CancelApplication on a key press -> %s", show(id),
                        cancelOk and "called" or show(cancelErr))
                end
                keyFrame:EnableKeyboard(true)
            end)
            return
        end
    end
end

local function list(activity, context)
    local variants = {
        { "{activity}, 0, 0, false, false", function()
            return lfgCall("CreateListing", { activity }, 0, 0, false, false)
        end },
        { "{activity}", function() return lfgCall("CreateListing", { activity }) end },
        { "activity", function() return lfgCall("CreateListing", activity) end },
    }
    for _, variant in ipairs(variants) do
        local ok, err = variant[2]()
        log(ok and "INFO" or "WARN", "list %s (%s) from %s -> %s", show(activity), variant[1], context,
            ok and "called" or show(err))
        if ok then
            C_Timer.After(3, function()
                local _, entry = lfgCall("GetActiveEntryInfo")
                log(entry and "PASS" or "WARN", "list: GetActiveEntryInfo -> %s", dumpTable(entry))
            end)
            C_Timer.After(5, function()
                log("INFO", "list: press any key to remove the listing again")
                pendingKeyAction = function()
                    local removeOk, removeErr = lfgCall("RemoveListing")
                    log(removeOk and "INFO" or "FAIL", "list: RemoveListing on a key press -> %s",
                        removeOk and "called" or show(removeErr))
                end
                keyFrame:EnableKeyboard(true)
            end)
            return
        end
    end
end

local function onApplicationStatus(event, id, newStatus, oldStatus, groupName)
    log("EVENT", "%s result %s: %s -> %s (%s)", event, show(id), show(oldStatus), show(newStatus), show(groupName))
end

local function ensureKeyFrame()
    if keyFrame == nil then
        cmdKeySearch("")
        cmdKeySearch("off")
    end
end

local function cmdApplyOrList(word, rest)
    ensureKeyFrame()
    if word == "cancel" or word == "unlist" then
        local id = tonumber(rest:match("(%d+)"))
        local ok, err
        if word == "cancel" then
            ok, err = lfgCall("CancelApplication", id)
        else
            ok, err = lfgCall("RemoveListing")
        end
        log(ok and "INFO" or "FAIL", "%s %s from slash command -> %s", word, show(id), ok and "called" or show(err))
        return
    end
    local id = tonumber(rest:match("(%d+)"))
    if not id then
        log("WARN", "usage: /fgp lfg %s <%s>", word, word:find("list") and "activityID" or "resultID")
        return
    end
    local action = word:find("list") and list or apply
    if word:find("key$") then
        pendingKeyAction = function()
            action(id, "key press")
        end
        keyFrame:EnableKeyboard(true)
        log("INFO", "%s: press any key to run it", word)
    else
        action(id, "slash command")
    end
end

local function cmdLfg(rest)
    local word = rest:match("^(%S*)"):lower()
    if word == "info" then
        lfgInfo()
    elseif word == "search" then
        lfgSearch("slash command")
    elseif word == "searchlater" then
        log("INFO", "lfg: searching in 3s from a timer (no hardware event)")
        C_Timer.After(3, function()
            lfgSearch("timer")
        end)
    elseif word == "results" then
        lfgDumpResults()
    elseif word == "keysearch" then
        cmdKeySearch(rest:gsub("^%S+", ""))
    elseif word == "searchfor" then
        cmdSearchFor((rest:gsub("^%S+", "")))
    elseif word == "groups" then
        cmdGroups()
    elseif word == "apply" or word == "applykey" or word == "list" or word == "listkey" or word == "cancel"
        or word == "unlist" then
        cmdApplyOrList(word, (rest:gsub("^%S+", "")))
    else
        log("WARN", "usage: /fgp lfg info | search | searchlater | results | keysearch [off]"
            .. " | searchfor A|B <activityID> | groups | apply[key] <groupID> | cancel <groupID>"
            .. " | list[key] <activityID> | unlist")
    end
end

local function probeCall(path, ...)
    local fn = resolve(path)
    if type(fn) ~= "function" then
        return "missing"
    end
    local result = { pcall(fn, ...) }
    if not result[1] then
        return "error: " .. show(result[2])
    end
    local parts = {}
    for i = 2, table.maxn(result) do
        parts[#parts + 1] = dumpTable(result[i])
    end
    return #parts > 0 and table.concat(parts, " | ") or "(no returns)"
end

-- What Forever tells about the quests in the log: group size, elite/group
-- tags, objectives; and whether the Group Finder has categories besides
-- dungeons (for questing groups).
local function cmdQuests()
    local count = resolve("C_QuestLog.GetNumQuestLogEntries")
    if type(count) ~= "function" then
        log("FAIL", "quests: C_QuestLog.GetNumQuestLogEntries missing")
        return
    end
    log("INFO", "quests: GetNumQuestLogEntries -> %s", probeCall("C_QuestLog.GetNumQuestLogEntries"))
    log("INFO", "quests: Enum.QuestTag = %s", dumpTable(resolve("Enum.QuestTag")))
    local ok, entries = pcall(count)
    local quests = 0
    for index = 1, ok and tonumber(entries) or 0 do
        local infoOk, info = pcall(C_QuestLog.GetInfo, index)
        if infoOk and type(info) == "table" then
            store("INFO", "quests: GetInfo(%d) = %s", index, dumpTable(info))
            if info.isHeader then
                print(string.format("  [%s]", show(info.title)))
            elseif info.questID then
                quests = quests + 1
                local id = info.questID
                print(string.format("  %s (id %s, level %s, suggestedGroup %s)", show(info.title), show(id),
                    show(info.level), show(info.suggestedGroup)))
                store("INFO", "quests: %s C_QuestLog.GetQuestTagInfo -> %s", show(id),
                    probeCall("C_QuestLog.GetQuestTagInfo", id))
                store("INFO", "quests: %s GetQuestTagInfo -> %s", show(id), probeCall("GetQuestTagInfo", id))
                store("INFO", "quests: %s C_QuestLog.GetQuestObjectives -> %s", show(id),
                    probeCall("C_QuestLog.GetQuestObjectives", id))
                store("INFO", "quests: %s C_QuestLog.IsPushableQuest -> %s", show(id),
                    probeCall("C_QuestLog.IsPushableQuest", id))
                store("INFO", "quests: %s C_QuestLog.GetQuestDifficultyLevel -> %s", show(id),
                    probeCall("C_QuestLog.GetQuestDifficultyLevel", id))
                store("INFO", "quests: %s C_QuestLog.IsComplete -> %s", show(id),
                    probeCall("C_QuestLog.IsComplete", id))
            end
        else
            log("WARN", "quests: GetInfo(%d) -> %s", index, show(info))
        end
    end
    log("INFO", "quests: %d quests dumped (details in the saved log)", quests)

    local catOk, categories = lfgCall("GetAvailableCategories")
    if not catOk or type(categories) ~= "table" then
        log("FAIL", "quests: GetAvailableCategories -> %s", show(categories))
        return
    end
    for _, id in ipairs(categories) do
        local infoOk, info = lfgCall("GetLfgCategoryInfo", id)
        local actOk, activities = lfgCall("GetAvailableActivities", id)
        local names = {}
        for i, activity in ipairs(actOk and type(activities) == "table" and activities or {}) do
            local aOk, aInfo = lfgCall("GetActivityInfoTable", activity)
            if i <= 12 then
                names[#names + 1] = show(activity) .. "=" .. dumpValue(aOk and type(aInfo) == "table"
                    and (aInfo.fullName or aInfo.shortName) or aInfo)
            end
        end
        log("INFO", "quests: lfg category %s %s: %d activities: %s", show(id),
            infoOk and dumpTable(info) or show(info), actOk and type(activities) == "table" and #activities or 0,
            table.concat(names, ", "))
    end
end

-- How Forever tells a character's specialization: retail specs, classic
-- talent trees, or neither.
local function cmdSpec()
    local _, classToken = UnitClass("player")
    log("INFO", "spec: class %s, level %s", show(classToken), show(UnitLevel("player")))
    for _, path in ipairs({ "GetSpecialization", "GetNumSpecializations", "GetSpecializationRole",
        "C_SpecializationInfo.GetSpecialization", "C_SpecializationInfo.GetSpecializationInfo",
        "GetActiveSpecGroup", "GetNumTalentTabs", "GetTalentTabInfo", "GetPrimaryTalentTree",
        "C_ClassTalents.GetActiveConfigID", "UnitCharacterPoints", "GetUnspentTalentPoints",
        "GetInspectSpecialization", "C_LFGList.GetPlayerInfo" }) do
        log("INFO", "spec: %s %s", path, type(resolve(path)) == "function" and "present" or "missing")
    end
    log("INFO", "spec: GetSpecialization() -> %s", probeCall("GetSpecialization"))
    log("INFO", "spec: GetNumSpecializations() -> %s", probeCall("GetNumSpecializations"))
    for i = 1, 4 do
        log("INFO", "spec: GetSpecializationInfo(%d) -> %s", i, probeCall("GetSpecializationInfo", i))
        log("INFO", "spec: GetSpecializationRole(%d) -> %s", i, probeCall("GetSpecializationRole", i))
    end
    log("INFO", "spec: GetActiveSpecGroup() -> %s", probeCall("GetActiveSpecGroup"))
    log("INFO", "spec: GetNumTalentTabs() -> %s", probeCall("GetNumTalentTabs"))
    for i = 1, 4 do
        log("INFO", "spec: GetTalentTabInfo(%d) -> %s", i, probeCall("GetTalentTabInfo", i))
    end
    log("INFO", "spec: GetPrimaryTalentTree() -> %s", probeCall("GetPrimaryTalentTree"))
    log("INFO", "spec: GetNumTalentGroups() -> %s", probeCall("GetNumTalentGroups"))
    log("INFO", "spec: GetActiveTalentGroup() -> %s", probeCall("GetActiveTalentGroup"))
    for group = 1, 2 do
        for i = 1, 3 do
            log("INFO", "spec: GetTalentTabInfo(%d, false, false, %d) -> %s", i, group,
                probeCall("GetTalentTabInfo", i, false, false, group))
        end
    end
    log("INFO", "spec: UnitCharacterPoints(player) -> %s", probeCall("UnitCharacterPoints", "player"))
    log("INFO", "spec: GetUnspentTalentPoints() -> %s", probeCall("GetUnspentTalentPoints"))
    log("INFO", "spec: UnitGroupRolesAssigned(player) -> %s", probeCall("UnitGroupRolesAssigned", "player"))
end

-- The talent tree: which nodes have points and where they sit, to see
-- whether the tree is split into sections (like the classic three trees).
local function cmdTalents()
    log("INFO", "talents: C_SpecializationInfo.GetSpecialization() -> %s",
        probeCall("C_SpecializationInfo.GetSpecialization"))
    log("INFO", "talents: C_SpecializationInfo.GetSpecializationInfo(1) -> %s",
        probeCall("C_SpecializationInfo.GetSpecializationInfo", 1))
    local getConfig = resolve("C_ClassTalents.GetActiveConfigID")
    local ok, configID = pcall(getConfig or error)
    log("INFO", "talents: active config -> %s", show(configID))
    if not ok or not configID then
        return
    end
    local infoOk, config = pcall(C_Traits.GetConfigInfo, configID)
    log("INFO", "talents: GetConfigInfo -> %s", infoOk and dumpTable(config) or show(config))
    local trees = infoOk and type(config) == "table" and config.treeIDs or {}
    for _, treeID in ipairs(trees) do
        log("INFO", "talents: tree %s info -> %s", show(treeID), probeCall("C_Traits.GetTreeInfo", configID, treeID))
        local nodesOk, nodes = pcall(C_Traits.GetTreeNodes, treeID)
        nodes = nodesOk and type(nodes) == "table" and nodes or {}
        local purchased, subTrees, minX, maxX = 0, {}, math.huge, -math.huge
        for _, nodeID in ipairs(nodes) do
            local nOk, node = pcall(C_Traits.GetNodeInfo, configID, nodeID)
            if nOk and type(node) == "table" and node.ID and node.ID ~= 0 then
                minX, maxX = math.min(minX, node.posX or 0), math.max(maxX, node.posX or 0)
                if node.subTreeID then
                    subTrees[node.subTreeID] = true
                end
                local spell = ""
                local entryID = node.activeEntry and node.activeEntry.entryID or (node.entryIDs or {})[1]
                if entryID then
                    local eOk, entry = pcall(C_Traits.GetEntryInfo, configID, entryID)
                    local dOk, def = pcall(C_Traits.GetDefinitionInfo, eOk and entry and entry.definitionID or 0)
                    local spellID = dOk and type(def) == "table" and def.spellID
                    if spellID and C_Spell and C_Spell.GetSpellName then
                        spell = show(C_Spell.GetSpellName(spellID))
                    end
                end
                local ranks = node.ranksPurchased or node.currentRank or 0
                if ranks > 0 then
                    purchased = purchased + ranks
                end
                store("INFO", "talents: node %s x=%s y=%s ranks=%s/%s sub=%s type=%s %s", show(nodeID),
                    show(node.posX), show(node.posY), show(ranks), show(node.maxRanks), show(node.subTreeID),
                    show(node.type), spell)
            end
        end
        local subs = {}
        for id in pairs(subTrees) do
            subs[#subs + 1] = show(id) .. "=" .. probeCall("C_Traits.GetSubTreeInfo", configID, id)
        end
        log("INFO", "talents: tree %s: %d nodes, %d points spent, x from %s to %s, sub trees: %s", show(treeID),
            #nodes, purchased, show(minX), show(maxX), #subs > 0 and table.concat(subs, "; ") or "none")
    end
end

-- Whether another player's talents can be read: inspect a unit, wait for
-- INSPECT_READY, then read the inspect talent config (points per tree, by
-- the same x columns as the player's own tree).
local inspecting

local function readInspect(unit)
    log("INFO", "inspect: GetInspectSpecialization(%s) -> %s", unit, probeCall("GetInspectSpecialization", unit))
    log("INFO", "inspect: C_Traits.HasValidInspectData() -> %s", probeCall("C_Traits.HasValidInspectData"))
    local consts = resolve("Constants.TraitConsts")
    local configID = type(consts) == "table" and consts.INSPECT_TRAIT_CONFIG_ID or nil
    log("INFO", "inspect: Constants.TraitConsts.INSPECT_TRAIT_CONFIG_ID -> %s", show(configID))
    local export = resolve("C_Traits.GenerateInspectImportString")
    if type(export) == "function" then
        local ok, text = pcall(export, unit)
        log("INFO", "inspect: GenerateInspectImportString -> %s", ok and (type(text) == "string"
            and (#text .. " chars: " .. text:sub(1, 60)) or show(text)) or ("error: " .. show(text)))
    else
        log("INFO", "inspect: GenerateInspectImportString missing")
    end
    if not configID then
        return
    end
    local infoOk, config = pcall(C_Traits.GetConfigInfo, configID)
    log("INFO", "inspect: GetConfigInfo(%s) -> %s", show(configID), infoOk and dumpTable(config) or show(config))
    local trees = infoOk and type(config) == "table" and config.treeIDs or {}
    for _, treeID in ipairs(trees) do
        local nodesOk, nodes = pcall(C_Traits.GetTreeNodes, treeID)
        nodes = nodesOk and type(nodes) == "table" and nodes or {}
        local points, readable = { 0, 0, 0 }, 0
        for _, nodeID in ipairs(nodes) do
            local nOk, node = pcall(C_Traits.GetNodeInfo, configID, nodeID)
            if nOk and type(node) == "table" and node.ID and node.ID ~= 0 then
                readable = readable + 1
                local ranks = node.ranksPurchased or 0
                if not isSecret(ranks) and type(ranks) == "number" and ranks > 0 and type(node.posX) == "number" then
                    local tree = node.posX < 4000 and 1 or node.posX < 8000 and 2 or 3
                    points[tree] = points[tree] + ranks
                end
            end
        end
        log(points[1] + points[2] + points[3] > 0 and "PASS" or "WARN",
            "inspect: tree %s: %d nodes, %d readable, points per tree %d / %d / %d", show(treeID), #nodes,
            readable, points[1], points[2], points[3])
    end
end

local function onInspectReady(_, guid)
    if not inspecting then
        return
    end
    log("EVENT", "INSPECT_READY %s (asked %s)", show(guid), show(inspecting.guid))
    if guid == inspecting.guid then
        local unit = inspecting.unit
        inspecting = nil
        readInspect(unit)
        local clear = resolve("ClearInspectPlayer")
        if type(clear) == "function" then
            pcall(clear)
        end
    end
end

local function cmdInspect(rest)
    local unit = rest ~= "" and rest or (UnitExists("target") and "target" or "party1")
    if not UnitExists(unit) then
        log("FAIL", "inspect: no %s; target a party member or use /fgp inspect party1", unit)
        return
    end
    log("INFO", "inspect: %s = %s, player=%s, CanInspect -> %s, in inspect range -> %s", unit,
        show(UnitName(unit)), show(UnitIsPlayer(unit)), probeCall("CanInspect", unit),
        probeCall("CheckInteractDistance", unit, 1))
    local notify = resolve("NotifyInspect")
    if type(notify) ~= "function" then
        log("FAIL", "inspect: NotifyInspect missing")
        return
    end
    inspecting = { unit = unit, guid = UnitGUID(unit) }
    local ok, err = pcall(notify, unit)
    log(ok and "INFO" or "FAIL", "inspect: NotifyInspect(%s) -> %s", unit, ok and "sent" or show(err))
    C_Timer.After(5, function()
        if inspecting and inspecting.guid == UnitGUID(unit) then
            inspecting = nil
            log("FAIL", "inspect: no INSPECT_READY within 5 s (too far away?)")
        end
    end)
end

-- The /fgp lfgapi checks live in their own block: the file is near Lua's
-- limit of 200 locals in one chunk.
local cmdLfgApi, checkApiTest, checkTwice, checkGap
do
    -- /fgp lfgapi: every Group Finder function and Blizzard's own finder code,
    -- then test searches for one dungeon (Ruins of Lordaeron), plain or with the
    -- server-side filter; each search is its own command (a slash command counts
    -- as player input).
    local RUINS_OF_LORDAERON = 1982
    local LFG_TABLES = { "C_LFGList", "C_LFGInfo", "C_LFGBrowse", "C_LFGListBrowse", "C_LFGFinder" }
    local FINDER_PREFIXES = { "LFGListSearchPanel", "LFGListFrame", "LFGListUtil", "LFGBrowse", "LFGList_",
        "LFG_LIST_SEARCH", "LFG_LIST_TOO_MANY", "LFG_LIST_MAX", "MAX_LFG_LIST" }
    local apiTest

    local function functionNames(t)
        local names = {}
        for name, value in pairs(t) do
            if type(value) == "function" then
                names[#names + 1] = tostring(name)
            end
        end
        table.sort(names)
        return names
    end

    local function finderGlobals()
        local names = {}
        for name, value in pairs(_G) do
            if type(name) == "string" then
                for _, prefix in ipairs(FINDER_PREFIXES) do
                    if name:sub(1, #prefix) == prefix then
                        local shown = type(value) == "function" and (name .. "()")
                            or ((type(value) == "string" or type(value) == "number")
                                and (name .. "=" .. tostring(value)))
                            or (name .. ":" .. type(value))
                        names[#names + 1] = shown
                        break
                    end
                end
            end
        end
        table.sort(names)
        return names
    end

    local function apiSearch(mode)
        local languages
        local _, offered = lfgCall("GetAvailableLanguageSearchFilter")
        if type(offered) == "table" then
            languages = {}
            for _, code in ipairs(offered) do
                languages[code] = true
            end
        end
        local advanced
        if mode == "heal" or mode == "dps" or mode == "tank" or mode == "healdps" then
            local _, base = lfgCall("GetAdvancedFilter")
            advanced = {}
            for key, value in pairs(type(base) == "table" and base or {}) do
                advanced[key] = value
            end
            local _, info = lfgCall("GetActivityInfoTable", RUINS_OF_LORDAERON)
            local group = type(info) == "table" and info.groupFinderActivityGroupID
            advanced.activities = group and { group } or {}
            advanced.needsHealer = mode == "heal" or mode == "healdps"
            advanced.needsDamage = mode == "dps" or mode == "healdps"
            advanced.needsTank = mode == "tank"
        end
        apiTest = { mode = mode, at = GetTime() }
        local ok, err = lfgCall("Search", 2, 0, 0, languages, false, advanced, { RUINS_OF_LORDAERON })
        log(ok and "INFO" or "FAIL", "lfgapi %s: Search for Ruins of Lordaeron%s -> %s", mode,
            advanced and (" with " .. dumpValue(advanced)) or "", ok and "called" or show(err))
    end

    -- The quests in the log: their Group Finder activity, whether WoW calls them
    -- elite, and the first one with an activity to search for.
    local function questActivities()
        local first
        local countOk, count = pcall(C_QuestLog.GetNumQuestLogEntries)
        count = countOk and tonumber(count) or 0
        for index = 1, count do
            local ok, info = pcall(C_QuestLog.GetInfo, index)
            if ok and type(info) == "table" and not info.isHeader and info.questID then
                local _, activity = lfgCall("GetActivityIDForQuestID", info.questID)
                local eliteOk, elite = pcall(resolve("C_QuestLog.IsEliteQuest") or error, info.questID)
                store("INFO", "lfgapi quest %s \"%s\": activity %s, suggestedGroup %s, IsEliteQuest %s",
                    show(info.questID), show(info.title), show(activity), show(info.suggestedGroup),
                    eliteOk and show(elite) or "missing")
                if activity and not first then
                    first = { questID = info.questID, title = info.title, activity = activity }
                end
            end
        end
        return first
    end

    local function apiQuestSearch(rest)
        local quest = questActivities()
        local questID = tonumber(rest)
        if questID then
            local _, activity = lfgCall("GetActivityIDForQuestID", questID)
            quest = { questID = questID, title = "#" .. questID, activity = activity }
        end
        if not quest or not quest.activity then
            log("FAIL", "lfgapi quest: no quest in the log has a Group Finder activity")
            return
        end
        local _, info = lfgCall("GetActivityInfoTable", quest.activity)
        local category = type(info) == "table" and info.categoryID or 116
        local set, setErr = lfgCall("SetSearchToQuestID", quest.questID)
        apiTest = { mode = "quest", at = GetTime(), questID = quest.questID }
        local ok, err = lfgCall("Search", category)
        log(ok and "INFO" or "FAIL", "lfgapi quest: SetSearchToQuestID(%s \"%s\") -> %s; Search(category %s) -> %s",
            show(quest.questID), show(quest.title), set and "ok" or show(setErr), show(category),
            ok and "called" or show(err))
    end

    -- Two searches from one command, straight after each other: Ruins of
    -- Lordaeron, then Wailing Caverns. Does WoW run both (two result events,
    -- each with its own dungeon), or does the second replace or fail the first?
    local twiceTest

    local function apiTwice()
        twiceTest = { at = GetTime(), events = 0 }
        local first = { lfgCall("Search", 2, 0, 0, nil, false, nil, { RUINS_OF_LORDAERON }) }
        local second = { lfgCall("Search", 2, 0, 0, nil, false, nil, { 796 }) }
        log("INFO", "lfgapi twice: first Search -> %s %s, second Search -> %s %s", show(first[1]), show(first[2]),
            show(second[1]), show(second[2]))
    end

    function checkTwice(event)
        if not twiceTest or GetTime() - twiceTest.at > 10 then
            return
        end
        twiceTest.events = twiceTest.events + 1
        local _, _, results = pcall(C_LFGList.GetSearchResults)
        local ruins, caverns = 0, 0
        for _, id in ipairs(type(results) == "table" and results or {}) do
            local _, info = lfgCall("GetSearchResultInfo", id)
            for _, activity in ipairs(type(info) == "table" and info.activityIDs or {}) do
                ruins = ruins + (activity == RUINS_OF_LORDAERON and 1 or 0)
                caverns = caverns + (activity == 796 and 1 or 0)
            end
        end
        log("RECV", "lfgapi twice: %s #%d after %.2f s: %d results, %d Ruins, %d Wailing Caverns", event,
            twiceTest.events, GetTime() - twiceTest.at, type(results) == "table" and #results or 0, ruins, caverns)
    end

    -- How soon a search may follow the previous one: for 30 s every key press
    -- (at most every 0.2 s) searches, Ruins of Lordaeron and Wailing Caverns in
    -- turn; each result or failure is matched to its search and gap.
    local GAP_TIME, GAP_MIN = 30, 0.2
    local gapTest, gapFrame
    local gapMin = GAP_MIN

    local function gapSearch(source)
        local now = GetTime()
        local gap = now - gapTest.last
        gapTest.last = now
        gapTest.count = gapTest.count + 1
        local activity = gapTest.count % 2 == 1 and RUINS_OF_LORDAERON or 796
        gapTest.searches[#gapTest.searches + 1] = { number = gapTest.count, at = now, gap = gap, activity = activity }
        local ok, err = lfgCall("Search", 2, 0, 0, nil, false, nil, { activity })
        log("INFO", "lfgapi gap: search %d (%s, %s) %.2f s after the previous -> %s", gapTest.count,
            activity == 796 and "Wailing Caverns" or "Ruins", source, gap, ok and "called" or show(err))
    end

    local function apiGap(arg)
        gapMin = math.max(GAP_MIN, tonumber(arg) or GAP_MIN)
        if not gapFrame then
            gapFrame = CreateFrame("Frame", "ForeverGroupsProbeGapFrame", UIParent)
            gapFrame:SetScript("OnKeyDown", function()
                if gapTest and GetTime() < gapTest.ends and GetTime() - gapTest.last >= gapMin then
                    gapSearch("key")
                end
            end)
            pcall(gapFrame.SetPropagateKeyboardInput, gapFrame, true)
        end
        gapTest = { ends = GetTime() + GAP_TIME, last = -math.huge, count = 0, searches = {} }
        pcall(gapFrame.EnableKeyboard, gapFrame, true)
        gapSearch("command")
        log("INFO", "lfgapi gap: for %d s a key press searches when %.1f s have passed; keep pressing keys",
            GAP_TIME, gapMin)
        C_Timer.After(GAP_TIME + 3, function()
            pcall(gapFrame.EnableKeyboard, gapFrame, false)
            log("INFO", "lfgapi gap: done after %d searches", gapTest and gapTest.count or 0)
            gapTest = nil
        end)
    end

    function checkGap(event)
        if not gapTest then
            return
        end
        local last = gapTest.searches[#gapTest.searches]
        if not last then
            return
        end
        if event == "LFG_LIST_SEARCH_FAILED" then
            log("RECV", "lfgapi gap: FAILED after search %d (%.2f s after the previous)", last.number, last.gap)
            return
        end
        local _, _, results = pcall(C_LFGList.GetSearchResults)
        local ruins, caverns = 0, 0
        for _, id in ipairs(type(results) == "table" and results or {}) do
            local _, info = lfgCall("GetSearchResultInfo", id)
            for _, activity in ipairs(type(info) == "table" and info.activityIDs or {}) do
                ruins = ruins + (activity == RUINS_OF_LORDAERON and 1 or 0)
                caverns = caverns + (activity == 796 and 1 or 0)
            end
        end
        local fits = (last.activity == 796 and caverns > ruins) or (last.activity ~= 796 and ruins > caverns)
        log("RECV", "lfgapi gap: results %.2f s after search %d (%.2f s after the previous): %d Ruins, %d Caverns"
            .. " -> %s",
            GetTime() - last.at, last.number, last.gap, ruins, caverns, fits and "this search" or "an older search")
    end

    -- Who is in the listed groups of the last search, member by member.
    local function apiMembers()
        local shown = 0
        local _, _, results = pcall(C_LFGList.GetSearchResults)
        for _, id in ipairs(type(results) == "table" and results or {}) do
            local _, info = lfgCall("GetSearchResultInfo", id)
            if type(info) == "table" and (info.numMembers or 0) > 1 and shown < 4 then
                shown = shown + 1
                for member = 1, info.numMembers do
                    local _, player = lfgCall("GetSearchResultPlayerInfo", id, member)
                    store("INFO", "lfgapi members: group %s member %d -> %s", show(id), member, dumpValue(player))
                end
                local _, a, b, c = lfgCall("GetSearchResultFriends", id)
                store("INFO", "lfgapi members: group %s friends -> %s | %s | %s", show(id), dumpValue(a), dumpValue(b),
                    dumpValue(c))
            end
        end
        log(shown > 0 and "INFO" or "WARN", "lfgapi members: %d groups read (search first)", shown)
    end

    function cmdLfgApi(rest)
        local mode = (rest or ""):lower()
        if mode == "" then
            for _, path in ipairs(LFG_TABLES) do
                local t = resolve(path)
                local names = type(t) == "table" and table.concat(functionNames(t), ", ") or type(t)
                store("INFO", "lfgapi: %s: %s", path, names)
            end
            store("INFO", "lfgapi: finder globals: %s", table.concat(finderGlobals(), ", "))
            for _, name in ipairs({ "GetAdvancedFilter", "GetSearchResultsCount", "GetFilteredSearchResults",
                "GetLanguageSearchFilter", "GetDefaultLanguageSearchFilter" }) do
                if type(resolve("C_LFGList." .. name)) == "function" then
                    store("INFO", "lfgapi: C_LFGList.%s() -> %s", name, probeCall("C_LFGList." .. name))
                end
            end
            local roles = resolve("C_LFGListRoles")
            store("INFO", "lfgapi: C_LFGListRoles: %s",
                type(roles) == "table" and table.concat(functionNames(roles), ", ")
                or type(roles))
            for _, path in ipairs({ "C_LFGListRoles.GetRoles", "C_LFGListRoles.GetSavedRoles",
                "C_LFGList.GetAvailableRoles", "C_LFGList.GetRoleCheckInfo", "C_LFGInfo.GetLevelUpInstances",
                "IsTrialAccount", "IsVeteranTrialAccount", "IsRestrictedAccount" }) do
                if type(resolve(path)) == "function" then
                    store("INFO", "lfgapi: %s() -> %s", path, probeCall(path))
                else
                    store("INFO", "lfgapi: %s missing", path)
                end
            end
            log("INFO", "lfgapi: stored; then /fgp lfgapi plain | heal | dps | quest | members")
            return
        end
        local word, arg = mode:match("^(%S+)%s*(.-)$")
        if word == "quest" then
            apiQuestSearch(arg)
        elseif word == "members" then
            apiMembers()
        elseif word == "twice" then
            apiTwice()
        elseif word == "gap" then
            apiGap(arg)
        elseif word == "plain" or word == "heal" or word == "dps" or word == "tank" or word == "healdps" then
            apiSearch(word)
        else
            log("FAIL", "lfgapi: use /fgp lfgapi, or plain | heal | dps | tank | quest [questID] | members")
        end
    end

    function checkApiTest()
        if not apiTest then
            return
        end
        local test = apiTest
        apiTest = nil
        local _, count, results = pcall(C_LFGList.GetSearchResults)
        results = type(results) == "table" and results or {}
        if test.mode == "quest" then
            local forQuest, solo = 0, 0
            for _, id in ipairs(results) do
                local _, info = lfgCall("GetSearchResultInfo", id)
                if type(info) == "table" then
                    forQuest = forQuest + (info.questID == test.questID and 1 or 0)
                    solo = solo + ((info.numMembers or 0) <= 1 and 1 or 0)
                    if forQuest + solo <= 3 then
                        store("INFO", "lfgapi quest: result %s -> %s", show(id), dumpValue(info))
                    end
                end
            end
            log("RECV", "lfgapi quest: %s found, %d returned, %d with questID %s, %d solo", show(count), #results,
                forQuest, show(test.questID), solo)
            return
        end
        local ruins, solo, needing, other = 0, 0, 0, 0
        local roleKey = ({ heal = "HEALER_REMAINING", dps = "DAMAGER_REMAINING", tank = "TANK_REMAINING" })[test.mode]
        local both, healOnly, dpsOnly = 0, 0, 0
        for _, id in ipairs(results) do
            local _, info = lfgCall("GetSearchResultInfo", id)
            local _, counts = lfgCall("GetSearchResultMemberCounts", id)
            local forRuins = false
            for _, activity in ipairs(type(info) == "table" and info.activityIDs or {}) do
                forRuins = forRuins or activity == RUINS_OF_LORDAERON
            end
            if forRuins then
                ruins = ruins + 1
            else
                other = other + 1
            end
            if type(info) == "table" and (info.numMembers or 0) > 1 and type(counts) == "table" then
                local heal, dps = (counts.HEALER_REMAINING or 0) > 0, (counts.DAMAGER_REMAINING or 0) > 0
                both = both + ((heal and dps) and 1 or 0)
                healOnly = healOnly + ((heal and not dps) and 1 or 0)
                dpsOnly = dpsOnly + ((dps and not heal) and 1 or 0)
            end
            if type(info) == "table" and (info.numMembers or 0) <= 1 then
                solo = solo + 1
            elseif roleKey and type(counts) == "table" and (counts[roleKey] or 0) > 0 then
                needing = needing + 1
            end
        end
        log("RECV", "lfgapi %s: %s found, %d returned in %.1f s: %d for Ruins, %d for other activities, %d solo%s",
            test.mode, show(count), #results, GetTime() - test.at, ruins, other, solo,
            roleKey and string.format(", %d groups with a %s place", needing, test.mode) or "")
        log("RECV", "lfgapi %s: groups needing healer and DPS %d, only a healer %d, only DPS %d", test.mode, both,
            healOnly, dpsOnly)
    end
end

local function onLfgResults(event)
    log("EVENT", "%s%s", event, keySearch.on and " (keysearch active)" or "")
    checkFilterTest()
    checkApiTest()
    checkTwice(event)
    checkGap(event)
    lfgDumpResults()
end

local function onLfgFailed(event, reason)
    log("FAIL", "%s reason=%s", event, show(reason))
    checkTwice(event)
    checkGap(event)
end

-- Accepting a party invite from the invite event itself (no click): what
-- Forever Groups would do for the leader of a proposal the player accepted.
local autoAccept = { on = false, until_ = 0 }

local function cmdAutoAccept(rest)
    autoAccept.on = rest:match("^%s*off") == nil
    autoAccept.until_ = GetTime() + 600
    log("INFO", "autoaccept: %s. AcceptGroup=%s StaticPopup_Hide=%s StaticPopup_Visible=%s", autoAccept.on and "on"
        or "off", type(_G.AcceptGroup), type(_G.StaticPopup_Hide), type(_G.StaticPopup_Visible))
    if autoAccept.on then
        log("INFO", "autoaccept: leave your group and let someone invite you within 10 min; do NOT click the popup")
    end
end

local function tryAutoAccept(inviter)
    if not autoAccept.on or GetTime() > autoAccept.until_ then
        return
    end
    autoAccept.on = false
    local visible = type(_G.StaticPopup_Visible) == "function" and show(_G.StaticPopup_Visible("PARTY_INVITE")) or "?"
    autoAccept.pending = true
    local ok, err = pcall(_G.AcceptGroup)
    log(ok and "INFO" or "FAIL", "autoaccept: AcceptGroup() for %s -> %s (popup was %s)", show(inviter),
        ok and "called" or show(err), visible)
    local hideOk, hideErr = pcall(_G.StaticPopup_Hide, "PARTY_INVITE")
    log(hideOk and "INFO" or "FAIL", "autoaccept: StaticPopup_Hide(PARTY_INVITE) -> %s",
        hideOk and "called" or show(hideErr))
    C_Timer.After(3, function()
        autoAccept.pending = false
        local popup = type(_G.StaticPopup_Visible) == "function" and show(_G.StaticPopup_Visible("PARTY_INVITE")) or "?"
        if IsInGroup() then
            log("PASS", "autoaccept: in a group of %s after 3 s, invite popup %s", show(GetNumGroupMembers()), popup)
        else
            log("FAIL", "autoaccept: not in a group after 3 s, invite popup %s", popup)
        end
    end)
end

-- Which dungeon background pictures (the dungeon finder's art) the client
-- has: a window with each dungeon's candidates side by side, and what the
-- LFG dungeon list calls their texture.
local IMAGE_DUNGEONS = {
    { "Ragefire Chasm", "RAGEFIRECHASM" }, { "Wailing Caverns", "WAILINGCAVERNS" },
    { "The Deadmines", "DEADMINES" }, { "Shadowfang Keep", "SHADOWFANGKEEP" },
    { "Blackfathom Deeps", "BLACKFATHOMDEEPS" }, { "The Stockade", "STORMWINDSTOCKADES", "STOCKADES" },
    { "Gnomeregan", "GNOMEREGAN" }, { "Razorfen Kraul", "RAZORFENKRAUL" },
    { "Scarlet Monastery: Graveyard", "SCARLETMONASTERY", "SCARLETMONASTERYGRAVEYARD" },
    { "Scarlet Monastery: Library", "SCARLETMONASTERY", "SCARLETMONASTERYLIBRARY" },
    { "Scarlet Monastery: Armory", "SCARLETMONASTERY", "SCARLETMONASTERYARMORY" },
    { "Scarlet Monastery: Cathedral", "SCARLETMONASTERY", "SCARLETMONASTERYCATHEDRAL" },
    { "Razorfen Downs", "RAZORFENDOWNS" }, { "Uldaman", "ULDAMAN" }, { "Zul'Farrak", "ZULFARAK", "ZULFARRAK" },
    { "Maraudon", "MARAUDON" }, { "Sunken Temple", "SUNKENTEMPLE", "TEMPLEOFATALHAKKAR" },
    { "Blackrock Depths", "BLACKROCKDEPTHS" },
    { "Lower Blackrock Spire", "BLACKROCKSPIRE", "LOWERBLACKROCKSPIRE" },
    { "Upper Blackrock Spire", "BLACKROCKSPIRE", "UPPERBLACKROCKSPIRE" },
    { "Dire Maul: East", "DIREMAUL", "DIREMAULEAST" }, { "Dire Maul: North", "DIREMAUL", "DIREMAULNORTH" },
    { "Dire Maul: West", "DIREMAUL", "DIREMAULWEST" }, { "Scholomance", "SCHOLOMANCE" },
    { "Stratholme: Living", "STRATHOLME", "STRATHOLMELIVING" },
    { "Stratholme: Undead", "STRATHOLME", "STRATHOLMEUNDEAD" },
    { "Hall of Thanes", "HALLOFTHANES" }, { "Ruins of Lordaeron", "RUINSOFLORDAERON" },
    { "Excavation Site: Wetlands", "EXCAVATIONSITE" }, { "City of Dalaran", "CITYOFDALARAN", "DALARAN" },
    { "The Drowned City", "DROWNEDCITY" }, { "Krol'dok Stronghold", "KROLDOKSTRONGHOLD" },
    { "Alcaz Prison", "ALCAZPRISON" }, { "Blackmaw Hold", "BLACKMAWHOLD" },
    { "Shaper's Terrace", "SHAPERSTERRACE" },
}
local IMAGE_PREFIX = "Interface\\LFGFrame\\UI-LFG-BACKGROUND-"
local IMAGES_PER_PAGE = 12
local imageFrame
local lfgTextures

-- GetLFGDungeonInfo's name and texture name (11th value), by dungeon name.
local function scanLfgTextures()
    if lfgTextures then
        return lfgTextures
    end
    lfgTextures = {}
    local get = _G.GetLFGDungeonInfo
    if type(get) ~= "function" then
        log("INFO", "images: GetLFGDungeonInfo missing")
        return lfgTextures
    end
    local found = 0
    for id = 1, 3000 do
        local ok, name, _, _, _, _, _, _, _, _, _, texture = pcall(get, id)
        if ok and type(name) == "string" and name ~= "" then
            found = found + 1
            lfgTextures[name] = { id = id, texture = texture }
        end
    end
    log("INFO", "images: GetLFGDungeonInfo knows %d dungeons", found)
    for _, d in ipairs(IMAGE_DUNGEONS) do
        local known = lfgTextures[d[1]] or lfgTextures[(d[1]:gsub("^The ", ""))]
        if known then
            store("RECV", "images: LFG %s id=%s texture=%s", d[1], show(known.id), show(known.texture))
        end
    end
    return lfgTextures
end

local function candidates(d)
    local paths = {}
    local known = lfgTextures[d[1]] or lfgTextures[(d[1]:gsub("^The ", ""))]
    if known and type(known.texture) == "string" and known.texture ~= "" then
        paths[#paths + 1] = IMAGE_PREFIX .. known.texture
    end
    for i = 2, #d do
        paths[#paths + 1] = IMAGE_PREFIX .. d[i]
    end
    return paths
end

local function buildImageFrame()
    local ok, f = pcall(CreateFrame, "Frame", "ForeverGroupsProbeImages", UIParent, "BasicFrameTemplateWithInset")
    if not ok then
        f = CreateFrame("Frame", "ForeverGroupsProbeImages", UIParent)
    end
    f:SetSize(3 * 216 + 24, 4 * 132 + 40)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOP", 0, -5)
    f.cells = {}
    for i = 1, IMAGES_PER_PAGE do
        local cell = CreateFrame("Frame", nil, f)
        cell:SetSize(208, 124)
        cell:SetPoint("TOPLEFT", 12 + ((i - 1) % 3) * 216, -30 - math.floor((i - 1) / 3) * 132)
        local back = cell:CreateTexture(nil, "BACKGROUND")
        back:SetPoint("TOPLEFT")
        back:SetSize(208, 104)
        back:SetColorTexture(0, 0.4, 0, 0.6)
        cell.image = cell:CreateTexture(nil, "ARTWORK")
        cell.image:SetPoint("TOPLEFT")
        cell.image:SetSize(208, 104)
        cell.label = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        cell.label:SetPoint("TOPLEFT", cell, "TOPLEFT", 0, -106)
        cell.label:SetWidth(208)
        cell.label:SetJustifyH("LEFT")
        cell.label:SetWordWrap(false)
        f.cells[i] = cell
    end
    table.insert(UISpecialFrames, "ForeverGroupsProbeImages")
    return f
end

local function cmdImages(rest)
    scanLfgTextures()
    imageFrame = imageFrame or buildImageFrame()
    local pages = math.ceil(#IMAGE_DUNGEONS / IMAGES_PER_PAGE)
    local page = math.max(1, math.min(pages, tonumber(rest:match("%d+")) or 1))
    imageFrame.title:SetText(string.format("Dungeon backgrounds %d/%d  (/fgp images %d)", page, pages,
        page % pages + 1))
    for i, cell in ipairs(imageFrame.cells) do
        local d = IMAGE_DUNGEONS[(page - 1) * IMAGES_PER_PAGE + i]
        if d then
            local shown, results = nil, {}
            for _, path in ipairs(candidates(d)) do
                local setOk, loaded = pcall(cell.image.SetTexture, cell.image, path)
                results[#results + 1] = path:sub(#IMAGE_PREFIX + 1) .. "=" .. show(setOk and loaded)
                if setOk and loaded ~= false and not shown then
                    shown = path
                end
            end
            cell.image:SetTexture(shown)
            cell.label:SetText(d[1])
            store("RECV", "images: %s -> %s", d[1], table.concat(results, " "))
            cell:Show()
        else
            cell:Hide()
        end
    end
    imageFrame:Show()
    log("INFO", "images: page %d/%d shown; a green box means no picture. SetTexture results are in /fgp log",
        page, pages)
end

-- Loading screens: the classic ones by name (GetFileIDFromPath tells which
-- exist) and file ids around Forever's own (7963775 City of Dalaran, 7963777
-- Excavation Site) to find the other Forever dungeons' screens.
local LOAD_PREFIX = "Interface\\Glues\\LoadingScreens\\LoadScreen"
local LOAD_NAMES = {
    "RagefireChasm", "WailingCaverns", "Deadmines", "ShadowFangKeep", "BlackFathomDeeps", "Stockade",
    "StormwindStockade", "Gnomeregan", "RazorfenKraul", "ScarletMonastery", "ScarletMonastery2", "Monastery",
    "RazorfenDowns", "Uldaman", "ZulFarrak", "Maraudon", "SunkenTemple", "BlackrockDepths", "BlackrockSpire",
    "DireMaul", "Scholomance", "Stratholme",
}
local LOAD_FIRST_ID, LOAD_LAST_ID = 7963760, 7963795

local loadScreens

local function loadScreenList()
    if loadScreens then
        return loadScreens
    end
    loadScreens = {}
    local has = _G.GetFileIDFromPath
    for _, name in ipairs(LOAD_NAMES) do
        local id
        if type(has) == "function" then
            local ok, result = pcall(has, LOAD_PREFIX .. name)
            id = ok and result or nil
        end
        store("RECV", "loadscreens: %s -> fileID %s", name, show(id))
        if id or type(has) ~= "function" then
            loadScreens[#loadScreens + 1] = { label = name, texture = LOAD_PREFIX .. name }
        end
    end
    for id = LOAD_FIRST_ID, LOAD_LAST_ID do
        loadScreens[#loadScreens + 1] = { label = tostring(id), texture = id }
    end
    log("INFO", "loadscreens: %d classic screens found, %d Forever ids to look at", #loadScreens -
        (LOAD_LAST_ID - LOAD_FIRST_ID + 1), LOAD_LAST_ID - LOAD_FIRST_ID + 1)
    return loadScreens
end

local function cmdLoadScreens(rest)
    local screens = loadScreenList()
    imageFrame = imageFrame or buildImageFrame()
    local pages = math.ceil(#screens / IMAGES_PER_PAGE)
    local page = math.max(1, math.min(pages, tonumber(rest:match("%d+")) or 1))
    imageFrame.title:SetText(string.format("Loading screens %d/%d  (/fgp loadscreens %d)", page, pages,
        page % pages + 1))
    for i, cell in ipairs(imageFrame.cells) do
        local item = screens[(page - 1) * IMAGES_PER_PAGE + i]
        if item then
            cell.image:SetTexture(nil)
            pcall(cell.image.SetTexture, cell.image, item.texture)
            cell.label:SetText(item.label)
            cell:Show()
        else
            cell:Hide()
        end
    end
    imageFrame:Show()
    log("INFO", "loadscreens: page %d/%d; a green box means nothing at that name or id", page, pages)
end

-- How many members a chat channel has: every count API the client might
-- have is tried, by display index and by channel number, and the roster
-- events are logged for a while. A named channel the player is not in is
-- joined for the check and left again.
local CHANNEL_COUNT_APIS = {
    "GetChannelList", "GetNumDisplayChannels", "GetChannelDisplayInfo", "SetSelectedDisplayChannel",
    "GetSelectedDisplayChannel", "GetNumChannelMembers", "C_ChatInfo.GetNumChannelMembers",
    "GetChannelRosterInfo", "C_ChatInfo.GetChannelRosterInfo", "C_ChatInfo.GetChannelInfoFromIdentifier",
    "ListChannelByName",
}
local CHANNEL_WATCH_SECONDS = 20
local ROUTINE_NOTICES = { YOU_JOINED = true, YOU_LEFT = true, YOU_CHANGED = true }
local channelWatchUntil = 0
local channelCounts = {}

local function watchingChannels()
    return GetTime() <= channelWatchUntil
end

local function callLogged(label, path, ...)
    local fn = resolve(path)
    if type(fn) ~= "function" then
        return false
    end
    local argText = select("#", ...) > 0 and showAll(...) or ""
    local function unpackResult(ok, ...)
        if not ok then
            log("WARN", "%s: %s(%s) raised %s", label, path, argText, show((...)))
            return false
        end
        store("RECV", "%s: %s(%s) -> %s", label, path, argText, showAll(...))
        return true, ...
    end
    return unpackResult(pcall(fn, ...))
end

local function noteCount(name, count, source)
    if type(name) ~= "string" or isSecret(name) or type(count) ~= "number" or count <= 0 then
        return
    end
    local known = channelCounts[name]
    if not known or known.count ~= count then
        channelCounts[name] = { count = count, source = source }
        log("PASS", "channels: '%s' has %d members (%s)", name, count, source)
    end
end

local function displayChannels()
    local ok, n = callLogged("channels", "GetNumDisplayChannels")
    local channels = {}
    for i = 1, (ok and tonumber(n)) or 0 do
        local found, name, header, _, number, count = callLogged("channels", "GetChannelDisplayInfo", i)
        if found and not header then
            channels[#channels + 1] = { index = i, name = name, number = number }
            noteCount(name, count, "GetChannelDisplayInfo")
        end
    end
    return channels
end

local function readCounts(channel)
    local found, _, _, _, _, count = callLogged("channels", "GetChannelDisplayInfo", channel.index)
    if found then
        noteCount(channel.name, count, "GetChannelDisplayInfo after selecting")
    end
    for _, path in ipairs({ "GetNumChannelMembers", "C_ChatInfo.GetNumChannelMembers" }) do
        for _, key in ipairs({ channel.index, channel.number }) do
            if key ~= nil then
                local ok, members = callLogged("channels", path, key)
                if ok then
                    noteCount(channel.name, members, path .. "(" .. tostring(key) .. ")")
                end
            end
        end
    end
end

local function surveyChannels()
    local ids = { callLogged("channels", "GetChannelList") }
    if ids[1] then
        local parts = {}
        for i = 2, #ids do
            parts[#parts + 1] = show(ids[i])
        end
        log("INFO", "channels: joined %s", table.concat(parts, " "))
    end
    local channels = displayChannels()
    if #channels == 0 then
        log("WARN", "channels: GetNumDisplayChannels/GetChannelDisplayInfo listed no channels")
    end
    for step, channel in ipairs(channels) do
        C_Timer.After(step * 1.5, function()
            callLogged("channels", "SetSelectedDisplayChannel", channel.index)
            C_Timer.After(1, function()
                readCounts(channel)
            end)
        end)
    end
    C_Timer.After(#channels * 1.5 + 3, function()
        local names = {}
        for _, channel in ipairs(channels) do
            local known = channelCounts[channel.name]
            names[#names + 1] = string.format("%s=%s", show(channel.name), known and known.count or "?")
        end
        log("INFO", "channels: done. %s", table.concat(names, ", "))
        log("INFO", "channels: /reload or log out to save the results to ForeverGroupsProbeDB")
    end)
end

local function cmdChannels(rest)
    local present = {}
    for _, path in ipairs(CHANNEL_COUNT_APIS) do
        present[#present + 1] = path .. "=" .. (type(resolve(path)) == "function" and "yes" or "no")
    end
    log("INFO", "channels: APIs %s", table.concat(present, ", "))
    channelWatchUntil = GetTime() + CHANNEL_WATCH_SECONDS + 30
    local name = rest ~= "" and rest or nil
    if not name or (GetChannelName(name) or 0) > 0 then
        surveyChannels()
        return
    end
    local ok, err = pcall(JoinTemporaryChannel, name)
    if not ok then
        log("FAIL", "channels: JoinTemporaryChannel('%s') raised %s", name, show(err))
        return
    end
    log("INFO", "channels: joining '%s' for the check, leaving it again after %d s", name, CHANNEL_WATCH_SECONDS + 15)
    C_Timer.After(3, function()
        if (GetChannelName(name) or 0) == 0 then
            log("FAIL", "channels: could not join '%s' (see the notices above, if any)", name)
        end
        if type(resolve("ListChannelByName")) == "function" then
            callLogged("channels", "ListChannelByName", name)
        end
        surveyChannels()
    end)
    C_Timer.After(CHANNEL_WATCH_SECONDS + 15, function()
        pcall(LeaveChannelByName, name)
        log("INFO", "channels: left '%s'", name)
    end)
end

local function onChannelCount(event, index, count)
    if not watchingChannels() then
        return
    end
    local found, name = callLogged("channels", "GetChannelDisplayInfo", index)
    log("EVENT", "%s index=%s count=%s (%s)", event, show(index), show(count), found and show(name) or "?")
    if found then
        noteCount(name, count, event)
    end
end

local function onChannelList(event, text, _, _, channelString, _, _, _, _, baseName)
    if not watchingChannels() or isSecret(text) then
        return
    end
    local members = 0
    if type(text) == "string" and text ~= "" then
        members = select(2, text:gsub(",", ",")) + 1
    end
    log("EVENT", "%s %s: %d names listed", event, show(channelString), members)
    noteCount(baseName, members, event)
end

-- Level ranges of the "Quests & Zones" activities, as the Group Finder
-- gives them for dungeons (GetActivityInfoTable), and the zone map's own
-- (C_Map.GetMapLevels) when the activity names a map.
local function cmdZoneLevels()
    local category
    local catOk, categories = lfgCall("GetAvailableCategories")
    for _, id in ipairs(catOk and type(categories) == "table" and categories or {}) do
        local infoOk, info = lfgCall("GetLfgCategoryInfo", id)
        local name = infoOk and type(info) == "table" and info.name
        if type(name) == "string" and string.find(string.lower(name), "quest") then
            category = id
        end
    end
    local actOk, activities = lfgCall("GetAvailableActivities", category)
    local count, withLevels = 0, 0
    for _, activity in ipairs(actOk and type(activities) == "table" and activities or {}) do
        local ok, info = lfgCall("GetActivityInfoTable", activity)
        if ok and type(info) == "table" then
            count = count + 1
            local min = tonumber(info.minLevelSuggestion) or tonumber(info.minLevel) or 0
            local max = tonumber(info.maxLevelSuggestion) or tonumber(info.maxLevel) or 0
            if min > 0 or max > 0 then
                withLevels = withLevels + 1
            end
            local mapLevels = ""
            local getLevels = resolve("C_Map.GetMapLevels")
            if type(info.mapID) == "number" and type(getLevels) == "function" then
                mapLevels = " map " .. showAll(pcall(getLevels, info.mapID))
            end
            store("RECV", "zonelevels: %s %s min=%s max=%s minSug=%s maxSug=%s mapID=%s%s", show(activity),
                show(info.fullName or info.shortName), show(info.minLevel), show(info.maxLevel),
                show(info.minLevelSuggestion), show(info.maxLevelSuggestion), show(info.mapID), mapLevels)
        end
    end
    log("INFO", "zonelevels: %d zone activities in category %s, %d with a level range; details in /fgp log",
        count, show(category), withLevels)
end

local dropdownFrame
local DROPDOWN_STYLES = { "Any", "Relaxed", "Learning", "Competitive", "Carry Offered" }

-- Which dropdowns this client has: the 11.0 one (WowStyle1DropdownTemplate,
-- SetupMenu with radios) and the old UIDropDownMenu. Shows each that exists.
local function cmdDropdown()
    log("INFO", "dropdown: MenuUtil=%s CreateContextMenu=%s UIDropDownMenu_Initialize=%s",
        type(MenuUtil), type(MenuUtil) == "table" and type(MenuUtil.CreateContextMenu) or "nil",
        type(UIDropDownMenu_Initialize))
    if dropdownFrame then
        dropdownFrame:SetShown(not dropdownFrame:IsShown())
        return
    end
    dropdownFrame = CreateFrame("Frame", "ForeverGroupsProbeDropdowns", UIParent, "BasicFrameTemplateWithInset")
    dropdownFrame:SetSize(420, 170)
    dropdownFrame:SetPoint("CENTER")
    dropdownFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    dropdownFrame:EnableMouse(true)
    dropdownFrame:SetMovable(true)
    dropdownFrame:RegisterForDrag("LeftButton")
    dropdownFrame:SetScript("OnDragStart", dropdownFrame.StartMoving)
    dropdownFrame:SetScript("OnDragStop", dropdownFrame.StopMovingOrSizing)
    local title = dropdownFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -5)
    title:SetText("Dropdowns (/fgp dropdown)")

    local chosenNew, chosenOld = 1, 1
    local newLabel = dropdownFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    newLabel:SetPoint("TOPLEFT", 20, -40)
    newLabel:SetText("1) WowStyle1DropdownTemplate")
    local ok, newDropdown = pcall(CreateFrame, "DropdownButton", nil, dropdownFrame, "WowStyle1DropdownTemplate")
    if ok and newDropdown and type(newDropdown.SetupMenu) == "function" then
        newDropdown:SetPoint("TOPLEFT", 20, -60)
        if newDropdown.SetWidth then
            newDropdown:SetWidth(150)
        end
        local setupOk, err = pcall(newDropdown.SetupMenu, newDropdown, function(_, root)
            for i, word in ipairs(DROPDOWN_STYLES) do
                local radio = root:CreateRadio(word, function()
                    return chosenNew == i
                end, function()
                    chosenNew = i
                    log("RECV", "dropdown: new style picked %s", word)
                end)
                if radio and radio.SetTooltip then
                    radio:SetTooltip(function(tooltip)
                        GameTooltip_SetTitle(tooltip, word)
                        GameTooltip_AddNormalLine(tooltip, "Tooltip for " .. word)
                    end)
                end
            end
        end)
        log("INFO", "dropdown: new style created, SetupMenu %s %s", show(setupOk), show(err))
    else
        log("WARN", "dropdown: no WowStyle1DropdownTemplate (%s)", show(newDropdown))
        newLabel:SetText("1) WowStyle1DropdownTemplate: not available")
    end

    local oldLabel = dropdownFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    oldLabel:SetPoint("TOPLEFT", 20, -100)
    oldLabel:SetText("2) UIDropDownMenuTemplate")
    local oldOk, oldDropdown = pcall(CreateFrame, "Frame", "ForeverGroupsProbeOldDropdown", dropdownFrame,
        "UIDropDownMenuTemplate")
    if oldOk and oldDropdown and type(UIDropDownMenu_Initialize) == "function" then
        oldDropdown:SetPoint("TOPLEFT", 4, -116)
        UIDropDownMenu_SetWidth(oldDropdown, 130)
        UIDropDownMenu_Initialize(oldDropdown, function()
            for i, word in ipairs(DROPDOWN_STYLES) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = word
                info.checked = chosenOld == i
                info.func = function()
                    chosenOld = i
                    UIDropDownMenu_SetText(oldDropdown, word)
                    log("RECV", "dropdown: old style picked %s", word)
                end
                UIDropDownMenu_AddButton(info)
            end
        end)
        UIDropDownMenu_SetText(oldDropdown, DROPDOWN_STYLES[1])
        log("INFO", "dropdown: old style created")
    else
        log("WARN", "dropdown: no UIDropDownMenuTemplate (%s)", show(oldDropdown))
        oldLabel:SetText("2) UIDropDownMenuTemplate: not available")
    end
    table.insert(UISpecialFrames, "ForeverGroupsProbeDropdowns")
end

-- Hiding our own outgoing whispers: registers a filter for "To X: ..."
-- lines (CHAT_MSG_WHISPER_INFORM) and whispers yourself twice; the line
-- with "fgp-hide" should not show in chat, the other should. Run it again
-- in combat to see whether the text is readable then (secret values).
local chatFilterAdded = false
local function cmdChatFilter()
    local add = resolve("ChatFrameUtil.AddMessageEventFilter") or ChatFrame_AddMessageEventFilter
    log("INFO", "chatfilter: ChatFrameUtil.AddMessageEventFilter=%s ChatFrame_AddMessageEventFilter=%s",
        type(resolve("ChatFrameUtil.AddMessageEventFilter")), type(ChatFrame_AddMessageEventFilter))
    if type(add) ~= "function" then
        log("FAIL", "chatfilter: no filter function")
        return
    end
    if not chatFilterAdded then
        local ok, err = pcall(add, "CHAT_MSG_WHISPER_INFORM", function(_, _, text, target)
            local readable = not isSecret(text)
            local hide = false
            if readable then
                hide = string.find(text, "fgp-hide", 1, true) ~= nil
            end
            store("RECV", "chatfilter: called, readable=%s target=%s hide=%s", show(readable),
                readable and show(target) or "secret", show(hide))
            return hide
        end)
        chatFilterAdded = ok
        log(ok and "INFO" or "FAIL", "chatfilter: filter added %s %s", show(ok), show(err))
    end
    local me = myFullName()
    local send = resolve("C_ChatInfo.SendChatMessage") or SendChatMessage
    pcall(send, "fgp-hide this line should NOT show", "WHISPER", nil, me)
    pcall(send, "fgp-show this line should show", "WHISPER", nil, me)
    log("INFO", "chatfilter: whispered yourself twice; only the 'should show' line should be in chat")
end

-- Class art for the role tiles: the Classic talent tab backgrounds and
-- icons, retail atlases that might hold class art, and what the spec APIs
-- return. Files are checked with GetFileIDFromPath, atlases with
-- C_Texture.GetAtlasInfo; everything found is drawn so a screenshot shows it.
local CLASS_TREES = {
    WARRIOR = { "WarriorArms", "WarriorFury", "WarriorProtection" },
    PALADIN = { "PaladinHoly", "PaladinProtection", "PaladinCombat" },
    HUNTER = { "HunterBeastMastery", "HunterMarksmanship", "HunterSurvival" },
    ROGUE = { "RogueAssassination", "RogueCombat", "RogueSubtlety" },
    PRIEST = { "PriestDiscipline", "PriestHoly", "PriestShadow" },
    SHAMAN = { "ShamanElementalCombat", "ShamanEnhancement", "ShamanRestoration" },
    MAGE = { "MageArcane", "MageFire", "MageFrost" },
    WARLOCK = { "WarlockCurses", "WarlockSummoning", "WarlockDestruction" },
    DRUID = { "DruidBalance", "DruidFeralCombat", "DruidRestoration" },
}
local CLASS_SPECS = {
    WARRIOR = { "arms", "fury", "protection" }, PALADIN = { "holy", "protection", "retribution" },
    HUNTER = { "beastmastery", "marksmanship", "survival" }, ROGUE = { "assassination", "outlaw", "subtlety" },
    PRIEST = { "discipline", "holy", "shadow" }, SHAMAN = { "elemental", "enhancement", "restoration" },
    MAGE = { "arcane", "fire", "frost" }, WARLOCK = { "affliction", "demonology", "destruction" },
    DRUID = { "balance", "feral", "restoration" },
}
local CLASS_TAB_ICONS = {
    WARRIOR = { "Ability_Rogue_Eviscerate", "Ability_Warrior_InnerRage", "INV_Shield_06" },
    PALADIN = { "Spell_Holy_HolyBolt", "Spell_Holy_DevotionAura", "Spell_Holy_AuraOfLight" },
    HUNTER = { "Ability_Hunter_BeastTaming", "Ability_Marksmanship", "Ability_Hunter_SwiftStrike" },
    ROGUE = { "Ability_Rogue_Eviscerate", "Ability_BackStab", "Ability_Stealth" },
    PRIEST = { "Spell_Holy_WordFortitude", "Spell_Holy_HolyBolt", "Spell_Shadow_ShadowWordPain" },
    SHAMAN = { "Spell_Nature_Lightning", "Spell_Nature_LightningShield", "Spell_Nature_MagicImmunity" },
    MAGE = { "Spell_Holy_MagicalSentry", "Spell_Fire_FireBolt02", "Spell_Frost_FrostBolt02" },
    WARLOCK = { "Spell_Shadow_DeathCoil", "Spell_Shadow_Metamorphosis", "Spell_Shadow_RainOfFire" },
    DRUID = { "Spell_Nature_StarFall", "Ability_Racial_BearForm", "Spell_Nature_HealingTouch" },
}
local CLASS_IDS = { WARRIOR = 1, PALADIN = 2, HUNTER = 3, ROGUE = 4, PRIEST = 5, SHAMAN = 7, MAGE = 8, WARLOCK = 9,
    DRUID = 11 }

local classArtFrame

local function fileExists(path)
    local has = _G.GetFileIDFromPath
    if type(has) ~= "function" then
        return nil
    end
    local ok, id = pcall(has, path)
    return ok and id ~= nil and id ~= 0, ok and id or nil
end

local function atlasExists(name)
    local get = resolve("C_Texture.GetAtlasInfo")
    if type(get) ~= "function" then
        return nil
    end
    local ok, info = pcall(get, name)
    return ok and type(info) == "table", ok and type(info) == "table" and info or nil
end

local function classAtlases(class)
    local lower = class:lower()
    local proper = class:sub(1, 1) .. class:sub(2):lower()
    local names = {
        "talents-background-" .. lower, "classicon-" .. lower, "GarrMission_ClassIcon-" .. proper,
        "groupfinder-icon-class-" .. lower, "charactercreate-class-" .. lower, "class-" .. lower,
        "Class-" .. proper, "talents-heroclass-" .. lower, "UI-HUD-ActionBar-" .. proper,
    }
    for _, spec in ipairs(CLASS_SPECS[class] or {}) do
        names[#names + 1] = "spec-thumbnail-" .. lower .. "-" .. spec
        names[#names + 1] = "talents-background-" .. lower .. "-" .. spec
        names[#names + 1] = "spec-background-" .. lower .. "-" .. spec
        names[#names + 1] = "talents-background-" .. lower .. spec
    end
    return names
end

local function classArtCell(parent, x, y, width, height)
    local cell = CreateFrame("Frame", nil, parent)
    cell:SetSize(width, height + 14)
    cell:SetPoint("TOPLEFT", x, y)
    cell.image = cell:CreateTexture(nil, "ARTWORK")
    cell.image:SetSize(width, height)
    cell.image:SetPoint("TOP")
    cell.label = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cell.label:SetPoint("TOP", cell.image, "BOTTOM", 0, -1)
    cell.label:SetWidth(width + 20)
    return cell
end

local function cmdClassArt(rest)
    local class = (rest or ""):upper():match("%a+")
    if not class or not CLASS_TREES[class] then
        class = select(2, UnitClass("player"))
    end
    if classArtFrame then
        classArtFrame:Hide()
    end
    local frame = CreateFrame("Frame", nil, UIParent, "BasicFrameTemplateWithInset")
    classArtFrame = frame
    frame:SetSize(780, 600)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -5)
    title:SetText(string.format("Class art for %s  (/fgp classart [class])", class))

    local x, y = 16, -34
    for i, name in ipairs(CLASS_TREES[class]) do
        local path = "Interface\\TalentFrame\\" .. name .. "-TopLeft"
        local exists, id = fileExists(path)
        store("RECV", "classart: file %s exists=%s id=%s", path, show(exists), show(id))
        local cell = classArtCell(frame, x + (i - 1) * 180, y, 160, 160)
        cell.image:SetTexture(exists ~= false and path or nil)
        if exists == false then
            cell.image:SetColorTexture(0.3, 0, 0, 0.5)
        end
        cell.label:SetText(name .. (exists == false and " (missing)" or ""))
        local icon = "Interface\\Icons\\" .. CLASS_TAB_ICONS[class][i]
        local iconExists = fileExists(icon)
        store("RECV", "classart: icon %s exists=%s", icon, show(iconExists))
        local iconCell = classArtCell(frame, x + (i - 1) * 180 + 60, y - 182, 40, 40)
        iconCell.image:SetTexture(icon)
        iconCell.label:SetText(CLASS_TAB_ICONS[class][i] .. (iconExists == false and " (missing)" or ""))
    end

    local tabInfo = _G.GetTalentTabInfo
    for i = 1, 3 do
        if type(tabInfo) == "function" then
            store("RECV", "classart: GetTalentTabInfo(%d) -> %s", i, showAll(pcall(tabInfo, i)))
        end
    end
    local specInfo = _G.GetSpecializationInfoForClassID
    local classId = CLASS_IDS[class]
    if type(specInfo) == "function" and classId then
        for i = 1, 4 do
            local ok, id, name, _, icon, role, _, _ = pcall(specInfo, classId, i)
            store("RECV", "classart: GetSpecializationInfoForClassID(%d,%d) -> %s %s %s icon=%s role=%s", classId, i,
                show(ok), show(id), show(name), show(icon), show(role))
            if ok and icon then
                local cell = classArtCell(frame, 560 + (i - 1) * 52, y, 40, 40)
                cell.image:SetTexture(icon)
                cell.label:SetText(tostring(name))
            end
        end
    else
        store("RECV", "classart: GetSpecializationInfoForClassID=%s", type(specInfo))
    end

    local found, missing = {}, {}
    for _, name in ipairs(classAtlases(class)) do
        local exists, info = atlasExists(name)
        if exists then
            found[#found + 1] = { name = name, info = info }
        else
            missing[#missing + 1] = name
        end
    end
    store("RECV", "classart: atlases missing: %s", table.concat(missing, ", "))
    local ax, ay = 16, y - 250
    for _, atlas in ipairs(found) do
        local w, h = atlas.info.width or 100, atlas.info.height or 100
        local scale = math.min(170 / w, 110 / h, 1)
        local cell = classArtCell(frame, ax, ay, math.max(20, w * scale), math.max(20, h * scale))
        cell.image:SetAtlas(atlas.name)
        cell.label:SetText(atlas.name)
        store("RECV", "classart: atlas %s exists %dx%d", atlas.name, w, h)
        ax = ax + 190
        if ax > 760 - 180 then
            ax, ay = 16, ay - 140
        end
    end
    frame:Show()
    log("INFO", "classart: %s: %d atlases found, %d not; details in /fgp log. Please take a screenshot.", class,
        #found, #missing)
end

-- Which retail spec art atlases exist for every class: spec-thumbnail-*
-- and talents-background-*, with a few spellings per spec.
local SPEC_ART_NAMES = {
    warrior = { "arms", "fury", "protection" },
    paladin = { "holy", "protection", "retribution" },
    hunter = { "beastmastery", "beast-mastery", "marksmanship", "survival" },
    rogue = { "assassination", "outlaw", "combat", "subtlety" },
    priest = { "discipline", "holy", "shadow" },
    shaman = { "elemental", "enhancement", "restoration" },
    mage = { "arcane", "fire", "frost" },
    warlock = { "affliction", "demonology", "destruction" },
    druid = { "balance", "feral", "guardian", "restoration" },
}

local function cmdSpecArt()
    local found, missing = 0, {}
    for class, specs in pairs(SPEC_ART_NAMES) do
        for _, spec in ipairs(specs) do
            for _, prefix in ipairs({ "spec-thumbnail-", "talents-background-" }) do
                local name = prefix .. class .. "-" .. spec
                local exists, info = atlasExists(name)
                if exists then
                    found = found + 1
                    store("RECV", "specart: %s %dx%d", name, info.width or 0, info.height or 0)
                else
                    missing[#missing + 1] = name
                end
            end
        end
    end
    store("RECV", "specart: missing: %s", table.concat(missing, ", "))
    log("INFO", "specart: %d found, %d missing; details in the saved log", found, #missing)
end

-- The art on the category buttons of WoW's Group Finder (Dungeons, Quests &
-- Zones): reads the textures of the real buttons (open the Group Finder
-- first) and checks likely atlas names; what exists is drawn.
local FINDER_ATLASES = {
    "groupfinder-button-dungeons", "groupfinder-button-questing", "groupfinder-button-raids",
    "groupfinder-button-raids-classic", "groupfinder-button-raids-bc", "groupfinder-button-arenas",
    "groupfinder-button-rbg", "groupfinder-button-skirmishes", "groupfinder-button-custom-pve",
    "groupfinder-button-custom-pvp", "groupfinder-button-delves", "groupfinder-button-cover",
    "groupfinder-button-select", "groupfinder-button-questing-classic", "groupfinder-button-dungeons-classic",
    "groupfinder-background", "groupfinder-background-dungeons", "groupfinder-background-questing",
}

local finderArtFrame

local function scanFinderArt(frame, depth, seen, found)
    if not frame or depth > 8 or seen[frame] then
        return
    end
    seen[frame] = true
    local label
    if frame.GetRegions then
        for _, region in ipairs({ frame:GetRegions() }) do
            if region.GetObjectType and region:GetObjectType() == "FontString" then
                local text = region:GetText()
                if type(text) == "string" and text ~= "" then
                    label = label or text
                end
            end
        end
        for _, region in ipairs({ frame:GetRegions() }) do
            if region.GetObjectType and region:GetObjectType() == "Texture" then
                local atlas = region.GetAtlas and region:GetAtlas()
                local texture = region.GetTexture and region:GetTexture()
                if (atlas and atlas ~= "") or texture then
                    local w, h = region:GetSize()
                    local fw, fh = frame:GetSize()
                    local points = {}
                    for i = 1, region:GetNumPoints() do
                        local point, _, relativePoint, px, py = region:GetPoint(i)
                        points[#points + 1] = string.format("%s>%s(%s,%s)", tostring(point), tostring(relativePoint),
                            tostring(px), tostring(py))
                    end
                    found[#found + 1] = { label = label or "?", atlas = atlas, texture = texture,
                        coords = { region:GetTexCoord() }, name = region:GetDebugName(),
                        size = string.format("%.0fx%.0f in %.0fx%.0f %s", w or 0, h or 0, fw or 0, fh or 0,
                            table.concat(points, " ")) }
                end
            end
        end
    end
    if frame.GetChildren then
        for _, child in ipairs({ frame:GetChildren() }) do
            scanFinderArt(child, depth + 1, seen, found)
        end
    end
end

local function cmdFinderArt()
    local found, seen = {}, {}
    for _, name in ipairs({ "LFGListFrame", "LFGParentFrame", "PVEFrame", "GroupFinderFrame" }) do
        local root = _G[name]
        if root then
            scanFinderArt(root, 0, seen, found)
        end
    end
    local kept = 0
    for _, item in ipairs(found) do
        local atlas, texture = tostring(item.atlas), tostring(item.texture)
        if item.label ~= "?" or atlas:find("groupfinder") or texture:find("[Gg]roup") then
            kept = kept + 1
            store("RECV", "finderart: [%s] %s atlas=%s texture=%s size=%s", item.label, tostring(item.name), atlas,
                texture, item.size)
        end
    end
    if finderArtFrame then
        finderArtFrame:Hide()
    end
    local frame = CreateFrame("Frame", nil, UIParent, "BasicFrameTemplateWithInset")
    finderArtFrame = frame
    frame:SetSize(700, 520)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -5)
    title:SetText("Group Finder art (/fgp finderart)")
    local x, y, shown = 16, -34, 0
    for _, name in ipairs(FINDER_ATLASES) do
        local exists, info = atlasExists(name)
        if exists then
            shown = shown + 1
            store("RECV", "finderart: atlas %s %dx%d", name, info.width or 0, info.height or 0)
            local w, h = info.width or 100, info.height or 100
            local scale = math.min(320 / w, 70 / h, 1)
            local cell = classArtCell(frame, x, y, math.max(20, w * scale), math.max(20, h * scale))
            cell.image:SetAtlas(name)
            cell.label:SetText(name)
            if x > 16 then
                x, y = 16, y - 92
            else
                x = 350
            end
        else
            store("RECV", "finderart: atlas %s missing", name)
        end
    end
    frame:Show()
    log("INFO", "finderart: %d textures read from the Group Finder (%d kept), %d atlases found. Open the Group "
        .. "Finder first for the first number.", #found, kept, shown)
end

-- Battlegrounds: which functions exist, which battlegrounds the client
-- knows, the Group Finder's battleground activities, and (once a
-- battlemaster's window opens or the queue changes) what those tell.
local PVP_FUNCTIONS = {
    "JoinBattlefield", "GetNumBattlefields", "GetBattlefieldInfo", "GetBattlefieldStatus", "GetMaxBattlefieldID",
    "GetNumBattlegroundTypes", "GetBattlegroundInfo", "CanJoinBattlefieldAsGroup", "RequestBattlegroundInstanceInfo",
    "SetSelectedBattlefield", "GetSelectedBattlefield", "AcceptBattlefieldPort", "GetBattlefieldPortExpiration",
    "GetBattlefieldEstimatedWaitTime", "GetBattlefieldTimeWaited", "GetBattlefieldInstanceInfo",
    "JoinBattlegroundQueue", "JoinSkirmish", "CloseBattlefield", "UnitInBattleground", "GetBattlefieldWinner",
}

local function pvpStatus(context)
    local max = resolve("GetMaxBattlefieldID")
    local count = type(max) == "function" and select(2, pcall(max)) or 3
    for i = 1, tonumber(count) or 3 do
        store("RECV", "pvp: %s GetBattlefieldStatus(%d) -> %s", context, i, probeCall("GetBattlefieldStatus", i))
        store("RECV", "pvp: %s GetBattlefieldEstimatedWaitTime(%d) -> %s", context, i,
            probeCall("GetBattlefieldEstimatedWaitTime", i))
    end
end

local function pvpBattlemaster(context)
    local count = probeCall("GetNumBattlefields")
    log("RECV", "pvp: %s GetNumBattlefields -> %s, CanJoinBattlefieldAsGroup -> %s, GetSelectedBattlefield -> %s",
        context, count, probeCall("CanJoinBattlefieldAsGroup"), probeCall("GetSelectedBattlefield"))
    for i = 1, math.min(tonumber(count) or 0, 20) do
        store("RECV", "pvp: %s GetBattlefieldInfo(%d) -> %s", context, i, probeCall("GetBattlefieldInfo", i))
    end
    for _, name in ipairs({ "BattlefieldFrame", "PVPBattlegroundFrame", "PVPUIFrame", "PVPFrame",
        "HonorFrame", "BattlefieldFrameJoinButton", "BattlefieldFrameGroupJoinButton" }) do
        local frame = _G[name]
        if frame then
            store("RECV", "pvp: %s frame %s shown=%s", context, name,
                show(frame.IsShown and frame:IsShown()))
        end
    end
end

local function onBattlefieldsShow(event, ...)
    log("RECV", "pvp: %s %s", event, showAll(...))
    pvpBattlemaster(event)
end

local function onBattlefieldStatus(event, ...)
    log("RECV", "pvp: %s %s", event, showAll(...))
    pvpStatus(event)
end

local function cmdPvp()
    local present, missing = {}, {}
    for _, name in ipairs(PVP_FUNCTIONS) do
        if type(resolve(name)) == "function" then
            present[#present + 1] = name
        else
            missing[#missing + 1] = name
        end
    end
    log("INFO", "pvp: present: %s", table.concat(present, ", "))
    log("INFO", "pvp: missing: %s", #missing > 0 and table.concat(missing, ", ") or "none")
    if type(_G.C_PvP) == "table" then
        local names = {}
        for name, value in pairs(_G.C_PvP) do
            if type(value) == "function" then
                names[#names + 1] = name
            end
        end
        table.sort(names)
        store("INFO", "pvp: C_PvP: %s", table.concat(names, ", "))
        for _, name in ipairs({ "GetBattlegroundInfo", "GetAvailableBattlegrounds", "IsBattleground",
            "GetRandomBGInfo", "IsWarModeActive", "GetActiveBrawlInfo" }) do
            if type(_G.C_PvP[name]) == "function" then
                store("INFO", "pvp: C_PvP.%s() -> %s", name, probeCall("C_PvP." .. name))
            end
        end
    end
    local types = probeCall("GetNumBattlegroundTypes")
    log("INFO", "pvp: GetNumBattlegroundTypes -> %s", types)
    for i = 1, math.min(tonumber(types) or 0, 30) do
        store("INFO", "pvp: GetBattlegroundInfo(%d) -> %s", i, probeCall("GetBattlegroundInfo", i))
        log("INFO", "pvp: C_PvP.GetBattlegroundInfo(%d) -> %s", i, probeCall("C_PvP.GetBattlegroundInfo", i))
    end
    store("INFO", "pvp: C_PvP.GetLevelUpBattlegrounds() -> %s", probeCall("C_PvP.GetLevelUpBattlegrounds"))
    store("INFO", "pvp: C_PvP.GetRandomEpicBGInfo() -> %s", probeCall("C_PvP.GetRandomEpicBGInfo"))
    pvpStatus("now")
    pvpBattlemaster("now")
    local ok, categories = lfgCall("GetAvailableCategories")
    if ok and type(categories) == "table" then
        for _, id in ipairs(categories) do
            local infoOk, info = lfgCall("GetLfgCategoryInfo", id)
            local name = infoOk and type(info) == "table" and info.name or ""
            store("INFO", "pvp: lfg category %s = %s", show(id), dumpValue(name))
            if type(name) == "string" and not isSecret(name) and name:lower():find("battle") then
                local actOk, activities = lfgCall("GetAvailableActivities", id)
                for _, activity in ipairs(actOk and type(activities) == "table" and activities or {}) do
                    local aOk, aInfo = lfgCall("GetActivityInfoTable", activity)
                    store("INFO", "pvp: lfg battleground activity %s: %s", show(activity),
                        aOk and dumpTable(aInfo) or show(aInfo))
                end
                log("INFO", "pvp: Group Finder category %s (%s) has %d activities", show(id), name,
                    actOk and type(activities) == "table" and #activities or 0)
            end
        end
    end
    log("INFO", "pvp: now talk to a battlemaster (the window logs itself); queue alone and leave the queue again "
        .. "if you can. Then /fgp log or just say done.")
end

-- Rounded corners for art: draws a place like the group card's (106 x 80,
-- the tooltip border on top) filled with spec art, once per mask candidate,
-- so a screenshot shows which mask makes the art follow the round corners.
local MASK_CANDIDATES = {
    { "none", nil },
    { "common-iconmask", "Interface\\Common\\common-iconmask" },
    { "UI-Frame-IconMask", "Interface\\FrameGeneral\\UIFrameIconMask" },
    { "SquareMask", "Interface\\Masks\\SquareMask" },
    { "white rounded", "Interface\\Buttons\\WHITE8X8" },
}

local maskFrame

local function cmdMask()
    if maskFrame then
        maskFrame:SetShown(not maskFrame:IsShown())
        return
    end
    maskFrame = CreateFrame("Frame", nil, UIParent, "BasicFrameTemplateWithInset")
    maskFrame:SetSize(660, 170)
    maskFrame:SetPoint("CENTER")
    maskFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    maskFrame:EnableMouse(true)
    maskFrame:SetMovable(true)
    maskFrame:RegisterForDrag("LeftButton")
    maskFrame:SetScript("OnDragStart", maskFrame.StartMoving)
    maskFrame:SetScript("OnDragStop", maskFrame.StopMovingOrSizing)
    local title = maskFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -5)
    title:SetText("Masks for rounded art (/fgp mask)")
    log("INFO", "mask: CreateMaskTexture=%s", show(type(maskFrame.CreateMaskTexture)))
    for i, candidate in ipairs(MASK_CANDIDATES) do
        local ok, place = pcall(CreateFrame, "Frame", nil, maskFrame, "BackdropTemplate")
        if not ok then
            place = CreateFrame("Frame", nil, maskFrame)
        end
        place:SetSize(106, 80)
        place:SetPoint("TOPLEFT", 16 + (i - 1) * 126, -40)
        local art = place:CreateTexture(nil, "BACKGROUND", nil, 1)
        art:SetPoint("TOPLEFT", 2, -2)
        art:SetPoint("BOTTOMRIGHT", -2, 2)
        local atlasOk = pcall(art.SetAtlas, art, "spec-thumbnail-druid-feral")
        if not atlasOk then
            art:SetColorTexture(0.6, 0.3, 0.1, 1)
        end
        local path = candidate[2]
        local exists = path and fileExists(path)
        if path and type(place.CreateMaskTexture) == "function" then
            local mask = place:CreateMaskTexture()
            mask:SetAllPoints(art)
            local setOk, err = pcall(mask.SetTexture, mask, path, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            local addOk, addErr = pcall(art.AddMaskTexture, art, mask)
            store("RECV", "mask: %s exists=%s set=%s %s add=%s %s", candidate[1], show(exists), show(setOk), show(err),
                show(addOk), show(addErr))
        end
        if place.SetBackdrop then
            place:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14 })
            place:SetBackdropBorderColor(1, 1, 1, 0.5)
        end
        local label = maskFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("TOP", place, "BOTTOM", 0, -4)
        label:SetText(i .. ") " .. candidate[1] .. (path and exists == false and " (missing)" or ""))
    end
    maskFrame:Show()
    log("INFO", "mask: shown; please take a screenshot")
end

-- Raids for battleground premades: whether the addon may turn the party
-- into a raid without a click (from a timer), and back again. Only as the
-- leader of a party outside an instance: the group is a raid for a few
-- seconds.
local raidTest

local function raidStep(text, fnName)
    local fn = resolve("C_PartyInfo." .. fnName) or resolve(fnName)
    if type(fn) ~= "function" then
        log("FAIL", "raid: %s missing", fnName)
        return
    end
    raidTest.blocked = nil
    local ok, err = pcall(fn)
    log(ok and "INFO" or "FAIL", "raid: %s from a timer -> %s %s", text, show(ok), show(err))
    C_Timer.After(2, function()
        log("RECV", "raid: after %s: IsInRaid=%s IsInGroup=%s members=%s blocked=%s", text, show(IsInRaid()),
            show(IsInGroup()), show(GetNumGroupMembers()), show(raidTest.blocked))
    end)
end

local function cmdRaid()
    log("INFO", "raid: C_PartyInfo.ConvertToRaid=%s ConvertToRaid=%s C_PartyInfo.ConvertToParty=%s ConvertToParty=%s",
        type(resolve("C_PartyInfo.ConvertToRaid")), type(_G.ConvertToRaid), type(resolve("C_PartyInfo.ConvertToParty")),
        type(_G.ConvertToParty))
    if not IsInGroup() or IsInRaid() or not UnitIsGroupLeader("player") then
        log("FAIL", "raid: be the leader of a party (not a raid) for this test")
        return
    end
    if IsInInstance() then
        log("FAIL", "raid: leave the instance first; the group is a raid for a few seconds")
        return
    end
    raidTest = {}
    C_Timer.After(1, function()
        raidStep("ConvertToRaid", "ConvertToRaid")
    end)
    C_Timer.After(6, function()
        raidStep("ConvertToParty", "ConvertToParty")
    end)
    log("INFO", "raid: turning the party into a raid in 1 s and back in 6 s, both from a timer")
end

-- /fgp rescind <Name> [expire]: invite a player, then take the invite back
-- after 5 s with C_PartyInfo.UninviteUnit (or, with "expire", leave it to
-- see how long WoW keeps it open); every system message and roster change
-- is logged meanwhile.
local cmdRescind
do
    local watch, watchFrame, keyFrameRescind

    local function groupState()
        return string.format("IsInGroup=%s members=%s", show(IsInGroup()), show(GetNumGroupMembers()))
    end

    local function startWatch(name, seconds)
        if not watchFrame then
            watchFrame = CreateFrame("Frame")
            watchFrame:SetScript("OnEvent", function(_, event, text)
                if not watch or GetTime() > watch.ends then
                    return
                end
                log("RECV", "rescind %s +%.1fs: %s %s | %s", watch.name, GetTime() - watch.at, event,
                    event == "CHAT_MSG_SYSTEM" and show(text) or "", groupState())
            end)
            for _, event in ipairs({ "CHAT_MSG_SYSTEM", "GROUP_ROSTER_UPDATE", "PARTY_INVITE_CANCEL",
                "GROUP_INVITE_CONFIRMATION" }) do
                pcall(watchFrame.RegisterEvent, watchFrame, event)
            end
        end
        watch = { name = name, at = GetTime(), ends = GetTime() + seconds }
    end

    function cmdRescind(rest)
        local name, mode = (rest or ""):match("^%s*(.-)%s*(expire)%s*$")
        name = name or (rest or ""):match("^%s*(.-)%s*$")
        if (not name or name == "") and UnitExists("target") and UnitIsPlayer("target") then
            -- Forever names have a space: UnitFullName gives the two parts.
            local first, second = UnitFullName("target")
            name = second and second ~= "" and (first .. " " .. second) or first
            log("INFO", "rescind: using your target, %s", show(name))
        end
        if not name or name == "" then
            log("FAIL", "rescind: target a player (or give a name): /fgp rescind [Name] [expire], not in a group")
            return
        end
        if IsInGroup() then
            log("FAIL", "rescind: leave your group first, so the invite is the only thing in it")
            return
        end
        local uninvite = resolve("C_PartyInfo.UninviteUnit") or _G.UninviteUnit
        log("INFO", "rescind: C_PartyInfo.UninviteUnit=%s UninviteUnit=%s", type(resolve("C_PartyInfo.UninviteUnit")),
            type(_G.UninviteUnit))
        startWatch(name, mode == "expire" and 180 or 15)
        local ok, err = pcall(C_PartyInfo.InviteUnit, name)
        log(ok and "INFO" or "FAIL", "rescind: invited %s -> %s %s | %s", name, show(ok), show(err), groupState())
        if mode == "expire" then
            log("INFO", "rescind: leaving the invite open; ask %s not to answer, logging for 3 minutes", name)
            return
        end
        if type(uninvite) ~= "function" then
            log("FAIL", "rescind: no UninviteUnit function")
            return
        end
        -- UninviteUnit is protected: from a timer it is blocked, so it waits
        -- for the first key press after 5 s.
        if not keyFrameRescind then
            keyFrameRescind = CreateFrame("Frame", "ForeverGroupsProbeRescindFrame", UIParent)
            pcall(keyFrameRescind.SetPropagateKeyboardInput, keyFrameRescind, true)
        end
        keyFrameRescind:SetScript("OnKeyDown", function()
            if GetTime() - watch.at < 5 then
                return
            end
            keyFrameRescind:EnableKeyboard(false)
            local okU, errU = pcall(uninvite, name)
            log(okU and "INFO" or "FAIL", "rescind: UninviteUnit(%s) on a key press %.1f s after the invite"
                .. " -> %s %s | %s", name, GetTime() - watch.at, show(okU), show(errU), groupState())
        end)
        keyFrameRescind:EnableKeyboard(true)
        log("INFO", "rescind: press any key after 5 s to take the invite back")
    end
end

local COMMANDS = {
    { "all", "run info, api, join, chan, whisper, big, ping and popup", cmdAll },
    { "info", "build, names, time, lockdown, group state", cmdInfo },
    { "api", "check which API functions exist", cmdApi },
    { "join", "[name] join and hide the probe channel", cmdJoin },
    { "leave", "leave the probe channel", cmdLeave },
    { "chan", "[text] addon message to the channel", cmdChannel },
    { "whisper", "[Name] [text] addon whisper (default: yourself)", cmdWhisper },
    { "party", "addon message to PARTY", cmdParty },
    { "ping", "PING on the channel, other probes answer by whisper", cmdPing },
    { "big", "255 and 256 byte addon whispers to yourself", cmdBig },
    { "burst", "[n] send n messages at once (throttle test, default 30)", cmdBurst },
    { "invite", "<Name> invite now (slash command = hardware event)", function(rest) cmdInvite(rest, 0) end },
    { "invitelater", "<Name> [s] invite from a timer (no hardware event)", function(rest) cmdInvite(rest, 3) end },
    { "tell", "<Name>[: text] plain chat whisper from a timer", cmdTell },
    { "popup", "[Name] proposal popup from a timer; Accept invites Name", cmdPopup },
    { "lfg", "info | search | searchlater | results  WoW group finder checks", cmdLfg },
    { "lfgapi", "[plain|heal|dps|tank|quest [id]|members|twice|gap] Group Finder functions, test searches",
        cmdLfgApi },
    { "quests", "quest log details (group size, elite, objectives) and Group Finder categories", cmdQuests },
    { "spec", "how the client tells your specialization (specs, talent trees)", cmdSpec },
    { "talents", "dump the talent tree: nodes, points spent, positions", cmdTalents },
    { "inspect", "[unit] read another player's talents (default: target, else party1)", cmdInspect },
    { "clicksearch", "[off] test Group Finder searches from mouse clicks and scrolls in the world", cmdClickSearch },
    { "loadscreens", "[page] show the loading screens (classic by name, Forever's by file id)", cmdLoadScreens },
    { "images", "[page] show the dungeon background pictures the client has", cmdImages },
    { "zonelevels", "level ranges of the Quests & Zones activities", cmdZoneLevels },
    { "dropdown", "show the dropdown styles this client has", cmdDropdown },
    { "chatfilter", "check that our own outgoing whispers can be hidden from chat", cmdChatFilter },
    { "classart", "[class] show the class art this client has (talent backgrounds, icons, atlases)", cmdClassArt },
    { "specart", "check the retail spec art atlases for every class", cmdSpecArt },
    { "finderart", "the art of the Group Finder's category buttons (open the Group Finder first)", cmdFinderArt },
    { "pvp", "battlegrounds: functions, the battlegrounds and the Group Finder's battleground activities", cmdPvp },
    { "mask", "draw art with rounded-corner mask candidates, to see which one fits the frames", cmdMask },
    { "raid", "as party leader outside an instance: turn the party into a raid and back, from a timer", cmdRaid },
    { "rescind", "[Name] [expire] invite your target (or Name), take it back on a key press after 5 s", cmdRescind },
    { "autoaccept", "[off] accept the next party invite by itself, without a click (10 min)", cmdAutoAccept },
    { "channels", "[name] member count of every joined channel (with a name: join it for the check)", cmdChannels },
    { "log", "[n] print the last n stored log lines", cmdLog },
    { "clear", "clear the stored log", cmdClear },
}

local function cmdHelp()
    print("|cffa0c8ffForever Groups Probe|r commands (results are saved in ForeverGroupsProbeDB):")
    for _, command in ipairs(COMMANDS) do
        print(string.format("  /fgp %s - %s", command[1], command[2]))
    end
end

SLASH_FOREVERGROUPSPROBE1 = "/fgp"
SLASH_FOREVERGROUPSPROBE2 = "/dqp"
SlashCmdList.FOREVERGROUPSPROBE = function(input)
    local name, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
    name = (name or ""):lower()
    for _, command in ipairs(COMMANDS) do
        if command[1] == name then
            store("CMD", "/fgp %s %s", name, rest)
            command[3](rest)
            return
        end
    end
    cmdHelp()
end

local function scheduleRecvSummary()
    if recvSummaryScheduled then
        return
    end
    recvSummaryScheduled = true
    C_Timer.After(4, function()
        recvSummaryScheduled = false
        local parts = {}
        for key, count in pairs(recvCounts) do
            parts[#parts + 1] = key .. "=" .. count
        end
        recvCounts = {}
        log("RECV", "burst received: %s", table.concat(parts, ", "))
    end)
end

local function onAddonMessage(event, prefix, text, chatType, sender, target, zoneChannelID, localID, chanName)
    if prefix ~= PREFIX then
        return
    end
    if isSecret(text) or isSecret(sender) then
        log("WARN", "%s: payload or sender is a secret value (chatType=%s)", event, show(chatType))
        return
    end
    local kind, arg = strsplit("|", text)
    if kind == "BURST" then
        local key = event .. ":" .. tostring(chatType)
        recvCounts[key] = (recvCounts[key] or 0) + 1
        scheduleRecvSummary()
        return
    end
    log("RECV", "%s %s from %s (me=%s) target=%s zone=%s local=%s chan=%s: %s (%d bytes)",
        event, show(chatType), show(sender), tostring(isMe(sender)), show(target), show(zoneChannelID),
        show(localID), show(chanName), show(kind == "BIG" and "BIG|..." or text), #text)
    if kind == "PING" and not isMe(sender) then
        sendAddon("PONG|" .. tostring(arg), "WHISPER", sender)
    elseif kind == "PONG" then
        local sentAt = pendingPings[arg]
        if sentAt then
            log("PASS", "ping: PONG %s from %s, round trip %.0f ms", arg, sender, (GetTime() - sentAt) * 1000)
        end
    end
end

local function onLoaded(_, name)
    if name ~= ADDON_NAME then
        return
    end
    ForeverGroupsProbeDB = ForeverGroupsProbeDB or {}
    db = ForeverGroupsProbeDB
    db.lines = db.lines or {}
    store("INFO", "==== session start, build: %s ====", showAll(GetBuildInfo()))
    local ok, ret = pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
    store(ok and "INFO" or "FAIL", "RegisterAddonMessagePrefix('%s') -> %s", PREFIX, ok and showAll(ret) or show(ret))
end

local function onLogin()
    log("INFO", "loaded. Type /fgp help, or /fgp all for the standard checks")
end

local function onChannelNotice(event, text, _, _, channelString, _, _, _, _, baseName)
    local ours = type(baseName) == "string" and not isSecret(baseName) and baseName:lower() == channelName:lower()
    local unusual = type(text) == "string" and not isSecret(text) and not ROUTINE_NOTICES[text]
    if ours or unusual or watchingChannels() then
        log("EVENT", "%s %s %s", event, show(text), show(channelString))
    end
end

local function onActionBlocked(event, addon, func)
    if raidTest then
        raidTest.blocked = tostring(func)
    end
    if autoAccept.pending then
        log("FAIL", "autoaccept: blocked (%s)", show(func))
    end
    if keySearch and keySearch.pending then
        keySearch.pending = false
        keySearch.blocked = keySearch.blocked + 1
    end
    if clickSearch.pending then
        clickResult(clickSearch.pending, "blocked")
        log("FAIL", "clicksearch: %s blocked", clickSearch.pending)
        clickSearch.pending = nil
    end
    log("FAIL", "%s addon=%s function=%s", event, show(addon), show(func))
end

-- Which window WoW shows for an invite (the plain popup, or one asking for
-- a role), the event's extra values, and the role functions there are.
local function describeInvitePopups(when)
    local popup = LFGInvitePopup
    local plain = type(StaticPopup_Visible) == "function" and StaticPopup_Visible("PARTY_INVITE")
    log("RECV", "invite %s: StaticPopup PARTY_INVITE=%s LFGInvitePopup=%s shown=%s", when, show(plain),
        type(popup), show(type(popup) == "table" and popup.IsShown and popup:IsShown()))
    if type(popup) == "table" and popup.GetChildren then
        for i, child in ipairs({ popup:GetChildren() }) do
            local name = child.GetName and child:GetName()
            local checked = child.checkButton and child.checkButton.GetChecked and child.checkButton:GetChecked()
            store("RECV", "LFGInvitePopup child %d: %s shown=%s checked=%s", i, show(name),
                show(child.IsShown and child:IsShown()), show(checked))
        end
    end
end

local function onInviteRequest(event, inviter, ...)
    log("RECV", "%s from %s, extra: %s", event, show(inviter), showAll(...))
    log("RECV", "role functions: SetLFGRoles=%s GetLFGRoles=%s UnitSetRole=%s LFGInvitePopup_Show=%s "
        .. "LFGInvitePopupAccept_OnClick=%s StaticPopupSpecial_Hide=%s", type(SetLFGRoles), type(GetLFGRoles),
        type(UnitSetRole), type(LFGInvitePopup_Show), type(LFGInvitePopupAccept_OnClick),
        type(StaticPopupSpecial_Hide))
    if type(GetLFGRoles) == "function" then
        log("RECV", "GetLFGRoles(): %s", showAll(pcall(GetLFGRoles)))
    end
    C_Timer.After(0.3, function()
        describeInvitePopups("after 0.3 s")
    end)
    tryAutoAccept(inviter)
end

local function onRoleEvent(event, ...)
    log("RECV", "%s: %s; my role %s", event, showAll(...), show(UnitGroupRolesAssigned("player")))
end

-- For 20 s after loading: the player's role as WoW tells it, and the role
-- the party frames show for the player, written down whenever either
-- changes, with the time to a tenth of a second.
local ROLE_WATCH_SECONDS = 20
local roleWatchStart = GetTime()
local lastRoleWatch

local function shownRole()
    local parts = {}
    for _, prefix in ipairs({ "CompactPartyFrameMember", "CompactRaidFrame" }) do
        for i = 1, 5 do
            local frame = _G[prefix .. i]
            local unit = frame and frame.unit
            if unit and UnitExists(unit) and UnitIsUnit(unit, "player") then
                local icon = frame.roleIcon
                local atlas = icon and icon.GetAtlas and icon:GetAtlas()
                local coords = icon and icon.GetTexCoord and table.concat({ icon:GetTexCoord() }, ",")
                parts[#parts + 1] = string.format("%s%d shown=%s atlas=%s coords=%s", prefix, i,
                    show(icon and icon:IsShown()), show(atlas), show(coords))
            end
        end
    end
    return #parts > 0 and table.concat(parts, "; ") or "no party frame for the player"
end

local roleWatch = CreateFrame("Frame")
roleWatch:SetScript("OnUpdate", function(self)
    local elapsed = GetTime() - roleWatchStart
    if elapsed > ROLE_WATCH_SECONDS then
        self:SetScript("OnUpdate", nil)
        store("INFO", "rolewatch: done after %d s", ROLE_WATCH_SECONDS)
        return
    end
    local now = string.format("role=%s ingroup=%s | %s", show(UnitGroupRolesAssigned("player")), show(IsInGroup()),
        shownRole())
    if now ~= lastRoleWatch then
        lastRoleWatch = now
        store("RECV", "rolewatch +%.1fs: %s", elapsed, now)
    end
end)

-- Who sets a role: every call of a role function, with the code that made
-- it (the Lua stack without this hook), for the whole session.
local function hookRoleSetter(path)
    local parent, key = path:match("^(.-)%.?([^%.]+)$")
    local owner = parent ~= "" and resolve(parent) or _G
    if type(owner) ~= "table" or type(owner[key]) ~= "function" or type(hooksecurefunc) ~= "function" then
        return
    end
    hooksecurefunc(owner, key, function(...)
        local stack = type(debugstack) == "function" and debugstack(2, 8, 0) or "no debugstack"
        stack = stack:gsub("\n", " <- ")
        store("RECV", "rolewatch +%.1fs: %s(%s) from %s", GetTime() - roleWatchStart, path, showAll(...), stack)
    end)
end

for _, path in ipairs({ "UnitSetRole", "SetLFGRoles", "C_LFGList.SetRoles", "C_PartyInfo.SetRole",
    "SetPVPRoles", "C_LFGList.SetRole" }) do
    hookRoleSetter(path)
end

local function onRoleChanged(event, ...)
    store("RECV", "rolewatch +%.1fs: %s %s; my role %s", GetTime() - roleWatchStart, event, showAll(...),
        show(UnitGroupRolesAssigned("player")))
end

local function onRoster()
    local size = GetNumGroupMembers()
    if size ~= lastGroupSize then
        lastGroupSize = size
        log("EVENT", "GROUP_ROSTER_UPDATE: %s members, leader=%s", show(size), show(UnitIsGroupLeader("player")))
    end
end

local function onSystem(_, text)
    if GetTime() <= watchSystemUntil then
        log("EVENT", "system: %s", show(text))
    end
end

local function onCombat(event)
    local lockdown = resolve("C_ChatInfo.InChatMessagingLockdown")
    log("EVENT", "%s, InChatMessagingLockdown=%s", event,
        type(lockdown) == "function" and showAll(lockdown()) or "missing")
end

local handlers = {
    ADDON_LOADED = onLoaded,
    PLAYER_LOGIN = onLogin,
    CHAT_MSG_ADDON = onAddonMessage,
    CHAT_MSG_ADDON_LOGGED = onAddonMessage,
    CHAT_MSG_CHANNEL_NOTICE = onChannelNotice,
    CHAT_MSG_CHANNEL_NOTICE_USER = onChannelNotice,
    CHAT_MSG_CHANNEL_LIST = onChannelList,
    CHANNEL_COUNT_UPDATE = onChannelCount,
    CHANNEL_ROSTER_UPDATE = onChannelCount,
    ADDON_ACTION_BLOCKED = onActionBlocked,
    ADDON_ACTION_FORBIDDEN = onActionBlocked,
    PARTY_INVITE_REQUEST = onInviteRequest,
    ROLE_POLL_BEGIN = onRoleEvent,
    LFG_ROLE_CHECK_SHOW = onRoleEvent,
    PLAYER_ROLES_ASSIGNED = onRoleEvent,
    ROLE_CHANGED_INFORM = onRoleChanged,
    GROUP_ROSTER_UPDATE = onRoster,
    CHAT_MSG_SYSTEM = onSystem,
    PLAYER_REGEN_DISABLED = onCombat,
    PLAYER_REGEN_ENABLED = onCombat,
    LFG_LIST_SEARCH_RESULTS_RECEIVED = onLfgResults,
    LFG_LIST_SEARCH_FAILED = onLfgFailed,
    LFG_LIST_APPLICATION_STATUS_UPDATED = onApplicationStatus,
    LFG_LIST_ACTIVE_ENTRY_UPDATE = onApplicationStatus,
    INSPECT_READY = onInspectReady,
    BATTLEFIELDS_SHOW = onBattlefieldsShow,
    BATTLEFIELDS_CLOSED = onBattlefieldsShow,
    PVPQUEUE_ANYWHERE_SHOW = onBattlefieldsShow,
    UPDATE_BATTLEFIELD_STATUS = onBattlefieldStatus,
}

local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", function(_, event, ...)
    local handler = handlers[event]
    if handler then
        handler(event, ...)
    end
end)
for event in pairs(handlers) do
    if not pcall(eventFrame.RegisterEvent, eventFrame, event) then
        unknownEvents[#unknownEvents + 1] = event
    end
end
