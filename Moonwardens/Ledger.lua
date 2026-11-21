-- Ledger: the guild's record of badge events, for the officers' Audit Log
-- and for badges no client can count by itself (Patrols...). Events are
-- only added, never changed. Two kinds so far:
--  * award: an officer gives a guildie progress toward a badge (n), or the
--    badge outright (n = 0, "grant"), with a note. `by` is the officer.
--  * claim: a guildie's client earned a badge it counts itself (kills); it
--    says so, quietly, with what it was earned on (week, count, version).
-- Everyone sends their own events to the guild; everyone keeps the ledger
-- (db.ledger). After a login one guildie who has it sends what's newer.
-- BL|1|id|kind|at|by|who|badge|n|week|value|version|note
-- BLQ|1|since                  "send me events after `since`" (GUILD)
-- `by` is checked against the sender of a BL as it comes in; one sent on in
-- a reply (catching up) is taken from its sender's word. Before officers
-- are required (OPEN below), anyone may award; then only officers, and a
-- relayed award only from an officer.
local _, ns = ...
local Ledger = {}
ns.Ledger = Ledger

-- On = anyone may award and see the Officers tab. Off (live) = officer ranks
-- only (Roster.OFFICER_RANKS: Glaivemistress, High Council, Warden-General);
-- others try it out in test mode (below).
Ledger.OPEN = false

---------------------------------------------------------------------------
-- Test mode (/mw test): the officer tools on my client, with nothing sent.
-- Awards made in it go to db.ledgerTest, never to the guild; the Badges and
-- Officers tabs show them (marked) alongside the real ones while it's on.
-- Only for officers, the guild leader, and the testers named here.
---------------------------------------------------------------------------
local TESTERS = { ["shandor moonfang"] = true }

function Ledger.TestAllowed()
    local key = ns.meKey
    if not key then return false end
    if TESTERS[key] then return true end
    if IsGuildLeader and IsGuildLeader() then return true end
    return ns.Roster and ns.Roster.IsOfficer(key) and true or false
end

function Ledger.Testing()
    return ns.db and ns.db.testMode and Ledger.TestAllowed() or false
end

local function testStore()
    ns.db.ledgerTest = ns.db.ledgerTest or {}
    return ns.db.ledgerTest
end

local KEEP = 3000          -- events kept, newest
local NOTE_MAX = 80
local CATCHUP_MAX = 400    -- events sent in one catch-up reply
local seq = 0

function Ledger.CanAward(key)
    key = key or ns.meKey
    if Ledger.OPEN then return true end
    if key == ns.meKey and Ledger.Testing() then return true end
    return ns.Roster and ns.Roster.IsOfficer(key) and true or false
end

local function store()
    ns.db.ledger = ns.db.ledger or {}
    return ns.db.ledger
end

local function clean(s, max)
    s = tostring(s or ""):gsub("[|\r\n]", " ")
    if max and #s > max then s = s:sub(1, max) end
    return s
end

