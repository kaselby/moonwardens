-- MapMini: guildie dots on the minimap.
-- Same zone only. Offsets in yards come from the zone's size in world
-- coordinates; the minimap's view radius from C_Minimap.GetViewRadius (falls
-- back to the Classic zoom table). Rotating minimap supported. Dots past the
-- edge are hidden (the alert edge pip comes with alerts).
local _, ns = ...
local MapMini = {}
ns.MapMini = MapMini

local DOT_SIZE = ns.DOT_DIAMOND or 11   -- (MapWorld.lua loads first)
local TICK = 0.05
local HOVER_RADIUS = 6

-- Classic minimap diameters in yards by zoom level, outdoors and indoors.
local OUTDOOR = { [0] = 466.67, 400, 333.33, 266.67, 200, 133.33 }
local INDOOR = { [0] = 300, 240, 180, 120, 80, 50 }

local holder, driver, pip
local halos = {}            -- gold rings around group members' game dots
local dots, used = {}, 0
local sizes = {}            -- map -> { w, h } in yards, or { fail = time }
local acc, hoverAcc = 0, 0
local tipKey                -- hovered guildies in the tooltip we own, or nil
local gameDrives = false    -- hooked the game's Minimap_OnUpdate (see below)

---------------------------------------------------------------------------
-- Hover: guildies join the minimap's own tooltip, the way party members do.
-- The game builds that tooltip (GameTooltip:SetMinimapMouseover: flight
-- masters, nodes, party members...) every frame while something is under
-- the cursor. A post-call adds our guildie lines to it each time, so it is one
-- tooltip with everything in it. Only when the game has nothing to show do we
-- show GameTooltip ourselves, with the same lines; once it has, we step back.
---------------------------------------------------------------------------

-- Is the mouse over the minimap? By area, not by mouse focus: another
-- addon's pin on the minimap may hold the focus (0.5.4 checked focus, and
-- hovering showed nothing in game). An open world map on top doesn't count.
local function overMinimap()
    if not holder:IsMouseOver() then return false end
    if WorldMapFrame and WorldMapFrame:IsShown() and WorldMapFrame:IsMouseOver() then return false end
    return true
end

-- Is the game's own minimap hover running (its OnUpdate is set while the
-- mouse is on the minimap and the minimap has the focus)?
local function gameHovering()
    local ok, fn = pcall(Minimap.GetScript, Minimap, "OnUpdate")
    return ok and fn ~= nil
end

local dbg = { hook = 0, added = 0, dot = 0 }   -- counters for /mw hover
local addedAt = -10         -- when the game-hover hook last added our lines
local hoverDot              -- our dot under the mouse (dots take mouse motion, not clicks)

-- Guildies whose dots are under the cursor, sorted by name (a stable order).
local function hovered()
    if used == 0 or not holder or not overMinimap() then return {} end
    return ns.SortHits(ns.DotsUnderCursor(dots, used, HOVER_RADIUS))
end

-- Each guildie as in 0.5.1, the name a notch bigger under the game's lines
-- (shared with the world map: ns.AddGuildieLines in MapWorld.lua).
local function addLines(tt, hits) ns.AddGuildieLines(tt, hits) end

-- The game's minimap tooltip is being built: add our guildies to it.
local function onMinimapTooltip(tt)
    if tt ~= GameTooltip then return end
    local hits = hovered()
    if #hits > 0 then addLines(tt, hits) end
end

-- Does the game have minimap lines of its own under the cursor right now?
local function gameHasLines()
    local get = C_TooltipInfo and C_TooltipInfo.GetMinimapMouseover
    if not get then return false end
    local ok, data = pcall(get)
    if not ok or type(data) ~= "table" or not ns.readable(data) then return false end
    local lines = data.lines
    return type(lines) == "table" and ns.readable(lines) and #lines > 0
end

