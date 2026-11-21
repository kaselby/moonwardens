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
        { id = "patrols", name = "Patrols", soon = true },   -- (switched off for now: not shown, not reported, not awarded)
        { id = "objectives", name = "Objectives" },
        { id = "leaderboard", name = "Leaderboard" },
    } },
    -- Overlord's guild outposts and forts, anywhere (Captures.lua).
    { id = "overlord", name = "Overlord", children = {
        { id = "outposts", name = "Outposts" },
        { id = "forts", name = "Forts" },
    } },
    { id = "wyldhunt", name = "The Wyld Hunt", children = {
        { id = "training", name = "Huntress Training" },
        { id = "ritual", name = "Ritual of the Hunt" },
    } },
}

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
local WEEKLY_ICON = { "inv_glaive_1h_warfrontsnightelf_d_01", "Ability_DemonHunter_ThrowGlaive", "INV_Weapon_Glaive_01", "Ability_Hunter_MarkedForDeath" }

-- (names are working names; they get settled before this ships)
--
-- ORDER: wherever Copper, Silver and Gold of one badge sit side by side,
-- Copper comes first, then Silver, then Gold - in this list (which sets the
-- order of the cards) and in any list made from it. Keep new tiered
-- badges in that order. Their ids never change with it.
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
      name = "Lifetime Wrath of the Kaldorei", icon = LIFETIME_ICON,
      desc = "Kill or assist in killing 10,000 Horde in Ashenvale." },
    { id = "lt2", cat = "kills", kind = "lifetime", tier = "silver", goal = 25000, points = 100,
      name = "Lifetime Wrath of the Kaldorei", icon = LIFETIME_ICON,
      desc = "Kill or assist in killing 25,000 Horde in Ashenvale." },
    { id = "lt3", cat = "kills", kind = "lifetime", tier = "gold", goal = 50000, points = 250,
      name = "Lifetime Wrath of the Kaldorei", icon = LIFETIME_ICON,
      desc = "Kill or assist in killing 50,000 Horde in Ashenvale." },
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
-- again - and Total Victory on the Ashenvale front with your raid. Weekly:
-- that many in one week, each tier once a week. Lifetime: all of them.
-- Counted by your own client and claimed as Kills badges are.
-- PLACEHOLDER names and numbers.
-- (`what`: "X" names them "Weekly X" and "Lifetime X"; or their own
-- names, { weekly, lifetime }, either nil for the usual.
-- `descW` / `descL`: own wording, given the count; else the usual)
local function objectiveSet(cat, series, idW, idL, what, plural, icon, weekly, lifetime, descW, descL)
    local own = type(what) == "table" and what or {}
    local base = type(what) == "string" and what or ""
    local nameW, nameL = own[1] or ("Weekly " .. base), own[2] or ("Lifetime " .. base)
    for i, t in ipairs(weekly) do
        Badges.LIST[#Badges.LIST + 1] = {
            id = idW .. i, cat = cat, kind = "selfweekly", series = series, tier = t[1], goal = t[2], points = t[3],
            name = nameW, icon = icon, unit = plural,
            desc = descW and descW(t[2]) or ("Be inside %d %s as they're taken for the Alliance, in one week."):format(t[2], plural),
        }
    end
    for i, t in ipairs(lifetime) do
        Badges.LIST[#Badges.LIST + 1] = {
            id = idL .. i, cat = cat, kind = "selflifetime", series = series, tier = t[1], goal = t[2], points = t[3],
            name = nameL, icon = icon, unit = plural,
            desc = descL and descL(t[2]) or ("Be inside %d %s as they're taken for the Alliance."):format(t[2], plural),
        }
    end
end
local function times(n) return n == 1 and "1 time" or (n .. " times") end
-- Total Victory: every one counts again ("selfcount"). First in Objectives.
Badges.LIST[#Badges.LIST + 1] = {
    id = "tv", cat = "objectives", kind = "selfcount", series = "victory", points = 50, goal = 1,
    name = "Tor ilisar'thera'nal!", icon = { "Achievement_Zone_Ashenvale_01", "INV_BannerPVP_02" },
    desc = "Be in the party or raid that takes all of Ashenvale on Overlord.",
}
-- Ashenvale Defense > Objectives: the Ashenvale front's capture points (no
-- other front's), and Ashenvale's two outposts, Shobek'Aran and Lesi's Bear
-- Cave (a copy of the outposts track, for those two only; a capture there
-- counts for both).
local OUTPOST_WEEKLY = { { "copper", 1, 8 }, { "silver", 3, 15 }, { "gold", 5, 30 }, { "moonstone", 10, 60 } }
local OUTPOST_LIFETIME = { { "copper", 10, 35 }, { "silver", 30, 75 }, { "gold", 75, 150 }, { "moonstone", 150, 300 } }
objectiveSet("objectives", "captures", "ow", "ol", { "Reclaim Our Home (Weekly)", "The Forest Remembers" }, "Ashenvale capture points", { "INV_BannerPVP_02", "Achievement_BG_winWSG" },
    { { "copper", 10, 5 }, { "silver", 20, 10 }, { "gold", 40, 20 }, { "moonstone", 80, 40 } },   -- (doubling)
    { { "copper", 100, 25 }, { "silver", 400, 50 }, { "gold", 1000, 100 }, { "moonstone", 2500, 250 } },
    function(n) return ("Be inside %d Ashenvale capture points in one week."):format(n) end,
    function(n) return ("Be inside %d Ashenvale capture points."):format(n) end)
