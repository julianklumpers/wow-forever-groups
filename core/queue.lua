local _, ns = ...
ns = ns or {}

local Matchmaker = ns.Matchmaker or require("core.matchmaker")

local Queue = {}
Queue.__index = Queue

-- version goes up on every change to the entries (not on touch), so views
-- built from the queue can tell when to rebuild.
function Queue.new(timeout)
    return setmetatable({ entries = {}, timeout = timeout, version = 0 }, Queue)
end

function Queue:upsert(entry, now)
    local copy = {
        id = entry.id,
        joinedAt = entry.joinedAt,
        dungeons = entry.dungeons,
        members = entry.members,
        reserved = entry.reserved or "",
        since = entry.since or entry.joinedAt,
        playstyle = entry.playstyle or 0,
        spec = entry.spec,
        lastSeen = now,
    }
    self.entries[entry.id] = copy
    self.version = self.version + 1
    return copy
end

function Queue:touch(id, now)
    local entry = self.entries[id]
    if entry then
        entry.lastSeen = now
    end
end

function Queue:get(id)
    return self.entries[id]
end

function Queue:remove(id)
    local entry = self.entries[id]
    if entry then
        self.entries[id] = nil
        self.version = self.version + 1
    end
    return entry
end

function Queue:expire(now, keepId)
    local removed = {}
    for id, entry in pairs(self.entries) do
        if id ~= keepId and now - entry.lastSeen > self.timeout then
            removed[#removed + 1] = id
        end
    end
    table.sort(removed)
    for _, id in ipairs(removed) do
        self.entries[id] = nil
    end
    if #removed > 0 then
        self.version = self.version + 1
    end
    return removed
end

function Queue:list()
    local list = {}
    for _, entry in pairs(self.entries) do
        list[#list + 1] = entry
    end
    return Matchmaker.sortByPriority(list)
end

function Queue:ids()
    local ids = {}
    for id in pairs(self.entries) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    return ids
end

ns.Queue = Queue
return Queue
