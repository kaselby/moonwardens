-- MapMini: guildie dots on the minimap.
-- Same zone only. Offsets in yards come from the zone's size in world
-- coordinates; the minimap's view radius from C_Minimap.GetViewRadius (falls
-- back to the Classic zoom table). Rotating minimap supported. Dots past the
-- edge are hidden (the alert edge pip comes with alerts).
local _, ns = ...
local MapMini = {}
ns.MapMini = MapMini

local DOT_SIZE = 9
local TICK = 0.05
local HOVER_RADIUS = 6

-- Classic minimap diameters in yards by zoom level, outdoors and indoors.
local OUTDOOR = { [0] = 466.67, 400, 333.33, 266.67, 200, 133.33 }
local INDOOR = { [0] = 300, 240, 180, 120, 80, 50 }

local holder, driver, pip
local dots, used = {}, 0
local sizes = {}            -- map -> { w, h } in yards, or { fail = time }
local acc, hoverAcc = 0, 0
local tipKey                -- hovered guildies in the tooltip we own, or nil

---------------------------------------------------------------------------
-- Hover: guildies join the minimap's own tooltip, the way party members do.
-- The game builds that tooltip (GameTooltip:SetMinimapMouseover: flight
-- masters, nodes, party members...) every frame while something is under
-- the cursor. A post-call adds our guildie lines to it each time, so it is one
-- tooltip with everything in it. Only when the game has nothing to show do we
-- show GameTooltip ourselves, with the same lines; once it has, we step back.
---------------------------------------------------------------------------

-- Is the mouse on the minimap itself (not on a frame on top of it, such as
-- an open world map)? Our dots take no mouse, so the minimap keeps the focus.
local function overMinimap()
    if Minimap.IsMouseMotionFocus then
        local ok, yes = pcall(Minimap.IsMouseMotionFocus, Minimap)
        if ok then return yes and true or false end
    end
    if GetMouseFocus then
        local ok, f = pcall(GetMouseFocus)
        if ok then return f == Minimap end
    end
    return holder:IsMouseOver()
end

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

-- Every hover tick: own GameTooltip only while the game isn't using it.
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
    for i = n + 1, used do dots[i]:Hide(); dots[i].g = nil end
    used = n
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
    if inInstance() then hideFrom(0); pip:Hide(); return end
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
    if not ns.db.minimapDots then hideFrom(0); return end
    local map, px, py = ns.Position.ReadMine()
    if not (map and px and py) then hideFrom(0); return end
    local w, h = MapMini.ZoneSize(map)
    if not w then hideFrom(0); return end
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
                    if not d then d = ns.NewDot(holder, DOT_SIZE); dots[n] = d end
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
        updateHover()
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
    -- Our lines in the game's own minimap tooltip (see updateHover). Guarded:
    -- an error here must never break the game's tooltip.
    local kind = Enum and Enum.TooltipDataType and Enum.TooltipDataType.MinimapMouseover
    if kind and TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall then
        TooltipDataProcessor.AddTooltipPostCall(kind, ns.guard(onMinimapTooltip, "minimap tooltip"))
    end
end, "minimap")

-- For tests.
function MapMini.Debug() return dots, used, pip end
