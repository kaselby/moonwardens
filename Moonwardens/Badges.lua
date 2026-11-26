-- Badges: what each badge is, and what a guildie has earned of them. The
-- page is BadgesUI.lua.
--
-- Badges are worked out from kill counts, per week (the Leaderboard's weeks):
-- a weekly badge from that week's count, a lifetime one from the sum of all
-- weeks. Earned badges stay earned; only a week's progress starts again.
-- A weekly tier is earned at most once a week (the Leaderboard's week, to
-- its reset): reaching it again that week counts nothing; next week it
-- can be earned again. A lifetime tier is earned once, ever.
--
-- My weeks are kept in db.badgeWeeks for good (the Leaderboard keeps two).
-- Another guildie's come by whisper when their badges are viewed:
-- BQ|1                        "send me your weeks"
-- BS|1|part|parts|w:c,w:c...  the weeks, in chunks under 255 bytes
-- BV|1|part|parts|a,b,c,id... their Showcase and Collection's order (after
--                             the weeks): the three slots (an id, or "-"
--                             for an empty one), then the rest in order
-- BW|1|a|b|c                  (to the guild) my Showcase changed: its slots,
--                             so rosters show it at once; again at login
-- (Officers keeping everyone's weeks, so a wiped client gets them back, is
-- the next step.)
local _, ns = ...
local Badges = {}
ns.Badges = Badges

-- THE FRESH START: nothing from before this moment (server time, UTC)
-- counts toward any badge - no Ledger event (awards, claims, hunts,
-- requests, the whole Audit Log), no capture, no week of kills before its
-- week. Its own week counts only the kills after each client first ran
-- this version (a client first running it a later week: none of that
-- week). Every client wipes its own copy once (Ledger.lua, Captures.lua,
-- below). Move it later only to wipe again; never earlier.
Badges.FRESH_START = 1795339200          -- 2026-11-22 09:20 UTC

