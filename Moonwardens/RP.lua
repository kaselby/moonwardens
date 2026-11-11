-- RP: guildies' totalRP3 profiles on the dots (EXPERIMENT, 0.5.2-test).
--
-- Two settings under Map, both off by default:
--   rpColors  "Show guildies custom Roleplay colors": a profile's custom
--             colour (TRP's display version, contrast-adjusted) for the dot
--             and the name in tooltips, instead of the class colour.
--   rpNames   "Show guildies custom Roleplay names/class names": the profile's
--             name, race and class in tooltips, the real class kept in
--             brackets: "Level 60 Moonborn Starcaller (Druid)".
--
-- totalRP3 only has profiles it has received (you met them with TRP running).
-- Anyone without one, a field left empty, or totalRP3 not loaded: the game's
-- own name, race, class and class colour, exactly as before.
-- Read through totalRP3's public API (AddOn_TotalRP3.Player); cached briefly,
-- since the minimap styles its dots 20 times a second.
local _, ns = ...
local RP = {}
ns.RP = RP

local CACHE_FOR = 5          -- seconds a looked-up profile is reused
local cache = {}             -- key -> { at, color = {r,g,b}|false, name, race, class }

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

-- The profile fields for a guildie, or nil. Uncached fields that come back
-- empty are simply nil: the caller falls back to the game's.
local function get(key)
    if not key or not available() then return nil end
    local now = ns.now()
    local e = cache[key]
    if not e or now - e.at > CACHE_FOR then
        e = lookUp(key) or {}
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

-- Settings changed: drop the cache and redraw both maps.
ns.listen("SETTINGS", function(setting)
    if setting ~= "rpColors" and setting ~= "rpNames" then return end
    wipe(cache)
    if ns.MapWorld and ns.MapWorld.Refresh then ns.MapWorld.Refresh() end
end)
