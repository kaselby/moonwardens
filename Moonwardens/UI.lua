-- UI: minimap button, main window with bottom tabs, the Settings page.
-- (Stats is BadgesUI.lua; the guild stats are on the Info tab, GuildInfoStats.lua.)
-- Other modules add pages with ns.UI.AddPage(index, label, build, refresh, guild).
-- Pages given `guild` ({ icon = {names...}, tooltip }) live as side tabs on
-- the game's guild window instead (GuildTabs.lua); the window keeps the rest,
-- and takes them back if that window can't be used.
local _, ns = ...
local UI = {}
ns.UI = UI

local WIDTH, HEIGHT = 560, 470
local win
local pages = {}   -- index -> { label, build, refresh, guild, frame }
UI.pages = pages

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
    -- (tabs are numbered by position, not by page index)
    if PanelTemplates_SetTab and pages[i] and pages[i].tabIndex then pcall(PanelTemplates_SetTab, win, pages[i].tabIndex) end
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
    local guildHost = ns.GuildTabs and ns.GuildTabs.Hosting()
    for i, p in pairs(pages) do
        if not (p.guild and guildHost) then order[#order + 1] = i end
    end
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

function UI.AddPage(index, label, build, refresh, guild)
    pages[index] = { label = label, build = build, refresh = refresh, guild = guild }
end

-- Rows that fit a list page: `top` pixels above the first row, a footer
-- below the last. Height not known yet: 14, what the Moonwardens window fits.
function UI.RowsFor(f, max, rowH, top)
    local h = f.GetHeight and f:GetHeight() or 0
    if not h or h < 100 then return math.min(max, 14) end
    return math.max(5, math.min(max, math.floor((h - top - 30) / rowH)))
end

function UI.Refresh()
    if win and win:IsShown() and win.current then selectPage(win.current) end
    if ns.GuildTabs then ns.GuildTabs.Refresh() end
end

-- Open a page (or toggle: no index). Guild pages open on the guild window;
-- with no index that means Stats, the first of them.
function ns.ToggleWindow(index)
    local p = index and pages[index]
    if ns.GuildTabs and ns.GuildTabs.Hosting() and (not index or (p and p.guild)) then
        if ns.GuildTabs.Toggle(index) then return end
    end
    if not win then buildWindow() end
    if index and p and p.tabIndex then win.current = index end
    if win:IsShown() and not index then win:Hide() else win:Show(); if index and p and p.tabIndex then selectPage(index) end end
end

---------------------------------------------------------------------------
-- "83%"; "<1%" for a small non-zero share.
function UI.Pct(n, total)
    if not total or total <= 0 then return "" end
    local p = math.floor(100 * n / total + 0.5)
    if p == 0 and n > 0 then return "<1%" end
    return p .. "%"
end

---------------------------------------------------------------------------
-- A GameTooltip line at another size: the tooltip text font at `size`,
-- until the tooltip is cleared or hides (then the game's again). Line 1,
-- the title, by TooltipTitleSize.
---------------------------------------------------------------------------
local lineFonts, lineSaved, lineHooked = {}, {}, false
function UI.TooltipLineSize(n, size)
    local line = n and _G["GameTooltipTextLeft" .. n]
    if not (line and GameTooltipText and size) then return end
    local f = lineFonts[size]
    if not f then
        local path, _, flags = GameTooltipText:GetFont()
        f = CreateFont("MoonwardensTooltipTitle" .. size)
        f:SetFont(path, size, flags or "")
        lineFonts[size] = f
    end
    lineSaved[line] = lineSaved[line] or line:GetFontObject() or (n == 1 and GameTooltipHeaderText or GameTooltipText)
    line:SetFontObject(f)
    if not lineHooked then
        lineHooked = true
        local function restore()
            for l, obj in pairs(lineSaved) do l:SetFontObject(obj); lineSaved[l] = nil end
        end
        GameTooltip:HookScript("OnHide", restore)
        pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipCleared", restore)
    end
end
function UI.TooltipTitleSize(size) UI.TooltipLineSize(1, size) end

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
    -- (layers off for now, ns.LAYERS: their two settings hidden)
    -- { "otherLayers", "Show guildies on other layers (faded)" },
    { "minimapDots", "Show guildies on the minimap" },
    -- { "layerPlates", "Show nameplates for a moment to read my layer" },
    -- totalRP3 profiles (RP.lua): maps, the guild roster and the
    -- Leaderboard tab. Profiles guildies phoned in work without totalRP3.
    { "Roleplay" },
    { "rpColors", "Show guildies custom Roleplay colors" },
    { "rpNames", "Show guildies custom Roleplay names/class names" },
    -- Research section ("Help collect layer data") comes back with the data log (0.6).
}

local function buildSettings(f)
    -- Everything else lives on the guild window now: say so, up top.
    local moved = UI.Text(f, nil, nil, "CENTER")
    moved:SetPoint("TOPLEFT", 0, 0); moved:SetPoint("TOPRIGHT", 0, 0)
    moved:SetText("Moonwardens has moved to your Guild & Communities tab (|cffffd100J|r by default).")
    local y = -26
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

UI.AddPage(9, "Settings", buildSettings, refreshSettings)

-- Once (per account): where Moonwardens went, in our dialog, a few seconds
-- after loading in. Only its button closes it (not Escape); after that it
-- never shows again. Closed any other way, it shows again next time.
ns.onLogin(function()
    if ns.db.movedNoticeSeen then return end
    ns.after(4, function()
        if ns.db.movedNoticeSeen or not ns.Dialog then return end
        ns.Dialog.Show({
            title = "Moonwardens",
            text = "Moonwardens has moved to your Guild & Communities tab.\n|cffffd100J|r by default",
            accept = OKAY or "Okay", noCancel = true, noEscape = true,
            onAccept = function() ns.db.movedNoticeSeen = true end,
        })
    end, "moved notice")
end, "moved notice")

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
    local update = ns.Comm.Version and ns.Comm.Version.TooltipLine()
    if update then tt:AddLine(update, 0.12, 1, 0) end
    tt:AddLine("Click: settings", 0.62, 0.62, 0.62)
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
    -- Settings only: the other pages are tabs on the guild window (J).
    mmb:SetScript("OnClick", function()
        if MoonwardensFrame and MoonwardensFrame:IsShown() then MoonwardensFrame:Hide() else ns.ToggleWindow(9) end
    end)
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
