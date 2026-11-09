-- Alert: call nearby guildies for help.
-- A|1|id|map|x|y|layer|kind   (GUILD)   kind = "help"; room for "horde"
-- R|1|id|map|x|y              (WHISPER to the sender)
-- E|1|id                      (GUILD)   ended by the sender or expired
--
-- Receivers: same zone, within half the zone's larger side. They get a
-- chime, a banner that fades after 20 s, a Respond button and keybind, a
-- minimap edge pip toward the sender, and one chat line. An alert lives 2 min.
-- Sender: the alert button glows; a responder list builds as R arrives, with
-- auto-invite / auto-raid, Invite all, Ping again, End alert.
local _, ns = ...
local Alert = {}
ns.Alert = Alert

local LIFETIME = 120
local BANNER_TIME = 20
local SPAM_GUARD = 30
local SOUND = 8959          -- SOUNDKIT.RAID_WARNING; to be chosen in testing

local active                -- my alert: { id, at, map, x, y, reached, responders = { key -> r } }
local current               -- alert I received: { id, key, name, map, x, y, at, layer, responded }
local lastFrom = {}         -- key -> { id, at }  (spam guard)
local acceptFrom            -- key of a sender whose invite I auto-accept, until `acceptUntil`
local acceptUntil = 0
local button, list, banner

---------------------------------------------------------------------------
-- Geometry
---------------------------------------------------------------------------
function Alert.Yards(map, x1, y1, x2, y2)
    local w, h = ns.MapMini.ZoneSize(map)
    if not w then return end
    local dx, dy = (x2 - x1) * w, (y2 - y1) * h
    return math.sqrt(dx * dx + dy * dy), dx, dy
end

local DIRS = { "east", "northeast", "north", "northwest", "west", "southwest", "south", "southeast" }
local SHORT = { east = "E", northeast = "NE", north = "N", northwest = "NW", west = "W", southwest = "SW", south = "S", southeast = "SE" }
function Alert.Direction(dx, dy)
    local a = math.atan2(-dy, dx)                 -- map y grows southward
    local i = math.floor((a / (2 * math.pi)) * 8 + 0.5) % 8
    return DIRS[i + 1]
end

function Alert.InRange(map, x, y)
    local m, px, py = ns.Position.ReadMine()
    if m ~= map or not px then return false end
    local w, h = ns.MapMini.ZoneSize(map)
    if not w then return false end
    local d = Alert.Yards(map, px, py, x, y)
    return d <= 0.5 * math.max(w, h), d
end

local function mapName(map)
    local info = ns.try(C_Map.GetMapInfo, map)
    return type(info) == "table" and info.name or "this zone"
end

---------------------------------------------------------------------------
-- Group helpers
---------------------------------------------------------------------------
local function groupKeys()
    local keys = {}
    local raid = ns.try(IsInRaid) == true
    local n = ns.try(GetNumGroupMembers) or 0
    for i = 1, raid and n or 4 do
        local first, last = ns.try(UnitName, (raid and "raid" or "party") .. i)
        if type(first) == "string" then
            keys[ns.key(type(last) == "string" and last ~= "" and (first .. " " .. last) or first)] = true
        end
    end
    return keys
end
Alert.GroupKeys = groupKeys

local function invite(r)
    if groupKeys()[r.key] then return end
    local n = ns.try(GetNumGroupMembers) or 0
    if n >= 5 and ns.try(IsInRaid) ~= true then
        if not ns.db.autoRaid then return end
        local convert = C_PartyInfo and C_PartyInfo.ConvertToRaid or ConvertToRaid
        pcall(convert)
    end
    local inv = C_PartyInfo and C_PartyInfo.InviteUnit or InviteUnit
    pcall(inv, r.address)
    r.invited = true
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------
local function newId() return tostring((GetServerTime and GetServerTime() or time()) % 1000000) end

local function broadcast()
    local layer = ns.Layer and ns.Layer.Mine(active.map) or 0
    ns.Comm.Send({ "A", ns.Comm.PROTO, active.id, active.map, ("%.4f"):format(active.x), ("%.4f"):format(active.y), layer, "help" }, "GUILD")
end

