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

ns.slash.comm = { help = "message counters", fn = function()
    local s = Comm.stats
    ns.print(("sent %d, received %d, ignored (not in guild) %d, too long %d, queued %d"):format(
        s.sent, s.recv, s.ignored, s.dropped, #queue))
end }
