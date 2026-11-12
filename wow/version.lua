local addonName, ns = ...

local Log = ns.Log

-- Clients tell each other their Forever Groups version, so players with an old
-- one are asked to update.
local Version = {}

-- Deliberately outside the "v1|" protocol: a client that only speaks an old
-- protocol must still understand that a newer one exists.
local PREFIX = "DQV|"
local CONFIRMATIONS = 2

local mine
local reported = {}
local warned

local function parse(text)
    if type(text) ~= "string" or #text > 16 or not string.find(text, "^%d+[%.%d]*$") then
        return nil
    end
    local parts = {}
    for n in string.gmatch(text, "%d+") do
        parts[#parts + 1] = tonumber(n)
    end
    return parts
end

-- -1, 0 or 1 like a comparator; nil when either is not a version.
function Version.compare(a, b)
    local pa, pb = parse(a), parse(b)
    if not pa or not pb then
        return nil
    end
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then
            return x < y and -1 or 1
        end
    end
    return 0
end

function Version.mine()
    if mine == nil then
        local ok, value = pcall(C_AddOns.GetAddOnMetadata, addonName, "Version")
        mine = ok and parse(value) and value or false
    end
    return mine or nil
end

local function announcement()
    return PREFIX .. Version.mine() .. "|" .. ns.Protocol.VERSION
end

-- The newest version at least CONFIRMATIONS different players run, so one
-- player announcing a made-up version cannot make everyone see a warning.
local function confirmedNewer()
    local newer = {}
    for _, report in pairs(reported) do
        if Version.compare(report.version, Version.mine()) == 1 then
            newer[#newer + 1] = report
        end
    end
    if #newer < CONFIRMATIONS then
        return nil
    end
    table.sort(newer, function(a, b)
        return Version.compare(a.version, b.version) == 1
    end)
    return newer[CONFIRMATIONS]
end

-- { version, protocolChanged } when a newer version is out, else nil.
function Version.newer()
    local stored = ns.db and ns.db.newestVersion
    if stored and Version.compare(stored.version, Version.mine()) == 1 then
        return stored
    end
    return nil
end

local function warn(newest)
    if warned == newest.version then
        return
    end
    warned = newest.version
    if newest.protocolChanged then
        Log.warn("Forever Groups %s is out and talks differently; you have %s, so you cannot be matched with players "
            .. "who updated. Please update Forever Groups.", newest.version, Version.mine())
    else
        Log.warn("Forever Groups %s is out (you have %s). Please update so matchmaking keeps working well.",
            newest.version, Version.mine())
    end
end

local function check()
    local report = confirmedNewer()
    if not report then
        return
    end
    local newest = { version = report.version, protocolChanged = report.protocol ~= ns.Protocol.VERSION }
    local stored = Version.newer()
    if not stored or Version.compare(newest.version, stored.version) >= 0 then
        ns.db.newestVersion = newest
    end
    warn(Version.newer())
end

-- From the Forever Groups channel; returns true when the message was ours.
function Version.onMessage(sender, text)
    if string.sub(text, 1, #PREFIX) ~= PREFIX then
        return false
    end
    local version, protocol = string.match(text, "^DQV|([%d%.]+)|(%w+)$")
    local order = Version.compare(version, Version.mine())
    if not order then
        return true
    end
    reported[sender] = { version = version, protocol = protocol }
    if order == 1 then
        check()
    elseif order == -1 then
        -- An older client learns it is behind from the announcement every
        -- client answers a newcomer with (wow/presence.lua).
        ns.Presence.newcomer()
    end
    return true
end

-- Once connected: announce the own version, and repeat an earlier warning.
function Version.onReady()
    local stored = ns.db.newestVersion
    if stored and not Version.newer() then
        ns.db.newestVersion = nil
    end
    if Version.newer() then
        warn(Version.newer())
    end
    Version.announce()
end

-- Tells the channel this client's version; also how others see it is online.
function Version.announce()
    if Version.mine() and ns.Comm.selfName then
        ns.Comm.send(announcement())
    end
end

ns.Version = Version
