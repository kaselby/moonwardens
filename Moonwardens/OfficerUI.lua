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
    { id = "approvals", name = "Approvals" },
}

-- (Award Progress: `section` a subsection's id, `entry` a badge in it - a
-- tier track's id, or a badge's - and `badge` the badge itself, its tier)
local state = { view = "award", who = nil, section = nil, entry = nil, badge = nil, filter = "" }
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

OUI.Matches = matches        -- (the Badge Chest's name field too)

---------------------------------------------------------------------------
-- Award Progress
---------------------------------------------------------------------------
local function badgeLabel(b)
    if not b then return "Pick a badge" end
    return Badges.Coin(b) .. Badges.Title(b)
end

-- What can be awarded in a subsection: one entry per badge, a tier track
-- as one ({ id, name, icon, tiers } - its tiers are picked under Progress),
-- else { id, name, icon, badge }. Only what I may award, and nothing
-- switched off or from past months.
local function entriesOf(cat)
    local out, byTrack = {}, {}
    for _, b in ipairs(Badges.Grantable(cat)) do
        local past = (b.parent and b.month ~= Badges.BOUNTY.month) or Badges.CategorySoon(b.cat)
        if not past and ns.Ledger.CanAward(nil, b.id) then
            if b.track then
                local en = byTrack[b.track]
                if not en then
                    en = { id = b.track, name = Badges.Title(b), icon = b.icon, tiers = {} }
                    byTrack[b.track] = en
                    out[#out + 1] = en
                end
                en.tiers[#en.tiers + 1] = b
            else
                out[#out + 1] = { id = b.id, name = Badges.Title(b), icon = b.icon, badge = b }
            end
        end
    end
    for _, en in ipairs(out) do
        if en.tiers then table.sort(en.tiers, function(x, y) return Badges.TIER_ORDER[x.tier] < Badges.TIER_ORDER[y.tier] end) end
    end
    return out
end

local function sectionLabel(id)
    for _, p in ipairs(Badges.Pages()) do
        if p.id == id then return p.top and (p.top .. " > " .. p.name) or p.name end
    end
end

local function currentEntry()
    if not (state.section and state.entry) then return nil end
    for _, en in ipairs(entriesOf(state.section)) do if en.id == state.entry then return en end end
end

local function iconText(icon, size)
    local n = type(icon) == "table" and icon[1] or icon
    -- (the first the game has)
    if type(icon) == "table" and K.iconExists then
        for _, x in ipairs(icon) do if K.iconExists("Interface\\Icons\\" .. x) then n = x; break end end
    end
    return n and ("|TInterface\\Icons\\%s:%d:%d|t "):format(n, size or 16, size or 16) or ""
end

-- A menu entry's tooltip: a title, then lines.
local function menuTip(desc, title, lines)
    if not (desc and desc.SetTooltip) then return end
    pcall(desc.SetTooltip, desc, function(tt)
        tt:SetText(title, 1, 0.82, 0)
        for _, l in ipairs(lines) do tt:AddLine(l, 1, 1, 1, true) end
    end)
end

local function pickSection(id)
    state.section, state.entry, state.badge = id, nil, nil
    OUI.Refresh()
end

-- A badge picked: itself; a track: the tier they're on (the next to earn).
local function pickEntry(id)
    state.entry, state.badge = id, nil
    local en = currentEntry()
    if en and en.badge then
        state.badge = en.badge.id
    elseif en and en.tiers then
        local pick = en.tiers[1]
        if state.who then
            local st = Badges.TrackState(en.id, Badges.Of(state.who))
            for _, b in ipairs(en.tiers) do if st and st.current == b then pick = b end end
        end
        state.badge = pick and pick.id
    end
    OUI.Refresh()
end

local function buildAward(f, parent, w)
    local a = CreateFrame("Frame", nil, parent)
    a:SetPoint("TOPLEFT")
    a:SetSize(w, 440)

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

    -- What to award, in three steps: a section (category > subsection), a
    -- badge in it (a tier track is one), and - a track's - its tier, by
    -- Progress. Each is the game's dropdown.
    local function dropdown(width, x, y, default)
        local ok, dd = pcall(CreateFrame, "DropdownButton", nil, a, "WowStyle1DropdownTemplate")
        if not (ok and dd and dd.SetupMenu) then return nil end
        dd:SetWidth(width)
        dd:SetPoint("TOPLEFT", x, y)
        if dd.SetDefaultText then dd:SetDefaultText(default) end
        return dd
    end
    label("Section", -96)
    a.section = dropdown(280, X, -90, "Pick a section")
    label("Badge", -136)
    a.badge = dropdown(280, X, -130, "Pick a badge")
    if a.section and a.badge then
        a.section:SetupMenu(function(_, root)
            local function isPicked(id) return state.section == id end
            for _, top in ipairs(Badges.CATEGORIES) do
                if top.children then
                    local subs = {}
                    for _, c in ipairs(top.children) do
                        if #entriesOf(c.id) > 0 then subs[#subs + 1] = c end
                    end
                    if #subs > 0 then
                        local sub = root:CreateButton(top.name)
                        for _, c in ipairs(subs) do sub:CreateRadio(c.name, isPicked, pickSection, c.id) end
                    end
                elseif #entriesOf(top.id) > 0 then
                    root:CreateRadio(top.name, isPicked, pickSection, top.id)
                end
            end
        end)
        a.badge:SetupMenu(function(_, root)
            if not state.section then root:CreateTitle("Pick a section first"); return end
            for _, en in ipairs(entriesOf(state.section)) do
                local r = root:CreateRadio(iconText(en.icon) .. en.name, function(id) return state.entry == id end, pickEntry, en.id)
                local lines = {}
                if en.tiers then
                    for _, b in ipairs(en.tiers) do lines[#lines + 1] = Badges.Coin(b) .. b.desc end
                else
                    lines[1] = en.badge.desc
                end
                menuTip(r, en.name, lines)
            end
        end)
        a.dropdown = a.badge
    else
        -- (no dropdown template: a button that goes through the badges)
        if a.section then a.section:Hide() end
        if a.badge then a.badge:Hide() end
        a.section, a.badge = nil, nil
        local b = CreateFrame("Button", nil, a, "UIPanelButtonTemplate")
        b:SetSize(280, 22)
        b:SetPoint("TOPLEFT", X + 2, -132)
        b:SetScript("OnClick", function()
            local list, at = Badges.LIST, 0
            for i, x in ipairs(list) do if x.id == state.badge then at = i end end
            state.badge = list[at % #list + 1].id
            OUI.Refresh()
        end)
        a.cycle = b
    end

    label("Progress", -176)
    -- (a track's tier: only for a track)
    a.tier = dropdown(150, X, -170, "Pick a tier")
    if a.tier then
        a.tier:SetupMenu(function(_, root)
            local en = currentEntry()
            for _, b in ipairs(en and en.tiers or {}) do
                local r = root:CreateRadio(Badges.Coin(b) .. Badges.TierName(b), function(id) return state.badge == id end,
                    function(id) state.badge = id; OUI.Refresh() end, b.id)
                menuTip(r, Badges.TierName(b), { b.desc })
            end
        end)
    end
    a.amount = input(a, 60, true)
    a.amount:SetPoint("TOPLEFT", X + 6, -172)
    a.amount:SetScript("OnTextChanged", function(_, user) if user then OUI.Refresh() end end)
    a.amountNote = K.text(a, "GameFontHighlightSmall")
    a.amountNote:SetPoint("LEFT", a.amount, "RIGHT", 10, 0)
    a.amountNote:SetPoint("RIGHT", a, "RIGHT", -8, 0)

    label("Note", -212)
    a.note = input(a, w - X - 24)
    a.note:SetPoint("TOPLEFT", X + 6, -208)
    a.note:SetMaxLetters(80)
    a.noteHint = K.text(a, "GameFontDisableSmall")
    a.noteHint:SetPoint("TOPLEFT", a.note, "BOTTOMLEFT", -4, -3)
    a.noteHint:SetText("Why: which patrol, what they did. Needed to remove or revoke. Shown in the Audit Log.")

    -- Where they stand, and what this would do.
    a.card = CreateFrame("Frame", nil, a)
    a.card:SetPoint("TOPLEFT", 4, -254)
    a.card:SetPoint("RIGHT", a, "RIGHT", -4, 0)
    a.card:SetHeight(96)
    a.card.bg = a.card:CreateTexture(nil, "BACKGROUND"); a.card.bg:SetAllPoints()
    if not K.atlas(a.card.bg, "Legacy-Challenge-Cards-Bar") then a.card.bg:SetColorTexture(0.15, 0.12, 0.08, 0.8) end
    a.card.icon = K.newIcon(a.card, 46)
    a.card.icon:SetPoint("LEFT", 10, 0)
    a.card.title = K.text(a.card, "GameFontHighlight")
    a.card.title:SetPoint("TOPLEFT", a.card, "TOPLEFT", 68, -12)
    a.card.desc = K.text(a.card, "GameFontHighlightSmall")             -- (what it takes)
    a.card.desc:SetPoint("TOPLEFT", a.card.title, "BOTTOMLEFT", 0, -4)
    a.card.desc:SetPoint("RIGHT", a.card, "RIGHT", -16, 0)
    a.card.desc:SetWordWrap(true)
    a.card.bar = K.newBar(a.card, 16)
    a.card.bar:SetPoint("TOPLEFT", a.card.desc, "BOTTOMLEFT", 4, -6)
    a.card.bar:SetPoint("RIGHT", a.card, "RIGHT", -16, 0)
    a.card.after = K.text(a.card, "GameFontNormalSmall")
    a.card.after:SetPoint("TOPLEFT", a.card.bar, "BOTTOMLEFT", -4, -6)

    -- Add / Remove progress, Grant / Revoke the badge. Each asks twice: the
    -- first click says what it will do, a second within 4 s does it.
    local bw = math.floor((w - 16 - 3 * 8) / 4)
    local function button(label, prev)
        local b = CreateFrame("Button", nil, a, "UIPanelButtonTemplate")
        b:SetSize(bw, 24)
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 8, 0) else b:SetPoint("TOPLEFT", 8, -362) end
        b:SetText(label)
        return b
    end
    a.add = button("Add Progress")
    a.remove = button("Remove Progress", a.add)
    a.grant = button("Grant Badge", a.remove)
    a.revoke = button("Revoke Badge", a.grant)
    a.result = K.text(a, "GameFontHighlight")
    a.result:SetPoint("TOPLEFT", a.add, "BOTTOMLEFT", 0, -10)
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
    local function twice(btn, ask, act)
        btn:SetScript("OnClick", function()
            local c = a.confirm
            if c and c.btn == btn and GetTime() - c.at < 4 then
                done(act())
            else
                local text = ask()
                if not text then return end
                a.confirm = { btn = btn, at = GetTime() }
                a.result:SetText("|cffffd100" .. text .. " Click again to confirm.|r")
                C_Timer.After(4, function()
                    if a.confirm and a.confirm.btn == btn and GetTime() - a.confirm.at >= 4 then a.confirm = nil; OUI.Refresh() end
                end)
            end
        end)
    end
    local function amount() return math.max(0, math.floor(tonumber(a.amount:GetText()) or 0)) end
    local function title() local b = Badges.Get(state.badge); return b and (Badges.Coin(b) .. Badges.Title(b)) or "" end
    twice(a.add, function() return ("Add %d to %s's %s?"):format(amount(), K.nameOf(state.who), title()) end,
        function() return ns.Ledger.Award(state.who, state.badge, amount(), a.note:GetText()) end)
    twice(a.remove, function() return ("Take %d away from %s's %s?"):format(amount(), K.nameOf(state.who), title()) end,
        function() return ns.Ledger.Award(state.who, state.badge, -amount(), a.note:GetText()) end)
    twice(a.grant, function() return ("Grant %s %s?"):format(K.nameOf(state.who), title()) end,
        function() return ns.Ledger.Award(state.who, state.badge, 0, a.note:GetText()) end)
    twice(a.revoke, function()
        return ("Revoke %s from %s (the latest time it was given)?"):format(title(), K.nameOf(state.who))
    end, function()
        local e = ns.Ledger.LatestGiving(state.who, state.badge)
        if not e then return nil, "Nothing to revoke: no grant or claim of it still counts." end
        return ns.Ledger.Revoke(e.id, a.note:GetText())
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
    -- The three dropdowns: what's picked, and the tier only for a track.
    local en = currentEntry()
    for _, dd in ipairs({ a.section, a.badge, a.tier }) do
        if dd.GenerateMenu then pcall(dd.GenerateMenu, dd) end
    end
    if a.section and a.section.OverrideText then
        pcall(a.section.OverrideText, a.section, state.section and sectionLabel(state.section) or "Pick a section")
    end
    if a.badge and a.badge.OverrideText then
        pcall(a.badge.OverrideText, a.badge, en and (iconText(en.icon) .. en.name) or (state.section and "Pick a badge" or "Pick a section first"))
    end
    if a.badge then a.badge:SetEnabled(state.section and true or false) end
    local tiered = a.tier and en and en.tiers and true or false
    if a.tier then
        a.tier:SetShown(tiered)
        if tiered and a.tier.OverrideText then
            pcall(a.tier.OverrideText, a.tier, b and (Badges.Coin(b) .. Badges.TierName(b)) or "Pick a tier")
        end
    end
    a.amount:ClearAllPoints()
    if tiered then a.amount:SetPoint("LEFT", a.tier, "RIGHT", 14, 0) else a.amount:SetPoint("TOPLEFT", 116, -172) end
    if a.cycle then a.cycle:SetText(badgeLabel(b)) end

    local manual = b and (b.kind == "manual" or b.kind == "manualweekly")
    if not b then
        a.amountNote:SetText("|cff9d9d9dPick a badge.|r")
    elseif manual then
        a.amountNote:SetText("patrols to add or remove")
    elseif b.kind == "granted" then
        a.amountNote:SetText("|cff9d9d9dGranted only: use Grant Badge.|r")
    elseif b.kind == "rank" then
        a.amountNote:SetText(("|cff9d9d9dComes with the rank of %s; grant it only to fix a mistake.|r"):format(b.rank))
    else
        a.amountNote:SetText("|cff9d9d9dThe addon counts this one itself; it can only be granted or revoked.|r")
    end

    local ready = state.who and b
    a.card:SetShown(ready and true or false)
    if ready then
        local r = Badges.Of(state.who)
        local e = r.badges[b.id]
        K.setBadgeIcon(a.card.icon, b, e.times > 0)
        a.card.title:SetText(("%s - %s%s"):format(who(state.who), Badges.Coin(b), Badges.Title(b)))
        a.card.desc:SetText(b.desc or "")
        if b.kind == "granted" or b.kind == "rank" then
            a.card.bar:Set(e.times > 0 and 1 or 0, 1, e.times > 0 and ("Earned x%d"):format(e.times) or "Not earned")
        else
            a.card.bar:Set(e.value, e.goal)
        end
        local add = tonumber(a.amount:GetText()) or 0
        local have = math.max(0, ns.Ledger.ManualFor(state.who).progress[Badges.CounterOf(b)] or 0)
        if manual and add > 0 then
            local up, down = have + add, math.max(0, have - add)
            a.card.after:SetText(("Add: %s / %s%s     Remove: %s / %s%s"):format(
                K.commas(math.min(up, e.goal)), K.commas(e.goal),
                (have < e.goal and up >= e.goal) and " |cff1eff00(earns it)|r" or "",
                K.commas(math.min(down, e.goal)), K.commas(e.goal),
                (have >= e.goal and down < e.goal) and " |cffff4040(loses it)|r" or ""))
        elseif e.times > 0 then
            a.card.after:SetText((b.kind == "weekly" or b.kind == "selfcount" or b.stack) and ("Earned %d time%s."):format(e.times, e.times == 1 and "" or "s")
                or "Already earned.")
        else
            a.card.after:SetText(manual and "Enter how many to add." or "Not earned yet.")
        end
    end
    local n = tonumber(a.amount:GetText()) or 0
    local have = (ready and manual) and (ns.Ledger.ManualFor(state.who).progress[Badges.CounterOf(b)] or 0) or 0
    a.add:SetEnabled((ready and manual and n > 0) and true or false)
    a.remove:SetEnabled((ready and manual and n > 0 and have > 0) and true or false)
    a.grant:SetEnabled(ready and true or false)
    a.revoke:SetEnabled((ready and ns.Ledger.LatestGiving(state.who, b.id)) and true or false)
    if not a.confirm and a.result:GetText() and a.result:GetText():find("Click again") then a.result:SetText("") end
    return 420
end

---------------------------------------------------------------------------
-- Audit Log
---------------------------------------------------------------------------
local function describe(e)
    local id = Badges.Resolve(e)
    local b = Badges.Get(id)
    -- (its name, and its id after it: "Wrath of the Kaldorei (lt2)")
    local title = (b and (Badges.Title(b) .. " ") or "") .. "|cff9d9d9d(" .. tostring(id) .. ")|r"
    local line, meta
    local function quote(s) return (s and s ~= "") and ("\"" .. s .. "\"") or "No note." end
    if e.kind == "award" then
        if (e.n or 0) > 0 then
            line = ("%s gave %s |cffffffff+%d|r toward %s"):format(who(e.by), who(e.who), e.n, title)
        elseif (e.n or 0) < 0 then
            line = ("%s took |cffffffff%d|r from %s's %s"):format(who(e.by), -e.n, who(e.who), title)
        else
            line = ("%s granted %s %s"):format(who(e.by), who(e.who), title)
            if b and b.level then line = line .. (" (Lv %d)"):format(b.level) end
        end
        meta = quote(e.note)
        if e.ref then meta = meta .. "  -  from a logged hunt" end
    elseif e.kind == "request" then
        if b and b.autoRequest == "rank" then
            line = ("%s reached the rank of |cffffffff%s|r (asks for %s)"):format(who(e.who), b.rank or "?", Badges.Title(b))
        else
            line = ("%s reported a patrol: |cffffffff%s|r"):format(who(e.who), e.value and ns.Dialog.When(e.value) or "time not given")
        end
        local d = ns.Ledger.DecisionOf(e.id)
        if not d then line = line .. "  |cffffd100waiting|r"
        elseif d.kind == "deny" then line = line .. "  |cffff4040denied|r"
        else line = line .. "  |cff1eff00approved|r" end
        meta = ("Reported %s"):format(ns.Dialog.When(e.at))
            .. (d and ("  -  %s by %s"):format(d.kind == "deny" and "Denied" or "Approved", K.nameOf(d.by)) or "")
    elseif e.kind == "deny" then
        local r = ns.Ledger.Find(e.ref)
        if b and b.autoRequest == "rank" then
            line = ("%s denied %s's %s badge"):format(who(e.by), who(e.who), Badges.Title(b))
        else
            line = ("%s denied %s's patrol of %s"):format(who(e.by), who(e.who), r and r.value and ns.Dialog.When(r.value) or "?")
        end
        meta = quote(e.note)
    elseif e.kind == "hunt" then
        local t = b and b.target
        line = ("%s hunted %s%s"):format(who(e.who), t and ("Lv %d %s"):format(b.level, t.name) or "a Hunt Target",
            (e.n or 0) == 1 and "  |cff1eff00passed|r" or "  |cffff4040failed checks|r")
        local g = ns.Ledger.GrantFor(e.id)
        meta = (g and ("Granted by %s.  "):format(K.nameOf(g.by)) or "") .. (e.note or "")
    elseif e.kind == "revoke" then
        local t = ns.Ledger.Find(e.ref)
        local what = not t and "an entry" or t.kind == "claim" and "a claim of"
            or (t.n or 0) > 0 and ("+%d toward"):format(t.n) or (t.n or 0) < 0 and ("-%d from"):format(-t.n) or "the grant of"
        line = ("%s revoked %s %s's %s"):format(who(e.by), what, who(e.who), title)
        meta = quote(e.note) .. (t and ("  -  that entry was " .. date("%m/%d/%y %H:%M", t.at)) or "")
    else
        line = ("%s earned %s%s"):format(who(e.who), title, b and b.kind == "weekly" and (" (x%d)"):format(e.n or 1) or "")
        local bits = { "Claimed by their addon" }
        if e.week and e.week > 0 then bits[#bits + 1] = "week of " .. Badges.WeekDate(e.week) end
        if e.value and e.value > 0 then
            local what = ({ captures = " capture points", outposts = " outposts", forts = " forts", victory = " victories",
                ashenvale_outposts = " Ashenvale outposts", shobekaran = " Shobek'Aran captures",
                lesi_cave = " Lesi's Bear Cave captures" })[b and b.series or ""]
            bits[#bits + 1] = K.commas(e.value) .. (what or " kills")
        end
        if e.version and e.version ~= "" then bits[#bits + 1] = "v" .. e.version end
        meta = table.concat(bits, "  -  ")
    end
    local rv = e.kind ~= "revoke" and ns.Ledger.RevokeOf(e.id)
    if rv then
        line = "|cff9d9d9d" .. line:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") .. "|r  |cffff4040REVOKED|r"
        meta = ("Revoked by %s: %s"):format(K.nameOf(rv.by), (rv.note and rv.note ~= "") and rv.note or "no reason")
    end
    return line, meta, b, rv
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
    r.revoke = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
    r.revoke:SetSize(64, 18)
    r.revoke:SetPoint("RIGHT", -8, 0)
    r.revoke:SetText("Revoke")
    r.revoke:SetScript("OnClick", function(self)
        local e = self:GetParent().event
        if not e then return end
        local line = describe(e)
        line = (line:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
        if e.kind == "hunt" then
            OUI.AskGrantHunt(e.id, line)
        elseif e.kind == "request" then
            -- (approving is one click; the award it makes can be revoked)
            local ok, err = ns.Ledger.Approve(e.id)
            if not ok then ns.print("|cffff4040" .. (err or "Not approved.") .. "|r") end
        else
            OUI.AskRevoke(e.id, line)
        end
    end)
    r.deny = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
    r.deny:SetSize(64, 18)
    r.deny:SetPoint("RIGHT", r.revoke, "LEFT", -4, 0)
    r.deny:SetText("Deny")
    r.deny:SetScript("OnClick", function(self)
        local e = self:GetParent().event
        if not e then return end
        local line = describe(e)
        OUI.AskDeny(e.id, (line:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")))
    end)
    r.deny:Hide()
    -- (with the buttons there, the time and tag sit left of them)
    function r:Place(buttons)
        local x = -(12 + buttons * 68)
        self.when:ClearAllPoints(); self.when:SetPoint("TOPRIGHT", x, -6)
        self.kind:ClearAllPoints(); self.kind:SetPoint("BOTTOMRIGHT", x, 5)
    end
    r:Place(1)
    r.meta:SetPoint("RIGHT", r.kind, "LEFT", -8, 0)
    return r
end

local function fillLog(f, approvals)
    local child = f.scroll.child
    -- Filtering ranks as the Guildie suggestions do: events with someone
    -- whose first name starts with it (guildie or officer), newest first;
    -- then last names / RP names; then badge names and notes that have it.
    local q = approvals and "" or trim(state.filter)
    local list
    if approvals then
        list = ns.Ledger.Pending()
    elseif q == "" then
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
    f.logHead:SetText(approvals and ("Approvals  |cff9d9d9d%d waiting|r"):format(#list)
        or ("Audit Log  |cff9d9d9d%d event%s|r"):format(#list, #list == 1 and "" or "s"))
    local y = 32
    for i, e in ipairs(list) do
        local r = f.logRows[i]
        if not r then r = newLogRow(child); f.logRows[i] = r end
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
        r:SetPoint("RIGHT", child, "RIGHT", 0, 0)
        local line, meta, b, rv = describe(e)
        r.event = e
        local pending = e.kind == "request" and not ns.Ledger.DecisionOf(e.id) and ns.Ledger.CanAward(nil, e.badge)
        r.deny:SetShown(pending and true or false)
        r:Place(pending and 2 or 1)
        if e.kind == "request" then
            r.revoke:SetText("Approve")
            r.revoke:SetShown(pending and true or false)
        elseif e.kind == "hunt" then
            r.revoke:SetText("Grant")
            r.revoke:SetShown((ns.Ledger.CanAward(nil, Badges.Resolve(e)) and not ns.Ledger.GrantFor(e.id)) and true or false)
        else
            r.revoke:SetText("Revoke")
            r.revoke:SetShown(ns.Ledger.CanRevoke(e) and true or false)
        end
        if b then K.setBadgeIcon(r.icon, b, not rv and e.kind ~= "revoke") end
        r.line:SetText(line)
        r.meta:SetText(meta)
        r.when:SetText(date("%m/%d/%y %H:%M", e.at))
        r.kind:SetText(e.test and "|cffff8040Test|r" or (e.kind == "award" or e.kind == "revoke") and "|cffffd100Granter|r"
            or e.kind == "hunt" and "|cff40c0ffHunt|r" or e.kind == "request" and "|cffffd100Request|r"
            or e.kind == "deny" and "|cffffd100Granter|r" or "|cff9d9d9dAutomatic|r")
        r:Show()
        y = y + LOG_ROW_H
    end
    for i = #list + 1, #f.logRows do f.logRows[i]:Hide() end
    f.logEmpty:SetShown(#list == 0)
    f.logEmpty:SetText(approvals and "Nothing waiting for approval." or q ~= "" and "Nothing matches." or "Nothing logged yet.")
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
    for i, c in ipairs(NAV) do
        K.styleCatButton(f.nav[i], c, false, state.view == c.id)
        if c.id == "approvals" then
            local n = #ns.Ledger.Pending()
            if n > 0 then f.nav[i].label:SetText(("Approvals |cffffffff(%d)|r"):format(n)) end
        end
    end
    local h
    local isLog = state.view == "log" or state.view == "approvals"
    f.award:SetShown(not isLog)
    f.logHead:SetShown(isLog)
    f.logFilter:SetShown(state.view == "log")
    if isLog then
        h = fillLog(f, state.view == "approvals")
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
    ns.ToggleWindow(6)          -- (switches tab if the guild window is open; else it opens there on J)
    OUI.Refresh()
end

UI.AddPage(6, "Officers", build, refresh,
    { order = 3, icon = { "INV_Misc_Note_06", "INV_Scroll_03" }, tooltip = "Officers", title = "Officer",
      bgAtlas = "Legacy-Rewards-Tracker-background",
      visible = function() return ns.Ledger and ns.Ledger.CanAward() end })

-- The Audit Log's questions, in our own dialog (Dialog.lua), never the
-- game's StaticPopup.
local function failed(err, what) ns.print("|cffff4040" .. (err or what) .. "|r") end

-- Revoking: the reason typed in.
function OUI.AskRevoke(id, line)
    ns.Dialog.Show({
        text = ("Revoke this entry?\n\n%s\n\nThe reason goes in the Audit Log:"):format(line),
        accept = "Revoke", edit = true, maxLetters = 80,
        onAccept = function(typed)
            local ok, err = ns.Ledger.Revoke(id, typed)
            if not ok then failed(err, "Not revoked.") end
        end,
    })
end

function OUI.AskDeny(id, line)
    ns.Dialog.Show({
        text = ("Deny this request?\n\n%s\n\nThe reason goes in the Audit Log:"):format(line),
        accept = "Deny", edit = true, maxLetters = 80,
        onAccept = function(typed)
            local ok, err = ns.Ledger.Deny(id, typed)
            if not ok then failed(err, "Not denied.") end
        end,
    })
end

-- Granting a Huntress Training Hunt Target from a logged hunt: to its hunter, for its target.
function OUI.AskGrantHunt(id, line)
    ns.Dialog.Show({
        text = ("Grant this Hunt Target for this hunt?\n\n%s"):format(line),
        accept = "Grant",
        onAccept = function()
            local h = ns.Ledger.Find(id)
            if not h then return end
            local bid = Badges.Resolve(h)
            local b = Badges.Get(bid)
            local ok, err = ns.Ledger.Award(h.who, bid, 0, b and ("Hunt of " .. ns.Dialog.When(h.at)) or "Hunt Target", { ref = h.id })
            if not ok then failed(err, "Not granted.") end
        end,
    })
end

ns.onLogin(function()
    ns.listen("LEDGER", function() OUI.Refresh() end)
    ns.listen("ROSTER", function() OUI.Refresh() end)
end, "officer ui")
