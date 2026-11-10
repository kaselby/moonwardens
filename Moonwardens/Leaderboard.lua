-- Leaderboard: Horde players killed in Ashenvale, per week, shared through the guild.
-- Any kill counts, honorable or not (Krylea, 11-09): grey-level Horde too.
-- H|1|week|count            GUILD: my own count this week
-- HQ|1|week|attempt         GUILD: "send me the board"; one elected member replies
-- HS|1|week|Name:n,Name:n   WHISPER: the board, in chunks under 255 bytes
-- Counts are each player's own claim; we keep the highest we've seen.
local _, ns = ...
local LB = {}
ns.Leaderboard = LB

local ASHENVALE = 1440
local WEEK = 604800
-- A known reset: Tuesday 2024-01-02 15:00 UTC (US weekly reset).
local ANCHOR = 1704207600
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
-- Tuesday 15:00 UTC.
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

local function weekTable(week)
    local b = ns.db.board
    b[week] = b[week] or {}
    return b[week]
end

-- Keep only this week and last week.
local function prune()
    local w = LB.Week()
    for k in pairs(ns.db.board) do
        if type(k) ~= "number" or k < w - 1 or k > w + 1 then ns.db.board[k] = nil end
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
    local t = ns.db.board[week or LB.Week()]
    local e = t and ns.meKey and t[ns.meKey]
    return e and e.c or 0
end

---------------------------------------------------------------------------
-- Counting my kills
---------------------------------------------------------------------------
local function inAshenvale()
    local inside, kind = ns.try(IsInInstance)
    if inside == true and kind ~= "none" then return false end
    local map = ns.try(C_Map.GetBestMapForUnit, "player")
    if map == ASHENVALE then return true end
    return ns.try(GetZoneText) == "Ashenvale"
end

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
-- counted kill waits up to MATCH seconds for its twin from the other source;
-- a twin that arrives is absorbed, not counted again.
local MATCH = 10
local fromParty, fromHK = {}, {}   -- times of counted kills still waiting for a twin

local function absorb(list)
    local now = ns.now()
    while list[1] and now - list[1] > MATCH do table.remove(list, 1) end
    if list[1] then table.remove(list, 1); return true end
    return false
end

local function count(from, other)
    if absorb(other) then return end
    from[#from + 1] = ns.now()
    LB.Add(1)
end

function LB.PartyKill(attacker, victim)
    if type(victim) ~= "string" or not ns.readable(victim) then return end
    -- Only players. In open-world Ashenvale every player who can die to us is
    -- Horde (no duels to the death, no free-for-all areas).
    if victim:sub(1, 7) ~= "Player-" or not inAshenvale() then return end
    count(fromParty, fromHK)
end

-- Kills on the HK counter from before login are not ours to count (we don't
-- know where they happened).
function LB.Read()
    local kills = ns.try(GetPVPSessionStats)
    if type(kills) ~= "number" then return end
    if lastCounter == nil then lastCounter = kills; return end -- baseline at login
    local d = kills >= lastCounter and kills - lastCounter or kills -- a drop = daily reset to 0
    lastCounter = kills
    if d > 0 and inAshenvale() then
        for _ = 1, d do count(fromHK, fromParty) end
    end
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
    local t = ns.db.board[week]
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
-- Page
---------------------------------------------------------------------------
local ROWS = 14
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
    for key, e in pairs(ns.db.board[week] or {}) do
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
    f.title = UI.Text(f, "big", UI.GOLD, "LEFT"); f.title:SetPoint("TOPLEFT", 0, 0)
    f.title:SetText("Horde Kills in Ashenvale")
    f.sub = UI.Text(f, "small", UI.GREY, "LEFT"); f.sub:SetPoint("TOPLEFT", 0, -22)

    f.tabs = {}
    for i, label in ipairs({ "This week", "Last week" }) do
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(84, 20)
        b:SetPoint("TOPRIGHT", -(2 - i) * 86, 2)
        b:SetText(label)
        b:SetScript("OnClick", function() f.week = i - 1; f.offset = 0; UI.Refresh() end)
        f.tabs[i] = b
    end

    local y = -44
    local function col(text, x, w, justify)
        local h = UI.Text(f, nil, UI.GOLD, justify); h:SetPoint("TOPLEFT", x, y); h:SetWidth(w); h:SetText(text)
    end
    col("#", 0, 24, "RIGHT"); col("Name", 36, 200, "LEFT"); col("Level / class", 250, 150, "LEFT"); col("Kills", 440, 60, "RIGHT")
    local line = f:CreateTexture(nil, "ARTWORK"); line:SetColorTexture(0.35, 0.28, 0.08, 1)
    line:SetPoint("TOPLEFT", 0, y - 16); line:SetSize(508, 1)

    f.rows = {}
    for i = 1, ROWS do
        local r = CreateFrame("Frame", nil, f)
        r:SetSize(508, ROW_H)
        r:SetPoint("TOPLEFT", 0, y - 20 - (i - 1) * ROW_H)
        r.hl = r:CreateTexture(nil, "BACKGROUND"); r.hl:SetAllPoints(); r.hl:SetColorTexture(1, 0.82, 0, 0.12)
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
        f.offset = math.max(0, math.min((f.count or 0) - ROWS, f.offset - delta * 3))
        UI.Refresh()
    end)
    f.foot = UI.Text(f, "small", UI.GREY, "LEFT"); f.foot:SetPoint("BOTTOMLEFT", 0, 0); f.foot:SetWidth(508)
