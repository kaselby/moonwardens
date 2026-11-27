-- RosterTRP: totalRP3's own character tooltip for guildies hovered in the
-- guild roster, and on their world map and minimap dots, drawn in totalRP3's
-- tooltip frame with its settings (fonts,
-- colours, icons, what to show), exactly as when you mouse over them in the
-- world: RP icon and name, OOC / AFK / experience icons, full title, race,
-- class and level, guild, relation, Currently, OOC information, pronouns,
-- voice reference, zone, the unread / notes / walk-up icons and their TRP
-- version. Then the roster's own Note line.
--
-- totalRP3 builds that tooltip only for a unit in the world (its function is
-- private, and reads the unit's class, race, health and target). This is the
-- same sequence as its writeTooltipForCharacter (totalRP3 3.5.5), with the
-- unit's parts taken from the roster instead: class, race, level, zone,
-- AFK / busy. What only a unit has is left out: health, PvP flag, their
-- target, and a title from the game.
--
-- Only for guildies totalRP3 has a profile for (you, too); others keep the
-- game-style tooltip (RosterLayer.lua). On the maps only for one guildie
-- alone under the cursor with nothing of the game's there (MapWorld.lua,
-- MapMini.lua): a flight master, a node, a party member or another guildie
-- in the stack keeps the shared tooltip, which can hold them all. Dots add
-- a Moonwardens footer: dead / in combat, layer, last seen. Hovering an online guildie also asks
-- totalRP3 to fetch their profile, as a mouseover does (it has its own
-- cooldown), and the tooltip redraws when it arrives.
-- Everything is read through totalRP3's public API (TRP3_API, AddOn_TotalRP3)
-- and guarded: if any of it isn't there or fails, the game-style tooltip shows.
local _, ns = ...
local RT = {}
ns.RosterTRP = RT

