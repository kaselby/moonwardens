-- Layer: which layer I'm on in this zone, from creature GUIDs.
--
-- A layer is the server field of a real NPC's GUID
-- (Creature-0-SERVER-map-zoneUID-npc-spawn), per zone. The zoneUID field is
-- per client and is never used. Player-controlled creatures (pets, totems,
-- guardians) carry other players' server numbers, so they don't count.
-- Ported from LayerLab's detector (zqxtjb), then from LayerSwap 1.14.40
-- (Adam5288), whose live measurements on Forever these rules follow:
--
--  * Sources: nameplates (as they appear, and scanned every second), target,
--    mouseover, focus, soft targets, the NPC you talk to (gossip, vendor,
--    quest), and NPC speech (say/yell/emote carry the speaker's GUID, and an
--    NPC is only heard on its own layer). The game now gives most creature
--    GUIDs only through nameplates, hence the next point.
--  * Nameplates shown for a moment (Blink, below) when the layer is needed
--    and nothing in view gives it: at login, a zone border, a landing, or
--    when asked (Layer.Want). Not when LayerSwap is loaded: it does the
--    same at the same moments, and we read its nameplates as they appear.
--  * Votes: the last 5 creatures (each GUID once). Nothing known: 1 creature
--    gives a provisional layer, a second agreeing one confirms it, two of
--    another number correct it. A confirmed layer changes only when 3 of
--    the last 5 agree on another number (patrols from the next zone can't
--    flip it).
--  * A layer move (SHARD_TRANSFER) or loading screen: creatures in view at
--    that moment may be the layer just left, so they're ignored for 10 s;
--    one new creature decides after 3 s. The layer is kept until then.
--  * A zone border: the layer is forgotten; creatures in view at the border
--    are ignored for 15 s, and in that time nothing is believed on one
--    creature, and nameplates (which may be the zone left behind) aren't read.
--  * Forgotten after 10 minutes without a sighting.
local _, ns = ...
local Layer = {}
ns.Layer = Layer

local MAX_AGE = 600
local VOTES = 5                -- creatures remembered for a vote
local STALE_FOR = 10           -- creatures in view at a move are ignored this long
local SHARD_QUIET = 3          -- after a move, one creature new in view decides
local BORDER_QUIET = 15        -- after a zone border: nothing on one creature, no nameplates
local NEAR = { "softinteract", "softfriend", "softenemy", "npc", "focus" }

local state = {}               -- { map, layer, at, n, single }
local votes, voted = {}, {}    -- last VOTES server numbers (one per GUID); GUIDs counted
local stale, border            -- { untilAt, guids } in view at the last move / zone border
local lastShardAt, borderAt = -1000, -1000
local mapAt, mapNow = -10, nil
local stats = { seen = 0, used = 0, pets = 0, speech = 0, blinks = 0 }
-- Recheck mode: after a loading screen, shard transfer or group change we
-- may (or may not) have been moved. The layer is kept rather than wiped (a
-- wipe shows every guildie as "unknown" until new NPCs turn up), and the
-- first creature that settles it, confirms or replaces it.
local recheck = false
local lastEvent                -- { why, at, kind = "reset" | "recheck" } for /mw layer

local function currentMap()
    local t = ns.now()
    if t - mapAt > 1 then
        mapAt = t
        local m = ns.try(C_Map.GetBestMapForUnit, "player")
        mapNow = type(m) == "number" and m or nil
    end
    return mapNow
end

local function guidOf(unit)
    local g = ns.try(UnitGUID, unit)
    if type(g) == "string" then return g end
end

-- GUIDs in view now (nameplates, target, mouseover) and those voted with.
local function inView()
    local guids = {}
    for g in pairs(voted) do guids[g] = true end
    for i = 1, 40 do
        local g = guidOf("nameplate" .. i)
        if g then guids[g] = true end
    end
    for _, u in ipairs({ "target", "mouseover" }) do
        local g = guidOf(u)
        if g then guids[g] = true end
    end
    return guids
end

local function forgetVotes() votes, voted = {}, {} end

