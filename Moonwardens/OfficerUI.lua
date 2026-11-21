-- OfficerUI: the Officers tab of the guild window. Award Progress gives a
-- guildie progress toward a badge officers record (Patrols...), or any badge
-- outright; the Audit Log lists every badge event (Ledger.lua): who awarded
-- what to whom and why, and what each guildie's client claimed, with when
-- and on what. Approvals (of those claims) come later.
-- Laid out as the Stats tab: a list on the left, a page on the right.
-- Only officers see the tab, once Ledger.OPEN is off.
local _, ns = ...
local UI = ns.UI
local Badges = ns.Badges
local K = ns.BadgesUI.Kit
local OUI = {}
ns.OfficerUI = OUI

local CAT_H = 25
local LOG_ROW_H = 40
local NAV = {
    { id = "award", name = "Award Progress" },
    { id = "log", name = "Audit Log" },
    { id = "approvals", name = "Approvals", soon = true },
}

local state = { view = "award", who = nil, badge = nil, filter = "" }
local page

local function classHex(key)
    local m = key and ns.Roster.Get(key)
    local r, g, b = ns.classColor(m and m.classFile)
    return ("|cff%02x%02x%02x"):format(r * 255, g * 255, b * 255)
end

-- A guildie's name, class-coloured.
local function who(key)
    if not key then return "?" end
    return classHex(key) .. K.nameOf(key) .. "|r"
end

local function input(parent, w, numeric)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(w, 20)
    e:SetAutoFocus(false)
    if numeric then e:SetNumeric(true); e:SetMaxLetters(6) end
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    e:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    return e
end

