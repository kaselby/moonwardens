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
    -- Everything else lives on the guild window now: say so, up top, in two
    -- centred lines - large: up to twice the text's size, as large as lets
    -- the longer line fit the page's width.
    local moved = UI.Text(f, nil, nil, "CENTER")
    local file, size, flags = moved:GetFont()
    size = size or 12
    local big = size * 2
    local avail = f:GetWidth()
    if not avail or avail < 100 then avail = WIDTH - 32 end
    if file then
        local probe = UI.Text(f, nil, nil, "LEFT")
        probe:SetFont(file, big, flags)
        probe:SetWordWrap(false)
        probe:SetText("to your Guild & Communities tab (J by default).")
        local w = ns.try(probe.GetStringWidth, probe) or 0
        probe:Hide()
        if w > avail - 8 then big = math.max(size, math.floor(big * (avail - 8) / w)) end
        moved:SetFont(file, big, flags)
    end
    moved:SetPoint("TOPLEFT", 0, 0); moved:SetPoint("TOPRIGHT", 0, 0)
    moved:SetText("Moonwardens has moved\nto your Guild & Communities tab (|cffffd100J|r by default).")
    local y = -(big * 2 + 14)
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

---------------------------------------------------------------------------
-- The notice: where Moonwardens went. Once (per account), a few seconds
-- after loading in, in a window of the addon's own look: the Badge
-- Inspector's frame (the game's portrait window, the moon for portrait),
-- the Badges tab's ground (dark, the game's rock, the Legacy art), a gold
-- heading over a gold rule, what moved, and the key that opens it (the
-- player's own binding, read from the game; J by default). Only its button
-- closes it - no close box, not Escape; after that it never shows again
-- (till a fresh start, Badges.lua). Closed any other way (a reload, logging
-- out), it shows again next time. (Seen or not: asked only as it's due,
-- after the fresh start has had its say.) /mw test notice: shown again.
---------------------------------------------------------------------------
local NOTICE_ICON = "Interface\\Icons\\Spell_Nature_MoonGlow"
local NOTICE_W, NOTICE_H = 440, 262
local notice

local function noticeAtlas(tex, name)
    if not (tex.SetAtlas and pcall(tex.SetAtlas, tex, name, false)) then return false end
    return true
end

-- The key that opens the guild window, as the game names it ("J",
-- "Shift-G"), and whether it's the game's own: nil if none is bound.
local function guildKey()
    for _, action in ipairs({ "TOGGLEGUILDTAB", "TOGGLECOMMUNITIESFRAME" }) do
        local key = ns.try(GetBindingKey, action)
        if type(key) == "string" and key ~= "" then
            local shown = ns.try(GetBindingText, key, "KEY_")
            return (type(shown) == "string" and shown ~= "") and shown or key, key == "J"
        end
    end
end

local function buildNotice()
    local f
    for _, t in ipairs({ "PortraitFrameTemplate", "BasicFrameTemplateWithInset" }) do
        local ok, fr = pcall(CreateFrame, "Frame", "MoonwardensNotice", UIParent, t)
        if ok and fr then f = fr; break end
    end
    if not f then
        f = CreateFrame("Frame", "MoonwardensNotice", UIParent, "BackdropTemplate")
        f:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 } })
    end
    f:SetSize(NOTICE_W, NOTICE_H)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetPoint("CENTER", 0, 80)
    if f.SetTitle then pcall(f.SetTitle, f, "Moonwardens")
    else
        local fs = f.TitleText or (f.TitleContainer and f.TitleContainer.TitleText)
        if fs then fs:SetText("Moonwardens") end
    end
    if not (f.SetPortraitToAsset and pcall(f.SetPortraitToAsset, f, NOTICE_ICON)) then
        local p = f.portrait or (f.PortraitContainer and f.PortraitContainer.portrait)
        if p then p:SetTexture(NOTICE_ICON) end
    end
    -- (only its button closes it)
    for _, k in ipairs({ "CloseButton", "ClosePanelButton" }) do
        local close = rawget(f, k)
        if type(close) == "table" and close.Hide then close:Hide() end
    end

    -- The ground: the Badges tab's (dark, the game's rock, the Legacy art).
    local inset = CreateFrame("Frame", nil, f)
    inset:SetPoint("TOPLEFT", 10, -62)
    inset:SetPoint("BOTTOMRIGHT", -10, 46)
    local under = inset:CreateTexture(nil, "BACKGROUND", nil, -4); under:SetAllPoints(); under:SetColorTexture(0.03, 0.03, 0.04, 1)
    local rock = inset:CreateTexture(nil, "BACKGROUND", nil, -3); rock:SetAllPoints()
    rock:SetTexture("Interface\\FrameGeneral\\UI-Background-Rock", "REPEAT", "REPEAT")
    rock:SetHorizTile(true); rock:SetVertTile(true)
    local art = inset:CreateTexture(nil, "BACKGROUND", nil, -2); art:SetAllPoints()
    if not noticeAtlas(art, "Legacy-Rewards-Tracker-background") then art:Hide() end

    -- A gold heading over a gold rule, as the Badges pages' (larger: it's the whole message).
    local head = inset:CreateFontString(nil, "OVERLAY", _G.Game15Font_Shadow and "Game15Font_Shadow" or "GameFontNormalLarge")
    local hf, hs, hfl = head:GetFont()
    if hf and hs then head:SetFont(hf, hs + 5, hfl) end
    head:SetTextColor(UI.GOLD[1], UI.GOLD[2], UI.GOLD[3])
    head:SetPoint("TOP", 0, -18)
    head:SetText("Moonwardens has moved")
    local rule = inset:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(0.55, 0.45, 0.2, 0.6)
    rule:SetHeight(1)
    rule:SetPoint("TOP", head, "BOTTOM", 0, -8)
    rule:SetWidth(NOTICE_W - 120)

    local body = UI.Text(inset, nil, nil, "CENTER")
    body:SetPoint("TOP", rule, "BOTTOM", 0, -12)
    body:SetWidth(NOTICE_W - 80)
    body:SetSpacing(3)
    body:SetText("The Leaderboard and your Badges now live in the\n|cffffffffGuild & Communities|r window, as tabs along its side.")

    -- "Press [J] to open it": the key as a key cap.
    local row = CreateFrame("Frame", nil, inset)
    row:SetSize(NOTICE_W - 60, 28)
    row:SetPoint("TOP", body, "BOTTOM", 0, -16)
    local press = UI.Text(row, nil, nil, "RIGHT")
    press:SetText("Press")
    local cap = CreateFrame("Frame", nil, row, "BackdropTemplate")
    cap:SetHeight(26)
    if cap.SetBackdrop then
        cap:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = false, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        cap:SetBackdropColor(0.08, 0.07, 0.05, 0.95)
        cap:SetBackdropBorderColor(0.8, 0.66, 0.3, 1)
    end
    cap.key = cap:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    cap.key:SetPoint("CENTER", 0, 0)
    local open = UI.Text(row, nil, nil, "LEFT")
    open:SetText("to open it")
    f.hint = UI.Text(inset, "small", UI.GREY, "CENTER")
    f.hint:SetPoint("TOP", row, "BOTTOM", 0, -5)
    -- (laid out as it's shown: the key's width changes with the binding)
    function f.refreshKey()
        local key, default = guildKey()
        cap.key:SetText(key or "J")
        local kw = math.max(26, math.ceil((ns.try(cap.key.GetStringWidth, cap.key) or 10) + 18))
        cap:SetWidth(kw)
        local pw = ns.try(press.GetStringWidth, press) or 34
        local ow = ns.try(open.GetStringWidth, open) or 60
        local total = pw + 8 + kw + 8 + ow
        press:ClearAllPoints(); press:SetPoint("LEFT", row, "CENTER", -total / 2, 0)
        cap:ClearAllPoints(); cap:SetPoint("LEFT", row, "CENTER", -total / 2 + pw + 8, 0)
        open:ClearAllPoints(); open:SetPoint("LEFT", cap, "RIGHT", 8, 0)
        f.hint:SetText(not key and "(by default - it isn't bound to a key now: Esc > Options > Keybindings)"
            or default and "(by default)" or "")
    end

    f.ok = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.ok:SetSize(140, 24)
    f.ok:SetPoint("BOTTOM", 0, 14)
    f.ok:SetText(OKAY or "Okay")
    f.ok:SetScript("OnClick", function()
        ns.db.movedNoticeSeen = true
        f:Hide()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_CLOSE or 851)
    end)
    f:Hide()
    return f
end

function UI.ShowMovedNotice()
    if not notice then notice = buildNotice() end
    notice.refreshKey()
    notice:Show()
    notice:Raise()
    PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPEN or 850)
end
function UI.Notice() return notice end   -- (tests)

ns.onLogin(function()
    ns.after(4, function()
        if ns.db.movedNoticeSeen then return end
        UI.ShowMovedNotice()
    end, "moved notice")
end, "moved notice")

ns.tests.notice = { dev = true, help = "the Moonwardens has moved notice again", fn = function() UI.ShowMovedNotice() end }

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
