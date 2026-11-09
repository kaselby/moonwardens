-- UI: minimap button, main window with bottom tabs, Stats and Settings pages.
-- Other modules add pages with ns.UI.AddPage(index, label, build, refresh).
local _, ns = ...
local UI = {}
ns.UI = UI

local WIDTH, HEIGHT = 560, 470
local win
local pages = {}   -- index -> { label, build, refresh, frame }

-- Try templates in order: Forever's 12.x code has the Mainline ones, but we
-- don't depend on any single one existing.
local function createWith(kind, name, parent, templates)
    for _, t in ipairs(templates) do
        local ok, f = pcall(CreateFrame, kind, name, parent, t)
        if ok and f then return f, t end
    end
    return CreateFrame(kind, name, parent), nil
end

function UI.Text(parent, size, color, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", size == "big" and "GameFontNormalLarge"
        or size == "small" and "GameFontHighlightSmall" or "GameFontHighlight")
    if color then fs:SetTextColor(color[1], color[2], color[3]) end
    if justify then fs:SetJustifyH(justify) end
    return fs
end
UI.GOLD = { 1, 0.82, 0 }
UI.GREY = { 0.62, 0.62, 0.62 }
UI.GREEN = { 0.12, 1, 0 }

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
local function selectPage(i)
    for j, p in pairs(pages) do
        if p.frame then p.frame:SetShown(j == i) end
    end
    win.current = i
    if PanelTemplates_SetTab then pcall(PanelTemplates_SetTab, win, i) end
    local p = pages[i]
    if p and p.refresh then ns.guard(p.refresh, "page " .. p.label)(p.frame) end
end

