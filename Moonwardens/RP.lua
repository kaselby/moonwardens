-- RP: guildies' totalRP3 profiles on the dots, in the guild roster and on
-- the Leaderboard tab.
--
-- Two settings under Roleplay, both off by default:
--   rpColors  "Show guildies custom Roleplay colors": a profile's custom
--             colour (TRP's display version, contrast-adjusted) for the dot
--             and the name in tooltips, instead of the class colour.
--   rpNames   "Show guildies custom Roleplay names/class names": the profile's
--             name, race and class in tooltips, the real class kept in
--             brackets: "Level 60 Moonborn Starcaller (Druid)".
--
-- Where profiles come from, best first:
--  1. Phoned in: guildies who run totalRP3 send their own name, colour, race
--     and class to the guild (RN), at login, when they change, and when
--     someone asks (RNQ, sent once at login). We keep the last one each sent
--     in MoonwardensDB.rpKnown, so it works without totalRP3 installed, and
--     for people we haven't met, until they send again.
--  2. Our own totalRP3, if installed: profiles it has received.
-- Anyone with neither, or a field left empty: the game's own name, race,
-- class and class colour, exactly as before.
-- RN|1|name|rrggbb|race|class   GUILD: my profile (all empty: I have none now)
-- RNQ|1                         GUILD: "send me your profiles"
-- Looked-up profiles are cached briefly, since the minimap styles its dots
-- 20 times a second.
local _, ns = ...
local RP = {}
ns.RP = RP

local CACHE_FOR = 5          -- seconds a looked-up profile is reused
local KEEP_FOR = 90 * 86400  -- phoned-in profiles not heard again are forgotten after this
local FIELD_MAX = 48         -- bytes per field sent (four fit well under 255)
local cache = {}             -- key -> { at, color = {r,g,b}|false, name, race, class }

local function known()
    if not ns.db then return {} end
    ns.db.rpKnown = ns.db.rpKnown or {}
    return ns.db.rpKnown
end

local function available()
    return type(AddOn_TotalRP3) == "table" and type(AddOn_TotalRP3.Player) == "table"
        and type(AddOn_TotalRP3.Player.CreateFromCharacterID) == "function"
        and type(TRP3_NameUtil) == "table" and type(TRP3_NameUtil.GetQualifiedNameFromString) == "function"
end

-- A text field from the profile, or nil when it's empty or not a plain string.
local function text(v)
    if type(v) ~= "string" or not ns.readable(v) then return nil end
    v = v:match("^%s*(.-)%s*$")
    if v == "" then return nil end
    return v
end

local function lookUp(key)
    local m = ns.Roster.Get(key)
    local name = (m and m.name) or key
    local ok, id = pcall(TRP3_NameUtil.GetQualifiedNameFromString, name)
    if not ok or type(id) ~= "string" then return nil end
    local ok2, p = pcall(AddOn_TotalRP3.Player.CreateFromCharacterID, id)
    if not ok2 or type(p) ~= "table" then return nil end
    local e = {}
    local okc, c = pcall(p.GetCustomColorForDisplay, p)
    if okc and type(c) == "table" and c.GetRGB then
        local okr, r, g, b = pcall(c.GetRGB, c)
        if okr and type(r) == "number" then e.color = { r, g, b } end
    end
    local okn, full = pcall(p.GetFullName, p)       -- (nil without a profile: no game-name fallback)
    if okn then e.name = text(full) end
    local okra, race = pcall(p.GetCustomRace, p)
    if okra then e.race = text(race) end
    local okcl, class = pcall(p.GetCustomClass, p)
    if okcl then e.class = text(class) end
    return e
end

local function fromHex(h)
    if type(h) ~= "string" or not h:match("^%x%x%x%x%x%x$") then return nil end
    return { tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255 }
end

-- The profile fields for a guildie, or nil. What they phoned in wins over
-- what our totalRP3 has; fields that come back empty are simply nil: the
-- caller falls back to the game's.
local function get(key)
    if not key then return nil end
    local now = ns.now()
    local e = cache[key]
    if not e or now - e.at > CACHE_FOR then
        e = (available() and lookUp(key)) or {}
        local k = known()[key]
        if k then
            e.name = k.n or e.name
            e.color = fromHex(k.c) or e.color
            e.race = k.r or e.race
            e.class = k.k or e.class
        end
        e.at = now
        cache[key] = e
    end
    return e
end

-- r, g, b of a guildie's custom colour, or nil (setting off, no profile).
function RP.Color(key)
    if not (ns.db and ns.db.rpColors) then return nil end
    local e = get(key)
    local c = e and e.color
    if c then return c[1], c[2], c[3] end
end

-- name, race, class from the profile (each nil when off or not set).
function RP.Identity(key)
    if not (ns.db and ns.db.rpNames) then return nil end
    local e = get(key)
    if e then return e.name, e.race, e.class end
end

-- Just the name (nil when off or not set): rosters and lists.
function RP.Name(key)
    return (RP.Identity(key))
end

-- Something about RP names or colours changed: drop the cache and redraw
-- everything that shows them (modules listen for "RP").
local function changed()
    wipe(cache)
    if ns.MapWorld and ns.MapWorld.Refresh then ns.MapWorld.Refresh() end
    if ns.UI then ns.UI.Refresh() end
    ns.fire("RP")
end

ns.listen("SETTINGS", function(setting)
    if setting == "rpColors" or setting == "rpNames" then changed() end
end)

---------------------------------------------------------------------------
-- Phone-in: my profile out, guildies' profiles in.
---------------------------------------------------------------------------
-- A field fit to send and to show: no "|" (it splits messages and starts
-- colour codes), no control characters, trimmed and cut short.
local function clean(v)
    v = text(v)
    if not v then return "" end
    v = v:gsub("|", ""):gsub("%c", " ")
    v = v:match("^%s*(.-)%s*$") or ""
    if #v > FIELD_MAX then v = v:sub(1, FIELD_MAX) end
    return v
end

-- My own profile from totalRP3, as sent: { n, c, r, k } (strings, "" for
-- unset), or nil without totalRP3.
local function mine()
    if not (available() and type(AddOn_TotalRP3.Player.GetCurrentUser) == "function") then return nil end
    local ok, p = pcall(AddOn_TotalRP3.Player.GetCurrentUser)
    if not ok or type(p) ~= "table" then return nil end
    local m = { n = "", c = "", r = "", k = "" }
    local okn, full = pcall(p.GetFullName, p); if okn then m.n = clean(full) end
    local okra, race = pcall(p.GetCustomRace, p); if okra then m.r = clean(race) end
    local okcl, class = pcall(p.GetCustomClass, p); if okcl then m.k = clean(class) end
    local okc, c = pcall(p.GetCustomColorForDisplay, p)
    if okc and type(c) == "table" and c.GetRGB then
        local okr, r, g, b = pcall(c.GetRGB, c)
        if okr and type(r) == "number" then
            m.c = ("%02x%02x%02x"):format(math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
        end
    end
    return m
end

local lastSent
local function sendMine(force)
    local m = mine()
    if not m then return end
    local sig = table.concat({ m.n, m.c, m.r, m.k }, ",")
    if sig == lastSent and not force then return end
    lastSent = sig
    ns.Comm.Send({ "RN", ns.Comm.PROTO, m.n, m.c, m.r, m.k }, "GUILD", nil, "rpname")
end

ns.Comm.handlers.RN = function(f, sender, key)
    local n, c, r, k = text(f[3]), text(f[4]), text(f[5]), text(f[6])
    local list = known()
    if not (n or c or r or k) then
        if not list[key] then return end
        list[key] = nil
    else
        local e = { at = time() }
        if n then e.n = text(clean(n)) end
        if c then e.c = c:lower():match("^%x%x%x%x%x%x$") end
        if r then e.r = text(clean(r)) end
        if k then e.k = text(clean(k)) end
        list[key] = e
    end
    changed()
end

-- Someone asked: answer once, a moment later (so a burst of asks is one reply).
local replyPending = false
ns.Comm.handlers.RNQ = function()
    if replyPending or not mine() then return end
    replyPending = true
    ns.after(2 + math.random() * 6, function()
        replyPending = false
        sendMine(true)
    end, "rp reply")
end

ns.onLogin(function()
    local list, now = known(), time()
    for key, e in pairs(list) do
        if type(e) ~= "table" or not e.at or now - e.at > KEEP_FOR then list[key] = nil end
    end
    ns.after(8, function() sendMine(true) end, "rp send")
    ns.after(12, function() ns.Comm.Send({ "RNQ", ns.Comm.PROTO }, "GUILD") end, "rp ask")
    ns.every(60, function() sendMine(false) end, "rp send")    -- (only when it changed)
end, "rp")

---------------------------------------------------------------------------
-- Guildies coming online / going offline: their RP name in the game's line
-- ("[Moonborn Starcaller] has come online."), when "Show guildies custom
-- Roleplay names" is on, in the game's own colour for the line. The link
-- still whispers the character. Anyone else's line, or a guildie with no RP
-- name, is left exactly as the game wrote it.
-- (The game's own templates, ERR_FRIEND_ONLINE_SS / ERR_FRIEND_OFFLINE_S,
-- are matched and refilled, so it works in any client language.)
---------------------------------------------------------------------------
local function toPattern(fmt)
    if type(fmt) ~= "string" then return nil end
    local p = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")   -- every magic character literal
    p = p:gsub("%%%%s", "(.-)")                                 -- then each %s a capture
    return "^" .. p .. "$"
end

-- The RP name to show for a guildie in chat; nil to leave it.
local function chatName(name)
    local key = ns.key(name)
    if not key or not (ns.Roster and ns.Roster.Get(key)) then return nil end
    local rp = RP.Name(key)
    if not rp then return nil end
    return (rp:gsub("|", ""))       -- (in the line's own colour: no RP colour here)
end

local onlinePattern, offlinePattern
local function systemFilter(_, _, msg, ...)
    if not (ns.db and ns.db.rpNames) or type(msg) ~= "string" or not ns.readable(msg) then return false end
    if onlinePattern then
        local link, shown = msg:match(onlinePattern)
        if link and shown then
            local rp = chatName(link)
            if rp then return false, ERR_FRIEND_ONLINE_SS:format(link, rp), ... end
            return false
        end
    end
    if offlinePattern then
        local name = msg:match(offlinePattern)
        if name then
            local rp = chatName(name)
            if rp then return false, ERR_FRIEND_OFFLINE_S:format(rp), ... end
        end
    end
    return false
end

ns.onLogin(function()
    onlinePattern, offlinePattern = toPattern(ERR_FRIEND_ONLINE_SS), toPattern(ERR_FRIEND_OFFLINE_S)
    local add = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
    if add and (onlinePattern or offlinePattern) then
        -- (an error in ours must never eat the game's line: it then goes through as it was)
        local function pass(ok, ...)
            if ok then return ... end
            return false
        end
        pcall(add, "CHAT_MSG_SYSTEM", function(...) return pass(pcall(systemFilter, ...)) end)
    end
end, "rp chat")
