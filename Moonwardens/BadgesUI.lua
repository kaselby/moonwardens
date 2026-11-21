-- BadgesUI: the Stats tab of the guild window, laid out as the game's Legacy
-- Challenges (Blizzard_LegacySystem) and drawn with its art: a search box and
-- a folding category list on the left; on the right the Overview (score,
-- most prestigious, recent, progress) or a category's badge cards, each
-- scrolling with the game's scroll bar. Another guildie's badges show the
-- same way (Badges.View, from the right-click menu).
-- We use the Legacy atlases only, not its templates: those live in a
-- load-on-demand addon of the game's, and its code expects achievements.
local _, ns = ...
local UI = ns.UI
local Badges = ns.Badges
local BUI = {}
ns.BadgesUI = BUI

local CARD_H = 112
local CARD_GAP = 5
local CAT_H = 25
local SCROLL_STEP = 40

local state = { cat = "overview", view = nil, search = "", collapsed = {} }
-- Kept across closing and reloads (db.badgeUI): the category open, the
-- folded headers, and how far down each category was scrolled.
local saved

local function loadSaved()
    if saved or not ns.db then return end
    local sv = ns.db.badgeUI or {}
    saved = { cat = sv.cat or "overview", collapsed = sv.collapsed or {}, scroll = sv.scroll or {} }
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
local function setIcon(tex, names)
    for _, n in ipairs(names or {}) do
        local ok, res = pcall(tex.SetTexture, tex, "Interface\\Icons\\" .. n)
        if ok and res ~= false then return end
    end
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

-- The badge tooltip: title, what it takes, how it stands.
local function badgeTooltip(owner, b, e)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    local c = Badges.TIER_COLOR[b.tier]
    GameTooltip:AddLine(Badges.Title(b), c[1], c[2], c[3])
    GameTooltip:AddLine(b.desc, 1, 1, 1, true)
    GameTooltip:AddLine(" ")
    if e.times > 0 then
        if b.kind == "weekly" then
            GameTooltip:AddLine(("Earned %d time%s, last in the week of %s"):format(e.times, e.times == 1 and "" or "s",
                Badges.WeekDate(e.last)), 0.12, 1, 0)
        else
            GameTooltip:AddLine("Earned in the week of " .. Badges.WeekDate(e.last), 0.12, 1, 0)
        end
    else
        GameTooltip:AddLine("Not earned yet", 0.62, 0.62, 0.62)
    end
    if b.kind == "weekly" then
        GameTooltip:AddLine(("This week: %s / %s"):format(commas(e.value), commas(e.goal)), 1, 0.82, 0)
        GameTooltip:AddLine("Can be earned again: every 500 kills in a week is a full Copper, Silver and Gold.", 0.62, 0.62, 0.62, true)
    else
        GameTooltip:AddLine(("Progress: %s / %s"):format(commas(e.value), commas(e.goal)), 1, 0.82, 0)
    end
    GameTooltip:AddLine(("Worth %d points%s"):format(b.points, b.kind == "weekly" and " each time" or ""), 0.62, 0.62, 0.62)
    GameTooltip:Show()
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
    icon.coin:SetTexture(Badges.COIN[b.tier])
    icon.coin:SetDesaturated(not earned)
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
    local ok = pcall(bar.SetStatusBarTexture, bar, "Legacy-Progressbar-Fill")
    local fill = bar:GetStatusBarTexture()
    if fill and fill.SetAtlas and atlas(fill, "Legacy-Progressbar-Fill") then
        -- (fine)
    elseif not ok or not fill then
        bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar"); bar:SetStatusBarColor(0.9, 0.7, 0.2)
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
local function newShield(parent, scale)
    scale = scale or 1
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(35 * scale, 51 * scale)
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetAllPoints()
    if not atlas(f.icon, "Legacy-Tree-Frame-Points-Icon") then f.icon:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Shields") end
    f.points = f:CreateFontString(nil, "OVERLAY")
    font(f.points, scale > 1.2 and "GameFontNormalHuge" or "GameFontNormalMed3", "GameFontNormal")
    f.points:SetTextColor(1, 1, 1)
    f.points:SetPoint("CENTER", -1 * scale, -4 * scale)
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
    b.label:SetText(c.name)
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
    c.progress:SetPoint("BOTTOMLEFT", 84, 16)
    c.progress:SetPoint("BOTTOMRIGHT", -70, 16)
    c.shield = newShield(c)
    c.shield:SetPoint("TOPRIGHT", -14, -26)
    c.dateBg = c:CreateTexture(nil, "OVERLAY")
    c.dateBg:SetPoint("TOPRIGHT", -6, -3)
    if not atlas(c.dateBg, "Legacy-Challenge-Cards-Date-BG", true) then c.dateBg:SetSize(1, 1) end
    c.check = c:CreateTexture(nil, "OVERLAY", nil, 2)
    if not atlas(c.check, "worldquest-tracker-checkmark", true) then c.check:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready") end
    c.check:SetSize(18, 18)
    c.check:SetPoint("TOPRIGHT", -10, -6)
    c.date = text(c, "GameFontNormal")
    c.date:SetPoint("RIGHT", c.check, "LEFT", -2, 0)
    c:SetScript("OnEnter", function(self) if self.badge then badgeTooltip(self, self.badge, self.entry) end end)
    c:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return c