-- (only two outposts, taken again and again: more of them a week than the
-- general outposts track asks, for the same points)
objectiveSet("objectives", "ashenvale_outposts", "aw", "al", { "Uproot the Invaders (Weekly)" }, "Ashenvale outposts (Shobek'Aran, Lesi's Bear Cave)",
    { "Achievement_Zone_Ashenvale_01", "Achievement_BG_captureflag_AB" },
    { { "copper", 3, 5 }, { "silver", 6, 10 }, { "gold", 10, 25 }, { "moonstone", 20, 50 } }, {},   -- (points as the weekly kills)
    function(n) return ("Capture Shobek'Aran or Lesi's Bear Cave %s in one week."):format(times(n)) end)
-- Their lifetimes, one each: Shobek'Aran's is "Bankai!", Lesi's "War-Den".
local function siteLifetime(series, idL, name, site, icon)
    for i, t in ipairs(OUTPOST_LIFETIME) do
        Badges.LIST[#Badges.LIST + 1] = {
            id = idL .. i, cat = "objectives", kind = "selflifetime", series = series, tier = t[1], goal = t[2], points = t[3],
            name = name, icon = icon, unit = site .. " captures",
            desc = ("Capture %s %s."):format(site, times(t[2])),
        }
    end
end
siteLifetime("shobekaran", "bk", "Bankai!", "Shobek'Aran",
    { "inv_sword_1h_pandariaquest_b_01", "inv_sword_1h_pvppandarias1_c_01", "INV_Sword_36", "INV_Sword_19", "Achievement_Zone_Ashenvale_01" })   -- (a katana)
siteLifetime("lesi_cave", "lc", "War-Den", "Lesi's Bear Cave",
    { "Ability_Druid_ChallangingRoar", "Ability_Racial_BearForm", "Achievement_Zone_Ashenvale_01" })
-- Overlord: guild outposts and forts on any map.
objectiveSet("outposts", "outposts", "uw", "ul", "Outpost Capture", "guild outposts", { "Achievement_BG_captureflag_AB", "INV_BannerPVP_02" },
    OUTPOST_WEEKLY, OUTPOST_LIFETIME)
objectiveSet("forts", "forts", "fw", "fl", { "Weekly Fort Capture", "Ancient of War" }, "forts", { "Achievement_BG_DefendXbases_AB", "INV_Misc_Tournaments_banner_Nightelf" },
    { { "copper", 1, 10 }, { "silver", 2, 20 }, { "gold", 3, 40 }, { "moonstone", 6, 80 } },
    { { "copper", 5, 50 }, { "silver", 15, 100 }, { "gold", 40, 200 }, { "moonstone", 80, 400 } })
-- Leaderboard ("placement"): 1st, 2nd or 3rd on a week's final Horde kills
-- board (ties share the place). Each guildie's client claims its own, a day
-- after the reset, once late counts are in.
-- (Copper first, as everywhere; the id is the place: lb1 = 1st = Gold)
for _, t in ipairs({ { "copper", 3, 10 }, { "silver", 2, 15 }, { "gold", 1, 25 } }) do
    Badges.LIST[#Badges.LIST + 1] = {
        id = "lb" .. t[2], cat = "leaderboard", kind = "placement", tier = t[1], place = t[2], points = t[3], goal = 1,
        name = "Chosen of Elune (Weekly)", icon = { "spell_nature_moonglow" },
        desc = ("Place %s on the weekly Horde kills leaderboard."):format(({ "first", "second", "third" })[t[2]]),
    }