local function countReach()
    local n = 0
    for _, g in pairs(ns.Position.All()) do
        if g.map == active.map then
            local d = Alert.Yards(g.map, active.x, active.y, g.x, g.y)
            local w, h = ns.MapMini.ZoneSize(g.map)
            if d and d <= 0.5 * math.max(w, h) then n = n + 1 end
        end
    end
    return n
end

-- Press the alert button / keybind. Pressing again while it's open pings again.
function Alert.Send()
    if active then return Alert.Ping() end
    if not IsInGuild() then ns.print("you're not in a guild.") return end
    local map, x, y = ns.Position.ReadMine()
    if not (map and x) then ns.print("can't send an alert here (no map position).") return end
    active = { id = newId(), at = ns.now(), map = map, x = x, y = y, responders = {}, order = {} }
    active.reached = countReach()
    broadcast()
    ns.print(("alert sent to guildies near you in %s."):format(mapName(map)))
    Alert.UpdateButton()
end

function Alert.Ping()
    if not active then return end
    local map, x, y = ns.Position.ReadMine()
    if map == active.map and x then active.x, active.y = x, y end
    active.reached = countReach()
    broadcast()
    Alert.UpdateList()
end

function Alert.End()
    if not active then return end
    ns.Comm.Send({ "E", ns.Comm.PROTO, active.id }, "GUILD")
    active = nil
    Alert.UpdateButton()
end

function Alert.InviteAll()
    if not active then return end
    for _, r in ipairs(active.order) do invite(r) end
    Alert.UpdateList()
end

function Alert.Active() return active end

