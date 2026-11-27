-- GuildInfoStats: the guild's race, class and level breakdowns on the guild
-- window's Info tab, in the space between its left column (Message of the
-- Day, Guild Information) and Guild News. (They were the Stats tab; that's
-- Badges now.) Ours is a child of the game's Info page, so it shows and hides
-- with it; nothing of the game's is moved.
local _, ns = ...
local UI = ns.UI
local GIS = {}
ns.GuildInfoStats = GIS

local ROW_H = 15
local COL_GAP = 20         -- between the three columns (ours keeps this much clear each side)
local RACE_COLOR = { NightElf = { 0.79, 0.71, 0.94 } }
local LEVEL_BANDS = { "1-9", "10-19", "20-29", "30-39", "40-49", "50-59", "60" }
local panel

local function heading(parent, label)
    local h = ns.BadgesUI.Kit.bump(UI.Text(parent, nil, UI.GOLD, "LEFT"))
    h:SetText(label)
    h.line = parent:CreateTexture(nil, "ARTWORK")
    h.line:SetColorTexture(0.55, 0.45, 0.2, 0.6)
    h.line:SetHeight(1)
    h.line:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -2)
    h.line:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
    return h
end

-- A label, a coloured bar, a number: the bar takes what the width leaves.
local function newRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_H - 2)
    row.label = UI.Text(row, "small", nil, "LEFT"); row.label:SetPoint("LEFT"); row.label:SetWidth(62)
    row.value = UI.Text(row, "small", nil, "RIGHT"); row.value:SetPoint("RIGHT"); row.value:SetWidth(54)
    row.bar = CreateFrame("StatusBar", nil, row)
    row.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    row.bar:SetPoint("LEFT", 64, 0)
    row.bar:SetPoint("RIGHT", -56, 0)
    row.bar:SetHeight(9)
    local bg = row.bar:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetColorTexture(0, 0, 0, 0.6)
    return row
end

-- Rows under `head`, biggest first; returns the bottom-most thing.
local function fill(pool, parent, head, entries, colorOf)
    local total = 0
    for _, e in ipairs(entries) do total = total + e.n end
    table.sort(entries, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.label < b.label end)
    local maxN = entries[1] and entries[1].n or 1
    local last = head
    for i = 1, math.max(#entries, #pool) do
        local e, row = entries[i], pool[i]
        if e then
            if not row then row = newRow(parent); pool[i] = row end
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -6 - (i - 1) * ROW_H)
            row:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
            row.label:SetText(e.label)
            local r, g, b = colorOf(e)
            row.label:SetTextColor(r, g, b)
            row.bar:SetStatusBarColor(r, g, b)
            row.bar:SetMinMaxValues(0, maxN)
            row.bar:SetValue(e.n)
            row.value:SetText(e.n .. " |cff9d9d9d" .. UI.Pct(e.n, total) .. "|r")
            row:Show()
            last = row
        elseif row then
            row:Hide()
        end
    end
    return last
end

