-- Core: namespace, saved settings, events, timers, safe reads, slash command.
local ADDON, ns = ...
ns.VERSION = "0.3.0"
_G.Moonwardens = ns -- for /dump and other addons; nothing reads it back

---------------------------------------------------------------------------
-- Safe reads. Forever runs 12.x UI code: some values are "secret" and any
-- comparison or arithmetic on them is an error. Everything read from a unit,
-- the map or the roster goes through readable() or try().
---------------------------------------------------------------------------
function ns.readable(v)
    if v == nil then return true end
    if canaccessvalue then
        local ok, r = pcall(canaccessvalue, v)
        if ok then return r and true or false end
    end
    if issecretvalue then
        local ok, r = pcall(issecretvalue, v)
        if ok then return not r end
    end
    return true
end
local readable = ns.readable

-- Call f(...) and return its results only if the call worked and the first
-- result is readable; otherwise nothing.
function ns.try(f, ...)
    if type(f) ~= "function" then return end
    local r = { pcall(f, ...) }
    if not r[1] or not readable(r[2]) then return end
    return select(2, unpack(r, 1, table.maxn(r)))
end

function ns.now() return GetTime() end

---------------------------------------------------------------------------
-- Names. On Forever a character is "First Surname"; addon senders arrive as
-- "First-Surname" or "First Surname", sometimes with "-Realm" after.
-- key(): stable lowercase id "first surname" for tables.
-- address(): "First-Surname", the form whispers and invites need.
---------------------------------------------------------------------------
function ns.key(name)
    if type(name) ~= "string" or not readable(name) then return nil end
    local a, b = name:gsub("%-", " "):match("^%s*(%S+)%s*(%S*)")
    if not a then return nil end
    if b ~= "" then return (a .. " " .. b):lower() end
    return a:lower()
end

function ns.address(name)
    if type(name) ~= "string" or not readable(name) then return nil end
    local a, b = name:gsub("%-", " "):match("^%s*(%S+)%s*(%S*)")
    if not a then return nil end
    if b ~= "" then return a .. "-" .. b end
    return a
end

function ns.playerName()
    local first, last = ns.try(UnitName, "player")
    if type(first) ~= "string" then return nil end
    if type(last) == "string" and readable(last) and last ~= "" then return first .. " " .. last end
    return first
end

---------------------------------------------------------------------------
-- Saved settings
---------------------------------------------------------------------------
ns.DEFAULTS = {
    alertButton = true, alertButtonLocked = false, alertButtonPos = nil,
    autoInvite = true, autoRaid = true, autoAccept = false, sound = true,
    worldDots = true, otherLayers = true, minimapDots = true,
    dataCollection = true, minimapAngle = 200, mapKill = false,
}

local function applyDefaults(db)
    for k, v in pairs(ns.DEFAULTS) do
        if db[k] == nil then db[k] = v end
    end
    db.char = db.char or {}
    db.board = db.board or {}   -- leaderboard: week -> key -> {n=name, c=count, cls=class}
    db.data = db.data or {}     -- research log
    db.schema = 1
end

---------------------------------------------------------------------------
-- Events: ns:On(event, fn) registers any number of handlers. Errors in one
-- handler are caught so the rest still run; the first few are printed.
---------------------------------------------------------------------------
local frame = CreateFrame("Frame")
ns.frame = frame
local handlers = {}
local errors = 0

function ns.guard(fn, label)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            errors = errors + 1
            if errors <= 3 then ns.print("|cffff4040error|r " .. tostring(label or "") .. ": " .. tostring(err)) end
        end
    end
end

function ns:On(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        pcall(frame.RegisterEvent, frame, event) -- an unknown event on this client is not fatal
    end
    table.insert(handlers[event], ns.guard(fn, event))
end

frame:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    if not list then return end
    for i = 1, #list do list[i](...) end
end)

-- Repeating timer with error guard. Returns the ticker (cancel with :Cancel()).
function ns.every(seconds, fn, label)
    return C_Timer.NewTicker(seconds, ns.guard(fn, label))
end

function ns.after(seconds, fn, label)
    C_Timer.After(seconds, ns.guard(fn, label))
end

function ns.print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd100Moonwardens:|r " .. tostring(msg))
end

-- Internal messages between modules: ns.listen("ROSTER", fn); ns.fire("ROSTER", ...)
local listeners = {}
function ns.listen(name, fn)
    listeners[name] = listeners[name] or {}
    table.insert(listeners[name], ns.guard(fn, name))
end
function ns.fire(name, ...)
    local l = listeners[name]
    if not l then return end
    for i = 1, #l do l[i](...) end
end

function ns.classColor(classFile)
    local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if c then return c.r, c.g, c.b end
    return 0.8, 0.8, 0.8
end

-- Modules register init functions; they run at PLAYER_LOGIN in order.
local inits = {}
function ns.onLogin(fn, label) inits[#inits + 1] = { fn = fn, label = label } end

ns:On("ADDON_LOADED", function(name)
    if name ~= ADDON then return end
    MoonwardensDB = MoonwardensDB or {}
    applyDefaults(MoonwardensDB)
    ns.db = MoonwardensDB
end)

ns:On("PLAYER_LOGIN", function()
    ns.me = ns.playerName()
    ns.meKey = ns.key(ns.me)
    for _, i in ipairs(inits) do ns.guard(i.fn, i.label)() end
end)

---------------------------------------------------------------------------
-- Slash command: modules add verbs with ns.slash[verb] = { fn, help }.
---------------------------------------------------------------------------
ns.slash = {}
SLASH_MOONWARDENS1 = "/mw"
SLASH_MOONWARDENS2 = "/moonwardens"
SlashCmdList.MOONWARDENS = function(msg)
    local verb, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    verb = verb:lower()
    local c = ns.slash[verb]
    if c then return c.fn(rest) end
    if verb == "" and ns.ToggleWindow then return ns.ToggleWindow() end
    ns.print("v" .. ns.VERSION .. " commands:")
    local verbs = {}
    for v in pairs(ns.slash) do verbs[#verbs + 1] = v end
    table.sort(verbs)
    for _, v in ipairs(verbs) do ns.print("  /mw " .. v .. " - " .. ns.slash[v].help) end
end