local function onR(f, sender, key)
    if not active or f[3] ~= active.id then return end
    local map, x, y = tonumber(f[4]), tonumber(f[5]), tonumber(f[6])
    local r = active.responders[key]
    if not r then
        local m = ns.Roster.Get(key) or {}
        r = { key = key, name = m.name or sender, address = m.address or ns.address(sender), classFile = m.classFile }
        active.responders[key] = r
        active.order[#active.order + 1] = r
    end
    if map == active.map and x and y then r.dist = math.floor(Alert.Yards(map, active.x, active.y, x, y) + 0.5) end
    if ns.db.autoInvite then invite(r) end
    Alert.UpdateList()
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------
local function onA(f, sender, key)
    local id, map, x, y = f[3], tonumber(f[4]), tonumber(f[5]), tonumber(f[6])
    if not (id and map and x and y) then return end
    local prev = lastFrom[key]
    local repeatPing = prev and prev.id == id
    if prev and not repeatPing and ns.now() - prev.at < SPAM_GUARD then return end
    local ok, d = Alert.InRange(map, x, y)
    if not ok then return end
    lastFrom[key] = { id = id, at = ns.now() }

    local m = ns.Roster.Get(key) or {}
    local responded = repeatPing and current and current.id == id and current.responded
    current = { id = id, key = key, name = m.name or sender, address = m.address or ns.address(sender),
        classFile = m.classFile, map = map, x = x, y = y, at = ns.now(), layer = tonumber(f[7]) or 0,
        responded = responded }
    local mine = ns.Layer and ns.Layer.Mine(map) or 0
    current.otherLayer = current.layer ~= 0 and mine ~= 0 and current.layer ~= mine

    local _, px, py = ns.Position.ReadMine()
    local _, dx, dy = Alert.Yards(map, px, py, x, y)
    current.dir = dx and Alert.Direction(dx, dy) or ""
    current.dist = math.floor(d + 0.5)
    if ns.db.sound then PlaySound(SOUND, "Master") end
    ns.print(("|cffffd100%s needs help|r in %s (%d yd %s)%s."):format(current.name, mapName(map),
        current.dist, SHORT[current.dir] or "", current.otherLayer and ", other layer" or ""))
    Alert.ShowBanner()
end

local function onE(f, sender, key)
    if current and current.key == key and current.id == f[3] then
        current = nil
        if banner then banner:Hide() end
    end
end

function Alert.Respond()
    if not current or ns.now() - current.at > LIFETIME then return end
    local map, x, y = ns.Position.ReadMine()
    ns.Comm.Send({ "R", ns.Comm.PROTO, current.id, map or 0, ("%.4f"):format(x or 0), ("%.4f"):format(y or 0) },
        "WHISPER", current.address)
    current.responded = true
    if ns.db.autoAccept then acceptFrom, acceptUntil = current.key, ns.now() + LIFETIME end
    ns.print(("you answered %s's call."):format(current.name))
    Alert.ShowBanner()
end

function Alert.Current()
    if current and ns.now() - current.at > LIFETIME then current = nil end
    return current
end

-- Where the minimap pip points, or nil.
function Alert.PipTarget()
    local c = Alert.Current()
    if c then return c.map, c.x, c.y end
end

local function onPartyInvite(name)
    if not acceptFrom or ns.now() > acceptUntil then return end
    if ns.key(name) ~= acceptFrom then return end
    acceptFrom = nil
    pcall(AcceptGroup)
    if StaticPopup_Hide then pcall(StaticPopup_Hide, "PARTY_INVITE") end
end

---------------------------------------------------------------------------
-- Banner (receiver)
---------------------------------------------------------------------------
local function buildBanner()
    banner = CreateFrame("Frame", "MoonwardensAlertBanner", UIParent)
    banner:SetSize(560, 74)
    banner:SetPoint("TOP", UIParent, "TOP", 0, -110)
    banner:SetFrameStrata("HIGH")
    banner:Hide()
    local bg = banner:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(); bg:SetColorTexture(0, 0, 0, 0.6)
    for _, edge in ipairs({ "TOP", "BOTTOM" }) do
        local l = banner:CreateTexture(nil, "ARTWORK")
        l:SetColorTexture(0.85, 0.68, 0.1, 0.9)
        l:SetHeight(1)
        l:SetPoint(edge .. "LEFT", 40, 0); l:SetPoint(edge .. "RIGHT", -40, 0)
    end
    banner.title = banner:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    banner.title:SetPoint("TOP", 0, -12)
    banner.sub = banner:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    banner.sub:SetPoint("TOP", banner.title, "BOTTOM", 0, -6)
    banner.respond = CreateFrame("Button", nil, banner, "UIPanelButtonTemplate")
    banner.respond:SetSize(96, 22)
    banner.respond:SetPoint("TOP", banner, "BOTTOM", -40, -4)
    banner.respond:SetScript("OnClick", function() Alert.Respond() end)
    banner.key = banner:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    banner.key:SetPoint("LEFT", banner.respond, "RIGHT", 6, 0)
    banner:SetScript("OnUpdate", ns.guard(function(self)
        local c = Alert.Current()
        if not c then self:Hide() return end
        local left = BANNER_TIME - (ns.now() - c.at)
        if left <= 0 then self:Hide() return end
        self:SetAlpha(left < 2 and left / 2 or 1)
        local sub = ("%s - %d yards %s"):format(mapName(c.map), c.dist or 0, c.dir or "")
        if c.otherLayer then sub = sub .. " - other layer" end
        self.sub:SetText(sub .. ("  |cff9d9d9dfades in %ds|r"):format(math.ceil(left)))
    end, "banner"))
end

function Alert.ShowBanner()
    if not banner then buildBanner() end
    local c = current
    if not c then banner:Hide() return end
    local r, g, b = ns.classColor(c.classFile)
    banner.title:SetText(("|cff%02x%02x%02x%s|r needs help!"):format(r * 255, g * 255, b * 255, c.name))
    banner.respond:SetText(c.responded and "Responded" or "Respond")
    banner.respond:SetEnabled(not c.responded)
    local key = GetBindingKey and GetBindingKey("MOONWARDENS_RESPOND")
    banner.key:SetText(key and not c.responded and ("or press " .. key) or "")
    banner:SetAlpha(1)
    banner:Show()
end

---------------------------------------------------------------------------
-- Alert button + responder list (sender)
---------------------------------------------------------------------------
local function buildList()
    local ok
    ok, list = pcall(CreateFrame, "Frame", "MoonwardensAlertList", button, "BackdropTemplate")
    if not ok then list = CreateFrame("Frame", "MoonwardensAlertList", button) end
    list:SetSize(220, 100)
    list:SetPoint("TOPRIGHT", button, "TOPLEFT", -6, 0)
    list:SetFrameStrata("MEDIUM")
    if list.SetBackdrop then
        list:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        list:SetBackdropColor(0.04, 0.04, 0.04, 0.92)
        list:SetBackdropBorderColor(0.85, 0.68, 0.1, 1)
    end
    list.title = ns.UI.Text(list, nil, ns.UI.GOLD, "LEFT")
    list.title:SetPoint("TOPLEFT", 10, -8)
    list.rows = {}
    local function cb(label, setting)
        local c = CreateFrame("CheckButton", nil, list, "UICheckButtonTemplate")
        c:SetSize(20, 20)
        local t = ns.UI.Text(list, "small", nil, "LEFT"); t:SetPoint("LEFT", c, "RIGHT", 2, 0); t:SetText(label)
        c:SetScript("OnClick", function(self) ns.db[setting] = self:GetChecked() and true or false; ns.fire("SETTINGS", setting) end)
        c.setting = setting
        return c
    end
    list.autoInvite = cb("Auto-invite responders", "autoInvite")
    list.autoRaid = cb("Convert to raid at 5", "autoRaid")
    local function btn(label, fn)
        local b = CreateFrame("Button", nil, list, "UIPanelButtonTemplate")
        b:SetSize(64, 20); b:SetText(label)
        b:SetScript("OnClick", fn)
        return b
    end
    list.inviteAll = btn("Invite all", Alert.InviteAll)
    list.ping = btn("Ping again", Alert.Ping)
    list.stop = btn("End alert", Alert.End)
    list.foot = ns.UI.Text(list, "small", ns.UI.GREY, "LEFT")
    list:SetScript("OnUpdate", ns.guard(function(self, el)
        self.acc = (self.acc or 0) + el
        if self.acc < 1 then return end
        self.acc = 0
        Alert.UpdateList()
    end, "alert list"))
end

function Alert.UpdateList()
    if not list then return end
    if not active then list:Hide() return end
    local left = LIFETIME - (ns.now() - active.at)
    if left <= 0 then Alert.End() return end
    local n = #active.order
    list.title:SetText(("Help called - %d responding"):format(n))
    local inGroup = groupKeys()
    local y = -26
    for i, r in ipairs(active.order) do
        local row = list.rows[i]
        if not row then
            row = { name = ns.UI.Text(list, "small", nil, "LEFT"), info = ns.UI.Text(list, "small", nil, "RIGHT") }
            list.rows[i] = row
        end
        row.name:SetPoint("TOPLEFT", 10, y); row.info:SetPoint("TOPRIGHT", -10, y)
        row.name:SetText(r.name); row.name:SetTextColor(ns.classColor(r.classFile))
        local status = inGroup[r.key] and "|TInterface\\RaidFrame\\ReadyCheck-Ready:12|t"
            or r.invited and "|cffffd100inv.|r" or ""
        row.info:SetText((r.dist and ("%d yd "):format(r.dist) or "") .. status)
        row.name:Show(); row.info:Show()
        y = y - 14
    end
    for i = n + 1, #list.rows do list.rows[i].name:Hide(); list.rows[i].info:Hide() end
    y = y - 4
    list.autoInvite:SetPoint("TOPLEFT", 6, y); list.autoInvite:SetChecked(ns.db.autoInvite)
    list.autoRaid:SetPoint("TOPLEFT", 6, y - 18); list.autoRaid:SetChecked(ns.db.autoRaid)
    y = y - 42
    list.inviteAll:SetPoint("TOPLEFT", 10, y); list.ping:SetPoint("LEFT", list.inviteAll, "RIGHT", 4, 0)
    list.stop:SetPoint("LEFT", list.ping, "RIGHT", 4, 0)
    list.foot:SetPoint("TOPLEFT", 10, y - 24)
    list.foot:SetText(("%d:%02d left - reached %d guildies"):format(left / 60, left % 60, active.reached or 0))
    list:SetHeight(-y + 44)
    list:Show()
end

local function savePos()
    local p, _, rp, x, y = button:GetPoint()
    ns.db.alertButtonPos = { p, rp, x, y }
end

local function buildButton()
    button = CreateFrame("Button", "MoonwardensAlertButton", UIParent)
    button:SetSize(42, 42)
    button:SetFrameStrata("MEDIUM")
    local pos = ns.db.alertButtonPos
    if pos then button:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else button:SetPoint("RIGHT", UIParent, "RIGHT", -60, -60) end
    button:SetClampedToScreen(true)
    button:SetMovable(true)
    button:RegisterForDrag("LeftButton")
    button:RegisterForClicks("LeftButtonUp")
    -- Our own art (media/, drawn by tools_make_icons.py): a red megaphone in
    -- a red rounded square, so it can't be taken for an action button.
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\AddOns\\Moonwardens\\media\\alert")
    icon:SetAllPoints()
    button.border = button:CreateTexture(nil, "OVERLAY")
    button.border:SetTexture("Interface\\AddOns\\Moonwardens\\media\\alert_glow")
    button.border:SetBlendMode("ADD")
    button.border:SetSize(64, 64); button.border:SetPoint("CENTER")
    local hl = button:CreateTexture(nil, "HIGHLIGHT")
    hl:SetTexture("Interface\\AddOns\\Moonwardens\\media\\alert")
    hl:SetAllPoints(); hl:SetBlendMode("ADD"); hl:SetAlpha(0.35)
    button:SetScript("OnMouseDown", function() icon:SetPoint("TOPLEFT", 1, -1); icon:SetPoint("BOTTOMRIGHT", 1, -1) end)
    button:SetScript("OnMouseUp", function() icon:ClearAllPoints(); icon:SetAllPoints() end)
    button:SetScript("OnClick", function() Alert.Send() end)
    button:SetScript("OnDragStart", function(self) if not ns.db.alertButtonLocked then self:StartMoving() end end)
    button:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); savePos() end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Call for help", 1, 0.82, 0)
        GameTooltip:AddLine(active and "Click to ping again." or "Alerts guildies in this zone near you.", 1, 1, 1)
        if not ns.db.alertButtonLocked then GameTooltip:AddLine("Drag to move.", 0.62, 0.62, 0.62) end
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    buildList()
end