local function reset(why)
    local had = state.layer
    state = {}
    forgetVotes()
    recheck = false
    mapAt = -10
    lastEvent = { why = why, at = ns.now(), kind = "reset" }
    if had then ns.fire("LAYER", nil, had, nil, why) end
end

-- Keep the layer, but let the next creature settle it. Nameplates are
-- rescanned shortly after, since NAME_PLATE_UNIT_ADDED won't fire again for
-- plates that were already up. `moved`: the game may have moved us, so what
-- is in view now may be the layer left (ignored STALE_FOR s).
local function softReset(why, moved)
    if moved then
        stale = { untilAt = ns.now() + STALE_FOR, guids = inView() }
        lastShardAt = ns.now()
    end
    mapAt = -10
    forgetVotes()
    if state.layer then recheck = true end
    lastEvent = { why = why, at = ns.now(), kind = state.layer and "recheck" or "reset" }
    for _, delay in ipairs({ 0.5, 2, 5 }) do
        ns.after(delay, function() if Layer.ScanPlates then Layer.ScanPlates() end end, "layer rescan")
    end
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

-- From game build 71037 every creature carries a number of its own: the
-- server part no longer names a layer (LayerSwap 1.14.41, measured on live
-- Forever, 20 Nov 2026). Then layers come from LayerLink.lua instead.
local private
function Layer.Private()
    if private == nil then
        private = false
        local ok, _, build = pcall(GetBuildInfo)
        if ok and (tonumber(build) or 0) >= 71037 then private = true end
    end
    return private
end

local function inBorderQuiet() return ns.now() - borderAt < BORDER_QUIET end

local function setLayer(map, server, n, src)
    local from = state.layer
    state = { map = map, layer = server, at = ns.now(), n = n, single = (n == 1) or nil }
    recheck = false
    if from ~= server then ns.fire("LAYER", map, from, server, src) end
    if Layer.BlinkDone then Layer.BlinkDone() end
