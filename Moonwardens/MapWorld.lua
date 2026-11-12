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
local DIAMOND = "Interface\\AddOns\\Moonwardens\\media\\diamond"
local RING = "Interface\\AddOns\\Moonwardens\\media\\ring"
-- Guildies are diamonds, so they can't be mistaken for the game's round
-- party/raid dots; group members get a gold ring around the game's dot
-- (ns.NewHalo) to stand out further.
ns.DOT_DIAMOND = 11
local DOT_SIZE = ns.DOT_DIAMOND
local HALO_SIZE = 20
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

-- A dot: dark outline, class-coloured shape, and a dark centre that makes it
-- hollow when the layer is unknown. `shape` "diamond" (guildies) or nil for
-- a disc (the alert pip). Both textures are plain white shapes, tinted.
function ns.NewDot(parent, size, shape)
    local d = ns.NewFrame("Frame", parent)
    d:SetSize(size, size)
    d.size = size
    local tex = shape == "diamond" and DIAMOND or CIRCLE
    local function disc(layer, sub, inset)
        local t = d:CreateTexture(nil, layer, nil, sub)
        t:SetTexture(tex)
        t:SetPoint("TOPLEFT", inset, -inset)
        t:SetPoint("BOTTOMRIGHT", -inset, inset)
        return t
    end
    d.outline = disc("ARTWORK", 1, 0); d.outline:SetVertexColor(0, 0, 0, 0.9)
    d.fill = disc("ARTWORK", 2, shape == "diamond" and 2 or 1.5)   -- (a diamond's edge is thinner at the same inset)
    d.hole = disc("ARTWORK", 3, math.floor(size * 0.32)); d.hole:SetVertexColor(0.05, 0.05, 0.05, 0.9)
    return d
end

-- A gold ring drawn around a group member's own (game) dot.
function ns.NewHalo(parent, size)
    local h = ns.NewFrame("Frame", parent)
    h:SetSize(size or HALO_SIZE, size or HALO_SIZE)
    h.outline = h:CreateTexture(nil, "ARTWORK", nil, 1)
    h.outline:SetTexture(RING); h.outline:SetAllPoints(); h.outline:SetVertexColor(0, 0, 0, 0.8)
    h.ring = h:CreateTexture(nil, "ARTWORK", nil, 2)
    h.ring:SetTexture(RING)
    h.ring:SetPoint("TOPLEFT", 1, -1); h.ring:SetPoint("BOTTOMRIGHT", -1, 1)
    h.ring:SetVertexColor(1, 0.82, 0.2, 1)
    return h
end

-- Group members' positions on `map` (map fractions), from the game itself
-- (the same source as its own dots, so the rings sit on them). Unreadable
-- (an instance, a restricted client): none.
function ns.GroupPositions(map)
    local out = {}
    if not (map and C_Map and C_Map.GetPlayerMapPosition) then return out end
    local n = ns.try(GetNumGroupMembers) or 0
    if n == 0 then return out end
    local raid = ns.try(IsInRaid) == true
    for i = 1, raid and n or (n - 1) do
        local u = (raid and "raid" or "party") .. i
        if ns.try(UnitIsUnit, u, "player") ~= true then
            local pos = ns.try(C_Map.GetPlayerMapPosition, map, u)
            if type(pos) == "table" and ns.readable(pos) then
                local ok, x, y = pcall(pos.GetXY, pos)
                if ok and type(x) == "number" and type(y) == "number" and ns.readable(x) and ns.readable(y)
                        and (x ~= 0 or y ~= 0) then
                    out[#out + 1] = { unit = u, x = x, y = y }
                end
            end
        end
    end
    return out
end

-- rel: "same"/"na" solid, "other" faded, "unknown" ring.
function ns.StyleDot(d, g, rel)
    local m = ns.Roster.Get(g.key)
    local r, gg, b = ns.classColor(m and m.classFile)
    if ns.RP then                                      -- (custom Roleplay colour, when on)
        local cr, cg, cb = ns.RP.Color(g.key)
        if cr then r, gg, b = cr, cg, cb end
    end
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

---------------------------------------------------------------------------
-- Guildie lines for any tooltip (world map and minimap share these).
-- Each guildie as in 0.5.1 (Position.AddTooltip: name, level/race/class,
-- guild rank, dead or in combat, layer, last seen), a blank line between.
-- In a tooltip of guildies alone, a later guildie's name (not line 1, which
-- the game draws in its bigger header font) is drawn NAME_BUMP points bigger.
-- Under someone else's lines (a flight master's) names keep the normal size.
-- Sizes are put back before the tooltip is built again.
---------------------------------------------------------------------------
local NAME_BUMP = 1
local MAX_LINES = 5
-- font string -> its font before we bumped it: { obj, path, size, flags }.
-- Tooltip line slots are reused by the next tooltip (our name on line 4 now
-- may be someone's "Updated 30 s ago" next), so every bumped slot is put back
-- to exactly what it was before the tooltip is built again.
local bumped = {}

local function lineText(tt, n)
    if tt.GetLeftLine then
        local ok, fs = pcall(tt.GetLeftLine, tt, n)
        if ok and fs then return fs end
    end
    local name = tt:GetName()
    return name and _G[name .. "TextLeft" .. n]
end

local function bumpLine(tt, n)
    local fs = lineText(tt, n)
    if not (fs and fs.GetFont) then return end
    local orig = bumped[fs]
    if not orig then                          -- (never bump an already bumped slot again)
        local path, size, flags = fs:GetFont()
        if not (path and type(size) == "number") then return end
        orig = { obj = fs.GetFontObject and fs:GetFontObject(), path = path, size = size, flags = flags }
        bumped[fs] = orig
    end
    fs:SetFont(orig.path, orig.size + NAME_BUMP, orig.flags)
end

-- Put `tt`'s bumped slots (all tooltips' when tt is nil) back as they were.
local function unbump(tt)
    if not next(bumped) then return end
    for fs, orig in pairs(bumped) do
        local owner = fs.GetParent and fs:GetParent()
        if not tt or owner == tt then
            if orig.obj then fs:SetFontObject(orig.obj) end
            fs:SetFont(orig.path, orig.size, orig.flags)   -- (exact, whatever the object says)
            bumped[fs] = nil
        end
    end