end
-- The Wyld Hunt. Kinds: "granted" (only ever granted, by those its
-- `grantedBy` names, officers always; `stack`: each grant counts again) and
-- "rank" (comes with a guild rank or any above it).
local SUELEVIN = { names = { "suelevin stormsong" } }
for _, b in ipairs({
    { id = "hp", cat = "ritual", kind = "granted", stack = true, points = 10,
      name = "Hunting Party", icon = { "Ability_Tracking", "Ability_Hunter_BeastCall" },
      desc = "Aid another Moonwarden in their Wyld Hunt." },
    { id = "cv", cat = "ritual", kind = "granted", stack = true, points = 10,
      name = "Cadre of Vengeance", icon = { "Ability_Hunter_RunningShot", "Ability_Rogue_Sprint" },
      desc = "Complete a Wyld Hunt without dying." },
    -- Not automatic: officers are promoted through Huntress, so holding the
    -- rank (or one above) only files a request (autoRequest); an officer
    -- approves it in Approvals before it counts.
    { id = "hr", cat = "ritual", kind = "granted", rank = "Huntress", autoRequest = "rank", points = 100,
      name = "Huntress", icon = { "achievement_boss_councilsentinel", "Ability_Mount_WhiteTiger" },
      desc = "Earn the rank of Huntress." },
    { id = "fh", cat = "ritual", kind = "granted", stack = true, points = 0,
      name = "Failed Hunt", icon = { "INV_Misc_Bone_HumanSkull_01", "Ability_Rogue_FeignDeath" },
      desc = "Fail a Wyld Hunt." },
}) do
    b.goal = 1
    Badges.LIST[#Badges.LIST + 1] = b
end
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
--     +/-); each parent remembers its fold. A child's row shows its icon,
--     label, points (on a small shield) and a check once earned.
--   * `active`: while true the parent is never greyed out (it's there to be
--     done). Afterwards it's grey only if none of its children was earned.
--   * Ids are forever: a parent's id and its children's are what earned
--     badges point at. Never reuse or renumber them; add new ones instead.
--
-- Badges.Compound{
--     id = "bh:2026-11",                      -- unique, never reused
--     cat = "training",                       -- the category it's listed in
--     name = "Bounty Hunter: November 2026",
--     desc = "Complete any ... from November 2026.\nNo one in ...",
--     icon = { "Ability_Hunter_MarkedForDeath" },   -- first the client has
--     listLabel = "This month's bounties",    -- heading over the children
--     active = true,                          -- see above
--     children = {                            -- each a full badge (kind, points, ...)
--         { id = "bh:2026-11:1", kind = "granted", points = 50,
--           name = "Bounty: Blackmoss the Fetid",   -- its own title, tooltips, log
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
            name = "Bounty: " .. t.name, label = ("|cffffd100Lv %d|r  %s"):format(t.level, t.name), icon = icon,
            desc = ("Complete the level %d Huntress Training bounty: %s."):format(t.level, t.more or t.name),
        }
    end
    Badges.Compound({
        id = pid, cat = "training", icon = BOUNTY_ICON,
        name = "Bounty Hunter: " .. m.label,
        desc = ("Complete any Huntress Training bounty from %s.\nNo one in your party may be above the bounty's level."):format(m.label),
        listLabel = mi == #Badges.BOUNTIES and "This month's bounties" or "Bounties",
        active = mi == #Badges.BOUNTIES,
        extra = { month = m.month },
        children = children,
    })
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

local SET = 500   -- a full weekly set: the Gold goal

-- Moonstone for the kills (past Gold, and not part of the 500 sets: 1,000
-- in one week; 100,000 in all).
Badges.LIST[#Badges.LIST + 1] = { id = "wk4", cat = "kills", kind = "weekly", tier = "moonstone", goal = 1000, points = 50,
    noCycle = true, name = "Weekly Moonblade Hunt", icon = WEEKLY_ICON,
    desc = "Kill or assist in killing 1,000 Horde in Ashenvale in a week." }
Badges.LIST[#Badges.LIST + 1] = { id = "lt4", cat = "kills", kind = "lifetime", tier = "moonstone", goal = 100000, points = 500,
    name = "Lifetime Wrath of the Kaldorei", icon = LIFETIME_ICON,
    desc = "Kill or assist in killing 100,000 Horde in Ashenvale." }

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

-- Is a category switched off for now ("coming soon")?
local soonCats
function Badges.CategorySoon(cat)
    if not soonCats then
        soonCats = {}
        for _, top in ipairs(Badges.CATEGORIES) do
            if top.soon then soonCats[top.id] = true end
            for _, c in ipairs(top.children or {}) do if c.soon then soonCats[c.id] = true end end
        end
    end
    return soonCats[cat] or false
end

-- What a manual badge's progress is counted in: its counter, shared by its
-- tiers (patrols), or the badge itself.
function Badges.CounterOf(b) return b and (b.counter or b.id) end

-- "Weekly Moonblade Hunt: Copper"; untiered ones just their name.
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

-- Does guildie `key` hold rank `rankName` or one above it? (Server data:
-- the roster's rank, against the guild's rank list.)
function Badges.HasRank(key, rankName)
    local m = key and ns.Roster and ns.Roster.Get(key)
    if not (m and m.rankIndex and rankName) then return false end
    if m.rank == rankName then return true end
    local n = ns.try(GuildControlGetNumRanks) or 0
    for i = 1, n do
        if ns.try(GuildControlGetRankName, i) == rankName then
            return m.rankIndex <= i - 1      -- (roster ranks count from 0, the guild master)
        end
    end
    return false
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
                local t = b.noCycle and (c >= b.goal and 1 or 0) or weeklyTimes(b, c)
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
            -- (this week's run toward the next one; Moonstone isn't in the sets: the week's whole count)
            e.value = b.noCycle and math.min(now, b.goal) or math.min(now % SET, b.goal)
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
        -- A rank badge: held while the roster shows the rank (or above), and
        -- kept after by its claim.
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

function Badges.Mine() return Badges.Compute(Badges.MyWeeks(), manualFor(ns.meKey), ns.meKey) end

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

function Badges.Of(key) return Badges.Compute(Badges.WeeksOf(key), manualFor(key), key) end

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