end

local function fillCard(c, b, e)
    c.badge, c.entry = b, e
    local earned = e.times > 0
    if not atlas(c.bg, earned and "Legacy-Challenge-Cards" or "Legacy-Challenge-Cards-Disable") then
        c.bg:SetColorTexture(0.12, 0.1, 0.07, earned and 0.95 or 0.7)
    end
    if not atlas(c.ribbon, earned and "Legacy-Challenge-Cards-Ribbon-Brown" or "Legacy-Challenge-Cards-Ribbon-Brown-Disable", true) then
        c.ribbon:SetHeight(40)
        c.ribbon:SetColorTexture(0.3, 0.2, 0.1, 0.8)
    end
    setBadgeIcon(c.icon, b, earned)
    c.title:SetText(Badges.Title(b))
    c.title:SetTextColor(earned and 1 or 0.62, earned and 1 or 0.62, earned and 1 or 0.62)
    c.coin:SetTexture(Badges.COIN[b.tier])
    c.coin:SetDesaturated(not earned)
    -- Re-earnable ones say how often; one-time ones don't.
    if b.kind == "weekly" and e.times > 0 then
        c.times:SetText("x" .. e.times); c.times:Show()
    else
        c.times:Hide()
    end
    c.desc:SetText(b.desc)
    c.desc:SetTextColor(earned and 1 or 0.7, earned and 1 or 0.7, earned and 1 or 0.7)
    if b.kind == "weekly" then
        c.progress:Set(e.value, e.goal, ("This week: %s / %s"):format(commas(e.value), commas(e.goal)))
    else
        c.progress:Set(e.value, e.goal)
    end
    c.shield.points:SetText(b.points)
    c.shield.icon:SetDesaturated(not earned)
    c.dateBg:SetShown(earned)
    c.check:SetShown(earned)
    c.date:SetShown(earned)
    if earned then c.date:SetText(Badges.WeekDate(e.last)) end
end

