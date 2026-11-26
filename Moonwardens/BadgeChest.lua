-- BadgeChest: a guildie's badges in a window of its own, opened from "View
-- Badges" in any right-click menu (chat, roster, Leaderboard, unit frames),
-- wherever you are: it's our own frame, so nothing of the game's is opened
-- (no taint), and the guild window's Badges tab stays yours.
-- Like opening a chest: their Badge Showcase, then every other badge
-- they've earned (their Badge Collection) - the badge board, BadgesUI.lua -
-- each an icon, its tier's coin bottom right and how many times bottom left
-- (x3), the badge's own tooltip on hover. Yours can be rearranged by
-- dragging, as on the Overview. Whose it is: "Inspected Moonwarden:" and
-- their name, a field - type another guildie's (first names first, as the
-- Officers tab's) or pick one from the list beside it (you: "(you)"); My
-- Chest, top right, back to yours.
-- The Collection as they arranged it, or by points or the date earned:
-- the sort sits on the Collection's heading, as it orders only that - the
-- Showcase, above, stays as placed. (The choice is kept in
-- MoonwardensDB.chestSort; where the window was moved to, in chestPos.)
local _, ns = ...
local Badges = ns.Badges
local K = ns.BadgesUI.Kit
local Chest = {}
ns.BadgeChest = Chest

local W, H = 640, 450          -- (wide enough for a long name between the label and My Chest)
local ICON, GAP = 53, 12
local CHEST_ICON = "Interface\\Icons\\INV_Misc_Spyglass_03"   -- (the Badge Inspector: a spyglass)
local f                 -- the window
local who               -- whose badges it shows
local PICKS = 8         -- names suggested while typing

-- How the Collection is shown (Badges.SORTS; "arranged": as they arranged it).
local function sortId()
    local s = ns.db and ns.db.chestSort
    for _, o in ipairs(Badges.SORTS) do if o.id == s and not o.hidden then return s end end   -- (a hidden one: as arranged)
    return "arranged"
end

local function sortText(id)
    for _, o in ipairs(Badges.SORTS) do if o.id == id then return o.text end end
end

---------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------
local function setTitle(t)
    if f.SetTitle then pcall(f.SetTitle, f, t); return end
    local fs = f.TitleText or (f.TitleContainer and f.TitleContainer.TitleText)
    if fs then fs:SetText(t) end
end

local function setPortrait(tex)
    if f.SetPortraitToAsset and pcall(f.SetPortraitToAsset, f, tex) then return true end
    local p = f.portrait or (f.PortraitContainer and f.PortraitContainer.portrait)
    if p then p:SetTexture(tex); return true end
    return false
end

