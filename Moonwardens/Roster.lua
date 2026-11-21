-- Roster: guild member cache. Rank, class, level, online, race (via GUID).
local _, ns = ...
local Roster = {}
ns.Roster = Roster

local members = {}   -- key -> member
local count, loaded = 0, false
local raceCache = {} -- guid -> { race, raceFile } (survives roster rebuilds)
local lastBuild = -10

-- Short race names for the Stats bars (Krylea, 11-09).
Roster.RACE_SHORT = { ["High Order Skyborne"] = "Skyborne" }

Roster.OFFICER_RANKS = { ["Glaivemistress"] = true, ["High Council"] = true, ["Warden-General"] = true }

local function raceOf(guid)
    if not guid then return nil end
    local c = raceCache[guid]
    if c then return c[1], c[2] end
    local _, _, race, raceFile = ns.try(GetPlayerInfoByGUID, guid)
    if type(race) == "string" and race ~= "" then
        raceCache[guid] = { race, raceFile }
        return race, raceFile
    end
end

function Roster.Build()
    lastBuild = ns.now()
    local n = ns.try(GetNumGuildMembers) or 0
    local fresh, c = {}, 0
    for i = 1, n do
        local name, rank, rankIndex, level, class, zone, _, _, online, _, classFile, _, _, _, _, _, guid =
            ns.try(GetGuildRosterInfo, i)
        local key = ns.key(name)
        if key then
            local race, raceFile = raceOf(guid)
            fresh[key] = {
                key = key, name = name, address = ns.address(name), rank = rank, rankIndex = rankIndex,
                level = level, class = class, classFile = classFile, zone = zone,
                online = online and true or false, guid = guid, race = race, raceFile = raceFile,
            }
            c = c + 1
        end
    end
    if c > 0 then
        members, count, loaded = fresh, c, true
        if ns.fire then ns.fire("ROSTER") end
    end
end

function Roster.Get(key) return members[key] end

-- The game's club member info for a guildie: what the guild roster's rows
-- hold (name, guid, level, zone, rank, note, presence...), and the guild's
-- club id. Nil when the game hasn't got them. (Their member ids, by key,
-- are kept and looked up again on a miss.)
local memberIds = {}
function Roster.ClubMember(key)
    if not (key and C_Club and C_Club.GetGuildClubId) then return nil end
    local club = ns.try(C_Club.GetGuildClubId)
    if not club then return nil end
    local id = memberIds[key]
    local info = id and ns.try(C_Club.GetMemberInfo, club, id)
    if type(info) == "table" and type(info.name) == "string" and ns.key(info.name) == key then return info, club end
    info = nil
    memberIds = {}
    for _, mid in ipairs(ns.try(C_Club.GetClubMembers, club) or {}) do
        local i = ns.try(C_Club.GetMemberInfo, club, mid)
        local k = type(i) == "table" and type(i.name) == "string" and ns.key(i.name)
        if k then
            memberIds[k] = mid
            if k == key then info = i end
        end
    end
    if info then return info, club end
end
function Roster.All() return members end
function Roster.Count() return count end
function Roster.Loaded() return loaded end

-- Before the first roster arrives we can't tell; accept rather than drop the
-- first seconds of positions. After that, the roster decides.
function Roster.IsMember(key)
    if not loaded then return true end
    return members[key] ~= nil
end

function Roster.IsOfficer(key)
    local m = members[key]
    return m and Roster.OFFICER_RANKS[m.rank] or false
end

-- Counts for the Stats tab. onlineOnly limits to members online now.
function Roster.Stats(onlineOnly)
    local s = { total = 0, online = 0, max = 0, race = {}, class = {}, level = {}, unknownRace = 0 }
    for _, m in pairs(members) do
        if m.online then s.online = s.online + 1 end
        if not onlineOnly or m.online then
            s.total = s.total + 1
            local lvl = tonumber(m.level) or 0
            if lvl >= 60 then s.max = s.max + 1 end
            local band = lvl >= 60 and 7 or math.floor(lvl / 10) + 1
            s.level[band] = (s.level[band] or 0) + 1
            if m.classFile then
                local e = s.class[m.classFile] or { n = 0, label = m.class or m.classFile, file = m.classFile }
                e.n = e.n + 1
                s.class[m.classFile] = e
            end
            if m.raceFile or m.race then
                local rk = m.raceFile or m.race
                local e = s.race[rk] or { n = 0, label = Roster.RACE_SHORT[m.race] or m.race or rk }
                e.n = e.n + 1
                s.race[rk] = e
            else
                s.unknownRace = s.unknownRace + 1
            end
        end
    end
    return s
end

ns.onLogin(function()
    local function request() if IsInGuild() then ns.try(C_GuildInfo.GuildRoster) end end
    ns:On("GUILD_ROSTER_UPDATE", function()
        if ns.now() - lastBuild > 2 then Roster.Build() end
    end)
    request()
    ns.every(60, request, "roster request")
    -- Races fill in over the first minutes as the GUID cache warms up.
    ns.every(20, function() if loaded then Roster.Build() end end, "roster race fill")
end, "roster")
