-- RosterLayer: a Layer column on the guild window's Roster tab, between
-- Zone and Rank: the layer number the guild agreed for their zone
-- (LayerLink.lua): green for mine (me included), orange for another layer in
-- my zone, white in another zone, paler with "?" when it's only a lead; "?"
-- grey when not known; blank for guildies with no position.
-- Clicking its heading sorts by zone, then layer (unknown last), then name;
-- again reverses the zones. Offline members always go last.
-- Also: names in their RP name and colour (RP.lua, the Roleplay settings),
-- and wider Name, Zone and Rank columns for the bigger guild window; a
-- Top Badges column after Note: their most prestigious badges (most points
-- first, one per tier track), as small as the class icon, with the tier's
-- coin bottom right, and the badge's own tooltip on hovering one; and a
-- hover tooltip on every member: the game's details with their note, plus
-- their RP profile (totalRP3's own tooltip only works on units in the world).
--
-- How it fits in (Blizzard_Communities, Classic Era):
--  * Rows: CommunitiesMemberListEntryMixin:RefreshExpandedColumns anchors
--    Rank to Zone each time; after it we put our cell there and Rank after
--    our cell. Note follows Rank and simply gets narrower.
--    Note runs to the row's right edge (or, with one of the game's extra
--    guild columns, is 93 wide with that column after it): our badges go
--    after it, its right end (or the extra column's left) moved to make
--    room, and back when the list isn't the guild's.
--  * Heading: the member list's ColumnDisplay:LayoutColumns rebuilds the
--    headings each layout; after it we add ours after Zone and move Rank's,
--    and Top Badges at Note's right end, Note shortened by as much.
--  * Sort: the list keeps its active column in activeColumnSortIndex and
--    re-sorts with it on every roster update. Ours is SORT_ID, a column the
--    game doesn't have (its own SortByColumnIndex ignores it), and after
--    that we sort the list ourselves.
-- This doesn't load the guild window; it attaches when the game loads it.
-- Layers off (ns.LAYERS, Core.lua): no Layer column or heading - Rank stays
-- after Zone, as the game has it; the rest (names, widths, badges, the
-- tooltip) as ever.
local _, ns = ...
local RL = {}
ns.RosterLayer = RL

local CELL_W = 56           -- the layer column in rows
local GAP = 7               -- as the game spaces Zone and Rank
local SORT_ID = 99          -- our column for the list's sort state
-- The guild window is made bigger (GuildTabs.lua), so the columns get
-- wider than the game's: rows, then headings (game: Name 95/100, Zone
-- 90/100, Rank 75/85; Note takes what's left).
local NAME_EXTRA = 40
local ZONE_W, ZONE_HEAD = 120, 130
local RANK_W, RANK_HEAD = 95, 105
local BADGE_N, BADGE_GAP = 3, 4      -- the badges column: how many, the space between
local BADGE_TITLE = "Top Badges"
local PRESTIGE_TTL = 60              -- (s) a guildie's badges are worked out again after this
local hooked = false
local header, badgeHeader

-- Colours by how a guildie's layer relates to mine; the pale ones are leads.
local LAYER_COLOR = {
    same = { 0.12, 1, 0 }, sameLead = { 0.6, 0.9, 0.55 },
    other = { 1, 0.5, 0.25 }, otherLead = { 0.95, 0.72, 0.55 },
    zone = { 1, 1, 1 }, zoneLead = { 0.7, 0.7, 0.7 },
    unknown = { 0.62, 0.62, 0.62 }, na = { 0.5, 0.5, 0.5 },
}

-- A guildie's agreed layer: number (nil: "?"), lead?, colour key. nil when
-- we have no position for them.
local function numberOf(key)
    if not key then return end
    local me = ns.Position.Me()
    local g = (key == ns.meKey) and me or ns.Position.All()[key]
    if not (g and g.map) then return end
    local n, lead
    if ns.LayerLink then n, lead = ns.LayerLink.Label(key) end
    if not n then return false, false, "unknown" end
    local kind
    if g.map ~= me.map then kind = "zone"
    elseif n == ns.LayerLink.MyLabel() then kind = "same"
    else kind = "other" end
    return n, lead, lead and (kind .. "Lead") or kind
end


local function memberList()
    return CommunitiesFrame and CommunitiesFrame.MemberList
end

local function isGuildList(ml)
    local ok, info = pcall(ml.GetSelectedClubInfo, ml)
    return ok and info and Enum and Enum.ClubType and info.clubType == Enum.ClubType.Guild
end

local function offline(info)
    local P = Enum and Enum.ClubMemberPresence
    return not P or info.presence == P.Offline or info.presence == P.OnlineMobile
end

-- Text and colour for one member.
local function cellText(info)
    if offline(info) then return "" end
    local n, lead, k = numberOf(ns.key(info.name))
    if n == nil then return "" end
    if not n then return "?", LAYER_COLOR.unknown end
    return ("Layer %d%s"):format(n, lead and "?" or ""), LAYER_COLOR[k] or LAYER_COLOR.unknown
end

-- After the game lays out a row: our cell after Zone, Rank after our cell.
-- Our Layer cell for each of the game's roster rows (kept here, not on them).
local cells = setmetatable({}, { __mode = "k" })

-- A guildie's Top Badges: their Badge Showcase, in its order, the empty
-- slots left out (Badges.ShowcaseOf; never arranged, or not heard from:
-- their most prestigious). Kept a while; dropped when the Ledger or their
-- badges or Showcase change (and the rows redrawn then).
local prestige = {}         -- key -> { at, list }
local function prestigeOf(key)
    if not (key and ns.Badges and ns.Badges.Of) then return {} end
    local p = prestige[key]
    if p and ns.now() - p.at < PRESTIGE_TTL then return p.list end
    local list = {}
    local ok, result = pcall(ns.Badges.Of, key)
    if ok and type(result) == "table" then
        local okS, show = pcall(ns.Badges.ShowcaseOf, key, result)
        for _, it in ipairs(okS and show or {}) do
            if #list < BADGE_N then list[#list + 1] = it end
        end
    end
    prestige[key] = { at = ns.now(), list = list }
    return list
end

-- The badges column's width, for icons the size of the row's class icon.
local function iconSize(row)
    local s = row and row.Class and row.Class:GetHeight()
    return (s and s > 0) and s or 16
end
local function badgesWidth(size) return BADGE_N * size + (BADGE_N - 1) * BADGE_GAP end
-- The column's width in rows: the icons, or the heading's title if wider
-- (set when the headings are laid out).
local colW

-- Our badge icons for each roster row (kept here, not on them), and rows
-- whose Note (or extra column) we moved.
local badgeIcons = setmetatable({}, { __mode = "k" })
local noteMoved = setmetatable({}, { __mode = "k" })
local GUILDINFO_GAP = 20             -- as the game spaces Note and its extra column

local function hideBadges(row)
    for _, s in ipairs(badgeIcons[row] or {}) do s.tex:Hide(); s.coin:Hide(); s.hit:Hide() end
    local moved = noteMoved[row]
    if moved and row.Note then
        if moved == "note" then row.Note:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        elseif row.GuildInfo then row.GuildInfo:SetPoint("LEFT", row.Note, "RIGHT", GUILDINFO_GAP, 0) end
        noteMoved[row] = nil
    end
end

local function newSlot(row)
    local s = {}
    s.tex = row:CreateTexture(nil, "ARTWORK")
    s.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)         -- (the icon's border trimmed, as the class icon is)
    s.coin = row:CreateTexture(nil, "OVERLAY", nil, 1)
    -- Hovering the icon: the badge's tooltip (the Badges page's), in place of
    -- the row's. The row gets its OnLeave and OnEnter as the cursor goes on
    -- and off it, so the rest of the row is as before. Clicks go through to
    -- the row (its right-click menu).
    s.hit = CreateFrame("Frame", nil, row)
    s.hit:EnableMouse(true)
    if s.hit.SetPropagateMouseClicks then pcall(s.hit.SetPropagateMouseClicks, s.hit, true) end
    s.hit:SetScript("OnEnter", ns.guard(function(self)
        local Kit = ns.BadgesUI and ns.BadgesUI.Kit
        if self.entry and self.entry.e and Kit and Kit.badgeTooltip then Kit.badgeTooltip(self, self.entry.b, self.entry.e) end
    end, "roster badge tooltip"))
    s.hit:SetScript("OnLeave", function(self) if GameTooltip:GetOwner() == self then GameTooltip:Hide() end end)
    s.hit:Hide()
    return s
