-- Position: where I am (sent as P), where guildies are (received P / Q).
-- P|1|map|x|y|layer|flags|level   Q|1
-- PQ|1: "where is everyone?" (sent after a login or /reload), answered with a P.
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
local replyPending = false -- a PQ answer is on its way
local lastHeardAt = -100   -- when the last P arrived

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
    lastHeardAt = g.at
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

---------------------------------------------------------------------------
-- Guildies in my party/raid. The game already draws group members on the
-- world map and minimap, so our dots for them are hidden (no double dots)
-- and come back as soon as they leave the group. Names use the same
-- "First Surname" key as everything else (see ns.key).
---------------------------------------------------------------------------
local grouped = {}

-- "first surname" key of the player behind a unit token, or nil.
local function unitKey(unit)
    local first, last = ns.try(UnitName, unit)
    if type(first) ~= "string" then return nil end
    if type(last) == "string" and ns.readable(last) and last ~= "" then first = first .. " " .. last end
    local key = ns.key(first)
    if key and key ~= ns.meKey then return key end
end

local function rebuildGroup()
    local fresh = {}
    local n = ns.try(GetNumGroupMembers) or 0
    if n > 0 then
        local raid = ns.try(IsInRaid) == true
        local prefix = raid and "raid" or "party"
        for i = 1, raid and n or (n - 1) do
            local key = unitKey(prefix .. i)
            if key then fresh[key] = true end
        end
    end
    grouped = fresh
end

function Position.InMyGroup(key) return grouped[key] == true end

---------------------------------------------------------------------------
-- Seen in the world. If I can see a guildie (their nameplate, my target or
-- mouseover), we are on the same layer whatever the NPC detectors say right
-- now: their dot is drawn as "same" instead of "unknown".
---------------------------------------------------------------------------
local SEEN_FOR = 30            -- seconds a sighting counts
local seenAt = {}              -- key -> time I last saw them

local function noteSeen(unit)
    if ns.try(UnitIsPlayer, unit) ~= true then return end
    local key = unitKey(unit)
    if not (key and ns.Roster.Get(key)) then return end
    seenAt[key] = ns.now()
end

local function scanPlayerPlates()
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
    local plates = ns.try(C_NamePlate.GetNamePlates)
    if type(plates) ~= "table" then return end
    for _, plate in ipairs(plates) do
        local u = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
        if u then noteSeen(u) end
    end
    -- A guildie kept as target or focus stays "seen" (no event while held).
    noteSeen("target"); noteSeen("focus")
end

function Position.SeenRecently(key)
    local at = seenAt[key]
    return at ~= nil and ns.now() - at <= SEEN_FOR
end

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

