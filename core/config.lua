local _, ns = ...
ns = ns or {}

local Config = {
    HEARTBEAT_INTERVAL = 45,
    ENTRY_TIMEOUT = 120,
    RESTORE_WINDOW = 900,
    WARMUP = 10,
    MATCH_INTERVAL = 5,
    -- One matchmaking round as a client sees it: a Forever Groups player who
    -- may fit is given this long before the Group Finder fills their place.
    MATCH_ROUND = 9,
    ALIVE_INTERVAL = 10,
    ALIVE_TIMEOUT = 25,
    ALIVE_RANKS = 3,
    ACK_TIMEOUT = 10,
    PROPOSAL_TIMEOUT = 30,
    PROPOSAL_GRACE = 5,
    ANSWER_RESEND = 8,
    CONFLICT_PAUSE = 15,
    SYNC_JITTER = 5,
    FINISHED_RETENTION = 120,
    MAX_PREMADE = 4,
    PARTIAL_GROUPS = true,
    PARTIAL_AFTER = 0,
    PARTIAL_MIN_PLAYERS = 2,
    -- A group gets varied classes while its longest waiting player has
    -- waited less than this, or Forever Groups builds it this long (Fill.avoided).
    VARIETY_TIME = 300,
    SLOTS = { T = 1, H = 1, D = 3 },
}

function Config.with(overrides)
    local result = {}
    for key, value in pairs(Config) do
        if type(value) ~= "function" then
            result[key] = value
        end
    end
    for key, value in pairs(overrides or {}) do
        result[key] = value
    end
    return result
end

ns.Config = Config
return Config