-- The game's own minimap hover (Blizzard_Minimap, Forever and retail): while
-- the mouse is over the minimap, Minimap_OnUpdate runs EVERY frame and does
--   GameTooltip:SetOwner(UIParent, "ANCHOR_CURSOR"); GameTooltip:SetMinimapMouseover()
-- which wipes any tooltip we showed a moment before (0.5.1, 0.5.2-test: the
-- guildie tooltip never showed in game). So we add our lines right after it,
-- every frame, in a hook: one tooltip, the game's lines (if any) then ours.
local function afterGameHover()
    dbg.hook = dbg.hook + 1
    if used == 0 or not holder or not holder:IsVisible() then return end
    if GameTooltip:GetOwner() ~= UIParent then return end   -- (someone else's tooltip now)
    local hits = ns.SortHits(ns.DotsUnderCursor(dots, used, HOVER_RADIUS))
    if #hits == 0 then return end
    addLines(GameTooltip, hits)
    GameTooltip:Show()
    dbg.added = dbg.added + 1
    addedAt = ns.now()
end

-- Is the hook above really putting our lines in the game's tooltip? If the
-- minimap kept its own reference to Minimap_OnUpdate, hooking the global
-- never runs (a likely reason 0.5.2-0.5.4 showed nothing in game), so we
-- trust it only while it is seen working.
local function hookWorking()
    return gameDrives and gameHovering() and ns.now() - addedAt < 0.2
end

-- Dots take mouse motion (not clicks: pings and clicks still reach the
-- minimap), so the mouse over a dot is the game telling us, as for any
-- minimap pin addon (HandyNotes, GatherMate). The tooltip is ours, on the dot,
-- with every guildie whose dot is under the cursor.
local function showDotTooltip(d)
    local hits = ns.SortHits(ns.DotsUnderCursor(dots, used, HOVER_RADIUS))
    if #hits == 0 and d.g then hits = { { d = d, dist = 0 } } end
    if #hits == 0 then return end
    local setKey = ns.HitsKey(hits)
    if setKey == tipKey and GameTooltip:IsShown() and GameTooltip:GetOwner() == d then return end
    GameTooltip:SetOwner(d, "ANCHOR_CURSOR")
    addLines(GameTooltip, hits)
    GameTooltip:Show()
    tipKey = setKey
    dbg.dot = dbg.dot + 1
end

local function makeHoverable(d)
    if d.SetMouseMotionEnabled then
        pcall(d.SetMouseMotionEnabled, d, true)
        if d.SetMouseClickEnabled then pcall(d.SetMouseClickEnabled, d, false) end
    else
        d:EnableMouse(true)
    end
    d:SetScript("OnEnter", ns.guard(function(self)
        hoverDot = self
        if not hookWorking() then showDotTooltip(self) end
    end, "minimap dot hover"))
    d:SetScript("OnLeave", ns.guard(function(self)
        if hoverDot == self then hoverDot = nil end
        if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
        tipKey = nil
    end, "minimap dot leave"))
end

-- Every hover tick (clients without Minimap_OnUpdate only): own GameTooltip
-- only while the game isn't using it.
local function updateHover()
    local shown, owner = GameTooltip:IsShown(), GameTooltip:GetOwner()
    if shown and owner ~= holder then
        tipKey = nil                -- the game's tooltip (or another's): ours ride along in it
        return
    end
    local hits = hovered()
    if #hits == 0 then
        if tipKey and owner == holder then GameTooltip:Hide() end
        tipKey = nil
        return
    end
    -- Something of the game's is under the cursor too (a flight master, a
    -- node): build its tooltip the way the game does, and our post-call adds
    -- the guildies under its lines. Rebuilt each tick, as the game does.
    if GameTooltip.SetMinimapMouseover and gameHasLines() then
        GameTooltip:SetOwner(holder, "ANCHOR_CURSOR")
        local ok = pcall(GameTooltip.SetMinimapMouseover, GameTooltip)
        if ok then
            GameTooltip:Show()
            tipKey = "game"
            return
        end
    end
    local setKey = ns.HitsKey(hits)
    if setKey == tipKey and shown and owner == holder then return end
    GameTooltip:SetOwner(holder, "ANCHOR_CURSOR")
    addLines(GameTooltip, hits)
    GameTooltip:Show()
    tipKey = setKey
end

function MapMini.ZoneSize(map)
    local s = sizes[map]
    if s and s.w then return s.w, s.h end
    if s and s.fail and ns.now() - s.fail < 10 then return end
    local ok, w, h = pcall(function()
        local _, a = C_Map.GetWorldPosFromMapPos(map, CreateVector2D(0, 0))
        local _, b = C_Map.GetWorldPosFromMapPos(map, CreateVector2D(1, 0))
        local _, c = C_Map.GetWorldPosFromMapPos(map, CreateVector2D(0, 1))
        local w = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
        local h = math.sqrt((c.x - a.x) ^ 2 + (c.y - a.y) ^ 2)
        return w + 0, h + 0
    end)
    if ok and w and w > 0 and h > 0 then
        sizes[map] = { w = w, h = h }
        return w, h
    end
    sizes[map] = { fail = ns.now() }
end