end

local function refresh(f)
    prune()
    local cur = LB.Week()
    local week = cur - f.week
    local rows = LB.Rows(week)
    f.count = #rows
    f.offset = math.max(0, math.min(f.offset or 0, #rows - ROWS))
    for i, b in ipairs(f.tabs) do
        if i - 1 == f.week then b:LockHighlight() else b:UnlockHighlight() end
    end
    local total = 0
    for _, r in ipairs(rows) do total = total + r.c end
    local resetAt = LB.NextReset()
    local left = resetAt - (ns.try(GetServerTime) or time())
    if f.week == 0 then
        f.sub:SetText(("Resets %s at server reset  -  %s left  -  guild total |cffffd100%d|r"):format(
            date("%A", resetAt), duration(left), total))
    else
        f.sub:SetText(("Final standings  -  guild total |cffffd100%d|r"):format(total))
    end
    for i, r in ipairs(f.rows) do
        local e = rows[i + f.offset]
        if e then
            local rank = i + f.offset
            local rc = RANK_COLOR[rank] or { 0.8, 0.8, 0.8 }
            r.rank:SetText(rank); r.rank:SetTextColor(rc[1], rc[2], rc[3])
            local cr, cg, cb = ns.classColor(e.cls)
            r.name:SetText(e.name .. (e.key == ns.meKey and " |cff9d9d9d(you)|r" or ""))
            r.name:SetTextColor(cr, cg, cb)
            local lc = {}
            if e.level then lc[#lc + 1] = e.level end
            if e.class then lc[#lc + 1] = e.class end
            r.class:SetText(table.concat(lc, " "))
            r.n:SetText(e.c)
            r.hl:SetShown(e.key == ns.meKey)
            r:Show()
        else
            r:Hide()
        end
    end
    if #rows == 0 then
        f.empty:SetText(f.week == 0 and "No kills in Ashenvale yet this week.\nGo find some Horde."
            or "Nothing recorded for last week.")
        f.empty:Show()
    else
        f.empty:Hide()
    end
    local foot = "Counts Horde killed in Ashenvale by you or your group, honour or not. Only members with the addon appear."
    if f.week == 0 then
        local last = LB.Rows(cur - 1)[1]
        if last then
            local cr, cg, cb = ns.classColor(last.cls)
            foot = foot .. (" Last week's winner: |cff%02x%02x%02x%s|r (%d)."):format(
                cr * 255, cg * 255, cb * 255, last.name, last.c)
        end
    end
    if #rows > ROWS then foot = foot .. " Scroll for more." end
    f.foot:SetText(foot)
end

ns.UI.AddPage(5, "Leaderboard", build, refresh)

---------------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------------
ns.onLogin(function()
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

ns.slash.hk = { help = "my Horde kills in Ashenvale this week", fn = function()
    ns.print(("%d Horde kills in Ashenvale this week (%d last week)."):format(LB.Mine(), LB.Mine(LB.Week() - 1)))
end }
