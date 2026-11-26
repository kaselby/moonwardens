-- Leaderboard: Horde players killed in Ashenvale, Mount Hyjal and at
-- Stonetalon Peak, per week, shared through the guild.
-- Any kill counts, honorable or not (Krylea, 11-09): grey-level Horde too.
-- Weeks run on the game's Tuesday reset, the same weeks and messages as 0.5,
-- so every version shares one board. Sunday weeks (Krylea, 11-15) are on hold
-- until every kill is logged with its time (Krylea, 11-19: then any rule
-- change can be recounted exactly). The log is below: db.kills.
-- H|1|week|count            GUILD: my own count this week
-- HQ|1|week|attempt         GUILD: "send me the board"; one elected member replies
-- HS|1|week|Name:n,Name:n   WHISPER: the board, in chunks under 255 bytes
-- Counts are each player's own claim; we keep the highest we've seen.
local _, ns = ...
local LB = {}
ns.Leaderboard = LB

local ASHENVALE = 1440
local STONETALON = 1442
local HYJAL = 2482               -- (this realm's Mount Hyjal map)
local PEAK = "Stonetalon Peak"   -- the subzone; the rest of Stonetalon doesn't count
local WEEK = 604800
-- A known reset: Tuesday 2024-01-02 15:00 UTC (US weekly reset).
local ANCHOR = 1704207600
local SUNDAY_ANCHOR = 1704639600   -- 0.6.0-test's Sunday weeks (carried back once)
local DEBOUNCE = 30       -- seconds between my H broadcasts
local RECENT = 300        -- a member heard from within this counts as "online with the addon"

local lastCounter         -- GetPVPSessionStats() kills last time we read it
local sendPending = false
local lastH = -100
local gotHS = false

---------------------------------------------------------------------------
-- Weeks
---------------------------------------------------------------------------
-- Server time of the next weekly reset. Probes the client API, else assumes
-- Tuesday 15:00 UTC. (As 0.5: the week ids must match.)
function LB.NextReset()
    local now = ns.try(GetServerTime) or time()
    local secs = C_DateAndTime and ns.try(C_DateAndTime.GetSecondsUntilWeeklyReset)
    if type(secs) == "number" and secs > 0 and secs <= WEEK then return now + secs end
    return ANCHOR + (math.floor((now - ANCHOR) / WEEK) + 1) * WEEK
end

-- Week id: whole weeks from the anchor to the start of this week. Rounded, so
-- a reset a few hours off the anchor (other regions) still gives one id.
function LB.Week()
    return math.floor((LB.NextReset() - ANCHOR) / WEEK + 0.5) - 1
end

-- When week `week` began (server time).
function LB.WeekStart(week) return ANCHOR + week * WEEK end

-- The week a moment `t` falls in.
function LB.WeekOf(t) return math.floor((t - ANCHOR) / WEEK) end

local function board()
    return ns.db.board
end

local function weekTable(week)
    local b = board()
    b[week] = b[week] or {}
    return b[week]
end

-- Keep only this week and last week.
local function prune()
    local w = LB.Week()
    local b = board()
    for k in pairs(b) do
        if type(k) ~= "number" or k < w - 1 or k > w + 1 then b[k] = nil end
    end
end

-- Record a claim. Returns true if it raised the stored count.
function LB.Set(week, key, count, name)
    week, count = tonumber(week), tonumber(count)
    if not (week and key and count) or count < 0 or count > 100000 then return false end
    local cur = LB.Week()
    if week < cur - 1 or week > cur + 1 then return false end
    local t = weekTable(week)
    local e = t[key]
    local m = ns.Roster and ns.Roster.Get(key)
    if not e then e = { n = (m and m.name) or name or key, c = 0 }; t[key] = e end
    if m then e.n, e.cls = m.name, m.classFile end
    if count <= e.c then return false end
    e.c = math.floor(count)
    return true
end

function LB.Mine(week)
    local t = board()[week or LB.Week()]
    local e = t and ns.meKey and t[ns.meKey]
    return e and e.c or 0
end

---------------------------------------------------------------------------
-- Counting my kills
---------------------------------------------------------------------------
-- Ashenvale, Mount Hyjal, or the Stonetalon Peak subzone of Stonetalon
-- Mountains.
local function counts()
    local inside, kind = ns.try(IsInInstance)
    if inside == true and kind ~= "none" then return false end
    local map = ns.try(C_Map.GetBestMapForUnit, "player")
    local zone = ns.try(GetZoneText)
    if map == ASHENVALE or zone == "Ashenvale" then return true end
    if map == HYJAL or zone == "Mount Hyjal" then return true end
    if map == STONETALON or zone == "Stonetalon Mountains" then
        return ns.try(GetSubZoneText) == PEAK or ns.try(GetMinimapZoneText) == PEAK
    end
    return false
end
LB.Counts = counts

local function scheduleH()
    if sendPending then return end
    sendPending = true
    local wait = math.max(0, DEBOUNCE - (ns.now() - lastH))
    ns.after(wait, function()
        sendPending = false
        lastH = ns.now()
        ns.Comm.Send({ "H", ns.Comm.PROTO, LB.Week(), LB.Mine() }, "GUILD", nil, "hk")
    end, "hk send")
end

-- Two sources, because neither is sure to work everywhere:
--  * PARTY_KILL (attacker, victim GUIDs): a killing blow by me or my group.
--    Counts any player, honour or not. May be secret where unit identity is
--    restricted.
--  * GetPVPSessionStats() honorable kills. PLAYER_PVP_KILLS_CHANGED fires
--    twice per kill, so we count the counter's rise, never the events.
-- The same kill usually shows up in both, within a second or two. Each
-- kill waits up to MATCH seconds for its twin from the other source; a twin
-- that arrives is absorbed (it only adds what it knows to the log entry).
--
-- Every kill is logged, wherever it happened (Krylea, 11-19), so any future
-- rule (other weeks, other zones) can be recounted exactly:
-- db.kills[my key] = list of {
--   t = server time, m = map id, z = zone, sz = subzone, i = 1 if in an instance,
--   s = "p" (party kill), "h" (honour counter) or "ph" (both),
--   k = 1 if it counted on the leaderboard,
--   g = victim GUID, v = victim name, c = victim class (file), r = race,
--   by = who struck it, when not me }
-- Victim fields only come with a party kill, and only when readable.
local MATCH = 10
local LOG_MAX = 50000              -- per character; oldest dropped beyond this
local fromParty, fromHK = {}, {}   -- { at, e } of logged kills still waiting for a twin

-- The oldest waiting kill from the other source that counted the same way
-- (a kill just over a zone border must not swallow one inside it).
local function absorb(list, counted)
    local now = ns.now()
    while list[1] and now - list[1].at > MATCH do table.remove(list, 1) end
    for i = 1, #list do
        if (list[i].e.k == 1) == counted then return table.remove(list, i) end
    end
end

local function str(v)
    if type(v) == "string" and ns.readable(v) and v ~= "" then return v end
end

local function victimInfo(guid, attacker, e)
    e.g = str(guid)
    if e.g and GetPlayerInfoByGUID then
        local ok, _, class, _, race, _, name, realm = pcall(GetPlayerInfoByGUID, e.g)
        if ok then
            e.c, e.r, e.v = str(class), str(race), str(name)
            if e.v and str(realm) then e.v = e.v .. "-" .. realm end
        end
    end
    if str(attacker) and attacker ~= ns.try(UnitGUID, "player") and GetPlayerInfoByGUID then
        local ok, _, _, _, _, _, name = pcall(GetPlayerInfoByGUID, attacker)
        if ok then e.by = str(name) end
    end
end

function LB.Log()
    if not (ns.db and ns.meKey) then return {} end
    ns.db.kills[ns.meKey] = ns.db.kills[ns.meKey] or {}
    return ns.db.kills[ns.meKey]
end

local function kill(src, guid, attacker)
    local counted = counts()
    local twin = absorb(src == "p" and fromHK or fromParty, counted)
    if twin then
        twin.e.s = "ph"
        if src == "p" then victimInfo(guid, attacker, twin.e) end
        return
    end
    local inside, kind = ns.try(IsInInstance)
    local e = {
        t = ns.try(GetServerTime) or time(),
        m = ns.try(C_Map.GetBestMapForUnit, "player"),
        z = str(ns.try(GetZoneText)), sz = str(ns.try(GetSubZoneText)),
        i = (inside == true and kind ~= "none") and 1 or nil,
        s = src,
    }
    if type(e.m) ~= "number" then e.m = nil end
    if src == "p" then victimInfo(guid, attacker, e) end
    if counted then e.k = 1 end
    local log = LB.Log()
    log[#log + 1] = e
    while #log > LOG_MAX do table.remove(log, 1) end
    local list = src == "p" and fromParty or fromHK
    list[#list + 1] = { at = ns.now(), e = e }
    if e.k then LB.Add(1) end
end

function LB.PartyKill(attacker, victim)
    if type(victim) ~= "string" or not ns.readable(victim) then return end
    -- Only players. In open-world Ashenvale, Hyjal and Stonetalon every player who
    -- can die to us is Horde (no duels to the death, no free-for-all areas).
    if victim:sub(1, 7) ~= "Player-" then return end
    kill("p", victim, attacker)
end

-- Kills on the HK counter from before login are not ours to count (we don't
-- know where they happened).
function LB.Read()
    local kills = ns.try(GetPVPSessionStats)
    if type(kills) ~= "number" then return end
    if lastCounter == nil then lastCounter = kills; return end -- baseline at login
    local d = kills >= lastCounter and kills - lastCounter or kills -- a drop = daily reset to 0
    lastCounter = kills
    for _ = 1, d do kill("h") end
end

function LB.Add(n)
    if not ns.meKey then return end
    local w = LB.Week()
    LB.Set(w, ns.meKey, LB.Mine(w) + n, ns.me)
    scheduleH()
    if ns.UI then ns.UI.Refresh() end
end

---------------------------------------------------------------------------
-- Sync
---------------------------------------------------------------------------
-- Members heard from recently, plus me, sorted: everyone computes the same
-- list from what they've heard, and the lowest name (or second, on a retry)
-- answers. Two repliers now and then is harmless (max merge).
function LB.Repliers(exclude)
    local list = { ns.meKey }
    local heard = ns.Comm.lastHeard or {}
    local now = ns.now()
    for key, at in pairs(heard) do
        if now - at < RECENT and key ~= ns.meKey then
            local m = ns.Roster.Get(key)
            if not m or m.online then list[#list + 1] = key end
        end
    end
    local out = {}
    for _, k in ipairs(list) do if k ~= exclude then out[#out + 1] = k end end
    table.sort(out)
    return out
end

-- Board for one week as "Name-Surname:n" chunks, each message under 255 bytes.
function LB.Chunks(week)
    local t = board()[week]
    if not t then return {} end
    local entries = {}
    for key, e in pairs(t) do
        if e.c > 0 then entries[#entries + 1] = (ns.address(e.n) or key) .. ":" .. e.c end
    end
    table.sort(entries)
    local head = ("HS|%d|%d|"):format(ns.Comm.PROTO, week)
    local chunks, cur = {}, {}
    local len = #head
    for _, s in ipairs(entries) do
        if #cur > 0 and len + 1 + #s > 240 then
            chunks[#chunks + 1] = cur; cur = {}; len = #head
        end
        cur[#cur + 1] = s
        len = len + #s + 1
    end
    if #cur > 0 then chunks[#chunks + 1] = cur end
    return chunks
end

local function reply(to, week)
    for _, w in ipairs({ week, week - 1 }) do
        for _, c in ipairs(LB.Chunks(w)) do
            ns.Comm.Send({ "HS", ns.Comm.PROTO, w, table.concat(c, ",") }, "WHISPER", to)
        end
    end
end

local function request(attempt)
    ns.Comm.Send({ "HQ", ns.Comm.PROTO, LB.Week(), attempt }, "GUILD")
end

ns.Comm.handlers.H = function(f, sender, key)
    if LB.Set(f[3], key, f[4], sender) and ns.UI then ns.UI.Refresh() end
end

ns.Comm.handlers.HQ = function(f, sender, key)
    local week, attempt = tonumber(f[3]), tonumber(f[4]) or 1
    if not week or week ~= LB.Week() then return end
    local who = LB.Repliers(key)[attempt]
    if who == ns.meKey then reply(ns.address(sender), week) end
end

ns.Comm.handlers.HS = function(f, sender)
    gotHS = true
    local week = tonumber(f[3])
    if not week or not f[4] then return end
    local changed = false
    for item in f[4]:gmatch("[^,]+") do
        local name, n = item:match("^(.-):(%d+)$")
        local key = ns.key(name)
        -- My own count I know better than anyone.
        if key and key ~= ns.meKey and LB.Set(week, key, n, name) then changed = true end
    end
    if changed and ns.UI then ns.UI.Refresh() end
end

---------------------------------------------------------------------------
-- 0.6.0-test kept Sunday weeks in db.weeks (Krylea and testers only). Once:
-- each into the Tuesday week that holds most of it (Sunday + 2 days), as a
-- claim like any other, then dropped.
---------------------------------------------------------------------------
function LB.CarryBack()
    local weeks = ns.db.weeks
    ns.db.weeks, ns.db.oldBoard = nil, nil
    if type(weeks) ~= "table" then return end
    for w, t in pairs(weeks) do
        w = tonumber(w)
        if w and type(t) == "table" then
            local target = math.floor((SUNDAY_ANCHOR + w * WEEK + 2 * 86400 - ANCHOR) / WEEK)
            for key, e in pairs(t) do
                if type(e) == "table" and LB.Set(target, key, e.c, e.n) then
                    local mine = weekTable(target)[key]
                    if mine and not mine.cls then mine.cls = e.cls end
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Page
---------------------------------------------------------------------------
local ROWS = 18             -- at most; fewer when the page is shorter
local ROW_H = 20
local RANK_COLOR = { { 1, 0.82, 0 }, { 0.85, 0.85, 0.9 }, { 0.85, 0.55, 0.3 } }

local function duration(secs)
    local d, h, m = math.floor(secs / 86400), math.floor(secs % 86400 / 3600), math.floor(secs % 3600 / 60)
    if d > 0 then return ("%d day%s %d hour%s"):format(d, d == 1 and "" or "s", h, h == 1 and "" or "s") end
    if h > 0 then return ("%d hour%s %d min"):format(h, h == 1 and "" or "s", m) end
    return ("%d min"):format(m)
end

-- Sorted rows for a week: only guild members (when the roster is known).
function LB.Rows(week)
    local rows = {}
    for key, e in pairs(board()[week] or {}) do
        local m = ns.Roster.Get(key)
        if e.c > 0 and (m or not ns.Roster.Loaded()) then
            rows[#rows + 1] = { key = key, name = m and m.name or e.n, c = e.c,
                cls = m and m.classFile or e.cls, class = m and m.class, level = m and m.level }
        end
    end
    table.sort(rows, function(a, b) if a.c ~= b.c then return a.c > b.c end return a.name < b.name end)
    return rows
end

local function build(f)
    local UI = ns.UI
    LB.page = f
    f.week = 0 -- 0 = this week, 1 = last week
    -- The heading: where it counts; under it, when it resets. (The Guild
    -- Total: over the Kills column, below.)
    f.sub = UI.Text(f, "small", UI.GREY, "LEFT"); f.sub:SetPoint("TOPLEFT", 0, -4)
    f.reset = UI.Text(f, "small", UI.GREY, "LEFT"); f.reset:SetPoint("TOPLEFT", f.sub, "BOTTOMLEFT", 0, -3)
    f.reset:SetHeight(14)                 -- (a line's height even when empty: the Guild Total sits on it)

    f.tabs = {}
    for i, label in ipairs({ "This week", "Last week" }) do
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(84, 20)
        b:SetPoint("TOPRIGHT", -(2 - i) * 86, 2)
        b:SetText(label)
        b:SetScript("OnClick", function() f.week = i - 1; f.offset = 0; UI.Refresh() end)
        f.tabs[i] = b
    end

    local y = -40                         -- (under the heading's two lines)
    local function col(text, x, w, justify)
        local h = UI.Text(f, nil, UI.GOLD, justify); h:SetPoint("TOPLEFT", x, y); h:SetWidth(w); h:SetText(text)
        return h
    end
    col("#", 0, 24, "RIGHT"); col("Name", 36, 200, "LEFT"); col("Level / class", 250, 150, "LEFT")
    local kills = col("Kills", 440, 60, "RIGHT")
    -- The Guild Total: on the Resets line, centred over the Kills heading
    -- (on the word, at its box's right end - not the box). Placed as it's
    -- filled in, by its width (refresh).
    f.total = UI.Text(f, "small", UI.GREY, "LEFT")
    f.killsMid = 440 + 60 - (ns.try(kills.GetStringWidth, kills) or 0) / 2
    local line = f:CreateTexture(nil, "ARTWORK"); line:SetColorTexture(0.35, 0.28, 0.08, 1)
    line:SetPoint("TOPLEFT", 0, y - 16); line:SetSize(508, 1)

    -- Rows: hovering a guildie shows the guild roster's tooltip for them
    -- (RosterLayer.lua: totalRP3's when it has their profile), right-click
    -- the roster's menu (Menu.lua), as on the roster itself.
    local function rowEnter(r)
        local info = r.key and ns.Roster.ClubMember(r.key)
        if info and ns.MemberTooltip then ns.MemberTooltip(r, info) end
    end
    local function rowLeave(r)
        if ns.RosterTRP then ns.RosterTRP.Hide(r) end
        if GameTooltip:GetOwner() == r then GameTooltip:Hide() end
    end
    f.rows = {}
    for i = 1, ns.UI.RowsFor(f, ROWS, ROW_H, -y + 20) do
        local r = CreateFrame("Button", nil, f)
        r:SetSize(508, ROW_H)
        r:SetPoint("TOPLEFT", 0, y - 20 - (i - 1) * ROW_H)
        r:RegisterForClicks("RightButtonUp")
        r:SetScript("OnEnter", ns.guard(rowEnter, "leaderboard hover"))
        r:SetScript("OnLeave", ns.guard(rowLeave, "leaderboard hover"))
        r:SetScript("OnClick", ns.guard(function(self)
            rowLeave(self)
            if self.key and ns.OpenMemberMenu then ns.OpenMemberMenu(self.key) end
        end, "leaderboard menu"))
        r:SetScript("OnMouseWheel", function(_, delta) local h = f:GetScript("OnMouseWheel"); if h then h(f, delta) end end)
        r.hl = r:CreateTexture(nil, "BACKGROUND"); r.hl:SetAllPoints(); r.hl:SetColorTexture(1, 0.82, 0, 0.12)
        local over = r:CreateTexture(nil, "HIGHLIGHT"); over:SetAllPoints(); over:SetColorTexture(1, 1, 1, 0.08); over:SetBlendMode("ADD")
        r.rank = UI.Text(r, nil, nil, "RIGHT"); r.rank:SetPoint("LEFT", 0, 0); r.rank:SetWidth(24)
        r.name = UI.Text(r, nil, nil, "LEFT"); r.name:SetPoint("LEFT", 36, 0); r.name:SetWidth(210)
        r.class = UI.Text(r, nil, UI.GREY, "LEFT"); r.class:SetPoint("LEFT", 250, 0); r.class:SetWidth(180)
        r.n = UI.Text(r, nil, nil, "RIGHT"); r.n:SetPoint("RIGHT", -8, 0); r.n:SetWidth(60)
        f.rows[i] = r
    end
    f.empty = UI.Text(f, nil, UI.GREY, "CENTER"); f.empty:SetPoint("TOP", 0, y - 70); f.empty:SetWidth(460)

    f.offset = 0
    f:EnableMouseWheel(true)
    f:SetScript("OnMouseWheel", function(_, delta)
        f.offset = math.max(0, math.min((f.count or 0) - #f.rows, f.offset - delta * 3))
        UI.Refresh()
    end)
    -- The game's own scroll bar (MinimalScrollBar, as the guild roster's),
    -- beside the rows; shown only when there are more rows than fit.
    local okSB, sb = pcall(CreateFrame, "EventFrame", nil, f, "MinimalScrollBar")
    if okSB and sb and sb.Init and sb.RegisterCallback and ScrollBarMixin and ScrollBarMixin.Event then
        sb:SetPoint("TOPLEFT", f, "TOPLEFT", 516, y - 20)
        sb:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 516, y - 20 - #f.rows * ROW_H)
        sb:RegisterCallback(ScrollBarMixin.Event.OnScroll, function(_, pct)
            if f.syncing then return end
            local max = (f.count or 0) - #f.rows
            if max <= 0 then return end
            local o = math.max(0, math.min(max, math.floor(pct * max + 0.5)))
            if o ~= f.offset then f.offset = o; UI.Refresh() end
        end, f)
        sb:Hide()
        f.scrollBar = sb
    end
    f.foot = UI.Text(f, "small", UI.GREY, "LEFT"); f.foot:SetPoint("BOTTOMLEFT", 0, 0); f.foot:SetWidth(508)

    -- The empty column right of the board: coming soon.
    f.soon = UI.Text(f, "big", UI.GREY, "CENTER")
    f.soon:SetPoint("TOPLEFT", 548, y)
    f.soon:SetPoint("BOTTOMRIGHT", 0, 20)
    f.soon:SetText("Coming Soon")
end

-- The scroll bar follows the offset (wheel, week change, new rows).
local function syncScrollBar(f)
    local sb = f.scrollBar
    if not sb then return end
    local max = (f.count or 0) - #f.rows
    if max <= 0 then sb:Hide(); return end
    f.syncing = true
    pcall(function()
        sb:Init(#f.rows / f.count, 1 / max)
        sb:SetScrollPercentage(f.offset / max, true)
    end)
    f.syncing = false
    sb:Show()
end

local function refresh(f)
    prune()
    local cur = LB.Week()
    local week = cur - f.week
    local rows = LB.Rows(week)
    f.count = #rows
    f.offset = math.max(0, math.min(f.offset or 0, #rows - #f.rows))
    syncScrollBar(f)
    for i, b in ipairs(f.tabs) do
        if i - 1 == f.week then b:LockHighlight() else b:UnlockHighlight() end
    end
    local total = 0
    for _, r in ipairs(rows) do total = total + r.c end
    local resetAt = LB.NextReset()
    local left = resetAt - (ns.try(GetServerTime) or time())
    f.total:SetText(("Guild Total |cffffd100%s|r"):format(total))
    local tw = ns.try(f.total.GetStringWidth, f.total) or 0
    f.total:ClearAllPoints()
    f.total:SetPoint("LEFT", f.reset, "LEFT", math.floor(f.killsMid - tw / 2 + 0.5), 0)
    if f.week == 0 then
        f.sub:SetText("Ashenvale, Mount Hyjal and Stonetalon Peak")
        f.reset:SetText(("Resets Tuesday  -  %s left"):format(duration(left)))
    else
        f.sub:SetText("Final standings")
        f.reset:SetText("")
    end
    for i, r in ipairs(f.rows) do
        local e = rows[i + f.offset]
        if e then
            local rank = i + f.offset
            local rc = RANK_COLOR[rank] or { 0.8, 0.8, 0.8 }
            r.rank:SetText(rank); r.rank:SetTextColor(rc[1], rc[2], rc[3])
            local cr, cg, cb = ns.RP.Color(e.key)          -- (RP name and colour when on)
            if not cr then cr, cg, cb = ns.classColor(e.cls) end
            r.name:SetText((ns.RP.Name(e.key) or e.name) .. (e.key == ns.meKey and " |cff9d9d9d(you)|r" or ""))
            r.name:SetTextColor(cr, cg, cb)
            local lc = {}
            if e.level then lc[#lc + 1] = e.level end
            if e.class then lc[#lc + 1] = e.class end
            r.class:SetText(table.concat(lc, " "))
            r.n:SetText(e.c)
            r.hl:SetShown(e.key == ns.meKey)
            r.key = e.key
            r:Show()
        else
            r.key = nil
            r:Hide()
        end
    end
    if #rows == 0 then
        f.empty:SetText(f.week == 0 and "No kills yet this week.\nGo find some Horde."
            or "Nothing recorded for last week.")
        f.empty:Show()
    else
        f.empty:Hide()
    end
    local foot = "Counts Horde killed by you or your group in Ashenvale, Mount Hyjal or Stonetalon Peak."
    if f.week == 0 then
        local last = LB.Rows(cur - 1)[1]
        if last then
            -- (their name and colour as in the rows: the RP ones when on, else class)
            local cr, cg, cb = ns.RP.Color(last.key)
            if not cr then cr, cg, cb = ns.classColor(last.cls) end
            foot = foot .. ("\nLast week's winner: |cff%02x%02x%02x%s|r (%d)"):format(
                cr * 255, cg * 255, cb * 255, ns.RP.Name(last.key) or last.name, last.c)
        end
    end
    f.foot:SetText(foot)
end

ns.UI.AddPage(5, "Leaderboard", build, refresh,
    { order = 1, icon = { "Spell_Nature_MoonGlow", "Spell_Nature_StarFall" }, tooltip = "Leaderboard", title = "Ashenvale Leaderboard",
      bgAtlas = "Legacy-Rewards-Tracker-background",   -- (the minimap button's)
      button = "invite" })                              -- (the game's Invite Member, bottom right)

---------------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------------
ns.onLogin(function()
    LB.CarryBack()
    prune()
    LB.Read() -- sets the baseline; kills from before login don't count
    ns:On("PLAYER_PVP_KILLS_CHANGED", LB.Read)
    ns:On("PARTY_KILL", LB.PartyKill)
    ns.every(5, LB.Read, "hk poll")
    -- Announce and ask once the roster and some P messages are in.
    ns.after(15, function()
        if LB.Mine() > 0 then scheduleH() end
        request(1)
        ns.after(20, function() if not gotHS then request(2) end end, "hk retry")
    end, "hk login")
end, "leaderboard")

ns.slash.hk = { help = "my Horde kills this week (Ashenvale, Mount Hyjal and Stonetalon Peak)", fn = function()
    ns.print(("%d Horde kills this week (%d last week)."):format(LB.Mine(), LB.Mine(LB.Week() - 1)))
end }

-- /mw kills: the last few entries of my kill log, to check it's recording.
ns.slash.kills = { help = "my last kills from the kill log", fn = function()
    local log = LB.Log()
    ns.print(("%d kills logged on this character."):format(#log))
    for i = math.max(1, #log - 4), #log do
        local e = log[i]
        local who = e.v or (e.g and "a player") or "unknown"
        ns.print(("  %s  %s%s  %s%s%s"):format(date("%m-%d %H:%M", e.t), e.z or "?", e.sz and (" / " .. e.sz) or "",
            who, e.c and (" (" .. e.c .. ")") or "", e.k and "" or "  [not counted]"))
    end
end }