local function refresh()
    if not (panel and panel:IsVisible()) then return end
    local f = panel
    local onlineOnly = f.toggle:GetChecked()
    local s = ns.Roster.Stats(onlineOnly)
    if not ns.Roster.Loaded() then
        f.head:SetText("Waiting for the roster...")
    else
        f.head:SetText(("|cffffffff%d|r members, |cff1eff00%d online|r, %d at 60"):format(
            onlineOnly and ns.Roster.Count() or s.total, s.online, s.max))
    end
    -- Every race and class in the guild keeps its row; with Online only, one
    -- with nobody online shows at 0 rather than going away.
    local all = onlineOnly and ns.Roster.Stats(false) or s
    local races, classes = {}, {}
    for k, e in pairs(all.race) do
        races[#races + 1] = { n = s.race[k] and s.race[k].n or 0, label = e.label, key = k }
    end
    for k, e in pairs(all.class) do
        classes[#classes + 1] = { n = s.class[k] and s.class[k].n or 0, label = e.label, file = e.file }
    end
    local lastRace = fill(f.racePool, f, f.raceHead, races, function(e)
        local c = RACE_COLOR[e.key] or { 0.85, 0.75, 0.6 }
        return c[1], c[2], c[3]
    end)
    f.classHead:ClearAllPoints()
    f.classHead:SetPoint("TOPLEFT", lastRace, "BOTTOMLEFT", 0, -12)
    local lastClass = fill(f.classPool, f, f.classHead, classes, function(e) return ns.classColor(e.file) end)
    f.levelHead:ClearAllPoints()
    f.levelHead:SetPoint("TOPLEFT", lastClass, "BOTTOMLEFT", 0, -12)

    local maxBand = 1
    for i = 1, #LEVEL_BANDS do maxBand = math.max(maxBand, s.level[i] or 0) end
    local colW = math.floor((f:GetWidth() or 210) / #LEVEL_BANDS)
    for i, col in ipairs(f.levelBars) do
        local n = s.level[i] or 0
        col:ClearAllPoints()
        col:SetSize(colW, 74)
        col:SetPoint("TOPLEFT", f.levelHead, "BOTTOMLEFT", (i - 1) * colW, -6)
        col.bar:SetHeight(math.max(1, 34 * n / maxBand))
        col.bar:SetWidth(math.max(6, colW - 10))
        col.n:SetText(n)
    end
    -- (race is read for the whole roster, offline members included)
    f.foot:SetText(s.unknownRace > 0 and ("Race not known yet for %d."):format(s.unknownRace) or "")
end
GIS.Refresh = refresh

local function attach()
    local cf = CommunitiesFrame
    local gd = cf and cf.GuildDetailsFrame
    if panel or not (gd and gd.Info and gd.News) then return end
    -- Three columns of one width: the game's left column (Message of the Day,
    -- Guild Information), ours, Guild News. Guild News's fixed-width parts
    -- (header, list; the list's rows follow the list) change with it. Done
    -- on each show, once the window has its size.
    local news = gd.News
    local orig = {
        info = gd.Info:GetWidth(), news = news:GetWidth(),
        header = news.Header and news.Header:GetWidth(),
        list = news.ScrollBox and news.ScrollBox:GetWidth(),
        impeach = news.GMImpeachButton and news.GMImpeachButton:GetWidth(),
    }
    local function columns()
        local W = gd:GetWidth()
        if not W or W < 300 then return end
        local col = math.floor((W - 4 - 2 * COL_GAP) / 3)   -- (News sits 4 in from the right)
        gd.Info:SetWidth(col)
        local d = col - orig.news
        news:SetWidth(col)
        if orig.header then news.Header:SetWidth(orig.header + d) end
        if orig.list then news.ScrollBox:SetWidth(orig.list + d) end
        if orig.impeach then news.GMImpeachButton:SetWidth(orig.impeach + d) end
    end
    pcall(columns)
    gd:HookScript("OnShow", function() pcall(columns) end)
    gd:HookScript("OnSizeChanged", function() pcall(columns) end)
    local f = CreateFrame("Frame", nil, gd)
    f:SetPoint("TOPLEFT", gd.Info, "TOPRIGHT", COL_GAP + 14, -4)   -- (clear of the left column's wide header bars)
    f:SetPoint("BOTTOMRIGHT", gd.News, "BOTTOMLEFT", -(COL_GAP - 12), 6)
    panel = f

    f.title = UI.Text(f, nil, UI.GOLD, "LEFT"); f.title:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 0, 8)
    pcall(f.title.SetFontObject, f.title, GameFontNormalMed1 or GameFontNormal)
    ns.BadgesUI.Kit.bump(f.title)
    f.title:SetText("Guild Stats")

    f.head = UI.Text(f, "small", nil, "LEFT"); f.head:SetPoint("TOPLEFT", 0, 0); f.head:SetPoint("RIGHT", 0, 0)
    f.toggle = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    f.toggle:SetSize(20, 20); f.toggle:SetPoint("TOPLEFT", f.head, "BOTTOMLEFT", -3, -2)
    f.toggleLabel = UI.Text(f, "small", UI.GOLD, "LEFT"); f.toggleLabel:SetPoint("LEFT", f.toggle, "RIGHT", 1, 0)
    f.toggleLabel:SetText("Online only")
    f.toggle:SetScript("OnClick", refresh)

    f.raceHead = heading(f, "Race"); f.raceHead:SetPoint("TOPLEFT", 0, -42)
    f.classHead = heading(f, "Class")
    f.levelHead = heading(f, "Level")
    f.racePool, f.classPool = {}, {}
    f.levelBars = {}
    for i = 1, #LEVEL_BANDS do
        local col = CreateFrame("Frame", nil, f)
        col.bar = col:CreateTexture(nil, "ARTWORK")
        col.bar:SetColorTexture(1, 1, 1, 1)
        if not (CreateColor and pcall(col.bar.SetGradient, col.bar, "VERTICAL",
                CreateColor(0.75, 0.5, 0, 1), CreateColor(1, 0.85, 0.2, 1))) then
            col.bar:SetColorTexture(1, 0.82, 0, 1)
        end
        col.bar:SetPoint("BOTTOM", 0, 26)
        col.n = UI.Text(col, "small", nil, "CENTER"); col.n:SetPoint("BOTTOM", col.bar, "TOP", 0, 2)
        col.label = UI.Text(col, "small", UI.GREY, "CENTER"); col.label:SetPoint("BOTTOM", 0, 14)
        col.label:SetText(LEVEL_BANDS[i])
        pcall(col.label.SetFontObject, col.label, SystemFont_Tiny or GameFontHighlightSmall)
        f.levelBars[i] = col
    end
    f.foot = UI.Text(f, "small", UI.GREY, "LEFT"); f.foot:SetPoint("BOTTOMLEFT", 0, 0); f.foot:SetPoint("RIGHT", 0, 0)
    f.foot:SetJustifyV("BOTTOM")

    f:SetScript("OnShow", refresh)
    if f:IsVisible() then refresh() end
end

ns:On("ADDON_LOADED", function(name) if name == "Blizzard_Communities" then attach() end end)
ns.onLogin(function()
    if CommunitiesFrame then attach() end
    ns.listen("ROSTER", refresh)
end, "guild info stats")
