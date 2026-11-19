-- Comm: addon messages. Prefix, rate-limited send queue, decode, dispatch.
-- Message = "TYPE|VERSION|field|field...", always under 255 bytes.
local _, ns = ...
local Comm = {}
ns.Comm = Comm

Comm.PREFIX = "MWG1"
Comm.PROTO = 1
Comm.handlers = {}       -- type -> fn(fields, sender, senderKey, channel)
Comm.lastHeard = {}      -- key -> time of their last message (any type)
Comm.stats = { sent = 0, recv = 0, dropped = 0, ignored = 0 }

local SPACING = 0.25     -- seconds between sends (LayerLab: 4/s passed with no loss)
local queue = {}         -- { msg, channel, target, kind }
local lastSend = -10
local newerSeen = false

local function locked()
    return C_ChatInfo.InChatMessagingLockdown and ns.try(C_ChatInfo.InChatMessagingLockdown) == true
end

local function rawSend(msg, channel, target)
    local r = ns.try(C_ChatInfo.SendAddonMessage, Comm.PREFIX, msg, channel, target)
    Comm.stats.sent = Comm.stats.sent + 1
    return r
end

-- Queue a message. `kind` lets a newer message replace an older unsent one of
-- the same kind (positions: only the latest matters).
function Comm.Send(fields, channel, target, kind)
    local msg = table.concat(fields, "|")
    if #msg > 254 then
        Comm.stats.dropped = Comm.stats.dropped + 1
        return
    end
    if kind then
        for i = 1, #queue do
            if queue[i].kind == kind then
                queue[i] = { msg = msg, channel = channel, target = target, kind = kind }
                return
            end
        end
    end
    queue[#queue + 1] = { msg = msg, channel = channel, target = target, kind = kind }
end

-- Send at once, skipping the queue. Only for the last word before a loading
-- screen or logout, when the queue won't get another pump.
function Comm.SendNow(fields, channel, target)
    if channel == "GUILD" and not IsInGuild() then return end
    lastSend = ns.now()
    return rawSend(table.concat(fields, "|"), channel, target)
end

-- Drain one message per SPACING. Called from a fast ticker.
function Comm.Pump()
    if #queue == 0 or ns.now() - lastSend < SPACING or locked() then return end
    if not IsInGuild() then
        -- Nothing guild-wide can go out; whispers still can.
        for i = #queue, 1, -1 do if queue[i].channel == "GUILD" then table.remove(queue, i) end end
        if #queue == 0 then return end
    end
    local m = table.remove(queue, 1)
    lastSend = ns.now()
    rawSend(m.msg, m.channel, m.target)
end

function Comm.QueueLength() return #queue end

local function onMessage(prefix, text, channel, sender)
    if prefix ~= Comm.PREFIX then return end
    if not ns.readable(text) or not ns.readable(sender) or type(text) ~= "string" then return end
    local key = ns.key(sender)
    if not key or key == ns.meKey then return end
    -- Only guild members count; the roster decides, never the message.
    if ns.Roster and not ns.Roster.IsMember(key) then
        Comm.stats.ignored = Comm.stats.ignored + 1
        return
    end
    local f = { strsplit("|", text) }
    local kind, proto = f[1], tonumber(f[2])
    if not proto then return end
    if proto > Comm.PROTO then
        if not newerSeen then
            newerSeen = true
            ns.print("a guildie has a newer version of the addon. Update when you can.")
        end
        return
    end
    Comm.lastHeard[key] = ns.now()
    local h = Comm.handlers[kind]
    if not h then return end
    Comm.stats.recv = Comm.stats.recv + 1
    h(f, sender, key, channel)
end

ns.onLogin(function()
    ns.try(C_ChatInfo.RegisterAddonMessagePrefix, Comm.PREFIX)
    ns:On("CHAT_MSG_ADDON", onMessage)
    ns.every(0.1, Comm.Pump, "comm pump")
end, "comm")

---------------------------------------------------------------------------
-- Update reminder. Each client says its version once after login
-- (V|1|0.6.1). A release newer than mine (no "-test" in it), vouched for by an
-- officer or by two guildies, gets one chat line per session and a line in
-- the minimap button's tooltip. Someone who logs in later only hears from
-- those who log in after them, so when a guildie announces an older version
-- than mine, I answer after a random wait, unless another guildie with my
-- version or newer answers first (one or two answers, not the whole guild).
-- Old clients ignore V: unknown types are dropped.
---------------------------------------------------------------------------
local Version = {}
Comm.Version = Version

-- { major, minor, patch, release } from "0.6.1" or "0.6.1-test", or nil.
function Version.Parse(v)
    if type(v) ~= "string" then return nil end
    local a, b, c, rest = v:match("^(%d+)%.(%d+)%.?(%d*)(.*)$")
    if not a then return nil end
    return { tonumber(a), tonumber(b), tonumber(c) or 0, rest == "" }
end

-- Is version a newer than b? A test build is older than the release it leads to.
function Version.Newer(a, b)
    local x, y = Version.Parse(a), Version.Parse(b)
    if not x or not y then return false end
    for i = 1, 3 do
        if x[i] ~= y[i] then return x[i] > y[i] end
    end
    return x[4] and not y[4]
end

local vouch = {}               -- version -> { key = true }, newer releases only
local newest                   -- newest release vouched for, or nil
local told = false
local answerAt = -1000         -- when I last answered (or saw an answer to) an old version
local answering = false

local function announce()
    Comm.Send({ "V", Comm.PROTO, ns.VERSION }, "GUILD", nil, "version")
end

local function consider(v, key)
    local p = Version.Parse(v)
    if not (p and p[4] and Version.Newer(v, ns.VERSION)) then return end
    vouch[v] = vouch[v] or {}
    vouch[v][key] = true
    local n = 0
    for _ in pairs(vouch[v]) do n = n + 1 end
    if not (n >= 2 or (ns.Roster and ns.Roster.IsOfficer(key))) then return end
    if newest and not Version.Newer(v, newest) then return end
    newest = v
    if not told then
        told = true
        ns.print(("|cff1eff00version %s is out|r (you have %s). Update it from CurseForge when you can."):format(v, ns.VERSION))
    end
end

local function onV(f, sender, key)
    local v = f[3]
    if type(v) ~= "string" or #v > 20 then return end
    consider(v, key)
    if not Version.Newer(v, ns.VERSION) and not Version.Newer(ns.VERSION, v) then
        answerAt = ns.now()    -- someone with my version spoke: no need for me to
        return
    end
    if Version.Newer(v, ns.VERSION) then answerAt = ns.now(); return end
    -- They're behind me. Answer once in a while, if nobody beats me to it.
    if answering or ns.now() - answerAt < 300 then return end
    answering = true
    local heardAt = answerAt
    ns.after(5 + math.random() * 25, function()
        answering = false
        if answerAt ~= heardAt then return end
        answerAt = ns.now()
        announce()
    end, "version answer")
end

function Version.Newest() return newest end

-- "Update available: 0.6.1" for the minimap button tooltip, or nil.
function Version.TooltipLine()
    if newest then return ("Update available: %s (you have %s)"):format(newest, ns.VERSION) end
end

ns.onLogin(function()
    Comm.handlers.V = onV
    ns.after(10, announce, "version announce")
end, "version")

ns.slash.comm = { help = "message counters", fn = function()
    local s = Comm.stats
    ns.print(("sent %d, received %d, ignored (not in guild) %d, too long %d, queued %d"):format(
        s.sent, s.recv, s.ignored, s.dropped, #queue))
end }