-- The week of the fresh start (the Leaderboard's), once it can be known.
function Badges.FreshWeek()
    local LB = ns.Leaderboard
    return LB and LB.WeekOf and LB.WeekOf(Badges.FRESH_START) or nil
end

---------------------------------------------------------------------------
-- What there is
---------------------------------------------------------------------------
-- The category tree, in order. A category with `children` is a header that
-- folds; one without is a page of its own; `soon` ones show greyed with
-- nothing in them yet.
Badges.CATEGORIES = {
    { id = "overview", name = "Badges Overview" },
    -- Kalimdor Defense: the Leaderboard's kills and places, Ashenvale's
    -- objectives, and Kalimdor's guild outposts and forts (Captures.lua), one
    -- page. (Was two: Ashenvale Defense and Overlord.)
    { id = "kalimdor", name = "Kalimdor Defense" },
    -- Huntress Training's monthly bounties, then the Ritual of the Hunt.
    { id = "wyldhunt", name = "The Wyld Hunt" },
}

-- Categories switched off for now, in no list: their badges aren't shown,
-- reported or awarded. (Patrols: no client can count them yet.)
Badges.OFF = { patrols = true }

-- Huntress Training bounties, month by month: a release item. Each month
-- ships a new list ADDED at the end (never replace an old one: earned
-- bounties point at it). The last is this month's, the one Hunt.lua
-- watches for. A kill counts when nobody in the party is above the
-- bounty's level. Names as the game shows them.
Badges.BOUNTIES = {
    { month = "2026-11", label = "November 2026", targets = {
        -- (icons: the first this client has; npc = its NPC ID, for reference)
        { level = 13, name = "Blackmoss the Fetid", npc = 3535,     -- a rare timberling, Wellspring River
          icon = { "INV_Misc_Organ_02", "Spell_Nature_StrangleVines" } },          -- (his Moss-Twined Heart)
        -- A patrol: all three Horde Runners (elite, 19-21), within 15 minutes.
        { level = 21, name = "The Horde Runners", npc = 2477,
          names = { "Gradok", "Haren Swifthoof", "Thragomm" },     -- (NPCs 2477, 2478, 7170)
          more = "Gradok, Haren Swifthoof and Thragomm, the Horde patrol of Loch Modan",
          icon = { "INV_BannerPVP_01", "Achievement_Character_Orc_Male" } },       -- (a Horde banner)
        { level = 26, name = "Vultros", npc = 462,                  -- a rare vulture, Westfall
          icon = { "Ability_Hunter_Pet_Vulture", "Spell_Nature_RavenForm" } },
        { level = 37, name = "Ironeye the Invincible", npc = 5935,  -- a rare elite basilisk, Shimmering Flats
          icon = { "inv_treasurebasiliskmount_green", "inv_pet_-basilisk", "inv_pet_basilisk", "Ability_Hunter_Pet_Basilisk", "INV_Sword_43" } },
        { level = 56, name = "Zaricotl", npc = 2931,                -- a rare elite white buzzard, Badlands
          icon = { "Spell_Nature_RavenForm", "Ability_Hunter_Pet_Vulture" } },
    } },
}
Badges.BOUNTY = Badges.BOUNTIES[#Badges.BOUNTIES]

local COIN = {
    copper = "Interface\\MoneyFrame\\UI-CopperIcon",
    silver = "Interface\\MoneyFrame\\UI-SilverIcon",
    gold = "Interface\\MoneyFrame\\UI-GoldIcon",
    moonstone = "Interface\\Icons\\inv_misc_gem_crystal_01",      -- (a moonstone, for the tier past Gold)
}
Badges.COIN = COIN
Badges.TIER_COLOR = { copper = { 0.93, 0.6, 0.35 }, silver = { 0.85, 0.87, 0.9 }, gold = { 1, 0.82, 0 },
    moonstone = { 0.72, 0.86, 1 } }
-- Tiers, low to high. (Moonstone: the far one, past Gold.)
Badges.TIER_ORDER = { copper = 1, silver = 2, gold = 3, moonstone = 4 }

-- A Sentinel's moon glaive; the first of these this client has.
-- Elune's boundless moonlight, for a lifetime of it.
local LIFETIME_ICON = { "inv_ability_eluneschosendruid_boundlessmoonlight", "Spell_Nature_StarFall" }

-- (names are working names; they get settled before this ships)
--
-- ORDER: wherever Copper, Silver and Gold of one badge sit side by side,
-- Copper comes first, then Silver, then Gold - in this list (which sets the
-- order of the cards) and in any list made from it. Keep new tiered
-- badges in that order. Their ids never change with it.
-- (Retired ids, never to be reused: wk1-4 Moonglaive Hunt, ow1-4 Reclaim
-- Our Home, aw1-4 Uproot the Invaders, lc1-4 War-Den, uw1-4 Moon's
-- Conquest, fw1-4 Glaives at the Gate, cv the first Cadre of Vengeance,
-- fh Failed Hunt, bk1-4 Bankai! (Shobek'Aran: Elune's Reach counts it).
-- What was earned of them no longer counts.)
Badges.LIST = {
    { id = "lt1", cat = "kalimdor", kind = "lifetime", tier = "copper", goal = 10000, points = 50,
      name = "Wrath of the Kaldorei", icon = LIFETIME_ICON,
      desc = "Kill or assist in killing 10,000 Horde in Ashenvale, Mount Hyjal or Stonetalon." },
    { id = "lt2", cat = "kalimdor", kind = "lifetime", tier = "silver", goal = 25000, points = 100,
      name = "Wrath of the Kaldorei", icon = LIFETIME_ICON,
      desc = "Kill or assist in killing 25,000 Horde in Ashenvale, Mount Hyjal or Stonetalon." },
    { id = "lt3", cat = "kalimdor", kind = "lifetime", tier = "gold", goal = 50000, points = 250,
      name = "Wrath of the Kaldorei", icon = LIFETIME_ICON,
      desc = "Kill or assist in killing 50,000 Horde in Ashenvale, Mount Hyjal or Stonetalon." },
}
-- Patrols: no client can count these. Guildies report a patrol (the card's
-- Report a Patrol), officers approve it in the Officers tab (or award it
-- there themselves). One count of patrols for all three tiers (`counter`).
-- Weekly ("manualweekly"): that many patrols in one week (the week each was
-- reported), each tier once a week. Lifetime: all patrols ever.
for i, t in ipairs({ { "copper", 2, 5 }, { "silver", 4, 10 }, { "gold", 6, 20 }, { "moonstone", 10, 40 } }) do
    Badges.LIST[#Badges.LIST + 1] = {
        id = "pw" .. i, cat = "patrols", kind = "manualweekly", tier = t[1], goal = t[2], points = t[3],
        counter = "patrol", requestable = true, unit = "patrol",
        name = "Sentinel's Watch (Weekly)", icon = { "achievement_zone_ashenvale_01", "INV_Misc_Spyglass_03" },
        desc = ("Complete %d Moonwardens patrols in a week."):format(t[2]),
    }
end
for i, t in ipairs({ { "copper", 5, 15 }, { "silver", 15, 40 }, { "gold", 30, 100 }, { "moonstone", 75, 250 } }) do
    Badges.LIST[#Badges.LIST + 1] = {
        id = "pt" .. i, cat = "patrols", kind = "manual", tier = t[1], goal = t[2], points = t[3],
        counter = "patrol", requestable = true, unit = "patrol",
        name = "Owl's Vigilance", icon = { "ability_hunter_sentinelowl", "achievement_zone_ashenvale_01" },
        desc = ("Complete %d Moonwardens patrols."):format(t[2]),
    }
end
-- Objectives (Captures.lua, by `series`): Overlord's capture points, guild
-- outposts and forts taken for our side while you were inside them -
-- outposts worth a little more than capture points, forts a bit more
-- again - and Total Victory on the Ashenvale front with your raid. Weekly
-- (none now): that many in one week, each tier once a week. Lifetime: all
-- of them.
-- Counted by your own client and claimed as Kills badges are.
-- PLACEHOLDER names and numbers.
-- (`what`: "X" names them "X (Weekly)" and "X"; or their own
-- names, { weekly, lifetime }, either nil for the usual.
-- `icon`: one list for both, or { weekly = list, lifetime = list }.
-- `descW` / `descL`: own wording, given the count; else the usual)
local function objectiveSet(cat, series, idW, idL, what, plural, icon, weekly, lifetime, descW, descL)
    local own = type(what) == "table" and what or {}
    local base = type(what) == "string" and what or ""
    local nameW, nameL = own[1] or (base .. " (Weekly)"), own[2] or base
    local iconW, iconL = icon.weekly or icon, icon.lifetime or icon
    for i, t in ipairs(weekly) do
        Badges.LIST[#Badges.LIST + 1] = {
            id = idW .. i, cat = cat, kind = "selfweekly", series = series, tier = t[1], goal = t[2], points = t[3],
            name = nameW, icon = iconW, unit = plural,
            desc = descW and descW(t[2]) or ("Be inside %d %s as they're taken for the Alliance, in one week."):format(t[2], plural),
        }
    end
    for i, t in ipairs(lifetime) do
        Badges.LIST[#Badges.LIST + 1] = {
            id = idL .. i, cat = cat, kind = "selflifetime", series = series, tier = t[1], goal = t[2], points = t[3],
            name = nameL, icon = iconL, unit = plural,
            desc = descL and descL(t[2]) or ("Be inside %d %s as they're taken for the Alliance."):format(t[2], plural),
        }
    end
end
-- Total Victory, in tiers by how many in all ("selflifetime"). The first
-- keeps the id it had alone ("tv"), so a victory claimed before still counts.
for i, t in ipairs({ { "copper", 1, 50 }, { "silver", 5, 100 }, { "gold", 10, 200 }, { "moonstone", 20, 400 } }) do
    Badges.LIST[#Badges.LIST + 1] = {
        id = i == 1 and "tv" or ("tv" .. i), cat = "kalimdor", kind = "selflifetime", series = "victory",
        tier = t[1], goal = t[2], points = t[3], unit = "total victories",
        name = "Tor ilisar'thera'nal!", icon = { "inv_misc_head_orc_01", "INV_BannerPVP_02" },
        desc = t[2] == 1 and "Be in the party or raid that takes all of Ashenvale on Overlord."
            or ("Be in the party or raid that takes all of Ashenvale on Overlord %d times."):format(t[2]),
    }
end
-- Holding the line: inside one of Splintertree Post's two approaches
-- (Overlord's prerequisites for it) as it falls - each time counts again
-- (Captures.lua, series "support").
Badges.LIST[#Badges.LIST + 1] = {
    id = "dp", cat = "kalimdor", kind = "selfcount", series = "support", points = 25, goal = 1,
    name = "I'm Doing My Part!", icon = { "ability_warrior_rallyingcry", "INV_BannerPVP_02" },
    desc = "Be inside Dor'Danil Barrow Den or Raynewood Retreat when Splintertree Post is captured.",
}
-- Kalimdor Defense: the Ashenvale front's capture points (no other
-- front's).
objectiveSet("kalimdor", "captures", "ow", "ol", { nil, "Protect Our Sacred Groves" }, "Ashenvale capture points",
    { "spell_nature_protectionformnature", "Achievement_BG_winWSG" },
    {},
    { { "copper", 100, 25 }, { "silver", 400, 50 }, { "gold", 1000, 100 }, { "moonstone", 2500, 250 } },
    nil,
    function(n) return ("Be inside %d Ashenvale capture points when they are captured."):format(n) end)
-- Overlord: Kalimdor's guild outposts and forts (guild keeps) only (which
-- ones: Captures.REGION; Shobek'Aran among them).
-- (Their counts: about double the first ones at the low tiers, a third
-- more at the high.)
objectiveSet("kalimdor", "outposts", "uw", "ul", { nil, "Elune's Reach" }, "guild outposts",
    { "spell_holy_elunesgrace", "Spell_Nature_StarFall" },
    {},
    { { "copper", 20, 35 }, { "silver", 60, 75 }, { "gold", 100, 150 }, { "moonstone", 195, 300 } },
    nil,
    function(n) return ("Be inside %d of Kalimdor's Outposts as they're captured."):format(n) end)
objectiveSet("kalimdor", "forts", "fw", "fl", { nil, "Ancient of War" }, "forts",
    { "inv_misc_tournaments_symbol_nightelf", "INV_Misc_Tournaments_banner_Nightelf" },
    {},
    { { "copper", 10, 50 }, { "silver", 30, 100 }, { "gold", 55, 200 }, { "moonstone", 105, 400 } },
    nil,
    function(n) return ("Be inside %d of Kalimdor's Guild Keeps as they're captured."):format(n) end)
-- (only Overlord can see them taken - capture points, outposts, forts:
-- `requires` puts a note on their cards and tooltips, Badges.Needs. Not
-- Total Victory: a groupmate with Overlord can tell it, TV.)
local NEEDS_OVERLORD = { captures = true, support = true, outposts = true, forts = true }
for _, b in ipairs(Badges.LIST) do
    if NEEDS_OVERLORD[b.series] then b.requires = "Overlord" end
end
-- Leaderboard ("placement"): 1st, 2nd or 3rd on a week's final Horde kills
-- board (ties share the place). Each guildie's client claims its own, a day
-- after the reset, once late counts are in.
-- (Copper first, as everywhere; the id is the place: lb1 = 1st = Gold)
for _, t in ipairs({ { "copper", 3, 10 }, { "silver", 2, 15 }, { "gold", 1, 25 } }) do
    Badges.LIST[#Badges.LIST + 1] = {
        id = "lb" .. t[2], cat = "kalimdor", kind = "placement", tier = t[1], place = t[2], points = t[3], goal = 1,
        lead = true,       -- (first of its page's badges not earned yet)
        name = "Chosen of Elune (Weekly)", icon = { "spell_nature_moonglow" },
        desc = ("Place %s on the weekly Horde kills leaderboard."):format(({ "first", "second", "third" })[t[2]]),
    }
end
-- The Wyld Hunt. Kinds: "granted" (only ever granted, by those its
-- `grantedBy` names, officers always; `stack`: each grant counts again) and
-- "rank" (comes with holding a guild rank).
local SUELEVIN = { names = { "suelevin stormsong" } }
-- (listed after the bounties, below)
-- `noInfo`: the card shows no line under its description (no "Granted
-- by...", no rank request text, no progress bar). We don't need that
-- additional detail on these: the description says it all.
local RITUAL = {
    -- (id "hp": it was Hunting Party; what was earned of it carries over)
    { id = "hp", cat = "wyldhunt", kind = "granted", stack = true, points = 10, noInfo = true,
      name = "Cadre of Vengeance", icon = { "Ability_Tracking", "Ability_Hunter_BeastCall" },
      desc = "Aid another Moonwarden in the successful completion of their Wyld Hunt." },
    -- Not automatic: officers are promoted through Huntress, so holding the
    -- rank (or one above) only files a request (autoRequest); an officer
    -- approves it in Approvals before it counts.
    { id = "hr", cat = "wyldhunt", kind = "granted", rank = "Huntress", autoRequest = "rank", points = 100, noInfo = true,
      name = "Vengeance Abides", icon = { "achievement_boss_councilsentinel", "Ability_Mount_WhiteTiger" },
      desc = "Earn the rank of Huntress." },
}
---------------------------------------------------------------------------
-- COMPOUND BADGES - THE TEMPLATE FOR EVERY BADGE MADE OF OTHER BADGES
---------------------------------------------------------------------------
-- Any badge that groups other badges (as Legacy Challenges' "Explore
-- Eastern Kingdoms" groups its zones) is made with Badges.Compound, and
-- nothing else. The monthly bounties below are the first; every compound
-- badge from now on - more monthly hunts, patrol routes, event series,
-- anything of the kind - is made the same way, so all of them follow the
-- same rules and get the same card (BadgesUI.lua draws any "parent").
--
-- The rules every compound badge keeps:
--   * The PARENT is only a container: no points, never granted or claimed.
--     It shows "done / all" and, on its shield, the points its children
--     have earned. It's complete (check and date) when every child is.
--   * Each CHILD is a badge of its own: its own points, granting rules,
--     tooltip and Audit Log entries, earned on its own. It's shown only
--     inside its parent's card, never as a card of its own, so lists don't
--     pile up as months go by. (Recent and Most Prestigious still list it;
--     clicking it there opens the parent's card.)
--   * The parent's card folds its children away with a click (Legacy's
--     +/-); folded at first, each parent remembers being opened. A child's row shows its icon,
--     label, points (on a small shield) and a check once earned.
--   * `active`: while true the parent is never greyed out (it's there to be
--     done). Afterwards it's grey only if none of its children was earned.
--   * Ids are forever: a parent's id and its children's are what earned
--     badges point at. Never reuse or renumber them; add new ones instead.
--
-- Badges.Compound{
--     id = "bh:2026-11",                      -- unique, never reused
--     cat = "wyldhunt",                       -- the category it's listed in
--     name = "Huntress Training: Nov, 2026",
--     desc = "Complete any ... from November 2026.\nNo one in ...",
--     icon = { "Ability_Hunter_MarkedForDeath" },   -- first the client has
--     listLabel = "Includes",                 -- heading over the children (nil: none)
--     active = true,                          -- see above
--     children = {                            -- each a full badge (kind, points, ...)
--         { id = "bh:2026-11:1", kind = "granted", points = 50,
--           name = "Hunt Target: Blackmoss the Fetid",   -- its own title, tooltips, log
--           label = "|cffffd100Lv 13|r  Blackmoss the Fetid",   -- its row in the card
--           desc = "...", icon = { ... } },
--     },
-- }
-- Children take the parent's category and get goal = 1 unless they say
-- otherwise. Returns the parent.
function Badges.Compound(def)
    local parent = {
        id = def.id, cat = def.cat, kind = "parent", points = 0, children = {},
        name = def.name, desc = def.desc or "", icon = def.icon,
        listLabel = def.listLabel, active = def.active and true or false,
    }
    for k, v in pairs(def.extra or {}) do parent[k] = v end
    Badges.LIST[#Badges.LIST + 1] = parent
    for _, child in ipairs(def.children or {}) do
        child.parent = parent.id
        child.cat = child.cat or parent.cat
        child.goal = child.goal or 1
        parent.children[#parent.children + 1] = child.id
        Badges.LIST[#Badges.LIST + 1] = child
    end
    parent.goal = #parent.children
    return parent
end

-- The monthly bounties, made with the template: a parent per month, newest
-- first, and a child for each bounty (50 points, granted once by officers
-- or Suelevin). Child ids: "bh:2026-11:3".
local BOUNTY_ICON = { "Ability_Hunter_MarkedForDeath", "Ability_Hunter_SniperShot" }
-- "2026-11" -> "Nov, 2026"
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local function shortMonth(month)
    local y, mo = month:match("^(%d+)-(%d+)$")
    return (y and MONTHS[tonumber(mo)]) and (MONTHS[tonumber(mo)] .. ", " .. y) or month
end
for mi = #Badges.BOUNTIES, 1, -1 do
    local m = Badges.BOUNTIES[mi]
    local pid = "bh:" .. m.month
    local children = {}
    for i, t in ipairs(m.targets) do
        local icon = t.icon and { unpack(t.icon) } or { unpack(BOUNTY_ICON) }
        if t.icon then icon[#icon + 1] = BOUNTY_ICON[1] end   -- (never a question mark)
        children[#children + 1] = {
            id = pid .. ":" .. i, kind = "granted", points = 50, grantedBy = SUELEVIN,
            month = m.month, index = i, level = t.level, target = t,
            name = "Hunt Target: " .. t.name, label = ("|cffffd100Lv %d|r  %s"):format(t.level, t.name), icon = icon,
            desc = ("Complete the level %d Huntress Training bounty: %s."):format(t.level, t.more or t.name),
        }
    end
    Badges.Compound({
        id = pid, cat = "wyldhunt", icon = BOUNTY_ICON,
        name = "Huntress Training: " .. shortMonth(m.month),
        desc = ("Complete any Huntress Training bounty from %s.\nNo one in your party may be above the bounty's level."):format(m.label),
        -- (noInfo: no "Bounties: x / y" bar - we don't need that additional
        -- detail on these; the rows and their checks show it)
        active = mi == #Badges.BOUNTIES,
        extra = { month = m.month, noInfo = true },
        children = children,
    })
end

-- The Ritual of the Hunt, after the bounties.
for _, b in ipairs(RITUAL) do
    b.goal = 1
    Badges.LIST[#Badges.LIST + 1] = b
end

-- This month's child badge for bounty `index` (Hunt.lua).
function Badges.BountyChild(index)
    return "bh:" .. Badges.BOUNTY.month .. ":" .. index
end

-- Events from before bounties were badges of their own ("bh" and a bounty
-- number): the child badge they mean.
function Badges.Resolve(e)
    if e.badge == "bh" and e.value then return "bh:" .. date("%Y-%m", e.at) .. ":" .. e.value end
    return e.badge
end

-- Moonstone for the kills (past Gold: 100,000 in all).
Badges.LIST[#Badges.LIST + 1] = { id = "lt4", cat = "kalimdor", kind = "lifetime", tier = "moonstone", goal = 100000, points = 500,
    name = "Wrath of the Kaldorei", icon = LIFETIME_ICON,
    desc = "Kill or assist in killing 100,000 Horde in Ashenvale, Mount Hyjal or Stonetalon." }

---------------------------------------------------------------------------
-- TIER TRACKS: one card for all the tiers of a badge
---------------------------------------------------------------------------
-- The Copper, Silver, Gold and Moonstone of one badge (same category, same
-- name) are one TRACK and show as ONE card: the next tier to earn, with its
-- progress; the tiers already earned as coin counters on the ribbon. Each
-- tier stays a badge of its own underneath (its id, points, claims, Audit
-- Log entries), so nothing earned moves. Tiers are tracked by `track`,
-- given here to every tiered badge; their order is Badges.TIER_ORDER.
-- (Not a compound badge: those group different badges - Badges.Compound.)
-- What a badge's goal counts, in one word, for the Tiers tooltip
-- ("Copper 10,000 kills", "Gold 1st place"). By what's counted; a badge can
-- say its own (`measure`).
local MEASURE = { captures = "captures", shobekaran = "captures", lesi_cave = "captures", ashenvale_outposts = "captures",
    outposts = "outposts", forts = "forts", victory = "victories" }
for _, b in ipairs(Badges.LIST) do
    if not b.measure then
        if b.kind == "lifetime" or b.kind == "weekly" then b.measure = "kills"
        elseif b.kind == "placement" then b.measure = "place"
        elseif b.counter == "patrol" then b.measure = "patrols"
        elseif b.series then b.measure = MEASURE[b.series] end
    end
end

Badges.TRACKS = {}
for _, b in ipairs(Badges.LIST) do
    if b.tier and not b.parent then
        b.track = b.track or (b.cat .. ":" .. b.name)
        local t = Badges.TRACKS[b.track]
        if not t then t = { id = b.track, name = b.name, tiers = {} }; Badges.TRACKS[b.track] = t end
        t.tiers[#t.tiers + 1] = b
    end
end
for _, t in pairs(Badges.TRACKS) do
    table.sort(t.tiers, function(x, y) return Badges.TIER_ORDER[x.tier] < Badges.TIER_ORDER[y.tier] end)
end
-- Placements have no progress to show: one line of what the track is.
for _, b in ipairs(Badges.LIST) do
    if b.kind == "placement" and b.track and Badges.TRACKS[b.track] then
        Badges.TRACKS[b.track].desc = "Place in the top three on the weekly Horde kills leaderboard."
    end
end

-- Where a guildie stands on a track: the tier to show (the next to earn:
-- weekly, the first not yet reached this week; else the first never
-- earned; all done, the top one), and whether any tier was ever earned.
function Badges.TrackState(trackId, result)
    local t = Badges.TRACKS[trackId]
    if not t then return nil end
    local cur, any = nil, false
    for _, b in ipairs(t.tiers) do
        local e = result.badges[b.id]
        if e.times > 0 then any = true end
        local weekly = b.kind == "weekly" or b.kind == "manualweekly" or b.kind == "selfweekly"
        -- (placements, like lifetime tiers: the lowest never earned yet - Copper first, as everywhere)
        local reached = weekly and (e.value or 0) >= (e.goal or 1) or (not weekly and e.times > 0)
        if not cur and not reached then cur = b end
    end
    return { track = t, current = cur or t.tiers[#t.tiers], any = any, done = cur == nil }
end

local byId = {}
for _, b in ipairs(Badges.LIST) do byId[b.id] = b end
function Badges.Get(id) return byId[id] end

-- The addon a badge needs, as its card and tooltip say it (in gold, under
-- its progress), or nil (`requires`).
function Badges.Needs(b)
    return b.requires and ("Requires the %s addon."):format(b.requires) or nil
end

-- Is a category switched off for now ("coming soon")?
local soonCats
function Badges.CategorySoon(cat)
    if not soonCats then
        soonCats = {}
        for id in pairs(Badges.OFF) do soonCats[id] = true end
        for _, top in ipairs(Badges.CATEGORIES) do
            if top.soon then soonCats[top.id] = true end
            for _, c in ipairs(top.children or {}) do if c.soon then soonCats[c.id] = true end end
        end
    end
    return soonCats[cat] or false
end

-- The pages: categories with no children (the Overview too), and those
-- folded under a header. { id, name, top } in order; `top` is the header's
-- name, if any.
function Badges.Pages()
    local out = {}
    for _, top in ipairs(Badges.CATEGORIES) do
        if top.children then
            for _, c in ipairs(top.children) do out[#out + 1] = { id = c.id, name = c.name, top = top.name, soon = c.soon } end
        else
            out[#out + 1] = { id = top.id, name = top.name, soon = top.soon }
        end
    end
    return out
end
function Badges.IsPage(cat)
    for _, p in ipairs(Badges.Pages()) do if p.id == cat then return true end end
    return false
end

-- What a manual badge's progress is counted in: its counter, shared by its
-- tiers (patrols), or the badge itself.
function Badges.CounterOf(b) return b and (b.counter or b.id) end

-- A badge's title: its name. The tier is never in it: it's the coin, in the
-- corner of the badge's icon wherever the icon shows, and in front of the
-- name (Badges.Coin) wherever only text does - dropdowns, tooltips, prompts.
function Badges.Title(b)
    return b.name
end

-- "Copper", "Moonstone"... (nil: not a tiered badge)
function Badges.TierName(b)
    return b.tier and (b.tier:sub(1, 1):upper() .. b.tier:sub(2)) or nil
end

-- The tier's coin as text ("|T...|t "), for text with no icon; "" untiered.
function Badges.Coin(b, size)
    if not (b and b.tier and COIN[b.tier]) then return "" end
    size = size or 14
    return ("|T%s:%d:%d|t "):format(COIN[b.tier], size, size)
end

-- Does guildie `key` hold rank `rankName` - that rank itself, not one above
-- it (officers aren't Huntresses)? (Server data: the roster's rank.)
function Badges.HasRank(key, rankName)
    local m = key and ns.Roster and ns.Roster.Get(key)
    if not (m and rankName) then return false end
    return m.rank == rankName
end

-- Who can grant a badge, as text: "officers and Suelevin Stormsong".
function Badges.Granters(b)
    local names = { "officers" }
    for _, key in ipairs(b.grantedBy and b.grantedBy.names or {}) do
        local m = ns.Roster and ns.Roster.Get(key)
        names[#names + 1] = m and m.name or key:gsub("(%a)(%w*)", function(a, r) return a:upper() .. r end)
    end
    if #names == 1 then return names[1] end
    return table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end

-- A category's badges, as cards. A child (a bounty) is shown only inside
-- its parent's card, never as a card of its own: months of bounties would
-- otherwise pile up.
function Badges.InCategory(cat)
    local list, tracks = {}, {}
    for _, b in ipairs(Badges.LIST) do
        -- (a tier track: one card, for its first tier; BadgesUI draws the track)
        if b.cat == cat and not b.parent and not (b.track and tracks[b.track]) then
            if b.track then tracks[b.track] = true end
            list[#list + 1] = b
        end
    end
    return list
end

-- What a badge can be granted as: itself, or for a parent, its children.
function Badges.Grantable(cat)
    local list = {}
    for _, b in ipairs(Badges.LIST) do
        if b.cat == cat and b.kind ~= "parent" then list[#list + 1] = b end
    end
    return list
end

---------------------------------------------------------------------------
-- Working out what's earned
---------------------------------------------------------------------------

-- A guildie's badges from their weeks ({ [week] = count }) and what officers
-- gave them (`manual`, Ledger.ManualFor: progress toward the badges officers
-- record, and badges granted outright). For each badge: times earned, when
-- last (a week), progress now (value, goal). Plus their score and the week
-- id this was worked out in.
function Badges.Compute(weeks, manual, key)
    weeks = weeks or {}
    manual = manual or { progress = {}, progressLast = {}, grants = {}, deduct = {} }
    manual.deduct = manual.deduct or {}
    manual.claims = manual.claims or {}
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
                -- (once a week at most: past the goal that week counts nothing more)
                if c >= b.goal then e.times = e.times + 1; e.last = w end
            elseif b.kind == "lifetime" and before < b.goal and lifetime >= b.goal then
                e.times, e.last = 1, w
            end
        end
    end
    local now = weeks[cur] or 0
    for _, b in ipairs(Badges.LIST) do
        local e = out[b.id]
        if b.kind == "weekly" then
            -- (this week's count toward it; reached, it stays full until the reset)
            e.value = math.min(now, b.goal)
        elseif b.kind == "manual" then
            local c = Badges.CounterOf(b)
            local p = math.max(0, manual.progress[c] or 0)
            e.value = math.min(p, b.goal)
            if p >= b.goal then e.times, e.last = 1, manual.progressLast[c] end
        elseif b.kind == "manualweekly" then
            local byWeek = manual.weekly and manual.weekly[Badges.CounterOf(b)] or {}
            for w, n in pairs(byWeek) do
                if n >= b.goal then
                    e.times = e.times + 1
                    if not e.last or w > e.last then e.last = w end
                end
            end
            e.value = math.min(math.max(0, byWeek[cur] or 0), b.goal)
        elseif b.kind == "placement" then
            local c = manual.claims[b.id]
            e.times = c and c.n or 0
            e.last = c and c.last
            e.value = e.times
        elseif b.kind == "selfweekly" or b.kind == "selflifetime" or b.kind == "selfcount" then
            -- Counted by the guildie's own client (mine: here; Captures.lua).
            -- Theirs, and mine after a wipe: from their standing claims.
            local c = manual.claims[b.id]
            local times, last, value = 0, nil, 0
            if key and key == ns.meKey and b.series and ns.Captures then
                local byWeek, total = ns.Captures.Weeks(b.series)
                if b.kind == "selfcount" then
                    times, value = total, total
                    for w in pairs(byWeek) do if not last or w > last then last = w end end
                elseif b.kind == "selfweekly" then
                    for w, n in pairs(byWeek) do
                        if n >= b.goal then
                            times = times + 1
                            if not last or w > last then last = w end
                        end
                    end
                    value = math.min(byWeek[cur] or 0, b.goal)
                else
                    if total >= b.goal then times = 1 end
                    value = math.min(total, b.goal)
                end
            end
            if c and (c.max or 0) > times then times, last = c.max, c.last end
            if b.kind == "selflifetime" then times = math.min(times, 1) end   -- (reached once: no "x2")
            e.times = times
            e.last = last or (times > 0 and c and c.last) or nil
            e.value = value
        elseif b.kind == "granted" or b.kind == "rank" then
            e.value = 0
        else
            e.value = math.min(lifetime, b.goal)
        end
        -- Granted outright by an officer: on top of what's earned.
        local g = manual.grants[b.id]
        if g and g.times > 0 then
            if b.kind == "weekly" or b.kind == "manualweekly" or b.kind == "placement" or b.stack then e.times = e.times + g.times
            else e.times = math.max(e.times, 1) end
            if not e.last or (g.last or 0) > e.last then e.last = g.last end
            if b.kind ~= "weekly" then e.value = b.goal end
        end
        -- Revoked by an officer (a claim taken back): that many fewer.
        local d = manual.deduct[b.id] or 0
        if d > 0 and b.kind ~= "placement" and b.kind ~= "selfweekly" and b.kind ~= "selflifetime" and b.kind ~= "selfcount" then   -- (placements count only standing claims already)
            e.times = math.max(0, e.times - d)
            if e.times == 0 then e.last = nil end
        end
        -- A rank badge: held while the roster shows the rank, and kept
        -- after by its claim.
        if b.kind == "rank" then
            local c = manual.claims[b.id]
            if Badges.HasRank(key, b.rank) or (c and c.n > 0) then
                e.times = 1
                e.last = e.last or (c and c.last) or cur
            end
            e.value = e.times
        end
        -- When it was last earned (a time): the latest of its claims, grants
        -- and, for the ones officers count, progress. (Nil: not known.)
        if e.times > 0 then
            local at = 0
            local c, g = manual.claims[b.id], manual.grants[b.id]
            if c and (c.lastAt or 0) > at then at = c.lastAt end
            if g and (g.lastAt or 0) > at then at = g.lastAt end
            if b.kind == "manual" or b.kind == "manualweekly" then
                local p = manual.progressLastAt and manual.progressLastAt[Badges.CounterOf(b)]
                if (p or 0) > at then at = p end
            end
            e.lastAt = at > 0 and at or nil
        end
        e.goal = b.goal
        e.points = b.points * e.times
        score = score + e.points
    end
    -- A track that counts up (kills, captures, victories, patrols, all
    -- time): a tier earned or granted means every tier under it was reached
    -- - earned too, at their goals. (Weekly and placement tiers each stand
    -- alone.)
    local CUMULATIVE = { lifetime = true, selflifetime = true, manual = true }
    for _, t in pairs(Badges.TRACKS) do
        local top
        for i = #t.tiers, 1, -1 do
            local tb = t.tiers[i]
            if CUMULATIVE[tb.kind] and out[tb.id].times > 0 then top = i; break end
        end
        local hi = top and out[t.tiers[top].id]
        for i = 1, (top or 1) - 1 do
            local tb = t.tiers[i]
            local e = out[tb.id]
            if CUMULATIVE[tb.kind] and e.times == 0 then
                e.times, e.last, e.lastAt, e.value = 1, hi.last, hi.lastAt, tb.goal
                e.points = tb.points
                score = score + e.points
            end
        end
    end
    -- Parents: how many of their children are done; complete when all are.
    for _, b in ipairs(Badges.LIST) do
        if b.kind == "parent" then
            local e, done, last, lastAt = out[b.id], 0, nil, nil
            for _, cid in ipairs(b.children) do
                local c = out[cid]
                if c and c.times > 0 then
                    done = done + 1
                    if not last or (c.last or 0) > last then last = c.last end
                    if (c.lastAt or 0) > (lastAt or 0) then lastAt = c.lastAt end
                end
            end
            e.value, e.goal, e.points = done, #b.children, 0
            e.times = (done > 0 and done == #b.children) and 1 or 0
            e.last = e.times > 0 and last or nil
            e.lastAt = e.times > 0 and lastAt or nil
            local pts = 0
            for _, cid in ipairs(b.children) do pts = pts + (out[cid] and out[cid].points or 0) end
            e.childPoints = pts
        end
    end
    return { badges = out, score = score, lifetime = lifetime, week = now, at = cur }
end

-- Earned badges, most points first (then latest): the "most prestigious".
function Badges.Prestigious(result, n)
    local list = {}
    for _, b in ipairs(Badges.LIST) do
        local e = result.badges[b.id]
        if e.times > 0 and b.points > 0 then list[#list + 1] = b end   -- (a 0-point badge is no honour)
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
        if e.times > 0 and e.last and b.kind ~= "parent" then list[#list + 1] = { badge = b, week = e.last } end
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
        if (not cat or b.cat == cat) and b.kind ~= "parent" then      -- (a parent's children count, not it)
            all = all + 1
            if result.badges[b.id].times > 0 then have = have + 1 end
        end
    end
    return have, all
end

---------------------------------------------------------------------------
-- The Showcase and the Collection
---------------------------------------------------------------------------
-- A guildie's earned badges, as icons in two parts: the Showcase (three
-- slots, each a badge or empty, picked and placed by them) and the
-- Collection (all the rest, in their order). Mine are arranged by dragging
-- (BadgesUI.lua's board) and kept in MoonwardensDB.badgeLayout =
-- { showcase = { id or false, x3 }, order = { id... } }; another guildie's
-- come by whisper (BV) with their weeks, and their Showcase to the guild
-- whenever it changes (BW). Never arranged: the Showcase is the three most
-- prestigious, the Collection by points. Badges earned since the last
-- arranging go first in the Collection, to be seen. A tier track is shown
-- by its best tier earned, wherever its tiers were placed.
Badges.SHOWCASE_N = 3
local layouts = {}         -- key -> { showcase, order }, another guildie's

-- A badge's points (a parent's: its children's).
function Badges.PointsOf(b)
    if b.kind ~= "parent" then return b.points or 0 end
    local n = 0
    for _, cid in ipairs(b.children or {}) do local c = byId[cid]; n = n + (c and c.points or 0) end
    return n
end

-- When it was last earned: the time, else its week's start, else 0.
local function earnedAt(e)
    if e.lastAt then return e.lastAt end
    local LB = ns.Leaderboard
    return (e.last and LB and LB.WeekStart and LB.WeekStart(e.last)) or 0
end

-- The orders the Collection can be shown in (the Badge Chest's dropdown).
Badges.SORTS = {
    { id = "arranged", text = "As arranged" },
    -- (hidden for now, while badges' points aren't shown; still how new
    -- badges and ties are ordered)
    { id = "pointsDesc", text = "Points: high to low", hidden = true },
    { id = "pointsAsc", text = "Points: low to high", hidden = true },
    { id = "newest", text = "Date earned: newest first" },
    { id = "oldest", text = "Date earned: oldest first" },
}

local function sortBy(s)
    return function(x, y)
        if s == "pointsDesc" and x.pts ~= y.pts then return x.pts > y.pts end
        if s == "pointsAsc" and x.pts ~= y.pts then return x.pts < y.pts end
        if s == "newest" and x.at ~= y.at then return x.at > y.at end
        if s == "oldest" and x.at ~= y.at then return x.at < y.at end
        -- (ties: the higher points, then the name, then the tier)
        if x.pts ~= y.pts then return x.pts > y.pts end
        local tx, ty = Badges.Title(x.b), Badges.Title(y.b)
        if tx ~= ty then return tx < ty end
        return (Badges.TIER_ORDER[x.b.tier] or 0) < (Badges.TIER_ORDER[y.b.tier] or 0)
    end
end

-- Like badges together: a tier track's tiers side by side (Copper first,
-- as everywhere), the track placed where its first tier falls in `cmp`'s
-- order (sorted by points high to low, where its best one is; arranged,
-- where its first-placed one is).
local function groupOf(b) return b.track or b.id end
local function grouped(list, cmp)
    table.sort(list, cmp)
    local lead = {}
    for i, it in ipairs(list) do
        local g = groupOf(it.b)
        if not lead[g] then lead[g] = i end
    end
    table.sort(list, function(x, y)
        local gx, gy = groupOf(x.b), groupOf(y.b)
        if gx ~= gy then return lead[gx] < lead[gy] end
        return (Badges.TIER_ORDER[x.b.tier] or 0) < (Badges.TIER_ORDER[y.b.tier] or 0)
    end)
    return list
end
Badges.Grouped = grouped

-- My Collection's order with `id`'s track gathered where `id` is (a tier
-- dragged: its tiers go with it). A list of ids.
function Badges.Regroup(order, id)
    local b = byId[id]
    local t = b and b.track
    if not t then return order end
    local out, members, at = {}, {}, nil
    for _, x in ipairs(order) do
        local xb = byId[x]
        if x == id then at = #out + 1 end
        if xb and xb.track == t then members[#members + 1] = x else out[#out + 1] = x end
    end
    if not at then return order end
    table.sort(members, function(p, q) return (Badges.TIER_ORDER[byId[p].tier] or 0) < (Badges.TIER_ORDER[byId[q].tier] or 0) end)
    for k, m in ipairs(members) do table.insert(out, at + k - 1, m) end
    return out
end

function Badges.LayoutOf(key)
    if key == ns.meKey then return ns.db and ns.db.badgeLayout end
    return layouts[key]
end

-- Their Showcase and Collection: the Showcase's slots [1..3] (each
-- { b, e, pts, at } or nil: empty), the Collection a list of them, and how
-- many slots are filled. `sort`: a Badges.SORTS id for the Collection (nil:
-- "arranged").
function Badges.Arrange(key, result, sort)
    -- (a tier track: only its best tier earned, standing for the track -
    -- its Tiers are in its tooltip)
    local items, byGroup = {}, {}
    for _, b in ipairs(Badges.LIST) do
        local e = result.badges[b.id]
        if e and e.times > 0 then
            local g = groupOf(b)
            local had = byGroup[g]
            if not had or (Badges.TIER_ORDER[b.tier] or 0) > (Badges.TIER_ORDER[had.b.tier] or 0) then
                byGroup[g] = { b = b, e = e, pts = Badges.PointsOf(b), at = earnedAt(e) }
            end
        end
    end
    for _, b in ipairs(Badges.LIST) do
        local it = byGroup[groupOf(b)]
        if it and it.b == b then items[#items + 1] = it end
    end
    -- (a saved id stands for its track: a lower tier placed, the best shown there)
    local function itemFor(id)
        local b = id and byId[id]
        return b and byGroup[groupOf(b)]
    end
    local lay = Badges.LayoutOf(key)
    local ids = lay and lay.showcase
    if not ids then
        -- (the most prestigious, a track's best tier only)
        ids = {}
        local seen = {}
        for _, b in ipairs(Badges.Prestigious(result)) do
            local t = b.track or b.id
            if not seen[t] and #ids < Badges.SHOWCASE_N then seen[t] = true; ids[#ids + 1] = b.id end
        end
    end
    local show, shown, filled = {}, {}, 0
    for i = 1, Badges.SHOWCASE_N do
        local it = itemFor(ids[i])
        if it and not shown[it] then show[i] = it; shown[it] = true; filled = filled + 1 end
    end
    local rest = {}
    for _, it in ipairs(items) do if not shown[it] then rest[#rest + 1] = it end end
    sort = sort or "arranged"
    local pos
    if sort == "arranged" and lay and lay.order then
        pos = {}
        for i, id in ipairs(lay.order) do
            local it = itemFor(id)
            if it then pos[it] = pos[it] or i end
        end
    end
    local by = sortBy(sort == "arranged" and "pointsDesc" or sort)
    grouped(rest, function(x, y)
        if pos then
            local a, c = pos[x], pos[y]
            if a and c then return a < c end
            if a ~= c then return a == nil end          -- (new ones, not yet arranged, first)
        end
        return by(x, y)
    end)
    return show, rest, filled
end

-- Every badge they haven't earned, that can still be: closest to done
-- first (then the list's order). Nothing switched off, no past month's
-- bounties, and of a tier track only its lowest tier not earned. { b, e,
-- frac } each; frac is how far along (0 to 1).
function Badges.Unearned(result)
    local list = {}
    for i, b in ipairs(Badges.LIST) do
        local e = result.badges[b.id]
        local past = b.month and Badges.BOUNTY and b.month ~= Badges.BOUNTY.month
        if e and e.times == 0 and not past and not Badges.CategorySoon(b.cat) and Badges.IsPage(b.cat) then
            local g = e.goal or b.goal or 1
            local v = math.max(0, math.min(e.value or 0, g))
            list[#list + 1] = { b = b, e = e, frac = g > 0 and v / g or 0, i = i }
        end
    end
    -- (a tier track: only its lowest tier not earned - the next to go for)
    local low = {}
    for _, it in ipairs(list) do
        local g = groupOf(it.b)
        if not low[g] or (Badges.TIER_ORDER[it.b.tier] or 0) < (Badges.TIER_ORDER[low[g].b.tier] or 0) then low[g] = it end
    end
    local next_ = {}
    for _, it in ipairs(list) do if low[groupOf(it.b)] == it then next_[#next_ + 1] = it end end
    list = next_
    grouped(list, function(x, y)
        if x.frac ~= y.frac then return x.frac > y.frac end   -- (a track where its closest tier is)
        return x.i < y.i
    end)
    return list
end

-- Their Showcase's badges in order, the empty slots left out (the
-- roster's Top Badges): a list of { b, e }.
function Badges.ShowcaseOf(key, result)
    local show = Badges.Arrange(key, result, "arranged")
    local list = {}
    for i = 1, Badges.SHOWCASE_N do
        if show[i] then list[#list + 1] = { b = show[i].b, e = show[i].e } end
    end
    return list
end

-- My Showcase's slots, to the guild ("-": empty), a moment after the last
-- change (a few drags in a row: one message).
local tellToken = 0
local function tellShowcase()
    tellToken = tellToken + 1
    local mine = tellToken
    ns.after(2, function()
        if mine ~= tellToken or not IsInGuild() then return end
        local show = Badges.Arrange(ns.meKey, Badges.Mine(), "arranged")
        local f = { "BW", ns.Comm.PROTO }
        for i = 1, Badges.SHOWCASE_N do f[#f + 1] = show[i] and show[i].b.id or "-" end
        ns.Comm.Send(f, "GUILD", nil, "showcase")
    end, "showcase")
end

-- Mine, arranged: the Showcase's slots (an id or false each), then the
-- Collection's ids in order.
function Badges.SetLayout(showcase, order)
    if not ns.db then return end
    local slots = {}
    for i = 1, Badges.SHOWCASE_N do slots[i] = showcase[i] or false end
    ns.db.badgeLayout = { showcase = slots, order = order }
    ns.fire("BADGES", ns.meKey)
    tellShowcase()
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

-- (the fresh start: weeks before its week dropped; its week, the kills
-- since this client first ran it - badgeFreshBase is what it had then)
function Badges.MyWeeks()
    record()
    local raw = ns.db and ns.db.badgeWeeks or {}
    local fw = Badges.FreshWeek()
    if not fw then return raw end
    local base = ns.db and ns.db.badgeFreshBase
    local out = {}
    for w, c in pairs(raw) do
        if type(w) == "number" then
            if w > fw then out[w] = c
            elseif w == fw and base then out[w] = math.max(0, c - base) end
        end
    end
    return out
end

-- Once per fresh start, on this client: its own copy wiped (here: the
-- weeks of kills, and what was claimed of them).
local function freshStart()
    local db = ns.db
    if not db or db.freshStart == Badges.FRESH_START then return end
    local fw = Badges.FreshWeek()
    if not fw then return end
    record()
    local LB = ns.Leaderboard
    local cur = LB.Week()
    -- (its week: what's counted so far is from before; a later week: none of it)
    db.badgeFreshBase = (cur == fw) and math.max((db.badgeWeeks or {})[fw] or 0, LB.Mine(fw) or 0) or nil
    db.badgeClaimed, db.rankRequested, db.placementClaimed = {}, {}, {}
    db.freshStart = Badges.FRESH_START
end
Badges.FreshStartLocal = freshStart

local function manualFor(key)
    return ns.Ledger and ns.Ledger.ManualFor(key) or nil
end

function Badges.Mine() return Badges.Compute(Badges.MyWeeks(), manualFor(ns.meKey), ns.meKey) end

---------------------------------------------------------------------------
-- Other guildies' (by whisper, when their badges are viewed)
---------------------------------------------------------------------------
local others = {}          -- key -> { weeks, at, parts = {...} }
local asked = {}           -- key -> time I asked
local answered = {}        -- key -> time I answered
local ASK_GAP, ANSWER_GAP = 10, 10
-- What each guildie last sent (weeks, Showcase, order), kept between
-- sessions, so theirs still show while they're offline: db.badgeCache,
-- key -> { weeks, showcase, order, at = time() }. Not heard from in
-- CACHE_DAYS: dropped.
local CACHE_DAYS = 180
local function cache()
    ns.db.badgeCache = ns.db.badgeCache or {}
    return ns.db.badgeCache
end
local function cached(key)
    local c = cache()
    c[key] = c[key] or {}
    c[key].at = time()
    return c[key]
end

-- Their weeks as far as I know: what they sent, and the Leaderboard's
-- counts for them (this week and last), the higher of each.
function Badges.WeeksOf(key)
    if key == ns.meKey then return Badges.MyWeeks() end
    local weeks = {}
    -- (the fresh start: nothing before its week; the board's counts of its
    -- week aren't theirs to trust - they started before it - only theirs)
    local fw = Badges.FreshWeek() or -1
    local o = others[key]
    if o then for w, c in pairs(o.weeks) do if w >= fw then weeks[w] = c end end end
    local board = ns.db and ns.db.board or {}
    for w, t in pairs(board) do
        local e = type(w) == "number" and w > fw and type(t) == "table" and t[key]
        if e and e.c and e.c > (weeks[w] or 0) then weeks[w] = e.c end
    end
    return weeks
end

function Badges.Of(key) return Badges.Compute(Badges.WeeksOf(key), manualFor(key), key) end

-- Have they answered? (nil: never; else the time)
function Badges.HeardFrom(key) return others[key] and others[key].at end

-- When they last answered, any session (time(); nil: never).
function Badges.SavedAt(key)
    local c = ns.db and ns.db.badgeCache and ns.db.badgeCache[key]
    return c and c.at
end

-- (offline: no whisper - the game would answer "No player named ...")
function Badges.Request(key)
    if not key or key == ns.meKey then return end
    local m = ns.Roster and ns.Roster.Get(key)
    local to = m and m.online and m.address
    if not to then return end
    local now = ns.now()
    if asked[key] and now - asked[key] < ASK_GAP then return end
    asked[key] = now
    ns.Comm.Send({ "BQ", ns.Comm.PROTO }, "WHISPER", to)
end

-- `items` as "kind|1|part|parts|a,b,c" messages, each under 255 bytes
-- ("BS|1|nn|nn|" is at most 12).
local function sendChunks(kind, items, to)
    local chunks, cur = {}, {}
    local len = 0
    for _, it in ipairs(items) do
        if len + #it + 1 > 230 then chunks[#chunks + 1] = table.concat(cur, ","); cur, len = {}, 0 end
        cur[#cur + 1] = it; len = len + #it + 1
    end
    chunks[#chunks + 1] = table.concat(cur, ",")
    for i, s in ipairs(chunks) do
        ns.Comm.Send({ kind, ns.Comm.PROTO, i, #chunks, s }, "WHISPER", to)
    end
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
    sendChunks("BS", items, to)
    -- My Showcase and Collection, as I see them.
    local show, rest = Badges.Arrange(ns.meKey, Badges.Mine(), "arranged")
    local ids = {}
    for i = 1, Badges.SHOWCASE_N do ids[i] = show[i] and show[i].b.id or "-" end
    for _, it in ipairs(rest) do ids[#ids + 1] = it.b.id end
    sendChunks("BV", ids, to)
end

-- Their Showcase and Collection's order, in parts.
local layoutParts = {}     -- key -> { n, got = { [part] = { id... } } }
local function onBV(f, sender, key)
    local part, parts = tonumber(f[3]), tonumber(f[4])
    if not (part and parts) or part < 1 or parts < 1 or parts > 50 or part > parts then return end
    local p = layoutParts[key]
    if not p or p.n ~= parts then p = { n = parts, got = {} }; layoutParts[key] = p end
    local ids = {}
    for t in (f[5] or ""):gmatch("[^,]+") do ids[#ids + 1] = t end
    p.got[part] = ids
    for i = 1, parts do if not p.got[i] then return end end
    layoutParts[key] = nil
    local all = {}
    for i = 1, parts do for _, t in ipairs(p.got[i]) do all[#all + 1] = t end end
    local showcase, order = {}, {}
    for i = 1, Badges.SHOWCASE_N do showcase[i] = byId[all[i] or ""] and all[i] or false end
    for i = Badges.SHOWCASE_N + 1, #all do
        if byId[all[i]] and #order < 1000 then order[#order + 1] = all[i] end
    end
    layouts[key] = { showcase = showcase, order = order }
    local c = cached(key)
    c.showcase, c.order = showcase, order
    ns.fire("BADGES", key)
end

-- Their Showcase changed (to the guild): its slots; their Collection's
-- order stays what I last heard.
local function onBW(f, sender, key)
    local showcase = {}
    for i = 1, Badges.SHOWCASE_N do
        local id = f[2 + i]
        showcase[i] = (id and byId[id]) and id or false
    end
    local old = layouts[key]
    layouts[key] = { showcase = showcase, order = old and old.order }
    if ns.db and ns.db.badgeCache and ns.db.badgeCache[key] then ns.db.badgeCache[key].showcase = showcase end
    ns.fire("BADGES", key)
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
        cached(key).weeks = weeks
        ns.fire("BADGES", key)
    end
end

-- Last session's answers, as far as they go (not answers this session:
-- HeardFrom stays nil until they answer again).
local function loadCache()
    local c, old = cache(), time() - CACHE_DAYS * 86400
    for key, e in pairs(c) do
        if type(e) ~= "table" or (tonumber(e.at) or 0) < old then
            c[key] = nil
        else
            if type(e.weeks) == "table" and not others[key] then others[key] = { weeks = e.weeks } end
            if type(e.showcase) == "table" and not layouts[key] then
                local showcase, order = {}, {}
                for i = 1, Badges.SHOWCASE_N do local id = e.showcase[i]; showcase[i] = (id and byId[id]) and id or false end
                for _, id in ipairs(type(e.order) == "table" and e.order or {}) do if byId[id] then order[#order + 1] = id end end
                layouts[key] = { showcase = showcase, order = order }
            end
        end
    end
end

ns.onLogin(function()
    freshStart()
    loadCache()
    ns.Comm.handlers.BQ = function(f, sender, key) answer(sender, key) end
    ns.Comm.handlers.BS = onBS
    ns.Comm.handlers.BV = onBV
    ns.Comm.handlers.BW = onBW
    -- (my Showcase to the guild once, a while after login, if I've set one)
    ns.after(30, function() if ns.db and ns.db.badgeLayout then tellShowcase() end end, "showcase at login")
    record()
    ns.every(30, record, "badge weeks")
    ns:On("PLAYER_LOGOUT", record)
end, "badges")
