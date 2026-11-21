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

local CARD_H = 120
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
    saved = { cat = sv.cat or "overview", collapsed = sv.collapsed or {}, scroll = sv.scroll or {}, open = sv.open or {}, shut = sv.shut or {} }
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

-- The badge tooltip, laid out as totalRP3's character tooltip: the badge's
-- icon where TRP puts the profile icon (32 px, 4 px to the title), its
-- tier's coin on the icon's corner, the title where TRP puts the name (its
-- size), and the points shield at the top right, as on the cards. Then
-- what it takes, and how it stands.
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

local function badgeTooltip(owner, b, e)
    local deco = tipDecor()
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    local c = Badges.TIER_COLOR[b.tier] or { 1, 0.82, 0 }
    -- The points: a badge's own; a parent's, its children's.
    local pts = b.points or 0
    if b.kind == "parent" then
        pts = 0
        for _, cid in ipairs(b.children or {}) do local cb = Badges.Get(cid); pts = pts + (cb and cb.points or 0) end
    end
    local sw, sh = math.floor(35 * TIP_SHIELD + 0.5), math.floor(51 * TIP_SHIELD + 0.5)
    GameTooltip:AddDoubleLine(Badges.Title(b), ("|A:Legacy-Tree-Frame-Points-Icon:%d:%d|a"):format(sh, sw), c[1], c[2], c[3], 1, 1, 1)
    setIcon(tipIconTex, b.icon)
    local file = tipIconTex:GetTexture()
    local placed = file and pcall(GameTooltip.AddTexture, GameTooltip, file, {
        width = TIP_ICON, height = TIP_ICON,
        anchor = Enum and Enum.TooltipTextureAnchor and Enum.TooltipTextureAnchor.LeftCenter,
        margin = { left = 0, right = 4, top = 0, bottom = 0 },
    })
    if file and not placed then pcall(GameTooltip.AddTexture, GameTooltip, file) end
    if ns.UI and ns.UI.TooltipTitleSize then ns.UI.TooltipTitleSize(trpNameSize()) end
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
    if #lines > 0 then
        GameTooltip:AddLine(" ")
        for _, l in ipairs(lines) do GameTooltip:AddLine(l[1], l[2], l[3], l[4], true) end
    end
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
    local right = _G.GameTooltipTextRight1
    deco.points:ClearAllPoints()
    if right then
        font(deco.points, pts >= 100 and "GameFontHighlightSmall" or "GameFontHighlight")
        deco.points:SetText(pts)
        deco.points:SetWidth(sw * 2)
        deco.points:SetPoint("CENTER", right, "CENTER", 0, -4 * TIP_SHIELD)
        deco.points:Show()
    else
        deco.points:Hide()
    end
    deco:Show()
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
local function newShield(parent, scale, fontName)
    scale = scale or 1
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(35 * scale, 51 * scale)
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetAllPoints()
    if not atlas(f.icon, "Legacy-Tree-Frame-Points-Icon") then f.icon:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Shields") end
    f.points = f:CreateFontString(nil, "OVERLAY")
    font(f.points, fontName or (scale > 1.2 and "GameFontNormalHuge" or "GameFontNormalMed3"), "GameFontNormal")
    f.points:SetTextColor(1, 1, 1)
    -- (a set width, centred: one digit sits as centred as two)
    f.points:SetWidth(70 * scale)          -- (room for a score of thousands, still centred)
    f.points:SetJustifyH("CENTER")
    f.points:SetWordWrap(false)
    f.points:SetPoint("CENTER", 0, -4 * scale)
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
    c.progress:SetPoint("TOPLEFT", 84, -(CARD_H - 28))
    c.progress:SetPoint("TOPRIGHT", -70, -(CARD_H - 28))
    -- (granted and rank badges: who gives it, in place of the bar)
    c.info = text(c, "GameFontNormalSmall")
    c.info:SetPoint("TOPLEFT", 84, -(CARD_H - 30))
    c.info:SetPoint("RIGHT", c, "RIGHT", -70, 0)
    -- A parent's children, listed under it (as Explore Azeroth's are); the
    -- parent folds them away with a click, Legacy's +/- showing which.
    c.plus = c:CreateTexture(nil, "OVERLAY")
    c.plus:SetSize(20, 20)
    c.plus:SetPoint("TOPLEFT", 76, -(CARD_H - 32))
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
            saved.shut[b.id] = not saved.shut[b.id] or nil
            BUI.Refresh()
        end
    end)
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
    c:SetScript("OnEnter", function(self)
        if not self.badge then return end
        badgeTooltip(self, self.badge, self.entry)
        -- A track: every tier, its goal and points, and what's earned of it.
        local st, res = self.track, self.result
        if st and res then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Tiers", 1, 0.82, 0)
            for _, b in ipairs(st.track.tiers) do
                local e = res.badges[b.id]
                local col = Badges.TIER_COLOR[b.tier]
                local name = b.tier:sub(1, 1):upper() .. b.tier:sub(2)
                local goal = b.kind == "placement" and ({ "1st", "2nd", "3rd" })[b.place] or commas(b.goal)
                local got = e.times > 0 and ((b.kind == "lifetime" or b.kind == "manual" or b.kind == "selflifetime")
                    and "earned" or ("x" .. e.times)) or "-"
                GameTooltip:AddDoubleLine(("%s  %s  (%d pts)"):format(name, goal, b.points), got,
                    col[1], col[2], col[3], e.times > 0 and 0.12 or 0.5, e.times > 0 and 1 or 0.5, e.times > 0 and 0 or 0.5)
            end
            GameTooltip:Show()
        end
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
    r.points = r.shield.points
    r.name = text(r, "SystemFont_Small2", "ARTWORK")
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
    r.name:SetPoint("RIGHT", r.shield, "LEFT", -4, 0)
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
    -- A month's Bounty Hunter card isn't greyed out while its month is
    -- running: it's there to be hunted. Once the month is over, it's grey
    -- only if none of its bounties were completed. (Its check and date still
    -- wait for all of them.)
    local lit = earned
    if b.kind == "parent" then lit = b.active or (e.value or 0) > 0 end
    if opts and opts.lit ~= nil then lit = opts.lit end      -- (a track: lit once any tier is earned)
    local kids = b.kind == "parent" and b.children or {}
    local open = #kids > 0 and not (saved and saved.shut[b.id])
    local rows = math.ceil(#kids / 2)
    local h = CARD_H + (open and (26 + rows * (CRIT_H + CRIT_GAP)) or 0)
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
    local off = Badges.CategorySoon(b.cat)          -- (a category switched off: its buttons greyed)
    local canReport = b.requestable and not key
    c.report:SetShown(canReport and true or false)
    c.report:SetEnabled(not off)
    if canReport then c.report:SetText("Report a " .. (b.unit or "Patrol"):gsub("^%l", string.upper)) end
    c.progress:SetPoint("TOPRIGHT", canReport and -140 or -70, -(CARD_H - 28))
    c.progress:SetPoint("TOPLEFT", #kids > 0 and 104 or 84, -(CARD_H - 28))   -- (room for a parent's +/-)

    -- A parent's children: two columns of rows, each a badge of its own
    -- (icon, level and name, points, a check once earned; its own tooltip).
    c.listHead:SetShown(open)
    c.plus:SetShown(#kids > 0)
    if #kids > 0 and not atlas(c.plus, open and "128-redbutton-minus" or "128-redbutton-plus") then
        c.plus:SetTexture(open and "Interface\\Buttons\\UI-MinusButton-Up" or "Interface\\Buttons\\UI-PlusButton-Up")
    end
    if open then
        local first = kids[1] and Badges.Get(kids[1])
        -- ("N points each" only when every child is worth the same)
        local same = first ~= nil
        for _, cid in ipairs(kids) do
            local k = Badges.Get(cid)
            if not (k and first and k.points == first.points) then same = false end
        end
        c.listHead:SetText(same and ("%s - %d points each"):format(b.listLabel or "Includes", first.points)
            or (b.listLabel or "Includes"))
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
            r:SetPoint("TOPLEFT", c, "TOPLEFT", 20 + col * (cw + 10), -(CARD_H + 22 + row * (CRIT_H + CRIT_GAP)))
            setBadgeIcon(r.icon, child, r.done)
            r.name:SetText(child.label or child.name)
            r.name:SetTextColor(r.done and 1 or 0.75, r.done and 1 or 0.75, r.done and 1 or 0.75)
            r.points:SetText(child.points)
            r.shield.icon:SetDesaturated(not r.done)
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
        f.cardY[b.id], f.cardOf[b.id] = y, c
        c:Show()
        y = y + h + CARD_GAP
    end
    for i = #list + 1, #f.cards do f.cards[i]:Hide() end
    return y
end

---------------------------------------------------------------------------
-- Overview (right): score, most prestigious, recent
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

    o.prestigeHead = newHeading(o, "Most Prestigious")
    o.prestigeHead:SetPoint("TOPLEFT", 4, -84)
    o.tiles = {}
    local tileW = math.floor((w - 8) / PRESTIGE_N)
    for i = 1, PRESTIGE_N do
        local t = CreateFrame("Button", nil, o)
        t:SetSize(tileW, 100)
        t:SetPoint("TOPLEFT", 4 + (i - 1) * tileW, -106)
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
        t:SetScript("OnClick", function(self) if self.badge then BUI.Focus(self.badge.parent or self.badge.id) end end)
        o.tiles[i] = t
    end
    o.prestigeEmpty = text(o, "GameFontDisable")
    o.prestigeEmpty:SetPoint("TOPLEFT", 12, -124)

    o.recentHead = newHeading(o, "Recent Badges")
    o.recentHead:SetPoint("TOPLEFT", 4, -220)
    o.recent = {}
    for i = 1, RECENT_N do
        local r = CreateFrame("Button", nil, o)
        r:SetHeight(30)
        r:SetPoint("TOPLEFT", 4, -242 - (i - 1) * 33)
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
        r:SetScript("OnClick", function(self) if self.badge then BUI.Focus(self.badge.parent or self.badge.id) end end)
        o.recent[i] = r
    end
    o.recentEmpty = text(o, "GameFontDisable")
    o.recentEmpty:SetPoint("TOPLEFT", 12, -250)
    f.overview = o
    return o
end

local function fillOverview(f, result, key)
    local o = f.overview
    local mine = not key or key == ns.meKey
    o.title:SetText(mine and "Your Badges" or (nameOf(key) .. "'s Badges"))
    o.sub:SetText(("Lifetime Horde kills in Ashenvale: |cffffffff%s|r"):format(commas(result.lifetime)))
    o.shield.points:SetText(result.score)

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
    local y = -242
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
            y = -242 - i * 33
        else
            r:Hide()
        end
    end
    o.recentEmpty:SetShown(#recent == 0)
    o.recentEmpty:SetText("Nothing earned yet.")
    if #recent == 0 then y = -274 end
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
    -- (a category switched off since it was last open: back to the Overview)
    if Badges.CategorySoon(state.cat) then state.cat = "overview"; if saved then saved.cat = "overview" end end
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
        ns.ToggleWindow(1)      -- (switches tab if the guild window is open; else it opens there on J)
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
    font = font, text = text, bump = bump, atlas = atlas, commas = commas, nameOf = nameOf, setIcon = setIcon,   -- (setIcon, badgeTooltip: the roster's Top Badges too)
    newIcon = newIcon, setBadgeIcon = setBadgeIcon, newBar = newBar, newHeading = newHeading,
    newScroll = newScroll, newCatButton = newCatButton, styleCatButton = styleCatButton,
    badgeTooltip = badgeTooltip,
}
