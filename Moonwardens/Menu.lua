-- Menu: a "Moonwardens" section at the bottom of the game's right-click menu
-- for a guildie, with Inspect Badges: their name in chat and in the guild
-- roster, and their unit frames - target, focus, party and raid.
-- Menu.ModifyMenu appends to the game's own menu (its tag is MENU_UNIT_ and
-- the menu's kind); nothing of the game's is rebuilt or moved.
local _, ns = ...

local TAGS = {
    "MENU_UNIT_FRIEND",                    -- a name in chat
    "MENU_UNIT_FRIEND_OFFLINE",
    "MENU_UNIT_COMMUNITIES_GUILD_MEMBER",  -- the guild roster
    "MENU_UNIT_COMMUNITIES_WOW_MEMBER",
    "MENU_UNIT_GUILD",                     -- (older guild list)
    "MENU_UNIT_GUILD_OFFLINE",
    -- Unit frames: the game picks the menu by who it is (in my party or
    -- raid, or not) and which frame.
    "MENU_UNIT_PLAYER",                    -- target / focus, not in my group
    "MENU_UNIT_TARGET",
    "MENU_UNIT_FOCUS",
    "MENU_UNIT_PARTY",                     -- party frames, or a party member targeted
    "MENU_UNIT_RAID_PLAYER",               -- a raid member targeted
    "MENU_UNIT_RAID",                      -- raid frames
}

-- The guildie a menu is for: from its unit (a unit frame: the full name,
-- "First Last"), else its name (and server, which on Forever is the last
-- name). Nil for anyone not in the guild, and for me.
local function guildieOf(contextData)
    if type(contextData) ~= "table" or not ns.Roster then return nil end
    local tries = {}
    local unit = contextData.unit
    if type(unit) == "string" then
        if ns.try(UnitIsPlayer, unit) ~= true then return nil end
        tries[#tries + 1] = ns.try(GetUnitName, unit, true)
        local first, last = ns.try(UnitName, unit)
        if type(first) == "string" and type(last) == "string" and last ~= "" then tries[#tries + 1] = first .. " " .. last end
    end
    local name, server = contextData.name, contextData.server
    if type(name) == "string" and ns.readable(name) then
        if type(server) == "string" and ns.readable(server) and server ~= "" then tries[#tries + 1] = name .. " " .. server end
        tries[#tries + 1] = name
    end
    for _, n in ipairs(tries) do
        local key = type(n) == "string" and ns.key(n)
        if key and ns.Roster.Get(key) then
            if key == ns.meKey and type(unit) == "string" then return nil end   -- (my own frame: not a fellow Moonwarden)
            return key
        end
    end
    return nil
end

local function addSection(owner, root, contextData)
    local key = guildieOf(contextData)
    if not key then return end
    root:CreateDivider()
    root:CreateTitle("Moonwardens")
    root:CreateButton("Inspect Badges", function() ns.guard(ns.Badges.View, "view badges")(key) end)
    if ns.Ledger and ns.Ledger.CanAward() and ns.OfficerUI then
        root:CreateButton("Award Badge Progress", function() ns.guard(ns.OfficerUI.Open, "award")(key) end)
    end
end

-- The guild roster's right-click menu for a guildie, opened from our own
-- lists (the Leaderboard): the same menu, with the same details the roster
-- gives it (CommunitiesMemberListMixin:OnClubMemberButtonClicked), so it
-- has the same entries, ours included.
function ns.OpenMemberMenu(key)
    if not (UnitPopup_OpenMenu and C_Club and ns.Roster.ClubMember) then return end
    local info, club = ns.Roster.ClubMember(key)
    if not (info and info.name and club) then return end
    local clubInfo = ns.try(C_Club.GetClubInfo, club)
    if type(clubInfo) ~= "table" then return end
    local P = Enum and Enum.ClubMemberPresence
    UnitPopup_OpenMenu("COMMUNITIES_GUILD_MEMBER", {
        name = info.name,
        clubMemberInfo = info,
        clubInfo = clubInfo,
        clubPrivileges = ns.try(C_Club.GetClubPrivileges, club),
        clubAssignableRoles = info.memberId and ns.try(C_Club.GetAssignableRoles, club, info.memberId),
        isSelf = info.isSelf,
        guid = info.guid,
        isMobile = P and info.presence == P.OnlineMobile or false,
        isGuildMember = true,
    })
end

ns.onLogin(function()
    if not (Menu and Menu.ModifyMenu) then return end
    for _, tag in ipairs(TAGS) do
        pcall(Menu.ModifyMenu, tag, function(owner, root, contextData)
            pcall(addSection, owner, root, contextData)
        end)
    end
end, "menu")
