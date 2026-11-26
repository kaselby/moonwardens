-- BadgesUI: the Stats tab of the guild window, laid out as the game's Legacy
-- Challenges (Blizzard_LegacySystem) and drawn with its art: a search box and
-- a folding category list on the left; on the right the Overview (score,
-- most prestigious, recent, progress) or a category's badge cards, each
-- scrolling with the game's scroll bar. Always your own: anyone's badges
-- (Badges.View, from the right-click menus) open in the Badge Chest, a
-- window of its own (BadgeChest.lua).
-- We use the Legacy atlases only, not its templates: those live in a
-- load-on-demand addon of the game's, and its code expects achievements.
local _, ns = ...
local UI = ns.UI
local Badges = ns.Badges
local BUI = {}
ns.BadgesUI = BUI

local CARD_H = 120
local CARD_GAP = 5
local CAT_H = 25
local SCROLL_STEP = 40

local state = { cat = "overview", view = nil, search = "", collapsed = {} }
-- Kept across closing and reloads (db.badgeUI): the category open, the
-- folded headers, and how far down each category was scrolled.
local saved

---------------------------------------------------------------------------
-- New badges: a blue dot (the game's "something new" look) on the Badges
-- tab, on the category a new badge is in, and on the badge itself - its
-- card's icon and its icon in the Collection - top right, as on the tab.
-- The badge's dots go once it's hovered; the tab's once every dot in it is
-- gone (the first-load one alone: once the tab is picked). The first time
-- with this version, the tab's dot shows too (nothing else: what's already
-- earned isn't new). New = earned (or earned again) since last looked:
-- MoonwardensDB.badgeKnown { id = times }, badgeNew { id = true },
-- badgeTabNew. (Earned long ago and only now heard of - a Ledger catching
-- up - isn't new.)
-- Also new: a badge not earned and never hovered - every one there is, the
-- first time, and each one added to the addon after (a new release, a new
-- month's hunt targets) - the same dot, gone on the first hover, as an
-- earned one's. Dotted only while "View Only Acquired Badges" is off, as
-- that's when the Overview shows them. (MoonwardensDB.badgeListed: every
-- badge id seen in the list; badgeUnseen { id = true }.)
---------------------------------------------------------------------------
-- The one blue: the new-badge dot, every progress bar, and the fill of a
-- badge not earned yet. `disc` the colour, `halo` its glow (added light),
-- `edge` the bright line or shine, `rim` the dark outline.
local BLUE = { disc = { 0.4, 0.82, 1 }, halo = { 0.35, 0.75, 1 }, edge = { 0.85, 0.96, 1 }, rim = { 0.02, 0.08, 0.2 } }
BUI.BLUE = BLUE

local New = {}
BUI.New = New
local OLD_NEWS = 14 * 86400

-- The dot: a bright blue disc with a dark rim, a shine, and a soft glow
-- around it that breathes (our own: no art of the game's is borrowed). On
-- `parent`, at `point`.
local DISC = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"
function New.Dot(parent, size, point, x, y, strong)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(size, size)
    holder:SetPoint("CENTER", parent, point or "TOPLEFT", x or 0, y or 0)
    holder:SetFrameLevel(parent:GetFrameLevel() + 30)
    -- (the glow: a soft round light, added, twice the dot's size)
    local glow = holder:CreateTexture(nil, "OVERLAY", nil, 5)
    glow:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    glow:SetPoint("CENTER")
    glow:SetSize(size * (strong and 3 or 2.2), size * (strong and 3 or 2.2))
    glow:SetVertexColor(BLUE.halo[1], BLUE.halo[2], BLUE.halo[3])
    glow:SetBlendMode("ADD")
    local rim = holder:CreateTexture(nil, "OVERLAY", nil, 6)
    rim:SetTexture(DISC)
    rim:SetAllPoints()
    rim:SetVertexColor(BLUE.rim[1], BLUE.rim[2], BLUE.rim[3], 0.95)
    local disc = holder:CreateTexture(nil, "OVERLAY", nil, 7)
    disc:SetTexture(DISC)
    disc:SetPoint("TOPLEFT", 1.5, -1.5)
    disc:SetPoint("BOTTOMRIGHT", -1.5, 1.5)
    disc:SetVertexColor(BLUE.disc[1], BLUE.disc[2], BLUE.disc[3])
    -- (a shine, top left)
    local shine = holder:CreateTexture(nil, "OVERLAY", nil, 7)
    shine:SetTexture(DISC)
    shine:SetSize(size * 0.38, size * 0.38)
    shine:SetPoint("TOPLEFT", size * 0.22, -size * 0.2)
    shine:SetVertexColor(1, 1, 1, 0.75)
    shine:SetBlendMode("ADD")
    local ok, ag = pcall(glow.CreateAnimationGroup, glow)
    if ok and ag then
        ag:SetLooping("BOUNCE")
        local a = ag:CreateAnimation("Alpha")
        a:SetFromAlpha(strong and 0.3 or 0.45); a:SetToAlpha(1); a:SetDuration(strong and 0.7 or 0.9)
        if a.SetSmoothing then a:SetSmoothing("IN_OUT") end
        -- (the tab's: a ring of light too, swelling out from it and fading)
        local ping
        if strong then
            local ring = holder:CreateTexture(nil, "OVERLAY", nil, 4)
            ring:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
            ring:SetPoint("CENTER")
            ring:SetSize(size * 2, size * 2)
            ring:SetVertexColor(0.45, 0.85, 1)
            ring:SetBlendMode("ADD")
            local okP, pg = pcall(ring.CreateAnimationGroup, ring)
            if okP and pg then
                pg:SetLooping("REPEAT")
                local sc = pg:CreateAnimation("Scale")
                if sc.SetScaleFrom then sc:SetScaleFrom(0.6, 0.6); sc:SetScaleTo(1.8, 1.8)
                else sc:SetScale(3, 3) end
                sc:SetDuration(1.4)
                local fa = pg:CreateAnimation("Alpha")
                fa:SetFromAlpha(0.9); fa:SetToAlpha(0); fa:SetDuration(1.4)
                ping = pg
            end
        end
        holder:SetScript("OnShow", function() ag:Play(); if ping then ping:Play() end end)
        holder:SetScript("OnHide", function() ag:Stop(); if ping then ping:Stop() end end)
    end
    holder:EnableMouse(false)
    holder:Hide()
    return holder
end

-- Is the Overview showing badges not earned yet ("View Only Acquired
-- Badges" off)?
local function showingAll()
    local ui = ns.db and ns.db.badgeUI
    return not (ui and ui.onlyAcquired)
end

function New.Is(id)
    local db = ns.db
    if not db then return false end
    if db.badgeNew and db.badgeNew[id] then return true end
    return (db.badgeUnseen and db.badgeUnseen[id] and showingAll()) and true or false
end

-- Anything new in category `cat`?
function New.InCat(cat)
    local db = ns.db or {}
    for _, set in ipairs({ db.badgeNew or {}, showingAll() and db.badgeUnseen or {} }) do
        for id in pairs(set) do
            local b = Badges.Get(id)
            if b and b.cat == cat then return true end
        end
    end
    return false
end

-- A card's badges: a track's tiers, a compound badge and its own, or itself.
local function cardIds(b, st)
    local ids = { b.id }
    if st and st.track then for _, t in ipairs(st.track.tiers) do ids[#ids + 1] = t.id end end
    for _, cid in ipairs(b.kind == "parent" and b.children or {}) do ids[#ids + 1] = cid end
    return ids
end
function New.InCard(b, st)
    for _, id in ipairs(cardIds(b, st)) do if New.Is(id) then return true end end
    return false
end

-- The tab's dot: while any dot shows in it (or the first-load one).
function New.Tab()
    local db = ns.db
    if not db then return false end
    if db.badgeTabNew or next(db.badgeNew or {}) then return true end
    return (showingAll() and next(db.badgeUnseen or {})) and true or false
end

-- Where the dots are shown again: the tab, the category list.
local function dotsChanged()
    if ns.GuildTabs and ns.GuildTabs.UpdateDots then ns.GuildTabs.UpdateDots() end
    if BUI.RefreshCats then BUI.RefreshCats() end
end

-- Hovered: not new any more.
function New.See(ids)
    local n = ns.db and ns.db.badgeNew
    if not n then return false end
    local u = ns.db.badgeUnseen or {}
    local all = showingAll()
    local any = false
    for _, id in ipairs(ids) do
        if n[id] then n[id] = nil; any = true end
        if u[id] and all then u[id] = nil; any = true end     -- (seen: it was showing)
    end
    if any then dotsChanged() end
    return any
end
function New.SeeCard(b, st) return New.See(cardIds(b, st)) end

-- An earned badge on the board (Showcase, Collection) stands for its
-- track's lower tiers too, so their new-dots are its own. (Only their
-- new-dots: a lower tier not earned has its own icon, not earned.)
local function lowerTiers(b)
    local ids = {}
    local t = b.track and Badges.TRACKS[b.track]
    local mine = Badges.TIER_ORDER[b.tier] or 0
    for _, x in ipairs(t and t.tiers or {}) do
        if (Badges.TIER_ORDER[x.tier] or 0) < mine then ids[#ids + 1] = x.id end
    end
    return ids
end
function New.IsShown(b)
    if New.Is(b.id) then return true end
    local n = ns.db and ns.db.badgeNew or {}
    for _, id in ipairs(lowerTiers(b)) do if n[id] then return true end end
    return false
end
function New.SeeShown(b)
    local any = New.See({ b.id })
    local n = ns.db and ns.db.badgeNew
    if not n then return any end
    local lower = false
    for _, id in ipairs(lowerTiers(b)) do if n[id] then n[id] = nil; lower = true end end
    if lower then dotsChanged() end
    return any or lower
end

-- The tab picked.
function New.TabSeen()
    if ns.db and ns.db.badgeTabNew then ns.db.badgeTabNew = nil; dotsChanged() end
end

-- What I've earned now, against what I'd seen.
local function check()
    local db = ns.db
    if not db then return end
    local ok, result = pcall(Badges.Mine)
    if not ok or type(result) ~= "table" then return end
    db.badgeNew = db.badgeNew or {}
    local first = db.badgeKnown == nil
    local known = db.badgeKnown or {}
    local now, found, changed = ns.now(), false, false
    for _, b in ipairs(Badges.LIST) do
        local e = result.badges[b.id]
        local t = e and e.times or 0
        if t > (known[b.id] or 0) and not first then
            local old = e.lastAt and now - e.lastAt > OLD_NEWS
            if not old then db.badgeNew[b.id] = true; found = true end
        end
        if t == 0 and db.badgeNew[b.id] then db.badgeNew[b.id] = nil; changed = true end   -- (taken back)
        known[b.id] = t > 0 and t or nil
    end
    db.badgeKnown = known
    if first then db.badgeTabNew = true; changed = true end
    -- Badges added to the addon since: not earned, there to be earned now.
    -- (version 2: every badge not yet earned starts unseen, not only those
    -- added later - the list is taken again once)
    if db.badgeSeenVersion ~= 2 then db.badgeListed, db.badgeSeenVersion = nil, 2 end
    db.badgeUnseen = db.badgeUnseen or {}
    local listed = db.badgeListed or {}
    local unearned = {}
    for _, it in ipairs(Badges.Unearned(result)) do unearned[it.b.id] = true end
    local added = false
    for _, b in ipairs(Badges.LIST) do
        if not listed[b.id] then
            listed[b.id] = true
            if unearned[b.id] then db.badgeUnseen[b.id] = true; added = true end
        end
        local e = result.badges[b.id]
        if db.badgeUnseen[b.id] and e and e.times > 0 then db.badgeUnseen[b.id] = nil end   -- (earned: that's its news now)
    end
    db.badgeListed = listed
    if added and showingAll() then found = true end
    -- (nothing left dotted that isn't shown anywhere: a past month's, a
    -- badge switched off or gone - else the tab's dot could never go)
    for id in pairs(db.badgeUnseen) do if not unearned[id] then db.badgeUnseen[id] = nil; changed = true end end
    for id in pairs(db.badgeNew) do if not Badges.Get(id) then db.badgeNew[id] = nil; changed = true end end
    if found then
        -- (the Badges page open in front of me: the tab needn't say so)
        local onIt = ns.GuildTabs and ns.GuildTabs.Showing and ns.GuildTabs.Showing("Stats")
        if not onIt then db.badgeTabNew = true end
        if BUI.Refresh then BUI.Refresh() end
    end
    if found or changed then dotsChanged() end
end
-- /mw test newdots: as on the first load with this version (the tab's dot);
-- "all": every badge I have marked new as well, to see their dots.
ns.tests.newdots = { usage = "[all]", help = "the new-badge dots again (all: on every badge you have, too)", fn = function(arg)
    local db = ns.db
    if not db then return end
    db.badgeKnown, db.badgeNew, db.badgeTabNew = nil, {}, nil
    db.badgeListed, db.badgeUnseen = nil, {}              -- (every badge not earned: unseen again)
    check()
    if (arg or ""):lower():match("^%s*all") then
        local ok, result = pcall(Badges.Mine)
        if ok then
            for _, b in ipairs(Badges.LIST) do
                local e = result.badges[b.id]
                if e and e.times > 0 then db.badgeNew[b.id] = true end
            end
        end
    end
    dotsChanged()
    if BUI.Refresh then BUI.Refresh() end
    ns.print("New-badge dots reset.")
end }

local checkSoon = false
function New.Check()
    if checkSoon then return end
    checkSoon = true
    C_Timer.After(0.5, function() checkSoon = false; ns.guard(check, "new badges")() end)
end

local function loadSaved()
    if saved or not ns.db then return end
    local sv = ns.db.badgeUI or {}
    -- (first time: every major section starts folded)
    local collapsed = sv.collapsed
    if not collapsed then
        collapsed = {}
        for _, c in ipairs(Badges.CATEGORIES) do if c.children then collapsed[c.id] = true end end
    end
    saved = { cat = sv.cat or "overview", collapsed = collapsed, scroll = sv.scroll or {}, open = sv.open or {}, shut = sv.shut or {},
        onlyAcquired = sv.onlyAcquired == true }      -- (the Overview's "View Only Acquired Badges": off at first)
    ns.db.badgeUI = saved
    state.cat = saved.cat
    state.collapsed = saved.collapsed
end
local page                    -- the page frame, once built

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------
local function font(fs, name, fallback)
    local obj = _G[name] or _G[fallback or "GameFontHighlight"]
    if obj then fs:SetFontObject(obj) end
    return fs
end

local function text(parent, fontName, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    font(fs, fontName)
    fs:SetJustifyH("LEFT")
    return fs
end

-- Titles: 2 px bigger than the font they're made with.
local function bump(fs, n)
    local path, size, flags = fs:GetFont()
    if path and size then fs:SetFont(path, size + (n or 2), flags) end
    return fs
end

local function atlas(tex, name, useSize)
    if not (tex.SetAtlas and pcall(tex.SetAtlas, tex, name, useSize and true or false)) then return false end
    return true
end

-- First icon of the list that exists on this client.
-- (an icon the game hasn't got is skipped for the next in the list: the
-- game's file list says, where it has one - SetTexture takes any path)
local function iconExists(path)
    if type(GetFileIDFromPath) ~= "function" then return true end
    local ok, id = pcall(GetFileIDFromPath, path)
    return not ok or id ~= nil
end
local function setIcon(tex, names)
    for _, n in ipairs(names or {}) do
        local path = "Interface\\Icons\\" .. n
        if iconExists(path) then
            local ok, res = pcall(tex.SetTexture, tex, path)
            if ok and res ~= false then return end
        end
    end
    -- (none the game says it has: the first anyway, as before, else the "?")
    local first = names and names[1]
    if first and pcall(tex.SetTexture, tex, "Interface\\Icons\\" .. first) then return end
    tex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
end

local function commas(n)
    local s = tostring(math.floor(n or 0))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

local function nameOf(key)
    if not key or key == ns.meKey then return ns.me or "You" end
    local rp = ns.RP and ns.db and ns.db.rpNames and ns.RP.Name and ns.RP.Name(key)
    if rp then return rp end
    local m = ns.Roster and ns.Roster.Get(key)
    return m and m.name or key
end

-- The badge tooltip, laid out as totalRP3's character tooltip: the badge's
-- icon where TRP puts the profile icon (32 px, 4 px to the title), its
-- tier's coin on the icon's corner, the title where TRP puts the name (its
-- size). Then what it takes, and how it stands. (Badges' points aren't
-- shown, here or on the cards; they still count underneath.)
-- The points shield is drawn this much bigger than the number on it was
-- made for (everywhere it shows: cards, rows, the chest, tooltips).
local SHIELD_ART = 1.2
local TIP_ICON, TIP_SHIELD = 32, 0.65
local tipDeco                -- our pieces on GameTooltip: the coin, the points
local tipIconTex             -- (resolves a badge's icon to a file for the tooltip)

local function tipDecor()
    if tipDeco then return tipDeco end
    local f = CreateFrame("Frame", nil, GameTooltip)
    f:SetAllPoints()
    f.coin = f:CreateTexture(nil, "OVERLAY")
    f.points = f:CreateFontString(nil, "OVERLAY")
    f.points:SetJustifyH("CENTER")
    f.points:SetTextColor(1, 1, 1)
    f.points:SetWordWrap(false)
    tipIconTex = f:CreateTexture(nil, "BACKGROUND")
    tipIconTex:Hide()
    f:Hide()
    GameTooltip:HookScript("OnHide", function() f:Hide() end)
    pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipCleared", function() f:Hide() end)
    tipDeco = f
    return f
end

-- The size totalRP3 draws names in (its setting), else its default.
local function trpNameSize()
    local ok, v = pcall(function() return TRP3_API.configuration.getValue("tooltip_char_mainSize") end)
    return (ok and tonumber(v)) or 16
end

local function tipDate(t) return t and date("%m/%d/%y", t) or nil end

-- Badges' points, shown again (their shields on the cards, rows and
-- tooltips, and in the Tiers): /mw test badgepoints on, for officers and
-- Shandor only (Ledger.IsAdmin). Kept in MoonwardensDB.badgePoints.
function BUI.ShowPoints()
    return ns.db and ns.db.badgePoints and ns.Ledger and ns.Ledger.IsAdmin and ns.Ledger.IsAdmin(ns.meKey) or false
end
ns.tests.badgepoints = { usage = "on | off", help = "show badges' points on cards and tooltips (officers)", fn = function(arg)
    if not (ns.Ledger and ns.Ledger.IsAdmin and ns.Ledger.IsAdmin(ns.meKey)) then
        ns.print("Badge points are for officers to check.")
        return
    end
    arg = (arg or ""):lower()
    if arg ~= "on" and arg ~= "off" then
        ns.print(("badge points are %s. /mw test badgepoints on | off"):format(BUI.ShowPoints() and "shown" or "hidden"))
        return
    end
    ns.db.badgePoints = arg == "on" or nil
    ns.print(arg == "on" and "Badge points shown on cards and tooltips." or "Badge points hidden.")
    if BUI.Refresh then BUI.Refresh() end
end }

-- Under a badge's tooltip, its track: every tier, its goal in what it
-- counts ("Copper 10,000 kills"), and what's earned of it.
local function addTiers(track, res)
    if not (track and res) then return end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Tiers", 1, 0.82, 0)
    -- (a heading: 2 px over the tooltip's text)
    if ns.UI and ns.UI.TooltipLineSize then
        local _, size = GameTooltipText:GetFont()
        ns.UI.TooltipLineSize(GameTooltip:NumLines(), math.floor((size or 12) + 0.5) + 2)
    end
    for _, b in ipairs(track.tiers) do
        local e = res.badges[b.id] or { times = 0 }
        local col = Badges.TIER_COLOR[b.tier]
        local name = b.tier:sub(1, 1):upper() .. b.tier:sub(2)
        local goal = b.kind == "placement" and ({ "1st", "2nd", "3rd" })[b.place] or commas(b.goal)
        local unit = b.measure
        if unit and b.kind ~= "placement" and b.goal == 1 then unit = unit:gsub("s$", "") end   -- ("1 capture")
        local got = e.times > 0 and ((b.kind == "lifetime" or b.kind == "manual" or b.kind == "selflifetime")
            and "earned" or ("x" .. e.times)) or "-"
        local line = unit and ("%s %s %s"):format(name, goal, unit) or ("%s %s"):format(name, goal)
        if BUI.ShowPoints() then line = line .. ("  (%d pts)"):format(b.points) end
        GameTooltip:AddDoubleLine(line, got,
            col[1], col[2], col[3], e.times > 0 and 0.12 or 0.5, e.times > 0 and 1 or 0.5, e.times > 0 and 0 or 0.5)
    end
    GameTooltip:Show()
end

-- A badge tooltip's top, every one the same: the title in its tier's
-- colour (the shield at the right with points shown), its icon at the left.
-- tipFinish, after the lines under it: the coin on the icon's corner and the
-- points on the shield. (badgeTooltip; logTooltip, the Audit Log's.)
local function tipBegin(owner, b)
    local deco = tipDecor()
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    local c = Badges.TIER_COLOR[b.tier] or { 1, 0.82, 0 }
    -- (points hidden: the title alone; shown, the shield at the top right)
    local showPts = BUI.ShowPoints()
    local pts = b.points or 0
    if b.kind == "parent" then
        pts = 0
        for _, cid in ipairs(b.children or {}) do local cb = Badges.Get(cid); pts = pts + (cb and cb.points or 0) end
    end
    local sw, sh = math.floor(35 * TIP_SHIELD * SHIELD_ART + 0.5), math.floor(51 * TIP_SHIELD * SHIELD_ART + 0.5)
    if showPts then
        GameTooltip:AddDoubleLine(Badges.Title(b), ("|A:Legacy-Tree-Frame-Points-Icon:%d:%d|a"):format(sh, sw), c[1], c[2], c[3], 1, 1, 1)
    else
        GameTooltip:AddLine(Badges.Title(b), c[1], c[2], c[3])
    end
    setIcon(tipIconTex, b.icon)
    local file = tipIconTex:GetTexture()
    local placed = file and pcall(GameTooltip.AddTexture, GameTooltip, file, {
        width = TIP_ICON, height = TIP_ICON,
        anchor = Enum and Enum.TooltipTextureAnchor and Enum.TooltipTextureAnchor.LeftCenter,
        margin = { left = 0, right = 4, top = 0, bottom = 0 },
    })
    if file and not placed then pcall(GameTooltip.AddTexture, GameTooltip, file) end
    if ns.UI and ns.UI.TooltipTitleSize then ns.UI.TooltipTitleSize(trpNameSize()) end
    return { deco = deco, showPts = showPts, pts = pts, sw = sw }
end

local function tipFinish(b, h)
    local deco, showPts, pts, sw = h.deco, h.showPts, h.pts, h.sw
    GameTooltip:Show()
    -- Our pieces over it: the coin on the icon's corner, the points on the shield.
    deco:SetFrameLevel(GameTooltip:GetFrameLevel() + 5)
    local icon
    for i = 1, 10 do
        local t = _G["GameTooltipTexture" .. i]
        if t and t:IsShown() then icon = t; break end
    end
    local coin = b.tier and Badges.COIN[b.tier]
    deco.coin:ClearAllPoints()
    if coin and icon then
        local cs = math.floor(TIP_ICON * 0.4)
        deco.coin:SetSize(cs, cs)
        deco.coin:SetTexture(coin)
        deco.coin:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", cs * 0.25, -cs * 0.25)
        deco.coin:Show()
    else
        deco.coin:Hide()
    end
    local right = showPts and _G.GameTooltipTextRight1
    deco.points:ClearAllPoints()
    if right then
        font(deco.points, pts >= 100 and "GameFontHighlightSmall" or "GameFontHighlight")
        deco.points:SetText(pts)
        deco.points:SetWidth(sw * 2)
        deco.points:SetPoint("CENTER", right, "CENTER", 0, -4 * TIP_SHIELD * SHIELD_ART)
        deco.points:Show()
    else
        deco.points:Hide()
    end
    deco:Show()
end

local function badgeTooltip(owner, b, e)
    local h = tipBegin(owner, b)
    GameTooltip:AddLine(b.desc, 1, 1, 1, true)
    -- How it stands.
    local lines = {}
    if e.times > 0 then
        local again = b.kind == "weekly" or b.kind == "manualweekly" or b.kind == "selfweekly" or b.kind == "selfcount"
            or b.kind == "placement" or b.stack
        local when = tipDate(e.lastAt)
        if again then
            local n = ("Earned %d time%s"):format(e.times, e.times == 1 and "" or "s")
            lines[#lines + 1] = { when and (n .. ", last on " .. when) or n, 0.12, 1, 0 }
        else
            lines[#lines + 1] = { when and ("Earned on " .. when) or "Earned", 0.12, 1, 0 }
        end
    end
    if b.kind == "selflifetime" or b.kind == "manual" or b.kind == "lifetime" then
        lines[#lines + 1] = { ("Progress: %s / %s"):format(commas(e.value), commas(e.goal)), 1, 0.82, 0 }
    elseif b.kind == "granted" then
        lines[#lines + 1] = { "Granted by " .. Badges.Granters(b) .. ".", 1, 0.82, 0 }
    elseif b.kind == "parent" then
        lines[#lines + 1] = { ("%d of %d done."):format(e.value or 0, e.goal or 0), 1, 0.82, 0 }
    elseif b.kind == "rank" then
        lines[#lines + 1] = { ("Comes with the rank of %s."):format(b.rank), 1, 0.82, 0 }
    end
    -- (an addon it needs: in gold under its progress, as on its card)
    local needs = Badges.Needs(b)
    if needs then lines[#lines + 1] = { needs, 1, 0.82, 0 } end
    if #lines > 0 then
        GameTooltip:AddLine(" ")
        for _, l in ipairs(lines) do GameTooltip:AddLine(l[1], l[2], l[3], l[4], true) end
    end
    tipFinish(b, h)
end

-- An Audit Log or Approvals entry: its badge (the top every badge tooltip
-- has), the entry's line in full (the row cuts it off), and when, in gold
-- as a badge's progress is. No badge (an id gone since): the line and date.
local function logTooltip(owner, b, line, when)
    if not b then
        GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
        GameTooltip:AddLine(line, 1, 1, 1, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(when, 1, 0.82, 0)
        GameTooltip:Show()
        return
    end
    local h = tipBegin(owner, b)
    GameTooltip:AddLine(line, 1, 1, 1, true)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(when, 1, 0.82, 0)
    tipFinish(b, h)
end

---------------------------------------------------------------------------
-- Pieces drawn with the Legacy art
---------------------------------------------------------------------------
-- The framed, masked icon, with the tier's coin in its corner.
local function newIcon(parent, size)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetPoint("CENTER")
    f.tex:SetSize(size * 50 / 60, size * 50 / 60)
    pcall(function()
        local mask = f:CreateMaskTexture()
        mask:SetAtlas("UI-Frame-IconMask")
        mask:SetAllPoints(f.tex)
        f.tex:AddMaskTexture(mask)
        f.mask = mask
    end)
    f.frame = f:CreateTexture(nil, "OVERLAY")
    if atlas(f.frame, "Legacy-Tree-Frame-icon-frame", true) then
        local w, h = f.frame:GetSize()
        if w and w > 0 then f.frame:SetSize(w * size / 60, h * size / 60) end
        f.frame:SetPoint("CENTER")
    else
        f.frame:SetTexture("Interface\\Buttons\\UI-Quickslot2"); f.frame:SetPoint("CENTER"); f.frame:SetSize(size * 1.7, size * 1.7)
    end
    f.coin = f:CreateTexture(nil, "OVERLAY", nil, 2)
    local cs = math.max(12, math.floor(size * 0.3))
    f.coin:SetSize(cs, cs)
    f.coin:SetPoint("BOTTOMRIGHT", f.tex, "BOTTOMRIGHT", cs * 0.25, -cs * 0.25)
    return f
end

local function setBadgeIcon(icon, b, earned)
    setIcon(icon.tex, b.icon)
    icon.tex:SetDesaturated(not earned)
    icon.tex:SetAlpha(earned and 1 or 0.75)
    icon.frame:SetDesaturated(not earned)          -- (not earned: a grey border too)
    icon.coin:SetShown(b.tier and true or false)
    if b.tier then
        icon.coin:SetTexture(Badges.COIN[b.tier])   -- (full colour, earned or not)
    end
end

-- A Legacy progress bar: dark track, fill, frame, "n / goal".
local function newBar(parent, height)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetHeight(height or 16)
    holder.bg = holder:CreateTexture(nil, "BORDER")
    holder.bg:SetAllPoints()
    if not atlas(holder.bg, "Legacy-Progressbar-BG") then holder.bg:SetColorTexture(0, 0, 0, 0.6) end
    local bar = CreateFrame("StatusBar", nil, holder)
    bar:SetPoint("TOPLEFT", 0, 0)
    bar:SetPoint("BOTTOMRIGHT", 0, 3)
    -- (the fill: the new-badge dot's blue and look - a shine over its top
    -- half and a little glow - without its pulse)
    bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    bar:SetStatusBarColor(BLUE.disc[1], BLUE.disc[2], BLUE.disc[3])
    local fill = bar:GetStatusBarTexture()
    if fill then
        local glow = bar:CreateTexture(nil, "ARTWORK", nil, 2)
        glow:SetTexture("Interface\\Buttons\\WHITE8X8")
        glow:SetVertexColor(BLUE.halo[1], BLUE.halo[2], BLUE.halo[3], 0.3)
        glow:SetBlendMode("ADD")
        glow:SetAllPoints(fill)
        local shine = bar:CreateTexture(nil, "ARTWORK", nil, 3)
        shine:SetTexture("Interface\\Buttons\\WHITE8X8")
        shine:SetVertexColor(BLUE.edge[1], BLUE.edge[2], BLUE.edge[3], 0.3)
        shine:SetBlendMode("ADD")
        shine:SetPoint("TOPLEFT", fill, "TOPLEFT")
        shine:SetPoint("BOTTOMRIGHT", fill, "RIGHT")
    end
    bar:SetMinMaxValues(0, 1)
    holder.frame = bar:CreateTexture(nil, "OVERLAY")
    holder.frame:SetPoint("TOPLEFT", -8, 7)
    holder.frame:SetPoint("BOTTOMRIGHT", 8, -10)
    if not atlas(holder.frame, "Legacy-Progressbar-Frame") then holder.frame:Hide() end
    holder.text = bar:CreateFontString(nil, "OVERLAY", nil, 2)
    font(holder.text, "NumberFontNormal", "GameFontHighlightSmall")
    holder.text:SetPoint("CENTER", 0, 1)
    holder.bar = bar
    function holder:Set(v, max, label)
        max = math.max(1, max or 1)
        self.bar:SetMinMaxValues(0, max)
        self.bar:SetValue(math.max(0, math.min(v or 0, max)))
        self.text:SetText(label or (commas(v) .. " / " .. commas(max)))
    end
    return holder
end

-- The points shield (Legacy-Tree-Frame-Points-Icon) with a number on it.
-- `fontName`: a font object's name, or a size (that size of the Huge font).
-- `art`: how much bigger the shield is drawn than `scale` (SHIELD_ART).
local function newShield(parent, scale, fontName, art)
    scale = scale or 1
    art = art or SHIELD_ART
    local s = scale * art
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(35 * s, 51 * s)
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetAllPoints()
    if not atlas(f.icon, "Legacy-Tree-Frame-Points-Icon") then f.icon:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Shields") end
    f.points = f:CreateFontString(nil, "OVERLAY")
    if type(fontName) == "number" then
        local path, _, flags = (GameFontNormalHuge or GameFontNormal):GetFont()
        f.points:SetFont(path, fontName, flags or "")
    else
        font(f.points, fontName or (scale > 1.2 and "GameFontNormalHuge" or "GameFontNormalMed3"), "GameFontNormal")
    end
    f.points:SetTextColor(1, 1, 1)
    -- (a set width, centred: one digit sits as centred as two)
    f.points:SetWidth(70 * s)              -- (room for a score of thousands, still centred)
    f.points:SetJustifyH("CENTER")
    f.points:SetWordWrap(false)
    f.points:SetPoint("CENTER", 0, -4 * s)
    return f
end

-- A section heading: gold text over a thin line.
local function newHeading(parent, label)
    local h = bump(text(parent, "Game15Font_Shadow"))
    h:SetTextColor(1, 0.82, 0)
    h:SetText(label)
    h.line = parent:CreateTexture(nil, "ARTWORK")
    h.line:SetColorTexture(0.55, 0.45, 0.2, 0.6)
    h.line:SetHeight(1)
    h.line:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -3)
    h.line:SetPoint("RIGHT", parent, "RIGHT", -4, 0)
    return h
end

---------------------------------------------------------------------------
-- A scroll area with the game's scroll bar (MinimalScrollBar)
---------------------------------------------------------------------------
local function newScroll(parent)
    local sf = CreateFrame("ScrollFrame", nil, parent)
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(10, 10)
    sf:SetScrollChild(child)
    sf.child = child
    local okSB, sb = pcall(CreateFrame, "EventFrame", nil, parent, "MinimalScrollBar")
    if not (okSB and sb and sb.Init and sb.RegisterCallback and ScrollBarMixin and ScrollBarMixin.Event) then sb = nil end
    function sf:Range() return math.max(0, child:GetHeight() - self:GetHeight()) end
    function sf:Sync()
        if not sb then return end
        local range = self:Range()
        if range <= 0 then sb:Hide(); return end
        self.syncing = true
        pcall(function()
            sb:Init(self:GetHeight() / child:GetHeight(), SCROLL_STEP / range)
            sb:SetScrollPercentage(self:GetVerticalScroll() / range, true)
        end)
        self.syncing = false
        sb:Show()
    end
    function sf:ScrollTo(y)
        local range = self:Range()
        self:SetVerticalScroll(math.max(0, math.min(range, y)))
        self:Sync()
    end
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta) self:ScrollTo(self:GetVerticalScroll() - delta * SCROLL_STEP) end)
    sf:SetScript("OnVerticalScroll", function(self, offset) if self.onScroll then self.onScroll(offset) end end)
    if sb then
        sb:SetPoint("TOPLEFT", sf, "TOPRIGHT", 6, -2)
        sb:SetPoint("BOTTOMLEFT", sf, "BOTTOMRIGHT", 6, 2)
        sb:RegisterCallback(ScrollBarMixin.Event.OnScroll, function(_, pct)
            if sf.syncing then return end
            sf:SetVerticalScroll(pct * sf:Range())
        end, sf)
        sb:Hide()
    end
    sf.bar = sb
    return sf
end

---------------------------------------------------------------------------
-- Category list (left)
---------------------------------------------------------------------------
local function selectCat(id)
    state.cat = id
    if saved and not state.view then saved.cat = id end
    if page and page.search and page.search:GetText() ~= "" then
        page.search:SetText("")          -- (clears the search; OnTextChanged sets it)
        state.search = ""
    end
    BUI.Refresh()
    if page and page.scroll then page.scroll:ScrollTo(saved and not state.view and saved.scroll[id] or 0) end
end

local function newCatButton(parent, w)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, CAT_H - 2)
    b.normal = b:CreateTexture(nil, "BACKGROUND"); b.normal:SetAllPoints()
    b.sel = b:CreateTexture(nil, "BORDER"); b.sel:SetAllPoints(); b.sel:Hide()   -- (the selected glow, over the tab)
    b.hl = b:CreateTexture(nil, "HIGHLIGHT"); b.hl:SetAllPoints()
    b.label = text(b, "Game15Font_Shadow", "OVERLAY")
    b.label:SetPoint("LEFT", 10, 0)
    b.label:SetPoint("RIGHT", -26, 0)
    b.plus = b:CreateTexture(nil, "ARTWORK")
    b.plus:SetPoint("RIGHT", -8, 0)
    b.newDot = New.Dot(b, 10, "TOPLEFT", 5, -5)
    b:SetScript("OnClick", function(self)
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        if self.parentOf then
            state.collapsed[self.id] = not state.collapsed[self.id]
            BUI.Refresh()
        elseif not self.soon then
            selectCat(self.id)
        end
    end)
    b:SetScript("OnEnter", function(self)
        if self.soon then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.name .. " - coming soon", 1, 0.82, 0)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

local function styleCatButton(b, c, isParent, selected, indent)
    b.id, b.name, b.soon, b.parentOf = c.id, c.name, c.soon, isParent
    if b.newDot then b.newDot:SetShown(not isParent and New.InCat(c.id)) end
    b.label:SetText(c.soon and (c.name .. " (coming soon)") or c.name)
    b.label:ClearAllPoints()
    b.label:SetPoint("LEFT", 10 + (indent or 0), 0)
    b.label:SetPoint("RIGHT", -26, 0)
    if isParent then
        if not atlas(b.normal, "common-button-list-collapseExpand") then b.normal:SetColorTexture(0.2, 0.15, 0.05, 0.9) end
        if atlas(b.hl, "common-button-list-collapseExpand") then b.hl:SetBlendMode("ADD"); b.hl:SetAlpha(0.4) end
        local collapsed = state.collapsed[c.id]
        if not atlas(b.plus, collapsed and "common-button-list-plus" or "common-button-list-minus", true) then
            b.plus:SetTexture(collapsed and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up")
            b.plus:SetSize(14, 14)
        end
        b.plus:Show()
        b.sel:Hide()
        b.label:SetTextColor(1, 0.82, 0)
    else
        b.plus:Hide()
        -- The tab itself always; selected, its glow on top (alone, the glow
        -- art is mostly see-through and the tab looked gone).
        local sel = selected and not c.soon
        if not atlas(b.normal, "Legacy-Challenge-Left-Sub-Tab") then b.normal:SetColorTexture(0.1, 0.08, 0.05, 0.6) end
        if sel then
            if not atlas(b.sel, "Legacy-Challenge-Left-Sub-Tab-selected") then b.sel:SetColorTexture(1, 0.82, 0, 0.18) end
            b.sel:Show()
        else
            b.sel:Hide()
        end
        -- (the highlight layer draws over the text: added light, not covering it)
        if atlas(b.hl, "Legacy-Challenge-Left-Sub-Tab-selected") then b.hl:SetBlendMode("ADD"); b.hl:SetAlpha(0.45)
        else b.hl:SetColorTexture(1, 0.82, 0, 0.12) end
        b.hl:SetShown(not c.soon)
        if c.soon then b.label:SetTextColor(0.5, 0.5, 0.5)
        elseif sel then b.label:SetTextColor(1, 1, 1)
        else b.label:SetTextColor(1, 0.82, 0) end
        b.normal:SetDesaturated(c.soon and true or false)
    end
end

local function refreshCats(f)
    local n = 0
    local searching = state.search ~= ""
    local function place(c, isParent, indent)
        n = n + 1
        local b = f.catButtons[n]
        if not b then b = newCatButton(f.catHolder, f.catW); f.catButtons[n] = b end
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", f.catHolder, "TOPLEFT", indent or 0, -(n - 1) * CAT_H)
        b:SetWidth(f.catW - (indent or 0))
        styleCatButton(b, c, isParent, not searching and state.cat == c.id)
        b:Show()
    end
    for _, c in ipairs(Badges.CATEGORIES) do
        if c.children then
            place(c, true)
            if not state.collapsed[c.id] then
                for _, ch in ipairs(c.children) do place(ch, false, 10) end
            end
        else
            place(c, false)
        end
    end
    for i = n + 1, #f.catButtons do f.catButtons[i]:Hide() end
end
function BUI.RefreshCats() if page and page.catButtons then refreshCats(page) end end

---------------------------------------------------------------------------
-- Badge cards (right)
---------------------------------------------------------------------------
local function newCard(parent)
    local c = CreateFrame("Button", nil, parent)
    c:SetHeight(CARD_H)
    c.bg = c:CreateTexture(nil, "BACKGROUND"); c.bg:SetAllPoints()
    c.ribbon = c:CreateTexture(nil, "ARTWORK")
    c.ribbon:SetPoint("TOPLEFT", 5, -4)
    c.ribbon:SetPoint("TOPRIGHT", -80, -4)
    c.ribbon:SetHeight(40)
    c.icon = newIcon(c, 60)
    c.newDot = New.Dot(c.icon, 13, "TOPRIGHT", -9, -9)
    c.icon:SetPoint("TOPLEFT", 12, -18)
    c.title = bump(text(c, "GameFontHighlightLarge"))
    c.title:SetPoint("TOPLEFT", c.ribbon, "TOPLEFT", 70, -12)
    c.coin = c:CreateTexture(nil, "OVERLAY")
    c.coin:SetSize(14, 14)
    c.coin:SetPoint("LEFT", c.title, "RIGHT", 4, 0)
    c.times = text(c, "GameFontNormalLarge")
    c.times:SetPoint("LEFT", c.coin, "RIGHT", 4, 0)
    c.desc = text(c, "SystemFont_Shadow_Med1")
    c.desc:SetPoint("TOPLEFT", c.ribbon, "BOTTOMLEFT", 72, -2)
    c.desc:SetPoint("RIGHT", c, "RIGHT", -70, 0)
    c.desc:SetJustifyV("TOP")
    c.progress = newBar(c, 16)
    c.progress:SetPoint("TOPLEFT", 84, -(CARD_H - 28))
    c.progress:SetPoint("TOPRIGHT", -70, -(CARD_H - 28))
    -- (granted and rank badges: who gives it, in place of the bar)
    c.info = text(c, "GameFontNormalSmall")
    c.info:SetPoint("TOPLEFT", 84, -(CARD_H - 30))
    c.info:SetPoint("RIGHT", c, "RIGHT", -70, 0)
    -- (an addon it needs, Badges.Needs: under the bar, as `info` is drawn)
    c.needs = text(c, "GameFontNormalSmall")
    c.needs:SetPoint("TOPLEFT", 84, -(CARD_H - 18))
    c.needs:SetPoint("RIGHT", c, "RIGHT", -70, 0)
    c.needs:Hide()
    -- A parent's children, listed under it (as Explore Azeroth's are); the
    -- parent folds them away with a click, Legacy's +/- showing which.
    c.plus = c:CreateTexture(nil, "OVERLAY")
    c.plus:SetSize(20, 20)
    c.plus:SetPoint("TOPLEFT", 76, -(CARD_H - 32))
    c.plusText = text(c, "GameFontNormal")          -- (gold: Expand / Collapse)
    c.plusText:SetPoint("LEFT", c.plus, "RIGHT", 4, 0)
    c.listHead = text(c, "GameFontNormal")
    c.listHead:SetPoint("TOPLEFT", 24, -(CARD_H - 4))
    c.rows = {}
    -- Tall cards: Legacy's tiled top, middle and bottom.
    c.bgTop = c:CreateTexture(nil, "BACKGROUND"); c.bgTop:SetPoint("TOPLEFT"); c.bgTop:SetPoint("TOPRIGHT")
    c.bgBot = c:CreateTexture(nil, "BACKGROUND"); c.bgBot:SetPoint("BOTTOMLEFT"); c.bgBot:SetPoint("BOTTOMRIGHT")
    c.bgMid = c:CreateTexture(nil, "BACKGROUND", nil, -1)
    -- Badges asked for (patrols): report one, for the officers to approve.
    c.report = CreateFrame("Button", nil, c, "UIPanelButtonTemplate")
    c.report:SetSize(120, 20)
    c.report:SetPoint("BOTTOMRIGHT", -12, 10)
    c.report:SetScript("OnClick", function(self)
        local b = self:GetParent().badge
        if b then BUI.AskReport(b) end
    end)
    c.report:Hide()
    -- Picked out for a moment when a link leads here (BUI.Focus).
    c.sel = c:CreateTexture(nil, "BORDER")
    c.sel:SetAllPoints()
    if not atlas(c.sel, "Legacy-Challenge-Cards-selected") then c.sel:SetColorTexture(1, 0.82, 0, 0.15) end
    c.sel:Hide()
    -- A child's card leads to its parent.
    c:SetScript("OnClick", function(self)
        local b = self.badge
        if b and b.parent then BUI.Focus(b.parent)
        elseif b and b.kind == "parent" and saved then
            PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
            saved.open[b.id] = not saved.open[b.id] or nil     -- (folded until opened)
            BUI.Refresh()
        end
    end)
    c.shield = newShield(c)
    c.shield:SetPoint("TOPRIGHT", -14, -26)
    c.shield:Hide()                                   -- (no points shown on badges)
    c.dateBg = c:CreateTexture(nil, "OVERLAY")
    c.dateBg:SetPoint("TOPRIGHT", -6, -3)
    if not atlas(c.dateBg, "Legacy-Challenge-Cards-Date-BG", true) then c.dateBg:SetSize(1, 1) end
    c.check = c:CreateTexture(nil, "OVERLAY", nil, 2)
    if not atlas(c.check, "worldquest-tracker-checkmark", true) then c.check:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready") end
    c.check:SetSize(18, 18)
    c.check:SetPoint("TOPRIGHT", -10, -6)
    c.date = text(c, "GameFontNormal")
    c.date:SetPoint("RIGHT", c.check, "LEFT", -2, 0)
    c:SetScript("OnEnter", function(self)
        if not self.badge then return end
        if not state.view and New.SeeCard(self.badge, self.track) then self.newDot:Hide() end
        badgeTooltip(self, self.badge, self.entry)
        local st = self.track
        if st then addTiers(st.track, self.result) end
    end)
    c:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return c
end

-- One criterion: a Legacy bar with its name, and a check once done.
local CRIT_H, CRIT_GAP = 30, 5
local function newCriterion(parent)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(CRIT_H)
    r.bg = r:CreateTexture(nil, "BORDER"); r.bg:SetAllPoints()
    if not atlas(r.bg, "Legacy-Challenge-Cards-Bar") then r.bg:SetColorTexture(0.15, 0.12, 0.08, 0.8) end
    r.icon = newIcon(r, 24)
    r.icon:SetPoint("LEFT", 4, 0)
    r.shield = newShield(r, 0.55, "GameFontHighlightSmall")
    r.shield:SetPoint("RIGHT", -26, -1)
    r.shield:Hide()                                   -- (no points shown on badges)
    r.points = r.shield.points
    r.name = text(r, "SystemFont_Small2", "ARTWORK")
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
    r.name:SetPoint("RIGHT", r, "RIGHT", -26, 0)
    r.name:SetWordWrap(false)
    r.check = r:CreateTexture(nil, "ARTWORK")
    if not atlas(r.check, "worldquest-tracker-checkmark", true) then r.check:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready") end
    r.check:SetSize(16, 16)
    r.check:SetPoint("RIGHT", -6, 0)
    r:EnableMouse(true)
    r:SetScript("OnEnter", function(self)
        if self.badge then badgeTooltip(self, self.badge, self.entry); return end
        if not self.target then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(("Level %d: %s"):format(self.target.level, self.target.name), 1, 0.82, 0)
        if self.target.more then GameTooltip:AddLine(self.target.name .. " " .. self.target.more, 1, 1, 1, true) end
        GameTooltip:AddLine(("Nobody in your party may be above level %d."):format(self.target.level), 0.62, 0.62, 0.62, true)
        GameTooltip:AddLine(self.done and "Done this month." or "Not done this month.", self.done and 0.12 or 0.62, self.done and 1 or 0.62, self.done and 0 or 0.62)
        GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return r
end

-- The card's background: one piece, or the tiled one when it's tall.
local function cardArt(c, earned, tall)
    local v = earned and "" or "-Disable"
    local okTall = tall and atlas(c.bgTop, "Legacy-Challenge-Cards-tiled-top" .. v, true)
        and atlas(c.bgBot, "Legacy-Challenge-Cards-tiled-bottom" .. v, true)
        and atlas(c.bgMid, "Legacy-Challenge-Cards-tiled-vertical" .. v, true)
    if okTall then
        -- As Legacy Challenges' own tall cards (Blizzard_LegacySystemTemplates):
        -- the middle at its atlas size, then stretched over the whole card 10
        -- in from top and bottom, under the top and bottom pieces; tiled
        -- downward, set after the atlas (which resets the wrap).
        c.bgMid:ClearAllPoints()
        c.bgMid:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -10)
        c.bgMid:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", 0, 10)
        c.bgMid:SetHorizTile(false)
        c.bgMid:SetVertTile(true)
    end
    c.bgTop:SetShown(okTall and true or false)
    c.bgBot:SetShown(okTall and true or false)
    c.bgMid:SetShown(okTall and true or false)
    c.bg:SetShown(not okTall)
    if not okTall and not atlas(c.bg, earned and "Legacy-Challenge-Cards" or "Legacy-Challenge-Cards-Disable") then
        c.bg:SetColorTexture(0.12, 0.1, 0.07, earned and 0.95 or 0.7)
    end
end

-- Returns the card's height. A "parent" (any compound badge, made with
-- Badges.Compound - see the template's rules in Badges.lua) is drawn here
-- the one way for all of them: tall Legacy card, its children as rows,
-- folding with a click. Keep it generic: nothing here may be about one
-- particular compound badge.
local function fillCard(c, b, e, key, result, opts)
    c.badge, c.entry = b, e
    local earned = e.times > 0
    -- A month's Huntress Training card isn't greyed out while its month is
    -- running: it's there to be hunted. Once the month is over, it's grey
    -- only if none of its bounties were completed. (Its check and date still
    -- wait for all of them.)
    local lit = earned
    if b.kind == "parent" then lit = b.active or (e.value or 0) > 0 end
    if opts and opts.lit ~= nil then lit = opts.lit end      -- (a track: lit once any tier is earned)
    local kids = b.kind == "parent" and b.children or {}
    local open = #kids > 0 and saved and saved.open[b.id] and true or false
    local rows = math.ceil(#kids / 2)
    local headed = b.listLabel ~= nil                -- (a heading over the rows, if it has one)
    local h = CARD_H + (open and ((headed and 26 or 6) + rows * (CRIT_H + CRIT_GAP)) or 0)
    c:SetHeight(h)
    cardArt(c, lit, open)
    if not atlas(c.ribbon, lit and "Legacy-Challenge-Cards-Ribbon-Brown" or "Legacy-Challenge-Cards-Ribbon-Brown-Disable", true) then
        c.ribbon:SetHeight(40)
        c.ribbon:SetColorTexture(0.3, 0.2, 0.1, 0.8)
    end
    setBadgeIcon(c.icon, b, lit)
    c.title:SetText(Badges.Title(b))
    c.title:SetTextColor(lit and 1 or 0.62, lit and 1 or 0.62, lit and 1 or 0.62)
    c.coin:Hide()                                    -- (the tier shows on the icon's corner only)
    c.times:ClearAllPoints()
    c.times:SetPoint("LEFT", c.title, "RIGHT", 6, 0)
    -- Re-earnable ones say how often; one-time ones don't.
    if (b.kind == "weekly" or b.kind == "manualweekly" or b.kind == "selfweekly" or b.kind == "selfcount" or b.kind == "placement" or b.stack) and e.times > 0 then
        c.times:SetText("x" .. e.times); c.times:Show()
    else
        c.times:Hide()
    end
    c.desc:SetText(b.desc)
    c.desc:SetTextColor(lit and 1 or 0.7, lit and 1 or 0.7, lit and 1 or 0.7)
    local plain = b.kind == "granted" or b.kind == "rank"
    c.progress:SetShown(not plain)
    c.info:SetShown(plain)
    if b.kind == "parent" then
        c.progress:Set(e.value, e.goal, ("Bounties: %d / %d"):format(e.value or 0, e.goal or 0))
    elseif b.kind == "weekly" or b.kind == "manualweekly" or b.kind == "selfweekly" then
        c.progress:Set(e.value, e.goal, ("This week: %s / %s"):format(commas(e.value), commas(e.goal)))
    elseif b.kind == "placement" then
        c.progress:SetShown(false)
        c.info:SetShown(true)
        c.info:SetText("Claimed a day after the weekly reset, from last week's final standings.")
    elseif b.kind == "selfcount" then
        c.progress:SetShown(false)              -- (how often shows by the title)
        c.info:SetShown(false)
    elseif plain then
        local part = b.parent and Badges.Get(b.parent)
        local text = b.kind == "rank" and ("Comes with the rank of %s."):format(b.rank)
            or ("Granted by %s.%s"):format(Badges.Granters(b), part and ("  |cff9d9d9dPart of %s.|r"):format(part.name) or "")
        if b.autoRequest == "rank" and e.times == 0 then
            -- (mine, waiting: say so)
            local waiting = false
            if not key and ns.Ledger then
                for _, r in ipairs(ns.Ledger.Pending()) do if r.who == ns.meKey and r.badge == b.id then waiting = true end end
            end
            text = waiting and ("|cffffd100Waiting for an officer to approve your rank of %s.|r"):format(b.rank)
                or ("Requested when you reach the rank of %s; an officer approves it."):format(b.rank)
        end
        c.info:SetText(text)
    else
        -- (mine: how many reported and still waiting for an officer)
        local waiting = 0
        if b.requestable and not key and ns.Ledger then
            for _, r in ipairs(ns.Ledger.Pending()) do
                if r.who == ns.meKey and Badges.CounterOf(Badges.Get(r.badge)) == Badges.CounterOf(b) then waiting = waiting + (r.n or 1) end
            end
        end
        c.progress:Set(e.value, e.goal, waiting > 0 and ("%s / %s  (%d waiting)"):format(commas(e.value), commas(e.goal), waiting) or nil)
    end
    -- `noInfo` (Badges.lua): nothing under the description - we don't need
    -- that additional detail on these.
    if b.noInfo then c.progress:Hide(); c.info:Hide() end
    local off = Badges.CategorySoon(b.cat)          -- (a category switched off: its buttons greyed)
    local canReport = b.requestable and not key
    c.report:SetShown(canReport and true or false)
    c.report:SetEnabled(not off)
    if canReport then c.report:SetText("Report a " .. (b.unit or "Patrol"):gsub("^%l", string.upper)) end
    -- (an addon it needs: its line under the bar, the bar up a little to
    -- make room)
    local needs = Badges.Needs(b)
    c.needs:SetText(needs or "")
    c.needs:SetShown(needs ~= nil)
    local barY = needs and (CARD_H - 38) or (CARD_H - 28)   -- (2 px more room above the line, 2 below)
    c.progress:SetPoint("TOPRIGHT", canReport and -140 or -70, -barY)
    c.progress:SetPoint("TOPLEFT", #kids > 0 and 104 or 84, -barY)   -- (room for a parent's +/-)

    -- A parent's children: two columns of rows, each a badge of its own
    -- (icon, level and name, points, a check once earned; its own tooltip).
    c.listHead:SetShown(open and headed)
    c.plus:SetShown(#kids > 0)
    c.plusText:SetShown(#kids > 0)
    c.plusText:SetText(open and "Collapse" or "Expand")
    if #kids > 0 and not atlas(c.plus, open and "128-redbutton-minus" or "128-redbutton-plus") then
        c.plus:SetTexture(open and "Interface\\Buttons\\UI-MinusButton-Up" or "Interface\\Buttons\\UI-PlusButton-Up")
    end
    if open and headed then
        c.listHead:SetText(b.listLabel or "Includes")       -- (no points shown)
    end
    local w = (c:GetWidth() > 0 and c:GetWidth() or 500)
    local cw = math.floor((w - 40 - 10) / 2)
    local shown = open and kids or {}          -- (folded: no rows at all)
    for i = 1, math.max(#shown, #c.rows) do
        local cid, r = shown[i], c.rows[i]
        local child = cid and Badges.Get(cid)
        if child then
            if not r then r = newCriterion(c); c.rows[i] = r end
            local ce = result and result.badges[cid] or { times = 0 }
            r.badge, r.entry, r.target = child, ce, child.target
            r.done = ce.times > 0
            r:SetWidth(cw)
            r:ClearAllPoints()
            local row, col = math.floor((i - 1) / 2), (i - 1) % 2
            r:SetPoint("TOPLEFT", c, "TOPLEFT", 20 + col * (cw + 10), -(CARD_H + (headed and 22 or 2) + row * (CRIT_H + CRIT_GAP)))
            setBadgeIcon(r.icon, child, r.done)
            r.name:SetText(child.label or child.name)
            r.name:SetTextColor(r.done and 1 or 0.75, r.done and 1 or 0.75, r.done and 1 or 0.75)
            r.points:SetText(child.points)
            r.shield.icon:SetDesaturated(not r.done)
            -- (points shown: the shield, the name up to it; else up to the check)
            local sp = BUI.ShowPoints()
            r.shield:SetShown(sp)
            r.name:ClearAllPoints()
            r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
            if sp then r.name:SetPoint("RIGHT", r.shield, "LEFT", -4, 0) else r.name:SetPoint("RIGHT", r, "RIGHT", -26, 0) end
            r.check:SetShown(r.done)
            r:Show()
        elseif r then
            r:Hide()
        end
    end
    c.info:ClearAllPoints()
    c.info:SetPoint("TOPLEFT", 84, -(CARD_H - 30))
    c.info:SetPoint("RIGHT", c, "RIGHT", -70, 0)
    -- (a parent's shield: the points its children have earned)
    c.shield.points:SetText(b.kind == "parent" and (e.childPoints or 0) or b.points)
    c.shield:SetShown(BUI.ShowPoints())
    c.shield.icon:SetDesaturated(not lit)
    c.dateBg:SetShown(earned)
    c.check:SetShown(earned)
    c.date:SetShown(earned)
    if earned then c.date:SetText(Badges.WeekDate(e.last)) end
    return h
end

-- A tier track's card (Badges.TRACKS): the tier to earn next, drawn as a
-- card of its own (fillCard), then lit if any tier was ever earned, titled
-- "Name: Tier", and the tiers earned shown as coin counters along the
-- bottom-left of the ribbon (xN where it can be earned again).
local function fillTrack(c, head, key, result)
    local st = Badges.TrackState(head.track, result)
    local cur = st.current
    local h = fillCard(c, cur, result.badges[cur.id], key, result, { lit = st.any, track = st })
    c.track, c.result = st, result
    c.times:Hide()
    -- The check and date: the last time any tier was earned.
    local last
    for _, b in ipairs(st.track.tiers) do
        local e = result.badges[b.id]
        if e.times > 0 and e.last and (not last or e.last > last) then last = e.last end
    end
    c.dateBg:SetShown(last ~= nil)
    c.check:SetShown(last ~= nil)
    c.date:SetShown(last ~= nil)
    if last then c.date:SetText(Badges.WeekDate(last)) end
    if cur.kind == "placement" then
        c.title:SetText(st.track.name)
        c.desc:SetText(st.track.desc or cur.desc)
    end
    -- The counters: every tier earned at least once, low to high.
    c.pips = c.pips or {}
    local n = 0
    for _, b in ipairs(st.track.tiers) do
        local e = result.badges[b.id]
        if e.times > 0 then
            n = n + 1
            local p = c.pips[n]
            if not p then
                p = CreateFrame("Frame", nil, c)
                p:SetSize(40, 14)
                p.coin = p:CreateTexture(nil, "OVERLAY")
                p.coin:SetSize(13, 13)
                p.coin:SetPoint("LEFT")
                p.count = text(p, "GameFontHighlightSmall")
                p.count:SetPoint("LEFT", p.coin, "RIGHT", 2, 0)
                c.pips[n] = p
            end
            p.coin:SetTexture(Badges.COIN[b.tier])
            local again = b.kind == "weekly" or b.kind == "manualweekly" or b.kind == "selfweekly" or b.kind == "placement"
            p.count:SetText(again and ("x" .. e.times) or "")
            local col = Badges.TIER_COLOR[b.tier]
            p.count:SetTextColor(col[1], col[2], col[3])
            p:SetWidth(again and (16 + p.count:GetStringWidth() + 6) or 16)
            p:ClearAllPoints()
            if n == 1 then p:SetPoint("BOTTOMLEFT", c.ribbon, "BOTTOMLEFT", 72, 3)
            else p:SetPoint("LEFT", c.pips[n - 1], "RIGHT", 4, 0) end
            p:Show()
        end
    end
    for i = n + 1, #c.pips do c.pips[i]:Hide() end
    -- (with counters on the ribbon, the description sits a little lower)
    c.desc:ClearAllPoints()
    c.desc:SetPoint("TOPLEFT", c.ribbon, "BOTTOMLEFT", 72, n > 0 and -6 or -2)
    c.desc:SetPoint("RIGHT", c, "RIGHT", -70, 0)
    return h
end

local function searchHits(result)
    local q = state.search:lower()
    local list = {}
    local seenTrack = {}
    for _, b in ipairs(Badges.LIST) do
      if not b.parent then                    -- (a child is found through its parent's card)
        local hay = Badges.Title(b) .. " " .. (b.tier or "") .. " " .. b.desc .. " " .. b.kind .. " " .. b.cat
        for _, cid in ipairs(b.children or {}) do
            local child = Badges.Get(cid)
            if child then hay = hay .. " " .. child.name .. " " .. child.desc end
        end
        for _, n in ipairs(b.target and b.target.names or {}) do hay = hay .. " " .. n end
        hay = hay:lower()
        if hay:find(q, 1, true) and not (b.track and seenTrack[b.track]) then
            if b.track then seenTrack[b.track] = true end
            list[#list + 1] = b
        end
      end
    end
    return list
end

-- A category's cards: the earned ones first (a track: any tier; a compound
-- badge: any of its own), else the list's order; of those not earned, a
-- badge marked `lead` first. A past month's bounties with none done aren't
-- shown: only this month's are there to be hunted.
local function earnedFirst(list, result)
    local out, rest = {}, {}
    local lead = {}
    for _, b in ipairs(list) do
        local e = result.badges[b.id] or { times = 0 }
        local got
        if b.track then got = Badges.TrackState(b.track, result).any
        elseif b.kind == "parent" then got = (e.value or 0) > 0
        else got = e.times > 0 end
        local past = b.kind == "parent" and b.month and Badges.BOUNTY and b.month ~= Badges.BOUNTY.month
        if got then out[#out + 1] = b
        elseif not past and b.lead then lead[#lead + 1] = b
        elseif not past then rest[#rest + 1] = b end
    end
    for _, b in ipairs(lead) do out[#out + 1] = b end
    for _, b in ipairs(rest) do out[#out + 1] = b end
    return out
end

local function showCards(f, list, result)
    local child = f.scroll.child
    local y = 0
    f.cardY, f.cardOf = {}, {}
    for i, b in ipairs(list) do
        local c = f.cards[i]
        if not c then c = newCard(child); f.cards[i] = c end
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
        c:SetPoint("RIGHT", child, "RIGHT", 0, 0)
        local h
        if b.track then h = fillTrack(c, b, state.view, result)
        else
            h = fillCard(c, b, result.badges[b.id], state.view, result)
            c.track = nil
            for _, p in ipairs(c.pips or {}) do p:Hide() end
            c.desc:ClearAllPoints()
            c.desc:SetPoint("TOPLEFT", c.ribbon, "BOTTOMLEFT", 72, -2)
            c.desc:SetPoint("RIGHT", c, "RIGHT", -70, 0)
        end
        c.sel:Hide()
        c.newDot:SetShown(not state.view and New.InCard(b, c.track))
        f.cardY[b.id], f.cardOf[b.id] = y, c
        c:Show()
        y = y + h + CARD_GAP
    end
    for i = #list + 1, #f.cards do f.cards[i]:Hide() end
    return y
end

---------------------------------------------------------------------------
-- The badge board: a guildie's Badge Showcase (three slots) over their
-- Badge Collection (everything else they've earned), as icons. On the
-- Overview (mine) and in the Badge Chest (anyone's: BadgeChest.lua).
-- The Showcase is never sorted: the Chest's sort (and anything else) only
-- orders the Collection under it; the Showcase stays as placed.
-- With `all` (the Overview's "View Only Acquired Badges" off), the badges
-- not yet earned follow the Collection, greyed, each filled bottom to top
-- in the progress bar's colour as far as it's got - closest first. They
-- can't be dragged.
-- Mine can be rearranged by dragging an icon: within either part, or from
-- one to the other. A Showcase slot can be left empty (any of the three).
-- Onto an empty slot: it goes there. Onto a filled one: from the Showcase,
-- the two swap; from the Collection, it takes the slot and pushes the others
-- along to the nearest empty slot (right first, then left) - none empty, the
-- one furthest right is bumped to the front of the Collection. (All our own frames: a picture follows
-- the cursor, nothing of the game's cursor or bags is used.) What's kept,
-- and how it's shared: Badges.Arrange, Badges.SetLayout.
---------------------------------------------------------------------------
local SHOW_N = Badges.SHOWCASE_N
local drag                 -- { board, id } while an icon is being dragged
local dragGhost
local lastDrop = 0

local function cursorXY()
    local x, y = GetCursorPosition()
    local s = UIParent:GetEffectiveScale()
    return x / s, y / s
end

-- Is the cursor over `fr` (and inside `clip`, the scroll area it's in)?
local function over(fr, clip)
    -- (the frame's own IsMouseOver: this client has no MouseIsOver global)
    local function on(x) return x.IsMouseOver and x:IsMouseOver() or false end
    return fr:IsVisible() and on(fr) and (not clip or on(clip))
end

-- Where a drop would land: ("show", slot) or ("rest", place).
local function dropTarget(bd)
    for i, s in ipairs(bd.slots) do if over(s, bd.clip) then return "show", i end end
    for i = 1, #bd.restIds do
        local c = bd.cells[i]
        if c and over(c, bd.clip) then return "rest", i end
    end
    if over(bd.grid, bd.clip) then return "rest", #bd.restIds + 1 end
end

-- The glow on where it would land.
local function markTarget(bd, to, i)
    local m = bd.mark
    m:ClearAllPoints()
    local fr = to == "show" and bd.slots[i] or (to == "rest" and bd.cells[i] and i <= #bd.restIds and bd.cells[i])
    if fr then
        m:SetAllPoints(fr)
        m:Show()
    elseif to == "rest" then
        -- (past the last: the next free place)
        local x, y = bd.restPos(i)
        m:SetSize(bd.icon, bd.icon)
        m:SetPoint("TOPLEFT", bd, "TOPLEFT", x, y)
        m:Show()
    else
        m:Hide()
    end
end

-- A board icon's tooltip: the badge, then (a tier track) all its tiers,
-- as on its card - the board shows one tier of a track only.
local function cellTooltip(c)
    badgeTooltip(c, c.badge, c.entry)
    local args = c.board and c.board.args
    if c.badge.track and args then addTiers(Badges.TRACKS[c.badge.track], args[2]) end
end

-- Let go: the tooltip of the icon now under the cursor (the cursor never
-- "entered" it, so it wouldn't show by itself).
local function tipUnderCursor(bd)
    for _, list in ipairs({ bd.slots, bd.cells }) do
        for _, c in ipairs(list) do
            if c.badge and c:IsShown() and over(c, bd.clip) then cellTooltip(c); return end
        end
    end
end

local function endDrag(dropIt)
    local d = drag
    if not d then return end
    drag = nil
    lastDrop = GetTime()
    if dragGhost then dragGhost:Hide() end
    local bd = d.board
    bd.mark:Hide()
    local to, ti
    if dropIt then to, ti = dropTarget(bd) end
    -- (where it came from, by its id: the board may have been redrawn meanwhile)
    local show, rest = {}, {}
    for i = 1, SHOW_N do show[i] = bd.showIds[i] or false end
    for _, id in ipairs(bd.restIds) do rest[#rest + 1] = id end
    local from, fi
    for i = 1, SHOW_N do if show[i] == d.id then from, fi = "show", i end end
    for i, id in ipairs(rest) do if id == d.id then from, fi = "rest", i end end
    if not (to and from) or (to == from and ti == fi) then bd.redraw(); tipUnderCursor(bd); return end
    if to == "show" and from == "show" then
        show[fi], show[ti] = show[ti], show[fi]           -- (a swap; onto an empty one, a move)
    elseif to == "show" then
        table.remove(rest, fi)
        if show[ti] then
            -- (the others along to the nearest empty slot: right, else left;
            -- none, the furthest right to the front of the Collection)
            local e
            for k = ti + 1, SHOW_N do if not show[k] then e = k; break end end
            if e then
                for k = e, ti + 1, -1 do show[k] = show[k - 1] end
            else
                for k = ti - 1, 1, -1 do if not show[k] then e = k; break end end
                if e then
                    for k = e, ti - 1 do show[k] = show[k + 1] end
                else
                    local bumped = show[SHOW_N]
                    table.insert(rest, 1, bumped)
                    rest = Badges.Regroup(rest, bumped)
                    for k = SHOW_N, ti + 1, -1 do show[k] = show[k - 1] end
                end
            end
        end
        show[ti] = d.id
    else
        if from == "show" then show[fi] = false else table.remove(rest, fi) end
        table.insert(rest, math.min(ti, #rest + 1), d.id)
        rest = Badges.Regroup(rest, d.id)               -- (its tiers go with it)
    end
    pcall(PlaySound, SOUNDKIT and SOUNDKIT.IG_ABILITY_ICON_DROP or 838)
    if bd.onArrange then bd.onArrange() end
    Badges.SetLayout(show, rest)
    if BUI.Refresh then BUI.Refresh() end
    if ns.BadgeChest and ns.BadgeChest.Refresh then ns.BadgeChest.Refresh() end
    tipUnderCursor(bd)
end

local function ghost()
    if dragGhost then return dragGhost end
    local g = CreateFrame("Frame", nil, UIParent)
    g:SetFrameStrata("TOOLTIP")
    g:SetSize(48, 48)
    g.icon = newIcon(g, 48)
    g.icon:SetAllPoints()
    g:SetAlpha(0.9)
    g:EnableMouse(false)
    g:SetScript("OnUpdate", function(self)
        if not drag then self:Hide(); return end
        local x, y = cursorXY()
        self:ClearAllPoints()
        self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
        markTarget(drag.board, dropTarget(drag.board))
        -- (let go somewhere the drag never heard of)
        if not IsMouseButtonDown("LeftButton") then endDrag(true) end
    end)
    g:Hide()
    dragGhost = g
    return g
end

local function startDrag(bd, cell)
    if drag or not cell.badge or cell.locked then return end      -- (only earned badges move)
    GameTooltip:Hide()
    drag = { board = bd, id = cell.badge.id }
    pcall(PlaySound, SOUNDKIT and SOUNDKIT.IG_ABILITY_ICON_PICKUP or 837)
    local g = ghost()
    setBadgeIcon(g.icon, cell.badge, true)
    g:Show()
    cell:SetAlpha(0.35)
end

local function newBoardCell(bd, size, countFont)
    local c = CreateFrame("Button", nil, bd)
    c.board = bd
    c:SetSize(size, size)
    c.icon = newIcon(c, size)
    c.icon:SetAllPoints()
    -- (how many times, bottom left over the icon's frame)
    c.count = c.icon:CreateFontString(nil, "OVERLAY")
    c.count:SetDrawLayer("OVERLAY", 7)
    font(c.count, countFont, "NumberFontNormal")
    c.count:SetPoint("BOTTOMLEFT", c.icon.tex, "BOTTOMLEFT", -1, -2)
    -- (not earned yet: how far along, bottom to top, the progress bar's colour)
    -- (the blue of the dot and the bars: the colour, a little glow, a bright edge)
    c.fill = c.icon:CreateTexture(nil, "ARTWORK", nil, 3)
    -- (see-through enough to show the icon under it, strong enough to read)
    c.fill:SetColorTexture(BLUE.disc[1], BLUE.disc[2], BLUE.disc[3], 0.35)
    c.fill:SetPoint("BOTTOMLEFT", c.icon.tex, "BOTTOMLEFT")
    c.fill:SetPoint("BOTTOMRIGHT", c.icon.tex, "BOTTOMRIGHT")
    c.fillGlow = c.icon:CreateTexture(nil, "ARTWORK", nil, 4)
    c.fillGlow:SetColorTexture(BLUE.halo[1], BLUE.halo[2], BLUE.halo[3], 0.22)
    c.fillGlow:SetBlendMode("ADD")
    c.fillGlow:SetAllPoints(c.fill)
    c.fillTop = c.icon:CreateTexture(nil, "ARTWORK", nil, 5)
    c.fillTop:SetColorTexture(BLUE.edge[1], BLUE.edge[2], BLUE.edge[3], 0.95)
    c.fillTop:SetHeight(1)
    c.fillTop:SetPoint("BOTTOMLEFT", c.fill, "TOPLEFT")
    c.fillTop:SetPoint("BOTTOMRIGHT", c.fill, "TOPRIGHT")
    for _, t in ipairs({ c.fill, c.fillGlow, c.fillTop }) do
        if c.icon.mask then pcall(t.AddMaskTexture, t, c.icon.mask) end
        t:Hide()
    end
    c:RegisterForDrag("LeftButton")
    c.newDot = New.Dot(c.icon, math.max(10, math.floor(size * 0.22)), "TOPRIGHT", -size * 0.14, -size * 0.14)
    c:SetScript("OnEnter", function(self)
        if not (self.badge and not drag) then return end
        if bd.editable and (self.locked and New.See({ self.badge.id }) or (not self.locked and New.SeeShown(self.badge))) then self.newDot:Hide() end
        cellTooltip(self)
    end)
    c:SetScript("OnLeave", function() GameTooltip:Hide() end)
    c:SetScript("OnClick", function(self)
        if self.badge and bd.onClick and GetTime() - lastDrop > 0.2 then bd.onClick(self.badge) end
    end)
    c:SetScript("OnDragStart", function(self) if bd.editable then startDrag(bd, self) end end)
    c:SetScript("OnDragStop", function() endDrag(true) end)
    return c
end

-- `it`: { b, e } (nil: an empty slot); `frac`: not earned yet, how far along.
-- (/mw test fill on: every not-earned one drawn half full, to see the fill)
local fillPreview
ns.tests.fill = { usage = "on | off", help = "every not-earned badge drawn half filled on the Overview", fn = function(arg)
    arg = (arg or ""):lower()
    if arg ~= "on" and arg ~= "off" then
        ns.print(("fill preview is %s. /mw test fill on | off"):format(fillPreview and "on" or "off"))
        return
    end
    fillPreview = arg == "on" and 0.5 or nil
    ns.print(fillPreview and "Fill preview on: not-earned badges drawn half full." or "Fill preview off.")
    if BUI.Refresh then BUI.Refresh() end
end }
local function fillCell(c, it, frac)
    if frac and fillPreview then frac = fillPreview end
    c.badge, c.entry = it and it.b, it and it.e
    c.locked = frac ~= nil
    if it then
        setBadgeIcon(c.icon, it.b, not c.locked)
        c.count:SetText((not c.locked and it.e.times > 1) and ("x" .. it.e.times) or "")
    else
        -- (an empty slot: the frame, dark inside)
        c.icon.tex:SetColorTexture(0, 0, 0, 0.55)
        c.icon.tex:SetDesaturated(false)
        c.icon.tex:SetAlpha(1)
        c.icon.frame:SetDesaturated(false)
        c.icon.coin:Hide()
        c.count:SetText("")
    end
    local h = c.icon.tex:GetHeight()
    if c.locked and frac > 0 and h and h > 0 then
        c.fill:SetHeight(math.max(5, h * math.min(1, frac)))   -- (started at all: a sliver that shows)
        c.fill:Show(); c.fillGlow:Show()
        c.fillTop:SetShown(frac < 1)
    else
        c.fill:Hide(); c.fillGlow:Hide(); c.fillTop:Hide()
    end
    c:SetAlpha((drag and it and drag.id == it.b.id) and 0.35 or 1)
    c.newDot:SetShown(c.board and c.board.editable and it and (c.locked and New.Is(it.b.id) or (not c.locked and New.IsShown(it.b))) or false)
end

-- opts: tile, tileGap (the Showcase's icons), icon, gap (the Collection's),
-- clip (the scroll frame it's in), onClick(badge), onArrange(), head (a
-- frame for the right end of the Collection's heading: the Chest's sort,
-- the Overview's checkbox).
local function newBoard(parent, opts)
    local bd = CreateFrame("Frame", nil, parent)
    bd.tile, bd.tileGap = opts.tile or 76, opts.tileGap or 20
    bd.icon, bd.gap = opts.icon or 53, opts.gap or 12
    bd.clip, bd.onClick, bd.onArrange = opts.clip, opts.onClick, opts.onArrange
    bd.showIds, bd.restIds = {}, {}
    bd.showHead = newHeading(bd, "Badge Showcase")
    bd.showHead:SetPoint("TOPLEFT", 4, -6)
    bd.slots = {}
    for i = 1, SHOW_N do bd.slots[i] = newBoardCell(bd, bd.tile, "NumberFontNormalLarge") end
    bd.none = text(bd, "GameFontDisable")
    -- (mine: how to fill and empty the Showcase, under its slots, always)
    bd.dragHint = text(bd, "GameFontDisable")
    bd.dragHint:SetJustifyH("CENTER")
    bd.dragHint:SetText("Drag a badge here to showcase it, or into your Collection to take it out.")
    bd.restHead = newHeading(bd, "Badge Collection")
    bd.grid = CreateFrame("Frame", nil, bd)
    bd.hint = text(bd.grid, "GameFontDisable")
    bd.hint:SetPoint("CENTER")
    bd.cells = {}
    bd.markHolder = CreateFrame("Frame", nil, bd)
    bd.markHolder:SetAllPoints()
    bd.markHolder:SetFrameLevel(bd:GetFrameLevel() + 20)
    bd.mark = bd.markHolder:CreateTexture(nil, "OVERLAY")
    bd.mark:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    bd.mark:SetBlendMode("ADD")
    bd.mark:Hide()
    bd:SetScript("OnHide", function() if drag and drag.board == bd then endDrag(false) end end)
    -- (the heading's right end: given by the page it's on)
    function bd:SetHeadWidget(w) self.head = w; w:SetParent(self) end

    -- Draws `key`'s (mine: rearrangeable), the Collection in `sort`
    -- (Badges.SORTS); `all`: the badges not yet earned after it. Returns
    -- its height.
    function bd:Fill(key, result, sort, all)
        self.args = { key, result, sort, all }
        self.redraw = function() self:Fill(unpack(self.args)) end
        local mine = key == ns.meKey
        self.editable = mine
        local w = self:GetWidth()
        local show, rest, filled = Badges.Arrange(key, result, sort)
        local locked = all and Badges.Unearned(result) or {}
        wipe(self.showIds); wipe(self.restIds)
        for i = 1, SHOW_N do self.showIds[i] = show[i] and show[i].b.id or false end
        for _, it in ipairs(rest) do self.restIds[#self.restIds + 1] = it.b.id end

        -- The Showcase: three slots, centred. Never sorted.
        self.showHead:SetText(("Badge Showcase - %d/%d"):format(filled, SHOW_N))
        local y = -30
        local T, TG = self.tile, self.tileGap
        local x0 = math.floor((w - (SHOW_N * T + (SHOW_N - 1) * TG)) / 2)
        for i, s in ipairs(self.slots) do
            s:ClearAllPoints()
            s:SetPoint("TOPLEFT", x0 + (i - 1) * (T + TG), y)
            fillCell(s, show[i])
            s:Show()
        end
        y = y - T - 12
        self.dragHint:ClearAllPoints()
        self.dragHint:SetShown(mine)
        if mine then
            self.dragHint:SetWidth(math.max(50, w - 8))       -- (a narrow board: it wraps)
            self.dragHint:SetPoint("TOP", self, "TOPLEFT", math.floor(w / 2), y + 4)
            y = y - math.max(12, math.ceil(self.dragHint:GetStringHeight() or 12)) - 4
        end
        -- (no badges at all: the Collection's heading and its control stay -
        -- the Overview's View Only Acquired Badges must be there to untick -
        -- and "no badges yet" goes where its icons would be)
        local any = filled + #rest + #locked > 0
        self.none:Hide()

        -- The Collection: the rest, in rows, centred; then (all) the ones
        -- not earned yet.
        self.restHead:Show(); self.restHead.line:Show()
        self.restHead:ClearAllPoints()
        self.restHead:SetPoint("TOPLEFT", 4, y - 4)
        if self.head then
            self.head:ClearAllPoints()
            self.head:SetPoint("RIGHT", self, "TOPLEFT", w - 4, y - 12)
            self.head:Show()
        end
        y = y - 30
        local I, G = self.icon, self.gap
        local pitch = I + G
        local cols = math.max(1, math.floor((w + G) / pitch))
        local left = math.floor((w - (cols * pitch - G)) / 2)
        local top = y
        self.restPos = function(i)
            local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
            return left + col * pitch, top - row * pitch
        end
        local n = #rest + #locked
        for i = 1, n do
            local c = self.cells[i]
            if not c then c = newBoardCell(self, I, "NumberFontNormal"); self.cells[i] = c end
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", self.restPos(i))
            if i <= #rest then fillCell(c, rest[i])
            else local l = locked[i - #rest]; fillCell(c, l, l.frac) end
            c:Show()
        end
        for i = n + 1, #self.cells do self.cells[i]:Hide() end
        -- (one row more while I can drag: room to drop at the end)
        local rows = math.max(1, math.ceil(n / cols))
        if mine and n > 0 and #locked == 0 and n % cols == 0 then rows = rows + 1 end
        self.grid:ClearAllPoints()
        self.grid:SetPoint("TOPLEFT", 0, top + 4)
        self.grid:SetSize(w, rows * pitch + 4)
        self.grid:Show()
        self.hint:SetShown(n == 0)
        if not any then
            self.hint:SetText(mine and "No badges yet. Defend Ashenvale to earn your first." or "No badges yet.")
        else
            self.hint:SetText("Nothing more.")
        end
        y = top - rows * pitch
        self:SetHeight(-y)
        return -y
    end
    return bd
end

---------------------------------------------------------------------------
-- Overview (right): your Badge Showcase, then your Badge Collection (the
-- badge board, above), with "View Only Acquired Badges" on its heading:
-- off (the first time, and until it's ticked; remembered), every badge
-- there is follows your earned ones, greyed and filled as far as you've got.
-- (Inspect Badges, for the Badge Inspector, is under the category list, on
-- every page.)
---------------------------------------------------------------------------
local function buildOverview(f, parent, w)
    local o = CreateFrame("Frame", nil, parent)
    o:SetPoint("TOPLEFT")
    o:SetWidth(w)

    o.board = newBoard(o, { clip = f.scroll,
        onClick = function(b) BUI.Focus(b.parent or b.id) end })
    o.board:SetPoint("TOPLEFT")
    o.board:SetWidth(w)

    -- View Only Acquired Badges: its label, then the box.
    local hold = CreateFrame("Frame", nil, o)
    hold:SetSize(10, 24)
    local cb = CreateFrame("CheckButton", nil, hold, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("RIGHT")
    local label = text(hold, "GameFontNormal")
    label:SetText("View Only Acquired Badges")
    label:SetPoint("RIGHT", cb, "LEFT", -2, 1)
    hold:SetWidth(label:GetStringWidth() + 30)
    cb:SetScript("OnClick", function(self)
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        if saved then saved.onlyAcquired = self:GetChecked() and true or false end
        BUI.Refresh()
        dotsChanged()                          -- (new badges not earned: dotted only while shown)
    end)
    o.only = cb
    o.board:SetHeadWidget(hold)
    f.overview = o
    return o
end

local function fillOverview(f, result, key)
    local o = f.overview
    o.board:SetWidth(o:GetWidth())
    local only = saved and saved.onlyAcquired or false
    o.only:SetChecked(only)
    local h = o.board:Fill(key or ns.meKey, result, "arranged", not only)
    o:SetHeight(h + 8)
    return h + 8
end

---------------------------------------------------------------------------
-- The page
---------------------------------------------------------------------------
local function build(f)
    page = f
    loadSaved()
    local W, H = f:GetWidth(), f:GetHeight()
    if not W or W < 100 then W, H = 528, 392 end
    f.catW = math.floor(math.min(210, W * 0.28))

    -- Search box (SearchBoxTemplate, as Legacy Challenges'), over the list.
    local okS, sb = pcall(CreateFrame, "EditBox", nil, f, "SearchBoxTemplate")
    if not okS or not sb then sb = CreateFrame("EditBox", nil, f, "InputBoxTemplate") end
    sb:SetSize(f.catW - 8, 20)
    sb:SetPoint("TOPLEFT", 8, -2)
    sb:SetAutoFocus(false)
    sb:HookScript("OnTextChanged", function(self)
        local t = self:GetText() or ""
        t = t:gsub("^%s+", ""):gsub("%s+$", "")
        if t ~= state.search then
            state.search = t
            BUI.Refresh()
            if f.scroll then f.scroll:ScrollTo(0) end
        end
    end)
    if type(sb.Instructions) == "table" and sb.Instructions.SetText then sb.Instructions:SetText("Search badges") end
    f.search = sb

    f.catHolder = CreateFrame("Frame", nil, f)
    f.catHolder:SetPoint("TOPLEFT", 4, -32)
    f.catHolder:SetPoint("BOTTOMLEFT", 4, 34)
    f.catHolder:SetWidth(f.catW)
    f.catButtons = {}

    -- Your Badge Chest: pinned under the list, so it's there on every page.
    f.chest = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.chest:SetSize(f.catW - 8, 26)
    f.chest:SetPoint("BOTTOMLEFT", 8, 4)
    f.chest:SetText("Inspect Badges")
    f.chest:SetScript("OnClick", function() if ns.BadgeChest then ns.BadgeChest.Open(ns.meKey) end end)
    -- Badge Management (officers): stacked above it, for those who may award.
    f.manage = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.manage:SetSize(f.catW - 8, 26)
    f.manage:SetPoint("BOTTOMLEFT", f.chest, "TOPLEFT", 0, 2)
    f.manage:SetText("Badge Management")
    f.manage:SetScript("OnClick", function() if ns.OfficerUI and ns.OfficerUI.Toggle then ns.OfficerUI.Toggle() end end)
    f.manage:Hide()

    f.divider = f:CreateTexture(nil, "ARTWORK")
    f.divider:SetPoint("TOPLEFT", f.catW + 8, 4)
    f.divider:SetPoint("BOTTOMLEFT", f.catW + 8, -4)
    f.divider:SetWidth(12)
    if not atlas(f.divider, "Legacy-Tree-Frame-divider-Vertical") then f.divider:SetColorTexture(0.4, 0.32, 0.15, 0.6); f.divider:SetWidth(1) end

    -- Viewing someone else's: a bar on top with the way back to mine.
    local left = f.catW + 24
    f.viewing = CreateFrame("Frame", nil, f)
    f.viewing:SetPoint("TOPLEFT", left, 0)
    f.viewing:SetPoint("TOPRIGHT", -20, 0)
    f.viewing:SetHeight(26)
    f.viewing.bg = f.viewing:CreateTexture(nil, "BACKGROUND"); f.viewing.bg:SetAllPoints()
    if not atlas(f.viewing.bg, "Legacy-Challenge-Cards-Bar") then f.viewing.bg:SetColorTexture(0.15, 0.12, 0.08, 0.8) end
    f.viewing.text = text(f.viewing, "GameFontNormal")
    f.viewing.text:SetPoint("LEFT", 10, 0)
    f.viewing.back = CreateFrame("Button", nil, f.viewing, "UIPanelButtonTemplate")
    f.viewing.back:SetSize(110, 20)
    f.viewing.back:SetPoint("RIGHT", -4, 0)
    f.viewing.back:SetText("My Badges")
    f.viewing.back:SetScript("OnClick", function()
        state.view = nil
        state.cat = saved and saved.cat or "overview"
        f.restoreScroll = true
        BUI.Refresh()
    end)
    f.viewing:Hide()

    f.scroll = newScroll(f)
    f.scroll:SetPoint("TOPLEFT", left, -2)
    f.scroll:SetPoint("BOTTOMRIGHT", -20, 2)
    f.scroll.child:SetWidth(W - left - 20)
    f.cards = {}
    buildOverview(f, f.scroll.child, W - left - 20)   -- (after the scroll: the board's drops are inside it)

    f.empty = text(f.scroll.child, "GameFontDisable")
    f.empty:SetPoint("TOP", 0, -40)

    f.testBanner = text(f, "GameFontNormalSmall")
    f.testBanner:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", -20, 2)
    f.testBanner:SetText("|cffff8040TEST MODE|r - includes your test awards")

    -- Where each of my categories was scrolled to; put back on each show.
    f.scroll.onScroll = function(y)
        if saved and not state.view and state.search == "" and not f.restoring then saved.scroll[state.cat] = y end
    end
    f.restoreScroll = true
    f:HookScript("OnShow", function() f.restoreScroll = true end)

    f:SetScript("OnHide", function() GameTooltip:Hide() end)
end

local function refresh(f)
    page = f
    -- (a category switched off or gone since it was last open: back to the Overview)
    if Badges.CategorySoon(state.cat) or not Badges.IsPage(state.cat) then state.cat = "overview"; if saved then saved.cat = "overview" end end
    f.testBanner:SetShown(ns.Ledger and ns.Ledger.Testing() and true or false)
    -- (Badge Management: only for those who may award; the list makes room)
    local manage = ns.Ledger and ns.Ledger.CanAward() and ns.OfficerUI and true or false
    f.manage:SetShown(manage)
    f.catHolder:SetPoint("BOTTOMLEFT", 4, manage and 62 or 34)
    refreshCats(f)
    local key = state.view
    local result = key and Badges.Of(key) or Badges.Mine()

    -- The viewing bar pushes the scroll area down.
    f.scroll:ClearAllPoints()
    local left = f.catW + 24
    if key then
        f.viewing:Show()
        local heard = Badges.HeardFrom(key)
        local m = ns.Roster and ns.Roster.Get(key)
        local note = ""
        if not heard and m and not m.online then
            -- (offline: what they last sent, else what the guild has seen)
            local at = Badges.SavedAt(key)
            note = at and ("  |cff9d9d9d(offline: as of %s)|r"):format(date("%b %d", at))
                or "  |cff9d9d9d(offline: only what the guild has seen)|r"
        elseif not heard then
            note = "  |cff9d9d9d(asking them for the rest...)|r"
        end
        f.viewing.text:SetText(("Viewing: |cffffffff%s|r%s"):format(nameOf(key), note))
        f.scroll:SetPoint("TOPLEFT", left, -32)
    else
        f.viewing:Hide()
        f.scroll:SetPoint("TOPLEFT", left, -2)
    end
    f.scroll:SetPoint("BOTTOMRIGHT", -20, 2)

    local h
    f.empty:Hide()
    if state.search ~= "" then
        f.overview:Hide()
        local list = searchHits(result)
        h = showCards(f, list, result)
        if #list == 0 then
            f.empty:SetText(("No badges match \"%s\"."):format(state.search)); f.empty:Show(); h = 80
        end
    elseif state.cat == "overview" then
        showCards(f, {}, result)
        f.overview:Show()
        h = fillOverview(f, result, key)
    else
        f.overview:Hide()
        local list = earnedFirst(Badges.InCategory(state.cat), result)
        h = showCards(f, list, result)
        if #list == 0 then f.empty:SetText("Coming soon."); f.empty:Show(); h = 80 end
    end
    f.scroll.child:SetHeight(math.max(1, h))
    if f.scroll:GetVerticalScroll() > f.scroll:Range() then f.scroll:SetVerticalScroll(f.scroll:Range()) end
    f.scroll:Sync()
    if f.restoreScroll then
        f.restoreScroll = nil
        if saved and not key and state.search == "" then
            f.restoring = true
            f.scroll:ScrollTo(saved.scroll[state.cat] or 0)
            f.restoring = nil
        end
    end
end

function BUI.Refresh()
    if page and page:IsVisible() then refresh(page) end
end

-- Go to a badge's card (its category, scrolled to it) and pick it out.
function BUI.Focus(id)
    local b = Badges.Get(id)
    if not (b and page) then return end
    PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
    state.cat = b.cat
    if saved and not state.view then saved.cat = b.cat end
    if page.search and page.search:GetText() ~= "" then page.search:SetText(""); state.search = "" end
    refresh(page)
    local y, c = page.cardY and page.cardY[id], page.cardOf and page.cardOf[id]
    if y then page.scroll:ScrollTo(y - 6) end
    if c then
        c.sel:Show()
        C_Timer.After(1.5, function() if c.badge == b then c.sel:Hide() end end)
    end
end

-- Open someone's badges (nil: mine): their Badge Chest, at once, wherever
-- I am (BadgeChest.lua). The Badges tab isn't touched.
function Badges.View(key)
    if ns.BadgeChest then ns.BadgeChest.Open(key) end
end

-- (the tab icon: the Warsong Gulch Mark of Honor)
UI.AddPage(1, "Stats", build, refresh,
    { order = 2, icon = { "INV_Misc_Rune_07", "INV_Misc_Book_09" }, tooltip = "Badges", title = "Your Badges",
      bgAtlas = "Legacy-Rewards-Tracker-background",
      dot = function() return New.Tab() end, onSelect = function() New.TabSeen() end })

ns.onLogin(function()
    ns.listen("BADGES", function(key) if state.view == key then BUI.Refresh() end end)
    ns.listen("LEDGER", function() BUI.Refresh(); New.Check() end)     -- (an officer's award)
    ns.listen("BADGES", function(key) if key == ns.meKey then New.Check() end end)
    ns.after(5, New.Check, "new badges")       -- (once the Ledger's loaded)
end, "badges ui")

-- Reporting a patrol: a note for the officers, then it waits for them. (Our
-- own dialog, Dialog.lua, never the game's StaticPopup.)
function BUI.AskReport(b)
    ns.Dialog.Show({
        text = "Report a patrol for the officers to approve.\n\nWhen did it start?",
        accept = "Report", when = true,
        onAccept = function(_, when)
            local ok, err = ns.Ledger.Request(b.id, when)
            if not ok then return false, err or "Not reported." end   -- (the box stays, saying why)
            ns.print(("Patrol of %s reported. It's waiting for an officer to approve it."):format(ns.Dialog.When(when)))
        end,
    })
end

-- The Legacy-art pieces, for the Officers tab (OfficerUI.lua).
BUI.Kit = {
    font = font, text = text, bump = bump, atlas = atlas, commas = commas, nameOf = nameOf, setIcon = setIcon, iconExists = iconExists,   -- (setIcon, badgeTooltip: the roster's Top Badges too)
    newIcon = newIcon, setBadgeIcon = setBadgeIcon, newBar = newBar, newHeading = newHeading, newShield = newShield,
    newScroll = newScroll, newCatButton = newCatButton, styleCatButton = styleCatButton,
    badgeTooltip = badgeTooltip, logTooltip = logTooltip, newBoard = newBoard,
}
