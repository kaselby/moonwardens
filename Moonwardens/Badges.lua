-- Badges: what each badge is, and what a guildie has earned of them. The
-- page is BadgesUI.lua.
--
-- Badges are worked out from kill counts, per week (the Leaderboard's weeks):
-- a weekly badge from that week's count, a lifetime one from the sum of all
-- weeks. Earned badges stay earned; only a week's progress starts again.
-- Weekly tiers come round in sets: every 500 kills in a week is one Copper,
-- one Silver and one Gold; 550 is one of each and 50 into the next Copper.
--
-- My weeks are kept in db.badgeWeeks for good (the Leaderboard keeps two).
-- Another guildie's come by whisper when their badges are viewed:
-- BQ|1                        "send me your weeks"
-- BS|1|part|parts|w:c,w:c...  the weeks, in chunks under 255 bytes
-- (Officers keeping everyone's weeks, so a wiped client gets them back, is
-- the next step.)
local _, ns = ...
local Badges = {}
ns.Badges = Badges

---------------------------------------------------------------------------
-- What there is
---------------------------------------------------------------------------
-- The category tree, in order. A category with `children` is a header that
-- folds; `soon` ones show greyed with nothing in them yet.
Badges.CATEGORIES = {
    { id = "overview", name = "Overview" },
    { id = "ashenvale", name = "Ashenvale Defense", children = {
        { id = "kills", name = "Kills" },
        { id = "patrols", name = "Patrols" },
        { id = "objectives", name = "Objectives", soon = true },
    } },
}

local COIN = {
    copper = "Interface\\MoneyFrame\\UI-CopperIcon",
    silver = "Interface\\MoneyFrame\\UI-SilverIcon",
    gold = "Interface\\MoneyFrame\\UI-GoldIcon",
}
Badges.COIN = COIN
Badges.TIER_COLOR = { copper = { 0.93, 0.6, 0.35 }, silver = { 0.85, 0.87, 0.9 }, gold = { 1, 0.82, 0 } }

-- A Sentinel's moon glaive; the first of these this client has.
local WEEKLY_ICON = { "Ability_DemonHunter_ThrowGlaive", "INV_Weapon_Glaive_01", "Ability_Hunter_MarkedForDeath" }

-- (names are working names; they get settled before this ships)
Badges.LIST = {
    { id = "wk1", cat = "kills", kind = "weekly", tier = "copper", goal = 125, points = 5,
      name = "Weekly Moonblade Hunt", icon = WEEKLY_ICON,
      desc = "Kill or assist in killing 125 Horde in Ashenvale in a week." },
    { id = "wk2", cat = "kills", kind = "weekly", tier = "silver", goal = 250, points = 10,
      name = "Weekly Moonblade Hunt", icon = WEEKLY_ICON,
      desc = "Kill or assist in killing 250 Horde in Ashenvale in a week." },
    { id = "wk3", cat = "kills", kind = "weekly", tier = "gold", goal = 500, points = 25,
      name = "Weekly Moonblade Hunt", icon = WEEKLY_ICON,
      desc = "Kill or assist in killing 500 Horde in Ashenvale in a week." },
    { id = "lt1", cat = "kills", kind = "lifetime", tier = "copper", goal = 10000, points = 50,
      name = "Lifetime Wrath of the Kaldorei", icon = { "Spell_Nature_StarFall" },
      desc = "Kill or assist in killing 10,000 Horde in Ashenvale." },
    { id = "lt2", cat = "kills", kind = "lifetime", tier = "silver", goal = 25000, points = 100,
      name = "Lifetime Wrath of the Kaldorei", icon = { "Spell_Nature_StarFall" },
      desc = "Kill or assist in killing 25,000 Horde in Ashenvale." },
    { id = "lt3", cat = "kills", kind = "lifetime", tier = "gold", goal = 50000, points = 250,
      name = "Lifetime Wrath of the Kaldorei", icon = { "Spell_Nature_StarFall" },
      desc = "Kill or assist in killing 50,000 Horde in Ashenvale." },
}
-- Patrols: no client can count these; officers award the progress
-- (Ledger.lua, the Officers tab). PLACEHOLDERS for testing the awards, to be
-- replaced by the real patrol badges.
for i, t in ipairs({ { "copper", 5, 15 }, { "silver", 15, 40 }, { "gold", 30, 100 } }) do
    Badges.LIST[#Badges.LIST + 1] = {
        id = "pt" .. i, cat = "patrols", kind = "manual", tier = t[1], goal = t[2], points = t[3],
        name = "Moonwell Patrol (placeholder)", icon = { "INV_Misc_Spyglass_03", "Ability_Tracking" },
        desc = ("Ride %d patrols through Ashenvale with the guild. Officers record your patrols."):format(t[2]),
    }
end
local SET = 500   -- a full weekly set: the Gold goal

local byId = {}
for _, b in ipairs(Badges.LIST) do byId[b.id] = b end
function Badges.Get(id) return byId[id] end

-- "Weekly Moonblade Hunt: Copper"
function Badges.Title(b)
    return b.name .. ": " .. b.tier:sub(1, 1):upper() .. b.tier:sub(2)
end

function Badges.InCategory(cat)
    local list = {}
    for _, b in ipairs(Badges.LIST) do if b.cat == cat then list[#list + 1] = b end end
    return list
end

---------------------------------------------------------------------------
-- Working out what's earned
---------------------------------------------------------------------------
-- How many of a weekly tier a week's count gives.
local function weeklyTimes(b, c)
    local sets = math.floor(c / SET)
    return sets + ((c % SET) >= b.goal and 1 or 0)
end

-- A guildie's badges from their weeks ({ [week] = count }) and what officers
-- gave them (`manual`, Ledger.ManualFor: progress toward the badges officers
-- record, and badges granted outright). For each badge: times earned, when
-- last (a week), progress now (value, goal). Plus their score and the week
-- id this was worked out in.
function Badges.Compute(weeks, manual)
    weeks = weeks or {}
    manual = manual or { progress = {}, progressLast = {}, grants = {} }
    local cur = ns.Leaderboard and ns.Leaderboard.Week() or 0
    local ordered = {}
    for w, c in pairs(weeks) do
        if type(w) == "number" and type(c) == "number" and c > 0 then ordered[#ordered + 1] = w end
    end
    table.sort(ordered)
    local out, score, lifetime = {}, 0, 0
    for _, b in ipairs(Badges.LIST) do out[b.id] = { times = 0 } end
    for _, w in ipairs(ordered) do
        local c = weeks[w]
        local before = lifetime
        lifetime = lifetime + c
        for _, b in ipairs(Badges.LIST) do
            local e = out[b.id]
            if b.kind == "weekly" then
                local t = weeklyTimes(b, c)
                if t > 0 then e.times = e.times + t; e.last = w end
            elseif b.kind == "lifetime" and before < b.goal and lifetime >= b.goal then
                e.times, e.last = 1, w
            end
        end
    end
    local now = weeks[cur] or 0
    for _, b in ipairs(Badges.LIST) do
        local e = out[b.id]
        if b.kind == "weekly" then
            e.value = math.min(now % SET, b.goal)   -- (this week's run toward the next one)
        elseif b.kind == "manual" then
            local p = manual.progress[b.id] or 0
            e.value = math.min(p, b.goal)
            if p >= b.goal then e.times, e.last = 1, manual.progressLast[b.id] end
        else
            e.value = math.min(lifetime, b.goal)
        end
        -- Granted outright by an officer: on top of what's earned.
        local g = manual.grants[b.id]
        if g and g.times > 0 then
            if b.kind == "weekly" then e.times = e.times + g.times
            else e.times = math.max(e.times, 1) end
            if not e.last or (g.last or 0) > e.last then e.last = g.last end
            if b.kind ~= "weekly" then e.value = b.goal end
        end
        e.goal = b.goal
        e.points = b.points * e.times
        score = score + e.points
    end
    return { badges = out, score = score, lifetime = lifetime, week = now, at = cur }
end

-- Earned badges, most points first (then latest): the "most prestigious".
function Badges.Prestigious(result, n)
    local list = {}
    for _, b in ipairs(Badges.LIST) do
        local e = result.badges[b.id]
        if e.times > 0 then list[#list + 1] = b end
    end
    table.sort(list, function(a, b)
        if a.points ~= b.points then return a.points > b.points end
        return (result.badges[a.id].last or 0) > (result.badges[b.id].last or 0)
    end)
    while n and #list > n do table.remove(list) end
    return list
end

-- The latest badges earned, by week: { badge, week }.
function Badges.Recent(result, n)
    local list = {}
    for _, b in ipairs(Badges.LIST) do
        local e = result.badges[b.id]
        if e.times > 0 and e.last then list[#list + 1] = { badge = b, week = e.last } end
    end
    table.sort(list, function(a, b)
        if a.week ~= b.week then return a.week > b.week end
        return a.badge.points > b.badge.points
    end)
    while n and #list > n do table.remove(list) end
    return list
end

-- Badges earned (at least once) and in all, for a category (nil: all).
function Badges.CategoryCount(result, cat)
    local have, all = 0, 0
    for _, b in ipairs(Badges.LIST) do
        if not cat or b.cat == cat then
            all = all + 1
            if result.badges[b.id].times > 0 then have = have + 1 end
        end
    end
    return have, all
end

-- The date a week began, as the game shows dates.
function Badges.WeekDate(week)
    local t = ns.Leaderboard and ns.Leaderboard.WeekStart and ns.Leaderboard.WeekStart(week)
    return t and date("%m/%d/%y", t) or ""
end

---------------------------------------------------------------------------
-- My weeks
---------------------------------------------------------------------------
-- Copy my Leaderboard counts in (it keeps this week and last).
local function record()
    if not (ns.db and ns.Leaderboard) then return end
    ns.db.badgeWeeks = ns.db.badgeWeeks or {}
    local cur = ns.Leaderboard.Week()
    for w = cur - 1, cur do
        local c = ns.Leaderboard.Mine(w)
        if c > (ns.db.badgeWeeks[w] or 0) then ns.db.badgeWeeks[w] = c end
    end
end

function Badges.MyWeeks()
    record()
    return ns.db and ns.db.badgeWeeks or {}
end

local function manualFor(key)
    return ns.Ledger and ns.Ledger.ManualFor(key) or nil
end

function Badges.Mine() return Badges.Compute(Badges.MyWeeks(), manualFor(ns.meKey)) end

---------------------------------------------------------------------------
-- Other guildies' (by whisper, when their badges are viewed)
---------------------------------------------------------------------------
local others = {}          -- key -> { weeks, at, parts = {...} }
local asked = {}           -- key -> time I asked
local answered = {}        -- key -> time I answered
local ASK_GAP, ANSWER_GAP = 10, 10

-- Their weeks as far as I know: what they sent, and the Leaderboard's
-- counts for them (this week and last), the higher of each.
function Badges.WeeksOf(key)
    if key == ns.meKey then return Badges.MyWeeks() end
    local weeks = {}
    local o = others[key]
    if o then for w, c in pairs(o.weeks) do weeks[w] = c end end
    local board = ns.db and ns.db.board or {}
    for w, t in pairs(board) do
        local e = type(t) == "table" and t[key]
        if e and e.c and e.c > (weeks[w] or 0) then weeks[w] = e.c end
    end
    return weeks
end

function Badges.Of(key) return Badges.Compute(Badges.WeeksOf(key), manualFor(key)) end

-- Have they answered? (nil: never; else the time)
function Badges.HeardFrom(key) return others[key] and others[key].at end

function Badges.Request(key)
    if not key or key == ns.meKey then return end
    local m = ns.Roster and ns.Roster.Get(key)
    local to = m and m.address
    if not to then return end
    local now = ns.now()
    if asked[key] and now - asked[key] < ASK_GAP then return end
    asked[key] = now
    ns.Comm.Send({ "BQ", ns.Comm.PROTO }, "WHISPER", to)
end

local function answer(sender, key)
    local now = ns.now()
    if answered[key] and now - answered[key] < ANSWER_GAP then return end
    answered[key] = now
    local to = ns.address(sender)
    if not to then return end
    local items = {}
    for w, c in pairs(Badges.MyWeeks()) do
        if type(w) == "number" and type(c) == "number" and c > 0 then items[#items + 1] = w .. ":" .. math.floor(c) end
    end
    table.sort(items)
    -- Chunks under 255 bytes ("BS|1|nn|nn|" is at most 12).
    local chunks, cur = {}, {}
    local len = 0
    for _, it in ipairs(items) do
        if len + #it + 1 > 230 then chunks[#chunks + 1] = table.concat(cur, ","); cur, len = {}, 0 end
        cur[#cur + 1] = it; len = len + #it + 1
    end
    chunks[#chunks + 1] = table.concat(cur, ",")
    for i, s in ipairs(chunks) do
        ns.Comm.Send({ "BS", ns.Comm.PROTO, i, #chunks, s }, "WHISPER", to)
    end
end

local function onBS(f, sender, key)
    local part, parts = tonumber(f[3]), tonumber(f[4])
    if not (part and parts) or part < 1 or parts < 1 or parts > 50 or part > parts then return end
    local o = others[key]
    if not o or not o.parts or o.parts.n ~= parts then
        o = { weeks = o and o.weeks or {}, at = o and o.at, parts = { n = parts, got = {} } }
        others[key] = o
    end
    local weeks = o.parts.weeks or {}
    for w, c in (f[5] or ""):gmatch("(%d+):(%d+)") do
        w, c = tonumber(w), tonumber(c)
        if w and c and c <= 100000 then weeks[w] = c end
    end
    o.parts.weeks = weeks
    o.parts.got[part] = true
    local done = 0
    for _ in pairs(o.parts.got) do done = done + 1 end
    if done >= parts then
        o.weeks, o.at, o.parts = weeks, ns.now(), nil
        ns.fire("BADGES", key)
    end
end

ns.onLogin(function()
    ns.Comm.handlers.BQ = function(f, sender, key) answer(sender, key) end
    ns.Comm.handlers.BS = onBS
    record()
    ns.every(30, record, "badge weeks")
    ns:On("PLAYER_LOGOUT", record)
end, "badges")