end

-- Watch a tooltip frame: slots back to their fonts whenever it may be rebuilt
-- (cleared, hidden, given a new owner, lines cleared), and `onClear` (if any)
-- when it is cleared.
local watched = {}
local clearHooks = {}
function ns.WatchTooltip(tt, onClear)
    if onClear then clearHooks[#clearHooks + 1] = { tt = tt, fn = onClear } end
    if watched[tt] then return end
    watched[tt] = true
    local function restore(self) pcall(unbump, self) end
    tt:HookScript("OnTooltipCleared", function(self)
        restore(self)
        for _, h in ipairs(clearHooks) do
            if h.tt == self then pcall(h.fn) end
        end
    end)
    tt:HookScript("OnHide", restore)
    if hooksecurefunc then
        if type(tt.SetOwner) == "function" then hooksecurefunc(tt, "SetOwner", restore) end
        if type(tt.ClearLines) == "function" then hooksecurefunc(tt, "ClearLines", restore) end
    end
end

-- Sort hits by name: a stable order while dots move.
function ns.SortHits(hits)
    table.sort(hits, function(a, b) return a.d.g.key < b.d.g.key end)
    return hits
end

-- The guildies of `hits` (sorted) added to tooltip `tt`.
function ns.AddGuildieLines(tt, hits)
    -- Any slot still bumped from an earlier build goes back first, so the
    -- lines above ours (the game's) and our own info lines get their real size.
    pcall(unbump, tt)
    -- Under someone else's lines (a flight master, a node, a map pin) names
    -- stay the normal size; the bump is only for a later guildie in a
    -- tooltip of guildies alone, whose first name is the header.
    local shared = tt:NumLines() > 0
    if shared then tt:AddLine(" ") end   -- (a blank line between their lines and ours)
    for i = 1, math.min(#hits, MAX_LINES) do
        if i > 1 then tt:AddLine(" ") end
        local nameLine = tt:NumLines() + 1
        ns.Position.AddTooltip(tt, hits[i].d.g)
        if nameLine > 1 and not shared then bumpLine(tt, nameLine) end
    end
    if #hits > MAX_LINES then tt:AddLine(("and %d more"):format(#hits - MAX_LINES), 0.62, 0.62, 0.62) end
end

-- "key,key": who is in a set of hits (first MAX_LINES).
function ns.HitsKey(hits)
    local keys = {}
    for i = 1, math.min(#hits, MAX_LINES) do keys[i] = hits[i].d.g.key end
    return table.concat(keys, ",")
end

local STICKY = 1.6   -- a dot already in the tooltip stays "hovered" out to this times the radius
local GRACE = 0.25   -- seconds with nothing under the cursor before the tooltip goes

-- Dots under the cursor. `st` (a caller's tooltip state) widens the radius
-- for dots already shown, so a dot moving under a still cursor doesn't flicker.
function ns.DotsUnderCursor(dots, count, radius, st)
    local cx, cy = GetCursorPosition()
    local shown = st and st.keys or {}
    local hits = {}
    for i = 1, count do
        local d = dots[i]
        local x, y = d:GetCenter()
        local s = d:GetEffectiveScale()
        if d.g and x and y and s and s > 0 then
            local r = shown[d.g.key] and radius * STICKY or radius
            local dx, dy = cx / s - x, cy / s - y
            local dist = dx * dx + dy * dy
            if dist <= r * r then hits[#hits + 1] = { d = d, dist = dist } end
        end
    end
    table.sort(hits, function(a, b) return a.dist < b.dist end)
    return hits
end

-- Hide GameTooltip, but only while it is still ours (`st.owner`): never
-- someone else's tooltip that took it over in the meantime.
function ns.HideDotTooltip(st)
    if st.key and st.owner and GameTooltip:GetOwner() == st.owner then GameTooltip:Hide() end
    st.key, st.keys, st.missAt, st.owner = nil, {}, nil, nil
end

-- Show the hit dots in GameTooltip on `owner` (as in 0.5.1, for the most
-- compatibility with tooltip and UI addons). It is rebuilt only when the set
-- of people changes (compared by name, not by distance order), and hidden only
-- after GRACE seconds with nothing hovered. If someone else has GameTooltip up
-- (a map pin: MapWorld.Hover joins those instead), we step back.
function ns.ShowDotTooltip(owner, hits, st)
    st.keys = st.keys or {}
    local tt = GameTooltip
    if tt:IsShown() and tt:GetOwner() ~= owner then
        st.key, st.keys, st.missAt, st.owner = nil, {}, nil, nil
        return
    end
    if #hits == 0 then
        if not st.key then return end
        st.missAt = st.missAt or ns.now()
        if ns.now() - st.missAt >= GRACE then ns.HideDotTooltip(st) end
        return
    end
    st.missAt = nil
    ns.SortHits(hits)
    local setKey = ns.HitsKey(hits)
    if setKey == st.key and tt:IsShown() and tt:GetOwner() == owner then return end
    tt:SetOwner(owner, "ANCHOR_CURSOR")
    ns.AddGuildieLines(tt, hits)
    tt:Show()
    st.key, st.owner = setKey, owner
    st.keys = {}
    for i = 1, math.min(#hits, MAX_LINES) do st.keys[hits[i].d.g.key] = true end
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
-- One dot frame per guildie, kept for the session: a dot never changes owner,
-- so a refresh can't leave one person's dot showing at another's old spot.
-- `dots` is the list of dots shown by the last refresh (for hover tests).
local dotOf = {}             -- key -> dot frame
local dots, used = {}, 0
local shownMap
local L = {}                 -- last root transform: ox, oy, w, h
local acc, hoverAcc = 0, 0
local tip = {}               -- hover tooltip state (see ns.ShowDotTooltip)

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

local placeDots -- forward: re-place shown dots after a zoom (defined with Refresh)

local function cacheCanvas()
    local sc = WorldMapFrame.ScrollContainer
    if not sc then return false end
    canvas = sc.Child
    if not viewport then
        viewport = ns.NewFrame("Frame", sc)
        root = ns.NewFrame("Frame", viewport)
        root:SetSize(1, 1)
        root:SetScript("OnSizeChanged", ns.guard(function(_, w, h)
            if placeDots then placeDots(w, h) end
        end, "world map zoom"))
    elseif viewport:GetParent() ~= sc then
        viewport:SetParent(sc)
    end
    viewport:ClearAllPoints()
    viewport:SetAllPoints(sc)
    pcall(viewport.SetClipsChildren, viewport, true)
    viewport:SetFrameStrata(sc:GetFrameStrata())
    viewport:SetFrameLevel(sc:GetFrameLevel() + 100)
    root:SetFrameLevel(viewport:GetFrameLevel() + 1)
    -- The root is ANCHORED to the canvas (not parented: nothing of ours goes
    -- into it). The game's layout then moves it in the same pass as the map,
    -- so pan and zoom don't drift. Copying the canvas position by hand from
    -- an OnUpdate (0.5.1) ran a frame behind the map's own pan and zoom.
    if canvas then
        root:ClearAllPoints()
        root:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, 0)
        root:SetPoint("BOTTOMRIGHT", canvas, "BOTTOMRIGHT", 0, 0)
    end
    L.w, L.h = nil, nil
    return canvas ~= nil
end

-- Track the root's size (it follows the canvas by anchors). Returns true when
-- it changed, i.e. dots must be placed again; a pan needs nothing.
local function syncRoot()
    local w, h = root:GetWidth(), root:GetHeight()
    if not (w and w > 0 and h and h > 0) then return nil end
    if w ~= L.w or h ~= L.h then
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
        local d = ns.NewDot(panel, ns.DOT_DIAMOND, "diamond")
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
    local drawn = {}
    if map then
        for _, g in pairs(ns.Position.All()) do
            local x, y = placeOn(g, map)
            if x then
                onMap.total = onMap.total + 1
                if g.map == map then onMap.direct = onMap.direct + 1 end
                local rel = ns.Position.Relation(g)
                if ns.db.worldDots and L.w and (rel ~= "other" or ns.db.otherLayers)
                        and not ns.Position.InMyGroup(g.key) then -- the game draws group members itself
                    local d = dotOf[g.key]
                    if not d then d = ns.NewDot(root, DOT_SIZE, "diamond"); dotOf[g.key] = d end
                    d.g = g
                    d.fx, d.fy = x, y     -- map fractions; placeDots turns them into offsets
                    ns.StyleDot(d, g, rel)
                    d:ClearAllPoints()
                    d:SetPoint("CENTER", root, "TOPLEFT", x * L.w, -y * L.h)
                    d:Show()
                    n = n + 1
                    dots[n] = d
                    drawn[g.key] = true
                end
            end
        end
    end
    for i = n + 1, used do dots[i] = nil end
    used = n
    for key, d in pairs(dotOf) do
        if not drawn[key] then d:Hide(); d.g = nil end
    end
    updatePanel(map, onMap)
    if ns.CompatOpenMap then ns.CompatOpenMap.Apply() end
end

-- Zoom: the root has just been resized by the layout (it is anchored to the
-- canvas), so move the shown dots to the new offsets right away rather than
-- waiting for the next OnUpdate.
placeDots = function(w, h)
    if not (w and w > 0 and h and h > 0) then return end
    L.w, L.h = w, h
    for i = 1, used do
        local d = dots[i]
        if d.fx then
            d:ClearAllPoints()
            d:SetPoint("CENTER", root, "TOPLEFT", d.fx * w, -d.fy * h)
        end
    end
end

-- Whether Moonwardens is drawing this guildie on the world map right now
-- (Compat_OpenMap.lua hides OpenMap's dot for them only while this is true).
function MapWorld.Draws(key)
    if not key or off() or not ns.db.worldDots or not WorldMapFrame:IsShown() then return false end
    local d = dotOf[key]
    return d ~= nil and d.g ~= nil and d:IsShown()
end

-- Gold rings around group members' own (game) dots, so the group stands
-- out from the guild. Moved with the hover tick (20 a second), since the
-- game moves its group dots smoothly.
local halos = {}
local function updateHalos()
    local n = 0
    if shownMap and L.w and ns.db.worldDots and not off() then
        for _, p in ipairs(ns.GroupPositions(shownMap)) do
            n = n + 1
            local h = halos[n]
            if not h then h = ns.NewHalo(root); halos[n] = h end
            h:SetFrameLevel(root:GetFrameLevel() + 1)
            h:ClearAllPoints()
            h:SetPoint("CENTER", root, "TOPLEFT", p.x * L.w, -p.y * L.h)
            h:Show()
        end
    end
    for i = n + 1, #halos do halos[i]:Hide() end
end
MapWorld.Halos = function() return halos end   -- (tests)

local function hideAll()
    for _, h in ipairs(halos) do h:Hide() end
    for _, d in pairs(dotOf) do d:Hide(); d.g = nil end
    for i = 1, used do dots[i] = nil end
    used = 0
    if viewport then viewport:Hide() end
    if panel then panel:Hide() end
    if driver then driver:Hide() end
    ns.HideDotTooltip(tip)
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
    -- Pan and zoom are followed by anchors (see cacheCanvas); this only
    -- catches a size change OnSizeChanged missed.
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
        updateHalos()
        MapWorld.Hover()
    end
end

---------------------------------------------------------------------------
-- Hover. A map pin (flight master, quest, OpenMap's...) shows GameTooltip
-- when the mouse enters it. If one is up while our dots are under the cursor
-- too, our guildies are added under its lines: one tooltip, as on the
-- minimap. Only when no pin's tooltip is up do we show our own.
---------------------------------------------------------------------------
local joined                 -- { owner, key }: our lines are in GameTooltip now

-- Is `f` a frame on the world map (a pin), other than our own viewport?
local function onWorldMap(f)
    local depth = 0
    while f and depth < 40 do
        if f == WorldMapFrame then return true end
        local ok, p = pcall(f.GetParent, f)
        if not ok then return false end
        f, depth = p, depth + 1
    end
    return false
end

local function pinTooltipUp()
    if not GameTooltip:IsShown() then return nil end
    local owner = GameTooltip:GetOwner()
    if not owner or owner == viewport or owner == WorldMapFrame then return nil end
    if not onWorldMap(owner) then return nil end
    local ok, over = pcall(owner.IsMouseOver, owner)   -- (the pin under the cursor, not a button nearby)
    if not ok or not over then return nil end
    return owner
end

function MapWorld.Hover()
    local hits = viewport:IsMouseOver() and ns.DotsUnderCursor(dots, used, HOVER_RADIUS, tip) or {}
    local owner = pinTooltipUp()
    if owner then
        ns.HideDotTooltip(tip)            -- (never two boxes)
        if #hits == 0 then return end
        ns.SortHits(hits)
        local key = ns.HitsKey(hits)
        -- Lines can't be taken back out of someone else's tooltip, so they go
        -- in once per build of it; a rebuild (OnTooltipCleared) clears `joined`.
        if joined and joined.owner == owner then return end
        ns.AddGuildieLines(GameTooltip, hits)
        GameTooltip:Show()                -- (resize to fit)
        joined = { owner = owner, key = key }
        return
    end
    ns.ShowDotTooltip(viewport, hits, tip)
end

ns.onLogin(function()
    -- (whether or not the map drawing is on: harmless, and /mw map on needs no reload)
    ns.WatchTooltip(GameTooltip, function() joined = nil end)
end, "world map tooltip")

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
    if arg == "debug" then
        -- Which dots are ours, and who the addon thinks is in the group.
        local frames = 0
        for _ in pairs(dotOf) do frames = frames + 1 end
        ns.print(("world map: %d dot(s) drawn by Moonwardens (%d frames made)."):format(used, frames))
        for i = 1, used do
            local g = dots[i].g
            if g then
                ns.print(("  %s  layer %s  %s"):format(g.key, tostring(g.layer), ns.Position.Relation(g)))
            end
        end
        local n = ns.try(GetNumGroupMembers) or 0
        local raid = ns.try(IsInRaid) == true
        ns.print(("group: %d member(s)%s."):format(n, raid and " (raid)" or ""))
        for i = 1, raid and n or math.max(0, n - 1) do
            local u = (raid and "raid" or "party") .. i
            local first, last = ns.try(UnitName, u)
            local key = ns.key(type(last) == "string" and last ~= "" and (tostring(first) .. " " .. last) or first)
            ns.print(("  %s: UnitName = %s / %s  -> key %s, hidden: %s"):format(u, tostring(first), tostring(last),
                tostring(key), tostring(key and ns.Position.InMyGroup(key) or false)))
        end
        return
    end
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
