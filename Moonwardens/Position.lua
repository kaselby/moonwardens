-- Position: where I am (sent as P), where guildies are (received P / Q).
-- P|1|map|x|y|layer|flags|level   Q|1
-- flags: 1 = in combat, 2 = dead or ghost, 4 = data collection on.
local _, ns = ...
local Position = {}
ns.Position = Position

local MOVE_EVERY = 3      -- seconds between sends while moving
local STILL_EVERY = 15    -- seconds between sends while standing still
local STALE = 50          -- a dot with no news for this long is dropped
local MOVED = 0.0005      -- map fraction that counts as "moved" (about 3 yd in Ashenvale)

Position.FLAG_COMBAT, Position.FLAG_DEAD, Position.FLAG_DATA = 1, 2, 4

local guildies = {}       -- key -> { key, map, x, y, layer, flags, level, at }
local me = {}             -- { map, x, y, flags, layer }
local lastSent = { at = -100 }
local quiet = false       -- true after we sent Q (instance); next P ends it

---------------------------------------------------------------------------
-- Reading my own position
---------------------------------------------------------------------------
function Position.ReadMine()
    local map = ns.try(C_Map.GetBestMapForUnit, "player")
    if type(map) ~= "number" then return nil end
    local pos = ns.try(C_Map.GetPlayerMapPosition, map, "player")
    if not pos then return map end
    local x, y = ns.try(pos.GetXY, pos)
    if type(x) ~= "number" or type(y) ~= "number" then return map end
    return map, x, y
end

local function inInstance()
    local inside, kind = ns.try(IsInInstance)
    return inside == true and kind ~= "none"
end

local function myFlags()
    local f = 0
    if ns.try(UnitAffectingCombat, "player") == true then f = f + Position.FLAG_COMBAT end
    if ns.try(UnitIsDeadOrGhost, "player") == true then f = f + Position.FLAG_DEAD end
    if ns.db and ns.db.dataCollection then f = f + Position.FLAG_DATA end
    return f
end

local function myLayer(map)
    if ns.Layer and ns.Layer.Mine then return ns.Layer.Mine(map) or 0 end
    return 0
end

function Position.Me() return me end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------
local function sendQuiet(now)
    if quiet then return end
    quiet = true
    if now then ns.Comm.SendNow({ "Q", ns.Comm.PROTO }, "GUILD")
    else ns.Comm.Send({ "Q", ns.Comm.PROTO }, "GUILD", nil, "pos") end
end

-- Called every second. Sends when moved (at most every 3 s), on a zone or
-- flag change, or every 15 s when nothing changed.
function Position.Tick(force)
    if not IsInGuild() then return end
    if inInstance() then
        me.map, me.x, me.y = nil, nil, nil
        sendQuiet()
        return
    end
    local map, x, y = Position.ReadMine()
    if not (map and x and y) then return end
    local flags, layer = myFlags(), myLayer(map)
    me.map, me.x, me.y, me.flags, me.layer = map, x, y, flags, layer

    local since = ns.now() - lastSent.at
    local zoneChange = map ~= lastSent.map
    local changed = zoneChange or flags ~= lastSent.flags or layer ~= lastSent.layer
    local moved = lastSent.x and (math.abs(x - lastSent.x) > MOVED or math.abs(y - lastSent.y) > MOVED)
    local due = force or quiet or changed and since >= 1 or moved and since >= MOVE_EVERY or since >= STILL_EVERY
    if not due then return end

    local level = ns.try(UnitLevel, "player") or 0
    ns.Comm.Send({ "P", ns.Comm.PROTO, map, ("%.4f"):format(x), ("%.4f"):format(y), layer, flags, level },
        "GUILD", nil, "pos")
    quiet = false
    lastSent.at, lastSent.map, lastSent.x, lastSent.y = ns.now(), map, x, y
    lastSent.flags, lastSent.layer = flags, layer
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------
local function onP(f, sender, key)
    local map, x, y = tonumber(f[3]), tonumber(f[4]), tonumber(f[5])
    if not (map and x and y) or x < 0 or x > 1 or y < 0 or y > 1 then return end
    local g = guildies[key] or { key = key }
    g.map, g.x, g.y = map, x, y
    g.layer = tonumber(f[6]) or 0
    g.flags = tonumber(f[7]) or 0
    g.level = tonumber(f[8])
    g.at = ns.now()
    g.cache = nil              -- converted positions (MapWorld) are now old
    guildies[key] = g
    ns.fire("POSITION", key, g)
end

local function onQ(f, sender, key)
    if guildies[key] then
        guildies[key] = nil
        ns.fire("POSITION", key, nil)
    end
end

function Position.HasFlag(g, flag)
    return g.flags and math.floor(g.flags / flag) % 2 == 1
end

