-- GuildTabs: the Leaderboard and Stats pages as side tabs on the
-- game's guild window (J: the Communities frame): Leaderboard on top,
-- above its own Chat tab, and the window opens on it; Stats under
-- its Roster, Info... tabs. Pages opt in with the `guild` argument of
-- ns.UI.AddPage; the Moonwardens window keeps the rest (Settings).
--
-- We never change the guild window's own mode (its SetDisplayMode): our page
-- is a panel laid over its content, our tab is checked and its tabs
-- unchecked. Clicking one of its tabs, or closing it, takes the panel away
-- again. That keeps the game's code running as it always does.
--
-- The guild window is load-on-demand (Blizzard_Communities). We attach when
-- it loads, or load it ourselves when the minimap button wants it. If it
-- isn't there, or isn't shaped as we expect, the pages stay in our window.
local _, ns = ...
local GT = {}
ns.GuildTabs = GT

local LIST_W = 170          -- the guild window's community list, on its left
local attached = false
local failed = false        -- the guild window isn't shaped as we expect
local overlay
local tabs = {}             -- our tab buttons, in page order
local current               -- page index shown on the guild window, or nil

-- First icon that exists on this client (SetTexture says false for a missing file).
local function setIcon(tex, names)
    for _, n in ipairs(names or {}) do
        local ok, res = pcall(tex.SetTexture, tex, "Interface\\Icons\\" .. n)
        if ok and res ~= false then return end
    end
    tex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
end

