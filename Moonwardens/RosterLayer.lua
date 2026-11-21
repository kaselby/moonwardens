-- RosterLayer: a Layer column on the guild window's Roster tab, between
-- Zone and Rank: the server number,
-- coloured green (your layer, you included), orange (another layer in your
-- zone), grey "?" (unknown); blank for guildies we have no position for.
-- Clicking its heading sorts by zone, then layer (unknown last), then name;
-- again reverses the zones. Offline members always go last.
-- Also: names in their RP name and colour (RP.lua, the Roleplay settings),
-- and wider Name, Zone and Rank columns for the bigger guild window; and a
-- hover tooltip on every member: the game's details with their note, plus
-- their RP profile (totalRP3's own tooltip only works on units in the world).
--
-- How it fits in (Blizzard_Communities, Classic Era):
--  * Rows: CommunitiesMemberListEntryMixin:RefreshExpandedColumns anchors
--    Rank to Zone each time; after it we put our cell there and Rank after
--    our cell. Note follows Rank and simply gets narrower.
--  * Heading: the member list's ColumnDisplay:LayoutColumns rebuilds the
--    headings each layout; after it we add ours after Zone and move Rank's.
--  * Sort: the list keeps its active column in activeColumnSortIndex and
--    re-sorts with it on every roster update. Ours is SORT_ID, a column the
--    game doesn't have (its own SortByColumnIndex ignores it), and after
--    that we sort the list ourselves.
-- This doesn't load the guild window; it attaches when the game loads it.
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
local hooked = false
local header

-- Colours by how a guildie's layer relates to mine.
local LAYER_COLOR = {
    me = { 0.4, 0.8, 1 }, same = { 0.12, 1, 0 }, other = { 1, 0.5, 0.25 },
    unknown = { 0.62, 0.62, 0.62 }, na = { 0.85, 0.85, 0.85 },
}

-- One guildie's layer: server number (0: not known yet), relation to mine,
-- map. nil when we have no position for them (no addon, offline, instance).
local function layerOf(key)
    if not key then return end
    if key == ns.meKey then
        local me = ns.Position.Me()
        if not me.map then return end
        return ns.Layer and ns.Layer.Mine(me.map) or 0, "me", me.map
    end
    local g = ns.Position.All()[key]
    if not g then return end
    return g.layer or 0, ns.Position.Relation(g), g.map
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
    local layer, rel = layerOf(ns.key(info.name))
    if not layer then return "" end
    local c = LAYER_COLOR
    if layer == 0 then return "?", c.unknown end
    if rel == "me" then rel = "same" end           -- (one colour for your layer, you included)
    return tostring(layer), c[rel] or c.na
end

-- After the game lays out a row: our cell after Zone, Rank after our cell.
local function refreshRow(row)
    local cell = row.mwLayer
    local ml = row.GetMemberList and row:GetMemberList()
    local info = row.GetMemberInfo and row:GetMemberInfo()
    if not (row.expanded and info and ml and row.Zone and row.Rank and isGuildList(ml)) then
        if cell then cell:Hide() end
        return
    end
    if not cell then
        cell = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        cell:SetJustifyH("LEFT")
        cell:SetWordWrap(false)
        cell:SetSize(CELL_W, 0)
        row.mwLayer = cell
    end
    row.Zone:SetWidth(ZONE_W)
    row.Rank:SetSize(RANK_W, 0)
    cell:ClearAllPoints()
    cell:SetPoint("LEFT", row.Zone, "RIGHT", GAP, 0)
    row.Rank:ClearAllPoints()
    row.Rank:SetPoint("LEFT", cell, "RIGHT", GAP, 0)
    local text, c = cellText(info)
    cell:SetText(text)
    if c then cell:SetTextColor(c[1], c[2], c[3]) end
    cell:Show()
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
local WHITE = { 1, 1, 1 }
local function onEnter(row)
    local info = row.GetMemberInfo and row:GetMemberInfo()
    local ml = row.GetMemberList and row:GetMemberList()
    if not (info and ml and isGuildList(ml)) then return end
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
        local layer = not offline(info) and layerOf(ns.key(info.name)) or nil
        keyed[info] = {
            group = offline(info) and 3 or (info.zone and info.zone ~= "" and 1 or 2),
            zone = (info.zone or ""):lower(),
            layer = (layer and layer > 0) and layer or math.huge,
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

-- After the game lays out the headings: ours after Zone, Rank's after ours.
local function layoutHeader(cd, columnInfo)
    local ml = memberList()
    local name, zone, rank
    if cd.columnHeaders and cd.columnHeaders.EnumerateActive and ml and isGuildList(ml) and type(columnInfo) == "table"
            and columnInfo[4] and columnInfo[4].attribute == "zone" and columnInfo[5] then
        for h in cd.columnHeaders:EnumerateActive() do
            local id = h:GetID()
            if id == 3 then name = h elseif id == 4 then zone = h elseif id == 5 then rank = h end
        end
    end
    if not (zone and rank) then
        if header then header:Hide() end
        return
    end
    if not header then
        header = CreateFrame("Button", nil, cd, "ColumnDisplayButtonTemplate")
        header:SetText("Layer")
        header:SetScript("OnClick", ns.guard(onHeaderClick, "roster layer sort"))
        header:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local c = LAYER_COLOR
            local function key(label, col) if col then GameTooltip:AddLine(label, col[1], col[2], col[3]) end end
            key("Your layer", c.same); key("Another layer in your zone", c.other); key("Unknown", c.unknown)
            GameTooltip:Show()
        end)
        header:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    if name then name:SetWidth(columnInfo[3].width + NAME_EXTRA) end
    zone:SetWidth(ZONE_HEAD)
    rank:SetWidth(RANK_HEAD)
    -- (headings overlap by 2 px each side, as the game lays them)
    header:SetWidth(CELL_W + GAP + 2)
    header:ClearAllPoints()
    header:SetPoint("BOTTOMLEFT", zone, "BOTTOMRIGHT", -2, 0)
    rank:ClearAllPoints()
    rank:SetPoint("BOTTOMLEFT", header, "BOTTOMRIGHT", -2, 0)
    header:Show()
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
end

ns:On("ADDON_LOADED", function(name)
    if name == "Blizzard_Communities" then attach() end
end)
ns.onLogin(attach, "roster layer")
