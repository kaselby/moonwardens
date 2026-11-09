-- Layer: which layer I'm on in this zone, from creature GUIDs.
--
-- A layer is the server field of a real NPC's GUID
-- (Creature-0-SERVER-map-zoneUID-npc-spawn), per zone. The zoneUID field is
-- per client and is never used. Player-controlled creatures (pets, totems,
-- guardians) carry other players' server numbers, so they don't count.
-- A new value needs sightings of two different NPCs. Forgotten on zone
-- change, on SHARD_TRANSFER, and after 10 minutes without a sighting.
-- Ported from LayerLab's detector (zqxtjb), with those fixes.
local _, ns = ...
local Layer = {}
ns.Layer = Layer

local MAX_AGE = 600
local NEED = 2                 -- distinct NPC GUIDs to accept a new layer

local state = {}               -- { map, layer, at, n }
local cand = {}                -- { layer, guids = {}, n }
local mapAt, mapNow = -10, nil
local stats = { seen = 0, used = 0, pets = 0 }

local function currentMap()
    local t = ns.now()
    if t - mapAt > 1 then
        mapAt = t
        local m = ns.try(C_Map.GetBestMapForUnit, "player")
        mapNow = type(m) == "number" and m or nil
    end
    return mapNow
end

local function reset(why)
    local had = state.layer
    state, cand = {}, {}
    mapAt = -10
    if had then ns.fire("LAYER", nil, had, nil, why) end
end

local function fresh()
    return state.layer and ns.now() - state.at <= MAX_AGE
end

-- My layer's server number in `map`, or 0 when not known.
function Layer.Mine(map)
    if state.layer and not fresh() then reset("stale") end
    if state.layer and state.map == map then return state.layer end
    return 0
end

function Layer.State() return state end

-- One GUID seen. Returns true if it counted toward the layer.
function Layer.Observe(guid, src)
    if type(guid) ~= "string" or not ns.readable(guid) then return end
    stats.seen = stats.seen + 1
    local kind, _, server = strsplit("-", guid)
    if kind ~= "Creature" and kind ~= "Vehicle" then return end
    server = tonumber(server)
    if not server or server == 0 then return end
    local map = currentMap()
    if not map then return end
    if state.map and state.map ~= map then reset("zone") end
    if state.layer and not fresh() then reset("stale") end
    stats.used = stats.used + 1

    if server == state.layer then
        state.at, state.n = ns.now(), state.n + 1
        cand = {}
        return true
    end
    if cand.layer ~= server then cand = { layer = server, guids = {}, n = 0 } end
    if not cand.guids[guid] then
        cand.guids[guid] = true
        cand.n = cand.n + 1
    end
    if cand.n >= NEED then
        local from = state.layer
        state = { map = map, layer = server, at = ns.now(), n = cand.n }
        cand = {}
        ns.fire("LAYER", map, from, server, src)
    end
    return true
end

local function observeUnit(unit, src)
    if ns.try(UnitExists, unit) ~= true then return end
    if ns.try(UnitPlayerControlled, unit) == true then stats.pets = stats.pets + 1; return end
    Layer.Observe(ns.try(UnitGUID, unit), src)
end
Layer.ObserveUnit = observeUnit

function Layer.ScanPlates()
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
    local plates = ns.try(C_NamePlate.GetNamePlates)
    if type(plates) ~= "table" then return end
    for _, plate in ipairs(plates) do
        local u = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
        if u then observeUnit(u, "plate") end
    end
end

-- No combat log: 12.x removed COMBAT_LOG_EVENT_UNFILTERED for addons, LayerLab
-- never got one sighting from it on Forever, and registering it is the likely
-- cause of the ADDON_ACTION_FORBIDDEN "UNKNOWN()" seen with 0.3.0 (11-09).

-- "Layer 2 (7075)" for the minimap button tooltip.
function Layer.TooltipLine()
    local map = currentMap()
    local mine = map and Layer.Mine(map) or 0
    if mine == 0 then return "Your layer: not known yet (target or pass a few NPCs)", 0.62, 0.62, 0.62 end
    local label = ns.Position.LayerLabel(map, mine) or "Layer"
    return ("Your layer: %s  |cff9d9d9d(%d)|r"):format(label, mine), 0.4, 0.8, 1
end

ns.onLogin(function()
    ns:On("NAME_PLATE_UNIT_ADDED", function(unit) observeUnit(unit, "plate") end)
    ns:On("UPDATE_MOUSEOVER_UNIT", function() observeUnit("mouseover", "mouse") end)
    ns:On("PLAYER_TARGET_CHANGED", function() observeUnit("target", "target") end)
    ns:On("PLAYER_FOCUS_CHANGED", function() observeUnit("focus", "focus") end)
    ns:On("PLAYER_SOFT_ENEMY_CHANGED", function() observeUnit("softenemy", "soft") end)
    ns:On("PLAYER_SOFT_FRIEND_CHANGED", function() observeUnit("softfriend", "soft") end)
    ns:On("PLAYER_SOFT_INTERACT_CHANGED", function() observeUnit("softinteract", "soft") end)
    ns:On("ZONE_CHANGED_NEW_AREA", function() reset("zone") end)
    ns:On("PLAYER_ENTERING_WORLD", function() reset("loading") end)
    ns:On("SHARD_TRANSFER", function() reset("shard transfer") end)
    ns.every(2, Layer.ScanPlates, "nameplate scan")
end, "layer")

ns.slash.layer = { help = "your layer in this zone and how it was found", fn = function()
    local map = currentMap()
    local mine = map and Layer.Mine(map) or 0
    if mine == 0 then
        ns.print("your layer here isn't known yet. Target, mouse over or pass near a few NPCs.")
    else
        ns.print(("you are on %s here (server number %d), confirmed by %d sightings, last %d s ago."):format(
            ns.Position.LayerLabel(map, mine) or "a layer", mine, state.n, ns.now() - state.at))
    end
    if cand.layer then ns.print(("  a different number (%d) was seen %d time(s); two NPCs are needed to switch."):format(cand.layer, cand.n)) end
    ns.print(("  GUIDs read %d, used %d, player-controlled skipped %d. Layers are experimental."):format(stats.seen, stats.used, stats.pets))
end }
