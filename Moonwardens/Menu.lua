-- Menu: a "Moonwardens" section at the bottom of the game's right-click menu
-- for a guildie's name, in chat and in the guild roster, with View Badges.
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
}

local function guildieOf(contextData)
    if type(contextData) ~= "table" then return nil end
    local name = contextData.name
    if type(name) ~= "string" or not ns.readable(name) then
        local unit = contextData.unit
        if type(unit) == "string" then name = ns.try(GetUnitName, unit, true) end
    end
    local key = ns.key(name)
    if not key or not (ns.Roster and ns.Roster.Get(key)) then return nil end
    return key
end

local function addSection(owner, root, contextData)
    local key = guildieOf(contextData)
    if not key then return end
    root:CreateDivider()
    root:CreateTitle("Moonwardens")
    root:CreateButton("View Badges", function() ns.guard(ns.Badges.View, "view badges")(key) end)
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
