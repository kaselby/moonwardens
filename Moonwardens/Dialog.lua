-- Dialog: our own confirm box (a line of text, optionally a text field or a
-- time picker, two buttons), drawn like the game's. We don't use the game's
-- StaticPopup for our questions: its few frames are shared with the game's
-- own protected confirmations (deleting an item, leaving a group...), and
-- showing one from addon code taints them for those.
--   ns.Dialog.Show{ text = "...", accept = "Revoke", edit = true, maxLetters = 80,
--                   onAccept = function(typed) ... end }
--   ns.Dialog.Show{ text = "...", when = true, onAccept = function(_, t) ... end }
-- `when`: Day / Hour / Minute / AM-PM dropdowns (nothing typed, so nothing
-- to get wrong); onAccept gets the moment picked, as a timestamp. onAccept
-- may return false, "why" to keep the box open and say why.
-- `noCancel`: one button, centred. `noEscape`: Escape doesn't close it
-- (only its button does). `title`: a heading above the text, larger.
local _, ns = ...
local Dialog = {}
ns.Dialog = Dialog

local WIDTH = 440
local DAYS = 7                 -- the picker goes back this many days, today included
local f
local current
local pick = {}                -- day (0 = today), hour (1-12), min (0-55), pm

-- Escape closes it (it's one of the game's UISpecialFrames) - or not.
local function escapeCloses(on)
    local at
    for i, name in ipairs(UISpecialFrames) do if name == "MoonwardensDialog" then at = i end end
    if on and not at then tinsert(UISpecialFrames, "MoonwardensDialog")
    elseif not on and at then tremove(UISpecialFrames, at) end
end

