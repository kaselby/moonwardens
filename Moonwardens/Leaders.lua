-- Leaders: the Horde's faction leaders slain - Thrall (Orgrimmar), Cairne
-- Bloodhoof (Thunder Bluff), Sylvanas Windrunner (Undercity) - for Bane of
-- the Horde (Badges.lua, series "leaders"). A death counts for me when any
-- of these holds:
--  * my party or raid landed the killing blow (PARTY_KILL names its victim;
--    told by a guildie: they're in my group now);
--  * I was in that leader's seat in their city as they died (within AREA_R
--    of where they stand, Leaders.AREAS, or in its subzone: Grommash Hold,
--    the High Rise, the Royal Quarter);
--  * I saw them (their nameplate, my target, mouseover or focus) in the
--    SEEN_FOR seconds before they died.
-- How a death is known, with no combat log on 12.x: my group's killing blow
-- (PARTY_KILL), or one of them seen dead (a nameplate, target, mouseover or
-- focus - looked at every second while I'm in their city). Whoever knows
-- tells the guild, once (LK|1|npc|spawn|time|how; how "k": their group's
-- kill, "s": seen dead), and each guildie's client asks the three things
-- above of itself. A death counts once - by its spawn (the GUID's last
-- part, new each respawn) - however many tell it. Kept with the captures
-- (Captures.Credit: db.objectiveCaptures), claimed as they are.
local _, ns = ...
local Leaders = {}
ns.Leaders = Leaders

local AREA_R = 7             -- (map percent) this near where they stand is "there"
local SEEN_FOR = 300         -- seen this long before they die still counts
local GRACE = 10             -- (s) around the moment of death
local FRESH = 300            -- a death told this long after is old news
local SPAN_GAP = 3
local SPANS_KEPT = 6

-- Their creature ids, where they stand (uiMap, x, y in percent) and the
-- subzone(s) of their seat, as the game may name it. (Coordinates:
-- Classic's; check in game.)
Leaders.AREAS = {
    [4949]  = { name = "Thrall", map = 1454, x = 31.6, y = 37.8, sub = { "Grommash Hold" } },
    [3057]  = { name = "Cairne Bloodhoof", map = 1456, x = 60.3, y = 51.7, sub = { "High Rise", "The High Rise" } },
    [10181] = { name = "Sylvanas Windrunner", map = 1458, x = 57.8, y = 91.6, sub = { "Royal Quarter", "The Royal Quarter" } },
}
local AREAS = Leaders.AREAS
local UNITS = { "target", "focus", "mouseover" }
for i = 1, 40 do UNITS[#UNITS + 1] = "nameplate" .. i end

local seenAt = {}            -- npc -> server time I last saw them
local spans = {}             -- npc -> { { from, to }, ... } times I was in their seat
local counted = {}           -- "npc:spawn" -> true: counted for me (this session)
local told = {}              -- "npc:spawn" -> true: told the guild, or heard told

local function serverNow() return ns.try(GetServerTime) or time() end

-- A creature's id and spawn from its GUID (Creature-0-server-map-zone-id-spawn).
local function npcOf(guid)
    if type(guid) ~= "string" or not ns.readable(guid) then return end
    local kind, _, _, _, _, id, spawn = strsplit("-", guid)
    if kind ~= "Creature" then return end
    id = tonumber(id)
    if id and AREAS[id] and spawn then return id, spawn end
end

local function noteInside(npc, t)
    local list = spans[npc] or {}
    spans[npc] = list
    local last = list[#list]
    if last and t - last.to <= SPAN_GAP then last.to = t
    else
        list[#list + 1] = { from = t, to = t }
        if #list > SPANS_KEPT then table.remove(list, 1) end
    end
end

local function wasThere(npc, t)
    for _, s in ipairs(spans[npc] or {}) do
        if s.from <= t + GRACE and s.to >= t - GRACE then return true end
    end
    return false
end

local function sawBefore(npc, t)
    local at = seenAt[npc]
    return at ~= nil and at <= t + GRACE and at >= t - SEEN_FOR
end

local function inMyGroup(key) return ns.Position and ns.Position.InMyGroup and ns.Position.InMyGroup(key) or false end

-- A leader's death, at `t`: known here (`from` nil) or told by guildie `from`.
local function died(npc, spawn, t, how, from)
    local L = AREAS[npc]
    if not L then return end
    local key = npc .. ":" .. spawn
    if not from and not told[key] then
        told[key] = true
        ns.Comm.Send({ "LK", ns.Comm.PROTO, npc, spawn, t, how }, "GUILD")
    end
    if counted[key] then return end
    local mine = (how == "k" and (not from or inMyGroup(from))) or wasThere(npc, t) or sawBefore(npc, t)
    if not mine then return end
    counted[key] = true
    if ns.Captures and ns.Captures.Credit then
        ns.Captures.Credit("leaders", key, L.name, t, "Bane of the Horde! A leader of the Horde has fallen:")
    end
end

-- A unit in view: one of them? Seen; and dead, a death.
local function look(unit)
    local npc, spawn = npcOf(ns.try(UnitGUID, unit))
    if not npc then return end
    local now = serverNow()
    seenAt[npc] = now
    if ns.try(UnitIsDead, unit) == true then died(npc, spawn, now, "s") end
end

-- Every second: in one of their cities, whether I'm in their seat, and who
-- of them is in view.
local function tick()
    local map = ns.try(C_Map.GetBestMapForUnit, "player")
    local here
    for npc, L in pairs(AREAS) do if L.map == map then here = npc end end
    if not here then return end
    local L, t = AREAS[here], serverNow()
    local inside = false
    local subzone = ns.try(GetSubZoneText)
    for _, name in ipairs(L.sub or {}) do if subzone == name then inside = true end end
    if not inside then
        local pos = ns.try(C_Map.GetPlayerMapPosition, map, "player")
        local ok, x, y = false, nil, nil
        if pos then ok, x, y = pcall(pos.GetXY, pos) end
        if ok and type(x) == "number" and ns.readable(x) then
            local dx, dy = L.x - x * 100, L.y - y * 100
            inside = dx * dx + dy * dy <= AREA_R * AREA_R
        end
    end
    if inside then noteInside(here, t) end
    for _, u in ipairs(UNITS) do look(u) end
end

local function onPartyKill(_, victim)
    local npc, spawn = npcOf(victim)
    if npc then died(npc, spawn, serverNow(), "k") end
end

local function onLK(f, sender, key)
    local npc, spawn, t, how = tonumber(f[3]), f[4], tonumber(f[5]), f[6]
    if not (npc and AREAS[npc] and t and type(spawn) == "string" and #spawn <= 16 and spawn:match("^%x+$")) then return end
    if how ~= "k" and how ~= "s" then return end
    if math.abs(serverNow() - t) > FRESH then return end
    told[npc .. ":" .. spawn] = true
    died(npc, spawn, t, how, key)
end

ns.onLogin(function()
    ns.Comm.handlers.LK = onLK
    ns:On("PARTY_KILL", onPartyKill)
    ns:On("NAME_PLATE_UNIT_ADDED", function(unit) look(unit) end)
    ns:On("PLAYER_TARGET_CHANGED", function() look("target") end)
    ns:On("UPDATE_MOUSEOVER_UNIT", function() look("mouseover") end)
    ns.every(1, tick, "faction leaders")
end, "faction leaders")
