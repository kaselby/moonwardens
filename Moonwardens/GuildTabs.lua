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
local opened = false        -- the window has been open this session (login/reload: Leaderboard first)
local remembered            -- our page to come back to: the window reopened, or the guild picked again
local pending               -- a page asked for while the window was closed (GT.Toggle): it opens on this
local W, H = 1018, 533      -- the window with Moonwardens picked: a quarter bigger than the game's 814 x 426
-- (what we know about the game's frames we keep here, never on them: a
-- field written onto one of the game's frames is tainted for its code)
local shownTitle            -- the title we last gave the window
local hookedTabs = setmetatable({}, { __mode = "k" })   -- the game's tabs we've hooked

-- Is the community picked in the window our guild? Everything of ours on the
-- guild window (tabs, size, title, the roster's extras) is for it only.
function GT.GuildPicked()
    local cf = CommunitiesFrame
    if not (cf and cf.GetSelectedClubId and C_Club and Enum and Enum.ClubType) then return false end
    local ok, id = pcall(cf.GetSelectedClubId, cf)
    if not ok or not id then return false end
    local ok2, info = pcall(C_Club.GetClubInfo, id)
    return ok2 and info and info.clubType == Enum.ClubType.Guild or false, info
end

-- The window's title on the guild: the tab's name - one of ours (its
-- `title`), or the game's page under it (by its display mode); else the
-- guild's name.
local MODE_TITLES = { CHAT = "Guild Chat", ROSTER = "Moonwardens Roster", GUILD_INFO = "Guild Info" }
local function titleFor(guild, info)
    if not guild then return COMMUNITIES_FRAME_TITLE end
    local p = current and ns.UI and ns.UI.pages[current]
    if p and p.guild and p.guild.title then return p.guild.title end
    local cf = CommunitiesFrame
    local okM, mode = pcall(function() return cf.GetDisplayMode and cf:GetDisplayMode() end)
    if okM and mode and COMMUNITIES_FRAME_DISPLAY_MODES then
        for name, title in pairs(MODE_TITLES) do
            if COMMUNITIES_FRAME_DISPLAY_MODES[name] == mode then return title end
        end
    end
    return (info and info.name ~= "" and info.name) or "Moonwardens"
end

-- The game's buttons along the window's bottom right, which it shows by its
-- page (its "display mode": Chat's Invite Member and Guild Recruitment,
-- Roster's Guild Control, Guild Info's View Log). Our pages sit over the
-- game's last page, whose buttons would show under them - so, under ours,
-- only what the page asks for (`button` in its guild opts: "invite", the
-- Invite Member button), the rest hidden, and kept so as the game shows
-- them again. Back on a page of the game's: as its mode has them.
-- (Only shown and hidden - nothing of the game's is called or changed.)
local BOTTOM = { "GuildLogButton", "InviteButton", "CommunitiesControlFrame", "AddToChatButton" }
local ASKED = { invite = "InviteButton" }
local hidByUs = {}           -- button -> true: we hid it while the game had it up
local bottomHooked = {}

local function oursUp() return current ~= nil and overlay ~= nil and overlay:IsShown() end
local function wanted(name)
    local p = current and ns.UI.pages[current]
    return p and p.guild and ASKED[p.guild.button or ""] == name or false
end

local function bottomButtons(ours)
    local cf = CommunitiesFrame
    if not cf then return end
    for _, name in ipairs(BOTTOM) do
        local b = cf[name]
        if b and not bottomHooked[b] then
            bottomHooked[b] = true
            b:HookScript("OnShow", function(self)
                if oursUp() and not wanted(name) then hidByUs[self] = true; self:Hide() end
            end)
            b:HookScript("OnHide", function(self)
                if oursUp() and wanted(name) and cf:IsShown() then self:Show() end
            end)
        end
    end
    if ours then
        for _, name in ipairs(BOTTOM) do
            local b = cf[name]
            if b then
                if wanted(name) then b:Show()
                elseif b:IsShown() then hidByUs[b] = true; b:Hide() end
            end
        end
        return
    end
    -- The game's page again: its mode's buttons up, the rest down. (Add to
    -- Chat is in no mode's list - the game shows it for some channels - so
    -- it's only put back if we hid it, never hidden here.)
    local okM, mode = pcall(function() return cf.GetDisplayMode and cf:GetDisplayMode() end)
    local inMode = {}
    if okM and type(mode) == "table" then for _, n in ipairs(mode) do inMode[n] = true end end
    for _, name in ipairs(BOTTOM) do
        local b = cf[name]
        if b then
            if name == "AddToChatButton" then
                if hidByUs[b] then b:Show() end
            elseif inMode[name] then b:Show()
            else b:Hide() end
        end
    end
    wipe(hidByUs)
end

-- The guild's title, centred on the whole window. (The game's sits between
-- its portrait and close button, off centre.) Ours is a font string of our
-- own over the window's top, the game's own title left empty meanwhile;
-- for other communities the game's comes back.
local ourTitle
local function showTitle(title)
    local cf = CommunitiesFrame
    local theirs = (cf.GetTitleText and cf:GetTitleText()) or (cf.TitleContainer and cf.TitleContainer.TitleText)
    if not ourTitle then
        local holder = CreateFrame("Frame", nil, cf)
        holder:SetAllPoints(cf)
        holder:SetFrameLevel((cf.TitleContainer and cf.TitleContainer:GetFrameLevel() or cf:GetFrameLevel()) + 5)
        ourTitle = holder:CreateFontString(nil, "OVERLAY")
        ourTitle:SetFontObject((theirs and theirs:GetFontObject()) or GameFontNormal)
        if theirs then ourTitle:SetTextColor(theirs:GetTextColor()) end
        ourTitle:SetWordWrap(false)
    end
    -- At the game's title's height, the window's middle.
    ourTitle:ClearAllPoints()
    local tx = theirs and theirs:GetCenter()
    local cx = cf:GetCenter()
    if tx and cx then ourTitle:SetPoint("CENTER", theirs, "CENTER", cx - tx, 0)
    else ourTitle:SetPoint("TOP", cf, "TOP", 0, -6) end
    ourTitle:SetText(title)
    ourTitle:Show()
end

-- Size and title for what's picked: ours for the guild, the game's otherwise.
local function guildLook(guild, info)
    local cf = CommunitiesFrame
    local w, h = cf:GetWidth(), cf:GetHeight()
    if guild and math.abs(w - 814) < 1 and math.abs(h - 426) < 1 then cf:SetSize(W, H)
    elseif not guild and math.abs(w - W) < 1 and math.abs(h - H) < 1 then cf:SetSize(814, 426) end
    local title = titleFor(guild, info)
    if not cf.SetTitle then return end
    if guild then
        if shownTitle ~= "" then shownTitle = ""; pcall(cf.SetTitle, cf, "") end
        showTitle(title)
    else
        if ourTitle then ourTitle:Hide() end
        if title and shownTitle ~= title then shownTitle = title; pcall(cf.SetTitle, cf, title) end
    end
end

-- First icon that exists on this client (SetTexture says false for a missing file).
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
    local was = current
    current = nil
    if overlay then overlay:Hide() end
    for _, t in ipairs(tabs) do t:SetChecked(false) end
    if was and CommunitiesFrame then
        bottomButtons(false)
        guildLook(GT.GuildPicked())          -- (the title: the game's page again)
    end
end

-- A tab of the game's was clicked: its page, not ours.
local function hookGameTab(t)
    if hookedTabs[t] then return end
    hookedTabs[t] = true
    t:HookScript("OnClick", function() GT.Deselect() end)
end

-- Our first tab (Leaderboard) takes the top spot, where the game's Chat tab
-- was, and Chat moves down under it (the game never re-anchors Chat). The
-- rest go under the lowest of the game's, 20 px apart as theirs are.
-- Preferred Play Settings goes last of all, under ours, and only the guild
-- master sees it (they're the guild's settings; only the GM can set them).
-- No tabs of the game's (minimized, guild finder): none of ours either.
local function layout()
    local cf = CommunitiesFrame
    local guild, info = GT.GuildPicked()
    guildLook(guild, info)
    if not guild then
        -- Another community: none of ours. Our page comes back with the guild.
        if current then remembered = current end
        for _, t in ipairs(tabs) do t:Hide() end
        GT.Deselect()
        return
    end
    local pps = cf.GuildPreferredPlaySettingsTab
    if pps and pps:IsShown() and not (IsGuildLeader and IsGuildLeader()) then
        pps:SetChecked(false)
        pps:Hide()
    end
    local list = {}
    for _, t in ipairs(cf:IsShown() and gameTabs() or {}) do
        if t == pps then hookGameTab(t) else list[#list + 1] = t end
    end
    local ppsShown = pps and pps:IsShown()
    if #list == 0 and ppsShown then list[1] = pps; ppsShown = false end
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
    -- (a page's `visible` can keep its tab away: the Officers tab)
    local prev = last
    for i = below, #tabs do
        local t = tabs[i]
        local p = ns.UI.pages[t.index]
        local vis = p and p.guild
        vis = not (vis and vis.visible) or vis.visible()
        if vis then
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -20)
            t:Show()
            prev = t
        else
            t:Hide()
            if current == t.index then GT.Deselect() end
        end
    end
    if ppsShown then
        pps:ClearAllPoints()
        pps:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -20)
    end
    if current then uncheckGameTabs() end
    GT.UpdateDots()
    -- Back on the guild after another community: the page we were on.
    if not current and remembered and cf:IsShown() then
        local want = remembered
        remembered = nil
        for _, t in ipairs(tabs) do
            if t.index == want and t:IsShown() then GT.Select(want) end
        end
    end
end

local function newTab(index, p)
    local ok, t = pcall(CreateFrame, "CheckButton", nil, CommunitiesFrame, "CommunitiesFrameTabTemplate")
    if not ok or not t or not t.Icon then return end
    t.mwTab = true
    t.index = index
    t.tooltip = p.guild.tooltip or ("Moonwardens: " .. p.label)
    setIcon(t.Icon, p.guild.icon)
    -- (something new on the page - its `dot` says: a blue dot, top right)
    if p.guild.dot and ns.BadgesUI and ns.BadgesUI.New then
        t.mwDot = ns.BadgesUI.New.Dot(t, 13, "TOPRIGHT", -6, -6, true)   -- (strong: a bigger glow, and a ping)
    end
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
    -- (only with the guild picked: guildLook puts it back for the others)
    hooksecurefunc(cf, "SetSize", function(_, w, h)
        if w == 814 and h == 426 and GT.GuildPicked() then cf:SetSize(W, H) end
    end)
    if math.abs(cf:GetWidth() - 814) < 1 and math.abs(cf:GetHeight() - 426) < 1 and GT.GuildPicked() then cf:SetSize(W, H) end

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
    -- A solid backing under it all: page art with see-through parts (the
    -- Legacy backgrounds) mustn't show the guild window's own page beneath.
    -- It's the window's own background (the tiled rock of the game's window
    -- template, which the Legacy window's art sits on too), so the Legacy art
    -- looks as it does there; solid dark if that can't be read.
    local base = overlay:CreateTexture(nil, "BACKGROUND", nil, -8); base:SetAllPoints()
    local okBase = pcall(function()
        local src = cf.Bg
        local tex = src and src.GetTexture and src:GetTexture() or "Interface\\FrameGeneral\\UI-Background-Rock"
        base:SetTexture(tex, "REPEAT", "REPEAT")
        base:SetHorizTile(true)
        base:SetVertTile(true)
        if src and src.GetVertexColor then base:SetVertexColor(src:GetVertexColor()) end
    end)
    if not okBase then base:SetColorTexture(0.03, 0.03, 0.04, 1) end
    -- (under it, solid dark: the rock may not be fully opaque)
    local under = overlay:CreateTexture(nil, "BACKGROUND", nil, -8); under:SetAllPoints()
    under:SetColorTexture(0.03, 0.03, 0.04, 1)
    under:SetDrawLayer("BACKGROUND", -8)
    base:SetDrawLayer("BACKGROUND", -7)
    local bg = overlay:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints()
    overlay.bg = bg
    -- (a page can bring its own art instead: `bgAtlas` in its guild opts)
    function overlay.DefaultBg()
    bg:SetDesaturated(false); bg:SetTexCoord(0, 1, 0, 1); bg:SetVertexColor(1, 1, 1); bg:SetAlpha(1)
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
    end
    overlay.DefaultBg()
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

    -- (the game titling its window itself: ours stays the one shown)
    if cf.SetTitle then
        hooksecurefunc(cf, "SetTitle", function(_, t)
            if t ~= "" and ourTitle and ourTitle:IsShown() and GT.GuildPicked() then
                shownTitle = ""
                pcall(cf.SetTitle, cf, "")
            end
        end)
    end
    if cf.UpdateCommunitiesTabs then hooksecurefunc(cf, "UpdateCommunitiesTabs", ns.guard(layout, "guild tabs")) end
    if cf.SetDisplayMode then hooksecurefunc(cf, "SetDisplayMode", ns.guard(layout, "guild tabs")) end
    GT.RosterRock()
    -- The guild window opens on our first tab (Leaderboard), unless the
    -- minimap button or /mw already asked for another page.
    cf:HookScript("OnShow", ns.guard(function()
        layout()
        C_Timer.After(0, ns.guard(function()               -- (once its tabs have positions)
            layout()
            -- First open since login/reload: the Leaderboard. After that, as
            -- the game does: the page you left it on (the game remembers its
            -- own; ours we bring back).
            if pending and tabs[1]:IsShown() then
                local want = pending
                pending = nil
                GT.Select(want)
            end
            if not current then
                if not opened then
                    if tabs[1]:IsShown() then GT.Select(tabs[1].index) end
                elseif remembered then
                    local want = remembered
                    remembered = nil
                    for _, t in ipairs(tabs) do
                        if t.index == want and t:IsShown() then GT.Select(want) end
                    end
                end
            end
            opened = true
        end, "guild tabs"))
    end, "guild tabs"))
    cf:HookScript("OnHide", function()
        remembered = current
        GT.Deselect()
    end)
    if cf.OnClubSelected then hooksecurefunc(cf, "OnClubSelected", ns.guard(layout, "guild tabs")) end
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

-- (GT.Available: can the pages live on the guild window, as it is now?)
-- Is the guild window there for our pages? Never loads it: loading the
-- game's guild window from addon code taints it (see GT.Toggle).
function GT.Available()
    if attached then return true end
    if not (IsInGuild and IsInGuild()) then return false end
    return CommunitiesFrame and attach() or false
end

-- Is it open now, with our tabs on it?
function GT.Open()
    return attached and CommunitiesFrame and CommunitiesFrame:IsShown() and GT.GuildPicked() or false
end

-- The Roster page on the same background as our pages (Leaderboard,
-- Badges): solid dark, the window's rock, the Legacy Rewards art stretched
-- over it, on the same area as our page panel. Our own textures, on the
-- window's inset (under the roster's rows and headers, over its marble);
-- shown only while the Roster is. Nothing of the game's is changed.
local ROSTER_ART = "Legacy-Rewards-Tracker-background"
local rosterBg
function GT.RosterRock()
    if rosterBg then return end
    local cf = CommunitiesFrame
    local inset = CommunitiesFrameInset or cf.Inset
    if not (inset and cf.SetDisplayMode and COMMUNITIES_FRAME_DISPLAY_MODES) then return end
    local function layer(sub)
        local t = inset:CreateTexture(nil, "BACKGROUND", nil, sub)
        t:SetPoint("TOPLEFT", cf, "TOPLEFT", LIST_W + 4, -23)
        t:SetPoint("BOTTOMRIGHT", cf, "BOTTOMRIGHT", -6, 26)
        t:Hide()
        return t
    end
    local under = layer(-4); under:SetColorTexture(0.03, 0.03, 0.04, 1)
    local rock = layer(-3)
    local src = cf.Bg
    rock:SetTexture(src and src.GetTexture and src:GetTexture() or "Interface\\FrameGeneral\\UI-Background-Rock", "REPEAT", "REPEAT")
    rock:SetHorizTile(true); rock:SetVertTile(true)
    if src and src.GetVertexColor then rock:SetVertexColor(src:GetVertexColor()) end
    local art = layer(-2)
    local okArt, res = pcall(art.SetAtlas, art, ROSTER_ART)
    if not okArt or res == false then art = nil end
    rosterBg = { under, rock, art }
    local function apply(mode)
        local on = mode == COMMUNITIES_FRAME_DISPLAY_MODES.ROSTER and GT.GuildPicked()
        for _, t in pairs(rosterBg) do t:SetShown(on and true or false) end
    end
    hooksecurefunc(cf, "SetDisplayMode", function(_, mode) pcall(apply, mode) end)
    if cf.OnClubSelected then
        hooksecurefunc(cf, "OnClubSelected", function() if cf.GetDisplayMode then pcall(apply, cf:GetDisplayMode()) end end)
    end
    if cf.GetDisplayMode then pcall(apply, cf:GetDisplayMode()) end
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
    if p.guild.onSelect then ns.guard(p.guild.onSelect, "tab picked")() end
    GT.UpdateDots()
    for _, q in pairs(ns.UI.pages) do if q.gframe then q.gframe:SetShown(q == p) end end
    local art = p.guild.bgAtlas
    -- "rock": nothing over the window's rock (the backing above).
    overlay.bg:SetShown(art ~= "rock")
    if art == "rock" then art = nil end
    local okArt, res = false, nil
    if art then
        -- (stretched to fit, not tiled: the inset copy left tiling on)
        overlay.bg:SetHorizTile(false); overlay.bg:SetVertTile(false)
        okArt, res = pcall(overlay.bg.SetAtlas, overlay.bg, art)
    end
    if okArt and res ~= false then overlay.bg:SetVertexColor(1, 1, 1); overlay.bg:SetAlpha(1)
    else overlay.DefaultBg() end
    overlay:Show()
    for _, t in ipairs(tabs) do t:SetChecked(t.index == index) end
    uncheckGameTabs()
    bottomButtons(true)
    guildLook(GT.GuildPicked())              -- (the title: this page's)
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
-- Show page `index` (default: the first, Leaderboard) on the guild window.
-- We never open or close the game's windows ourselves: on this client a
-- window opened or closed from addon code taints the game's window manager,
-- and the next window it opens (the character pane, say) breaks on secret
-- values. So: open, we switch to the page; closed, the page is kept for
-- when the guild window next opens (J), and we say so.
function GT.Toggle(index)
    if not (IsInGuild and IsInGuild()) or failed then return false end
    local want = index or (tabs[1] and tabs[1].index) or 5
    if GT.Open() then
        layout()
        if GT.Select(want) then return true end
    end
    pending = want
    local p = ns.UI.pages[want]
    ns.print(("Press |cffffd100J|r to open the guild window; it opens on %s."):format(
        p and (p.guild and p.guild.tooltip or p.label) or "Moonwardens"))
    return true
end

-- The guild window loaded (J pressed, or another addon): attach then.
ns:On("ADDON_LOADED", function(name)
    if name == "Blizzard_Communities" and ns.UI then attach() end
end)
ns.onLogin(function() if CommunitiesFrame then attach() end end, "guild tabs")

-- For tests.
function GT.Debug() return tabs, overlay, current end

-- Our tabs' dots, as their pages' `dot` say now.
function GT.UpdateDots()
    for _, t in ipairs(tabs) do
        local p = ns.UI.pages[t.index]
        if t.mwDot then t.mwDot:SetShown(p and p.guild and p.guild.dot and p.guild.dot() and true or false) end
    end
end

-- Is the page labelled `label` the one shown on the guild window now?
function GT.Showing(label)
    local p = current and ns.UI.pages[current]
    return p and p.label == label and overlay and overlay:IsVisible() and true or false
end

-- Tabs again now (one's `visible` changed: test mode, rank).
function GT.Relayout()
    if attached and CommunitiesFrame and CommunitiesFrame:IsShown() then layout() end
end
