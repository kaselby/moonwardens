-- Captures: what we take on Overlord's war fronts while I'm there, for the
-- Objectives badges (Badges.lua, by `series`):
--   captures  the Ashenvale front's capture points (no other front's)
--             taken for our side while I stood inside their bounds;
--   outposts  guild outposts taken for our side while I was inside them
--             (Kalimdor's only count: Captures.REGION);
--   forts     fortresses (guild keeps) likewise;
--   ashenvale_outposts  Ashenvale's own outposts (Shobek'Aran, Lesi's Bear
--             Cave): counted here as well as in outposts;
--   support   Splintertree Post taken for our side while I was inside one
--             of its two approaches, Dor'Danil Barrow Den or Raynewood
--             Retreat (I'm Doing My Part!);
--   victory   TOTAL VICTORY on the Ashenvale front (Tor ilisar'thera'nal!),
--             with me in the group (party or raid) that took it: I or a
--             group member inside the last objective taken. Only Overlord
--             can tell, so a guildie with it who sees our group take it
--             tells the group (TV|1|front|time); guildies in it without
--             Overlord count it from that. Each victory counts once
--             however many tell it (credit: one per front within 10 min).
--             Solo, it counts if I was inside Splintertree Post, the last
--             objective, at some time in the 10 minutes before it fell.
--
-- Read from Overlord (an addon of its own; nothing of it is changed):
-- Overlord.ZoneDatabase (objectives: centre, radius, owner, status,
-- capturedTime), Overlord.OutpostSites / Overlord.GuildKeepSites with their
-- state in OverlordDB.outposts (status, ownerFaction, claimedAt), its own
-- "am I inside" checks, and its victory record (Zones:SetVictoryCooldown).
--
-- When I'm inside something, and since when, is kept as time spans (server
-- time). A capture counts if I was inside at its capture time (a few
-- seconds' grace), so one seen late - I came back after it fell - never
-- counts. Captures from before I logged in, or before a front came into
-- view, never count either. Overlord's own leaderboard credits only the one
-- who completed a capture; this credits everyone there.
--
-- How often: every second while I'm on a front's map or an outpost's,
-- else every 10 s. Each look is a map position and a few distance sums.
--
-- My captures are kept in db.objectiveCaptures; the badges are claimed from
-- them as Kills badges are (Ledger.CheckClaims), so they show for others.
local _, ns = ...
local Captures = {}
ns.Captures = Captures

local GRACE = 5             -- inside up to this long (s) before a capture time still counts
local FRESH_FOR = 120       -- a capture time older than this (s) is old news
local SPAN_GAP = 3          -- out of a place this long (s): the next time in is a new span
local SPANS_KEPT = 6
local AWAY_EVERY = 10       -- off the war maps: look this often (s)
-- One capture, two times: Overlord re-stamps a capture when a guildmate's
-- sync of it arrives (their clock, their message's time). A second capture of
-- the same place for the same series this close (s) to the first is that.
-- Taking it back for real needs the enemy's hold and then ours, each at
-- least Overlord's hold less Attack's 60 s (platinum): capture points
-- 120 - 60, outposts 300 - 60, guild keeps 600 - 60. Each window is half
-- the quickest real retake (two such holds back to back), or less.
local SAME_CAPTURE = { captures = 60, support = 60,
                       outposts = 240, ashenvale_outposts = 240, shobekaran = 240, lesi_cave = 240,
                       forts = 540,
                       victory = 600 }   -- (one victory, heard twice)
local function sameCapture(series, a, b)
    return math.abs((a or 0) - (b or 0)) < (SAME_CAPTURE[series or "captures"] or 60)
end
local CAPTURE_FRONT = "ashenvale"   -- capture points count on this front only
local ASHENVALE_OUTPOSTS = { ashenvale = true, lesi_bear_cave = true }   -- (Shobek'Aran, Lesi's Bear Cave)
-- ...and each on its own too (they feed no
-- badge now, but are still counted, should one come back).
local SITE_SERIES = { ashenvale = "shobekaran", lesi_bear_cave = "lesi_cave" }
-- Splintertree Post, and the objectives that hold its approaches (its
-- prerequisites on Overlord's map): inside one as it falls, "support".
local SPLINTERTREE = "ash_splintertree"
local APPROACHES = { "ash_dor_danil", "ash_raynewood" }
-- The outposts and forts the badges count: Kalimdor's (Overlord's site
-- keys). Taken elsewhere: still kept, but counted for nothing and not told.
Captures.REGION = {
    outposts = { lesi_bear_cave = true,   -- Lesi's Bear Cave (Darkshore)
                 ashenvale = true,        -- Shobek'Aran (Ashenvale)
                 durotar = true,          -- Jaggedswine Farm (Durotar)
                 tanaris = true,          -- Broken Pillar (Tanaris)
                 anadora = true },        -- Anad'Ora Moonwell (Feralas)
    forts = { stonetalon = true,          -- Sun Rock Retreat (Stonetalon Mountains)
              mulgore = true,             -- Prairie Keep (Mulgore)
              crossroads = true },        -- Savanna Bastion (the Barrens)
}

local spans = {}            -- "kind:id" -> { { from, to }, ... } server times I was inside, newest last
local seen = {}             -- "kind:id" -> capture time last seen (false: never captured; nil: not looked at)
local nextAway = 0
local deduped = false

local function store()
    ns.db.objectiveCaptures = ns.db.objectiveCaptures or {}
    -- (the fresh start, Badges.FRESH_START: what was taken before it, gone)
    local fresh = ns.Badges and ns.Badges.FRESH_START
    if fresh and ns.db.capturesFresh ~= fresh then
        local kept = {}
        for _, c in ipairs(ns.db.objectiveCaptures) do if (c.at or 0) >= fresh then kept[#kept + 1] = c end end
        ns.db.objectiveCaptures = kept
        ns.db.capturesFresh = fresh
    end
    -- (once: the ones counted twice before SAME_CAPTURE, gone)
    if not deduped then
        deduped = true
        local kept, last = {}, {}
        for _, c in ipairs(ns.db.objectiveCaptures) do
            local k = (c.series or "captures") .. "|" .. tostring(c.zone)
            local prev = last[k]
            if not (prev and sameCapture(c.series, c.at, prev)) then
                kept[#kept + 1] = c
                last[k] = c.at or 0
            end
        end
        ns.db.objectiveCaptures = kept
    end
    return ns.db.objectiveCaptures
end

local function overlord()
    local O = _G.Overlord
    if type(O) ~= "table" or type(O.ZoneDatabase) ~= "table" or type(O.Zones) ~= "table" then return nil end
    return O
end

local function serverNow() return ns.try(GetServerTime) or time() end

-- My entries of a series by week: { [week] = count }, and in all. (A
-- series with a REGION: only its sites.)
function Captures.Weeks(series)
    local weeks, total = {}, 0
    local only = Captures.REGION[series]
    for _, c in ipairs(ns.db and store() or {}) do
        if (c.series or "captures") == series and (not only or only[c.zone]) then
            weeks[c.week] = (weeks[c.week] or 0) + 1
            total = total + 1
        end
    end
    return weeks, total
end

local function noteInside(key, t)
    local list = spans[key] or {}
    spans[key] = list
    local last = list[#list]
    if last and t - last.to <= SPAN_GAP then
        last.to = t
    else
        list[#list + 1] = { from = t, to = t }
        if #list > SPANS_KEPT then table.remove(list, 1) end
    end
end

-- Was I inside `key` at capture time `ct`?
local function wasInside(key, ct)
    for _, s in ipairs(spans[key] or {}) do
        if s.from <= ct + 2 and s.to >= ct - GRACE then return true end
    end
    return false
end

local function credit(series, id, name, ct, what, quiet)
    local list = store()
    for _, c in ipairs(list) do
        if (c.series or "captures") == series and c.zone == id then
            if sameCapture(series, c.at, ct) then return end                -- (counted already: SAME_CAPTURE)
        end
    end
    local LB = ns.Leaderboard
    list[#list + 1] = { series = series, zone = id, name = name, at = ct, week = LB and LB.WeekOf and LB.WeekOf(ct) or 0 }
    if not quiet then ns.print(("|cff1eff00%s|r %s"):format(what, tostring(name or id))) end
    ns.fire("BADGES", ns.meKey)
    if ns.Ledger and ns.Ledger.CheckClaims then ns.after(2, ns.Ledger.CheckClaims, "capture claims") end
end

-- A capture of `key` at `ct`: new since the last look, fresh, ours, and me in it?
-- (taken just now, for us - wherever I was)
local function freshCapture(key, ct, ours)
    local was = seen[key]
    seen[key] = ct or false
    if not (ct and was ~= nil and ct ~= was and ours) then return false end
    return math.abs(serverNow() - ct) <= FRESH_FOR
end
local function newCapture(key, ct, ours)
    return freshCapture(key, ct, ours) and wasInside(key, ct)
end

local function siteName(O, site)
    local L = O.L
    return (site.displayNameKey and L and L[site.displayNameKey]) or site.siteKey or site.id
end

local function onWarMap(O)
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok or not mapID then return false end
    if O.Fronts and O.Fronts.ResolveFrontByMapID then
        local okF, front = pcall(O.Fronts.ResolveFrontByMapID, O.Fronts, mapID)
        if okF and front then return true end
    end
    if O.Outpost and O.Outpost.IsPlayerOnOutpostMap then
        local okO, onMap = pcall(O.Outpost.IsPlayerOnOutpostMap, O.Outpost)
        if okO and onMap then return true end
    end
    return false
end

local function tick()
    local O = overlord()
    if not O then return end
    local now = GetTime()
    if not onWarMap(O) then
        if now < nextAway then return end
        nextAway = now + AWAY_EVERY
    end
    local t = serverNow()
    local alive = ns.try(UnitIsDeadOrGhost, "player") == false
    local faction = O.PlayerFaction

    -- Where I am: an objective, an outpost or a fort.
    if alive then
        local ok, zone = pcall(O.Zones.GetCurrentPlayerZone, O.Zones)
        if ok and type(zone) == "table" and zone.id then noteInside("zone:" .. zone.id, t) end
        local OP = O.Outpost
        if OP and OP.IsPlayerOnOutpostMap and OP.IsPlayerInOutpostGeometry then
            local okM, onMap, site = pcall(OP.IsPlayerOnOutpostMap, OP)
            if okM and onMap and type(site) == "table" then
                local okG, inside = pcall(OP.IsPlayerInOutpostGeometry, OP, site)
                if okG and inside then noteInside("site:" .. (site.siteKey or site.id), t) end
            end
        end
    end

    -- What has been taken for our side. (The capture points listed are the
    -- active front's: they count only when that's Ashenvale.)
    local onAshenvale = O.Fronts and O.Fronts.activeFrontId == CAPTURE_FRONT
    for _, zone in ipairs(O.ZoneDatabase) do
        if zone.id then
            local ct = tonumber(zone.capturedTime)
            local ours = onAshenvale and zone.status == "captured" and faction and zone.owner == faction and not zone._loginSyncUnconfirmed
            local key = "zone:" .. zone.id
            if freshCapture(key, ct, ours) then
                if wasInside(key, ct) then
                    credit("captures", zone.id, zone.name, ct, "Objective taken, with you in it:")
                end
                -- (Splintertree Post: or holding one of its approaches)
                if zone.id == SPLINTERTREE then
                    for _, id in ipairs(APPROACHES) do
                        if wasInside("zone:" .. id, ct) then
                            credit("support", zone.id, zone.name, ct, "I'm Doing My Part! You held the line as it fell:")
                            break
                        end
                    end
                end
            end
        end
    end
    local states = type(OverlordDB) == "table" and OverlordDB.outposts or nil
    if type(states) == "table" then
        for _, pair in ipairs({ { O.OutpostSites, "outposts", "Outpost taken, with you in it:" },
                                { O.GuildKeepSites, "forts", "Fort taken, with you in it:" } }) do
            for key, site in pairs(type(pair[1]) == "table" and pair[1] or {}) do
                local st = states[key]
                if type(st) == "table" then
                    local ct = tonumber(st.claimedAt)
                    if ct and ct <= 0 then ct = nil end
                    local ours = st.status == "held" and faction and st.ownerFaction == faction
                    if newCapture("site:" .. key, ct, ours) then
                        local counts = not Captures.REGION[pair[2]] or Captures.REGION[pair[2]][key]
                        credit(pair[2], key, siteName(O, site), ct, pair[3], not counts)
                        if pair[2] == "outposts" and ASHENVALE_OUTPOSTS[key] then
                            credit("ashenvale_outposts", key, siteName(O, site), ct, nil, true)
                        end
                        if pair[2] == "outposts" and SITE_SERIES[key] then
                            credit(SITE_SERIES[key], key, siteName(O, site), ct, nil, true)
                        end
                    end
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Total Victory on the Ashenvale front
---------------------------------------------------------------------------
local VICTORY_FRONT = "ashenvale"

-- Is unit `u` inside objective `zone` on the front's map?
local function unitInside(O, u, zone, mapID)
    if not (zone and zone.center and zone.radius and mapID) then return false end
    local ok, pos = pcall(C_Map.GetPlayerMapPosition, mapID, u)
    if not ok or not pos then return false end
    local okXY, x, y = pcall(pos.GetXY, pos)
    if not okXY or type(x) ~= "number" or not ns.readable(x) then return false end
    local okA, ar = pcall(O.Zones.GetMapAspectRatio, O.Zones)
    ar = okA and tonumber(ar) or 1
    local dx = zone.center[1] - x * 100
    local dy = (zone.center[2] - y * 100) * ar
    return dx * dx + dy * dy <= zone.radius * zone.radius
end

-- My group's units (party1-4, or raid1-40).
local function groupUnits()
    local out = {}
    if IsInRaid() then for i = 1, 40 do out[#out + 1] = "raid" .. i end
    else for i = 1, 4 do out[#out + 1] = "party" .. i end end
    return out
end

-- Is guildie `key` in my group?
local function inMyGroup(key)
    if not (key and IsInGroup()) then return false end
    for _, u in ipairs(groupUnits()) do
        if ns.try(UnitExists, u) == true then
            local first, realm = ns.try(UnitName, u)
            local name = (type(realm) == "string" and realm ~= "") and (first .. " " .. realm) or first
            if type(name) == "string" and ns.key(name) == key then return true end
        end
    end
    return false
end

local VICTORY_WHAT = "Tor ilisar'thera'nal! You helped take all of"
local FINAL_ZONE = "ash_splintertree"   -- Ashenvale's last objective (the Horde's capital there)
local SOLO_WINDOW = 600                 -- (s) solo: inside it this long before it fell still counts

-- Was I inside `key` at any time from `window` s before `ct` up to `ct`?
local function insideWithin(key, ct, window)
    for _, s in ipairs(spans[key] or {}) do
        if s.from <= ct + 2 and s.to >= ct - window then return true end
    end
    return false
end

local function onVictory(_, frontId, winner, ts)
    local O = overlord()
    ts = tonumber(ts)
    if not (O and frontId == VICTORY_FRONT and ts and winner and winner == O.PlayerFaction) then return end
    if math.abs(serverNow() - ts) > FRESH_FOR then return end          -- (an old one, replayed)
    -- Solo: inside Splintertree Post in the 10 minutes before it fell.
    if not IsInGroup() then
        local final
        for _, zone in ipairs(O.ZoneDatabase) do if zone.id == FINAL_ZONE then final = zone end end
        local ct = final and tonumber(final.capturedTime) or ts
        if insideWithin("zone:" .. FINAL_ZONE, ct, SOLO_WINDOW) then
            credit("victory", frontId, "Ashenvale", ts, VICTORY_WHAT)
        end
        return
    end
    -- My party or raid did it: I or a member inside the last objective taken.
    local last
    for _, zone in ipairs(O.ZoneDatabase) do
        local ct = tonumber(zone.capturedTime)
        if ct and zone.owner == winner and (not last or ct > tonumber(last.capturedTime)) then last = zone end
    end
    if not last then return end
    local frontMap = O.Fronts.GetMapID and O.Fronts:GetMapID(frontId)
    local ours = wasInside("zone:" .. last.id, tonumber(last.capturedTime))
    if not ours then
        for _, u in ipairs(groupUnits()) do
            if ns.try(UnitExists, u) == true and unitInside(O, u, last, frontMap) then ours = true; break end
        end
    end
    if not ours then return end
    credit("victory", frontId, "Ashenvale", ts, VICTORY_WHAT)
    -- Tell the group: its guildies without Overlord count it too.
    ns.Comm.Send({ "TV", ns.Comm.PROTO, frontId, ts }, IsInRaid() and "RAID" or "PARTY")
end

-- A guildie in my group saw it (Overlord): it counts for me too, if it's
-- fresh and they're in my group now. (Again from another: still once.)
local function onShared(f, sender, key, channel)
    if channel ~= "PARTY" and channel ~= "RAID" then return end
    local frontId, ts = f[3], tonumber(f[4])
    if frontId ~= VICTORY_FRONT or not ts then return end
    if math.abs(serverNow() - ts) > FRESH_FOR then return end
    if not inMyGroup(key) then return end
    credit("victory", frontId, "Ashenvale", ts, VICTORY_WHAT)
end

local hooked = false
local function hookVictory()
    local O = overlord()
    if hooked or not (O and O.Zones and type(O.Zones.SetVictoryCooldown) == "function") then return end
    hooked = true
    -- (Overlord is an addon: hooking it touches nothing of the game's)
    hooksecurefunc(O.Zones, "SetVictoryCooldown", function(...) pcall(onVictory, ...) end)
end

ns.onLogin(function()
    -- (heard from the group, with or without Overlord)
    ns.Comm.handlers.TV = onShared
    -- (Overlord is optional: without it, nothing else here does anything)
    hookVictory()
    ns:On("ADDON_LOADED", function(name) if name == "Overlord" then hookVictory() end end)
    ns.every(1, tick, "objective captures")
end, "captures")
