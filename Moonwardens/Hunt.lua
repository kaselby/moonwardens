-- Hunt: notices a Huntress Training bounty kill (Badges.BOUNTY) and logs
-- what it saw, for the officers and Suelevin to grant that bounty's badge from
-- (the Audit Log's Grant button). It grants nothing by itself.
--
-- A kill passes when my party got the killing blow (PARTY_KILL), nobody in
-- the party is above the bounty's level, the party tagged it, and in the
-- last 30 s no player above that level was seen nearby or buffed the party.
-- Forever gives addons no combat log, so "seen" means what the client can
-- see: nameplates (friendly and enemy player plates must be on to see
-- players), targets, mouseover, and the buffs on my party with their
-- caster. Someone off every nameplate who damaged the mob goes unseen; the
-- evidence says which nameplates were on, for the granter to weigh.
local _, ns = ...
local Hunt = {}
ns.Hunt = Hunt

local WINDOW = 30
local seen = {}      -- player name -> { level, at } (outside my party)
local helpers = {}   -- player name -> { level, at } (outside my party; buffed it)
local mobs = {}      -- guid -> { idx, name, tapDenied, at } (bounties I've seen)
local PATROL_FOR = 900
local patrols = {}   -- bounty index -> { at, down = { name = true }, fails = {}, roster } (a patrol half done)

-- Which bounty a creature is (its index), and its own name. A bounty with
-- `names` is a patrol: any of them.
local function bountyIndex(name)
    if type(name) ~= "string" then return nil end
    local low = name:lower()
    for i, t in ipairs(ns.Badges.BOUNTY.targets) do
        for _, n in ipairs(t.names or { t.name }) do
            if n:lower() == low then return i, n end
        end
    end
end

-- My party (or raid) by GUID -> unit; me included.
local function party()
    local list = {}
    local function add(u)
        local g = ns.try(UnitGUID, u)
        if g then list[g] = u end
    end
    add("player")
    if IsInRaid() then
        for i = 1, 40 do add("raid" .. i) end
    else
        for i = 1, 4 do add("party" .. i) end
    end
    return list
end

local function look(unit, members, now)
    if ns.try(UnitExists, unit) ~= true then return end
    local guid = ns.try(UnitGUID, unit)
    if not guid then return end
    if ns.try(UnitIsPlayer, unit) == true then
        if members[guid] then return end
        local name, level = ns.try(UnitName, unit), ns.try(UnitLevel, unit)
        if type(name) == "string" and type(level) == "number" then
            seen[name] = { level = level, at = now }
        end
    else
        local idx, who = bountyIndex(ns.try(UnitName, unit))
        if idx then
            local m = mobs[guid] or { idx = idx, name = who }
            m.at = now
            local td = ns.try(UnitIsTapDenied, unit)
            if td ~= nil then m.tapDenied = td end
            mobs[guid] = m
        end
    end
end

-- Buffs on my party cast by players outside it.
local function lookBuffs(members, now)
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return end
    for _, unit in pairs(members) do
        for i = 1, 40 do
            local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
            if not ok or type(a) ~= "table" then break end
            pcall(function()
                local src = a.sourceUnit
                if type(src) == "string" and ns.readable(src) and ns.try(UnitIsPlayer, src) == true then
                    local g = ns.try(UnitGUID, src)
                    if g and not members[g] then
                        local name, level = ns.try(UnitName, src), ns.try(UnitLevel, src)
                        if type(name) == "string" and type(level) == "number" then helpers[name] = { level = level, at = now } end
                    end
                end
            end)
        end
    end
end

local function scan()
    local now = ns.now()
    local members = party()
    for i = 1, 40 do look("nameplate" .. i, members, now) end
    for _, u in ipairs({ "target", "mouseover", "focus", "targettarget" }) do look(u, members, now) end
    for _, u in pairs(members) do if u ~= "player" then look(u .. "target", members, now) end end
    lookBuffs(members, now)
    for k, s in pairs(seen) do if now - s.at > WINDOW * 2 then seen[k] = nil end end
    for k, s in pairs(helpers) do if now - s.at > WINDOW * 2 then helpers[k] = nil end end
    for k, m in pairs(mobs) do if now - m.at > 600 then mobs[k] = nil end end
end

local function cvar(name)
    local v = C_CVar and C_CVar.GetCVar and ns.try(C_CVar.GetCVar, name) or ns.try(GetCVar, name)
    return v == "1"
end

local function short(name) return (name or "?"):match("^(%S+)") or name end

local function unitKey(u)
    local first, last = ns.try(UnitName, u)
    if type(first) ~= "string" then return nil end
    return ns.key((type(last) == "string" and last ~= "") and (first .. " " .. last) or first)
end

-- Which client logs a kill: the killer's, if they run the addon; else the
-- first by name of the party's guildies who do.
local function iLog(killerKey, members)
    if killerKey == ns.meKey then return true end
    local heard = ns.Comm.lastHeard or {}
    local now = ns.now()
    if heard[killerKey] and now - heard[killerKey] < 600 then return false end
    local first = ns.meKey
    for _, u in pairs(members) do
        local k = unitKey(u)
        if k and k ~= ns.meKey and heard[k] and now - heard[k] < 600 and k < first then first = k end
    end
    return first == ns.meKey
end

local function onKill(attacker, victim)
    if not (ns.readable(attacker) and ns.readable(victim)) or type(victim) ~= "string" then return end
    scan()                                  -- (one last look: a fresh corpse is still a unit)
    local m = mobs[victim]
    if not m then return end
    mobs[victim] = nil
    local members = party()
    local killerUnit = members[attacker]
    if not killerUnit then return end       -- (not my party's kill)
    local killer = unitKey(killerUnit)
    if not (killer and (killer == ns.meKey or ns.Roster.Get(killer))) then return end
    local t = ns.Badges.BOUNTY.targets[m.idx]
    local cap, now = t.level, ns.now()

    local fails, roster = {}, {}
    for _, u in pairs(members) do
        local level = ns.try(UnitLevel, u)
        local name = ns.try(UnitName, u)
        roster[#roster + 1] = ("%s %s"):format(short(name), tostring(level or "?"))
        if type(level) == "number" and level > cap then fails[#fails + 1] = ("%s is %d"):format(short(name), level) end
    end
    for name, s in pairs(seen) do
        if now - s.at <= WINDOW and s.level > cap then fails[#fails + 1] = ("%s (%d) near"):format(short(name), s.level) end
    end
    for name, s in pairs(helpers) do
        if now - s.at <= WINDOW and s.level > cap then fails[#fails + 1] = ("%s (%d) buffed"):format(short(name), s.level) end
    end
    if m.tapDenied then fails[#fails + 1] = "tagged by others" end

    -- A patrol: each of them down within PATROL_FOR, the checks of every
    -- kill together; the hunt is logged when the last falls.
    if t.names and #t.names > 1 then
        local p = patrols[m.idx]
        if not p or now - p.at > PATROL_FOR then p = { at = now, down = {}, fails = {} }; patrols[m.idx] = p end
        p.down[m.name or "?"] = true
        for _, f in ipairs(fails) do p.fails[#p.fails + 1] = f end
        local n = 0
        for _ in pairs(p.down) do n = n + 1 end
        if n < #t.names then
            ns.print(("|cffffd100Wyld Hunt:|r %s down, %d of %d of the %s. The rest within %d minutes."):format(
                m.name or "?", n, #t.names, t.name, PATROL_FOR / 60))
            return
        end
        patrols[m.idx] = nil
        fails = p.fails
    end

    if not iLog(killer, members) then return end
    local plates = ("plates %s/%s"):format(cvar("nameplateShowFriends") and "F" or "-", cvar("nameplateShowEnemies") and "E" or "-")
    table.sort(roster)
    local seenFail = {}
    local uniq = {}
    for _, f in ipairs(fails) do if not seenFail[f] then seenFail[f] = true; uniq[#uniq + 1] = f end end
    fails = uniq
    local note = ("%s. Party: %s. %s"):format(#fails == 0 and "Clean" or table.concat(fails, ", "),
        table.concat(roster, ", "), plates)
    ns.Ledger.Hunt({ who = killer, badge = ns.Badges.BountyChild(m.idx), value = m.idx, n = #fails == 0 and 1 or 0, note = note })
    if #fails == 0 then
        ns.print(("|cff1eff00Wyld Hunt:|r %s %s fallen. The hunt is logged for the Huntress council to grant it."):format(
            t.name, t.names and "have" or "has"))
    else
        ns.print(("|cffff8040Wyld Hunt:|r %s %s fallen, but the hunt didn't pass: %s. It's logged for the council to judge."):format(
            t.name, t.names and "have" or "has", table.concat(fails, ", ")))
    end
end

ns.onLogin(function()
    ns.every(1, scan, "hunt scan")
    ns:On("PARTY_KILL", onKill)
end, "hunt")
