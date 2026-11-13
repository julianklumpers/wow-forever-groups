local _, ns = ...

local Log = ns.Log

-- A member of a group whose leader has no Forever Groups can offer to take
-- the lead: a whisper asks the leader to promote them, and once they lead,
-- Forever Groups fills the group's open places.
local TakeLead = {}

local ASK_VALID = 600

local askedAt, askedLeader

local function leaderName()
    for _, unit in ipairs({ "party1", "party2", "party3", "party4" }) do
        if UnitExists(unit) and UnitIsGroupLeader(unit) then
            return ns.Party.unitName(unit)
        end
    end
end

local function forget()
    askedAt, askedLeader = nil, nil
end

-- The leader to ask, or nil when the offer does not apply: only for a member
-- of a dungeon group with open places whose leader has no Forever Groups.
function TakeLead.leader()
    if ns.Party.state() ~= "member" or not ns.GroupView.trackedDungeon() or not ns.Messages.isOn("askLead") then
        return nil
    end
    if ns.GroupView.composition().open == "" then
        return nil
    end
    local leader = leaderName()
    if leader and not ns.Presence.isOnline(leader) then
        return leader
    end
end

function TakeLead.isAsked()
    return askedAt ~= nil and GetTime() - askedAt < ASK_VALID and askedLeader == leaderName()
end

function TakeLead.ask()
    local leader = TakeLead.leader()
    if not leader or TakeLead.isAsked() then
        return false
    end
    local dungeon = ns.GroupView.trackedDungeon()
    local text = ns.Messages.text("askLead", {
        roles = ns.Widgets.describeRolesEnglish(ns.GroupView.composition().open),
        dungeon = ns.Dungeons.englishName(dungeon),
    })
    if not text or not ns.Whispers.send(leader, text) then
        return false
    end
    askedAt, askedLeader = GetTime(), leader
    Log.info("Asked %s to make you leader. Once you lead, Forever Groups fills the group.", leader)
    return true
end

local function onRosterUpdate()
    if not askedAt then
        return
    end
    if GetTime() - askedAt >= ASK_VALID or not IsInGroup() then
        forget()
    elseif ns.Party.state() == "leader" then
        forget()
        ns.Run.fillGroup()
    end
    ns.Window.refresh()
end

function TakeLead.init()
    ns.on("GROUP_ROSTER_UPDATE", onRosterUpdate)
    ns.on("PARTY_LEADER_CHANGED", onRosterUpdate)
end

ns.TakeLead = TakeLead
