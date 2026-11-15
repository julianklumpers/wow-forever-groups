local _, ns = ...

local Levels = ns.Levels
local Log = ns.Log

-- "Limit levels" on the Dungeons and Quests tabs, under "Lead a group": the
-- lowest and highest level of the players joining, the same for every
-- ticked dungeon or quest (core/levels.lua). Switched on with
-- charDb.levelsOn; switched off it is kept for next time. Each side is at
-- first a default (the lowest and highest level of the ticked dungeons, on
-- the Quests tab or with none ticked the player's level three either way);
-- a level the player types stays (charDb.levelLimit) until they empty the
-- box. It counts while the player builds the group: it goes with the queue
-- entry, and the filler, the quest finder and applicants only take players
-- within it, for as long as the queue entry holds (untilAt 0). A player who
-- whispers has no known level; once in the group, one outside the limit is
-- pointed out.
local PartyLevels = {}

local MAX_LEVEL = 60

local TABS = { dungeons = "wantsLead", quests = "wantsLeadQuests" }

local function clamp(level)
    return math.max(1, math.min(MAX_LEVEL, level))
end

-- The typed levels, { min, max }, nil for a side left at its default.
local function typed()
    local saved = ns.charDb.levelLimit
    if type(saved) ~= "table" or saved.at ~= nil then
        saved = {}
        ns.charDb.levelLimit = saved
    end
    return saved
end

local function tickedDungeons()
    local entry = ns.engine and ns.engine.myEntry
    if entry and entry.dungeons then
        return entry.dungeons
    end
    local W = ns.WindowParts
    return W and W.selectedVisibleIds and W.selectedVisibleIds() or {}
end

-- During PLAYER_LEVEL_UP, UnitLevel still gives the old level; the event
-- brings the new one.
local reachedLevel = 0

local function playerLevel()
    return math.max(UnitLevel("player") or 1, reachedLevel)
end

local function defaults(tab, dungeons)
    if tab ~= "quests" then
        local low, high
        for _, id in ipairs(dungeons or tickedDungeons()) do
            local dungeon = ns.Dungeons.get(id)
            if dungeon and dungeon.min then
                low = math.min(low or dungeon.min, dungeon.min)
                high = math.max(high or dungeon.max, dungeon.max)
            end
        end
        if low then
            return low, high
        end
    end
    local mine = playerLevel()
    return clamp(mine - 3), clamp(mine + 3)
end

-- { min, max } on this tab ("dungeons" or "quests"), and which sides the
-- player typed: { min = true, max = true }. A default never crosses a typed
-- side. dungeons: the ones being joined, when not the queued or ticked ones.
function PartyLevels.limit(tab, dungeons)
    local own = typed()
    local low, high = defaults(tab, dungeons)
    local limit = { min = own.min or low, max = own.max or high }
    if limit.min > limit.max then
        if own.min and not own.max then
            limit.max = limit.min
        else
            limit.min = limit.max
        end
    end
    return limit, { min = own.min ~= nil, max = own.max ~= nil }
end

function PartyLevels.isOn()
    return ns.charDb.levelsOn == true
end

function PartyLevels.setOn(on)
    ns.charDb.levelsOn = on and true or nil
    PartyLevels.apply()
end

-- A typed level; nothing (or 0) puts the side back to its default. The
-- lowest is never above the highest.
function PartyLevels.set(side, level)
    local own = typed()
    level = tonumber(level)
    own[side] = level and level > 0 and clamp(math.floor(level)) or nil
    if own.min and own.max and own.min > own.max then
        if side == "min" then
            own.max = own.min
        else
            own.min = own.max
        end
    end
    PartyLevels.apply()
end

-- Whether the player builds the group on this tab ("dungeons", "quests").
-- shown: as the window shows it (PartyCompose.isBuilder).
function PartyLevels.isBuilder(tab, shown)
    local state = shown and ns.Party.shownState() or ns.Party.state()
    return TABS[tab] ~= nil and (state == "leader" or (state == "solo" and ns.charDb[TABS[tab]] == true))
end

-- dungeons: the ones being joined (ns.join), else the queued or ticked ones.
function PartyLevels.wireText(tab, dungeons)
    if not PartyLevels.isOn() or not PartyLevels.isBuilder(tab) then
        return nil
    end
    local limit = PartyLevels.limit(tab, dungeons)
    return Levels.encode({ untilAt = 0, min = limit.min, max = limit.max })
end

local function engineOf(tab)
    return (tab == "dungeons" and ns.engine) or (tab == "quests" and ns.questEngine) or nil
end

-- The limit in force now on this tab, or nil.
function PartyLevels.rules(tab)
    local text = PartyLevels.wireText(tab)
    return text and Levels.active(text, GetServerTime()) or nil
end

-- A player who joined outside the limit (whispered, or invited by hand) is
-- pointed out once. The party there when the limit began counts as fixed;
-- alone, that is nobody, so the first to join is checked too.
local known

local function limited()
    return PartyLevels.rules("dungeons") or PartyLevels.rules("quests")
end

-- The party's names, or nil while some name is not loaded yet.
local function partyNames()
    local members = ns.Party.members()
    if not members then
        return nil
    end
    local names = {}
    for _, member in ipairs(members) do
        names[member.name] = true
    end
    return names
end

-- Called whenever the limit may have begun or ended, and after loading: who
-- is there then counts as fixed (alone: nobody).
local function noteStart()
    if not limited() then
        known = nil
    elseif not known then
        known = IsInGroup() and partyNames() or (not IsInGroup() and {}) or nil
    end
end

-- Puts the limit on both queue entries (or on the next ones).
function PartyLevels.apply()
    noteStart()
    for tab in pairs(TABS) do
        local engine = engineOf(tab)
        if engine then
            engine:setLevels(PartyLevels.wireText(tab))
        end
    end
end

-- The ticked dungeons whose level range has no level within the limit:
-- { { name, min, max } }.
function PartyLevels.outside(dungeonIds)
    local saved = PartyLevels.limit("dungeons")
    local list = {}
    for _, id in ipairs(dungeonIds or {}) do
        local dungeon = ns.Dungeons.get(id)
        if dungeon and dungeon.min and not Levels.overlaps(saved, dungeon.min, dungeon.max) then
            list[#list + 1] = { name = ns.Dungeons.name(id), min = dungeon.min, max = dungeon.max }
        end
    end
    return list
end

local function checkParty()
    local rules = limited()
    if not rules then
        known = nil
        return
    end
    if not known then
        -- Right after a /reload in a party: everyone there was there before.
        known = partyNames()
        return
    end
    for _, member in ipairs(ns.Party.members() or {}) do
        local level = tonumber(member.level)
        if level and level > 0 and not known[member.name] then
            known[member.name] = true
            if not Levels.fits(rules, level) then
                Log.info("%s is level %d, outside your level limit.", member.name, level)
            end
        end
    end
end

function PartyLevels.init()
    ns.on("PLAYER_LEVEL_UP", function(level)
        reachedLevel = tonumber(level) or reachedLevel
        PartyLevels.apply()
    end)
    ns.on("GROUP_ROSTER_UPDATE", function()
        checkParty()
        PartyLevels.apply()
    end)
    ns.on("PLAYER_ENTERING_WORLD", noteStart)
end

ns.PartyLevels = PartyLevels
