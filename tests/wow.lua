-- Minimal WoW API mock for running the addon under luajit.
-- Widgets: any method is a no-op unless defined here; Get* methods return 100.
local W = { clock = 0, timers = {}, sent = {}, events = {}, frames = {}, prints = {} }
unpack = unpack or table.unpack
function GetTime() return W.clock end
function time() return 1700000000 + math.floor(W.clock) end
function GetServerTime() return time() end
date = os.date
function strsplit(sep, s)
    local out = {}
    for piece in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = piece end
    return unpack(out)
end
tinsert, tremove, wipe = table.insert, table.remove, function(t) for k in pairs(t) do t[k] = nil end return t end
strmatch = string.match

local Widget = {}
Widget.__index = function(t, k)
    local v = rawget(Widget, k)
    if v then return v end
    if type(k) == "string" and k:match("^Get") then return function() return 100 end end
    if type(k) == "string" and k:match("^Is") then return function(self) return self._shown ~= false end end
    return function() end
end
function Widget:SetScript(k, fn) self._scripts[k] = fn end
function Widget:GetScript(k) return self._scripts[k] end
function Widget:HookScript(k, fn) self._scripts[k] = fn end
function Widget:Show() self._shown = true; if self._scripts.OnShow then self._scripts.OnShow(self) end end
function Widget:Hide() self._shown = false end
function Widget:IsShown() return self._shown ~= false end
function Widget:IsVisible() return self._shown ~= false end
function Widget:SetShown(v) if v then self:Show() else self:Hide() end end
function Widget:SetText(t) self._text = t end
function Widget:GetText() return self._text end
function Widget:SetChecked(v) self._checked = v end
function Widget:GetChecked() return self._checked end
function Widget:RegisterEvent(e) W.events[e] = W.events[e] or {}; table.insert(W.events[e], self) end
function Widget:UnregisterEvent(e) end
function Widget:CreateTexture() return W.new("Texture") end
function Widget:CreateFontString() return W.new("FontString") end
function Widget:CreateMaskTexture() return W.new("MaskTexture") end
function Widget:GetWidth() return self._w or 100 end
function Widget:GetHeight() return self._h or 100 end
function Widget:SetSize(w, h) self._w, self._h = w, h end
function Widget:SetWidth(w) self._w = w end
function Widget:SetHeight(h) self._h = h end
function Widget:GetCenter() return 500, 400 end
function Widget:GetEffectiveScale() return 1 end
function Widget:GetName() return self._name end
function Widget:GetID() return self._id end
function Widget:SetID(i) self._id = i end

function W.new(kind, name)
    local f = setmetatable({ _kind = kind, _scripts = {}, _name = name }, Widget)
    W.frames[#W.frames + 1] = f
    if name then _G[name] = f end
    return f
end
function CreateFrame(kind, name, parent, template)
    if template and W.missingTemplates and W.missingTemplates[template] then error("no template " .. template) end
    return W.new(kind, name)
end
UIParent = W.new("Frame", "UIParent")
Minimap = W.new("Frame", "Minimap")
WorldFrame = W.new("Frame", "WorldFrame")
GameTooltip = W.new("GameTooltip", "GameTooltip")
GameTooltip.lines = {}
function GameTooltip:AddLine(t) table.insert(self.lines, t) end
function GameTooltip:SetOwner() self.lines = {} end
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(W.prints, m) end }
UISpecialFrames = {}
SlashCmdList = {}
RAID_CLASS_COLORS = setmetatable({}, { __index = function() return { r = 1, g = 1, b = 1 } end })
SOUNDKIT = {}
function PlaySound() end
function GetCursorPosition() return 0, 0 end
function SetPortraitToTexture() end
function PanelTemplates_SetNumTabs() end
function PanelTemplates_SetTab() end
function PanelTemplates_TabResize() end

-- Timers
C_Timer = {}
function C_Timer.After(s, fn) table.insert(W.timers, { at = W.clock + s, fn = fn }) end
function C_Timer.NewTicker(s, fn)
    local t = { every = s, at = W.clock + s, fn = fn }
    function t:Cancel() self.cancelled = true end
    table.insert(W.timers, t)
    return t
end
function W.advance(seconds, step)
    step = step or 0.05
    local target = W.clock + seconds
    while W.clock < target do
        W.clock = W.clock + step
        local due = {}
        for i = #W.timers, 1, -1 do
            local t = W.timers[i]
            if t.cancelled then table.remove(W.timers, i)
            elseif t.at <= W.clock then
                due[#due + 1] = t
                if t.every then t.at = W.clock + t.every else table.remove(W.timers, i) end
            end
        end
        for _, t in ipairs(due) do t.fn(t) end
    end
end
function W.fire(event, ...)
    for _, f in ipairs(W.events[event] or {}) do
        local h = f._scripts.OnEvent
        if h then h(f, event, ...) end
    end
end

-- Player, guild, map
W.me = { first = "Sanalune", last = "Silverwind" }
function UnitName(u) if u == "player" then return W.me.first, W.me.last end return W.unitNames and W.unitNames[u] end
function IsInGuild() return true end
W.roster = {
    { "Sanalune Silverwind", "Warden-General", 0, 60, "Druid", "Ashenvale", true, "DRUID", "Player-1-01" },
    { "Thalanor Oakheart", "Sentinel", 3, 60, "Warrior", "Ashenvale", true, "WARRIOR", "Player-1-02" },
    { "Velanya Dawnleaf", "Initiate", 4, 41, "Priest", "Darnassus", false, "PRIEST", "Player-1-03" },
    { "Caelith Shade", "Initiate", 4, 33, "Rogue", "Teldrassil", true, "ROGUE", "Player-1-04" },
}
function GetNumGuildMembers() return #W.roster end
function GetGuildRosterInfo(i)
    local r = W.roster[i]
    return r[1], r[2], r[3], r[4], r[5], r[6], "", "", r[7], 0, r[8], 0, 0, false, false, 0, r[9]
end
C_GuildInfo = { GuildRoster = function() W.rosterRequests = (W.rosterRequests or 0) + 1 end }
W.races = { ["Player-1-02"] = { "Night Elf", "NightElf" }, ["Player-1-03"] = { "Skyborne", "Skyborne" } }
function GetPlayerInfoByGUID(g)
    local r = W.races[g]
    if not r then return nil end
    return "Class", "CLASS", r[1], r[2], 2, "Name", ""
end
C_ChatInfo = {
    RegisterAddonMessagePrefix = function() return true end,
    InChatMessagingLockdown = function() return false end,
    SendAddonMessage = function(p, m, ch, target)
        assert(#m <= 255, "addon message too long: " .. #m)
        table.insert(W.sent, { p = p, m = m, ch = ch, to = target, at = W.clock })
        return 0
    end,
}
return W