local function searchHits(result)
    local q = state.search:lower()
    local list = {}
    for _, b in ipairs(Badges.LIST) do
        local hay = (Badges.Title(b) .. " " .. b.desc .. " " .. b.kind .. " " .. b.cat):lower()
        if hay:find(q, 1, true) then list[#list + 1] = b end
    end
    return list
end

local function showCards(f, list, result)
    local child = f.scroll.child
    local y = 0
    for i, b in ipairs(list) do
        local c = f.cards[i]
        if not c then c = newCard(child); f.cards[i] = c end
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
        c:SetPoint("RIGHT", child, "RIGHT", 0, 0)
        fillCard(c, b, result.badges[b.id])
        c:Show()
        y = y + CARD_H + CARD_GAP
    end
    for i = #list + 1, #f.cards do f.cards[i]:Hide() end
    return y
end

---------------------------------------------------------------------------
-- Overview (right): score, most prestigious, recent, progress
---------------------------------------------------------------------------
local PRESTIGE_N, RECENT_N = 5, 5

local function buildOverview(f, parent, w)
    local o = CreateFrame("Frame", nil, parent)
    o:SetPoint("TOPLEFT")
    o:SetWidth(w)
    o.title = bump(text(o, "GameFontNormalHuge", "OVERLAY"))
    o.title:SetPoint("TOPLEFT", 4, -8)
    o.sub = text(o, "GameFontHighlight")
    o.sub:SetPoint("TOPLEFT", o.title, "BOTTOMLEFT", 0, -6)
    o.shield = newShield(o, 1.4)
    o.shield:SetPoint("TOPRIGHT", -6, -2)
    o.scoreLabel = text(o, "GameFontNormalSmall")
    o.scoreLabel:SetText("Score")
    o.scoreLabel:SetPoint("RIGHT", o.shield, "LEFT", -6, 4)
    o.total = newBar(o, 16)
    o.total:SetPoint("TOPLEFT", 12, -66)
    o.total:SetPoint("TOPRIGHT", -60, -66)

    o.prestigeHead = newHeading(o, "Most Prestigious")
    o.prestigeHead:SetPoint("TOPLEFT", 4, -100)
    o.tiles = {}
    local tileW = math.floor((w - 8) / PRESTIGE_N)
    for i = 1, PRESTIGE_N do
        local t = CreateFrame("Button", nil, o)
        t:SetSize(tileW, 100)
        t:SetPoint("TOPLEFT", 4 + (i - 1) * tileW, -122)
        t.icon = newIcon(t, 52)
        t.icon:SetPoint("TOP", 0, -4)
        t.name = text(t, "GameFontHighlightSmall")
        t.name:SetJustifyH("CENTER")
        t.name:SetPoint("TOP", t.icon, "BOTTOM", 0, -4)
        t.name:SetWidth(tileW - 6)
        t.times = text(t, "GameFontNormal")
        t.times:SetPoint("TOPRIGHT", t.icon, "TOPRIGHT", 6, 4)
        t:SetScript("OnEnter", function(self) if self.badge then badgeTooltip(self, self.badge, self.entry) end end)
        t:SetScript("OnLeave", function() GameTooltip:Hide() end)
        t:SetScript("OnClick", function(self) if self.badge then selectCat(self.badge.cat) end end)
        o.tiles[i] = t
    end
    o.prestigeEmpty = text(o, "GameFontDisable")
    o.prestigeEmpty:SetPoint("TOPLEFT", 12, -140)

    o.recentHead = newHeading(o, "Recent Badges")
    o.recentHead:SetPoint("TOPLEFT", 4, -236)
    o.recent = {}
    for i = 1, RECENT_N do
        local r = CreateFrame("Button", nil, o)
        r:SetHeight(30)
        r:SetPoint("TOPLEFT", 4, -258 - (i - 1) * 33)
        r:SetPoint("RIGHT", o, "RIGHT", -4, 0)
        r.bg = r:CreateTexture(nil, "BACKGROUND"); r.bg:SetAllPoints()
        if not atlas(r.bg, "Legacy-Challenge-Cards-Bar") then r.bg:SetColorTexture(0.15, 0.12, 0.08, 0.8) end
        r.icon = newIcon(r, 26)
        r.icon:SetPoint("LEFT", 4, 0)
        r.name = text(r, "GameFontHighlight")
        r.name:SetPoint("LEFT", r.icon, "RIGHT", 8, 0)
        r.date = text(r, "GameFontNormalSmall")
        r.date:SetPoint("RIGHT", -10, 0)
        r.points = text(r, "GameFontHighlightSmall")
        r.points:SetPoint("RIGHT", r.date, "LEFT", -14, 0)
        r:SetScript("OnEnter", function(self) if self.badge then badgeTooltip(self, self.badge, self.entry) end end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        r:SetScript("OnClick", function(self) if self.badge then selectCat(self.badge.cat) end end)
        o.recent[i] = r
    end
    o.recentEmpty = text(o, "GameFontDisable")
    o.recentEmpty:SetPoint("TOPLEFT", 12, -266)

    o.progressHead = newHeading(o, "Progress")
    o.progressBars = {}
    f.overview = o
    return o
end

local function fillOverview(f, result, key)
    local o = f.overview
    local mine = not key or key == ns.meKey
    o.title:SetText(mine and "Your Badges" or (nameOf(key) .. "'s Badges"))
    local have, all = Badges.CategoryCount(result)
    o.sub:SetText(("Lifetime Horde kills in Ashenvale: |cffffffff%s|r"):format(commas(result.lifetime)))
    o.shield.points:SetText(result.score)
    o.total:Set(have, all, ("Badges earned: %d / %d"):format(have, all))

    local top = Badges.Prestigious(result, PRESTIGE_N)
    for i, t in ipairs(o.tiles) do
        local b = top[i]
        if b then
            local e = result.badges[b.id]
            t.badge, t.entry = b, e
            setBadgeIcon(t.icon, b, true)
            t.name:SetText(Badges.Title(b))
            t.times:SetText(b.kind == "weekly" and ("x" .. e.times) or "")
            t:Show()
        else
            t:Hide()
        end
    end
    o.prestigeEmpty:SetShown(#top == 0)
    o.prestigeEmpty:SetText(mine and "No badges yet. Defend Ashenvale to earn your first." or "No badges yet.")

    local recent = Badges.Recent(result, RECENT_N)
    local y = -258
    for i, r in ipairs(o.recent) do
        local it = recent[i]
        if it then
            local b, e = it.badge, result.badges[it.badge.id]
            r.badge, r.entry = b, e
            setBadgeIcon(r.icon, b, true)
            r.name:SetText(Badges.Title(b))
            r.points:SetText(b.points .. " points")
            r.date:SetText(Badges.WeekDate(it.week))
            r:Show()
            y = -258 - i * 33
        else
            r:Hide()
        end
    end
    o.recentEmpty:SetShown(#recent == 0)
    o.recentEmpty:SetText("Nothing earned yet.")
    if #recent == 0 then y = -290 end

    -- Progress: one bar per category with badges; "soon" ones say so.
    o.progressHead:ClearAllPoints()
    o.progressHead:SetPoint("TOPLEFT", 4, y - 10)
    y = y - 34
    local n = 0
    for _, top in ipairs(Badges.CATEGORIES) do
        for _, c in ipairs(top.children or {}) do
            n = n + 1
            local row = o.progressBars[n]
            if not row then
                row = CreateFrame("Button", nil, o)
                row:SetHeight(24)
                row.label = text(row, "GameFontNormal")
                row.label:SetPoint("LEFT", 8, 0)
                row.label:SetWidth(150)
                row.bar = newBar(row, 16)
                row.bar:SetPoint("LEFT", 170, 0)
                row.bar:SetPoint("RIGHT", -12, 0)
                row:SetScript("OnClick", function(self) if not self.soon then selectCat(self.id) end end)
                o.progressBars[n] = row
            end
            row.id, row.soon = c.id, c.soon
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 4, y)
            row:SetPoint("RIGHT", o, "RIGHT", -4, 0)
            row.label:SetText(top.name .. ": " .. c.name)
            if c.soon then
                row.label:SetTextColor(0.5, 0.5, 0.5)
                row.bar:Set(0, 1, "Coming soon")
            else
                row.label:SetTextColor(1, 0.82, 0)
                local h, a = Badges.CategoryCount(result, c.id)
                row.bar:Set(h, a)
            end
            row:Show()
            y = y - 28
        end
    end
    for i = n + 1, #o.progressBars do o.progressBars[i]:Hide() end
    o:SetHeight(-y + 8)
    return -y + 8
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
    if sb.Instructions then sb.Instructions:SetText("Search badges") end
    f.search = sb

    f.catHolder = CreateFrame("Frame", nil, f)
    f.catHolder:SetPoint("TOPLEFT", 4, -32)
    f.catHolder:SetPoint("BOTTOMLEFT", 4, 0)
    f.catHolder:SetWidth(f.catW)
    f.catButtons = {}

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
    buildOverview(f, f.scroll.child, W - left - 20)

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
    f.testBanner:SetShown(ns.Ledger and ns.Ledger.Testing() and true or false)
    refreshCats(f)
    local key = state.view
    local result = key and Badges.Of(key) or Badges.Mine()

    -- The viewing bar pushes the scroll area down.
    f.scroll:ClearAllPoints()
    local left = f.catW + 24
    if key then
        f.viewing:Show()
        local heard = Badges.HeardFrom(key)
        f.viewing.text:SetText(("Viewing: |cffffffff%s|r%s"):format(nameOf(key),
            heard and "" or "  |cff9d9d9d(asking them for the rest...)|r"))
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
        local list = Badges.InCategory(state.cat)
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

-- Open someone's badges (nil or me: mine) on the Stats tab.
function Badges.View(key)
    if key == ns.meKey then key = nil end
    loadSaved()
    state.view = key
    -- Someone else's: their Overview. Mine: where I left it.
    state.cat = key and "overview" or (saved and saved.cat) or "overview"
    state.search = ""
    if page and page.search then page.search:SetText("") end
    if key then Badges.Request(key) end
    if ns.ToggleWindow then
        if ns.GuildTabs and ns.GuildTabs.Available() and CommunitiesFrame and CommunitiesFrame:IsShown() then
            ns.GuildTabs.Select(1)
        else
            ns.ToggleWindow(1)
        end
    end
    BUI.Refresh()
end

-- (the tab icon: the Warsong Gulch Mark of Honor)
UI.AddPage(1, "Stats", build, refresh,
    { order = 2, icon = { "INV_Misc_Rune_07", "INV_Misc_Book_09" }, tooltip = "Badges", bgAtlas = "Legacy-Rewards-Tracker-background" })

ns.onLogin(function()
    ns.listen("BADGES", function(key) if state.view == key then BUI.Refresh() end end)
    ns.listen("LEDGER", function() BUI.Refresh() end)     -- (an officer's award)
end, "badges ui")

-- The Legacy-art pieces, for the Officers tab (OfficerUI.lua).
BUI.Kit = {
    font = font, text = text, bump = bump, atlas = atlas, commas = commas, nameOf = nameOf,
    newIcon = newIcon, setBadgeIcon = setBadgeIcon, newBar = newBar, newHeading = newHeading,
    newScroll = newScroll, newCatButton = newCatButton, styleCatButton = styleCatButton,
    badgeTooltip = badgeTooltip,
}

ns.slash.badges = { help = "open your badges (or: /mw badges Name)", fn = function(rest)
    local key = rest and rest ~= "" and ns.key(rest) or nil
    if key and not (ns.Roster and ns.Roster.Get(key)) then
        -- a first name only: find the guildie
        for k, m in pairs(ns.Roster.All()) do
            if k:match("^" .. key:gsub("%p", "%%%0") .. " ") or k == key then key = k; break end
        end
    end
    Badges.View(key)
end }

-- /mw icon Name [Name...]: shows icons in chat, to pick badge art.
ns.slash.icon = { help = "preview icons by name: /mw icon Ability_DemonHunter_ThrowGlaive", fn = function(rest)
    for name in (rest or ""):gmatch("%S+") do
        local path = "Interface\\Icons\\" .. name
        local id = GetFileIDFromPath and GetFileIDFromPath(path)
        ns.print(id and ("|T%s:28|t %s"):format(path, name) or (name .. " - not on this client"))
    end
end }
