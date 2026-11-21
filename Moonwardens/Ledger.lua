-- Ledger: the guild's record of badge events, for the officers' Audit Log
-- and for badges no client can count by itself (Patrols...). Events are
-- only added, never changed: a mistake is put right by a later event. Kinds:
--  * award: an officer gives a guildie progress toward a badge (n), or the
--    badge outright (n = 0, "grant"), with a note. `by` is the officer.
--    A negative n takes progress away (a mistake), with the reason as note.
--  * claim: a guildie's client earned a badge it counts itself (kills); it
--    says so, quietly, with what it was earned on (week, count, version).
--  * revoke: an officer cancels an earlier award or claim (`ref`, its id),
--    with a reason. It stops counting; the event itself stays in the log.
--  * request: a guildie asks for progress no client can count (a patrol),
--    with a note. It waits in the Officers tab's Approvals: approving it is
--    an award that points back to it (`ref`); denying it is a deny.
--  * deny: an officer turns a request down (`ref`), with a reason.
--  * hunt: evidence of a bounty kill (Hunt.lua), for granters to grant from.
-- Everyone sends their own events to the guild; everyone keeps the ledger
-- (db.ledger). After a login one guildie who has it sends what's newer.
-- BL|1|id|kind|at|by|who|badge|n|week|value|version|note|ref
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
local HUNT_NOTE = 120       -- (a hunt's evidence; the message stays under 255)
local CATCHUP_MAX = 400    -- events sent in one catch-up reply
local seq = 0

-- May `key` grant (and award, revoke) badge `badgeId`? Officers may, for
-- every badge; a badge's `grantedBy` names others for it. Checked by every
-- client on every award it hears, from the guild roster (server data).
local function allowedFor(key, badgeId)
    if not key then return false end
    if ns.Roster and ns.Roster.IsOfficer(key) then return true end
    local b = badgeId and ns.Badges.Get(badgeId)
    for _, name in ipairs(b and b.grantedBy and b.grantedBy.names or {}) do
        if name == key then return true end
    end
    return false
end
Ledger.AllowedFor = allowedFor

-- May `key` (me if nil) grant `badgeId`, or with no badge, any badge at all
-- (the Officers tab)? On my own client, test mode allows everything.
function Ledger.CanAward(key, badgeId)
    key = key or ns.meKey
    if Ledger.OPEN then return true end
    if key == ns.meKey and Ledger.Testing() then return true end
    if badgeId then return allowedFor(key, badgeId) end
    if ns.Roster and ns.Roster.IsOfficer(key) then return true end
    for _, b in ipairs(ns.Badges.LIST) do
        if allowedFor(key, b.id) then return true end
    end
    return false
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
        e.n or 0, e.week or "", e.value or "", clean(e.version, 20), clean(e.note, e.kind == "hunt" and HUNT_NOTE or NOTE_MAX), e.ref or "" }
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
function Ledger.Award(who, badgeId, n, note, extra)
    local b = ns.Badges.Get(badgeId)
    if not b then return nil, "No such badge." end
    if not Ledger.CanAward(nil, badgeId) then return nil, ("Only %s can award this badge."):format(ns.Badges.Granters(b)) end
    if b.kind == "parent" then return nil, "Grant one of its bounties instead." end
    if not (who and ns.Roster.Get(who)) then return nil, "Pick a guildie on the roster." end
    n = math.floor(tonumber(n) or 0)
    if n < -100000 or n > 100000 then return nil, "That's too many." end
    if n ~= 0 and b.kind ~= "manual" and b.kind ~= "manualweekly" then return nil, "This badge counts itself; it can only be granted or revoked." end
    if n < 0 then
        note = clean(note, NOTE_MAX)
        if note == "" then return nil, "Say why in the note: taking progress away needs a reason." end
        local have = Ledger.ManualFor(who).progress[ns.Badges.CounterOf(b)] or 0
        if -n > have then return nil, ("They only have %d to take away."):format(have) end
    end
    local e = { id = newId(), kind = "award", at = now(), by = ns.meKey, who = who, badge = badgeId, n = n,
        week = ns.Leaderboard and ns.Leaderboard.Week() or 0, version = ns.VERSION, note = clean(note, NOTE_MAX),
        value = extra and extra.value, ref = extra and extra.ref }       -- (value: the bounty; ref: the hunt or request it came from)
    if extra and extra.week then e.week = extra.week end                  -- (an approval: the week it was reported)
    return Ledger.Commit(e)
end