-- The guild window's own side tabs on show: check buttons with an icon, on
-- its right edge. Found by shape, so tabs Forever adds are found too.
local function gameTabs()
    local cf, list = CommunitiesFrame, {}
    local right = cf:GetRight()
    for _, c in ipairs({ cf:GetChildren() }) do
        if not c.mwTab and c.GetObjectType and c:GetObjectType() == "CheckButton" and c.Icon and c:IsShown() then
            local left = c:GetLeft()
            if left and right and math.abs(left - right) < 6 then list[#list + 1] = c end
        end
    end
    if #list == 0 then
        -- (positions not worked out yet: the tabs we know of)
        for _, k in ipairs({ "ChatTab", "RosterTab", "GuildBenefitsTab", "GuildInfoTab" }) do
            if cf[k] and cf[k]:IsShown() then list[#list + 1] = cf[k] end
        end
    end
    return list
end

local function uncheckGameTabs()
    for _, t in ipairs(gameTabs()) do t:SetChecked(false) end
end

function GT.Deselect()
    current = nil
    if overlay then overlay:Hide() end
    for _, t in ipairs(tabs) do t:SetChecked(false) end
end

-- A tab of the game's was clicked: its page, not ours.
local function hookGameTab(t)
    if t.mwHooked then return end
    t.mwHooked = true
    t:HookScript("OnClick", function() GT.Deselect() end)
end

-- Our first tab (Leaderboard) takes the top spot, where the game's Chat tab
-- was, and Chat moves down under it (the game never re-anchors Chat). The
-- rest go under the lowest of the game's, 20 px apart as theirs are.
-- No tabs of the game's (minimized, guild finder): none of ours either.
local function layout()
    local cf = CommunitiesFrame
    local list = cf:IsShown() and gameTabs() or {}
    if #list == 0 then
        for _, t in ipairs(tabs) do t:Hide() end
        GT.Deselect()
        return
    end
    local below = 1                     -- our tabs from here go under the game's
    local chat = cf.ChatTab
    if chat and chat:IsShown() then
        local top = tabs[1]
        top:ClearAllPoints()
        top:SetPoint("TOPLEFT", cf, "TOPRIGHT", 0, -36)
        top:Show()
        chat:ClearAllPoints()
        chat:SetPoint("TOPLEFT", top, "BOTTOMLEFT", 0, -20)
        below = 2
    end
    -- The lowest one; without positions yet, the last in the list.
    local last, lastTop = list[#list], nil
    for _, t in ipairs(list) do
        hookGameTab(t)
        local top = t:GetTop()
        if not top then lastTop = nil; break end
        if not lastTop or top < lastTop then last, lastTop = t, top end
    end
    if not lastTop then last = list[#list] end
    for i = below, #tabs do
        local t = tabs[i]
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", i == below and last or tabs[i - 1], "BOTTOMLEFT", 0, -20)
        t:Show()
    end
    if current then uncheckGameTabs() end
end

local function newTab(index, p)
    local ok, t = pcall(CreateFrame, "CheckButton", nil, CommunitiesFrame, "CommunitiesFrameTabTemplate")
    if not ok or not t or not t.Icon then return end
    t.mwTab = true
    t.index = index
    t.tooltip = p.guild.tooltip or ("Moonwardens: " .. p.label)
    setIcon(t.Icon, p.guild.icon)
    t:SetScript("OnClick", ns.guard(function()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        GT.Select(index)
    end, "guild tab"))
    t:Hide()
    return t
end

local function attach()
    local cf = CommunitiesFrame
    if attached or not cf or not cf.ChatTab or not cf.RosterTab then return attached end
    local UI = ns.UI
    local order = {}
    for i, p in pairs(UI.pages) do if p.guild then order[#order + 1] = i end end
    local function rank(i) return UI.pages[i].guild.order or i end
    table.sort(order, function(a, b) return rank(a) < rank(b) end)
    if #order == 0 then return false end

    -- A quarter wider and taller than the game's 814 x 426, for the roster's
    -- extra and wider columns (RosterLayer.lua) and longer lists here. The
    -- game sets 814 x 426 again on every maximize; we follow it each time.
    local W, H = 1018, 533
    hooksecurefunc(cf, "SetSize", function(_, w, h)
        if w == 814 and h == 426 then cf:SetSize(W, H) end
    end)
    if math.abs(cf:GetWidth() - 814) < 1 and math.abs(cf:GetHeight() - 426) < 1 then cf:SetSize(W, H) end

    -- The panel our pages draw on: the content area right of the community
    -- list, above everything there: the chat's scroll bar is HIGH strata
    -- (the rest of the window MEDIUM), the chat box at level 1200.
    overlay = CreateFrame("Frame", nil, cf)
    overlay:SetFrameStrata("HIGH")
    overlay:SetPoint("TOPLEFT", cf, "TOPLEFT", LIST_W + 4, -23)
    overlay:SetPoint("BOTTOMRIGHT", cf, "BOTTOMRIGHT", -6, 26)
    local eb = cf.ChatEditBox
    overlay:SetFrameLevel(math.max(1300, (eb and eb:GetFrameLevel() or 0) + 20))
    overlay:EnableMouse(true)          -- (clicks don't fall through to the chat under it)
    -- The background the game's own pages sit on (Preferred Play Settings has
    -- none of its own: it shows the window's inset), copied from that inset;
    -- a plain dark one if it can't be read.
    local bg = overlay:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints()
    local okBg = pcall(function()
        local inset = CommunitiesFrameInset or cf.Inset
        local src = inset and inset.Bg
        if not src then error("no inset background") end
        local atlas = src.GetAtlas and src:GetAtlas()
        if atlas then
            bg:SetAtlas(atlas)
        else
            local tex = src:GetTexture()
            if not tex then error("no texture") end
            bg:SetTexture(tex, "REPEAT", "REPEAT")
            bg:SetHorizTile(src:GetHorizTile())
            bg:SetVertTile(src:GetVertTile())
            bg:SetTexCoord(src:GetTexCoord())
        end
        bg:SetVertexColor(src:GetVertexColor())
        bg:SetAlpha(src:GetAlpha())
    end)
    if not okBg then bg:SetColorTexture(0.04, 0.04, 0.05, 0.97) end
    local brand = UI.Text(overlay, "small", UI.GREY, "RIGHT"); brand:SetPoint("BOTTOMRIGHT", -10, 6)
    brand:SetText("Moonwardens")
    overlay:Hide()

    for _, i in ipairs(order) do
        local t = newTab(i, UI.pages[i])
        if not t then
            -- The game's tab template isn't what we know: stay in our window.
            overlay = nil
            for _, o in ipairs(tabs) do o:Hide() end
            tabs = {}
            failed = true
            return false
        end
        tabs[#tabs + 1] = t
    end

    if cf.UpdateCommunitiesTabs then hooksecurefunc(cf, "UpdateCommunitiesTabs", ns.guard(layout, "guild tabs")) end
    if cf.SetDisplayMode then hooksecurefunc(cf, "SetDisplayMode", ns.guard(layout, "guild tabs")) end
    -- The guild window opens on our first tab (Leaderboard), unless the
    -- minimap button or /mw already asked for another page.
    cf:HookScript("OnShow", ns.guard(function()
        layout()
        C_Timer.After(0, ns.guard(function()               -- (once its tabs have positions)
            layout()
            if not current and tabs[1]:IsShown() then GT.Select(tabs[1].index) end
        end, "guild tabs"))
    end, "guild tabs"))
    cf:HookScript("OnHide", function() GT.Deselect() end)
    attached = true
    if cf:IsShown() then layout() end
    return true
end

-- Do the guild pages belong on the guild window, rather than in ours?
-- Without loading it: yes unless it turned out unusable, or there's no guild.
function GT.Hosting()
    if attached then return true end
    if failed or not (IsInGuild and IsInGuild()) then return false end
    if CommunitiesFrame then return attach() end
    return true
end

-- Can the pages live on the guild window? Loads it if need be.
function GT.Available()
    if attached then return true end
    if not (IsInGuild and IsInGuild()) then return false end
    if not CommunitiesFrame then
        local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
        if load then pcall(load, "Blizzard_Communities") end
    end
    return attach()
end

-- Show page `index` on the guild window (which must be open).
function GT.Select(index)
    local p = ns.UI.pages[index]
    if not (attached and p and p.guild) then return false end
    if not p.gframe then
        local cf = CommunitiesFrame
        p.gframe = CreateFrame("Frame", nil, overlay)
        p.gframe:SetPoint("TOPLEFT", 14, -10)
        -- Sized from the window's fixed size, so pages can fit their rows at build.
        p.gframe:SetSize(cf:GetWidth() - LIST_W - 10 - 28, cf:GetHeight() - 49 - 28)
        p.gframe:Hide()
        ns.guard(p.build, "build " .. p.label)(p.gframe)
    end
    current = index
    for _, q in pairs(ns.UI.pages) do if q.gframe then q.gframe:SetShown(q == p) end end
    overlay:Show()
    for _, t in ipairs(tabs) do t:SetChecked(t.index == index) end
    uncheckGameTabs()
    local eb = CommunitiesFrame.ChatEditBox
    if eb and eb.HasFocus and eb:HasFocus() then eb:ClearFocus() end
    GT.Refresh()
    return true
end

function GT.Refresh()
    if not (current and overlay and overlay:IsShown()) then return end
    local p = ns.UI.pages[current]
    if p and p.gframe and p.refresh then ns.guard(p.refresh, "page " .. p.label)(p.gframe) end
end

-- Minimap button and /mw: open the guild window on a page (default: the
-- first, Stats), or close it if it's already showing one of ours.
function GT.Toggle(index)
    if not GT.Available() then return false end
    local cf = CommunitiesFrame
    if cf:IsShown() and current and (not index or index == current) then
        HideUIPanel(cf)
        return true
    end
    local want = index or tabs[1].index
    if not cf:IsShown() then
        if ToggleGuildFrame then ToggleGuildFrame() else ShowUIPanel(cf) end
    end
    if not cf:IsShown() then return false end
    layout()
    if tabs[1]:IsShown() then return GT.Select(want) end
    -- Its tabs come up a frame later on some opens; then it's minimized or
    -- on the guild finder, which have no tabs.
    C_Timer.After(0, ns.guard(function()
        layout()
        if tabs[1]:IsShown() then GT.Select(want)
        else ns.print("Maximise the guild window to see the Moonwardens tabs.") end
    end, "guild tabs"))
    return true
end

-- The guild window loaded (J pressed, or another addon): attach then.
ns:On("ADDON_LOADED", function(name)
    if name == "Blizzard_Communities" and ns.UI then attach() end
end)
ns.onLogin(function() if CommunitiesFrame then attach() end end, "guild tabs")

-- For tests.
function GT.Debug() return tabs, overlay, current end
