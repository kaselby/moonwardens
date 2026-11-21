-- LayerLink: whether a guildie is on my layer, from what we both see. Since
-- game build 71037 a creature's GUID no longer carries a number shared by its
-- layer (Layer.lua; LayerSwap 1.14.41), so there is no layer number to
-- compare. What's left is evidence between two players:
--
--  * Seen in the world: their nameplate, target or mouseover (Position.lua).
--    Proof, for 30 s.
--  * Their group frame: the game marks a party/raid member on another layer
--    (UnitPhaseReason: sharding), and no mark on a connected one means here.
--    Proof, while grouped.
--  * Shared sightings. Every client sends the guild short fingerprints of the
--    creatures and players it has seen in the last minute (F, below). A
--    creature lives on one layer, so one creature in common means one layer,
--    if the game gives every player the same GUID for it (not yet known on
--    71037: when it doesn't, they simply never match). Players move between
--    layers, so a stranger in common is only a lead: one is "probably your
--    layer", two different ones count as proof.
--  * Near but unseen: within 25 yards for 6 s with friendly player nameplates
--    on and no nameplate of theirs. "Probably another layer" (they may just be
--    out of sight, round a corner, on a ledge).
--
-- Everything is preliminary, as asked: each side's sightings expire (mine
-- after WINDOW s, theirs THEIRS_FOR s after they arrive), and a move of
-- either side (a shard transfer, a loading screen, a new zone) starts its
-- sightings over: that client's "epoch" goes up, and a guildie's list from an
-- older epoch is dropped.
--
-- F|1|map|epoch|creatures|players   GUILD, every SEND_EVERY s while there's
--   something new, at most every RESEND s otherwise; lists of 4-character
--   fingerprints joined by ",". The fingerprint is a hash: no GUID is sent.
local _, ns = ...
local LL = {}
ns.LayerLink = LL