-- Live guildies (fresh, still in the guild, online). Iterate with pairs.
function Position.All()
    local t = ns.now()
    for key, g in pairs(guildies) do
        local m = ns.Roster.Get(key)
        if t - g.at > STALE or (ns.Roster.Loaded() and (not m or not m.online)) then
            guildies[key] = nil
        end
    end
    return guildies
end

function Position.Get(key) return guildies[key] end

function Position.CountInMyZone()
    if not me.map then return nil end
    local n = 0
    for _, g in pairs(Position.All()) do
        if g.map == me.map then n = n + 1 end
    end
    return n
end

---------------------------------------------------------------------------
-- Layers as seen through positions. A layer is a server number per zone;
-- its label is its rank among the numbers known in that zone, so everyone
-- with the same data sees the same "Layer 2".
---------------------------------------------------------------------------

-- Sorted list of { layer, n, mine } for a map, plus the unknown count.
function Position.LayersIn(map)
    local by, unknown = {}, 0
    local function add(layer, isMe)
        if not layer or layer == 0 then unknown = unknown + 1; return end
        local e = by[layer] or { layer = layer, n = 0 }
        e.n = e.n + 1
        if isMe then e.mine = true end
        by[layer] = e
    end
    for _, g in pairs(Position.All()) do
        if g.map == map then add(g.layer) end
    end
    if me.map == map then add(me.layer, true) end
    local list = {}
    for _, e in pairs(by) do list[#list + 1] = e end
    table.sort(list, function(a, b) return a.layer < b.layer end)
    for i, e in ipairs(list) do e.label = "Layer " .. i end
    return list, unknown
end

function Position.LayerLabel(map, layer)
    if not layer or layer == 0 then return nil end
    for _, e in ipairs(Position.LayersIn(map)) do
        if e.layer == layer then return e.label end
    end
end

-- How a guildie's layer relates to mine: "same", "other", "unknown", or
-- "na" (other zone, or no layer detector yet: drawn solid).
function Position.Relation(g)
    if not ns.Layer or g.map ~= me.map then return "na" end
    if not g.layer or g.layer == 0 or not me.layer or me.layer == 0 then return "unknown" end
    return g.layer == me.layer and "same" or "other"
end

-- Tooltip lines for one guildie (world map and minimap share them).
function Position.AddTooltip(tt, g)
    local m = ns.Roster.Get(g.key) or {}
    local r, gg, b = ns.classColor(m.classFile)
    tt:AddLine(m.name or g.key, r, gg, b)
    local level = g.level or m.level
    local desc = ("Level %s %s %s"):format(level or "?", m.race or "", m.class or "")
    tt:AddLine((desc:gsub("%s+", " ")), 1, 1, 1)
    if m.rank then
        local guild = ns.try(GetGuildInfo, "player")
        tt:AddLine(type(guild) == "string" and ("<%s> %s"):format(guild, m.rank) or m.rank, 0.25, 1, 0.25)
    end
    if Position.HasFlag(g, Position.FLAG_DEAD) then tt:AddLine("Dead", 0.62, 0.62, 0.62)
    elseif Position.HasFlag(g, Position.FLAG_COMBAT) then tt:AddLine("In combat", 1, 0.25, 0.25) end
    local rel = Position.Relation(g)
    local label = Position.LayerLabel(g.map, g.layer)
    if rel == "same" then tt:AddLine((label or "Layer") .. " (same as you)", 0.75, 0.75, 0.75)
    elseif rel == "other" then tt:AddLine((label or "Layer") .. " (not yours)", 0.75, 0.75, 0.75)
    elseif rel == "unknown" then tt:AddLine("Layer not known yet", 0.62, 0.62, 0.62) end
    local age = ns.now() - g.at
    if age > 20 then tt:AddLine(("last seen %d s ago"):format(age), 0.62, 0.62, 0.62) end
end

ns.onLogin(function()
    ns.Comm.handlers.P = onP
    ns.Comm.handlers.Q = onQ
    ns.every(1, function() Position.Tick() end, "position")
    ns:On("ZONE_CHANGED_NEW_AREA", function() ns.after(1, function() Position.Tick(true) end, "position zone") end)
    -- Loading screen or logout: drop my dot now; PLAYER_ENTERING_WORLD brings it back.
    ns:On("PLAYER_LEAVING_WORLD", function() sendQuiet(true) end)
    ns:On("PLAYER_ENTERING_WORLD", function() ns.after(3, function() Position.Tick(true) end, "position enter") end)
end, "position")

ns.slash.where = { help = "where guildies with the addon are", fn = function()
    local n, zones = 0, {}
    for _, g in pairs(Position.All()) do
        n = n + 1
        local info = ns.try(C_Map.GetMapInfo, g.map)
        local name = type(info) == "table" and info.name or tostring(g.map)
        zones[name] = (zones[name] or 0) + 1
    end
    ns.print(("%d guildies with the addon are sharing their position."):format(n))
    for z, c in pairs(zones) do ns.print(("  %s: %d"):format(z, c)) end
end }
