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

ns.onLogin(function()
    if not (Menu and Menu.ModifyMenu) then return end
    for _, tag in ipairs(TAGS) do
        pcall(Menu.ModifyMenu, tag, function(owner, root, contextData)
            pcall(addSection, owner, root, contextData)
        end)
    end
end, "menu")
