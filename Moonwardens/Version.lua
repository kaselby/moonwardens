-- Version: tells you when a guildie runs a newer Moonwardens. Addons can't go
-- online, so (as Overlord does) we learn of a newer one from the guild: after
-- a login or /reload we say our version and ask for theirs; each answers by
-- whisper. A newer version is believed from an officer, or from two guildies
-- (one alone could claim any number); then one chat line, once per session.
-- V|1|version|ask    (ask "1": answer me with yours)
local _, ns = ...
local Version = {}
ns.Version = Version

local ANSWER_GAP = 30       -- answer the same guildie at most this often
local heard = {}            -- key -> version string they run
local answered = {}         -- key -> time I last answered them
local notified = false

-- "1.2.3" or "1.2.3-test" -> 1, 2, 3, suffix; nil for anything else. (Only
-- this shape is taken: the number is printed, so nothing else gets through.)
local function parse(v)
    if type(v) ~= "string" or #v > 20 then return nil end
    local a, b, c, s = v:match("^(%d+)%.(%d+)%.(%d+)%-?(%a*)$")
    if not a then return nil end
    return tonumber(a), tonumber(b), tonumber(c), s
end

-- >0 when v1 is newer than v2, 0 the same, <0 older. A "-test" build comes
-- before the release of the same number.
local function compare(v1, v2)
    local a1, b1, c1, s1 = parse(v1)
    local a2, b2, c2, s2 = parse(v2)
    if not a1 or not a2 then return 0 end
    if a1 ~= a2 then return a1 - a2 end
    if b1 ~= b2 then return b1 - b2 end
    if c1 ~= c2 then return c1 - c2 end
    if (s1 == "") ~= (s2 == "") then return s1 == "" and 1 or -1 end
    return 0
end
Version.Compare = compare

-- The newest version newer than mine that an officer runs, or that two
-- guildies run (or better); nil if none.
local function believedNewer()
    local best
    for key, v in pairs(heard) do
        if compare(v, ns.VERSION) > 0 and (not best or compare(v, best) > 0) then
            local vouched = ns.Roster and ns.Roster.IsOfficer and ns.Roster.IsOfficer(key)
            if not vouched then
                for other, w in pairs(heard) do
                    if other ~= key and compare(w, v) >= 0 then vouched = true; break end
                end
            end
            if vouched then best = v end
        end
    end
    return best
end

local function check()
    if notified then return end
    local v = believedNewer()
    if v then
        notified = true
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFD100[Moonwardens]|r " .. ("A newer version (%s) is available. Please update!"):format(v))
    end
end

local function send(ask, channel, target)
    ns.Comm.Send({ "V", ns.Comm.PROTO, ns.VERSION, ask and "1" or "0" }, channel, target, not target and "version" or nil)
end

local function onV(f, sender, key)
    if parse(f[3]) then
        heard[key] = f[3]
        check()
    end
    if f[4] == "1" then
        local now = ns.now()
        if answered[key] and now - answered[key] < ANSWER_GAP then return end
        answered[key] = now
        local to = ns.address(sender)
        if to then ns.after(math.random() * 0.5, function() send(false, "WHISPER", to) end, "version answer") end
    end
end

ns.onLogin(function()
    ns.Comm.handlers.V = onV
    ns:On("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
        if not (isLogin or isReload) then return end
        send(true, "GUILD")
        -- Once more if nobody answered: just after a fresh login the game can
        -- say we're in no guild yet, and the queue drops guild messages then.
        ns.after(5, function() if not next(heard) then send(true, "GUILD") end end, "version ask again")
    end)
end, "version")

ns.slash.version = { help = "guildies' addon versions", fn = function()
    local list = {}
    for key, v in pairs(heard) do list[#list + 1] = { key = key, v = v } end
    table.sort(list, function(a, b)
        local c = compare(a.v, b.v)
        if c ~= 0 then return c > 0 end
        return a.key < b.key
    end)
    ns.print(("you: v%s; %d guildie(s) heard"):format(ns.VERSION, #list))
    for _, e in ipairs(list) do
        local m = ns.Roster and ns.Roster.Get(e.key)
        ns.print(("  %s  v%s"):format(m and m.name or e.key, e.v))
    end
end }