local function build()
    if f then return end
    local templates = { "PortraitFrameTemplate", "BasicFrameTemplateWithInset" }
    for _, t in ipairs(templates) do
        local ok, fr = pcall(CreateFrame, "Frame", "MoonwardensBadgeChest", UIParent, t)
        if ok and fr then f = fr; break end
    end
    if not f then
        f = CreateFrame("Frame", "MoonwardensBadgeChest", UIParent, "BackdropTemplate")
        f:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 } })
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -4, -4)
    end
    f:SetSize(W, H)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, rel, x, y = self:GetPoint(1)
        if ns.db then ns.db.chestPos = { point, rel, x, y } end
    end)
    local pos = ns.db and ns.db.chestPos
    f:ClearAllPoints()
    if type(pos) == "table" and pos[1] then f:SetPoint(pos[1], UIParent, pos[2] or pos[1], pos[3] or 0, pos[4] or 0)
    else f:SetPoint("CENTER", 0, 40) end
    setTitle("Badge Inspector")
    local portrait = setPortrait(CHEST_ICON)
    tinsert(UISpecialFrames, "MoonwardensBadgeChest")   -- (Escape closes it)

    -- One row beside the portrait: "Inspected Moonwarden:", their name, the
    -- guild's list; My Chest on the right. (The sort: on the Collection's
    -- heading, below.)
    local x = portrait and 62 or 12
    local ROW_Y = -50                     -- (the row's middle)
    f.who = K.text(f, "GameFontNormalLarge")
    f.who:SetText("Inspected Moonwarden:")
    f.who:SetPoint("LEFT", f, "TOPLEFT", x, ROW_Y)
    f.mine = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.mine:SetSize(96, 22)
    f.mine:SetPoint("RIGHT", f, "TOPRIGHT", -12, ROW_Y)
    f.mine:SetText("My Badges")
    f.mine:SetScript("OnClick", function() Chest.Open(ns.meKey) end)
    -- Their name: a field to type another's in, and the guild's list
    -- (ns.GuildiePicker, below - Badge Management's Guildie is the same).
    f.picker = ns.GuildiePicker(f, {
        current = function() return who end,
        onPick = function(key) Chest.Open(key) end,
        onBlur = function() Chest.Refresh() end,
    })
    f.name, f.arrow = f.picker.box, f.picker.arrow
    f.name:SetPoint("LEFT", f.who, "RIGHT", 12, 0)
    local okDD, dd = pcall(CreateFrame, "DropdownButton", nil, f, "WowStyle1DropdownTemplate")
    if okDD and dd and dd.SetupMenu then
        dd:SetWidth(170)
        dd:SetupMenu(function(_, root)
            for _, o in ipairs(Badges.SORTS) do
                if not o.hidden then
                    root:CreateRadio(o.text, function(id) return sortId() == id end,
                        function(id) if ns.db then ns.db.chestSort = id end; Chest.Refresh() end, o.id)
                end
            end
        end)
        dd:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Sort the Badge Collection", 1, 0.82, 0)
            GameTooltip:AddLine("The Badge Showcase stays as placed.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        dd:HookScript("OnLeave", function() GameTooltip:Hide() end)
        f.sort = dd
    end
    f.name:SetPoint("RIGHT", f.mine, "LEFT", -34, 0)

    -- The chest: the Badges tab's ground (dark, the game's rock, the Legacy art).
    local inset = CreateFrame("Frame", nil, f)
    inset:SetPoint("TOPLEFT", 10, -82)
    inset:SetPoint("BOTTOMRIGHT", -10, 10)
    local under = inset:CreateTexture(nil, "BACKGROUND", nil, -4); under:SetAllPoints(); under:SetColorTexture(0.03, 0.03, 0.04, 1)
    local rock = inset:CreateTexture(nil, "BACKGROUND", nil, -3); rock:SetAllPoints()
    rock:SetTexture("Interface\\FrameGeneral\\UI-Background-Rock", "REPEAT", "REPEAT")
    rock:SetHorizTile(true); rock:SetVertTile(true)
    local art = inset:CreateTexture(nil, "BACKGROUND", nil, -2); art:SetAllPoints()
    if not K.atlas(art, "Legacy-Rewards-Tracker-background") then art:Hide() end
    f.inset = inset

    f.scroll = K.newScroll(inset)
    f.scroll:SetPoint("TOPLEFT", 10, -10)
    f.scroll:SetPoint("BOTTOMRIGHT", -26, 10)
    f.scroll.child:SetWidth(W - 20 - 36)

    -- (dragging mine: the Collection then shows as I arrange it)
    f.board = K.newBoard(f.scroll.child, { clip = f.scroll,
        onArrange = function() if ns.db then ns.db.chestSort = "arranged" end end })
    f.board:SetPoint("TOPLEFT")
    f.board:SetWidth(W - 20 - 36)
    if f.sort then f.board:SetHeadWidget(f.sort) end

    f:SetScript("OnHide", function() GameTooltip:Hide() end)
    f:Hide()
end

-- A guildie's name in their class colour (or RP colour), for the lists.
local function coloured(key)
    local m = ns.Roster.Get(key)
    local r, g, b
    if ns.RP then r, g, b = ns.RP.Color(key) end
    if not r then r, g, b = ns.classColor(m and m.classFile) end
    return ("|cff%02x%02x%02x%s|r"):format((r or 1) * 255, (g or 1) * 255, (b or 1) * 255, K.nameOf(key))
        .. (key == ns.meKey and " |cff9d9d9d(you)|r" or "")
end

-- Guildies for what's typed: first names first (the Officers tab's way).
local function matching(q, n)
    if ns.OfficerUI and ns.OfficerUI.Matches then return ns.OfficerUI.Matches(q, n) end
    q = (q or ""):lower()
    local out = {}
    for key in pairs(ns.Roster.All()) do
        if #out < n and q ~= "" and key:sub(1, #q) == q then out[#out + 1] = key end
    end
    table.sort(out)
    return out
end

-- What's typed, as a guildie: their exact name, else the first suggestion.
local function resolve(t)
    local exact = ns.key(t)
    if exact and ns.Roster.Get(exact) then return exact end
    return matching(t, 1)[1]
end

-- A guildie field: type a name (first names first, then last and RP
-- names) and pick one of the suggestions under it, or pick one from the
-- guild's list beside it (the arrow), A-Z. Enter takes the name typed, else
-- the first suggestion; leaving it puts back whoever is picked. Not being
-- typed in, it shows them in their RP name and colour (the Roleplay
-- settings, totalRP3), else the game's and their class's.
-- The Badge Inspector's "Inspected Moonwarden:" and Badge Management's
-- Guildie (OfficerUI.lua) are both this.
-- opts: current() -> the key picked now; onPick(key); onBlur() (after
-- leaving it); width, font (GameFontNormalLarge), height (26).
-- Returns { box, arrow, picks, SetKey(key) }: SetKey draws `key` in it
-- (nil: empty) unless it's being typed in.
function ns.GuildiePicker(parent, opts)
    opts = opts or {}
    local p = {}
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetHeight(opts.height or 26)
    if opts.width then box:SetWidth(opts.width) end
    box:SetAutoFocus(false)
    box:SetFontObject(opts.font or GameFontNormalLarge)
    local arrow = CreateFrame("Button", nil, parent)
    arrow:SetSize(24, 24)
    arrow:SetPoint("LEFT", box, "RIGHT", 2, 0)
    arrow:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
    arrow:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Down")
    arrow:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    p.box, p.arrow = box, arrow

    local function pick(key)
        if key and opts.onPick then opts.onPick(key) end
    end
    local picks = CreateFrame("Frame", nil, parent)
    picks:SetPoint("TOPLEFT", box, "BOTTOMLEFT", -6, -2)
    picks:SetSize(240, PICKS * 18 + 6)
    picks:SetFrameLevel(parent:GetFrameLevel() + 50)
    local bg = picks:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetColorTexture(0, 0, 0, 0.92)
    picks.rows = {}
    for i = 1, PICKS do
        local b = CreateFrame("Button", nil, picks)
        b:SetSize(234, 18)
        b:SetPoint("TOPLEFT", 3, -3 - (i - 1) * 18)
        local hl = b:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 0.82, 0, 0.18)
        b.text = K.text(b, "GameFontHighlight"); b.text:SetPoint("LEFT", 6, 0)
        b:SetScript("OnClick", function(self) box:ClearFocus(); pick(self.key) end)
        picks.rows[i] = b
    end
    picks:Hide()
    p.picks = picks
    local function show(q)
        local list = matching(q, PICKS)
        for i, b in ipairs(picks.rows) do
            local key = list[i]
            b.key = key
            if key then b.text:SetText(coloured(key)); b:Show() else b:Hide() end
        end
        picks:SetHeight(math.max(1, #list) * 18 + 6)
        picks:SetShown(#list > 0)
    end
    box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    box:SetScript("OnTextChanged", function(self, user) if user then show(self:GetText()) end end)
    box:SetScript("OnEnterPressed", function(self)
        local key = resolve(self:GetText())
        self:ClearFocus()
        pick(key)
    end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEditFocusLost", function()
        -- (a moment, so a click on a suggestion lands first; then theirs again)
        C_Timer.After(0.2, function()
            picks:Hide()
            p.SetKey(opts.current and opts.current())
            if opts.onBlur then opts.onBlur() end
        end)
    end)
    -- The guild's list, A-Z, beside it.
    arrow:SetScript("OnClick", function(self)
        if not (MenuUtil and MenuUtil.CreateContextMenu) then box:SetFocus(); return end
        local keys = {}
        for key in pairs(ns.Roster.All()) do keys[#keys + 1] = key end
        table.sort(keys, function(a, b) return K.nameOf(a):lower() < K.nameOf(b):lower() end)
        MenuUtil.CreateContextMenu(self, function(_, root)
            if root.SetScrollMode then pcall(root.SetScrollMode, root, 360) end
            for _, key in ipairs(keys) do
                root:CreateRadio(coloured(key), function(k) return k == (opts.current and opts.current()) end,
                    function(k) pick(k) end, key)
            end
        end)
    end)

    -- Their name and colour: the RP ones when the Roleplay settings are on
    -- and they have them (totalRP3), else the game's and their class's.
    function p.SetKey(key)
        if box:HasFocus() then return end
        if not key then box:SetText(""); return end
        local m = ns.Roster.Get(key)
        local r, g, b
        if ns.RP then r, g, b = ns.RP.Color(key) end
        if not r then r, g, b = ns.classColor(m and m.classFile) end
        box:SetText((ns.RP and ns.RP.Name(key)) or (m and m.name) or K.nameOf(key))
        box:SetCursorPosition(0)
        box:SetTextColor(r or 1, g or 0.82, b or 0)
    end
    return p
end

local function refresh()
    if not (f and f:IsShown() and who) then return end
    local mine = who == ns.meKey
    local result = mine and Badges.Mine() or Badges.Of(who)

    f.picker.SetKey(who)
    f.mine:SetEnabled(not mine)
    if f.sort then
        if f.sort.GenerateMenu then pcall(f.sort.GenerateMenu, f.sort) end
        if f.sort.OverrideText then pcall(f.sort.OverrideText, f.sort, sortText(sortId())) end
    end

    -- Their Showcase and Collection.
    local h = f.board:Fill(who, result, sortId())
    f.scroll.child:SetHeight(math.max(1, h + 8))
    if f.scroll:GetVerticalScroll() > f.scroll:Range() then f.scroll:SetVerticalScroll(f.scroll:Range()) end
    f.scroll:Sync()
end

function Chest.Refresh() refresh() end
function Chest.Picker() return f and f.picker end   -- (tests)

-- Open a guildie's chest (nil: mine). Open already: it shows them instead.
function Chest.Open(key)
    key = key or ns.meKey
    if not key then return end
    build()
    local changed = key ~= who
    who = key
    if key ~= ns.meKey then Badges.Request(key) end
    if changed then f.scroll:ScrollTo(0) end
    f:Show()
    f:Raise()
    PlaySound(SOUNDKIT and SOUNDKIT.IG_BACKPACK_OPEN or 862)
    refresh()
end

ns.onLogin(function()
    ns.listen("BADGES", function(key) if key == who then refresh() end end)
    ns.listen("LEDGER", function() refresh() end)
    ns.listen("RP", function() refresh() end)
end, "badge chest")