function MapMini.ViewRadius()
    if C_Minimap and C_Minimap.GetViewRadius then
        local r = ns.try(C_Minimap.GetViewRadius)
        if type(r) == "number" and r > 0 then return r end
    end
    local zoom = ns.try(Minimap.GetZoom, Minimap) or 0
    local indoors = ns.try(IsIndoors) == true
    local d = (indoors and INDOOR or OUTDOOR)[zoom] or 466.67
    return d / 2
end

local function rotating()
    local get = C_CVar and C_CVar.GetCVar or GetCVar
    return ns.try(get, "rotateMinimap") == "1"
end

local function hideFrom(n)
    for i = n + 1, used do
        local d = dots[i]
        d:Hide(); d.g = nil
        if hoverDot == d then
            hoverDot = nil
            if GameTooltip:GetOwner() == d then GameTooltip:Hide() end
            tipKey = nil
        end
    end
    used = n
end

local function hideHalos(from)
    for i = (from or 0) + 1, #halos do halos[i]:Hide() end
end

-- A ring around each group member's own minimap dot (positions from the
-- game, as its dots are). Out of minimap range (the game shows an edge
-- arrow then): no ring.
local function updateHalos(map, px, py, w, h, ppy, facing, half)
    local n = 0
    local limit = half - 4
    for _, p in ipairs(ns.GroupPositions(map)) do
        local dx, dy = MapMini.Offset(p.x, p.y, px, py, w, h, ppy, facing)
        if dx * dx + dy * dy <= limit * limit then
            n = n + 1
            local r = halos[n]
            if not r then
                r = ns.NewHalo(holder, 18)
                r:SetFrameLevel(holder:GetFrameLevel() + 1)
                halos[n] = r
            end
            r:SetPoint("CENTER", holder, "CENTER", dx, dy)
            r:Show()
        end
    end
    hideHalos(n)
end

local function inInstance()
    local inside, kind = ns.try(IsInInstance)
    return inside == true and kind ~= "none"
end

-- Minimap offset in pixels of a point at map fraction (x, y), seen from the
-- player at (px, py). Exposed for tests and for the alert pip.
function MapMini.Offset(x, y, px, py, w, h, pxPerYard, facing)
    local dx = (x - px) * w * pxPerYard
    local dy = -(y - py) * h * pxPerYard
    if facing then
        local s, c = math.sin(facing), math.cos(facing)
        dx, dy = dx * c - dy * s, dx * s + dy * c
    end
    return dx, dy
end

-- Alert pip: points at the sender of an alert I received, on the minimap
-- edge when they're out of range, pulsing until the alert expires.
local function updatePip(map, px, py, w, h, ppy, facing, half)
    local am, ax, ay
    if ns.Alert then am, ax, ay = ns.Alert.PipTarget() end
    if not am or am ~= map then pip:Hide() return end
    local dx, dy = MapMini.Offset(ax, ay, px, py, w, h, ppy, facing)
    local edge = half - 6
    local d = math.sqrt(dx * dx + dy * dy)
    if d > edge then dx, dy = dx * edge / d, dy * edge / d end
    pip:SetPoint("CENTER", holder, "CENTER", dx, dy)
    pip:SetAlpha(0.55 + 0.45 * math.abs(math.sin(ns.now() * 3)))
    pip:Show()
end

function MapMini.Update()
    if inInstance() then hideFrom(0); hideHalos(); pip:Hide(); return end
    local map, px, py = ns.Position.ReadMine()
    if map and px then
        local w, h = MapMini.ZoneSize(map)
        if w then
            local half = Minimap:GetWidth() / 2
            local facing = rotating() and ns.try(GetPlayerFacing) or nil
            if facing and type(facing) ~= "number" then facing = nil end
            updatePip(map, px, py, w, h, half / MapMini.ViewRadius(), facing, half)
        end
    else
        pip:Hide()
    end
    if not ns.db.minimapDots then hideFrom(0); hideHalos(); return end
    local map, px, py = ns.Position.ReadMine()
    if not (map and px and py) then hideFrom(0); hideHalos(); return end
    local w, h = MapMini.ZoneSize(map)
    if not w then hideFrom(0); hideHalos(); return end
    local half = Minimap:GetWidth() / 2
    local ppy = half / MapMini.ViewRadius()
    local facing = rotating() and ns.try(GetPlayerFacing) or nil
    if facing and type(facing) ~= "number" then facing = nil end
    local limit = half - DOT_SIZE / 2 - 1
    local n = 0
    for _, g in pairs(ns.Position.All()) do
        if g.map == map then
            local rel = ns.Position.Relation(g)
            if (rel ~= "other" or ns.db.otherLayers) and not ns.Position.InMyGroup(g.key) then
                local dx, dy = MapMini.Offset(g.x, g.y, px, py, w, h, ppy, facing)
                if dx * dx + dy * dy <= limit * limit then
                    n = n + 1
                    local d = dots[n]
                    if not d then d = ns.NewDot(holder, DOT_SIZE, "diamond"); makeHoverable(d); dots[n] = d end
                    d.g = g
                    ns.StyleDot(d, g, rel)
                    d:SetPoint("CENTER", holder, "CENTER", math.floor(dx * 2 + 0.5) / 2, math.floor(dy * 2 + 0.5) / 2)
                    d:Show()
                end
            end
        end
    end
    hideFrom(n)
