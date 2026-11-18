local _, ns = ...
ns = ns or {}

-- How far a player's zone is from a dungeon, in zones: the dungeon's own
-- zone is step 0, the zones bordering it step 1, and so on over the zones
-- that border each other (wow/zonemap.lua reads the borders from WoW's map).
-- A player further away waits a little before an invite, so that someone
-- closer who shows up in the meantime goes first.
local Zones = {}

-- Seconds a player waits per step beyond the first ring.
Zones.STEP_WAIT = 15

-- graph: { [zone] = { [neighbour] = true } }; starts: the dungeon's own
-- zones. Returns { [zone] = steps } and the most steps of any zone reached.
function Zones.steps(graph, starts)
    local steps, ring, most = {}, {}, 0
    for _, zone in ipairs(starts) do
        if steps[zone] == nil then
            steps[zone] = 0
            ring[#ring + 1] = zone
        end
    end
    while #ring > 0 do
        local nextRing = {}
        for _, zone in ipairs(ring) do
            for other in pairs(graph[zone] or {}) do
                if steps[other] == nil then
                    steps[other] = steps[zone] + 1
                    most = math.max(most, steps[other])
                    nextRing[#nextRing + 1] = other
                end
            end
        end
        ring = nextRing
    end
    return steps, most
end

-- Seconds a player at `steps` waits after showing up: none in the dungeon's
-- zone and the ring around it, STEP_WAIT for each step further, and for a
-- player on another continent or in a zone not on the map (steps nil) one
-- step after the furthest ring (most).
function Zones.wait(steps, most)
    if steps == nil then
        return Zones.STEP_WAIT * math.max(1, most or 0)
    end
    return Zones.STEP_WAIT * math.max(0, steps - 1)
end

-- Seconds left before a player may be invited: the wait counts from when
-- they showed up or, when that was earlier, from when the search started.
function Zones.waitLeft(steps, most, shownAt, startedAt, now)
    local from = math.max(shownAt or now, startedAt or now)
    return math.max(0, Zones.wait(steps, most) - (now - from))
end

-- For ordering: steps, with another continent or an unknown zone after the
-- furthest ring.
function Zones.rank(steps, most)
    return steps or ((most or 0) + 1)
end

ns.Zones = Zones
return Zones