-- A hunt's evidence (Hunt.lua): always sent, test mode or not; it grants
-- nothing by itself. `h`: who (the killer), value (the bounty), n (1 = it
-- passed every check), note (what was seen).
function Ledger.Hunt(h)
    local e = { id = newId(), kind = "hunt", at = now(), by = ns.meKey, who = h.who, badge = h.badge, n = h.n or 0,
        value = h.value, week = ns.Leaderboard and ns.Leaderboard.Week() or 0, version = ns.VERSION,
        note = clean(h.note, HUNT_NOTE) }
    publish(e)
    return e
end

-- The grant made from a hunt's evidence, if any (and not revoked).
function Ledger.GrantFor(huntId)
    for _, e in ipairs(Ledger.Events()) do
        if e.kind == "award" and e.ref == huntId and not Ledger.RevokeOf(e.id) then return e end
    end
end

-- Report one patrol (no client can count them): mine, done at `when` (a
-- timestamp, kept in `value`). It counts for the week it was done in. Not
-- in the future, not more than a week back, not twice for one patrol (a
-- report of mine within 30 min of it that wasn't denied).
local REPORT_BACK, REPORT_NEAR = 7 * 86400, 1800
function Ledger.Request(badgeId, when)
    local b = ns.Badges.Get(badgeId)
    if not (b and (b.requestable or b.autoRequest)) then return nil, "This badge can't be asked for." end
    if ns.Badges.CategorySoon(b.cat) then return nil, "That's coming soon." end
    when = math.floor(tonumber(when) or 0)
    local t = now()
    if when > t + 300 then return nil, "That time hasn't happened yet." end
    if when < t - REPORT_BACK then return nil, "Patrols can be reported up to a week after." end
    for _, e in ipairs(Ledger.Events(ns.meKey)) do
        if e.kind == "request" and e.value and math.abs(e.value - when) < REPORT_NEAR then
            local d = Ledger.DecisionOf(e.id)
            if not (d and d.kind == "deny") then return nil, "You already reported a patrol around then." end
        end
    end
    local LB = ns.Leaderboard
    local e = { id = newId(), kind = "request", at = t, by = ns.meKey, who = ns.meKey, badge = badgeId, n = 1,
        value = when, week = LB and LB.WeekOf and LB.WeekOf(when) or (LB and LB.Week()) or 0, version = ns.VERSION }
    return Ledger.Commit(e)
end

-- What became of a request: the award approving it, or the deny; nil while
-- it waits. (An approval later revoked still counts as decided.)
function Ledger.DecisionOf(reqId)
    for _, e in ipairs(Ledger.Events()) do
        if (e.kind == "award" or e.kind == "deny") and e.ref == reqId then return e end
    end
end

-- Requests still waiting, oldest first.
function Ledger.Pending()
    local list = {}
    for _, e in ipairs(Ledger.Events()) do
        if e.kind == "request" and not Ledger.DecisionOf(e.id) then list[#list + 1] = e end
    end
    table.sort(list, function(a, b) return a.at < b.at end)
    return list
end

-- Approve a request: the progress it asked for, as an award pointing to it.
function Ledger.Approve(reqId)
    local r = Ledger.Find(reqId)
    if not (r and r.kind == "request") then return nil, "Nothing to approve." end
    if Ledger.DecisionOf(reqId) then return nil, "Already decided." end
    if r.who == ns.meKey and not Ledger.Testing() then return nil, "Another officer has to approve your own request." end
    local b = ns.Badges.Get(r.badge)
    local counted = b and (b.kind == "manual" or b.kind == "manualweekly")
    local note = (b and b.autoRequest == "rank") and ("Rank of " .. (b.rank or "?") .. " confirmed")
        or r.value and ("Patrol of " .. ns.Dialog.When(r.value)) or "Approved request"
    -- (progress for a counted badge; for any other, the badge itself)
    return Ledger.Award(r.who, r.badge, counted and r.n or 0, note, { ref = r.id, week = r.week })
end

-- Deny a request, with a reason.
function Ledger.Deny(reqId, note)
    local r = Ledger.Find(reqId)
    if not (r and r.kind == "request") then return nil, "Nothing to deny." end
    if Ledger.DecisionOf(reqId) then return nil, "Already decided." end
    if not Ledger.CanAward(nil, r.badge) then return nil, "You can't decide this one." end
    note = clean(note, NOTE_MAX)
    if note == "" then return nil, "Say why: denying needs a reason." end
    local e = { id = newId(), kind = "deny", at = now(), by = ns.meKey, who = r.who, badge = r.badge, n = 0, ref = reqId,
        week = ns.Leaderboard and ns.Leaderboard.Week() or 0, version = ns.VERSION, note = note }
    return Ledger.Commit(e)
end



-- Record an officer's event: sent to the guild, or in test mode kept here.
function Ledger.Commit(e)
    if Ledger.Testing() then
        -- (test mode: kept here, sent nowhere)
        e.test = true
        testStore()[e.id] = e
        ns.print("|cffff8040Test " .. (e.kind == "award" and "award" or e.kind) .. "|r - kept on this client, not sent to the guild.")
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
    local r = ns.Badges.Compute(ns.Badges.MyWeeks(), nil, ns.meKey)   -- (the badges my client counts, and my rank)
    for _, b in ipairs(ns.Badges.LIST) do
        if b.kind ~= "manual" and b.kind ~= "manualweekly" and b.kind ~= "granted" and b.kind ~= "placement" then
            local e = r.badges[b.id]
            if e.times > (done[b.id] or 0) then
                -- (what it was earned on: kills, or for the captures series, captures)
                local value = r.lifetime
                if b.series and ns.Captures then
                    local byWeek, total = ns.Captures.Weeks(b.series)
                    value = b.kind == "selfweekly" and (byWeek[e.last] or 0) or total
                elseif b.kind == "weekly" then
                    value = ns.Badges.MyWeeks()[e.last] or 0
                end
                claim(b.id, e.times, e.last, value)
                done[b.id] = e.times
            end
        end
    end
    -- Badges that come with a rank (Huntress): holding it files a request
    -- for an officer to approve - once. Not again while one waits, nor
    -- after it was approved or denied (a denial stands).
    ns.db.rankRequested = ns.db.rankRequested or {}
    for _, b in ipairs(ns.Badges.LIST) do
        -- (not in test mode: the request would stay on this client and never be filed for real)
        if b.autoRequest == "rank" and not Ledger.Testing() and not ns.db.rankRequested[b.id] and ns.Badges.HasRank(ns.meKey, b.rank) then
            local asked = false
            for _, e in ipairs(Ledger.Events(ns.meKey)) do
                if e.badge == b.id and (e.kind == "request" or e.kind == "award") then asked = true end
            end
            if not asked then
                local ok = Ledger.Request(b.id, now())
                if ok then ns.print(("You hold the rank of %s: your %s badge is waiting for an officer to approve it."):format(b.rank, b.name)) end
            end
            ns.db.rankRequested[b.id] = true
        end
    end
    -- Last week's board: my place on it, once a day has passed since the
    -- reset (late counts come in). One claim per week.
    local LB = ns.Leaderboard
    if not (LB and LB.Rows and LB.WeekStart) then return end
    local week = LB.Week() - 1
    if now() < LB.WeekStart(week + 1) + 86400 then return end
    ns.db.placementClaimed = ns.db.placementClaimed or {}
    if ns.db.placementClaimed[week] then return end
    local rows = LB.Rows(week)
    if #rows == 0 then return end
    local place, prev, mine = 0, nil, nil
    for i, row in ipairs(rows) do
        if row.c ~= prev then place, prev = i, row.c end      -- (ties share the place)
        if row.key == ns.meKey then mine = { place = place, c = row.c }; break end
    end
    ns.db.placementClaimed[week] = true
    if not mine then return end
    for _, b in ipairs(ns.Badges.LIST) do
        if b.kind == "placement" and b.place == mine.place then claim(b.id, 1, week, mine.c) end
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
-- The revoke of event `id`, if it has been revoked.
function Ledger.RevokeOf(id)
    for _, e in ipairs(each()) do
        if e.kind == "revoke" and e.ref == id then return e end
    end
end

-- An event by id (the guild's, or a test one in test mode).
function Ledger.Find(id)
    for _, e in ipairs(each()) do if e.id == id then return e end end
end

-- Can this event be revoked? (Not a revoke itself, not revoked already.)
function Ledger.CanRevoke(e)
    return e and (e.kind == "award" or e.kind == "claim") and not Ledger.RevokeOf(e.id) and Ledger.CanAward(nil, e.badge) or false
end

-- Revoke an award or claim, with a reason. Returns the event, or nil and why.
function Ledger.Revoke(id, note)
    local target = Ledger.Find(id)
    if not target or not (target.kind == "award" or target.kind == "claim") then return nil, "Nothing to revoke." end
    if not Ledger.CanAward(nil, target.badge) then return nil, "You can't revoke this badge." end
    if Ledger.RevokeOf(id) then return nil, "Already revoked." end
    note = clean(note, NOTE_MAX)
    if note == "" then return nil, "Say why: revoking needs a reason." end
    local e = { id = newId(), kind = "revoke", at = now(), by = ns.meKey, who = target.who, badge = target.badge,
        n = 0, ref = id, week = ns.Leaderboard and ns.Leaderboard.Week() or 0, version = ns.VERSION, note = note }
    return Ledger.Commit(e)
end

-- The latest award or claim that gave `who` badge `badgeId` (a grant, a
-- claim) and still counts: what "Revoke Badge" takes back.
function Ledger.LatestGiving(who, badgeId)
    local best
    for _, e in ipairs(each()) do
        if e.who == who and e.badge == badgeId and ((e.kind == "award" and (e.n or 0) == 0) or e.kind == "claim")
                and not Ledger.RevokeOf(e.id) and (not best or e.at > best.at) then
            best = e
        end
    end
    return best
end

function Ledger.ManualFor(who)
    -- (`lastAt`, `progressLastAt`: when, the event's time)
    local out = { progress = {}, progressLast = {}, progressLastAt = {}, grants = {}, deduct = {}, claims = {}, weekly = {} }
    local revoked = {}
    for _, e in ipairs(each()) do
        if e.kind == "revoke" and e.ref then revoked[e.ref] = true end
    end
    for _, e in ipairs(each()) do
        if e.who == who and e.kind == "claim" then
            if revoked[e.id] then
                -- (a revoked claim: one fewer of a badge the client counts itself)
                out.deduct[e.badge] = (out.deduct[e.badge] or 0) + 1
            else
                local c = out.claims[e.badge] or { n = 0, max = 0 }
                c.n = c.n + 1
                if not c.last or (e.week or 0) > c.last then c.last = e.week end
                if (e.at or 0) > (c.lastAt or 0) then c.lastAt = e.at end
                if (e.n or 0) > c.max then c.max = e.n end      -- (a claim says how many times in all)
                out.claims[e.badge] = c
            end
        end
        if e.kind == "award" and e.who == who and not revoked[e.id] then
            local badge = ns.Badges.Resolve(e)
            if (e.n or 0) ~= 0 then
                local c = ns.Badges.CounterOf(ns.Badges.Get(e.badge)) or e.badge
                out.progress[c] = (out.progress[c] or 0) + e.n
                if e.n > 0 and (e.week or 0) > (out.progressLast[c] or -1) then out.progressLast[c] = e.week end
                if e.n > 0 and (e.at or 0) > (out.progressLastAt[c] or 0) then out.progressLastAt[c] = e.at end
                -- (and per week, for the weekly ones)
                local wk = out.weekly[c] or {}
                wk[e.week or 0] = (wk[e.week or 0] or 0) + e.n
                out.weekly[c] = wk
            else
                local g = out.grants[badge] or { times = 0 }
                g.times = g.times + 1
                if not g.last or (e.week or 0) > g.last then g.last = e.week end
                if (e.at or 0) > (g.lastAt or 0) then g.lastAt = e.at end
                out.grants[badge] = g
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
        version = f[12], note = f[13], ref = f[14] ~= "" and f[14] or nil,
    }
    if type(e.id) ~= "string" or #e.id > 24 or not e.at then return nil end
    if e.kind ~= "award" and e.kind ~= "claim" and e.kind ~= "revoke" and e.kind ~= "hunt"
        and e.kind ~= "request" and e.kind ~= "deny" then return nil end
    if e.kind == "deny" and not e.ref then return nil end
    if e.kind == "revoke" and not e.ref then return nil end
    if not (e.who and ns.Badges.Get(e.badge)) then return nil end
    return e
end

local function onBL(f, sender, key, channel)
    local e = decode(f)
    if not e then return end
    if channel == "GUILD" then
        -- Sent by its maker: the maker is the sender, whatever it says.
        e.by = key
        if (e.kind == "claim" or e.kind == "request") and e.who ~= key then return end
    end
    if (e.kind == "award" or e.kind == "revoke" or e.kind == "deny") and not Ledger.OPEN then
        -- The badge of a revoke is the badge of what it revokes.
        if not allowedFor(e.by, e.badge) then return end
        if channel ~= "GUILD" and not allowedFor(key, e.badge) then return end   -- (relayed: only a granter's word)
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
        ns.print("|cffff8040Test mode on|r until you log out or reload. Awards you make stay on this client and are never sent. /mw test off to leave.")
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
    -- Test mode never carries over: each login or reload starts without it,
    -- so nobody forgets they're in it and awards for nothing.
    if ns.db then ns.db.testMode = nil end
    ns.Comm.handlers.BL = onBL
    ns.Comm.handlers.BLQ = onBLQ
    prune()
    ns.after(20, function()
        if IsInGuild() then ns.Comm.Send({ "BLQ", ns.Comm.PROTO, math.max(0, newest() - 60) }, "GUILD") end
    end, "ledger catch-up")
    ns.after(25, Ledger.CheckClaims, "badge claims")
    ns.every(60, Ledger.CheckClaims, "badge claims")
end, "ledger")
