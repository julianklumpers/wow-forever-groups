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
        lead = entry.lead,
        lastSeen = now,
        updatedAt = now,
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

-- Keeps an entry alive without a heartbeat (fake test players).
function Queue:keep(id, now)
    local entry = self.entries[id]
    if entry then
        entry.lastSeen, entry.updatedAt = now, now
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

-- An entry lives on its own heartbeats only: other messages from the same
-- player (its other queues, keep-alives) prove the player is online, not
-- that it still waits in this queue.
function Queue:expire(now, keepId)
    local removed = {}
    for id, entry in pairs(self.entries) do
        if id ~= keepId and now - (entry.updatedAt or entry.lastSeen) > self.timeout then
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

-- Sorted once per change to the entries; callers only read the list.
function Queue:list()
    if self.listVersion ~= self.version then
        local list = {}
        for _, entry in pairs(self.entries) do
            list[#list + 1] = entry
        end
        self.sorted, self.listVersion = Matchmaker.sortByPriority(list), self.version
    end
    return self.sorted
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