-- The moment picked, as a timestamp (this computer's clock and time zone).
local function picked()
    local d = date("*t", time() - pick.day * 86400)
    d.hour = (pick.hour % 12) + (pick.pm and 12 or 0)
    d.min, d.sec = pick.min, 0
    return time(d)
end

local function accept()
    local c = current
    if not c then return end
    local typed = c.edit and (f.edit:GetText() or "") or nil
    local when = c.when and picked() or nil
    local ok, why = true, nil
    if c.onAccept then
        local okCall, r1, r2 = pcall(c.onAccept, typed, when)
        if not okCall then ns.print("|cffff4040error|r dialog: " .. tostring(r1)); r1 = true end
        if r1 == false then ok, why = false, r2 end
    end
    if ok then f:Hide() else f.err:SetText(why or "") end
end

local function dropdown(parent, width, label, items, get, set)
    local okDD, dd = pcall(CreateFrame, "DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
    if not (okDD and dd and dd.SetupMenu) then return nil end
    dd:SetWidth(width)
    dd:SetupMenu(function(_, root)
        for _, it in ipairs(items()) do
            root:CreateRadio(it.text, function(v) return get() == v end, function(v) set(v); f.err:SetText("") end, it.value)
        end
    end)
    if label then
        dd.label = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        dd.label:SetPoint("BOTTOMLEFT", dd, "TOPLEFT", 2, 2)
        dd.label:SetText(label)
    end
    return dd
end

local function buildPicker()
    local p = CreateFrame("Frame", nil, f)
    p:SetSize(WIDTH - 60, 44)
    p.day = dropdown(p, 150, "Day", function()
        local list = {}
        for i = 0, DAYS - 1 do
            local t = time() - i * 86400
            local name = i == 0 and "Today" or i == 1 and "Yesterday" or date("%A", t)
            list[#list + 1] = { text = ("%s  |cff9d9d9d%s|r"):format(name, date("%m/%d", t)), value = i }
        end
        return list
    end, function() return pick.day end, function(v) pick.day = v end)
    p.hour = dropdown(p, 62, "Time", function()
        local list = {}
        for h = 1, 12 do list[#list + 1] = { text = tostring(h), value = h } end
        return list
    end, function() return pick.hour end, function(v) pick.hour = v end)
    p.min = dropdown(p, 62, nil, function()
        local list = {}
        for m = 0, 55, 5 do list[#list + 1] = { text = ("%02d"):format(m), value = m } end
        return list
    end, function() return pick.min end, function(v) pick.min = v end)
    p.pm = dropdown(p, 62, nil, function()
        return { { text = "AM", value = false }, { text = "PM", value = true } }
    end, function() return pick.pm end, function(v) pick.pm = v end)
    if not (p.day and p.hour and p.min and p.pm) then return nil end
    p.day:SetPoint("BOTTOMLEFT", 0, 0)
    p.hour:SetPoint("LEFT", p.day, "RIGHT", 16, 0)
    p.min:SetPoint("LEFT", p.hour, "RIGHT", 4, 0)
    p.pm:SetPoint("LEFT", p.min, "RIGHT", 4, 0)
    return p
end

local function build()
    f = CreateFrame("Frame", "MoonwardensDialog", UIParent, "BackdropTemplate")
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetWidth(WIDTH)
    f:SetPoint("TOP", UIParent, "TOP", 0, -135)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    f.title = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    f.title:SetPoint("TOP", 0, -20)
    f.title:SetWidth(WIDTH - 50)
    f.title:SetJustifyH("CENTER")
    f.title:Hide()
    f.text = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    f.text:SetPoint("TOP", 0, -20)
    f.text:SetWidth(WIDTH - 50)
    f.text:SetJustifyH("CENTER")
    f.text:SetSpacing(2)
    f.edit = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.edit:SetSize(WIDTH - 90, 22)
    f.edit:SetAutoFocus(false)
    f.edit:SetScript("OnEnterPressed", accept)
    f.edit:SetScript("OnEscapePressed", function() f:Hide() end)
    f.picker = buildPicker()
    if f.picker then f.picker:Hide() end
    f.err = f:CreateFontString(nil, "ARTWORK", "GameFontRedSmall")
    f.err:SetWidth(WIDTH - 50)
    f.ok = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.ok:SetSize(120, 22)
    f.ok:SetScript("OnClick", accept)
    f.cancel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.cancel:SetSize(120, 22)
    f.cancel:SetText(CANCEL or "Cancel")
    f.cancel:SetScript("OnClick", function() f:Hide() end)
    f.ok:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -6, 16)
    f.cancel:SetPoint("BOTTOMLEFT", f, "BOTTOM", 6, 16)
    f:SetScript("OnHide", function()
        current = nil
        f.edit:ClearFocus()
        escapeCloses(true)
    end)
    f:Hide()
    escapeCloses(true)              -- (Escape closes it, as the game's do)
end

function Dialog.Show(opts)
    if not f then build() end
    if opts.when and not f.picker then
        ns.print("|cffff4040This client has no dropdowns for the time picker.|r")
        return
    end
    current = opts
    local top = 20
    f.text:ClearAllPoints()
    if opts.title then
        f.title:SetText(opts.title)
        f.title:Show()
        f.text:SetPoint("TOP", f.title, "BOTTOM", 0, -10)
        top = top + f.title:GetStringHeight() + 10
    else
        f.title:Hide()
        f.text:SetPoint("TOP", 0, -20)
    end
    f.text:SetText(opts.text or "")
    f.ok:SetText(opts.accept or OKAY or "Okay")
    f.cancel:SetShown(not opts.noCancel)
    f.ok:ClearAllPoints()
    if opts.noCancel then f.ok:SetPoint("BOTTOM", f, "BOTTOM", 0, 16)
    else f.ok:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -6, 16) end
    escapeCloses(not opts.noEscape)
    f.err:SetText("")
    local h = top + f.text:GetStringHeight() + 16
    local below = f.text
    f.edit:ClearAllPoints()
    if opts.edit then
        f.edit:SetMaxLetters(opts.maxLetters or 80)
        f.edit:SetText("")
        f.edit:SetPoint("TOP", f.text, "BOTTOM", 0, -12)
        f.edit:Show()
        h, below = h + 34, f.edit
    else
        f.edit:Hide()
    end
    if f.picker then
        f.picker:ClearAllPoints()
        f.picker:SetShown(opts.when and true or false)
        if opts.when then
            -- Now, to the five minutes before.
            local d = date("*t")
            pick.day, pick.min, pick.pm = 0, d.min - d.min % 5, d.hour >= 12
            pick.hour = d.hour % 12 == 0 and 12 or d.hour % 12
            for _, k in ipairs({ "day", "hour", "min", "pm" }) do
                if f.picker[k].GenerateMenu then pcall(f.picker[k].GenerateMenu, f.picker[k]) end
            end
            f.picker:SetPoint("TOP", f.text, "BOTTOM", 0, -14)
            h, below = h + 58, f.picker
        end
    end
    f.err:ClearAllPoints()
    f.err:SetPoint("TOP", below, "BOTTOM", 0, -6)
    f:SetHeight(h + 16 + 22 + 26)
    f:Show()
    f:Raise()
    if opts.edit then f.edit:SetFocus() end
    PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPEN or 850)
end

function Dialog.Hide() if f then f:Hide() end end

-- A timestamp as people read it: "Sat 11/21, 7:30 PM".
function Dialog.When(t)
    if type(t) ~= "number" or t <= 0 then return "?" end
    return (date("%a %m/%d, %I:%M %p", t):gsub(", 0", ", "))
end