end

local function refreshBadges(row, info)
    local size = iconSize(row)
    local w = colW or badgesWidth(size)
    local slots = badgeIcons[row]
    if not slots then
        slots = {}
        for i = 1, BADGE_N do slots[i] = newSlot(row) end
        badgeIcons[row] = slots
    end
    -- Room after Note: its right end moved in (it runs to the row's edge),
    -- or the game's extra column moved along (Note is 93 wide then).
    local extra = row.GuildInfo and row.GuildInfo:IsShown()
    if extra then
        row.GuildInfo:SetPoint("LEFT", row.Note, "RIGHT", GAP + w + GUILDINFO_GAP, 0)
        noteMoved[row] = "extra"
    else
        row.Note:SetPoint("RIGHT", row, "RIGHT", -4 - w - GAP, 0)
        noteMoved[row] = "note"
    end
    local list = prestigeOf(ns.key(info.name))
    local Kit = ns.BadgesUI and ns.BadgesUI.Kit
    local coins = ns.Badges and ns.Badges.COIN or {}
    local cs = math.max(8, math.floor(size * 0.55))
    for i, s in ipairs(slots) do
        s.tex:SetSize(size, size)
        s.tex:ClearAllPoints()
        if i == 1 then s.tex:SetPoint("LEFT", row.Note, "RIGHT", GAP, 0)
        else s.tex:SetPoint("LEFT", slots[i - 1].tex, "RIGHT", BADGE_GAP, 0) end
        s.coin:SetSize(cs, cs)
        s.coin:ClearAllPoints()
        s.coin:SetPoint("BOTTOMRIGHT", s.tex, "BOTTOMRIGHT", 2, -2)
        s.hit:SetAllPoints(s.tex)
        local e = list[i]
        s.hit.entry = e
        if e and Kit and Kit.setIcon then
            Kit.setIcon(s.tex, e.b.icon); s.tex:Show()
            local coin = e.b.tier and coins[e.b.tier]
            if coin then s.coin:SetTexture(coin); s.coin:Show() else s.coin:Hide() end
            s.hit:Show()
        else
            s.tex:Hide(); s.coin:Hide(); s.hit:Hide()
        end
    end
end

local function refreshRow(row)
    local cell = cells[row]
    local ml = row.GetMemberList and row:GetMemberList()
    local info = row.GetMemberInfo and row:GetMemberInfo()
    if not (row.expanded and info and ml and row.Zone and row.Rank and isGuildList(ml)) then
        if cell then cell:Hide() end
        hideBadges(row)
        return
    end
    row.Zone:SetWidth(ZONE_W)
    row.Rank:SetSize(RANK_W, 0)
    if not ns.LAYERS then                 -- (no Layer column: Rank where the game put it)
        if cell then cell:Hide() end
        if row.Note then refreshBadges(row, info) end
        return
    end
    if not cell then
        cell = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        cell:SetJustifyH("LEFT")
        cell:SetWordWrap(false)
        cell:SetSize(CELL_W, 0)
        cells[row] = cell
    end
    cell:ClearAllPoints()
    cell:SetPoint("LEFT", row.Zone, "RIGHT", GAP, 0)
    row.Rank:ClearAllPoints()
    row.Rank:SetPoint("LEFT", cell, "RIGHT", GAP, 0)
    local text, c = cellText(info)
    cell:SetText(text)
    if c then cell:SetTextColor(c[1], c[2], c[3]) end
    cell:Show()
    if row.Note then refreshBadges(row, info) end
end

---------------------------------------------------------------------------
-- Names: the RP name and colour (RP.lua, the Roleplay settings) in place of
-- the game's, which stay when there's none. Offline names stay grey.
---------------------------------------------------------------------------
-- The rank icon sits just after the name's text, as the game places it.
local function placeRankIcon(row)
    local nf = row.NameFrame
    if not (nf and nf.RankIcon and nf.Name) then return end
    local offset = nf.PresenceIcon and nf.PresenceIcon:IsShown() and nf.PresenceIcon:GetWidth() or 0
    local w = nf.Name:IsTruncated() and nf.Name:GetWidth() or nf.Name:GetStringWidth()
    nf.RankIcon:ClearAllPoints()
    nf.RankIcon:SetPoint("LEFT", nf, "LEFT", w + offset, 0)
end

local function refreshName(row)
    local info = row.GetMemberInfo and row:GetMemberInfo()
    local ml = row.GetMemberList and row:GetMemberList()
    local nf = row.NameFrame
    if not (info and ml and nf and nf.Name and isGuildList(ml)) then return end
    local key = ns.key(info.name)
    nf.Name:SetText((ns.RP and ns.RP.Name(key)) or info.name or "")
    local P = Enum and Enum.ClubMemberPresence
    if not (P and info.presence == P.Offline) then
        local r, g, b
        if ns.RP then r, g, b = ns.RP.Color(key) end
        if not r and info.classID and C_CreatureInfo then
            local ok, ci = pcall(C_CreatureInfo.GetClassInfo, info.classID)
            if ok and ci then r, g, b = ns.classColor(ci.classFile) end
        end
        if r then nf.Name:SetTextColor(r, g, b) end
    end
    placeRankIcon(row)
end

-- After the game sizes the name: a wider name column in the roster.
local function afterNameFrame(row)
    local nf = row.NameFrame
    local ml = row.GetMemberList and row:GetMemberList()
    if row.expanded and nf and nf.Name and ml and isGuildList(ml) then
        nf:SetWidth(nf:GetWidth() + NAME_EXTRA)
        nf.Name:SetWidth(nf.Name:GetWidth() + NAME_EXTRA)
    end
    refreshName(row)
end

-- Hovering a member. The game shows a tooltip only when some of the row's
-- text is cut off; we show one always, with the same lines (rank, level,
-- race and class, zone, note), then their RP profile when the Roleplay
-- settings are on and we have one.
-- (ns.MemberTooltip: the same for any frame `row` and club member `info`;
-- the Leaderboard's rows use it too.)
local WHITE = { 1, 1, 1 }
function ns.MemberTooltip(row, info)
    if not (row and type(info) == "table") then return end
    -- totalRP3's own character tooltip when it has their profile (RosterTRP.lua).
    if ns.RosterTRP and ns.RosterTRP.Show(row, info) then return end
    local tt = GameTooltip
    if tt:GetOwner() ~= row or not tt:IsShown() then
        tt:SetOwner(row)
        tt:AddLine(info.name or "")
        tt:AddLine(info.guildRank or "")
        if info.level and info.race and info.classID and C_CreatureInfo and COMMUNITY_MEMBER_CHARACTER_INFO_FORMAT then
            local okr, race = pcall(C_CreatureInfo.GetRaceInfo, info.race)
            local okc, class = pcall(C_CreatureInfo.GetClassInfo, info.classID)
            if okr and okc and race and class then
                tt:AddLine(COMMUNITY_MEMBER_CHARACTER_INFO_FORMAT:format(info.level, race.raceName, class.className), 1, 1, 1, true)
            end
        end
        local P = Enum and Enum.ClubMemberPresence
        if P and info.presence == P.OnlineMobile and COMMUNITIES_PRESENCE_MOBILE_CHAT then
            tt:AddLine(COMMUNITIES_PRESENCE_MOBILE_CHAT, 1, 1, 1, true)
        elseif info.zone then
            tt:AddLine(info.zone, 1, 1, 1, true)
        end
        if info.memberNote and info.memberNote ~= "" then
            local fmt = COMMUNITY_MEMBER_NOTE_FORMAT or "Note: %s"
            tt:AddLine(fmt:format(info.memberNote), 1, 0.82, 0, true)
        end
    end
    local key = ns.key(info.name)
    local name, race, class
    if ns.RP then name, race, class = ns.RP.Identity(key) end
    if name or race or class then
        local r, g, b
        if ns.RP then r, g, b = ns.RP.Color(key) end
        local c = r and { r, g, b } or WHITE
        tt:AddLine(" ")
        if name then tt:AddLine(name, c[1], c[2], c[3]) end
        local rc = {}
        if race then rc[#rc + 1] = race end
        if class then rc[#rc + 1] = class end
        if #rc > 0 then tt:AddLine(table.concat(rc, " "), 0.8, 0.8, 0.8, true) end
    end
    tt:Show()
end

local function onEnter(row)
    local info = row.GetMemberInfo and row:GetMemberInfo()
    local ml = row.GetMemberList and row:GetMemberList()
    if not (info and ml and isGuildList(ml)) then return end
    ns.MemberTooltip(row, info)
end

local function refreshRows(names)
    local ml = memberList()
    if not (ml and ml:IsVisible() and ml.ScrollBox and ml.ScrollBox.ForEachFrame) then return end
    ml.ScrollBox:ForEachFrame(function(row)
        refreshRow(row)
        if names then refreshName(row) end
    end)
end

-- Zone A-Z (Z-A reversed), then layer low to high with unknown last, then
-- name. Online with a zone, then online without, then offline (by name).
local function sortList(ml)
    local list = ml.sortedMemberList
    if type(list) ~= "table" then return end
    local rev = ml.reverseActiveColumnSort
    local keyed = {}
    for _, info in ipairs(list) do
        local n, lead
        if not offline(info) then n, lead = numberOf(ns.key(info.name)) end
        keyed[info] = {
            group = offline(info) and 3 or (info.zone and info.zone ~= "" and 1 or 2),
            zone = (info.zone or ""):lower(),
            layer = n and (n * 2 + (lead and 1 or 0)) or 999,   -- (by number, a lead after the sure ones)
            name = (info.name or ""):lower(),
            id = tostring(info.guid or info.memberId or ""),
        }
    end
    table.sort(list, function(a, b)
        local x, y = keyed[a], keyed[b]
        if x.group ~= y.group then return x.group < y.group end
        if x.group == 1 and x.zone ~= y.zone then
            if rev then return x.zone > y.zone end
            return x.zone < y.zone
        end
        if x.layer ~= y.layer then return x.layer < y.layer end
        if x.name ~= y.name then return x.name < y.name end
        return x.id < y.id
    end)
end

local function onHeaderClick()
    local ml = memberList()
    if not ml then return end
    PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
    if ml.activeColumnSortIndex == SORT_ID then
        ml.reverseActiveColumnSort = not ml.reverseActiveColumnSort
    else
        ml.reverseActiveColumnSort = false
    end
    ml.activeColumnSortIndex = SORT_ID
    sortList(ml)
    ml:RefreshListDisplay()
end

-- The Layer legend's title: the tooltip's text font, 1 px larger.
local function legendTitle()
    local _, size = GameTooltipText:GetFont()
    ns.UI.TooltipTitleSize(math.floor((size or 12) + 0.5) + 1)
end

-- After the game lays out the headings: ours after Zone, Rank's after ours.
local function layoutHeader(cd, columnInfo)
    local ml = memberList()
    local name, zone, rank, note
    if cd.columnHeaders and cd.columnHeaders.EnumerateActive and ml and isGuildList(ml) and type(columnInfo) == "table"
            and columnInfo[4] and columnInfo[4].attribute == "zone" and columnInfo[5] then
        for h in cd.columnHeaders:EnumerateActive() do
            local id = h:GetID()
            if id == 3 then name = h elseif id == 4 then zone = h elseif id == 5 then rank = h
            elseif id == 6 and columnInfo[6] and columnInfo[6].attribute == "memberNote" then note = h end
        end
    end
    if not (zone and rank) then
        if header then header:Hide() end
        if badgeHeader then badgeHeader:Hide() end
        return
    end
    if not header and ns.LAYERS then
        header = CreateFrame("Button", nil, cd, "ColumnDisplayButtonTemplate")
        header:SetText("Layer")
        header:SetScript("OnClick", ns.guard(onHeaderClick, "roster layer sort"))
        header:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local c = LAYER_COLOR
            local function key(label, col) if col then GameTooltip:AddLine(label, col[1], col[2], col[3]) end end
            key("Layer Legend", { 1, 0.82, 0 })
            legendTitle()
            key("Your layer", c.same); key("Another layer in your zone", c.other)
            key("Possibly another layer in your zone?", c.otherLead)
            key("In another zone", c.zone); key("? - unknown", c.unknown)
            GameTooltip:Show()
        end)
        header:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    if name then name:SetWidth(columnInfo[3].width + NAME_EXTRA) end
    zone:SetWidth(ZONE_HEAD)
    rank:SetWidth(RANK_HEAD)
    -- (headings overlap by 2 px each side, as the game lays them; no Layer
    -- heading, layers off: Rank's where the game put it, after Zone)
    if header then
        header:SetWidth(CELL_W + GAP + 2)
        header:ClearAllPoints()
        header:SetPoint("BOTTOMLEFT", zone, "BOTTOMRIGHT", -2, 0)
        rank:ClearAllPoints()
        rank:SetPoint("BOTTOMLEFT", header, "BOTTOMRIGHT", -2, 0)
        header:Show()
    end
    -- Badges, after Rank; Note after it.
    if not note then
        if badgeHeader then badgeHeader:Hide() end
        return
    end
    if not badgeHeader then
        badgeHeader = CreateFrame("Button", nil, cd, "ColumnDisplayButtonTemplate")
        badgeHeader:SetText(BADGE_TITLE)
        -- Only a heading: not clickable (the template's click sorts the list
        -- by the heading's column - this one has none, and the game's sort
        -- errors on it), no highlight. The game's own headings sort as ever.
        badgeHeader:SetScript("OnClick", nil)
        badgeHeader:EnableMouse(false)
    end
    -- The column: the icons, or the title if that's wider.
    local fs = badgeHeader.GetFontString and badgeHeader:GetFontString()
    local textW = fs and fs:GetStringWidth() or 0
    local w = math.max(badgesWidth(16), math.ceil(textW) + 14)
    local changed = w ~= colW
    colW = w
    -- Note's right end (where the game stretched it to) moves in by ours;
    -- ours takes that end. With no right end it is shortened instead.
    local rp, rel, relP, rx, ry
    for i = 1, note:GetNumPoints() do
        local p, r, q, x, y = note:GetPoint(i)
        if p == "BOTTOMRIGHT" then rp, rel, relP, rx, ry = p, r, q, x, y end
    end
    badgeHeader:ClearAllPoints()
    if rp then
        note:SetPoint("BOTTOMRIGHT", rel, relP, (rx or 0) - (w + GAP), ry or 0)
        badgeHeader:SetPoint("BOTTOMRIGHT", rel, relP, rx or 0, ry or 0)
    else
        note:SetWidth(math.max(40, note:GetWidth() - (w + GAP)))
    end
    badgeHeader:SetPoint("BOTTOMLEFT", note, "BOTTOMRIGHT", -2, 0)
    if not rp then badgeHeader:SetWidth(w + GAP + 2) end
    badgeHeader:Show()
    if changed then refreshRows(false) end
    if header then header:Show() end
end

local function attach()
    local ml = memberList()
    if hooked or not (ml and ml.ColumnDisplay and ml.ColumnDisplay.LayoutColumns and ml.SortByColumnIndex
            and CommunitiesMemberListEntryMixin and CommunitiesMemberListEntryMixin.RefreshExpandedColumns) then
        return
    end
    hooked = true
    -- Rows made from now on (the mixin), and any made already (each row).
    local M = CommunitiesMemberListEntryMixin
    local function hookRows(method, fn)
        if type(M[method]) ~= "function" then return end
        local before = M[method]
        hooksecurefunc(M, method, ns.guard(fn, "roster " .. method))
        if ml.ScrollBox and ml.ScrollBox.ForEachFrame then
            ml.ScrollBox:ForEachFrame(function(row)
                if row[method] == before then hooksecurefunc(row, method, ns.guard(fn, "roster " .. method)) end
            end)
        end
    end
    hookRows("RefreshExpandedColumns", refreshRow)
    hookRows("UpdateNameFrame", afterNameFrame)     -- (the game sets the name colour just before)
    hookRows("UpdatePresence", refreshName)         -- (and again on presence changes)
    hookRows("OnEnter", onEnter)
    hookRows("OnLeave", function(row) if ns.RosterTRP then ns.RosterTRP.Hide(row) end end)
    hooksecurefunc(ml.ColumnDisplay, "LayoutColumns", ns.guard(layoutHeader, "roster layer heading"))
    hooksecurefunc(ml, "SortByColumnIndex", ns.guard(function(self, index)
        if index == SORT_ID then sortList(self) end
    end, "roster layer sort"))
    -- Positions and layers change between roster updates; RP names when
    -- someone phones theirs in or a Roleplay setting changes.
    ns.every(2, function() refreshRows(false) end, "roster layer")
    ns.listen("RP", function() refreshRows(true) end)
    -- (badges changed: work them out again)
    ns.listen("LEDGER", function() prestige = {}; refreshRows(false) end)
    ns.listen("BADGES", function(key)
        if key then prestige[key] = nil else prestige = {} end
        refreshRows(false)                    -- (at once: a Showcase rearranged shows now)
    end)
end

ns:On("ADDON_LOADED", function(name)
    if name == "Blizzard_Communities" then attach() end
end)
ns.onLogin(attach, "roster layer")