local function prune()
    local l = store()
    local list = {}
    for id, e in pairs(l) do list[#list + 1] = e end
    if #list <= KEEP then return end
    table.sort(list, function(a, b) return a.at > b.at end)
    for i = KEEP + 1, #list do l[list[i].id] = nil end
end

-- Add an event (ours or heard). True if it was new.
local function add(e)
    if type(e) ~= "table" or not e.id then return false end
    local l = store()
    if l[e.id] then return false end
    l[e.id] = e
    ns.fire("LEDGER", e)
    return true
end

local function fields(e)
    return { "BL", ns.Comm.PROTO, e.id, e.kind, e.at, e.by or "", e.who or "", e.badge or "",
        e.n or 0, e.week or "", e.value or "", clean(e.version, 20), clean(e.note, NOTE_MAX) }
end

local function now() return ns.try(GetServerTime) or time() end

local function newId()
    seq = seq + 1
    return ("%x%x%03x"):format(now(), math.random(0, 0xffff), seq % 4096)
end

local function publish(e)
    add(e)
    ns.Comm.Send(fields(e), "GUILD")
end

-- Every event I can see: the guild's, and in test mode my test ones too.
local function each()
    local list = {}
    for _, e in pairs(store()) do list[#list + 1] = e end
    if Ledger.Testing() then
        for _, e in pairs(testStore()) do list[#list + 1] = e end
    end
    return list
end

---------------------------------------------------------------------------
-- Making events
---------------------------------------------------------------------------
-- An officer's award: `n` progress toward `badgeId` for guildie `who`, or the
-- badge outright with n = 0. Returns the event, or nil and why not.
function Ledger.Award(who, badgeId, n, note)
    if not Ledger.CanAward() then return nil, "Only officers can award badges." end
    local b = ns.Badges.Get(badgeId)
    if not b then return nil, "No such badge." end
    if not (who and ns.Roster.Get(who)) then return nil, "Pick a guildie on the roster." end
    n = math.floor(tonumber(n) or 0)
    if n < 0 or n > 100000 then return nil, "Progress must be 0 or more." end
    if n > 0 and b.kind ~= "manual" then return nil, "This badge counts itself; it can only be granted outright." end
    local e = { id = newId(), kind = "award", at = now(), by = ns.meKey, who = who, badge = badgeId, n = n,
        week = ns.Leaderboard and ns.Leaderboard.Week() or 0, version = ns.VERSION, note = clean(note, NOTE_MAX) }
    if Ledger.Testing() then
        -- (test mode: kept here, sent nowhere)
        e.test = true
        testStore()[e.id] = e
        ns.fire("LEDGER", e)
        return e
    end
    publish(e)
    return e
end

-- My client earned a badge it counts itself: say so, quietly.
local function claim(badgeId, times, week, value)
    local e = { id = newId(), kind = "claim", at = now(), by = ns.meKey, who = ns.meKey, badge = badgeId, n = times,
        week = week or 0, value = value or 0, version = ns.VERSION }
    publish(e)
end

-- Compare what I've earned with what I've claimed; claim what's new.
function Ledger.CheckClaims()
    if not (ns.meKey and ns.db and ns.Badges) then return end
    ns.db.badgeClaimed = ns.db.badgeClaimed or {}
    local done = ns.db.badgeClaimed
    local r = ns.Badges.Compute(ns.Badges.MyWeeks())       -- (the badges my client counts)
    for _, b in ipairs(ns.Badges.LIST) do
        if b.kind ~= "manual" then
            local e = r.badges[b.id]
            if e.times > (done[b.id] or 0) then
                claim(b.id, e.times, e.last, b.kind == "weekly" and (ns.Badges.MyWeeks()[e.last] or 0) or r.lifetime)
                done[b.id] = e.times
            end
        end
    end
end

---------------------------------------------------------------------------
-- Reading it
---------------------------------------------------------------------------
-- All events, newest first (optionally only those about `who`).
function Ledger.Events(who)
    local list = {}
    for _, e in ipairs(each()) do
        if not who or e.who == who then list[#list + 1] = e end
    end
    table.sort(list, function(a, b) if a.at ~= b.at then return a.at > b.at end return a.id > b.id end)
    return list
end

-- What officers have given `who`: { progress = { [badge] = n }, grants = { [badge] = { times, last } } }.
function Ledger.ManualFor(who)
    local out = { progress = {}, progressLast = {}, grants = {} }
    for _, e in ipairs(each()) do
        if e.kind == "award" and e.who == who then
            if (e.n or 0) > 0 then
                out.progress[e.badge] = (out.progress[e.badge] or 0) + e.n
                if (e.week or 0) > (out.progressLast[e.badge] or -1) then out.progressLast[e.badge] = e.week end
            else
                local g = out.grants[e.badge] or { times = 0 }
                g.times = g.times + 1
                if not g.last or (e.week or 0) > g.last then g.last = e.week end
                out.grants[e.badge] = g
            end
        end
    end
    return out
end

---------------------------------------------------------------------------
-- Messages
---------------------------------------------------------------------------
local function decode(f)
    local e = {
        id = f[3], kind = f[4], at = tonumber(f[5]), by = f[6] ~= "" and f[6] or nil, who = f[7] ~= "" and f[7] or nil,
        badge = f[8], n = tonumber(f[9]) or 0, week = tonumber(f[10]), value = tonumber(f[11]),
        version = f[12], note = f[13],
    }
    if type(e.id) ~= "string" or #e.id > 24 or not e.at then return nil end
    if e.kind ~= "award" and e.kind ~= "claim" then return nil end
    if not (e.who and ns.Badges.Get(e.badge)) then return nil end
    return e
end

local function onBL(f, sender, key, channel)
    local e = decode(f)
    if not e then return end
    if channel == "GUILD" then
        -- Sent by its maker: the maker is the sender, whatever it says.
        e.by = key
        if e.kind == "claim" and e.who ~= key then return end
    end
    if e.kind == "award" and not Ledger.OPEN then
        if not ns.Roster.IsOfficer(e.by) then return end
        if channel ~= "GUILD" and not ns.Roster.IsOfficer(key) then return end   -- (relayed: only an officer's word)
    end
    add(e)
end

-- Catching up: the lowest-named guildie heard from lately answers.
local function onBLQ(f, sender, key)
    local since = tonumber(f[3]) or 0
    if not (ns.Leaderboard and ns.Leaderboard.Repliers) then return end
    local who = ns.Leaderboard.Repliers(key)
    if who[1] ~= ns.meKey then return end
    local list = {}
    for _, e in pairs(store()) do if e.at > since then list[#list + 1] = e end end
    table.sort(list, function(a, b) return a.at > b.at end)
    local to = ns.address(sender)
    if not to then return end
    for i = math.min(#list, CATCHUP_MAX), 1, -1 do ns.Comm.Send(fields(list[i]), "WHISPER", to) end
end

local function newest()
    local t = 0
    for _, e in pairs(store()) do if e.at > t then t = e.at end end
    return t
end

ns.slash.test = { help = "test mode for badges: on, off, clear (officers and testers)", fn = function(rest)
    local arg = (rest or ""):lower():match("%S+") or ""
    if not Ledger.TestAllowed() then
        ns.print("Test mode is for officers, the guild leader and named testers.")
        return
    end
    if arg == "on" then
        ns.db.testMode = true
        ns.print("|cffff8040Test mode on.|r Awards you make stay on this client and are never sent. /mw test off to leave.")
    elseif arg == "off" then
        ns.db.testMode = nil
        ns.print("Test mode off. Your test awards are hidden (kept until /mw test clear).")
    elseif arg == "clear" then
        local n = 0
        for _ in pairs(testStore()) do n = n + 1 end
        ns.db.ledgerTest = {}
        ns.print(("Cleared %d test award%s."):format(n, n == 1 and "" or "s"))
    else
        local n = 0
        for _ in pairs(testStore()) do n = n + 1 end
        ns.print(("Test mode is %s; %d test award%s kept. /mw test on | off | clear"):format(
            ns.db.testMode and "|cffff8040on|r" or "off", n, n == 1 and "" or "s"))
        return
    end
    ns.fire("LEDGER")
    if ns.GuildTabs and ns.GuildTabs.Relayout then ns.GuildTabs.Relayout() end
end }

ns.onLogin(function()
    ns.Comm.handlers.BL = onBL
    ns.Comm.handlers.BLQ = onBLQ
    prune()
    ns.after(20, function()
        if IsInGuild() then ns.Comm.Send({ "BLQ", ns.Comm.PROTO, math.max(0, newest() - 60) }, "GUILD") end
    end, "ledger catch-up")
    ns.after(25, Ledger.CheckClaims, "badge claims")
    ns.every(60, Ledger.CheckClaims, "badge claims")
end, "ledger")