-- Guildies in a zone by how their layer relates to mine: { label, n, mine,
-- keys, sub } for "Your layer" (me too) and "Another layer", plus the
-- unknown count and keys. There are no layer numbers to tell layers apart any
-- more (build 71037), so other layers aren't split: "Another layer" may be
-- several. `sub`: how many of them are only leads ("2 probable").
-- Another zone than mine: everyone there is unknown to me.
function Position.LayersIn(map)
    -- Agreed numbers (LayerLink.lua): "Layer 1", "Layer 2"..., mine marked.
    if ns.LayerLink and ns.LayerLink.LayersOf then
        local layers, loose = ns.LayerLink.LayersOf(map)
        local myN = (me.map == map) and ns.LayerLink.MyLabel() or nil
        local list = {}
        for _, e in ipairs(layers) do
            list[#list + 1] = { label = ("Layer %d%s"):format(e.n, e.n == myN and " - yours" or ""), n = #e.keys,
                keys = e.keys, mine = e.n == myN, sub = e.leads > 0 and (e.leads .. " probable") or "" }
        end
        -- (only once some are agreed: before that, "Your layer" / "Another
        -- layer" below, from what's known of each guildie)
        if #list > 0 then return list, #loose, loose end
    end
    local yours = { label = "Your layer", n = 0, keys = {}, mine = true, leads = 0 }
    local other = { label = "Another layer", n = 0, keys = {}, leads = 0 }
    local unknown, unknownKeys = 0, {}
    for key, g in pairs(Position.All()) do
        if g.map == map then
            local rel, sure = Position.Relation(g)
            local e = rel == "same" and yours or rel == "other" and other or nil
            if e then
                e.n = e.n + 1
                e.keys[#e.keys + 1] = key
                if not sure then e.leads = e.leads + 1 end
            else
                unknown = unknown + 1
                unknownKeys[#unknownKeys + 1] = key
            end
        end
    end
    local list = {}
    if me.map == map and ns.meKey then
        yours.n = yours.n + 1
        yours.keys[#yours.keys + 1] = ns.meKey
        list[#list + 1] = yours
    elseif yours.n > 0 then
        list[#list + 1] = yours
    end
    if other.n > 0 then list[#list + 1] = other end
    for _, e in ipairs(list) do e.sub = e.leads > 0 and (e.leads .. " probable") or "" end
    return list, unknown, unknownKeys
end

-- (Layer numbers have no labels any more: kept for older callers.)
function Position.LayerLabel() return nil end

-- How a guildie's layer relates to mine: "same", "other", "unknown", or
-- "na" (other zone, or no layer detector yet: drawn solid).
-- A second result says whether it's proven (true) or only a lead (false).
-- Layer numbers decide where the game still gives a shared one (before build
-- 71037); evidence between players (LayerLink.lua) everywhere else.
function Position.Relation(g)
    if not ns.Layer or g.map ~= me.map then return "na" end
    if Position.SeenRecently(g.key) then return "same", true end -- seeing them proves it
    if not (ns.Layer.Private and ns.Layer.Private()) then
        local mine = myLayer(me.map)
        if g.layer and g.layer ~= 0 and mine ~= 0 then return g.layer == mine and "same" or "other", true end
    end
    if ns.LayerLink then
        local rel, sure = ns.LayerLink.Relation(g)
        if rel then return rel, sure end
    end
    return "unknown"
end

-- A guildie's layer as a line of text: the agreed number (LayerLink.lua)
-- when there is one, "your layer" when it's mine; else the relation.
function Position.LayerText(g)
    local LL = ns.LayerLink
    local n, lead, map
    if LL then n, lead, map = LL.Label(g.key) end
    if n then
        local mine = map == me.map and LL.MyLabel() == n
        return ("Layer %d%s%s"):format(n, lead and "?" or "", mine and " - your layer" or ""), mine
    end
    return Position.RelationText(Position.Relation(g))
end

-- How a relation reads in tooltips and lists.
function Position.RelationText(rel, sure)
    if rel == "same" then return sure and "Your layer" or "Probably your layer" end
    if rel == "other" then return sure and "Another layer" or "Probably another layer" end
    if rel == "unknown" then return "Layer not known yet" end
end

-- Is a profile's class just the game's class? totalRP3 fills a new profile's
-- class with it, so everyone with TRP installed "has" one. Either gender's
-- name counts (some locales have both).
local function isRealClass(custom, m)
    local c = custom:lower()
    if m.class and c == m.class:lower() then return true end
    local f = m.classFile
    if not f then return false end
    for _, names in pairs({ LOCALIZED_CLASS_NAMES_MALE, LOCALIZED_CLASS_NAMES_FEMALE }) do
        if type(names) == "table" and type(names[f]) == "string" and c == names[f]:lower() then return true end
    end
    return false
end

-- Tooltip lines for one guildie (world map and minimap share them).
function Position.AddTooltip(tt, g)
    local m = ns.Roster.Get(g.key) or {}
    local r, gg, b = ns.classColor(m.classFile)
    -- totalRP3 profile (RP.lua; each part only when its setting is on and the
    -- profile has it): custom colour, name, race, and class with the real one
    -- after it in brackets. Same lines otherwise.
    local rpName, rpRace, rpClass, rpHex
    if ns.RP then
        local cr, cg, cb = ns.RP.Color(g.key)
        if cr then
            r, gg, b = cr, cg, cb
            rpHex = ("%02x%02x%02x"):format(math.floor(cr * 255 + 0.5), math.floor(cg * 255 + 0.5), math.floor(cb * 255 + 0.5))
        end
        rpName, rpRace, rpClass = ns.RP.Identity(g.key)
        if rpClass and isRealClass(rpClass, m) then rpClass = nil end   -- (no "Rogue (Rogue)")
    end
    -- With either RP setting on, the real class is always in its class colour:
    -- on its own, or in brackets after a custom class (which is in the custom
    -- colour, as TRP does). Both settings off: white, as before.
    local class = m.class
    if m.class and ns.db and (ns.db.rpColors or ns.db.rpNames) then
        local kr, kg, kb = ns.classColor(m.classFile)
        class = ("|cff%02x%02x%02x%s|r"):format(math.floor(kr * 255 + 0.5),
            math.floor(kg * 255 + 0.5), math.floor(kb * 255 + 0.5), m.class)
    end
    if rpClass then
        local custom = rpHex and ("|cff%s%s|r"):format(rpHex, rpClass) or rpClass
        class = class and ("%s (%s)"):format(custom, class) or custom
    end
    tt:AddLine(rpName or m.name or g.key, r, gg, b)
    local level = g.level or m.level
    local desc = ("Level %s %s %s"):format(level or "?", rpRace or m.race or "", class or "")
    tt:AddLine((desc:gsub("%s+", " ")), 1, 1, 1)
    if m.rank then
        local guild = ns.try(GetGuildInfo, "player")
        tt:AddLine(type(guild) == "string" and ("<%s> %s"):format(guild, m.rank) or m.rank, 0.25, 1, 0.25)
    end
    if Position.HasFlag(g, Position.FLAG_DEAD) then tt:AddLine("Dead", 0.62, 0.62, 0.62)
    elseif Position.HasFlag(g, Position.FLAG_COMBAT) then tt:AddLine("In combat", 1, 0.25, 0.25) end
    local text = Position.LayerText(g)
    if text then tt:AddLine(text, 0.75, 0.75, 0.75) end
    local age = ns.now() - g.at
    if age > 20 then tt:AddLine(("last seen %d s ago"):format(age), 0.62, 0.62, 0.62) end
end

ns.onLogin(function()
    ns.Comm.handlers.P = onP
    ns.Comm.handlers.Q = onQ
    rebuildGroup()
    ns:On("GROUP_ROSTER_UPDATE", rebuildGroup)
    -- Names can read as unknown for a moment after someone joins; recheck.
    ns.every(2, rebuildGroup, "group members")
    -- (seen in the world: only for layers - off, ns.LAYERS, not looked for)
    if ns.LAYERS then
        ns:On("NAME_PLATE_UNIT_ADDED", function(unit) noteSeen(unit) end)
        ns:On("UPDATE_MOUSEOVER_UNIT", function() noteSeen("mouseover") end)
        ns:On("PLAYER_TARGET_CHANGED", function() noteSeen("target") end)
        ns.every(5, scanPlayerPlates, "player plates")
    end
    ns.every(1, function() Position.Tick() end, "position")
    ns:On("ZONE_CHANGED_NEW_AREA", function() ns.after(1, function() Position.Tick(true) end, "position zone") end)
    -- Loading screen or logout: drop my dot now; PLAYER_ENTERING_WORLD brings it back.
    ns:On("PLAYER_LEAVING_WORLD", function() sendQuiet(true) end)
    ns:On("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
        -- After a login or /reload: ask everyone where they are at once,
        -- instead of waiting up to STILL_EVERY s for each one's next P (OpenMap
        -- does the same with its hello, answered with a place). Our own place
        -- goes out now too; the usual 3 s / 15 s sends carry on from there.
        -- (The queue holds both while the game won't let addons send yet.)
        if isLogin or isReload then
            local askedAt = ns.now()
            ns.Comm.Send({ "PQ", ns.Comm.PROTO }, "GUILD")
            -- Once more if nobody answered: just after a fresh login the game can
            -- say we're in no guild yet, and the queue drops guild messages then.
            ns.after(4, function()
                if lastHeardAt < askedAt then ns.Comm.Send({ "PQ", ns.Comm.PROTO }, "GUILD") end
            end, "position ask again")
        end
        Position.Tick(true)
        ns.after(1, function() Position.Tick(true) end, "position enter")   -- (if the map wasn't readable yet)
    end)
    ns.Comm.handlers.PQ = function()
        -- Answer once: a burst of asks (several logins) is one reply. A short
        -- jitter keeps the guild's replies from landing in the same instant.
        if replyPending then return end
        replyPending = true
        ns.after(math.random() * 0.3, function()
            replyPending = false
            Position.Tick(true)
        end, "position reply")
    end
    -- Across a /reload: the dots we had come back at once (the game keeps
    -- nothing of ours through one). Only fresh ones, ageing on from where they were.
    local c = ns.db and ns.db.posCache
    ns.db.posCache = nil
    if type(c) == "table" and type(c.at) == "number" and type(c.list) == "table" then
        local gap = time() - c.at
        if gap >= 0 and gap < STALE then
            for key, e in pairs(c.list) do
                local age = gap + (tonumber(e.age) or STALE)
                if type(e) == "table" and age < STALE and e.map and e.x and e.y and not guildies[key] then
                    guildies[key] = { key = key, map = e.map, x = e.x, y = e.y, layer = e.layer or 0,
                        flags = e.flags or 0, level = e.level, at = ns.now() - age }
                end
            end
        end
    end
    ns:On("PLAYER_LOGOUT", function()
        local list, now = {}, ns.now()
        for key, g in pairs(guildies) do
            list[key] = { map = g.map, x = g.x, y = g.y, layer = g.layer, flags = g.flags, level = g.level, age = now - g.at }
        end
        ns.db.posCache = { at = time(), list = list }
    end)
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

-- /mw test mapdots on: three online guildies placed around me (one in
-- combat on my layer, one on another, one unknown), so the dots, tooltip and
-- panel can be checked alone; kept there until /mw test mapdots off (or
-- until they send a position of their own).
local testDots, testTicker
local function clearTestDots()
    if testTicker then testTicker:Cancel(); testTicker = nil end
    for key in pairs(testDots or {}) do guildies[key] = nil end
    testDots = nil
end
ns.tests.mapdots = { dev = true, usage = "on | off", help = "three test guildie dots around you on the maps", fn = function(arg)
    arg = (arg or ""):lower()
    if arg == "off" then
        local had = testDots ~= nil
        clearTestDots()
        ns.print(had and "test dots off." or "no test dots to take away.")
        return
    end
    if arg ~= "on" then
        ns.print(("test dots are %s. /mw test mapdots on | off"):format(testDots and "on" or "off"))
        return
    end
    clearTestDots()
    local map, x, y = Position.ReadMine()
    if not (map and x) then ns.print("can't read your position here.") return end
    local picks = {}
    for key, m in pairs(ns.Roster.All()) do
        if m.online and key ~= ns.meKey and #picks < 3 then picks[#picks + 1] = key end
    end
    if #picks == 0 then ns.print("no other guildies online to borrow for the test.") return end
    local spots = { { 0.01, 0 }, { -0.008, 0.008 }, { 0, -0.012 } }
    local myL = me.layer and me.layer > 0 and me.layer or 1
    local layers = { myL, myL + 1, 0 }
    testDots = {}
    for i, key in ipairs(picks) do
        guildies[key] = { key = key, map = map, x = x + spots[i][1], y = y + spots[i][2],
            layer = layers[i], flags = i == 1 and Position.FLAG_COMBAT or 0, at = ns.now() }
        testDots[key] = guildies[key]
    end
    -- (kept fresh until turned off; one that sends a real position is theirs again)
    testTicker = C_Timer.NewTicker(10, function()
        for key, g in pairs(testDots or {}) do
            if guildies[key] == g then g.at = ns.now() else testDots[key] = nil end
        end
    end)
    ns.print(("test dots: %d guildies placed around you on the world map and minimap, until /mw test mapdots off."):format(#picks))
end }
