-- MapWorld: guildie dots on the world map, hover tooltip, side panel.
--
-- Taint rules learned from Overlord on this client (12.x UI code):
--  * the shown map comes from pcall(WorldMapFrame.GetMapID); never read
--    WorldMapFrame.mapID, never hooksecurefunc a WorldMapFrame method;
--  * nothing of ours goes into the map canvas (ScrollContainer.Child). Our
--    own viewport sits on the ScrollContainer and a root frame inside it is
--    moved to match the canvas every frame (pan and zoom);
--  * dots take no mouse: hover is a hit test against the cursor, so the map
--    still drags and clicks, and nothing needs a combat-blocked call;
--  * frames are made parentless then attached when the gamepad UI is on
--    (its CreateFrame hook would walk the whole map);
--  * nothing runs in instances.
-- Kill switch: /mw map off.
local _, ns = ...
local MapWorld = {}
ns.MapWorld = MapWorld

local CIRCLE = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMaskSmall"
local DOT_SIZE = 9
local HOVER_RADIUS = 7
local PANEL_WIDTH = 196

---------------------------------------------------------------------------
-- Shared helpers (the minimap uses them too, even with the world map off)
---------------------------------------------------------------------------
function ns.NewFrame(kind, parent, template)
    local gamepad = InputUtil and InputUtil.IsGamepadUIEnabled and ns.try(InputUtil.IsGamepadUIEnabled)
    if not gamepad or not parent then return CreateFrame(kind, nil, parent, template) end
    local f = CreateFrame(kind, nil, nil, template)
    f:SetParent(parent)
    f:SetFrameStrata(parent:GetFrameStrata())
    f:SetFrameLevel(parent:GetFrameLevel() + 1)
    return f
end

-- A dot: dark outline, class-coloured disc, and a dark centre that makes it
-- a ring when the layer is unknown. The circle mask texture drawn as a
-- texture is a plain white disc, so no mask objects are needed.
function ns.NewDot(parent, size)
    local d = ns.NewFrame("Frame", parent)
    d:SetSize(size, size)
    d.size = size
    local function disc(layer, sub, inset)
        local t = d:CreateTexture(nil, layer, nil, sub)
        t:SetTexture(CIRCLE)
        t:SetPoint("TOPLEFT", inset, -inset)
        t:SetPoint("BOTTOMRIGHT", -inset, inset)
        return t
    end
    d.outline = disc("ARTWORK", 1, 0); d.outline:SetVertexColor(0, 0, 0, 0.9)
    d.fill = disc("ARTWORK", 2, 1.5)
    d.hole = disc("ARTWORK", 3, math.floor(size * 0.32)); d.hole:SetVertexColor(0.05, 0.05, 0.05, 0.9)
    return d
end

-- rel: "same"/"na" solid, "other" faded, "unknown" ring.
function ns.StyleDot(d, g, rel)
    local m = ns.Roster.Get(g.key)
    local r, gg, b = ns.classColor(m and m.classFile)
    if d.cr ~= r or d.cg ~= gg or d.cb ~= b then
        d.fill:SetVertexColor(r, gg, b, 1)
        d.cr, d.cg, d.cb = r, gg, b
    end
    if d.rel ~= rel then
        d:SetAlpha(rel == "other" and 0.4 or 1)
        d.hole:SetShown(rel == "unknown")
        d.rel = rel
    end
end