local function buildWindow()
    local tmpl
    win, tmpl = createWith("Frame", "MoonwardensFrame", UIParent, { "PortraitFrameTemplate", "BasicFrameTemplateWithInset" })
    win:SetSize(WIDTH, HEIGHT)
    win:SetPoint("CENTER", UIParent, "CENTER", -120, 40)
    win:SetFrameStrata("HIGH")
    win:SetMovable(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", win.StopMovingOrSizing)
    win:SetClampedToScreen(true)
    win:Hide()
    tinsert(UISpecialFrames, "MoonwardensFrame") -- Escape closes it

    local title = "Moonwardens"
    if win.SetTitle then pcall(win.SetTitle, win, title)
    elseif win.TitleText then win.TitleText:SetText(title)
    else
        local t = UI.Text(win, "big", UI.GOLD); t:SetPoint("TOP", 0, -6); t:SetText(title)
    end
    if win.SetPortraitToAsset then pcall(win.SetPortraitToAsset, win, "Interface\\Icons\\Spell_Nature_MoonGlow")
    elseif win.PortraitContainer and win.PortraitContainer.portrait then
        pcall(SetPortraitToTexture, win.PortraitContainer.portrait, "Interface\\Icons\\Spell_Nature_MoonGlow")
    end
    if not tmpl then
        -- No template at all: plain dark panel with a close button.
        local bg = win:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetColorTexture(0.05, 0.05, 0.05, 0.95)
        local close = CreateFrame("Button", nil, win, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", 2, 2)
    end

    local order = {}
    for i in pairs(pages) do order[#order + 1] = i end
    table.sort(order)
    win.Tabs = {}
    for n, i in ipairs(order) do
        local p = pages[i]
        p.frame = CreateFrame("Frame", nil, win)
        p.frame:SetPoint("TOPLEFT", 16, -64)
        p.frame:SetPoint("BOTTOMRIGHT", -16, 14)
        p.frame:Hide()
        ns.guard(p.build, "build " .. p.label)(p.frame)

        local tab = createWith("Button", "MoonwardensFrameTab" .. n, win,
            { "PanelTabButtonTemplate", "CharacterFrameTabButtonTemplate", "UIPanelButtonTemplate" })
        tab:SetID(n)
        tab:SetText(p.label)
        if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, tab, 0) else tab:SetSize(100, 24) end
        if n == 1 then tab:SetPoint("TOPLEFT", win, "BOTTOMLEFT", 12, 2)
        else tab:SetPoint("LEFT", win.Tabs[n - 1], "RIGHT", -14, 0) end
        tab:SetScript("OnClick", function() selectPage(i); PlaySound(SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB or 841) end)
        win.Tabs[n] = tab
        p.tabIndex = n
    end
    if PanelTemplates_SetNumTabs then pcall(PanelTemplates_SetNumTabs, win, #order) end
    win:SetScript("OnShow", function() selectPage(win.current or order[1]) end)
end

function UI.AddPage(index, label, build, refresh)
    pages[index] = { label = label, build = build, refresh = refresh }
end

function UI.Refresh()
    if win and win:IsShown() and win.current then selectPage(win.current) end
end

function ns.ToggleWindow(index)
    if not win then buildWindow() end
    if index then win.current = index end
    if win:IsShown() and not index then win:Hide() else win:Show(); if index then selectPage(index) end end
end

---------------------------------------------------------------------------
-- Bars (Stats page): a label, a coloured bar, a number.
---------------------------------------------------------------------------
local function makeBar(parent)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(250, 16)
    row.label = UI.Text(row, nil, nil, "LEFT"); row.label:SetPoint("LEFT"); row.label:SetWidth(84)
    row.bar = CreateFrame("StatusBar", nil, row)
    row.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    row.bar:SetPoint("LEFT", 88, 0); row.bar:SetSize(100, 11)
    local bg = row.bar:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetColorTexture(0, 0, 0, 0.6)
    row.value = UI.Text(row, nil, nil, "RIGHT"); row.value:SetPoint("RIGHT"); row.value:SetWidth(60)
    return row
end

-- "83%"; "<1%" for a small non-zero share.
function UI.Pct(n, total)
    if not total or total <= 0 then return "" end
    local p = math.floor(100 * n / total + 0.5)
    if p == 0 and n > 0 then return "<1%" end
    return p .. "%"
end

local function fillBars(rows, pool, parent, anchor, entries, colorOf)
    local total = 0
    for _, e in ipairs(entries) do total = total + e.n end
    table.sort(entries, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.label < b.label end)
    local maxN = entries[1] and entries[1].n or 1
    for i = 1, math.max(#entries, #pool) do
        local e = entries[i]
        local row = pool[i]
        if e then
            if not row then row = makeBar(parent); pool[i] = row end
            row:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -6 - (i - 1) * 18)
            row.label:SetText(e.label)
            local r, g, b = colorOf(e)
            row.label:SetTextColor(r, g, b)
            row.bar:SetStatusBarColor(r, g, b)
            row.bar:SetMinMaxValues(0, maxN)
            row.bar:SetValue(e.n)
            row.value:SetText(e.n .. "  |cff9d9d9d" .. UI.Pct(e.n, total) .. "|r")
            row:Show()
        elseif row then
            row:Hide()
        end
    end
end

local RACE_COLOR = { NightElf = { 0.79, 0.71, 0.94 } }
local LEVEL_BANDS = { "1-9", "10-19", "20-29", "30-39", "40-49", "50-59", "60" }

local function buildStats(f)
    f.head = UI.Text(f, nil, nil, "LEFT"); f.head:SetPoint("TOPLEFT", 0, 0)
    f.toggle = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    f.toggle:SetSize(22, 22); f.toggle:SetPoint("TOPRIGHT", -90, 4)
    f.toggleLabel = UI.Text(f, "small", UI.GOLD, "LEFT"); f.toggleLabel:SetPoint("LEFT", f.toggle, "RIGHT", 2, 0)
    f.toggleLabel:SetText("Online only")
    f.toggle:SetScript("OnClick", function() UI.Refresh() end)

    local function heading(text, x, y)
        local h = UI.Text(f, nil, UI.GOLD, "LEFT"); h:SetPoint("TOPLEFT", x, y); h:SetText(text)
        local line = f:CreateTexture(nil, "ARTWORK"); line:SetColorTexture(0.35, 0.28, 0.08, 1)
        line:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -2); line:SetSize(250, 1)
        return h
    end
    f.raceHead = heading("Race", 0, -30)
    f.classHead = heading("Class", 270, -30)
    f.levelHead = heading("Level", 0, -150)
    f.racePool, f.classPool = {}, {}

    f.levelBars = {}
    for i = 1, #LEVEL_BANDS do
        local col = CreateFrame("Frame", nil, f)
        col:SetSize(30, 100)
        col:SetPoint("TOPLEFT", f.levelHead, "BOTTOMLEFT", (i - 1) * 36, -8)
        col.bar = col:CreateTexture(nil, "ARTWORK")
        -- Plain colour, not the status-bar texture: that one is a horizontal
        -- strip and looks smeared and low-res when stretched upward.
        col.bar:SetColorTexture(1, 1, 1, 1)
        if not (CreateColor and pcall(col.bar.SetGradient, col.bar, "VERTICAL",
                CreateColor(0.75, 0.5, 0, 1), CreateColor(1, 0.85, 0.2, 1))) then
            col.bar:SetColorTexture(1, 0.82, 0, 1)
        end
        col.bar:SetPoint("BOTTOM", 0, 14); col.bar:SetWidth(20)
        col.n = UI.Text(col, "small", nil, "CENTER"); col.n:SetPoint("BOTTOM", col.bar, "TOP", 0, 2)
        col.pct = UI.Text(col, "small", UI.GREY, "CENTER"); col.pct:SetPoint("BOTTOM", col.n, "TOP", 0, 1)
        col.label = UI.Text(col, "small", UI.GREY, "CENTER"); col.label:SetPoint("BOTTOM", 0, 0); col.label:SetText(LEVEL_BANDS[i])
        f.levelBars[i] = col
    end
    f.foot = UI.Text(f, "small", UI.GREY, "LEFT"); f.foot:SetPoint("BOTTOMLEFT", 0, 0)
end

local function refreshStats(f)
    local onlineOnly = f.toggle:GetChecked()
    local s = ns.Roster.Stats(onlineOnly)
    if not ns.Roster.Loaded() then
        f.head:SetText("Waiting for the guild roster...")
    else
        f.head:SetText(("|cffffffff%d|r members  |cff1eff00%d online|r  %d at level 60"):format(
            onlineOnly and ns.Roster.Count() or s.total, s.online, s.max))
    end
    local races, classes = {}, {}
    for k, e in pairs(s.race) do races[#races + 1] = { n = e.n, label = e.label, key = k } end
    for _, e in pairs(s.class) do classes[#classes + 1] = { n = e.n, label = e.label, file = e.file } end
    fillBars(nil, f.racePool, f, f.raceHead, races, function(e)
        local c = RACE_COLOR[e.key] or { 0.85, 0.75, 0.6 }
        return c[1], c[2], c[3]
    end)
    fillBars(nil, f.classPool, f, f.classHead, classes, function(e) return ns.classColor(e.file) end)
    local maxBand = 1
    for i = 1, #LEVEL_BANDS do maxBand = math.max(maxBand, s.level[i] or 0) end
    for i, col in ipairs(f.levelBars) do
        local n = s.level[i] or 0
        col.bar:SetHeight(math.max(1, 60 * n / maxBand))
        col.n:SetText(n)
        col.pct:SetText(UI.Pct(n, s.total))
    end
    local foot = "Race is read for everyone on the roster, offline members included."
    if s.unknownRace > 0 then foot = foot .. (" %d not known yet."):format(s.unknownRace) end
    f.foot:SetText(foot)
end

---------------------------------------------------------------------------
-- Settings page
---------------------------------------------------------------------------
UI.SETTINGS = {
    { "Alerts" },
    { "alertButton", "Show the alert button", function() if ns.Alert and ns.Alert.UpdateButton then ns.Alert.UpdateButton() end end },
    { "alertButtonLocked", "Lock the alert button in place" },
    { "autoInvite", "Invite guildies who respond to my alert" },
    { "autoRaid", "Convert to a raid when the party is full" },
    { "autoAccept", "Accept the invite when I respond to an alert" },
    { "sound", "Play a sound for alerts" },
    { "Map" },
    { "worldDots", "Show guildies on the world map" },
    { "otherLayers", "Show guildies on other layers (faded)" },
    { "minimapDots", "Show guildies on the minimap" },
    { "Research" },
    { "dataCollection", "Help collect layer data (recommended)" },
}

local function buildSettings(f)
    local y = 0
    f.checks = {}
    for _, s in ipairs(UI.SETTINGS) do
        if not s[2] then
            local h = UI.Text(f, nil, UI.GOLD, "LEFT"); h:SetPoint("TOPLEFT", 0, y - 4); h:SetText(s[1])
            y = y - 22
        else
            local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
            cb:SetSize(24, 24); cb:SetPoint("TOPLEFT", 8, y)
            local label = UI.Text(f, nil, nil, "LEFT"); label:SetPoint("LEFT", cb, "RIGHT", 4, 0); label:SetText(s[2])
            cb:SetScript("OnClick", function(self)
                ns.db[s[1]] = self:GetChecked() and true or false
                if s[3] then s[3]() end
                ns.fire("SETTINGS", s[1])
            end)
            f.checks[s[1]] = cb
            y = y - 24
        end
    end
    local hint = UI.Text(f, "small", UI.GREY, "LEFT"); hint:SetPoint("BOTTOMLEFT", 0, 0)
    hint:SetText("Keybinds for sending and answering alerts: Esc > Options > Keybindings > AddOns.")
end

local function refreshSettings(f)
    for k, cb in pairs(f.checks) do cb:SetChecked(ns.db[k] and true or false) end
end

UI.AddPage(1, "Stats", buildStats, refreshStats)
UI.AddPage(9, "Settings", buildSettings, refreshSettings)

---------------------------------------------------------------------------
-- Minimap button
---------------------------------------------------------------------------
local mmb
local function placeMinimapButton()
    local a = math.rad(ns.db.minimapAngle or 200)
    local r = (Minimap:GetWidth() / 2) + 10
    mmb:ClearAllPoints()
    mmb:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

function UI.MinimapTooltip(tt)
    tt:AddLine("Moonwardens", 1, 0.82, 0)
    local s = ns.Roster.Stats(false)
    local here = ns.Position and ns.Position.CountInMyZone and ns.Position.CountInMyZone()
    tt:AddLine(("%d guildies online%s"):format(s.online, here and (" - %d in your zone"):format(here) or ""), 1, 1, 1)
    if ns.Layer and ns.Layer.TooltipLine then
        local text, r, g, b = ns.Layer.TooltipLine()
        if text then tt:AddLine(text, r, g, b) end
    end
    tt:AddLine("Left-click: open window", 0.62, 0.62, 0.62)
    tt:AddLine("Right-click: settings", 0.62, 0.62, 0.62)
    tt:AddLine("Drag: move this button", 0.62, 0.62, 0.62)
end

local function buildMinimapButton()
    mmb = CreateFrame("Button", "MoonwardensMinimapButton", Minimap)
    mmb:SetSize(31, 31)
    mmb:SetFrameStrata("MEDIUM")
    mmb:SetFrameLevel(8)
    mmb:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    mmb:RegisterForDrag("LeftButton")
    mmb:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local icon = mmb:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture("Interface\\Icons\\Spell_Nature_MoonGlow")
    icon:SetSize(20, 20); icon:SetPoint("CENTER", 0, 1)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local border = mmb:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53); border:SetPoint("TOPLEFT")
    mmb:SetScript("OnClick", function(_, button) ns.ToggleWindow(button == "RightButton" and 9 or nil) end)
    mmb:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        UI.MinimapTooltip(GameTooltip)
        GameTooltip:Show()
    end)
    mmb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    mmb:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            ns.db.minimapAngle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
            placeMinimapButton()
        end)
    end)
    mmb:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    placeMinimapButton()
end

ns.onLogin(function()
    buildMinimapButton()
    ns.listen("ROSTER", function() UI.Refresh() end)
end, "ui")

ns.slash.show = { help = "open the window", fn = function() ns.ToggleWindow(1) end }