local WINDOW = 90          -- seconds my own sightings count
local THEIRS_FOR = 60      -- seconds a guildie's list counts after it arrives
local LIST_AGE = 60        -- sightings younger than this go in what I send
local SEND_EVERY = 10
local RESEND = 30
local MAX_IDS = 20         -- per kind in one message (2 x 20 x 5 bytes fits in 255)
local SEEN_FOR = 30        -- a guildie's own nameplate counts this long
local NEAR_YARDS = 25
local NEAR_FOR = 6
local PHASE_SHARDING = 1   -- Enum.PhaseReason.Sharding (LayerSwap's table)

local epoch = 1
local mine = { npc = {}, pc = {} }     -- fingerprint -> time I last saw it
local theirs = {}                      -- key -> { map, epoch, at, npc = set, pc = set }
local seenGuildie = {}                 -- key -> time I last saw their nameplate
local nearSince, nearFlag = {}, {}     -- key -> since when near & unseen; key -> true
local lastSent = { at = -100, sig = nil }
local myGuid

---------------------------------------------------------------------------
-- Fingerprints
---------------------------------------------------------------------------
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function hash(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 16777216 end
    local out = {}
    for i = 1, 4 do
        local d = h % 64
        out[i] = B64:sub(d + 1, d + 1)
        h = math.floor(h / 64)
    end
    return table.concat(out)
end

local function inInstance()
    local inside, kind = ns.try(IsInInstance)
    return inside == true and kind ~= "none"
end

-- A creature: its server, npc and spawn parts (not the per-client zone part).
local function noteGuid(guid, unit)
    if type(guid) ~= "string" or not ns.readable(guid) then return end
    local kind, a, b, _, _, npc, spawn = strsplit("-", guid)
    local now = ns.now()
    if kind == "Player" then
        myGuid = myGuid or ns.try(UnitGUID, "player")
        if guid == myGuid then return end
        mine.pc[hash(guid)] = now
        if unit then
            local first, last = ns.try(UnitName, unit)
            local key = type(first) == "string" and ns.key(last and last ~= "" and (first .. " " .. last) or first)
            if key and ns.Roster.Get(key) then seenGuildie[key] = now end
        end
    elseif (kind == "Creature" or kind == "Vehicle") and npc and spawn then
        if unit and ns.try(UnitPlayerControlled, unit) == true then return end   -- (pets carry their owner's place)
        mine.npc[hash(table.concat({ "C", b or "", npc, spawn }, "-"))] = now
    end
end

local function noteUnit(unit)
    if inInstance() or ns.try(UnitExists, unit) ~= true then return end
    noteGuid(ns.try(UnitGUID, unit), unit)
end

local function scan()
    for i = 1, 40 do noteUnit("nameplate" .. i) end
    for _, u in ipairs({ "target", "mouseover", "focus", "softenemy", "softfriend", "softinteract", "npc" }) do noteUnit(u) end
end

---------------------------------------------------------------------------
-- Sending and receiving
---------------------------------------------------------------------------
local function recent(set, limit)
    local now, list = ns.now(), {}
    for fp, at in pairs(set) do
        if now - at > WINDOW then set[fp] = nil
        elseif now - at <= LIST_AGE then list[#list + 1] = { fp = fp, at = at } end
    end
    table.sort(list, function(x, y) return x.at > y.at end)
    local out = {}
    for i = 1, math.min(#list, limit) do out[i] = list[i].fp end
    return out
end

local function send(force)
    if not IsInGuild() or inInstance() then return end
    local map = ns.Position.Me().map
    if not map then return end
    local npc, pc = recent(mine.npc, MAX_IDS), recent(mine.pc, MAX_IDS)
    local fields = { "F", ns.Comm.PROTO, map, epoch, table.concat(npc, ","), table.concat(pc, ",") }
    local sig = table.concat(fields, "|", 3)
    local now = ns.now()
    if not force and sig == lastSent.sig and now - lastSent.at < RESEND then return end
    lastSent.sig, lastSent.at = sig, now
    ns.Comm.Send(fields, "GUILD", nil, "layerlink")
end

local function toSet(s)
    local set = {}
    if type(s) == "string" then for fp in s:gmatch("[^,]+") do set[fp] = true end end
    return set
end

local function onF(f, sender, key)
    local map, ep = tonumber(f[3]), tonumber(f[4])
    if not (map and ep) then return end
    local t = theirs[key]
    if t and t.epoch ~= ep then nearSince[key], nearFlag[key] = nil, nil end
    theirs[key] = { map = map, epoch = ep, at = ns.now(), npc = toSet(f[5]), pc = toSet(f[6]) }
end

-- A move of mine: my sightings start over, and the guild hears it at once.
local function moved()
    epoch = epoch + 1
    mine.npc, mine.pc = {}, {}
    seenGuildie, nearSince, nearFlag = {}, {}, {}
    ns.after(1, function() send(true) end, "layerlink moved")
end

---------------------------------------------------------------------------
-- Group members: the game's phase mark
---------------------------------------------------------------------------
local groupUnits, groupAt = {}, -10
local function groupUnit(key)
    local now = ns.now()
    if now - groupAt > 1 then
        groupAt, groupUnits = now, {}
        local raid = ns.try(IsInRaid) == true
        local n = raid and 40 or 4
        for i = 1, n do
            local u = (raid and "raid" or "party") .. i
            if ns.try(UnitExists, u) == true then
                local first, last = ns.try(UnitName, u)
                local k = type(first) == "string" and ns.key(last and last ~= "" and (first .. " " .. last) or first)
                if k then groupUnits[k] = u end
            end
        end
    end
    return groupUnits[key]
end

---------------------------------------------------------------------------
-- Near but unseen (each second)
---------------------------------------------------------------------------
local function friendlyPlatesOn()
    local get = C_CVar and C_CVar.GetCVar or GetCVar
    local function on(name) local v = get and ns.try(get, name); return v == nil or tostring(v) == "1" end
    return on("nameplateShowFriends") and on("nameplateShowFriendlyPlayers")
end

local function updateNear()
    local me = ns.Position.Me()
    local now = ns.now()
    local plates = friendlyPlatesOn()
    local w, h
    if me.map and ns.MapMini and ns.MapMini.ZoneSize then w, h = ns.MapMini.ZoneSize(me.map) end
    for key, g in pairs(ns.Position.All()) do
        local near = false
        if plates and w and me.x and g.map == me.map and now - (g.at or 0) <= 4 then
            local dx, dy = (g.x - me.x) * w, (g.y - me.y) * h
            near = dx * dx + dy * dy <= NEAR_YARDS * NEAR_YARDS
        end
        local unseen = now - (seenGuildie[key] or -100) > 3
        if near and unseen and not groupUnit(key) then
            nearSince[key] = nearSince[key] or now
            nearFlag[key] = now - nearSince[key] >= NEAR_FOR or nil
        else
            nearSince[key], nearFlag[key] = nil, nil
        end
    end
end

---------------------------------------------------------------------------
-- The verdict
---------------------------------------------------------------------------
local function overlap(theirSet, mySet, now)
    local n = 0
    for fp in pairs(theirSet) do
        local at = mySet[fp]
        if at and now - at <= WINDOW then n = n + 1 end
    end
    return n
end

-- "same" / "other" and whether it's proof (true) or a lead (false); nil when
-- there's no evidence either way. `g`: the guildie's position (Position.lua).
function LL.Relation(g)
    local key, now = g.key, ns.now()
    local unit = groupUnit(key)
    if unit then
        local reason = ns.try(UnitPhaseReason, unit)
        if reason == ((Enum and Enum.PhaseReason and Enum.PhaseReason.Sharding) or PHASE_SHARDING) then return "other", true end
        if reason == nil and ns.try(UnitIsConnected, unit) == true and type(UnitPhaseReason) == "function" then return "same", true end
    end
    if now - (seenGuildie[key] or -100) <= SEEN_FOR then return "same", true end
    local t = theirs[key]
    if t and t.map == g.map and now - t.at <= THEIRS_FOR then
        local npcHits, pcHits = overlap(t.npc, mine.npc, now), overlap(t.pc, mine.pc, now)
        if npcHits >= 1 or pcHits >= 2 then return "same", true end
        if pcHits == 1 then return "same", false end
    end
    if nearFlag[key] then return "other", false end
    return nil
end

-- For /mw layer: what the evidence is for one guildie.
function LL.Explain(key)
    local g = ns.Position.Get(key)
    if not g then return "no position" end
    local now = ns.now()
    local t = theirs[key]
    local npcHits, pcHits = 0, 0
    if t and now - t.at <= THEIRS_FOR then npcHits, pcHits = overlap(t.npc, mine.npc, now), overlap(t.pc, mine.pc, now) end
    return ("seen %s, creatures in common %d, players in common %d, near unseen %s, group %s"):format(
        seenGuildie[key] and ("%d s ago"):format(now - seenGuildie[key]) or "no", npcHits, pcHits,
        nearFlag[key] and "yes" or "no", groupUnit(key) or "no")
end

function LL.Counts()
    local n, p = 0, 0
    for _ in pairs(mine.npc) do n = n + 1 end
    for _ in pairs(mine.pc) do p = p + 1 end
    return n, p, epoch
end

ns.onLogin(function()
    ns.Comm.handlers.F = onF
    ns:On("NAME_PLATE_UNIT_ADDED", function(unit) noteUnit(unit) end)
    ns:On("UPDATE_MOUSEOVER_UNIT", function() noteUnit("mouseover") end)
    ns:On("PLAYER_TARGET_CHANGED", function() noteUnit("target") end)
    for _, ev in ipairs({ "GOSSIP_SHOW", "MERCHANT_SHOW", "QUEST_GREETING", "QUEST_DETAIL" }) do
        ns:On(ev, function() noteUnit("npc") end)
    end
    for _, ev in ipairs({ "CHAT_MSG_MONSTER_SAY", "CHAT_MSG_MONSTER_YELL", "CHAT_MSG_MONSTER_EMOTE" }) do
        ns:On(ev, function(...) if not inInstance() then noteGuid(select(12, ...)) end end)
    end
    ns:On("SHARD_TRANSFER", moved)
    ns:On("PLAYER_ENTERING_WORLD", moved)
    ns:On("ZONE_CHANGED_NEW_AREA", moved)
    ns.every(1, function() scan(); updateNear() end, "layerlink scan")
    ns.every(SEND_EVERY, function() send(false) end, "layerlink send")
end, "layerlink")

---------------------------------------------------------------------------
-- Layer numbers by agreement. Each client sends what it has decided about
-- the guildies in its zone (LR); from everyone's, the guildies of a zone
-- fall into groups: "same" joins two (proof only), "other" keeps two apart
-- (proof or lead). A group is a numbered layer when it has two or more
-- guildies, or something says it differs from another; a guildie alone with
-- nothing either way is "?". (So the count can run high, never low: two
-- groups nothing has linked yet may be one layer. Everyone with one number
-- is together.)
-- One guildie in the zone numbers them and sends it (LN), so everyone shows
-- the same: an officer there if any (highest rank, then name), else the
-- first name among those reporting there. Numbers start at 1 with no gaps;
-- a group keeps its number from last time where it can, and when one goes,
-- those above move down. Without a recent LN for a zone, each client numbers
-- it the same way itself.
-- LR|1|map|same|leads|other    LN|1|map|1=a,b;2=c,~d   (4-char key hashes; ~ a lead)
---------------------------------------------------------------------------
local REPORT_FOR = 60      -- a verdict list counts this long
local NUMBERS_FOR = 30     -- an LN counts this long
local REPORT_EVERY = 5
local reports = {}         -- key -> { map, at, same = set, lead = set, other = set }
local numbered = {}        -- map -> { at, by, label = { key -> n }, lead = { key -> true } }
local lastReport = { at = -100 }
local lastNumbers = {}     -- map -> { at, sig }

local keyHash, hashKey = {}, {}
local function hk(key)
    local h = keyHash[key]
    if not h then h = hash(key); keyHash[key] = h; hashKey[h] = key end
    return h
end
local function keyOf(h)
    local key = hashKey[h]
    if not key then   -- (learn the guild's hashes, once per unknown one)
        for k in pairs(ns.Roster.All()) do hk(k) end
        key = hashKey[h]
    end
    return key
end
local function fromHashes(s)
    local set = {}
    if type(s) ~= "string" then return set end
    for h in s:gmatch("[^,]+") do
        local key = keyOf(h)
        if key then set[key] = true end
    end
    return set
end
local function hashes(set)
    local out = {}
    for key in pairs(set) do out[#out + 1] = hk(key) end
    table.sort(out)
    return table.concat(out, ",")
end

-- My own verdicts about everyone in my zone.
local function myReport()
    local me = ns.Position.Me()
    local r = { map = me.map, at = ns.now(), same = {}, lead = {}, other = {} }
    if not me.map then return r end
    for key, g in pairs(ns.Position.All()) do
        if g.map == me.map then
            local rel, sure = ns.Position.Relation(g)
            if rel == "same" then
                if sure then r.same[key] = true else r.lead[key] = true end
            elseif rel == "other" then
                r.other[key] = true
            end
        end
    end
    return r
end

local function sendReport()
    if not IsInGuild() or inInstance() or not ns.meKey then return end
    local r = myReport()
    reports[ns.meKey] = r
    if not r.map then return end
    local fields = { "LR", ns.Comm.PROTO, r.map, hashes(r.same), hashes(r.lead), hashes(r.other) }
    local sig = table.concat(fields, "|", 3)
    if sig == lastReport.sig and ns.now() - lastReport.at < 30 then return end
    lastReport.sig, lastReport.at = sig, ns.now()
    ns.Comm.Send(fields, "GUILD", nil, "layerreport")
end

local function onLR(f, sender, key)
    local map = tonumber(f[3])
    if not map then return end
    reports[key] = { map = map, at = ns.now(), same = fromHashes(f[4]), lead = fromHashes(f[5]), other = fromHashes(f[6]) }
end

-- Who's in a zone: guildies there by position, and me.
local function membersOf(map)
    local list = {}
    for key, g in pairs(ns.Position.All()) do
        if g.map == map then list[key] = true end
    end
    if ns.Position.Me().map == map and ns.meKey then list[ns.meKey] = true end
    return list
end

-- Who numbers a zone: an officer reporting there (highest rank, then name),
-- else the first name among those reporting there.
local function numbererOf(map, members)
    local best, bestRank, bestOfficer
    local now = ns.now()
    for key in pairs(members) do
        local r = reports[key]
        if r and r.map == map and now - r.at <= REPORT_FOR then
            local m = ns.Roster.Get(key)
            local officer = ns.Roster.IsOfficer(key) and true or false
            local rank = m and m.rankIndex or 99
            local better = not best or (officer and not bestOfficer)
                or (officer == bestOfficer and (rank < bestRank or (rank == bestRank and key < best)))
            if better then best, bestRank, bestOfficer = key, rank, officer end
        end
    end
    return best
end

-- Number a zone's guildies from everyone's reports (see the top).
local function numberZone(map)
    local members = membersOf(map)
    local now = ns.now()
    local parent = {}
    local function find(k)
        while parent[k] and parent[k] ~= k do k = parent[k] end
        return k
    end
    for k in pairs(members) do parent[k] = k end
    local leads, others = {}, {}
    for who, r in pairs(reports) do
        if members[who] and r.map == map and now - r.at <= REPORT_FOR then
            for k in pairs(r.same) do
                if members[k] then
                    local a, b = find(who), find(k)
                    if a ~= b then
                        if a < b then parent[b] = a else parent[a] = b end
                    end
                end
            end
            for k in pairs(r.lead) do if members[k] then leads[#leads + 1] = { who, k } end end
            for k in pairs(r.other) do if members[k] then others[#others + 1] = { who, k } end end
        end
    end
    local groups = {}
    for k in pairs(members) do
        local root = find(k)
        local gr = groups[root] or { keys = {}, n = 0, min = k, differs = false }
        gr.keys[#gr.keys + 1] = k
        gr.n = gr.n + 1
        if k < gr.min then gr.min = k end
        groups[root] = gr
    end
    for _, p in ipairs(others) do
        local a, b = groups[find(p[1])], groups[find(p[2])]
        if a and b and a ~= b then a.differs, b.differs = true, true end
    end
    local prev = numbered[map] and numbered[map].label or {}
    local list = {}
    for _, gr in pairs(groups) do
        if gr.n >= 2 or gr.differs then
            local p
            for _, k in ipairs(gr.keys) do
                if prev[k] and (not p or prev[k] < p) then p = prev[k] end
            end
            gr.prev = p
            list[#list + 1] = gr
        end
    end
    table.sort(list, function(a, b)
        if (a.prev ~= nil) ~= (b.prev ~= nil) then return a.prev ~= nil end
        if a.prev and b.prev and a.prev ~= b.prev then return a.prev < b.prev end
        if a.n ~= b.n then return a.n > b.n end
        return a.min < b.min
    end)
    local label, lead = {}, {}
    for i, gr in ipairs(list) do
        for _, k in ipairs(gr.keys) do label[k] = i end
    end
    -- A loose guildie with a lead to a numbered one: that number, as a lead.
    for _, p in ipairs(leads) do
        local a, b = p[1], p[2]
        if label[a] and not label[b] then label[b], lead[b] = label[a], true
        elseif label[b] and not label[a] then label[a], lead[a] = label[b], true end
    end
    return label, lead
end

local function encodeNumbers(label, lead, members)
    local by, top = {}, 0
    for k in pairs(members) do
        local n = label[k]
        if n then
            by[n] = by[n] or {}
            by[n][#by[n] + 1] = (lead[k] and "~" or "") .. hk(k)
            if n > top then top = n end
        end
    end
    local parts = {}
    for n = 1, top do
        if by[n] then
            table.sort(by[n])
            parts[#parts + 1] = n .. "=" .. table.concat(by[n], ",")
        end
    end
    return table.concat(parts, ";")
end

local function decodeNumbers(s)
    local label, lead = {}, {}
    if type(s) ~= "string" then return label, lead end
    for n, list in s:gmatch("(%d+)=([^;]*)") do
        n = tonumber(n)
        for item in list:gmatch("[^,]+") do
            local isLead = item:sub(1, 1) == "~"
            local key = keyOf(isLead and item:sub(2) or item)
            if key then
                label[key] = n
                if isLead then lead[key] = true end
            end
        end
    end
    return label, lead
end

local function onLN(f, sender, key)
    local map = tonumber(f[3])
    if not map then return end
    if numbererOf(map, membersOf(map)) ~= key then return end   -- (only the one who numbers that zone)
    local label, lead = decodeNumbers(f[4])
    numbered[map] = { at = ns.now(), by = key, label = label, lead = lead }
end

-- Each few seconds: number the zones I number (and send it when it changed),
-- and number myself any zone whose numberer hasn't been heard lately.
local function numberZones()
    if not ns.meKey or inInstance() then return end
    local zones = {}
    for _, g in pairs(ns.Position.All()) do zones[g.map] = true end
    local myMap = ns.Position.Me().map
    if myMap then zones[myMap] = true end
    local now = ns.now()
    for map in pairs(zones) do
        local members = membersOf(map)
        local by = numbererOf(map, members)
        local cur = numbered[map]
        local heard = cur and cur.by and cur.by == by and by ~= ns.meKey and now - cur.at <= NUMBERS_FOR
        if not heard then
            local label, lead = numberZone(map)
            numbered[map] = { at = now, by = (by == ns.meKey) and ns.meKey or nil, label = label, lead = lead }
            if by == ns.meKey then
                local s = encodeNumbers(label, lead, members)
                local last = lastNumbers[map]
                if not last or last.sig ~= s or now - last.at >= 20 then
                    lastNumbers[map] = { at = now, sig = s }
                    ns.Comm.Send({ "LN", ns.Comm.PROTO, map, s }, "GUILD", nil, "layernumbers" .. map)
                end
            end
        end
    end
end

-- A guildie's layer number in their zone (nil: "?"), whether that's only a
-- lead, and the zone.
function LL.Label(key)
    local g = (key == ns.meKey) and ns.Position.Me() or ns.Position.Get(key)
    local map = g and g.map
    local z = map and numbered[map]
    if not z then return nil end
    return z.label[key], z.lead[key] and true or false, map
end

-- My own number in my zone, or nil.
function LL.MyLabel()
    local map = ns.Position.Me().map
    local z = map and numbered[map]
    return z and ns.meKey and z.label[ns.meKey] or nil
end

-- The numbered layers of a zone, { n, keys, leads }, in order; and the "?" keys.
function LL.LayersOf(map)
    local z = numbered[map]
    local by, loose = {}, {}
    for key in pairs(membersOf(map)) do
        local n = z and z.label[key]
        if n then
            by[n] = by[n] or { n = n, keys = {}, leads = 0 }
            local e = by[n]
            e.keys[#e.keys + 1] = key
            if z.lead[key] then e.leads = e.leads + 1 end
        else
            loose[#loose + 1] = key
        end
    end
    local list = {}
    for _, e in pairs(by) do list[#list + 1] = e end
    table.sort(list, function(a, b) return a.n < b.n end)
    return list, loose
end

function LL.Numberer(map) return numbered[map] and numbered[map].by end

ns.onLogin(function()
    ns.Comm.handlers.LR = onLR
    ns.Comm.handlers.LN = onLN
    ns.every(REPORT_EVERY, function() sendReport(); numberZones() end, "layer numbers")
end, "layer numbers")
