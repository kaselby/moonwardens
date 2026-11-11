-- Compat_OpenMap: one dot per guildie when OpenMap is installed too.
--
-- OpenMap's "Guild members on the map" draws its own class-coloured dot for
-- guildies who run OpenMap and share where they are. Someone running both
-- addons then shows twice: our dot (sent every 3 s) and OpenMap's, which is
-- sent every 10 s and trails behind ours.
--
-- While BOTH "Show guildies" (ours) and "Guild members on the map" (OpenMap's)
-- are ticked, OpenMap's dot is hidden for each person we are drawing at that
-- moment. Anyone we aren't drawing (no Moonwardens, stale, hidden layer, a map
-- we can't place them on) keeps OpenMap's dot, and it comes back within a
-- refresh when we stop drawing them. OpenMap's zone badges are left alone.
--
-- Nothing in OpenMap's files is changed: its pin functions are wrapped through
-- its public namespace (_G.OpenMap). If a future OpenMap no longer looks like
-- this, the patch switches itself off and both addons work as before.
local _, ns = ...
local Compat = {}
ns.CompatOpenMap = Compat

local tracked = {}           -- OpenMap pin -> Moonwardens key, for its person dots
local active = false         -- the wrap is in place

-- OpenMap's guild switch. nil = can't tell (treated as off: don't touch it).
local function openMapGuildOn()
    local OM = _G.OpenMap
    local mod = OM and OM.GetModule and OM:GetModule("worldmap")
    return type(mod) == "table" and type(mod.db) == "table" and mod.db.guild == true
end

local function enabled()
    return active and ns.db and ns.db.worldDots and not ns.db.mapKill and openMapGuildOn()
end

-- Show or hide OpenMap's person dots to match what we draw right now.
function Compat.Apply()
    if not active then return end
    local on = enabled()
    for pin, key in pairs(tracked) do
        local hide = on and ns.MapWorld and ns.MapWorld.Draws(key)
        if hide then
            if pin:IsShown() then pin:Hide() end
            pin:EnableMouse(false)   -- (no tooltip from a dot nobody can see)
        elseif not pin:IsShown() then
            pin:Show()
            pin:EnableMouse(true)
        end
    end
end

local function install()
    local OM = _G.OpenMap
    local S = OM and OM.MapStitch
    if type(S) ~= "table" or type(S.AddPin) ~= "function" or type(S.ClearPinSet) ~= "function" then return end
    local origAdd, origClear = S.AddPin, S.ClearPinSet

    S.AddPin = function(set, u, v, look, data, ...)
        local pin = origAdd(set, u, v, look, data, ...)
        -- A person dot (Map/Friends.lua): data = { full = "Name-Realm", p = { map, x, y, guild, ... } }.
        -- Zone badges ({ map, people }) and every other pin are not touched.
        local ok = pcall(function()
            if pin and type(data) == "table" and type(data.full) == "string" and type(data.p) == "table"
                    and data.p.x ~= nil then
                local key = ns.key(data.full)
                tracked[pin] = key   -- (left shown unless we draw them; Apply keeps it in step)
                if key and enabled() and ns.MapWorld and ns.MapWorld.Draws(key) then
                    pin:Hide()
                    pin:EnableMouse(false)
                end
            end
        end)
        if not ok then tracked[pin] = nil end
        return pin
    end

    -- OpenMap clears a set before each redraw and pools its pins: forget them.
    S.ClearPinSet = function(set, ...)
        if type(set) == "table" and type(set.pins) == "table" then
            for _, pin in ipairs(set.pins) do tracked[pin] = nil end
        end
        return origClear(set, ...)
    end

    active = true
end

ns.onLogin(function()
    -- OpenMap loads its namespace at load time; wait a moment so its map module is set up.
    if _G.OpenMap then ns.after(1, install, "openmap compat") end
end, "openmap compat")