end

local function onUpdate(_, elapsed)
    acc = acc + elapsed
    if acc >= TICK then
        acc = 0
        MapMini.Update()
    end
    hoverAcc = hoverAcc + elapsed
    if hoverAcc >= 0.05 then
        hoverAcc = 0
        -- A dot under the mouse: our tooltip on it (kept up to date as dots
        -- move), unless the game's hover is running and our hook is adding to
        -- its tooltip. Otherwise, as before: the game's hover with our hook,
        -- or our own tooltip when that isn't seen working.
        if hoverDot and hoverDot:IsShown() and hoverDot.g then
            if not hookWorking() then showDotTooltip(hoverDot) end
        elseif not hookWorking() then
            updateHover()
        end
    end
end

ns.onLogin(function()
    holder = CreateFrame("Frame", nil, Minimap)
    holder:SetAllPoints(Minimap)
    holder:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 5)
    pip = ns.NewDot(holder, 13)
    pip.fill:SetVertexColor(1, 0.25, 0.1, 1)
    pip:SetFrameLevel(holder:GetFrameLevel() + 2)
    pip:Hide()
    driver = CreateFrame("Frame")
    driver:SetScript("OnUpdate", ns.guard(onUpdate, "minimap"))
    -- Bumped name lines go back to normal size before anything else reuses them.
    ns.WatchTooltip(GameTooltip)
    -- Our lines after the game's minimap hover (see afterGameHover). Guarded:
    -- an error here must never break the game's tooltip.
    if type(Minimap_OnUpdate) == "function" and hooksecurefunc then
        hooksecurefunc("Minimap_OnUpdate", ns.guard(afterGameHover, "minimap tooltip"))
        gameDrives = true
        return
    end
    -- Otherwise: our lines in the game's minimap tooltip data (see updateHover).
    local kind = Enum and Enum.TooltipDataType and Enum.TooltipDataType.MinimapMouseover
    if kind and TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall then
        TooltipDataProcessor.AddTooltipPostCall(kind, ns.guard(onMinimapTooltip, "minimap tooltip"))
    end
end, "minimap")

-- /mw hover: for 15 s, once a second, what the minimap hover sees.
ns.slash.hover = { help = "debug: hover a guildie on the minimap for 15 s", fn = function()
    ns.print("hover debug: put the mouse on a guildie's dot on the minimap.")
    for t = 1, 15 do
        ns.after(t, function()
            local cx, cy = GetCursorPosition()
            local best
            for i = 1, used do
                local x, y = dots[i]:GetCenter()
                local sc = dots[i]:GetEffectiveScale()
                if x and sc then
                    local d = math.sqrt((cx / sc - x) ^ 2 + (cy / sc - y) ^ 2)
                    if not best or d < best then best = d end
                end
            end
            local foci = GetMouseFoci and ns.try(GetMouseFoci)
            local focus = type(foci) == "table" and foci[1] or (GetMouseFocus and ns.try(GetMouseFocus))
            local fname = focus and (ns.try(focus.GetDebugName, focus) or ns.try(focus.GetName, focus)) or "none"
            local owner = GameTooltip:GetOwner()
            local oname = owner and (ns.try(owner.GetDebugName, owner) or ns.try(owner.GetName, owner)) or "none"
            ns.print(("%d: hooked %s, game hover %s, over %s, focus %s, dot %s, dots %d, nearest %s px (r %d), tip %s/%s, hook calls %d, added %d, dot tips %d"):format(
                t, tostring(gameDrives), tostring(gameHovering()), tostring(overMinimap()), tostring(fname),
                tostring(hoverDot ~= nil), used,
                best and ("%.1f"):format(best) or "-", HOVER_RADIUS, GameTooltip:IsShown() and "shown" or "hidden",
                tostring(oname), dbg.hook, dbg.added, dbg.dot))
            dbg.hook, dbg.added, dbg.dot = 0, 0, 0
        end, "hover debug")
    end
end }

-- For tests.
function MapMini.Debug() return dots, used, pip, halos end