end

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
    local now = ns.now()
    if stale and now < stale.untilAt and stale.guids[guid] then return end
    if border and now < border.untilAt and border.guids[guid] then return end
    stats.used = stats.used + 1
    -- One creature may decide: not just after a move (SHARD_QUIET) or a border.
    local calm = now - lastShardAt >= SHARD_QUIET and not inBorderQuiet()

    if voted[guid] then
        -- Seen before, when one wasn't enough (just after a move or border): it is now.
        if state.layer == server then state.at = now; recheck = false
        elseif (not state.layer or recheck) and calm then setLayer(map, server, 1, src) end
        return true
    end
    voted[guid] = true
    votes[#votes + 1] = server
    if #votes > VOTES then table.remove(votes, 1) end
    local count = 0
    for _, v in ipairs(votes) do if v == server then count = count + 1 end end

    if server == state.layer then
        state.at, state.n = now, state.n + 1
        if state.single and count >= 2 then state.single = nil end   -- a second creature agrees
        recheck = false
        return true
    end
    local need
    if not state.layer or recheck then need = calm and 1 or 2
    elseif state.single then need = 2          -- a provisional layer is put right by two
    else need = 3 end                          -- a confirmed one by a majority of the last five
    if count >= need then setLayer(map, server, count, src) end
    return true
end

local function observeUnit(unit, src)
    if ns.try(UnitExists, unit) ~= true then return end
    if ns.try(UnitPlayerControlled, unit) == true then stats.pets = stats.pets + 1; return end
    Layer.Observe(guidOf(unit), src)
end
Layer.ObserveUnit = observeUnit

function Layer.ScanPlates()
    if inBorderQuiet() then return end          -- (may be the zone left behind)
    for i = 1, 40 do
        local u = "nameplate" .. i
        if ns.try(UnitExists, u) == true then observeUnit(u, "plate") end
    end
end

local function scanNear()
    for _, u in ipairs(NEAR) do observeUnit(u, "near") end
end

-- No combat log: 12.x removed COMBAT_LOG_EVENT_UNFILTERED for addons, LayerLab
-- never got one sighting from it on Forever, and registering it is the likely
-- cause of the ADDON_ACTION_FORBIDDEN "UNKNOWN()" seen with 0.3.0 (11-09).

---------------------------------------------------------------------------
-- Blink: nameplates shown for a moment to read the layer (LayerSwap 1.14.40,
-- same moments and timings). Only the settings that are off are switched on
-- (enemies, friendly NPCs, all), and friendly players' off while 20 or more
-- of theirs crowd the 40 plates the game shows. Each is put back as it was,
-- and only while it still stands as we set it, the moment the layer is read
-- or after FLASH_FOR s; kept in MoonwardensDB.platesBack until then, so a
-- game that closes meanwhile is put right at the next login.
-- When: the layer is needed (login once the world is drawn, a zone border
-- once its quiet is over, 1 s after a landing, Layer.Want), it
-- isn't known, and nothing in view gave it. Never in combat, a group, an
-- instance, on a flight path or listed in the group finder; within 3 s of a
-- move; more than once in FLASH_EVERY s; or while LayerSwap is loaded. A
-- need lapses after WANT_FOR s. A login's showing that saw no creature
-- plate (the world not drawn yet) is tried again 3 s later, three in a row,
-- then a minute after the first, for up to POLL_FOR s.
---------------------------------------------------------------------------
local PLATES = { "nameplateShowEnemies", "nameplateShowFriendlyNPCs", "nameplateShowAll" }
local HIDE, CROWD = "nameplateShowFriendlyPlayers", 20
local FLASH_FOR, FLASH_EVERY = 3, 12
local FLASH_BURST, FLASH_RETRY = 3, 3
local WANT_FOR, LAND_WAIT, POLL_FOR = 20, 1, 240
local wanted                   -- { why, at, from, try, burst }
local flash                    -- { at, why, try, burst, seen }
local flashLast = -1000
local onTaxi = false
local loginAt

local function layerSwapLoaded()
    local f = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
    return f and ns.try(f, "LayerSwap") and true or false
end

local function cvar(name, value)
    local get = C_CVar and C_CVar.GetCVar or GetCVar
    local set = C_CVar and C_CVar.SetCVar or SetCVar
    if value ~= nil then return set and pcall(set, name, value) end
    local v = get and ns.try(get, name)
    return v ~= nil and tostring(v) or nil
end

local function flying() return ns.try(UnitOnTaxi, "player") == true end
local function inCombat() return ns.try(InCombatLockdown) == true end

local function playerPlates()
    local n = 0
    for i = 1, 40 do
        local g = guidOf("nameplate" .. i)
        if g and g:sub(1, 7) == "Player-" then n = n + 1 end
    end
    return n
end

local function creaturePlate()
    for i = 1, 40 do
        local g = guidOf("nameplate" .. i)
        if g and g:sub(1, 7) ~= "Player-" then return true end
    end
    return false
end

-- Put the nameplate settings back. `now` nil: at once (logout, login).
local function putBack(now)
    local back = ns.db and ns.db.platesBack
    if type(back) ~= "table" then flash = nil; return end
    if flash and not flash.seen and creaturePlate() then flash.seen = true end
    if now and flash and not state.layer and now - flash.at < FLASH_FOR then return end
    if inCombat() then return end                     -- (the game bars them; after combat)
    for name, old in pairs(back) do
        if cvar(name) == (name == HIDE and "0" or "1") then cvar(name, old) end
    end
    ns.db.platesBack = nil
    -- A login's showing that saw no creature at all: again shortly.
    local f = flash
    flash = nil
    if now and f and not state.layer and not f.seen and f.why == "login" and now - (loginAt or now) < POLL_FOR then
        local try, at, burst = (f.try or 1) + 1, now + FLASH_RETRY, f.burst or f.at
        if (try - 1) % FLASH_BURST == 0 then at, burst = math.max(at, burst + 60), nil end
        wanted = { why = f.why, at = at, try = try, burst = burst }
        flashLast = at - FLASH_EVERY
    end
end

-- The layer was read: put the nameplates back now.
function Layer.BlinkDone()
    wanted = nil
    if flash then putBack(ns.now()) end
end

local function flashOn(now)
    if flash or (ns.db and ns.db.platesBack) then return end
    if now - flashLast < FLASH_EVERY or inCombat() then return end
    if C_LFGList and C_LFGList.HasActiveEntryInfo and ns.try(C_LFGList.HasActiveEntryInfo) == true then return end
    local back, names = {}, {}
    for _, name in ipairs(PLATES) do
        local v = cvar(name)
        if v ~= nil and v ~= "1" then back[name] = v; names[#names + 1] = name end
    end
    flashLast = now
    local hide = playerPlates() >= CROWD and cvar(HIDE) == "1"
    if #names == 0 and not hide then return end       -- all shown already: what's in view is all there is
    if hide then back[HIDE] = "1" end
    ns.db.platesBack = back                           -- (kept before the first change)
    for _, name in ipairs(names) do cvar(name, "1") end
    if hide then cvar(HIDE, "0") end
    local w = wanted or {}
    flash = { at = now, why = w.why, try = w.try or 1, burst = w.burst or now }
    wanted = nil
    stats.blinks = stats.blinks + 1
    if not ns.db.platesSaid then
        ns.db.platesSaid = true
        ns.print("showed nameplates for a moment to read your layer, and put them back as they were. Settings > Map turns this off.")
    end
end

-- Each second: a need still open, and nothing in view read it.
local function blink(now)
    local w = wanted
    if not w then return end
    if state.layer then wanted = nil; return end
    if flying() then w.at = now; return end           -- kept until the landing
    if w.from and now < w.from then return end
    if now - w.at > WANT_FOR then wanted = nil; return end
    if not (ns.db and ns.db.layerPlates) or layerSwapLoaded() then return end
    if ns.try(IsInGroup) == true then wanted = nil; return end
    local inside = ns.try(IsInInstance)
    if inside == true then return end
    if inBorderQuiet() or now - lastShardAt < SHARD_QUIET then return end
    flashOn(now)
end

-- The layer is needed now (a page that shows it opened, say).
function Layer.Want(why)
    if state.layer then return end
    wanted = { why = why or "asked", at = ns.now(), from = wanted and wanted.from }
end

-- Every second: landings, the nameplates' put-back, a pending showing, and
-- while the layer isn't known, a look at what's in view.
local function tick()
    local now = ns.now()
    local f = flying()
    if onTaxi and not f and not state.layer then
        borderAt = -1000                              -- (the borders crossed in the air lie behind)
        wanted = { why = "landing", at = now, from = now + LAND_WAIT }
    end
    onTaxi = f
    if flash or (ns.db and ns.db.platesBack) then putBack(now) end
    Layer.ScanPlates()
    if not state.layer or recheck then
        observeUnit("target", "target")
        scanNear()
    end
    blink(now)
end

-- For the minimap button tooltip: how many guildies here share my layer.
function Layer.TooltipLine()
    local map = currentMap()
    if not map then return nil end
    local list, unknown = ns.Position.LayersIn(map)
    local yours, other = 0, 0
    for _, e in ipairs(list) do
        if e.mine then yours = e.n - 1 else other = other + e.n end
    end
    if yours + other + unknown == 0 then return nil end
    return ("On your layer here: %d guildie%s%s"):format(yours, yours == 1 and "" or "s",
        (other + unknown > 0) and ("  |cff9d9d9d(%d elsewhere or not known)|r"):format(other + unknown) or ""), 0.4, 0.8, 1
end

ns.onLogin(function()
    putBack(nil)                                      -- (left from a game that closed mid-showing)
    -- (the old nameplate peek's settings, if a game closed mid-peek: back as they were)
    local pb = ns.db and ns.db.peekBack
    if type(pb) == "table" and not inCombat() then
        for name, v in pairs(pb) do
            if type(v) == "table" and tonumber(cvar(name)) == tonumber(v.ours) then cvar(name, v.old) end
        end
        ns.db.peekBack = nil
    end
    ns:On("NAME_PLATE_UNIT_ADDED", function(unit) if not inBorderQuiet() then observeUnit(unit, "plate") end end)
    ns:On("UPDATE_MOUSEOVER_UNIT", function() observeUnit("mouseover", "mouse") end)
    ns:On("PLAYER_TARGET_CHANGED", function() observeUnit("target", "target") end)
    for _, ev in ipairs({ "PLAYER_FOCUS_CHANGED", "PLAYER_SOFT_ENEMY_CHANGED", "PLAYER_SOFT_FRIEND_CHANGED",
            "PLAYER_SOFT_INTERACT_CHANGED", "GOSSIP_SHOW", "MERCHANT_SHOW", "QUEST_GREETING", "QUEST_DETAIL" }) do
        ns:On(ev, function() if not inBorderQuiet() then scanNear() end end)
    end
    -- NPC speech: the 12th argument is the speaker's GUID.
    for _, ev in ipairs({ "CHAT_MSG_MONSTER_SAY", "CHAT_MSG_MONSTER_YELL", "CHAT_MSG_MONSTER_EMOTE" }) do
        ns:On(ev, function(...)
            if inBorderQuiet() then return end
            local guid = select(12, ...)
            if Layer.Observe(guid, "speech") then stats.speech = stats.speech + 1 end
        end)
    end
    ns:On("ZONE_CHANGED_NEW_AREA", function()
        reset("zone")
        -- Within 10 s of the login it's the login's own zone, not a border.
        if ns.now() - (loginAt or -1000) >= 10 then
            border = { untilAt = ns.now() + BORDER_QUIET, guids = inView() }
            borderAt = ns.now()
            wanted = { why = "zone", at = ns.now() }   -- (WANT_FOR outlasts BORDER_QUIET)
        end
    end)
    -- These may or may not move us to another layer; recheck instead of wiping.
    -- (A move to another zone is still caught: Mine() and Observe() are per map.)
    ns:On("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
        softReset("loading screen", true)
        if isLogin or isReload or not loginAt then
            loginAt = ns.now()
            wanted = { why = "login", at = ns.now() }
        end
    end)
    ns:On("SHARD_TRANSFER", function() softReset("shard transfer", true) end)
    ns:On("GROUP_LEFT", function() softReset("left group") end)
    ns:On("GROUP_JOINED", function() softReset("joined group") end)
    ns:On("PLAYER_LOGOUT", function() putBack(nil) end)
    ns:On("PLAYER_REGEN_ENABLED", function() if ns.db and ns.db.platesBack then putBack(ns.now()) end end)
    ns.every(1, tick, "layer tick")
end, "layer")

ns.slash.layer = { help = "your layer in this zone and how it was found", fn = function()
    local map = currentMap()
    local mine = map and Layer.Mine(map) or 0
    if mine == 0 then
        ns.print("your layer here isn't known yet. Target, mouse over or pass near a few NPCs.")
    else
        ns.print(("server number %d here, %s, %d sightings, last %d s ago%s."):format(
            mine,
            state.single and "provisional (one creature so far)" or "confirmed", state.n, ns.now() - state.at,
            Layer.Private() and " (this game build gives every creature its own number: it names no layer)" or ""))
    end
    if recheck then ns.print("  rechecking: the next creature seen will confirm or replace it.") end
    if #votes > 0 then ns.print("  last creatures: " .. table.concat(votes, ", ")) end
    if lastEvent then
        ns.print(("  last %s: %s, %d s ago."):format(lastEvent.kind, lastEvent.why, ns.now() - lastEvent.at))
    end
    ns.print(("  GUIDs read %d, used %d, player-controlled skipped %d, from NPC speech %d, nameplate showings %d%s."):format(
        stats.seen, stats.used, stats.pets, stats.speech, stats.blinks,
        layerSwapLoaded() and " (LayerSwap does the showings)" or ""))
    -- Guildies here, by the evidence between us (LayerLink.lua).
    if ns.LayerLink and map then
        local n, p, ep = ns.LayerLink.Counts()
        ns.print(("  sightings to compare: %d creatures, %d players (epoch %d)."):format(n, p, ep))
        for key, g in pairs(ns.Position.All()) do
            if g.map == map then
                local rel, sure = ns.Position.Relation(g)
                ns.print(("  %s: %s - %s"):format(key, ns.Position.RelationText(rel, sure) or rel, ns.LayerLink.Explain(key)))
            end
        end
    end
end }

---------------------------------------------------------------------------
-- /mw debug: NPC IDs on their tooltips, for testing whether the game still
-- gives every player the same number for one NPC. "ID: ####" (the GUID's
-- server part, what layers were read from) goes under the name; targeting
-- an NPC also prints its whole GUID in chat, to compare with a guildie's.
-- Kept in MoonwardensDB.debugIds, so it survives a /reload.
---------------------------------------------------------------------------
local function npcGuid(unit)
    if not unit or not ns.readable(unit) then return end
    local g = guidOf(unit)
    if not g then return end
    local kind, _, server = strsplit("-", g)
    if kind ~= "Creature" and kind ~= "Vehicle" then return end
    return g, server
end

-- "ID: ####" as line 2: the lines below move down one. When any of them
-- can't be read (a secret value), it goes at the bottom instead.
local function addIdLine(tt, text)
    local name = tt:GetName()
    local n = tt:NumLines()
    if not name or n < 1 then return end
    local L = function(i) return _G[name .. "TextLeft" .. i] end
    local R = function(i) return _G[name .. "TextRight" .. i] end
    local l2 = L(2)
    if l2 and l2:GetText() == text then return end    -- (already added to this build of it)
    local rows = {}
    for i = 2, n do
        local l, r = L(i), R(i)
        local lt, rt = l and l:GetText(), r and r:IsShown() and r:GetText() or nil
        if not (ns.readable(lt) and ns.readable(rt)) then
            tt:AddLine(text, 0.62, 0.62, 0.62)
            tt:Show()
            return
        end
        local lr, lg, lb = l:GetTextColor()
        local rr, rg, rb
        if r then rr, rg, rb = r:GetTextColor() end
        rows[#rows + 1] = { lt = lt, rt = rt, lc = { lr, lg, lb }, rc = { rr, rg, rb } }
    end
    tt:AddLine(" ")
    for i, row in ipairs(rows) do
        local l, r = L(i + 2), R(i + 2)
        l:SetText(row.lt or ""); l:SetTextColor(row.lc[1] or 1, row.lc[2] or 1, row.lc[3] or 1)
        if r then
            if row.rt then
                r:SetText(row.rt); r:SetTextColor(row.rc[1] or 1, row.rc[2] or 1, row.rc[3] or 1); r:Show()
            else
                r:SetText(""); r:Hide()
            end
        end
    end
    L(2):SetText(text); L(2):SetTextColor(0.62, 0.62, 0.62)
    if R(2) then R(2):SetText(""); R(2):Hide() end
    tt:Show()                                          -- (resize to fit)
end

local function onUnitTooltip(tt)
    if not (ns.db and ns.db.debugIds) or not tt.GetUnit then return end
    local ok, _, unit = pcall(tt.GetUnit, tt)
    if not ok then return end
    local _, server = npcGuid(unit)
    if server then addIdLine(tt, "ID: " .. server) end
end

ns.onLogin(function()
    local kind = Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit
    if kind and TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall then
        TooltipDataProcessor.AddTooltipPostCall(kind, ns.guard(onUnitTooltip, "debug ids"))
    else
        GameTooltip:HookScript("OnTooltipSetUnit", ns.guard(onUnitTooltip, "debug ids"))
    end
    ns:On("PLAYER_TARGET_CHANGED", function()
        if not (ns.db and ns.db.debugIds) then return end
        local g = npcGuid("target")
        if g then ns.print("target " .. (ns.try(UnitName, "target") or "?") .. ": " .. g) end
    end)
end, "debug ids")

ns.slash.debug = { help = "on | off - NPC IDs on their tooltips (and target GUIDs in chat)", fn = function(arg)
    arg = (arg or ""):lower()
    local on
    if arg == "on" then on = true elseif arg == "off" then on = false else on = not ns.db.debugIds end
    ns.db.debugIds = on
    ns.print(on and "debug on: NPC tooltips show \"ID: ####\" under the name, and targeting an NPC prints its GUID."
        or "debug off.")
end }