-- Dots under the cursor, nearest first.
function ns.DotsUnderCursor(dots, count, radius)
    local cx, cy = GetCursorPosition()
    local hits = {}
    for i = 1, count do
        local d = dots[i]
        local x, y = d:GetCenter()
        local s = d:GetEffectiveScale()
        if x and y and s and s > 0 then
            local dx, dy = cx / s - x, cy / s - y
            local dist = dx * dx + dy * dy
            if dist <= radius * radius then hits[#hits + 1] = { d = d, dist = dist } end
        end
    end
    table.sort(hits, function(a, b) return a.dist < b.dist end)
    return hits
end

-- Show a tooltip for the hit dots on `owner`, rebuilding only when the set
-- changes. Returns the new set key.
function ns.ShowDotTooltip(owner, hits, lastKey)
    if #hits == 0 then
        if lastKey and GameTooltip:GetOwner() == owner then GameTooltip:Hide() end
        return nil
    end
    local keys = {}
    for i = 1, math.min(#hits, 5) do keys[i] = hits[i].d.g.key end
    local setKey = table.concat(keys, ",")
    if setKey == lastKey and GameTooltip:GetOwner() == owner and GameTooltip:IsShown() then return setKey end
    GameTooltip:SetOwner(owner, "ANCHOR_CURSOR")
    for i = 1, math.min(#hits, 5) do
        if i > 1 then GameTooltip:AddLine(" ") end
        ns.Position.AddTooltip(GameTooltip, hits[i].d.g)
    end
    if #hits > 5 then GameTooltip:AddLine(("and %d more"):format(#hits - 5), 0.62, 0.62, 0.62) end
    GameTooltip:Show()
    return setKey
end

---------------------------------------------------------------------------
-- Map geometry
---------------------------------------------------------------------------

-- A guildie's position on another map (continent view, neighbouring zone),
-- through world coordinates. nil when off that map or not readable.
function MapWorld.Convert(fromMap, x, y, toMap)
    if fromMap == toMap then return x, y end
    if not (C_Map.GetWorldPosFromMapPos and C_Map.GetMapPosFromWorldPos and CreateVector2D) then return end
    local ok, cont, world = pcall(C_Map.GetWorldPosFromMapPos, fromMap, CreateVector2D(x, y))
    if not ok or not cont or not world or not ns.readable(cont) then return end
    local ok2, _, pos = pcall(C_Map.GetMapPosFromWorldPos, cont, world, toMap)
    if not ok2 or not pos then return end
    local px, py = ns.try(pos.GetXY, pos)
    if type(px) == "number" and type(py) == "number" and px >= 0 and px <= 1 and py >= 0 and py <= 1 then
        return px, py
    end
end

local function placeOn(g, map)
    if g.map == map then return g.x, g.y end
    local c = g.cache
    if not c or c.map ~= map then
        local x, y = MapWorld.Convert(g.map, g.x, g.y, map)
        c = { map = map, x = x, y = y }
        g.cache = c
    end
    return c.x, c.y
end

---------------------------------------------------------------------------
-- World map state
---------------------------------------------------------------------------
local hooked = false
local viewport, root, driver, panel
local canvas
local dots, used = {}, 0
local shownMap
local L = {}                 -- last root transform: ox, oy, w, h
local acc, hoverAcc = 0, 0
local tipKey

local function off()
    return ns.db.mapKill
end

local function inInstance()
    local inside, kind = ns.try(IsInInstance)
    return inside == true and kind ~= "none"
end

local function readShownMap()
    local ok, id = pcall(WorldMapFrame.GetMapID, WorldMapFrame)
    if ok and type(id) == "number" and ns.readable(id) and id > 0 then return id end
end

local function cacheCanvas()
    local sc = WorldMapFrame.ScrollContainer
    if not sc then return false end
    canvas = sc.Child
    if not viewport then
        viewport = ns.NewFrame("Frame", sc)
        root = ns.NewFrame("Frame", viewport)
        root:SetSize(1, 1)
    elseif viewport:GetParent() ~= sc then
        viewport:SetParent(sc)
    end
    viewport:ClearAllPoints()
    viewport:SetAllPoints(sc)
    pcall(viewport.SetClipsChildren, viewport, true)
    viewport:SetFrameStrata(sc:GetFrameStrata())
    viewport:SetFrameLevel(sc:GetFrameLevel() + 100)
    root:SetFrameLevel(viewport:GetFrameLevel() + 1)
    L.ox, L.w = nil, nil
    return canvas ~= nil
end

-- Move the root onto the canvas. Returns true when its size changed (dots
-- must be placed again); a pan only moves the root.
local function syncRoot()
    local cw, ch = canvas:GetWidth(), canvas:GetHeight()
    local cl, ct = canvas:GetLeft(), canvas:GetTop()
    local vl, vt = viewport:GetLeft(), viewport:GetTop()
    local cs, vs = canvas:GetEffectiveScale(), viewport:GetEffectiveScale()
    if not (cw and cw > 0 and ch and ch > 0 and cl and ct and vl and vt and cs and vs and vs > 0) then
        return nil
    end
    local k = cs / vs
    local ox, oy = (cl * cs - vl * vs) / vs, (ct * cs - vt * vs) / vs
    local w, h = cw * k, ch * k
    if ox ~= L.ox or oy ~= L.oy then
        root:ClearAllPoints()
        root:SetPoint("TOPLEFT", viewport, "TOPLEFT", ox, oy)
        L.ox, L.oy = ox, oy
    end
    if w ~= L.w or h ~= L.h then
        root:SetSize(w, h)
        L.w, L.h = w, h
        return true
    end
    return false
end

---------------------------------------------------------------------------
-- Side panel
---------------------------------------------------------------------------
local function makeBackdrop(f, r, g, b, a, er, eg, eb)
    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        f:SetBackdropColor(r, g, b, a)
        f:SetBackdropBorderColor(er, eg, eb, 1)
    else
        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(r, g, b, a)
    end
end

local function newPanelFrame(parent)
    local ok, f = pcall(ns.NewFrame, "Frame", parent, "BackdropTemplate")
    if not ok or not f then f = ns.NewFrame("Frame", parent) end
    return f
end

local function check(parent, label, setting)
    local cb = ns.NewFrame("CheckButton", parent, "UICheckButtonTemplate")
    cb:SetSize(22, 22)
    local t = ns.UI.Text(parent, nil, nil, "LEFT")
    t:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    t:SetText(label)
    cb:SetScript("OnClick", function(self)
        ns.db[setting] = self:GetChecked() and true or false
        ns.fire("SETTINGS", setting)
        MapWorld.Refresh()
    end)
    cb.setting = setting
    return cb
end

local function buildPanel()
    panel = newPanelFrame(WorldMapFrame)
    panel:SetWidth(PANEL_WIDTH)
    makeBackdrop(panel, 0.04, 0.04, 0.04, 0.92, 0.55, 0.45, 0.2)
    local UI = ns.UI

    panel.title = UI.Text(panel, nil, UI.GOLD, "LEFT")
    panel.title:SetPoint("TOPLEFT", 12, -10)
    panel.title:SetText("Moonwardens")
    local line = panel:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(0.45, 0.36, 0.1, 1)
    line:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -3)
    line:SetSize(PANEL_WIDTH - 24, 1)

    panel.showDots = check(panel, "Show guildies", "worldDots")
    panel.showDots:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", -4, -8)
    panel.showOther = check(panel, "Show other layers", "otherLayers")
    panel.showOther:SetPoint("TOPLEFT", panel.showDots, "BOTTOMLEFT", 0, 2)

    panel.head = UI.Text(panel, nil, UI.GOLD, "LEFT")
    panel.head:SetPoint("TOPLEFT", panel.showOther, "BOTTOMLEFT", 4, -10)
    panel.head:SetWidth(PANEL_WIDTH - 24)

    panel.cards = {}
    panel.empty = UI.Text(panel, "small", UI.GREY, "LEFT")
    panel.empty:SetWidth(PANEL_WIDTH - 24)

    panel.legend = {}
    local LEGEND = { { "your layer", "same" }, { "other layer", "other" }, { "layer unknown", "unknown" } }
    for i, e in ipairs(LEGEND) do
        local d = ns.NewDot(panel, 10)
        ns.StyleDot(d, { key = "" }, e[2])
        d.fill:SetVertexColor(0.67, 0.83, 0.45, 1)
        local t = UI.Text(panel, "small", nil, "LEFT")
        t:SetPoint("LEFT", d, "RIGHT", 5, 0)
        t:SetText(e[1])
        panel.legend[i] = d
    end
    panel.note = UI.Text(panel, "small", UI.GREY, "LEFT")
    panel.note:SetWidth(PANEL_WIDTH - 24)
    panel.note:SetText("Experimental. Layers are worked out from nearby creatures and can be wrong, especially in cities.")
end

local function card(i)
    local c = panel.cards[i]
    if c then return c end
    c = newPanelFrame(panel)
    c:SetSize(PANEL_WIDTH - 24, 38)
    makeBackdrop(c, 0.1, 0.1, 0.1, 0.9, 0.3, 0.3, 0.3)
    c.name = ns.UI.Text(c, nil, ns.UI.GOLD, "LEFT"); c.name:SetPoint("TOPLEFT", 8, -6)
    c.count = ns.UI.Text(c, "small", nil, "LEFT"); c.count:SetPoint("TOPLEFT", c.name, "BOTTOMLEFT", 0, -2)
    c.server = ns.UI.Text(c, "small", ns.UI.GREY, "RIGHT"); c.server:SetPoint("TOPRIGHT", -8, -7)
    panel.cards[i] = c
    return c
end

local function plural(n) return n == 1 and "1 guildie" or n .. " guildies" end

local function mapName(map)
    local info = map and ns.try(C_Map.GetMapInfo, map)
    return type(info) == "table" and info.name or "this map"
end

local function updatePanel(map, onMap)
    if not panel then return end
    panel.showDots:SetChecked(ns.db.worldDots and true or false)
    panel.showOther:SetChecked(ns.db.otherLayers and true or false)

    local me = ns.Position.Me()
    local isZone = map and (me.map == map or onMap.direct > 0)
    local y = -104    -- below the heading
    local shown = 0
    if isZone then
        panel.head:SetText("Layers in " .. mapName(map))
        local list, unknown = ns.Position.LayersIn(map)
        local rows = {}
        for _, e in ipairs(list) do rows[#rows + 1] = e end
        if unknown > 0 then rows[#rows + 1] = { unknownRow = true, n = unknown } end
        for i, e in ipairs(rows) do
            local c = card(i)
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", 12, y)
            if e.unknownRow then
                c.name:SetText("Layer not known")
                c.name:SetTextColor(0.75, 0.75, 0.75)
                c.server:SetText("")
                if c.SetBackdropBorderColor then c:SetBackdropBorderColor(0.3, 0.3, 0.3, 1) end
            else
                c.name:SetText(e.label .. (e.mine and " |cff1eff00- you|r" or ""))
                c.name:SetTextColor(1, 0.82, 0)
                c.server:SetText(e.layer)
                if c.SetBackdropBorderColor then
                    if e.mine then c:SetBackdropBorderColor(0.85, 0.68, 0.1, 1) else c:SetBackdropBorderColor(0.3, 0.3, 0.3, 1) end
                end
            end
            c.count:SetText(plural(e.n))
            c:Show()
            y = y - 42
            shown = i
        end
        panel.empty:SetShown(shown == 0)
        if shown == 0 then
            panel.empty:SetPoint("TOPLEFT", 12, y)
            panel.empty:SetText("No guildies with the addon here.")
            y = y - 28
        end
    else
        panel.head:SetText(map and mapName(map) or "World map")
        panel.empty:Show()
        panel.empty:SetPoint("TOPLEFT", 12, y)
        panel.empty:SetText(plural(onMap.total) .. " on this map. Open a zone to see its layers.")
        y = y - 40
    end
    for i = shown + 1, #panel.cards do panel.cards[i]:Hide() end

    y = y - 6
    for _, d in ipairs(panel.legend) do
        d:ClearAllPoints()
        d:SetPoint("TOPLEFT", 16, y)
        y = y - 16
    end
    panel.note:ClearAllPoints()
    panel.note:SetPoint("TOPLEFT", 12, y - 6)
    local noteH = ns.try(panel.note.GetStringHeight, panel.note) or 40
    panel:SetHeight(-y + 6 + noteH + 12)
end

-- Outside the map frame on its right when there is room; inside the map's
-- top-right corner otherwise (maximised map).
local function placePanel()
    local right = WorldMapFrame:GetRight()
    local screen = UIParent:GetRight()
    local sc = WorldMapFrame.ScrollContainer
    panel:ClearAllPoints()
    if right and screen and right + PANEL_WIDTH + 4 <= screen then
        panel:SetPoint("TOPLEFT", WorldMapFrame, "TOPRIGHT", 2, -24)
        panel:SetFrameStrata(WorldMapFrame:GetFrameStrata())
    else
        panel:SetPoint("TOPRIGHT", sc or WorldMapFrame, "TOPRIGHT", -8, -8)
        panel:SetFrameStrata(WorldMapFrame:GetFrameStrata())
        if sc then panel:SetFrameLevel(sc:GetFrameLevel() + 200) end
    end
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------
function MapWorld.Refresh()
    if not root or not WorldMapFrame:IsShown() or off() then return end
    local map = shownMap
    local n = 0
    local onMap = { total = 0, direct = 0 }
    if map then
        for _, g in pairs(ns.Position.All()) do
            local x, y = placeOn(g, map)
            if x then
                onMap.total = onMap.total + 1
                if g.map == map then onMap.direct = onMap.direct + 1 end
                local rel = ns.Position.Relation(g)
                if ns.db.worldDots and L.w and (rel ~= "other" or ns.db.otherLayers) then
                    n = n + 1
                    local d = dots[n]
                    if not d then d = ns.NewDot(root, DOT_SIZE); dots[n] = d end
                    d.g = g
                    ns.StyleDot(d, g, rel)
                    d:SetPoint("CENTER", root, "TOPLEFT", x * L.w, -y * L.h)
                    d:Show()
                end
            end
        end
    end
    for i = n + 1, used do dots[i]:Hide(); dots[i].g = nil end
    used = n
    updatePanel(map, onMap)
end

local function hideAll()
    for i = 1, used do dots[i]:Hide(); dots[i].g = nil end
    used = 0
    if viewport then viewport:Hide() end
    if panel then panel:Hide() end
    if driver then driver:Hide() end
    if tipKey and GameTooltip:GetOwner() == viewport then GameTooltip:Hide() end
    tipKey = nil
end

local function onUpdate(_, elapsed)
    if off() then hideAll(); return end
    if not canvas or (canvas:GetWidth() or 0) == 0 then
        -- The canvas can be recreated after a loading screen; look again.
        acc = acc + elapsed
        if acc < 0.45 then return end
        acc = 0
        if not cacheCanvas() then return end
    end
    local map = readShownMap()
    local dirty = false
    if map ~= shownMap then shownMap = map; dirty = true end
    local ok, resized = pcall(syncRoot)
    if ok and resized then dirty = true end
    acc = acc + elapsed
    if dirty or acc >= 0.2 then
        acc = 0
        MapWorld.Refresh()
    end
    hoverAcc = hoverAcc + elapsed
    if hoverAcc >= 0.05 then
        hoverAcc = 0
        local hits = viewport:IsMouseOver() and ns.DotsUnderCursor(dots, used, HOVER_RADIUS) or {}
        tipKey = ns.ShowDotTooltip(viewport, hits, tipKey)
    end
end

local function onShow()
    if off() or inInstance() then hideAll(); return end
    if not cacheCanvas() then return end
    if not panel then buildPanel() end
    viewport:Show()
    panel:Show()
    placePanel()
    shownMap = readShownMap()
    acc = 1   -- draw on the first frame
    driver:Show()
end

local function onHide()
    hideAll()
end

local function hook()
    if hooked or not WorldMapFrame then return end
    hooked = true
    driver = CreateFrame("Frame")
    driver:Hide()
    driver:SetScript("OnUpdate", ns.guard(onUpdate, "world map"))
    WorldMapFrame:HookScript("OnShow", ns.guard(onShow, "world map show"))
    WorldMapFrame:HookScript("OnHide", ns.guard(onHide, "world map hide"))
    WorldMapFrame:HookScript("OnSizeChanged", ns.guard(function()
        if panel and panel:IsShown() then placePanel() end
    end, "world map size"))
    if WorldMapFrame:IsShown() then onShow() end
end

ns.onLogin(function()
    if off() then return end
    if WorldMapFrame then hook()
    else
        ns:On("ADDON_LOADED", function(name) if name == "Blizzard_WorldMap" and not off() then hook() end end)
    end
end, "world map")

ns.slash.map = { help = "on | off - draw guildies on the world map (off if the map acts up)", fn = function(arg)
    arg = (arg or ""):lower()
    if arg == "off" then
        ns.db.mapKill = true
        hideAll()
        ns.print("world map drawing is off. /reload to unhook it completely. /mw map on brings it back.")
    elseif arg == "on" then
        ns.db.mapKill = false
        hook()
        ns.print("world map drawing is on.")
    else
        ns.print("world map drawing is " .. (off() and "off" or "on") .. ". Use /mw map on or /mw map off.")
    end
end }

-- For tests.
function MapWorld.Debug() return dots, used, panel, root end