-- How a guildie matches what's typed: 1 = first name starts with it (or the
-- full name, typed past the first name), 2 = last name or RP name starts
-- with it, nil = no match. Suggestions and the Audit Log filter both rank
-- by this: first names first, then the rest.
local function nameTier(key, q)
    if not key or q == "" then return nil end
    if key:sub(1, #q) == q then return 1 end
    for word in key:gmatch("%S+") do if word:sub(1, #q) == q then return 2 end end
    local rp = ns.RP and ns.RP.Name and ns.RP.Name(key)
    if type(rp) == "string" then
        local low = rp:lower()
        if low:sub(1, #q) == q then return 2 end
        for word in low:gmatch("%S+") do if word:sub(1, #q) == q then return 2 end end
    end
    return nil
end

local function trim(q) return ((q or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")) end

-- Guildies to suggest for what's typed: first names starting with it come
-- first (A-Z); only after those, last names (and RP names) starting with it.
local function matches(q, n)
    q = trim(q)
    if q == "" then return {} end
    local tiers = { {}, {} }
    for key in pairs(ns.Roster.All()) do
        local t = nameTier(key, q)
        if t then tiers[t][#tiers[t] + 1] = key end
    end
    local out = {}
    for _, list in ipairs(tiers) do
        table.sort(list)
        for _, k in ipairs(list) do if #out < n then out[#out + 1] = k end end
    end
    return out
end

---------------------------------------------------------------------------
-- Award Progress
---------------------------------------------------------------------------
local function badgeLabel(b)
    if not b then return "Pick a badge" end
    return Badges.Title(b)
end

local function buildAward(f, parent, w)
    local a = CreateFrame("Frame", nil, parent)
    a:SetPoint("TOPLEFT")
    a:SetSize(w, 400)

    a.head = K.newHeading(a, "Award Badge Progress")
    a.head:SetPoint("TOPLEFT", 4, -6)
    a.testing = K.text(a, "GameFontNormalSmall")
    a.testing:SetPoint("TOPLEFT", a.head, "BOTTOMLEFT", 0, -10)
    a.testing:SetWidth(w - 12)
    a.testing:SetTextColor(0.62, 0.62, 0.62)

    local function label(text, y)
        local l = K.text(a, "GameFontNormal")
        l:SetText(text)
        l:SetPoint("TOPLEFT", 8, y)
        return l
    end
    local X = 110

    -- Guildie: type a name; matches show under it to click.
    label("Guildie", -56)
    a.name = input(a, 200)
    a.name:SetPoint("TOPLEFT", X + 6, -52)
    a.nameState = K.text(a, "GameFontHighlight")
    a.nameState:SetPoint("LEFT", a.name, "RIGHT", 10, 0)
    a.picks = {}
    for i = 1, 5 do
        local b = CreateFrame("Button", nil, a)
        b:SetSize(200, 16)
        b:SetPoint("TOPLEFT", a.name, "BOTTOMLEFT", -4, -2 - (i - 1) * 16)
        b.hl = b:CreateTexture(nil, "HIGHLIGHT"); b.hl:SetAllPoints(); b.hl:SetColorTexture(1, 0.82, 0, 0.15)
        b.text = K.text(b, "GameFontHighlightSmall"); b.text:SetPoint("LEFT", 4, 0)
        b:SetFrameLevel(a:GetFrameLevel() + 20)
        b.bg = b:CreateTexture(nil, "BACKGROUND"); b.bg:SetAllPoints(); b.bg:SetColorTexture(0, 0, 0, 0.85)
        b:SetScript("OnClick", function(self)
            state.who = self.key
            a.name:SetText(K.nameOf(self.key))
            a.name:ClearFocus()
            OUI.Refresh()
        end)
        b:Hide()
        a.picks[i] = b
    end
    a.name:SetScript("OnTextChanged", function(self, user)
        if not user then return end
        local t = self:GetText() or ""
        local exact = ns.key(t)
        state.who = (exact and ns.Roster.Get(exact)) and exact or nil
        a.typed = t
        OUI.Refresh()
    end)
    a.name:SetScript("OnEditFocusLost", function() C_Timer.After(0.2, function() a.typed = nil; OUI.Refresh() end) end)

    -- Badge: the game's dropdown, grouped by category.
    label("Badge", -96)
    local okDD, dd = pcall(CreateFrame, "DropdownButton", nil, a, "WowStyle1DropdownTemplate")
    if okDD and dd and dd.SetupMenu then
        dd:SetWidth(280)
        dd:SetPoint("TOPLEFT", X, -90)
        if dd.SetDefaultText then dd:SetDefaultText("Pick a badge") end
        dd:SetupMenu(function(_, root)
            for _, top in ipairs(Badges.CATEGORIES) do
                for _, c in ipairs(top.children or {}) do
                    local list = Badges.InCategory(c.id)
                    if #list > 0 then
                        root:CreateTitle(top.name .. ": " .. c.name)
                        for _, b in ipairs(list) do
                            root:CreateRadio(Badges.Title(b), function(id) return state.badge == id end,
                                function(id) state.badge = id; OUI.Refresh() end, b.id)
                        end
                    end
                end
            end
        end)
        a.dropdown = dd
    else
        -- (no dropdown template: a button that goes through the badges)
        local b = CreateFrame("Button", nil, a, "UIPanelButtonTemplate")
        b:SetSize(280, 22)
        b:SetPoint("TOPLEFT", X + 2, -92)
        b:SetScript("OnClick", function()
            local list, at = Badges.LIST, 0
            for i, x in ipairs(list) do if x.id == state.badge then at = i end end
            state.badge = list[at % #list + 1].id
            OUI.Refresh()
        end)
        a.cycle = b
    end

    label("Progress", -136)
    a.amount = input(a, 60, true)
    a.amount:SetPoint("TOPLEFT", X + 6, -132)
    a.amount:SetScript("OnTextChanged", function(_, user) if user then OUI.Refresh() end end)
    a.amountNote = K.text(a, "GameFontHighlightSmall")
    a.amountNote:SetPoint("LEFT", a.amount, "RIGHT", 10, 0)
    a.amountNote:SetPoint("RIGHT", a, "RIGHT", -8, 0)

    label("Note", -172)
    a.note = input(a, w - X - 24)
    a.note:SetPoint("TOPLEFT", X + 6, -168)
    a.note:SetMaxLetters(80)
    a.noteHint = K.text(a, "GameFontDisableSmall")
    a.noteHint:SetPoint("TOPLEFT", a.note, "BOTTOMLEFT", -4, -3)
    a.noteHint:SetText("Why: which patrol, what they did. Everyone can read it in the Audit Log.")

    -- Where they stand, and what this would do.
    a.card = CreateFrame("Frame", nil, a)
    a.card:SetPoint("TOPLEFT", 4, -214)
    a.card:SetPoint("RIGHT", a, "RIGHT", -4, 0)
    a.card:SetHeight(74)
    a.card.bg = a.card:CreateTexture(nil, "BACKGROUND"); a.card.bg:SetAllPoints()
    if not K.atlas(a.card.bg, "Legacy-Challenge-Cards-Bar") then a.card.bg:SetColorTexture(0.15, 0.12, 0.08, 0.8) end
    a.card.icon = K.newIcon(a.card, 46)
    a.card.icon:SetPoint("LEFT", 10, 0)
    a.card.title = K.text(a.card, "GameFontHighlight")
    a.card.title:SetPoint("TOPLEFT", a.card.icon, "TOPRIGHT", 12, -2)
    a.card.bar = K.newBar(a.card, 16)
    a.card.bar:SetPoint("TOPLEFT", a.card.title, "BOTTOMLEFT", 4, -8)
    a.card.bar:SetPoint("RIGHT", a.card, "RIGHT", -16, 0)
    a.card.after = K.text(a.card, "GameFontNormalSmall")
    a.card.after:SetPoint("TOPLEFT", a.card.bar, "BOTTOMLEFT", -4, -6)

    a.add = CreateFrame("Button", nil, a, "UIPanelButtonTemplate")
    a.add:SetSize(140, 24)
    a.add:SetPoint("TOPLEFT", 8, -300)
    a.add:SetText("Add Progress")
    a.grant = CreateFrame("Button", nil, a, "UIPanelButtonTemplate")
    a.grant:SetSize(140, 24)
    a.grant:SetPoint("LEFT", a.add, "RIGHT", 10, 0)
    a.grant:SetText("Grant Badge")
    a.result = K.text(a, "GameFontHighlight")
    a.result:SetPoint("LEFT", a.grant, "RIGHT", 12, 0)
    a.result:SetPoint("RIGHT", a, "RIGHT", -8, 0)

    local function done(e, err)
        if e then
            a.result:SetText("|cff1eff00Logged.|r")
            a.amount:SetText("")
            a.note:SetText("")
        else
            a.result:SetText("|cffff4040" .. (err or "Not logged.") .. "|r")
        end
        a.confirm = nil
        OUI.Refresh()
    end
    a.add:SetScript("OnClick", function()
        done(ns.Ledger.Award(state.who, state.badge, tonumber(a.amount:GetText()) or 0, a.note:GetText()))
    end)
    -- Granting outright asks twice.
    a.grant:SetScript("OnClick", function(self)
        if a.confirm and GetTime() - a.confirm < 4 then
            done(ns.Ledger.Award(state.who, state.badge, 0, a.note:GetText()))
        else
            a.confirm = GetTime()
            a.result:SetText("|cffffd100Click again to grant it.|r")
            C_Timer.After(4, function() if a.confirm and GetTime() - a.confirm >= 4 then a.confirm = nil; OUI.Refresh() end end)
        end
    end)

    f.award = a
    return a
end

local function fillAward(f)
    local a = f.award
    if ns.Ledger.Testing() then
        a.testing:SetText("|cffff8040TEST MODE|r - awards you make here stay on this client and are never sent to the guild. /mw test off to leave, /mw test clear to wipe them.")
    else
        a.testing:SetText("Every award is logged with your name, in the Audit Log.")
    end

    -- Name field: state, and matches while typing.
    if state.who then
        a.nameState:SetText(who(state.who))
        if not a.name:HasFocus() and (a.name:GetText() or "") == "" then a.name:SetText(K.nameOf(state.who)) end
    elseif (a.name:GetText() or "") ~= "" then
        a.nameState:SetText("|cff9d9d9dNo guildie by that name|r")
    else
        a.nameState:SetText("")
    end
    local list = (a.typed and not state.who) and matches(a.typed, #a.picks) or {}
    for i, b in ipairs(a.picks) do
        local key = list[i]
        if key then b.key = key; b.text:SetText(who(key)); b:Show() else b:Hide() end
    end

    local b = state.badge and Badges.Get(state.badge)
    if a.dropdown and a.dropdown.GenerateMenu then pcall(a.dropdown.GenerateMenu, a.dropdown) end
    if a.cycle then a.cycle:SetText(badgeLabel(b)) end

    local manual = b and b.kind == "manual"
    if not b then
        a.amountNote:SetText("|cff9d9d9dPick a Patrol badge to add progress.|r")
    elseif manual then
        a.amountNote:SetText("patrols to add")
    else
        a.amountNote:SetText("|cff9d9d9dThe addon counts this one itself; it can only be granted.|r")
    end

    local ready = state.who and b
    a.card:SetShown(ready and true or false)
    if ready then
        local r = Badges.Of(state.who)
        local e = r.badges[b.id]
        K.setBadgeIcon(a.card.icon, b, e.times > 0)
        a.card.title:SetText(("%s - %s"):format(who(state.who), Badges.Title(b)))
        a.card.bar:Set(e.value, e.goal)
        local add = tonumber(a.amount:GetText()) or 0
        if manual and add > 0 then
            local after = math.min(e.goal, e.value + add)
            a.card.after:SetText(("After this: %s / %s%s"):format(K.commas(after), K.commas(e.goal),
                (e.times == 0 and after >= e.goal) and "  |cff1eff00- earns the badge|r" or ""))
        elseif e.times > 0 then
            a.card.after:SetText(b.kind == "weekly" and ("Earned %d times."):format(e.times) or "Already earned.")
        else
            a.card.after:SetText(manual and "Enter how many to add." or "Not earned yet.")
        end
    end
    a.add:SetEnabled((ready and manual and (tonumber(a.amount:GetText()) or 0) > 0) and true or false)
    a.grant:SetEnabled(ready and true or false)
    if not a.confirm and a.result:GetText() and a.result:GetText():find("Click again") then a.result:SetText("") end
    return 340
end

---------------------------------------------------------------------------
-- Audit Log
---------------------------------------------------------------------------
local function describe(e)
    local b = Badges.Get(e.badge)
    local title = b and Badges.Title(b) or e.badge
    local line, meta
    if e.kind == "award" then
        if (e.n or 0) > 0 then
            line = ("%s gave %s |cffffffff+%d|r toward %s"):format(who(e.by), who(e.who), e.n, title)
        else
            line = ("%s granted %s %s"):format(who(e.by), who(e.who), title)
        end
        meta = (e.note and e.note ~= "") and ("\"" .. e.note .. "\"") or "No note."
    else
        line = ("%s earned %s%s"):format(who(e.who), title, b and b.kind == "weekly" and (" (x%d)"):format(e.n or 1) or "")
        local bits = { "Claimed by their addon" }
        if e.week and e.week > 0 then bits[#bits + 1] = "week of " .. Badges.WeekDate(e.week) end
        if e.value and e.value > 0 then bits[#bits + 1] = K.commas(e.value) .. " kills" end
        if e.version and e.version ~= "" then bits[#bits + 1] = "v" .. e.version end
        meta = table.concat(bits, "  -  ")
    end
    return line, meta, b
end

local function newLogRow(parent)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(LOG_ROW_H - 3)
    r.bg = r:CreateTexture(nil, "BACKGROUND"); r.bg:SetAllPoints()
    if not K.atlas(r.bg, "Legacy-Challenge-Cards-Bar") then r.bg:SetColorTexture(0.15, 0.12, 0.08, 0.8) end
    r.icon = K.newIcon(r, 28)
    r.icon:SetPoint("LEFT", 6, 0)
    r.when = K.text(r, "GameFontNormalSmall")
    r.when:SetPoint("TOPRIGHT", -10, -6)
    r.when:SetJustifyH("RIGHT")
    r.line = K.text(r, "GameFontHighlight")
    r.line:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 10, 2)
    r.line:SetPoint("RIGHT", r.when, "LEFT", -8, 0)
    r.line:SetWordWrap(false)
    r.meta = K.text(r, "GameFontDisableSmall")
    r.meta:SetPoint("TOPLEFT", r.line, "BOTTOMLEFT", 0, -3)
    r.meta:SetPoint("RIGHT", r, "RIGHT", -10, 0)
    r.meta:SetWordWrap(false)
    r.kind = K.text(r, "GameFontNormalSmall")
    r.kind:SetPoint("BOTTOMRIGHT", -10, 5)
    return r
end

local function fillLog(f)
    local child = f.scroll.child
    -- Filtering ranks as the Guildie suggestions do: events with someone
    -- whose first name starts with it (guildie or officer), newest first;
    -- then last names / RP names; then badge names and notes that have it.
    local q = trim(state.filter)
    local list
    if q == "" then
        list = ns.Ledger.Events()
    else
        local tiers = { {}, {}, {} }
        for _, e in ipairs(ns.Ledger.Events()) do
            local t = math.min(nameTier(e.who, q) or 9, nameTier(e.by, q) or 9)
            if t > 2 then
                local b = Badges.Get(e.badge)
                local text = ((b and Badges.Title(b) or "") .. " " .. (e.note or "")):lower()
                if text:find(q, 1, true) then t = 3 end
            end
            if tiers[t] then tiers[t][#tiers[t] + 1] = e end
        end
        list = {}
        for _, tl in ipairs(tiers) do for _, e in ipairs(tl) do list[#list + 1] = e end end
    end
    f.logHead:SetText(("Audit Log  |cff9d9d9d%d event%s|r"):format(#list, #list == 1 and "" or "s"))
    local y = 32
    for i, e in ipairs(list) do
        local r = f.logRows[i]
        if not r then r = newLogRow(child); f.logRows[i] = r end
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
        r:SetPoint("RIGHT", child, "RIGHT", 0, 0)
        local line, meta, b = describe(e)
        if b then K.setBadgeIcon(r.icon, b, true) end
        r.line:SetText(line)
        r.meta:SetText(meta)
        r.when:SetText(date("%m/%d/%y %H:%M", e.at))
        r.kind:SetText(e.test and "|cffff8040Test|r" or e.kind == "award" and "|cffffd100Officer|r" or "|cff9d9d9dAutomatic|r")
        r:Show()
        y = y + LOG_ROW_H
    end
    for i = #list + 1, #f.logRows do f.logRows[i]:Hide() end
    f.logEmpty:SetShown(#list == 0)
    f.logEmpty:SetText(q ~= "" and "Nothing matches." or "Nothing logged yet.")
    return math.max(y, 80)
end

---------------------------------------------------------------------------
-- The page
---------------------------------------------------------------------------
local function build(f)
    page = f
    -- (the section open is kept across closing and reloads)
    ns.db.officerUI = ns.db.officerUI or {}
    if ns.db.officerUI.view then state.view = ns.db.officerUI.view end
    local W = f:GetWidth()
    if not W or W < 100 then W = 528 end
    f.catW = math.floor(math.min(210, W * 0.28))

    f.nav = {}
    for i, c in ipairs(NAV) do
        local b = K.newCatButton(f, f.catW)
        b:SetPoint("TOPLEFT", 4, -32 - (i - 1) * CAT_H)
        b:SetScript("OnClick", function(self)
            if self.soon then return end
            PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
            state.view = self.id
            ns.db.officerUI.view = self.id
            OUI.Refresh()
            f.scroll:ScrollTo(0)
        end)
        f.nav[i] = b
    end
    f.navHead = K.bump(K.text(f, "Game15Font_Shadow"))
    f.navHead:SetTextColor(1, 0.82, 0)
    f.navHead:SetPoint("TOPLEFT", 12, -8)
    f.navHead:SetText("Officers")

    f.divider = f:CreateTexture(nil, "ARTWORK")
    f.divider:SetPoint("TOPLEFT", f.catW + 8, 4)
    f.divider:SetPoint("BOTTOMLEFT", f.catW + 8, -4)
    f.divider:SetWidth(12)
    if not K.atlas(f.divider, "Legacy-Tree-Frame-divider-Vertical") then f.divider:SetColorTexture(0.4, 0.32, 0.15, 0.6); f.divider:SetWidth(1) end

    local left = f.catW + 24
    local cw = W - left - 20
    f.scroll = K.newScroll(f)
    f.scroll:SetPoint("TOPLEFT", left, -2)
    f.scroll:SetPoint("BOTTOMRIGHT", -20, 2)
    f.scroll.child:SetWidth(cw)
    buildAward(f, f.scroll.child, cw)

    -- Audit Log: a filter box, then the rows.
    f.logHead = K.bump(K.text(f.scroll.child, "Game15Font_Shadow"))
    f.logHead:SetTextColor(1, 0.82, 0)
    f.logHead:SetPoint("TOPLEFT", 4, -8)
    local okS, sb = pcall(CreateFrame, "EditBox", nil, f.scroll.child, "SearchBoxTemplate")
    if not okS or not sb then sb = CreateFrame("EditBox", nil, f.scroll.child, "InputBoxTemplate") end
    sb:SetSize(220, 20)
    sb:SetPoint("TOPRIGHT", -6, -4)
    sb:SetAutoFocus(false)
    if sb.Instructions then sb.Instructions:SetText("Filter: name, badge, note") end
    sb:HookScript("OnTextChanged", function(self)
        local t = (self:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if t ~= state.filter then state.filter = t; OUI.Refresh() end
    end)
    f.logFilter = sb
    f.logRows = {}
    f.logEmpty = K.text(f.scroll.child, "GameFontDisable")
    f.logEmpty:SetPoint("TOP", 0, -60)
end

local function refresh(f)
    page = f
    for i, c in ipairs(NAV) do K.styleCatButton(f.nav[i], c, false, state.view == c.id) end
    local h
    local isLog = state.view == "log"
    f.award:SetShown(not isLog)
    f.logHead:SetShown(isLog)
    f.logFilter:SetShown(isLog)
    if isLog then
        h = fillLog(f)
    else
        for _, r in ipairs(f.logRows) do r:Hide() end
        f.logEmpty:Hide()
        h = fillAward(f)
    end
    f.scroll.child:SetHeight(h)
    if f.scroll:GetVerticalScroll() > f.scroll:Range() then f.scroll:SetVerticalScroll(f.scroll:Range()) end
    f.scroll:Sync()
end

function OUI.Refresh()
    if page and page:IsVisible() then refresh(page) end
end

-- Open Award Progress for a guildie (the right-click menu).
function OUI.Open(key)
    state.view = "award"
    if ns.db then ns.db.officerUI = ns.db.officerUI or {}; ns.db.officerUI.view = "award" end
    state.who = key
    if page and page.award then page.award.name:SetText(key and K.nameOf(key) or "") end
    if ns.GuildTabs and ns.GuildTabs.Available() and CommunitiesFrame and CommunitiesFrame:IsShown() then
        ns.GuildTabs.Select(6)
    else
        ns.ToggleWindow(6)
    end
    OUI.Refresh()
end

UI.AddPage(6, "Officers", build, refresh,
    { order = 3, icon = { "INV_Misc_Note_06", "INV_Scroll_03" }, tooltip = "Officers",
      bgAtlas = "Legacy-Rewards-Tracker-background",
      visible = function() return ns.Ledger and ns.Ledger.CanAward() end })

ns.onLogin(function()
    ns.listen("LEDGER", function() OUI.Refresh() end)
    ns.listen("ROSTER", function() OUI.Refresh() end)
end, "officer ui")
