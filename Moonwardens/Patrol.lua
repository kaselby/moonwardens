-- Patrol: hotspots on the maps, and where and when Horde were last seen.
--
-- Sightings: an enemy player's nameplate, target or mouseover in a tracked
-- area (Ashenvale, Stonetalon Peak: the leaderboard's areas) is a sighting.
-- The position is MINE when I saw them (the game gives no enemy positions),
-- so a sighting means "within nameplate range of here". Shared with the
-- guild, a few names per message:
--   S|1|map|x|y|Name-Surname:CLASS:level,...
-- Each player is sent at most once a minute, and not at all while a guildie
-- reported them in the last 30 s. Kept 30 minutes.
-- Patrol mode (off by default) draws hotspots and recent sightings on the
-- world map and minimap. Recording and sharing don't depend on it.
local _, ns = ...
local Patrol = {}
ns.Patrol = Patrol

local ASHENVALE = 1440
local KEEP = 1800          -- seconds a sighting is kept
local SHOW = 900           -- seconds a sighting is drawn on the maps
local RESEND = 60          -- seconds before I send the same player again
local HEARD = 30           -- a guildie's report this recent makes mine unneeded
local FLUSH = 2            -- seconds to gather sightings into one message
local NEAR = 250           -- yards: a sighting this close to a hotspot is "at" it
local MAX_STORE = 300
local MAX_ENTRIES = 12     -- per received message

local CIRCLE = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMaskSmall"
local RING = "Interface\\AddOns\\Moonwardens\\media\\ring"
local SPOT_COLOR = { 0.55, 0.8, 1 }      -- hotspot ring, moonlight blue

-- Hotspots (Krylea, 11-15). Classic Ashenvale map coordinates (0-1), from
-- NPC and object spawns in Questie's Classic DB, checked against the WoW
-- Forever quest DB (tzofeh, 11-15). `why`: one line for the tooltip.
Patrol.HOTSPOTS = {
    -- (an area: the middle of the naga spawns along the coast)
    { name = "Zoram Strand", map = ASHENVALE, x = 0.110, y = 0.240,
      why = "North of Zoram'gar. Horde escort Vorsha the Lasher ends at the brazier (10, 28)." },
    -- (Delgren the Purifier)
    { name = "Maestra's Post", map = ASHENVALE, x = 0.262, y = 0.387, why = "Sentinel outpost" },
    -- (Ruul Snowhoof, where the escort starts)
    { name = "Thistlefur Village", map = ASHENVALE, x = 0.415, y = 0.345,
      why = "Horde escort Freedom to Ruul starts here and ends south of the camp (38, 37)." },
    -- (Keeper Ordanus)
    { name = "Raynewood Retreat", map = ASHENVALE, x = 0.620, y = 0.510, why = "Horde kill quest Ordanus (Keeper Ordanus)." },
    -- (the Foulweald Totem Mound object)
    { name = "Foulweald Totem Mound", map = ASHENVALE, x = 0.564, y = 0.635,
      why = "Horde banner quest King of the Foulweald: the banner goes here." },
    -- (Dor'Danil Pillar)
    { name = "Dor'Danil Barrow Den", map = ASHENVALE, x = 0.760, y = 0.740, why = "Forsaken camp right on top of it." },
    -- (Silverwing Sentinels; Torek's escort ends at 64.6, 75.3)
    { name = "Silverwing Outpost", map = ASHENVALE, x = 0.650, y = 0.750,
      why = "Horde escort Torek's Assault attacks here (starts at 68, 75)." },
    -- (the Circle of Imprisonment)
    { name = "Satyrnaar", map = ASHENVALE, x = 0.816, y = 0.486, why = "Satyr camp" },
}

local seen = {}            -- key -> { key, name, cls, level, map, x, y, at, by }
local sentAt, heardAt = {}, {}
local pending, flushing = {}, false
local stats = { seen = 0, sent = 0, recv = 0 }

local function now() return ns.now() end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
function Patrol.Ago(secs)
    secs = math.max(0, math.floor(secs))
    if secs < 60 then return "just now" end
    if secs < 3600 then return ("%d min ago"):format(math.floor(secs / 60)) end
    return ("%d h ago"):format(math.floor(secs / 3600))
end

-- Colour by age: red while fresh, orange, then grey.
function Patrol.AgeColor(secs)
    if secs < 300 then return 1, 0.25, 0.2 end
    if secs < 900 then return 1, 0.6, 0.15 end
    return 0.62, 0.62, 0.62
end

-- Yards between two points on one map, or nil.
local function yards(map, x1, y1, x2, y2)
    if not ns.MapMini then return nil end
    local w, h = ns.MapMini.ZoneSize(map)
    if not (w and h) then return nil end
    local dx, dy = (x1 - x2) * w, (y1 - y2) * h
    return math.sqrt(dx * dx + dy * dy)
end

-- The hotspot a point is at (within NEAR yards), or nil.
function Patrol.SpotAt(map, x, y)
    local best, bestD
    for _, s in ipairs(Patrol.HOTSPOTS) do
        if s.map == map then
            local d = yards(map, x, y, s.x, s.y)
            if d and d <= NEAR and (not bestD or d < bestD) then best, bestD = s, d end
        end
    end
    return best
end

local function prune()
    local t = now()
    local n = 0
    for k, r in pairs(seen) do
        if t - r.at > KEEP then seen[k] = nil else n = n + 1 end
    end
    if n > MAX_STORE then
        local list = {}
        for _, r in pairs(seen) do list[#list + 1] = r end
        table.sort(list, function(a, b) return a.at > b.at end)
        for i = MAX_STORE + 1, #list do seen[list[i].key] = nil end
    end
end

-- Sightings, newest first. `maxAge` defaults to KEEP; `map` filters.
-- Cached for half a second (the minimap asks 20 times a second); any new
-- sighting clears the cache. Callers must not change the list.
local cache, version = {}, 0
local function changed() version = version + 1 end
function Patrol.Recent(maxAge, map)
    local t = now()
    local ck = tostring(maxAge) .. ":" .. tostring(map)
    local c = cache[ck]
    if c and c.ver == version and t - c.at < 0.5 then return c.list end
    prune()
    local list = {}
    for _, r in pairs(seen) do
        if t - r.at <= (maxAge or KEEP) and (not map or r.map == map) then list[#list + 1] = r end
    end
    table.sort(list, function(a, b) if a.at ~= b.at then return a.at > b.at end return a.key < b.key end)
    cache[ck] = { at = t, ver = version, list = list }
    return list
end

-- Latest sighting at a hotspot: the record, how many players were seen
-- there within 5 minutes of it, and all sightings there (newest first).
function Patrol.LastAt(spot)
    local last, n, all = nil, 0, {}
    for _, r in ipairs(Patrol.Recent(KEEP, spot.map)) do
        local d = yards(spot.map, r.x, r.y, spot.x, spot.y)
        if d and d <= NEAR then
            if not last then last = r end
            if last.at - r.at <= 300 then n = n + 1 end
            all[#all + 1] = r
        end
    end
    return last, n, all
end

function Patrol.On() return ns.db and ns.db.patrol end

function Patrol.Set(on)
    ns.db.patrol = on and true or false
    ns.fire("SETTINGS", "patrol")
    if ns.MapWorld and ns.MapWorld.Refresh then ns.MapWorld.Refresh() end
    if ns.UI then ns.UI.Refresh() end
end

---------------------------------------------------------------------------
-- Seeing enemies
---------------------------------------------------------------------------
local function inArea()
    return ns.Leaderboard and ns.Leaderboard.Counts and ns.Leaderboard.Counts() or false
end

-- name, classFile, level of an enemy player unit, or nil.
function Patrol.ReadEnemy(unit)
    if ns.try(UnitIsPlayer, unit) ~= true then return end
    local fac, mine = ns.try(UnitFactionGroup, unit), ns.try(UnitFactionGroup, "player")
    if type(fac) ~= "string" or type(mine) ~= "string" or fac == mine then return end
    if fac ~= "Horde" and fac ~= "Alliance" then return end
    local first, last = ns.try(UnitName, unit)
    if type(first) ~= "string" or first == "" or first == UNKNOWNOBJECT or first == "Unknown" then return end
    local name = first
    if type(last) == "string" and ns.readable(last) and last ~= "" then name = first .. " " .. last end
    local _, cls = ns.try(UnitClass, unit)
    local level = ns.try(UnitLevel, unit)
    if type(cls) ~= "string" then cls = nil end
    if type(level) ~= "number" then level = nil end
    return name, cls, level
end

local flush

local function observe(unit)
    if not inArea() then return end
    local name, cls, level = Patrol.ReadEnemy(unit)
    if not name then return end
    local key = ns.key(name)
    if not key then return end
    local map, x, y = ns.Position.ReadMine()
    if not (map and x and y) then return end
    local t = now()
    local r = seen[key] or { key = key }
    r.name, r.cls, r.level = name, cls or r.cls, level or r.level
    r.map, r.x, r.y, r.at, r.by = map, x, y, t, ns.meKey
    seen[key] = r
    changed()
    stats.seen = stats.seen + 1
    if ns.db.shareSightings == false then return end
    if sentAt[key] and t - sentAt[key] < RESEND then return end
    if heardAt[key] and t - heardAt[key] < HEARD then return end
    pending[key] = true
    if not flushing then
        flushing = true
        ns.after(FLUSH, flush, "sightings send")
    end
end
Patrol.Observe = observe

local function scanPlates()
    if not inArea() then return end
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
    local plates = ns.try(C_NamePlate.GetNamePlates)
    if type(plates) ~= "table" then return end
    for _, plate in ipairs(plates) do
        local u = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
        if u then observe(u) end
    end
end

local CLASS_OK = "^[A-Z]+$"

flush = function()
    flushing = false
    local map, x, y = ns.Position.ReadMine()
    if not (map and x and y) then pending = {}; return end
    local entries = {}
    local t = now()
    for key in pairs(pending) do
        local r = seen[key]
        if r and not (heardAt[key] and t - heardAt[key] < HEARD) then
            local cls = r.cls and r.cls:match(CLASS_OK) and r.cls or ""
            entries[#entries + 1] = ("%s:%s:%s"):format(ns.address(r.name) or key, cls, r.level or "")
            sentAt[key] = t
        end
    end
    pending = {}
    table.sort(entries)
    local head = ("S|%d|%d|%.4f|%.4f|"):format(ns.Comm.PROTO, map, x, y)
    local cur, len = {}, #head
    local function send()
        if #cur == 0 then return end
        ns.Comm.Send({ "S", ns.Comm.PROTO, map, ("%.4f"):format(x), ("%.4f"):format(y), table.concat(cur, ",") }, "GUILD")
        stats.sent = stats.sent + 1
        cur, len = {}, #head
    end
    for _, e in ipairs(entries) do
        if #cur > 0 and (len + 1 + #e > 240 or #cur >= MAX_ENTRIES) then send() end
        cur[#cur + 1] = e
        len = len + #e + 1
    end
    send()
end

local function onS(f, sender, senderKey)
    local map, x, y = tonumber(f[3]), tonumber(f[4]), tonumber(f[5])
    if not (map and x and y and f[6]) or x < 0 or x > 1 or y < 0 or y > 1 then return end
    local t = now()
    local n = 0
    for item in f[6]:gmatch("[^,]+") do
        n = n + 1
        if n > MAX_ENTRIES then break end
        local name, cls, level = item:match("^([^:]+):([A-Z]*):(%-?%d*)$")
        local key = ns.key(name)
        if key and key ~= ns.meKey and not ns.Roster.IsMember(key) then
            local r = seen[key] or { key = key }
            r.name = name:gsub("%-", " ")
            if cls ~= "" then r.cls = cls end
            if tonumber(level) then r.level = tonumber(level) end
            r.map, r.x, r.y, r.at, r.by = map, x, y, t, senderKey
            seen[key] = r
            changed()
            heardAt[key] = t
            stats.recv = stats.recv + 1
        end
    end
    if ns.UI then ns.UI.Refresh() end
end

---------------------------------------------------------------------------
-- Tooltips
---------------------------------------------------------------------------
local function byName(key)
    if not key then return "?" end
    if key == ns.meKey then return "you" end
    local m = ns.Roster.Get(key)
    return m and m.name or key
end

function Patrol.AddSightingLines(tt, list, max)
    local t = now()
    max = max or 8
    for i, r in ipairs(list) do
        if i > max then tt:AddLine(("and %d more"):format(#list - max), 0.62, 0.62, 0.62); break end
        local cr, cg, cb = ns.classColor(r.cls)
        local cls = r.cls and (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[r.cls] or r.cls:sub(1, 1) .. r.cls:sub(2):lower())
        local desc = ((r.level and r.level > 0) and ("%d "):format(r.level) or "") .. (cls or "")
        tt:AddDoubleLine(r.name, desc, cr, cg, cb, 0.8, 0.8, 0.8)
        local ar, ag, ab = Patrol.AgeColor(t - r.at)
        tt:AddLine(("  seen %s by %s"):format(Patrol.Ago(t - r.at), byName(r.by)), ar, ag, ab)
    end
end

function Patrol.AddSpotLines(tt, s)
    tt:AddLine(s.name, SPOT_COLOR[1], SPOT_COLOR[2], SPOT_COLOR[3])
    if s.why then tt:AddLine(s.why, 0.8, 0.8, 0.8) end
    local last, n, all = Patrol.LastAt(s)
    if last then
        local age = now() - last.at
        local r, g, b = Patrol.AgeColor(age)
        tt:AddLine(("Horde seen here %s%s"):format(Patrol.Ago(age), n > 1 and (" (%d players)"):format(n) or ""), r, g, b)
        tt:AddLine(" ")
        Patrol.AddSightingLines(tt, all, 5)
    else
        tt:AddLine("No Horde seen here in the last 30 min", 0.62, 0.62, 0.62)
    end
end

---------------------------------------------------------------------------
-- Pins (shared by both maps): a hotspot ring, a sighting mark.
---------------------------------------------------------------------------
local function newSpotPin(parent, size, label)
    local p = ns.NewFrame("Frame", parent)
    p:SetSize(size, size)
    p.outline = p:CreateTexture(nil, "ARTWORK", nil, 1)
    p.outline:SetTexture(RING); p.outline:SetAllPoints(); p.outline:SetVertexColor(0, 0, 0, 0.85)
    p.ring = p:CreateTexture(nil, "ARTWORK", nil, 2)
    p.ring:SetTexture(RING)
    p.ring:SetPoint("TOPLEFT", 1, -1); p.ring:SetPoint("BOTTOMRIGHT", -1, 1)
    p.ring:SetVertexColor(SPOT_COLOR[1], SPOT_COLOR[2], SPOT_COLOR[3], 1)
    p.core = p:CreateTexture(nil, "ARTWORK", nil, 3)
    p.core:SetTexture(CIRCLE)
    p.core:SetPoint("CENTER"); p.core:SetSize(size * 0.3, size * 0.3)
    p.core:SetVertexColor(SPOT_COLOR[1], SPOT_COLOR[2], SPOT_COLOR[3], 1)
    if label then
        p.label = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        p.label:SetPoint("TOP", p, "BOTTOM", 0, -1)
    end
    return p
end

local function newMark(parent, size)
    local m = ns.NewFrame("Frame", parent)
    m:SetSize(size, size)
    m.outline = m:CreateTexture(nil, "ARTWORK", nil, 1)
    m.outline:SetTexture(CIRCLE); m.outline:SetAllPoints(); m.outline:SetVertexColor(0, 0, 0, 0.9)
    m.fill = m:CreateTexture(nil, "ARTWORK", nil, 2)
    m.fill:SetTexture(CIRCLE)
    m.fill:SetPoint("TOPLEFT", 1.5, -1.5); m.fill:SetPoint("BOTTOMRIGHT", -1.5, 1.5)
    m.fill:SetVertexColor(0.9, 0.12, 0.1, 1)
    return m
end

local function styleMark(m, r)
    local age = now() - r.at
    m:SetAlpha(math.max(0.25, 1 - 0.75 * age / SHOW))
end

local function styleSpot(p, s)
    local last = Patrol.LastAt(s)
    local age = last and now() - last.at
    if p.label then
        if last and age < SHOW then
            local r, g, b = Patrol.AgeColor(age)
            p.label:SetText(("%s\n|cff%02x%02x%02x%s|r"):format(s.name, math.floor(r * 255), math.floor(g * 255), math.floor(b * 255), Patrol.Ago(age)))
        else
            p.label:SetText(s.name)
        end
    end
    -- A ring turns red while Horde were seen there in the last 5 minutes.
    if last and age < 300 then p.ring:SetVertexColor(1, 0.3, 0.2, 1) else
        p.ring:SetVertexColor(SPOT_COLOR[1], SPOT_COLOR[2], SPOT_COLOR[3], 1) end
end

-- Things under the cursor among `frames` (each with .item), nearest first.
local function underCursor(frames, radius)
    local cx, cy = GetCursorPosition()
    local hits = {}
    for _, f in ipairs(frames) do
        if f:IsShown() and f.item then
            local x, y = f:GetCenter()
            local s = f:GetEffectiveScale()
            if x and y and s and s > 0 then
                local dx, dy = cx / s - x, cy / s - y
                local d = dx * dx + dy * dy
                local r = radius or (f:GetWidth() / 2 + 2)
                if d <= r * r then hits[#hits + 1] = { f = f, d = d } end
            end
        end
    end
    table.sort(hits, function(a, b) return a.d < b.d end)
    return hits
end

-- Fill GameTooltip with hotspots then sightings among `hits`.
local function hitsTooltip(owner, hits)
    local spots, marks = {}, {}
    for _, h in ipairs(hits) do
        if h.f.kind == "spot" then spots[#spots + 1] = h.f.item else marks[#marks + 1] = h.f.item end
    end
    table.sort(marks, function(a, b) return a.at > b.at end)
    GameTooltip:SetOwner(owner, "ANCHOR_CURSOR")
    for i, s in ipairs(spots) do
        if i > 1 then GameTooltip:AddLine(" ") end
        Patrol.AddSpotLines(GameTooltip, s)
    end
    if #marks > 0 then
        if #spots > 0 then GameTooltip:AddLine(" ") end
        if #spots == 0 then GameTooltip:AddLine("Horde seen near here", 1, 0.82, 0) end
        Patrol.AddSightingLines(GameTooltip, marks)
    end
    GameTooltip:Show()
end

local function hitsKey(hits)
    local k = {}
    for i, h in ipairs(hits) do k[i] = (h.f.kind == "spot" and h.f.item.name) or h.f.item.key end
    table.sort(k)
    return table.concat(k, ",")
end

---------------------------------------------------------------------------
-- World map (drawn on MapWorld's root, the same way as guildie dots)
---------------------------------------------------------------------------
local W = { spots = {}, marks = {}, shown = {}, tip = nil }

function Patrol.HideWorld()
    for _, p in ipairs(W.spots) do p:Hide(); p.item = nil end
    for _, m in ipairs(W.marks) do m:Hide(); m.item = nil end
    W.shown = {}
    if W.tip and GameTooltip:GetOwner() == W.tip.owner then GameTooltip:Hide() end
    W.tip = nil
end

local function placeWorld(f, w, h)
    f:ClearAllPoints()
    f:SetPoint("CENTER", W.root, "TOPLEFT", f.fx * w, -f.fy * h)
end

function Patrol.DrawWorld(root, map, w, h)
    if not (Patrol.On() and root and map and w and h) then Patrol.HideWorld(); return end
    W.root = root
    local shown = {}
    local n = 0
    for _, s in ipairs(Patrol.HOTSPOTS) do
        if s.map == map then
            n = n + 1
            local p = W.spots[n]
            if not p then p = newSpotPin(root, 18, true); p.kind = "spot"; W.spots[n] = p end
            p.item, p.fx, p.fy = s, s.x, s.y
            styleSpot(p, s)
            placeWorld(p, w, h)
            p:Show()
            shown[#shown + 1] = p
        end
    end
    for i = n + 1, #W.spots do W.spots[i]:Hide(); W.spots[i].item = nil end
    n = 0
    for _, r in ipairs(Patrol.Recent(SHOW, map)) do
        n = n + 1
        local m = W.marks[n]
        if not m then m = newMark(root, 9); m.kind = "mark"; W.marks[n] = m end
        m.item, m.fx, m.fy = r, r.x, r.y
        styleMark(m, r)
        placeWorld(m, w, h)
        m:Show()
        shown[#shown + 1] = m
    end
    for i = n + 1, #W.marks do W.marks[i]:Hide(); W.marks[i].item = nil end
    W.shown = shown
end

function Patrol.PlaceWorld(w, h)
    if not W.root then return end
    for _, f in ipairs(W.shown) do if f.fx then placeWorld(f, w, h) end end
end

-- Hover on the world map. `active`: the cursor is on the map and nothing of
-- the game's or ours (guildies) has the tooltip. Returns true when showing.
function Patrol.WorldHover(active)
    local hits = active and Patrol.On() and underCursor(W.shown) or {}
    if #hits == 0 then
        if W.tip and GameTooltip:GetOwner() == W.tip.owner then GameTooltip:Hide() end
        W.tip = nil
        return false
    end
    local key = hitsKey(hits)
    local owner = hits[1].f
    if W.tip and W.tip.key == key and GameTooltip:IsShown() and GameTooltip:GetOwner() == W.tip.owner then return true end
    hitsTooltip(owner, hits)
    W.tip = { key = key, owner = owner }
    return true
end

---------------------------------------------------------------------------
-- Minimap (MapMini passes its geometry each tick)
---------------------------------------------------------------------------
local M = { spots = {}, marks = {}, shown = {}, hover = nil }

local function miniHoverable(f)
    if f.SetMouseMotionEnabled then
        pcall(f.SetMouseMotionEnabled, f, true)
        if f.SetMouseClickEnabled then pcall(f.SetMouseClickEnabled, f, false) end
    else
        f:EnableMouse(true)
    end
    f:SetScript("OnEnter", ns.guard(function(self)
        M.hover = self
        local hits = underCursor(M.shown, 6)
        if #hits == 0 and self.item then hits = { { f = self, d = 0 } } end
        if #hits > 0 then hitsTooltip(self, hits) end
    end, "patrol minimap hover"))
    f:SetScript("OnLeave", ns.guard(function(self)
        if M.hover == self then M.hover = nil end
        if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
    end, "patrol minimap leave"))
end

function Patrol.HideMini()
    for _, p in ipairs(M.spots) do p:Hide(); p.item = nil end
    for _, m in ipairs(M.marks) do m:Hide(); m.item = nil end
    if M.hover and GameTooltip:GetOwner() == M.hover then GameTooltip:Hide() end
    M.shown, M.hover = {}, nil
end

function Patrol.DrawMini(holder, map, px, py, w, h, ppy, facing, half)
    if not Patrol.On() then Patrol.HideMini(); return end
    local shown = {}
    local function place(f, x, y, size)
        local dx, dy = ns.MapMini.Offset(x, y, px, py, w, h, ppy, facing)
        local limit = half - size / 2 - 1
        if dx * dx + dy * dy > limit * limit then return false end
        f:SetPoint("CENTER", holder, "CENTER", dx, dy)
        return true
    end
    local n = 0
    for _, s in ipairs(Patrol.HOTSPOTS) do
        if s.map == map then
            local p = M.spots[n + 1]
            if not p then
                p = newSpotPin(holder, 14, false); p.kind = "spot"
                p:SetFrameLevel(holder:GetFrameLevel() + 1)
                miniHoverable(p)
                M.spots[n + 1] = p
            end
            if place(p, s.x, s.y, 14) then
                n = n + 1
                p.item = s
                styleSpot(p, s)
                p:Show()
                shown[#shown + 1] = p
            end
        end
    end
    for i = n + 1, #M.spots do M.spots[i]:Hide(); M.spots[i].item = nil end
    n = 0
    for _, r in ipairs(Patrol.Recent(SHOW, map)) do
        local m = M.marks[n + 1]
        if not m then
            m = newMark(holder, 8); m.kind = "mark"
            m:SetFrameLevel(holder:GetFrameLevel() + 2)
            miniHoverable(m)
            M.marks[n + 1] = m
        end
        if place(m, r.x, r.y, 8) then
            n = n + 1
            m.item = r
            styleMark(m, r)
            m:Show()
            shown[#shown + 1] = m
        end
    end
    for i = n + 1, #M.marks do M.marks[i]:Hide(); M.marks[i].item = nil end
    M.shown = shown
    if M.hover and not M.hover:IsShown() then
        if GameTooltip:GetOwner() == M.hover then GameTooltip:Hide() end
        M.hover = nil
    end
end

---------------------------------------------------------------------------
-- Page
---------------------------------------------------------------------------
local SPOT_ROWS = 9
local SIGHT_ROWS = 15

local function build(f)
    local UI = ns.UI
    Patrol.page = f
    f.title = UI.Text(f, "big", UI.GOLD, "LEFT"); f.title:SetPoint("TOPLEFT", 0, 0)
    f.title:SetText("Patrol")
    f.sub = UI.Text(f, "small", UI.GREY, "LEFT"); f.sub:SetPoint("TOPLEFT", 0, -22); f.sub:SetWidth(400)
    f.toggle = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.toggle:SetSize(110, 22)
    f.toggle:SetPoint("TOPRIGHT", 0, 2)
    f.toggle:SetScript("OnClick", function() Patrol.Set(not Patrol.On()) end)

    local y = -46
    local h1 = UI.Text(f, nil, UI.GOLD, "LEFT"); h1:SetPoint("TOPLEFT", 0, y); h1:SetText("Hotspots")
    local h2 = UI.Text(f, nil, UI.GOLD, "LEFT"); h2:SetPoint("TOPLEFT", 236, y); h2:SetText("Horde seen (last 30 min)")
    local line = f:CreateTexture(nil, "ARTWORK"); line:SetColorTexture(0.35, 0.28, 0.08, 1)
    line:SetPoint("TOPLEFT", 0, y - 16); line:SetSize(528, 1)

    f.spots = {}
    for i = 1, SPOT_ROWS do
        local r = CreateFrame("Frame", nil, f)
        r:SetSize(224, 32)
        r:SetPoint("TOPLEFT", 0, y - 22 - (i - 1) * 32)
        r.name = UI.Text(r, nil, nil, "LEFT"); r.name:SetPoint("TOPLEFT", 0, 0); r.name:SetWidth(224)
        r.name:SetTextColor(SPOT_COLOR[1], SPOT_COLOR[2], SPOT_COLOR[3])
        r.last = UI.Text(r, "small", UI.GREY, "LEFT"); r.last:SetPoint("TOPLEFT", 0, -14); r.last:SetWidth(224)
        f.spots[i] = r
    end
    f.sights = {}
    for i = 1, SIGHT_ROWS do
        local r = CreateFrame("Frame", nil, f)
        r:SetSize(292, 19)
        r:SetPoint("TOPLEFT", 236, y - 22 - (i - 1) * 19)
        r.name = UI.Text(r, nil, nil, "LEFT"); r.name:SetPoint("LEFT", 0, 0); r.name:SetWidth(120)
        r.where = UI.Text(r, "small", UI.GREY, "LEFT"); r.where:SetPoint("LEFT", 124, 0); r.where:SetWidth(110)
        r.ago = UI.Text(r, "small", nil, "RIGHT"); r.ago:SetPoint("RIGHT", 0, 0); r.ago:SetWidth(60)
        f.sights[i] = r
    end
    f.empty = UI.Text(f, "small", UI.GREY, "LEFT"); f.empty:SetPoint("TOPLEFT", 236, y - 26); f.empty:SetWidth(290)
    f.foot = UI.Text(f, "small", UI.GREY, "LEFT"); f.foot:SetPoint("BOTTOMLEFT", 0, 0); f.foot:SetWidth(528)
    f.foot:SetText("A sighting is where the guildie was when they saw the Horde player (nameplate, target or mouseover), so within about 40 yards. Sightings are shared in Ashenvale and at Stonetalon Peak.")
end

local function mapName(map)
    local info = map and ns.try(C_Map.GetMapInfo, map)
    return type(info) == "table" and info.name or "?"
end

local function refresh(f)
    local on = Patrol.On()
    f.toggle:SetText(on and "End patrol" or "Start patrol")
    f.sub:SetText(on and "|cff1eff00On patrol.|r Hotspots and sightings are on your world map and minimap."
        or "Start a patrol to see hotspots and Horde sightings on your maps.")
    local t = now()
    for i, r in ipairs(f.spots) do
        local s = Patrol.HOTSPOTS[i]
        if s then
            r.name:SetText(s.name)
            local last, n = Patrol.LastAt(s)
            if last then
                local cr, cg, cb = Patrol.AgeColor(t - last.at)
                r.last:SetText(("Horde %s%s"):format(Patrol.Ago(t - last.at), n > 1 and (" (%d)"):format(n) or ""))
                r.last:SetTextColor(cr, cg, cb)
            else
                r.last:SetText("quiet")
                r.last:SetTextColor(0.62, 0.62, 0.62)
            end
            r:Show()
        else
            r:Hide()
        end
    end
    local list = Patrol.Recent(KEEP)
    for i, row in ipairs(f.sights) do
        local r = list[i]
        if r then
            local cr, cg, cb = ns.classColor(r.cls)
            row.name:SetText(((r.level and r.level > 0) and ("|cffbbbbbb%d|r "):format(r.level) or "") .. r.name)
            row.name:SetTextColor(cr, cg, cb)
            local spot = Patrol.SpotAt(r.map, r.x, r.y)
            row.where:SetText(spot and spot.name or mapName(r.map))
            local ar, ag, ab = Patrol.AgeColor(t - r.at)
            row.ago:SetText(Patrol.Ago(t - r.at)); row.ago:SetTextColor(ar, ag, ab)
            row:Show()
        else
            row:Hide()
        end
    end
    f.empty:SetShown(#list == 0)
    f.empty:SetText("No Horde seen yet. Sightings from every guildie with the addon show up here.")
end

ns.UI.AddPage(6, "Patrol", build, refresh)

---------------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------------
ns.onLogin(function()
    ns.Comm.handlers.S = onS
    ns:On("NAME_PLATE_UNIT_ADDED", function(unit) observe(unit) end)
    ns:On("UPDATE_MOUSEOVER_UNIT", function() observe("mouseover") end)
    ns:On("PLAYER_TARGET_CHANGED", function() observe("target") end)
    ns.every(3, scanPlates, "patrol plates")
    -- The page shows ages: keep it ticking while open.
    ns.every(10, function()
        if Patrol.page and Patrol.page:IsVisible() then ns.UI.Refresh() end
    end, "patrol page")
end, "patrol")

ns.slash.patrol = { help = "on | off - patrol mode: hotspots and Horde sightings on your maps", fn = function(arg)
    arg = (arg or ""):lower()
    if arg == "on" then Patrol.Set(true)
    elseif arg == "off" then Patrol.Set(false)
    elseif arg == "stats" then
        ns.print(("sightings: %d seen by me, %d messages sent, %d received, %d kept."):format(
            stats.seen, stats.sent, stats.recv, #Patrol.Recent(KEEP)))
        return
    else Patrol.Set(not Patrol.On()) end
    ns.print("patrol mode is " .. (Patrol.On() and "on: hotspots and sightings are on your maps." or "off."))
end }

function Patrol.Debug() return seen, W, M end