local OOC_ICON = "|TInterface\\COMMON\\Indicator-Red:15:15|t"
local AFK_ICON = "|TInterface\\FriendsFrame\\StatusIcon-Away:15:15|t"
local DND_ICON = "|TInterface\\FriendsFrame\\StatusIcon-DnD:15:15|t"
local ALLIANCE_ICON = "|TInterface\\GROUPFRAME\\UI-Group-PVP-Alliance:20:20|t"
local HORDE_ICON = "|TInterface\\GROUPFRAME\\UI-Group-PVP-Horde:20:20|t"
local NEW_ABOUT_ICON = "|TInterface\\AddOns\\totalRP3\\Resources\\UI\\ui-icon-unread:22:22|t"
local PROFILE_NOTES_ICON = "|TInterface\\AddOns\\totalRP3\\Resources\\UI\\ui-icon-note:22:22|t"
local TRANSPARENT_ICON = "|TInterface\\AddOns\\totalRP3\\Resources\\UI\\transparent:22:22|t"
local WALKUP_ICON = "|TInterface\\AddOns\\totalRP3\\Resources\\UI\\ui-icon-walkup:22:22|t"
local CROP = { Title = 100, Name = 50, Race = 30, Class = 30, Pronouns = 30, GuildName = 30, GuildRank = 30, VoiceReference = 30 }
-- (totalRP3's guild option: false hidden, true with custom guild, 2 original, 3 all)
local GUILD_HIDDEN, GUILD_CUSTOM, GUILD_ORIGINAL, GUILD_ALL = false, true, 2, 3
local RELATION_HIDDEN, RELATION_FULL = 1, 3

local builder
local shown                 -- { owner, who, id, anchor, key, drawn } while wanted
local warned = false

local function available()
    return type(TRP3_API) == "table" and type(TRP3_API.register) == "table" and type(TRP3_API.configuration) == "table"
        and type(TRP3_API.ui) == "table" and type(TRP3_API.ui.tooltip) == "table"
        and type(TRP3_API.ui.tooltip.createTooltipBuilder) == "function"
        and TRP3_CharacterTooltip and type(AddOn_TotalRP3) == "table" and type(AddOn_TotalRP3.Player) == "table"
        and type(TRP3_NameUtil) == "table" and type(TRP3_NameUtil.GetQualifiedNameFromString) == "function"
end

local function cfg(key) return TRP3_API.configuration.getValue(key) end

-- totalRP3's limitText: at most maxLines lines and maxChars characters.
local function limitText(input, maxChars, maxLines)
    local crop = TRP3_API.utils.str.crop
    local finish, matches = 0, 0
    repeat
        finish = string.find(input, "\n", finish + 1, true)
        matches = matches + 1
    until not finish or matches >= maxLines + 1
    if not finish then
        if #input <= maxChars then return input end
        return crop(input, maxChars)
    end
    return crop(input, math.min(finish - 1, maxChars))
end

-- What the tooltip needs of a guildie, from a roster row or a map dot:
-- { name, classFile, className, raceName, level, zone, rank, note, afk,
--   busy, online, isSelf, footer = { { text, r, g, b }... } }
local function fromMember(m)
    local w = { name = m.name, level = m.level, zone = m.zone, rank = m.guildRank, note = m.memberNote, isSelf = m.isSelf }
    if m.classID and C_CreatureInfo then
        local ok, ci = pcall(C_CreatureInfo.GetClassInfo, m.classID)
        if ok and ci then w.classFile, w.className = ci.classFile, ci.className end
    end
    if m.race and C_CreatureInfo then
        local ok, ri = pcall(C_CreatureInfo.GetRaceInfo, m.race)
        if ok and ri then w.raceName = ri.raceName end
    end
    local P = Enum and Enum.ClubMemberPresence
    w.afk = P and m.presence == P.Away
    w.busy = P and m.presence == P.Busy
    w.online = not (P and m.presence == P.Offline)
    return w
end

local function zoneName(map)
    local info = map and C_Map and ns.try(C_Map.GetMapInfo, map)
    return type(info) == "table" and type(info.name) == "string" and info.name or nil
end

-- A dot's guildie: the roster for who they are, their position for the rest.
local function fromDot(g)
    local m = ns.Roster.Get(g.key)
    if not m then return nil end
    local P = ns.Position
    local w = { name = m.name, classFile = m.classFile, className = m.class, raceName = m.race,
        level = g.level or m.level, zone = zoneName(g.map), rank = m.rank, online = true, footer = {} }
    local f = w.footer
    if P.HasFlag(g, P.FLAG_DEAD) then f[#f + 1] = { "Dead", 0.62, 0.62, 0.62 }
    elseif P.HasFlag(g, P.FLAG_COMBAT) then f[#f + 1] = { "In combat", 1, 0.25, 0.25 } end
    local text = P.LayerText(g)
    if text then f[#f + 1] = { text, 0.75, 0.75, 0.75 } end
    local age = ns.now() - (g.at or ns.now())
    if age > 20 then f[#f + 1] = { ("last seen %d s ago"):format(age), 0.62, 0.62, 0.62 } end
    return w
end

-- totalRP3's writeTooltipForCharacter, from a roster row or a dot (see the top).
local function write(id, m)
    local T, R, loc, G = TRP3_API, TRP3_API.register, TRP3_API.loc, TRP3_API.globals
    local crop = T.utils.str.crop
    local C = TRP3_TooltipCroppingConstants or CROP
    local mainSize, subSize, smallSize = cfg("tooltip_char_mainSize"), cfg("tooltip_char_subSize"), cfg("tooltip_char_terSize")
    local colors = T.ui.tooltip.getTooltipTextColors()
    local b = builder
    local isMe = id == G.player_id

    local info, character
    if isMe then
        info, character = T.profile.getData("player"), T.profile.getPlayerCharacter()
    elseif R.isUnitIDKnown(id) then
        info, character = R.getUnitIDCurrentProfile(id) or {}, R.getUnitIDCharacter(id) or {}
    end
    info, character = info or {}, character or {}
    local player = AddOn_TotalRP3.Player.CreateFromCharacterID(id)
    local profileID = player:GetProfileID()

    local healthBar = TRP3_CharacterTooltip.StatusBar
    if healthBar and healthBar.ClearWatch then healthBar:ClearWatch() end

    -- Blocked
    if R.isIDIgnored(id) then
        b:AddLine(loc.REG_TT_IGNORED, T.Colors.Red, subSize)
        b:AddLine("\"" .. (R.getIgnoreReason(id) or "") .. "\"", T.CreateColor(1, 0.75, 0, 1), smallSize)
        b:Build()
        return
    elseif R.unitIDIsFilteredForMatureContent and R.unitIDIsFilteredForMatureContent(id) then
        local icon = T.utils.str.texture("Interface\\AddOns\\totalRP3\\resources\\18_emoji.tga", 20)
        b:AddLine(icon .. " " .. loc.MATURE_FILTER_TOOLTIP_WARNING, T.CreateColor(1, 0.75, 0.86, 1), subSize)
        b:AddLine(loc.MATURE_FILTER_TOOLTIP_WARNING_SUBTEXT, T.CreateColor(1, 0.75, 0, 1), smallSize, true)
        b:Build()
        return
    end

    -- Icon, complete name, OOC / AFK / experience
    local classFile, className = m.classFile, m.className
    local color = T.GetClassDisplayColor(classFile)
    local rightIcons = ""
    if cfg("tooltip_char_color") then color = player:GetCustomColorForDisplay() or color end
    local targetName = (m.name or ""):gsub("%-", " ")       -- (Forever: "First Surname")
    local completeName = R.getCompleteName(info.characteristics or {}, targetName, not cfg("tooltip_char_title"))
    completeName = color:WrapTextInColorCode(crop(completeName, C.Name))
    if info.character and info.character.RP ~= 1 then
        if TRP3_OOCIndicatorStyle and cfg("tooltip_prefere_ooc_icon") == TRP3_OOCIndicatorStyle.Text then
            completeName = strconcat(T.Colors.Red("[" .. loc.CM_OOC .. "] "), completeName)
        else
            rightIcons = strconcat(rightIcons, OOC_ICON)
        end
    end
    if cfg("tooltip_char_icons") then
        if m.afk then rightIcons = strconcat(rightIcons, AFK_ICON)
        elseif m.busy then rightIcons = strconcat(rightIcons, DND_ICON) end
        local exp = T.GetRoleplayExperienceIconMarkup and T.GetRoleplayExperienceIconMarkup(player:GetRoleplayExperience())
        if exp then rightIcons = strconcat(rightIcons, exp) end
    end
    b:AddDoubleLine(completeName, rightIcons, colors.MAIN, colors.MAIN, mainSize)
    if cfg("tooltip_char_icons") and info.characteristics and info.characteristics.IC then
        b:AddIcon(info.characteristics.IC, { width = 32, height = 32,
            anchor = Enum.TooltipTextureAnchor and Enum.TooltipTextureAnchor.LeftCenter,
            margin = { left = 0, right = 4, top = 0, bottom = 0 } })
    end

    -- Full title
    if cfg("tooltip_char_ft") then
        local ft = info.characteristics and info.characteristics.FT
        if ft and ft ~= "" then
            ft = crop(string.gsub(ft, "%s+", " "), C.Title)
            b:AddLine(strconcat("< ", ft, " >"), colors.TITLE, subSize, true)
        end
    end
    b:AddSpace()

    -- Race, class, level and faction
    if cfg("tooltip_char_rc") then
        local race, class = m.raceName or "", className or ""
        if info.characteristics and info.characteristics.RA and info.characteristics.RA ~= "" then
            race = crop(info.characteristics.RA, C.Race)
        end
        if info.characteristics and info.characteristics.CL and info.characteristics.CL ~= "" then
            class = crop(info.characteristics.CL, C.Class)
        end
        local left = string.trim(strconcat(race, " ", color:WrapTextInColorCode(class)))
        local faction = ns.try(UnitFactionGroup, "player")       -- (guildmates share it)
        local icon = faction == "Alliance" and ALLIANCE_ICON or faction == "Horde" and HORDE_ICON or ""
        local right = loc.REG_TT_LEVEL:format(m.level or "?", icon)
        b:AddDoubleLine(left, right, colors.MAIN, colors.MAIN, subSize)
    end

    -- Guild (the original is ours; the custom one from the profile)
    local guildOption = cfg("tooltip_char_guild")
    if guildOption ~= GUILD_HIDDEN then
        local custom = player:GetCustomGuildMembership() or {}
        local customName = custom.name and string.trim(custom.name) or nil
        local customRank = custom.rank and string.trim(custom.rank) or nil
        if customRank == "" then customRank = nil end
        local originalName = ns.try(GetGuildInfo, "player")
        local originalRank = m.rank
        local showOriginal = originalName and originalName ~= "" and (guildOption == GUILD_ORIGINAL or guildOption == GUILD_ALL
            or (guildOption == GUILD_CUSTOM and (not customName or customName == "")))
        local showCustom = customName and customName ~= "" and (guildOption == GUILD_CUSTOM or guildOption == GUILD_ALL)
        if showOriginal then
            local text = string.format(loc.REG_TT_GUILD, crop(originalRank or loc.DEFAULT_GUILD_RANK, C.GuildRank),
                colors.SECONDARY:WrapTextInColorCode(crop(originalName, C.GuildName)))
            local membership = ""
            if info.misc and info.misc.ST then
                if info.misc.ST["6"] == 1 then membership = " |cnGREEN_FONT_COLOR:(" .. loc.REG_TT_GUILD_IC .. ")"
                elseif info.misc.ST["6"] == 2 then membership = " |cnRED_FONT_COLOR:(" .. loc.REG_TT_GUILD_OOC .. ")" end
            end
            b:AddDoubleLine(text, membership, colors.MAIN, colors.MAIN, subSize)
        end
        if showCustom then
            local text = string.format(loc.REG_TT_GUILD, crop(customRank or loc.DEFAULT_GUILD_RANK, C.GuildRank),
                colors.SECONDARY:WrapTextInColorCode(crop(customName, C.GuildName)))
            b:AddDoubleLine(text, " |cnBATTLENET_FONT_COLOR:(" .. loc.REG_TT_GUILD_CUSTOM .. ")", colors.MAIN, colors.MAIN, subSize)
        end
    end

    -- Relationship
    local relationLine = cfg("tooltip_char_relation_line")
    if relationLine ~= RELATION_HIDDEN and profileID and R.relation then
        local relation = R.relation.getRelation(profileID)
        if relation and relation.id ~= "NONE" then
            local rc = R.relation.getColor(relation) or colors.SECONDARY
            local text, wrap
            if relationLine == RELATION_FULL then
                text, wrap = rc:WrapTextInColorCode(R.relation.getRelationTooltipText(profileID, player:GetProfile())), true
            else
                text, wrap = loc.REG_RELATION .. ": " .. rc:WrapTextInColorCode(R.relation.getRelationText(profileID)), false
            end
            b:AddLine(text, colors.MAIN, subSize, wrap)
        end
    end
    b:AddSpace()

    -- Currently, and OOC information
    local maxSize, maxLines = cfg("tooltip_char_current_size"), cfg("tooltip_char_current_lines")
    local function status(show, field, title)
        if not (show and info.character and info.character[field] and info.character[field] ~= "") then return end
        local text = strtrim(info.character[field])
        if text == "" then return end
        b:AddLine(title, colors.MAIN, subSize)
        b:AddLine(limitText(text, maxSize, maxLines), colors.SECONDARY, smallSize, true)
    end
    status(cfg("tooltip_char_current"), "CU", loc.DB_STATUS_CURRENTLY)
    b:AddSpace()
    status(cfg("tooltip_char_ooc"), "CO", loc.DB_STATUS_CURRENTLY_OOC)
    b:AddSpace()

    -- Pronouns, voice reference
    local function field(show, value, label, max)
        if not (show and value) then return end
        b:AddLine(string.format("%1$s: %2$s", label, colors.SECONDARY:WrapTextInColorCode(crop(value, max))), colors.MAIN, subSize, true)
    end
    field(cfg("tooltip_char_pronouns"), player.GetCustomPronouns and player:GetCustomPronouns(), loc.REG_PLAYER_MISC_PRESET_PRONOUNS, C.Pronouns)
    field(cfg("tooltip_char_voice_reference"), player.GetCustomVoiceReference and player:GetCustomVoiceReference(),
        loc.REG_PLAYER_MISC_PRESET_VOICE_REFERENCE, C.VoiceReference)

    -- Zone, when it isn't yours
    if cfg("tooltip_char_zone") and not isMe and m.zone and m.zone ~= "" and m.zone ~= ns.try(GetRealZoneText) then
        b:AddLine(string.format("%1$s: %2$s", loc.REG_TT_ZONE, colors.SECONDARY:WrapTextInColorCode(m.zone)), colors.MAIN, subSize)
    end

    -- Unread / notes / walk-up icons, and their client
    local spinner = TRP3_CharacterTooltip.ProgressSpinner
    if cfg("tooltip_char_notif") then
        local pieces = {}
        if not isMe and R.ui and R.ui.shouldShowUnreadAboutIcon and R.ui.shouldShowUnreadAboutIcon(info) then pieces[#pieces + 1] = NEW_ABOUT_ICON end
        if player:GetCharacterSpecificNotes() or (player.GetAccountWideNotes and player:GetAccountWideNotes()) then pieces[#pieces + 1] = PROFILE_NOTES_ICON end
        if player.IsWalkupFriendly and player:IsWalkupFriendly() then pieces[#pieces + 1] = WALKUP_ICON end
        pieces[#pieces + 1] = TRANSPARENT_ICON
        local notif = table.concat(pieces, " ")
        local client = ""
        if cfg("tooltip_char_client") then
            local S = T.utils.str
            if isMe then
                client = strconcat(S.sanitize(G.addon_name_me), " v", S.sanitizeVersion(G.version_display))
                if G.extended_version then client = strconcat(client, " x ", S.sanitizeVersion(G.extended_display_version)) end
            elseif character.client then
                client = strconcat(character.client, " v", character.clientVersion or "")
                if character.extendedVersion then client = strconcat(client, " x ", character.extendedVersion) end
            end
            if player.IsOnATrialAccount and player:IsOnATrialAccount() then
                client = strconcat(client, " ", colors.SECONDARY("(" .. loc.REG_TRIAL_ACCOUNT .. ")"))
            end
        end
        b:AddDoubleLine(notif ~= "" and notif or " ", client, colors.MAIN, colors.MAIN, 10)
        if spinner then
            if R.HasActiveRequest and R.HasActiveRequest(id) then
                local left = TRP3_TooltipUtil.GetLineFontStrings(TRP3_CharacterTooltip, TRP3_CharacterTooltip:NumLines())
                spinner:ClearAllPoints(); spinner:SetPoint("RIGHT", left); spinner:Show()
            else
                spinner:Hide()
            end
        end
    elseif spinner then
        spinner:Hide()
    end

    -- Ours: their roster note, and a dot's footer.
    if m.note and m.note ~= "" then
        b:AddSpace()
        local fmt = COMMUNITY_MEMBER_NOTE_FORMAT or "Note: %s"
        b:AddLine(fmt:format(m.note), T.CreateColor(1, 0.82, 0, 1), smallSize, true)
    end
    if m.footer and #m.footer > 0 then
        b:AddSpace()
        for _, l in ipairs(m.footer) do b:AddLine(l[1], T.CreateColor(l[2], l[3], l[4], 1), smallSize) end
    end

    b:Build()
end

local function characterID(w)
    if w.isSelf then return TRP3_API.globals.player_id end
    local ok, id = pcall(TRP3_NameUtil.GetQualifiedNameFromString, w.name)
    if ok and type(id) == "string" then return id end
end

-- totalRP3's own rules for when its tooltip shows.
local function allowed()
    if cfg("tooltip_in_character_only") and TRP3_API.dashboard and TRP3_API.dashboard.isPlayerIC
            and not TRP3_API.dashboard.isPlayerIC() then return false end
    if ns.try(InCombatLockdown) == true and cfg("tooltip_char_combat") then return false end
    local mod = cfg("tooltip_hide_on_modifier")
    if mod and mod ~= "" and TRP3_BindingUtil and TRP3_BindingUtil.IsKeyDown(mod) then return false end
    return true
end

local function isUp(owner)
    return shown and shown.drawn and shown.owner == owner and TRP3_CharacterTooltip
        and TRP3_CharacterTooltip:IsShown() and not TRP3_CharacterTooltip.target
end

-- Draw totalRP3's tooltip for guildie `w` on `owner`. True when it did;
-- false: the caller shows its own tooltip instead.
local function show(owner, w, anchor)
    if not (available() and owner and w and w.name) then return false end
    local okA, yes = pcall(allowed)
    if not okA or not yes then return false end
    local id = characterID(w)
    if not id then return false end
    local R = TRP3_API.register
    -- Ask for their profile, as a mouseover would (its own cooldown applies).
    if not w.isSelf and w.online and TRP3_API.r and TRP3_API.r.sendQuery then pcall(TRP3_API.r.sendQuery, id) end
    shown = { owner = owner, who = w, id = id, anchor = anchor }
    if not w.isSelf and not (R.isUnitIDKnown(id) and R.hasProfile(id)) then return false end

    local tt = TRP3_CharacterTooltip
    if GameTooltip:GetOwner() == owner then GameTooltip:Hide() end
    tt:Hide()
    if TRP3_CompanionTooltip then TRP3_CompanionTooltip:Hide() end
    builder = builder or TRP3_API.ui.tooltip.createTooltipBuilder(tt)
    -- No unit: its fade-out watch (target / targetType) leaves this one alone.
    tt.target, tt.targetType, tt.targetMode, tt.isFading = nil, nil, nil, nil
    tt:SetAlpha(1)
    tt:SetOwner(owner, anchor)
    local ok, err = pcall(function()
        tt:SetBorderColor(TRP3_API.ui.tooltip.tooltipBorderColor:GetRGB())
        if cfg("tooltip_char_relation") and not w.isSelf and R.relation and R.relation.getRelationColor then
            local c = R.relation.getRelationColor(R.hasProfile(id))
            if c then tt:SetBorderColor(c:GetRGB()) end
        end
        write(id, w)
    end)
    if not ok then
        tt:Hide()
        if not warned then warned = true; ns.print("totalRP3 tooltip failed: " .. tostring(err)) end
        return false
    end
    shown.drawn = true
    return true
end

-- Roster row `row`, member `m` (club member info).
function RT.Show(row, m)
    if not (row and m) then return false end
    return show(row, fromMember(m), "ANCHOR_RIGHT")
end

-- A map dot's guildie `g` on `owner` (the world map's viewport, the minimap's
-- holder), at the cursor. Already up for them there: left as it is.
function RT.ShowDot(owner, g)
    if not (g and g.key) then return false end
    if isUp(owner) and shown.key == g.key then return true end
    local w = fromDot(g)
    if not w then return false end
    local ok = show(owner, w, "ANCHOR_CURSOR")
    if shown then shown.key = g.key end
    return ok
end

-- `owner` no longer wants it: our tooltip goes (only while it is ours).
function RT.Hide(owner)
    if not shown or (owner and shown.owner ~= owner) then return end
    local drawn = shown.drawn
    shown = nil
    if drawn and TRP3_CharacterTooltip and not TRP3_CharacterTooltip.target then TRP3_CharacterTooltip:Hide() end
end

function RT.IsShown(owner) return isUp(owner) and true or false end

-- totalRP3's hide-on-modifier key, pressed while ours is up: ours goes
-- first. (totalRP3's own handler swaps its tooltip for the game's with
-- GameTooltip:SetUnit(its unit) - ours has none, so that call errors. With
-- ours hidden, it does nothing; a dot's next hover tick shows our plain
-- tooltip, as totalRP3 would. totalRP3 only registers for the key at login
-- (its OnEnable, startModules); this frame registers as the file loads,
-- earlier, so it hears the key first.)
local modWatch = CreateFrame("Frame")
modWatch:RegisterEvent("MODIFIER_STATE_CHANGED")
modWatch:SetScript("OnEvent", function()
    local tt = TRP3_CharacterTooltip
    if not (shown and shown.drawn and tt and tt:IsShown() and not tt.target) then return end
    local ok, yes = pcall(allowed)
    if ok and yes then return end
    shown.drawn = false
    tt:Hide()
end)

-- A profile arrived for the dot `owner` shows in its own tooltip: the next
-- hover tick should try us again.
function RT.Ready(owner)
    return shown and shown.owner == owner and shown.ready and not shown.drawn and true or false
end

-- A profile arrived for the guildie under the cursor: draw it (again). A
-- dot's owner redraws on its own next hover tick, which sees it's ours now.
local function onData(_, unitID)
    local s = shown
    if not (s and s.id == unitID and s.owner and s.owner:IsMouseOver()) then return end
    if s.key then s.ready = true; return end       -- (a dot: its next hover tick takes it from here)
    show(s.owner, s.who, s.anchor)
end

ns.onLogin(function()
    if not available() or not (TRP3_API.RegisterCallback and TRP3_Addon and TRP3_Addon.Events) then return end
    local ev = TRP3_Addon.Events.REGISTER_DATA_UPDATED
    if ev then pcall(TRP3_API.RegisterCallback, TRP3_Addon, ev, ns.guard(onData, "trp data")) end
end, "roster trp")
