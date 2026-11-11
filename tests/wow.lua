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
    -- Unknown methods (capitalised) are no-ops; unknown fields are nil.
    if type(k) == "string" and k:match("^[A-Z]") then return function() end end
    return nil
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
function Widget:GetCenter() return self._cx or 500, self._cy or 400 end
-- Points are remembered; a CENTER point with offsets also sets a fake centre
-- (500 + x, 400 + y) so hover tests can aim the cursor at it.
function Widget:SetPoint(p, a, b, c, d)
    self._point = { p, a, b, c, d }
    -- A BOTTOMRIGHT point to the same frame as TOPLEFT: take its size (layout).
    if p == "BOTTOMRIGHT" and type(a) == "table" and a.GetWidth then
        self._w, self._h = a:GetWidth(), a:GetHeight()
        if self._scripts.OnSizeChanged then self._scripts.OnSizeChanged(self, self._w, self._h) end
    end
    if p == "CENTER" and type(c) == "number" then self._cx, self._cy = 500 + c, 400 + d end
end
function Widget:ClearAllPoints() self._point = nil end
function Widget:SetParent(p) self._parent = p end
function Widget:GetParent() return self._parent end
function Widget:SetAlpha(a) self._alpha = a end
function Widget:GetAlpha() return self._alpha or 1 end
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
    local f = W.new(kind, name)
    f._parent = parent
    return f
end
UIParent = W.new("Frame", "UIParent")
Minimap = W.new("Frame", "Minimap")
WorldFrame = W.new("Frame", "WorldFrame")
GameTooltip = W.new("GameTooltip", "GameTooltip")
GameTooltip.lines = {}
function GameTooltip:AddLine(t) table.insert(self.lines, t) end
function GameTooltip:SetOwner(o) self.lines = {}; self._owner = o end
function GameTooltip:GetOwner() return self._owner end
function GameTooltip:NumLines() return #self.lines end
function GameTooltip:ClearLines() self.lines = {} end
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(W.prints, m) end }
UISpecialFrames = {}
SlashCmdList = {}
RAID_CLASS_COLORS = setmetatable({}, { __index = function() return { r = 1, g = 1, b = 1 } end })
SOUNDKIT = {}
function PlaySound() end
W.cursor = { 0, 0 }
function GetCursorPosition() return W.cursor[1], W.cursor[2] end
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
        for i = 1, #W.frames do
            local f = W.frames[i]
            local u = f._scripts.OnUpdate
            if u and f._shown ~= false then u(f, step) end
        end
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
-- Position and maps. World coordinates are a flat plane: each map is a
-- rectangle (origin + size in yards), enough to test conversions.
W.map, W.pos = 1440, { 0.5, 0.5 }
W.maps = {
    [1440] = { name = "Ashenvale", ox = 0, oy = 0, w = 5767, h = 3844 },
    [1414] = { name = "Kalimdor", ox = -20000, oy = -10000, w = 40000, h = 30000 },
    [1439] = { name = "Darkshore", ox = 0, oy = -6000, w = 6000, h = 6000 },
}
function CreateVector2D(x, y)
    return { x = x, y = y, GetXY = function(v) return v.x, v.y end }
end
C_Map = {
    GetBestMapForUnit = function() return W.map end,
    GetPlayerMapPosition = function(map) if not W.pos then return nil end return CreateVector2D(W.pos[1], W.pos[2]) end,
    GetMapInfo = function(map) return W.maps[map] and { name = W.maps[map].name } end,
    GetWorldPosFromMapPos = function(map, v)
        local m = W.maps[map]
        if not m then return nil end
        return 1, CreateVector2D(m.ox + v.x * m.w, m.oy + v.y * m.h)
    end,
    GetMapPosFromWorldPos = function(cont, world, map)
        local m = W.maps[map]
        if not m then return nil end
        return map, CreateVector2D((world.x - m.ox) / m.w, (world.y - m.oy) / m.h)
    end,
}
W.instance = false
function IsInInstance() if W.instance then return true, "party" end return false, "none" end
W.combat = false
function UnitAffectingCombat() return W.combat end
function UnitIsDeadOrGhost() return false end
function UnitLevel() return 60 end
function GetGuildInfo() return "Moonwardens", "Warden-General", 0 end
function IsIndoors() return false end
W.radius = 233.33
C_Minimap = { GetViewRadius = function() return W.radius end }
W.cvars = { rotateMinimap = "0" }
function GetCVar(k) return W.cvars[k] end
W.facing = 0
function GetPlayerFacing() return W.facing end

WorldMapFrame = W.new("Frame", "WorldMapFrame")
WorldMapFrame._shown = false
WorldMapFrame.ScrollContainer = W.new("Frame")
WorldMapFrame.ScrollContainer.Child = W.new("Frame")
WorldMapFrame.ScrollContainer.Child:SetSize(1000, 667)
W.shownMap = 1440
function WorldMapFrame:GetMapID() return W.shownMap end
-- Scripts may be hooked more than once; keep them all.
function WorldMapFrame:HookScript(k, fn)
    local old = self._scripts[k]
    self._scripts[k] = old and function(...) old(...); fn(...) end or fn
end
-- Units for the layer detector: W.units[token] = { guid, pc = player-controlled }
W.units = {}
function UnitExists(u) return W.units[u] ~= nil end
function UnitGUID(u) return W.units[u] and W.units[u].guid end
function UnitPlayerControlled(u) return W.units[u] and W.units[u].pc or false end
W.plates = {}
C_NamePlate = { GetNamePlates = function()
    local t = {}
    for _, tok in ipairs(W.plates) do t[#t + 1] = { namePlateUnitToken = tok } end
    return t
end }
W.cleu = nil
function CombatLogGetCurrentEventInfo() return unpack(W.cleu) end
-- Group, invites, sounds, bindings
W.group = {}          -- list of "First Surname" in my party (not me)
W.raid = false
W.invites, W.sounds, W.converted, W.accepted, W.popupsHidden = {}, {}, 0, 0, {}
function GetNumGroupMembers() return #W.group > 0 and #W.group + 1 or 0 end
function IsInRaid() return W.raid end
local oldUnitName = UnitName
function UnitName(u)
    local i = u:match("^party(%d)$") or u:match("^raid(%d+)$")
    if i then
        local n = W.group[tonumber(i)]
        if n then local a, b = n:match("(%S+) (%S+)"); return a, b end
        return nil
    end
    return oldUnitName(u)
end
function InviteUnit(name) table.insert(W.invites, name) end
function ConvertToRaid() W.converted = W.converted + 1; W.raid = true end
function AcceptGroup() W.accepted = W.accepted + 1 end
function StaticPopup_Hide(w) table.insert(W.popupsHidden, w) end
function PlaySound(id) table.insert(W.sounds, id) end
function GetBindingKey(b) if b == "MOONWARDENS_RESPOND" then return "ALT-R" end end
-- Honorable kills and weekly reset
W.hk = nil            -- GetPVPSessionStats() kills; nil = not available yet
function GetPVPSessionStats() return W.hk, 0 end
function GetZoneText() return W.maps[W.map] and W.maps[W.map].name or "" end
W.untilReset = nil    -- set to make C_DateAndTime.GetSecondsUntilWeeklyReset exist
C_DateAndTime = setmetatable({}, { __index = function(_, k)
    if k == "GetSecondsUntilWeeklyReset" and W.untilReset then return function() return W.untilReset end end
end })
return W