function Alert.UpdateButton()
    if not button then return end
    button:SetShown(ns.db.alertButton and true or false)
    button.border:SetShown(active ~= nil)
    Alert.UpdateList()
end

ns.onLogin(function()
    ns.Comm.handlers.A = onA
    ns.Comm.handlers.R = onR
    ns.Comm.handlers.E = onE
    ns:On("PARTY_INVITE_REQUEST", onPartyInvite)
    buildButton()
    Alert.UpdateButton()
    ns.listen("SETTINGS", function(k) if k == "alertButton" then Alert.UpdateButton() end end)
    ns.every(1, function() if active and ns.now() - active.at >= LIFETIME then Alert.End() end end, "alert expiry")
end, "alert")

ns.slash.button = { help = "show the alert button and put it back at the centre of the screen", fn = function()
    if not button then ns.print("the alert button wasn't built; there should be an error in chat from login.") return end
    ns.db.alertButton = true
    ns.db.alertButtonPos = nil
    button:ClearAllPoints()
    button:SetPoint("CENTER", UIParent, "CENTER", 200, 0)
    savePos()
    Alert.UpdateButton()
    local l, b = button:GetLeft(), button:GetBottom()
    ns.print(("alert button shown at the centre-right of the screen (shown=%s, visible=%s, strata=%s, left=%s, bottom=%s). Drag it where you want it."):format(
        tostring(button:IsShown()), tostring(button:IsVisible()), tostring(button:GetFrameStrata()), tostring(l and math.floor(l)), tostring(b and math.floor(b))))
end }

ns.slash.alert = { help = "send an alert (same as the button)", fn = function() Alert.Send() end }
ns.slash.respond = { help = "answer the last alert", fn = function() Alert.Respond() end }

BINDING_HEADER_MOONWARDENS = "Moonwardens"
BINDING_NAME_MOONWARDENS_ALERT = "Call guildies for help"
BINDING_NAME_MOONWARDENS_RESPOND = "Answer a guildie's call"
