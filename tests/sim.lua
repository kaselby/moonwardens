-- Loads the addon from the .toc under the mock and runs checks.
-- Run from repo root: luajit tests/sim.lua
package.path = "./tests/?.lua;" .. package.path
local W = require("wow")
local fails, passes = 0, 0
local function check(cond, what)
    if cond then passes = passes + 1 else fails = fails + 1; print("FAIL: " .. what) end
end

local ns = {}
for line in io.lines("Moonwardens/Moonwardens.toc") do
    if line:match("%.lua$") then
        local chunk = assert(loadfile("Moonwardens/" .. line))
        chunk("Moonwardens", ns)
        -- (layers are off for release, Core.lua; on here, to keep checking
        -- their code: tests/layers_off.lua checks them off)
        if line == "Core.lua" then ns.LAYERS = true end
    end
end
W.fire("ADDON_LOADED", "Moonwardens")
W.fire("PLAYER_LOGIN")
W.fire("GUILD_ROSTER_UPDATE")

-- Names
check(ns.key("Thalanor-Oakheart") == "thalanor oakheart", "key dash form")
check(ns.key("Thalanor Oakheart-ClassicBetaPvP") == "thalanor oakheart", "key with realm")
check(ns.address("Thalanor Oakheart") == "Thalanor-Oakheart", "address")
check(ns.meKey == "sanalune silverwind", "my key")

-- Roster + stats
check(ns.Roster.Count() == 4, "roster count")
check(ns.Roster.IsMember("caelith shade"), "member")
check(not ns.Roster.IsMember("random stranger"), "non-member")
check(ns.Roster.IsOfficer("sanalune silverwind"), "officer rank")
local s = ns.Roster.Stats(false)
check(s.total == 4 and s.online == 3 and s.max == 2, "stats totals")
check(s.race.NightElf and s.race.NightElf.n == 1 and s.unknownRace == 2, "race counts")
W.races["Player-1-04"] = { "High Order Skyborne", "Skyborne" }
ns.Roster.Build()
check(ns.Roster.Stats(false).race.Skyborne.label == "Skyborne", "race name shortened")
check(s.level[7] == 2 and s.level[5] == 1 and s.level[4] == 1, "level bands")
check(ns.Roster.Stats(true).total == 3, "online-only stats")
check(ns.UI.Pct(108, 130) == "83%" and ns.UI.Pct(1, 300) == "<1%" and ns.UI.Pct(0, 5) == "0%" and ns.UI.Pct(1, 0) == "", "percent")

-- Comm: decode, membership, own messages, newer version
local got = {}
ns.Comm.handlers.T = function(f, sender, key) got[#got + 1] = { f = f, key = key } end
W.fire("CHAT_MSG_ADDON", "MWG1", "T|1|hello", "GUILD", "Thalanor-Oakheart")
W.fire("CHAT_MSG_ADDON", "MWG1", "T|1|spoof", "GUILD", "Random-Stranger")
W.fire("CHAT_MSG_ADDON", "MWG1", "T|1|me", "GUILD", "Sanalune-Silverwind")
W.fire("CHAT_MSG_ADDON", "OTHER", "T|1|x", "GUILD", "Thalanor-Oakheart")
check(#got == 1 and got[1].f[3] == "hello" and got[1].key == "thalanor oakheart", "dispatch only guild, not self, right prefix")
W.fire("CHAT_MSG_ADDON", "MWG1", "T|2|future", "GUILD", "Thalanor-Oakheart")
check(#got == 1, "newer protocol ignored")

-- Send queue: spacing and coalescing
for i = 1, 3 do ns.Comm.Send({ "P", 1, i }, "GUILD", nil, "pos") end
ns.Comm.Send({ "X", 1 }, "GUILD")
check(ns.Comm.QueueLength() == 2, "position coalesced")
W.advance(1)
check(#W.sent == 2 and W.sent[1].m == "P|1|3", "queue drained, latest position sent")
check(W.sent[2].at - W.sent[1].at >= 0.25 - 1e-9, "spacing")

-- UI builds and opens. (The pages live on the guild window when it can
-- host them; the mock has none, so here it's our own window, the fallback.)
ns.GuildTabs.Hosting = function() return false end
ns.ToggleWindow()
check(MoonwardensFrame and MoonwardensFrame:IsShown(), "window opens")
-- (The guild's race, class and level stats were the Stats page; they're on
-- the guild window's Info tab now - GuildInfoStats.lua - which the mock
-- doesn't have, so they aren't checked here.)
ns.ToggleWindow(9)
check(MoonwardensFrame.current == 9, "settings page")
W.missingTemplates = { PortraitFrameTemplate = true }
-- The makers' tools (dev): not for me (an officer, not one of them) -
-- hidden from the lists and refused; officers' ones there. Then I'm one.
do
    local from = #W.prints
    SlashCmdList.MOONWARDENS("help")
    SlashCmdList.MOONWARDENS("test")
    local shown = table.concat(W.prints, "\n", from + 1)
    check(not shown:find("/mw debug", 1, true) and not shown:find("/mw comm", 1, true)
        and not shown:find("mapdots", 1, true) and not shown:find("newdots", 1, true) and not shown:find("test fill", 1, true)
        and shown:find("/mw hk", 1, true) and shown:find("test victory", 1, true) and shown:find("test badgepoints", 1, true),
        "the makers' tools hidden from the lists; the rest there:\n" .. shown)
    from = #W.prints
    SlashCmdList.MOONWARDENS("comm")
    check(not W.prints[#W.prints]:find("sent %d") and W.prints[from + 1]:find("commands:", 1, true), "/mw comm refused (just the list)")
    SlashCmdList.MOONWARDENS("test mapdots on")
    check(W.prints[#W.prints] and not W.prints[#W.prints]:find("placed", 1, true), "/mw test mapdots refused")
    check(not ns.IsDev() and ns.IsDev("shandor moonfang") and ns.IsDev("kaelith nightbough"), "the makers: Shandor and Kaelith")
    ns.DEVS[ns.meKey] = true
end
SlashCmdList.MOONWARDENS("comm")
check(W.prints[#W.prints]:find("sent"), "slash comm")
MoonwardensMinimapButton._scripts.OnEnter(MoonwardensMinimapButton)
check(#GameTooltip.lines >= 3, "minimap tooltip")

W.advance(130)
check(W.rosterRequests >= 2, "roster re-requested")


---------------------------------------------------------------------------
-- Phase 2: positions
---------------------------------------------------------------------------
local P = ns.Position
local function lastSent(kind)
    for i = #W.sent, 1, -1 do if W.sent[i].m:sub(1, #kind + 1) == kind .. "|" then return W.sent[i], i end end
end
local function countSent(kind)
    local n = 0
    for _, m in ipairs(W.sent) do if m.m:sub(1, #kind + 1) == kind .. "|" then n = n + 1 end end
    return n
end
W.pos = { 0.52, 0.5 }
W.advance(4)
local m = lastSent("P")
check(m and m.m == "P|1|1440|0.5200|0.5000|0|4|60" and m.ch == "GUILD", "own P sent: " .. tostring(m and m.m))
local before = countSent("P")
W.advance(10)
check(countSent("P") == before, "standing still: no P for 10 s")
W.advance(6)
check(countSent("P") == before + 1, "standing still: P every 15 s")
before = countSent("P")
W.pos = { 0.51, 0.5 }
W.advance(4)
check(countSent("P") == before + 1 and lastSent("P").m:find("0.5100", 1, true), "moved: P within 3 s")
W.combat = true
W.advance(2.5)
check(lastSent("P").m:match("|(%d+)|60$") == "5", "combat flag sent at once")
W.combat = false
W.instance = true
W.advance(2)
check(lastSent("Q") and lastSent("Q").m == "Q|1", "Q in instance")
local qAt = select(2, lastSent("Q"))
W.advance(5)
check(select(2, lastSent("Q")) == qAt and select(2, lastSent("P")) < qAt, "nothing more while in instance")
W.instance = false
W.advance(2)
check(select(2, lastSent("P")) > qAt, "P again after the instance")
W.fire("PLAYER_LEAVING_WORLD")
check(lastSent("Q") and select(2, lastSent("Q")) > qAt, "Q sent at once on loading screen")
W.advance(2)

-- Receiving
local function recv(text, from) W.fire("CHAT_MSG_ADDON", "MWG1", text, "GUILD", from) end
recv("P|1|1440|0.4000|0.6000|0|1|60", "Thalanor-Oakheart")
recv("P|1|1440|0.4500|0.5000|0|0|33", "Caelith-Shade")
recv("P|1|1440|0.3|0.3|0|0|60", "Random-Stranger")
recv("P|1|1440|7|0.3|0|0|60", "Caelith-Shade")
recv("P|1|1440|0.2|0.2|0|0|41", "Velanya-Dawnleaf")   -- offline on the roster
local g = P.Get("thalanor oakheart")
check(g and g.x == 0.4 and g.y == 0.6 and g.level == 60 and P.HasFlag(g, P.FLAG_COMBAT), "P stored")
check(P.Get("caelith shade").x == 0.45, "bad P ignored")
check(P.Get("random stranger") == nil, "stranger's P ignored")
check(P.CountInMyZone() == 2, "count in my zone (offline member dropped): " .. tostring(P.CountInMyZone()))
MoonwardensMinimapButton._scripts.OnEnter(MoonwardensMinimapButton)
check(table.concat(GameTooltip.lines, "\n"):find("2 in your zone", 1, true), "minimap tooltip zone count")
recv("Q|1", "Caelith-Shade")
check(P.Get("caelith shade") == nil, "Q drops the dot")
recv("P|1|1440|0.4500|0.5000|0|0|33", "Caelith-Shade")
W.advance(55)
check(P.CountInMyZone() == 0, "stale dots dropped")

-- Layers seen through positions (a stand-in detector says I'm on 7)
local realLayer = ns.Layer
ns.Layer = { Mine = function() return 7 end }
W.advance(1.5)
recv("P|1|1440|0.4000|0.6000|7|0|60", "Thalanor-Oakheart")
recv("P|1|1440|0.4500|0.5000|3|0|33", "Caelith-Shade")
local list, unknown = P.LayersIn(1440)
check(#list == 2 and list[1].label == "Your layer" and list[1].mine and list[1].n == 2
    and list[2].label == "Another layer" and not list[2].mine and list[2].n == 1 and unknown == 0,
    "layers in zone: yours and another (no agreed numbers yet)")
check(P.Relation(P.Get("thalanor oakheart")) == "same" and P.Relation(P.Get("caelith shade")) == "other", "relation same/other")
recv("P|1|1440|0.4500|0.5000|0|0|33", "Caelith-Shade")
check(P.Relation(P.Get("caelith shade")) == "unknown", "relation unknown")
recv("P|1|1440|0.4500|0.5000|3|0|33", "Caelith-Shade")

-- Conversion between maps
local cx, cy = ns.MapWorld.Convert(1440, 0.5, 0.5, 1414)
check(cx and math.abs(cx - (20000 + 2883.5) / 40000) < 1e-6 and math.abs(cy - (10000 + 1922) / 30000) < 1e-6, "zone to continent")
check(ns.MapWorld.Convert(1440, 0.5, 0.5, 1439) == nil, "off the other zone's map")

---------------------------------------------------------------------------
-- World map
---------------------------------------------------------------------------
WorldMapFrame:Show()
W.advance(0.3)
local dots, used, panel, root = ns.MapWorld.Debug()
check(used == 2, "two dots on the world map: " .. tostring(used))
local tdot
for i = 1, used do if dots[i].g.key == "thalanor oakheart" then tdot = dots[i] end end
check(tdot and tdot._point[2] == root and tdot._point[3] == "TOPLEFT"
    and math.abs(tdot._point[4] - 400) < 1e-6 and math.abs(tdot._point[5] + 0.6 * 667) < 1e-6, "dot placed on the canvas")
check(tdot.rel == "same" and tdot:GetAlpha() == 0.8, "same layer dot: slightly faint (0.8)")
check(panel and panel:IsShown() and panel.head:GetText() == "Layers in Ashenvale", "side panel heading")
check(panel.cards[1] and panel.cards[1].name:GetText() == "Your layer" and panel.cards[1].count:GetText() == "2 guildies"
    and panel.cards[2] and panel.cards[2].name:GetText() == "Another layer" and panel.cards[2].count:GetText() == "1 guildie",
    "layer cards")
-- Hovering a layer card lists who is on it
if panel.cards[1] then
    panel.cards[1]._scripts.OnEnter(panel.cards[1])
    local ctip = table.concat(GameTooltip.lines, "\n")
    check(ctip:find("Your layer", 1, true) and ctip:find("Thalanor Oakheart  level 60", 1, true)
        and ctip:find("Sanalune Silverwind  you", 1, true) and not ctip:find("Caelith", 1, true), "layer card tooltip: " .. ctip)
    panel.cards[1]._scripts.OnLeave(panel.cards[1])
end

-- Hover
GameTooltip:Hide() -- (nobody else's tooltip up: ours steps back for those)
W.cursor = { tdot._cx + 3, tdot._cy - 2 }
W.advance(0.1)
local tip = table.concat(GameTooltip.lines, "\n")
check(GameTooltip:GetOwner() ~= nil and tip:find("Thalanor Oakheart", 1, true) and tip:find("Your layer", 1, true)
    and tip:find("<Moonwardens> Sentinel", 1, true), "hover tooltip")
W.cursor = { 0, 0 }
W.advance(0.1)

-- Other layer hidden by the checkbox
ns.db.otherLayers = false
W.advance(0.3)
dots, used = ns.MapWorld.Debug()
check(used == 1 and dots[1].g.key == "thalanor oakheart", "other layer hidden")
ns.db.otherLayers = true

-- Continent view: converted, panel says how many
W.shownMap = 1414
W.advance(0.3)
dots, used, panel = ns.MapWorld.Debug()
check(used == 2 and panel.empty:GetText():find("2 guildies on this map", 1, true), "continent view")
W.shownMap = 1440

-- Kill switch
SlashCmdList.MOONWARDENS("map off")
dots, used = ns.MapWorld.Debug()
check(ns.db.mapKill and used == 0 and not panel:IsShown(), "map off hides everything")
WorldMapFrame:Hide(); WorldMapFrame:Show()
W.advance(0.3)
dots, used = ns.MapWorld.Debug()
check(used == 0 and not panel:IsShown(), "map stays off on reopen")
SlashCmdList.MOONWARDENS("map on")
WorldMapFrame:Hide(); WorldMapFrame:Show()
W.advance(0.3)
dots, used = ns.MapWorld.Debug()
check(used == 2 and panel:IsShown(), "map on again")
WorldMapFrame:Hide()
W.advance(0.1)

---------------------------------------------------------------------------
-- Minimap (width 100 -> 50 px radius = 233.33 yd)
---------------------------------------------------------------------------
W.pos = { 0.5, 0.5 }
local ppy = 50 / 233.33
local ex, ey = ns.MapMini.Offset(0.5 + 10 / 5767, 0.5, 0.5, 0.5, 5767, 3844, ppy)
check(math.abs(ex - 10 * ppy) < 1e-6 and math.abs(ey) < 1e-9, "10 yd east")
local nx, ny = ns.MapMini.Offset(0.5, 0.5 - 20 / 3844, 0.5, 0.5, 5767, 3844, ppy)
check(math.abs(ny - 20 * ppy) < 1e-6 and math.abs(nx) < 1e-9, "20 yd north is up")
local rx, ry = ns.MapMini.Offset(0.5 + 10 / 5767, 0.5, 0.5, 0.5, 5767, 3844, ppy, math.pi / 2)
check(math.abs(rx) < 1e-6 and math.abs(ry - 10 * ppy) < 1e-6, "rotation by facing")
recv("P|1|1440|" .. ("%.4f"):format(0.5 + 30 / 5767) .. "|0.5000|7|0|60", "Thalanor-Oakheart")
recv("P|1|1440|0.9000|0.5000|3|0|33", "Caelith-Shade")   -- far away
W.advance(0.2)
local md, mused = ns.MapMini.Debug()
check(mused == 1 and md[1].g.key == "thalanor oakheart" and math.abs(md[1]._point[4] - 30 * ppy) < 0.3, "minimap: near dot placed, far one hidden")
-- Minimap hover (polling, 0.5.5): nothing of the game's under the cursor,
-- so we show GameTooltip ourselves with the guildie under it
GameTooltip:Hide(); GameTooltip.lines = {}
W.cursor = { md[1]._cx + 2, md[1]._cy }
W.advance(0.1)
local mtip = table.concat(GameTooltip.lines, "\n")
check(GameTooltip:IsShown() and GameTooltip:GetOwner() ~= UIParent and mtip:find("Thalanor Oakheart", 1, true), "minimap hover: name in our tooltip: " .. mtip)
W.cursor = { 0, 0 }
W.advance(0.1)
check(not GameTooltip:IsShown(), "minimap hover: nothing under the cursor, tooltip gone")
ns.db.minimapDots = false
W.advance(0.2)
check(select(2, ns.MapMini.Debug()) == 0, "minimap dots setting")
ns.db.minimapDots = true
ns.Layer = realLayer
-- Guildies in my group: the game draws them, so our dots hide (guildie fix, 11-10)
W.group = { "Thalanor Oakheart" }
W.fire("GROUP_ROSTER_UPDATE")
W.advance(0.3)
check(select(2, ns.MapMini.Debug()) == 0, "minimap: grouped guildie not drawn twice")
WorldMapFrame:Show(); W.advance(0.3)
local gd, gused = ns.MapWorld.Debug()
local hasT = false
for i = 1, gused do if gd[i].g.key == "thalanor oakheart" then hasT = true end end
check(not hasT, "world map: grouped guildie not drawn twice")
-- ...and a gold ring goes around the game's own dot for them, on both maps
W.unitPos = { party1 = { 0.5 + 30 / 5767, 0.5 } }
W.advance(0.3)
local _, _, _, mh = ns.MapMini.Debug()
check(not (mh[1] and mh[1]:IsShown()), "minimap: no ring on the party member (off since 0.5.4)")
local wh = ns.MapWorld.Halos()
check(not (wh[1] and wh[1]:IsShown()), "world map: no ring on the party member (off since 0.5.4)")
check(gd[1] and gd[1].fill:GetTexture():find("diamond", 1, true), "guildie dots are diamonds")
W.group = {}
W.fire("GROUP_ROSTER_UPDATE")
W.advance(0.3)
gd, gused = ns.MapWorld.Debug()
hasT = false
for i = 1, gused do if gd[i].g.key == "thalanor oakheart" then hasT = true end end
check(hasT and select(2, ns.MapMini.Debug()) == 1, "dots come back after leaving the group")
W.unitPos = nil
WorldMapFrame:Hide(); W.advance(0.1)
SlashCmdList.MOONWARDENS("test mapdots on")
check(W.prints[#W.prints]:find("2 guildies placed", 1, true) and P.CountInMyZone() == 2, "/mw test mapdots on")
W.advance(70)
check(P.CountInMyZone() == 2, "test dots stay until turned off")
SlashCmdList.MOONWARDENS("test mapdots off")
check(P.CountInMyZone() == 0 and W.prints[#W.prints]:find("test dots off", 1, true), "/mw test mapdots off")

---------------------------------------------------------------------------
-- Phase 3: layer detector
---------------------------------------------------------------------------
local Lr = ns.Layer
local function npc(server, spawn) return ("Creature-0-%d-1-2-3346-%s"):format(server, spawn) end
local layerEvents = {}
ns.listen("LAYER", function(map, from, to) layerEvents[#layerEvents + 1] = { map, from, to } end)
W.fire("PLAYER_ENTERING_WORLD")
W.advance(4)   -- (past the first 3 s after a loading screen)
check(Lr.Mine(1440) == 0, "unknown at start")
W.units.mouseover = { guid = "Pet-0-7052-1-2-1234-B1", pc = true }
W.fire("UPDATE_MOUSEOVER_UNIT")
W.units.mouseover = { guid = npc(7052, "B2"), pc = true }    -- a player's guardian
W.fire("UPDATE_MOUSEOVER_UNIT")
W.units.mouseover = { guid = "Player-0-7052-0001" }
W.fire("UPDATE_MOUSEOVER_UNIT")
check(Lr.Mine(1440) == 0, "pets, guardians and players ignored")
W.units.mouseover = nil
-- One creature: a provisional layer; a second agreeing one confirms it.
W.units.target = { guid = npc(7075, "A1") }
W.fire("PLAYER_TARGET_CHANGED")
check(Lr.Mine(1440) == 7075 and Lr.State().single and layerEvents[#layerEvents][3] == 7075, "one creature gives a provisional layer")
W.fire("PLAYER_TARGET_CHANGED")
check(Lr.State().single, "the same creature twice doesn't confirm it")
W.units.mouseover = { guid = npc(7075, "A2") }
W.fire("UPDATE_MOUSEOVER_UNIT")
check(Lr.Mine(1440) == 7075 and not Lr.State().single, "a second creature confirms it")
check(Lr.Mine(1439) == 0, "layer is per zone")
W.advance(1.5)
check(lastSent("P").m:match("^P|1|1440|[%d.]+|[%d.]+|7075|"), "P carries the layer: " .. lastSent("P").m)
-- A confirmed layer: another number needs 3 of the last 5 creatures.
W.units.n1 = { guid = npc(7062, "C1") }
W.plates = { "n1" }
W.advance(2.1)
check(Lr.Mine(1440) == 7075, "one creature with a new number doesn't switch")
W.fire("NAME_PLATE_UNIT_ADDED", "n1")
check(Lr.Mine(1440) == 7075, "the same creature again doesn't count twice")
W.units.target = { guid = npc(7062, "C2") }
W.fire("PLAYER_TARGET_CHANGED")
check(Lr.Mine(1440) == 7075, "two don't switch a confirmed layer")
W.units.mouseover = { guid = npc(7062, "C3") }
W.fire("UPDATE_MOUSEOVER_UNIT")
check(Lr.Mine(1440) == 7062, "three of the last five switch it")
W.plates = {}
-- Tooltip: a guildie here on my layer
recv("P|1|1440|0.4000|0.6000|7062|0|60", "Thalanor-Oakheart")
MoonwardensMinimapButton._scripts.OnEnter(MoonwardensMinimapButton)
check(table.concat(GameTooltip.lines, "\n"):find("On your layer here: 1 guildie", 1, true), "minimap tooltip layer line: " .. table.concat(GameTooltip.lines, " / "))
-- A zone border forgets it; one creature isn't believed just after one.
-- (Not in the first 10 s after a login: that's the login's own zone.)
W.advance(10)
W.fire("ZONE_CHANGED_NEW_AREA")
check(Lr.Mine(1440) == 0, "forgotten at a zone border")
W.units.target = { guid = npc(7075, "A4") }; W.fire("PLAYER_TARGET_CHANGED")
check(Lr.Mine(1440) == 0, "one creature isn't believed just after a border")
W.units.mouseover = { guid = npc(7075, "A5") }; W.fire("UPDATE_MOUSEOVER_UNIT")
check(Lr.Mine(1440) == 7075, "two agreeing creatures are")
W.advance(16)
-- A layer move: kept, and rechecked: a creature right after it doesn't
-- decide; once the move has settled (3 s), one new creature does.
W.fire("SHARD_TRANSFER")
check(Lr.Mine(1440) == 7075, "kept through a layer move (rechecking)")
W.advance(1)
W.units.target = { guid = npc(7062, "B1") }; W.fire("PLAYER_TARGET_CHANGED")
check(Lr.Mine(1440) == 7075, "a creature just after a move doesn't decide yet")
W.advance(3)
W.fire("PLAYER_TARGET_CHANGED")
check(Lr.Mine(1440) == 7062, "once the move has settled, it decides")
W.fire("SHARD_TRANSFER")
W.advance(4)
W.units.target = { guid = npc(7075, "A6") }; W.fire("PLAYER_TARGET_CHANGED")
check(Lr.Mine(1440) == 7075, "and back again")
-- (provisional now, on one creature: it takes two of another number to correct)
W.units.target = { guid = npc(7062, "B3") }; W.fire("PLAYER_TARGET_CHANGED")
check(Lr.Mine(1440) == 7075, "outside a recheck one creature doesn't switch")
W.units.mouseover = { guid = npc(7062, "B4") }; W.fire("UPDATE_MOUSEOVER_UNIT")
check(Lr.Mine(1440) == 7062, "two of another number correct a provisional layer")
W.advance(601)
check(Lr.Mine(1440) == 0, "forgotten after 10 min")
W.units = {}
local printed = #W.prints
SlashCmdList.MOONWARDENS("layer")
check(table.concat(W.prints, "\n", printed + 1):find("isn't known yet", 1, true), "/mw layer")
-- Seeing a guildie: they're on my layer (seeing them proves it).
recv("P|1|1440|0.5010|0.5000|0|0|60", "Thalanor-Oakheart")
W.units.target = { guid = "Player-0-7062-0002", name = "Thalanor Oakheart" }
W.fire("PLAYER_TARGET_CHANGED")
local tg = ns.Position.All()["thalanor oakheart"]
check(ns.Position.Relation(tg) == "same", "unknown guildie I can see is on my layer")
local ll, lunk = ns.Position.LayersIn(1440)
local onMine = false
for _, e in ipairs(ll) do if e.mine then for _, k in ipairs(e.keys) do if k == "thalanor oakheart" then onMine = true end end end end
check(onMine and lunk == 0, "layer list puts them on my layer, not 'not known'")
W.advance(40)   -- still targeted: the held target keeps counting
check(ns.Position.Relation(tg) == "same", "held target still counts as seen")
W.units = {}
W.advance(40)
check(ns.Position.Relation(tg) == "unknown", "out of sight for 30 s: unknown again")

---------------------------------------------------------------------------
-- Phase 4: alerts
---------------------------------------------------------------------------
local A = ns.Alert
W.pos = { 0.5, 0.5 }
W.advance(1)
local function sentWhere(kind) local m = lastSent(kind); return m end
-- Sending
A.Send()
W.advance(0.5)
local am = sentWhere("A")
check(am and am.ch == "GUILD" and am.m:match("^A|1|%d+|1440|0%.5000|0%.5000|%d+|help$"), "A sent: " .. tostring(am and am.m))
local aid = am.m:match("^A|1|(%d+)|")
check(A.Active() and MoonwardensAlertButton.border:IsShown(), "button glows while active")
check(MoonwardensAlertList:IsShown(), "responder list open")
-- A responder
W.fire("CHAT_MSG_ADDON", "MWG1", "R|1|" .. aid .. "|1440|0.5050|0.5000", "WHISPER", "Thalanor-Oakheart")
check(A.Active().order[1] and A.Active().order[1].key == "thalanor oakheart" and A.Active().order[1].dist == 29, "responder listed with distance")
check(W.invites[#W.invites] == "Thalanor-Oakheart", "auto-invite")
W.fire("CHAT_MSG_ADDON", "MWG1", "R|1|999999|1440|0.5|0.5", "WHISPER", "Caelith-Shade")
check(#A.Active().order == 1, "R for another alert id ignored")
-- Full party: convert to raid, then invite
W.group = { "Thalanor Oakheart", "A B", "C D", "E F" }
W.fire("CHAT_MSG_ADDON", "MWG1", "R|1|" .. aid .. "|1440|0.5|0.5", "WHISPER", "Caelith-Shade")
check(W.converted == 1 and W.invites[#W.invites] == "Caelith-Shade", "converted to raid at 5, then invited")
local nInv = #W.invites
A.InviteAll()
check(#W.invites == nInv + 1 and W.invites[#W.invites] == "Caelith-Shade", "invite all skips people in the group")
W.group, W.raid = {}, false
-- Ping again keeps the id
local nA = countSent("A")
A.Send()
W.advance(0.5)
check(countSent("A") == nA + 1 and sentWhere("A").m:match("^A|1|(%d+)|") == aid, "ping again, same id")
-- Expiry ends it
W.advance(121)
check(not A.Active() and sentWhere("E") and sentWhere("E").m == "E|1|" .. aid, "expires after 2 min with E")
check(not MoonwardensAlertList:IsShown(), "list closes")

-- Receiving
W.sounds = {}
local function alertFrom(name, id, x, y, layer)
    W.fire("CHAT_MSG_ADDON", "MWG1", ("A|1|%s|1440|%.4f|%.4f|%d|help"):format(id, x, y, layer or 0), "GUILD", name)
end
alertFrom("Thalanor-Oakheart", "111", 0.5, 0.5 + 240 / 3844)
local c = A.Current()
check(c and c.name == "Thalanor Oakheart" and math.abs(c.dist - 240) < 1 and c.dir == "south", "alert received: distance, direction")
check(#W.sounds == 1, "chime")
check(W.prints[#W.prints]:find("Thalanor Oakheart needs help", 1, true) and W.prints[#W.prints]:find("240 yd S", 1, true), "chat line: " .. W.prints[#W.prints])
check(MoonwardensAlertBanner:IsShown() and MoonwardensAlertBanner.title:GetText():find("needs help", 1, true), "banner shown")
W.advance(0.2)
check(MoonwardensAlertBanner.sub:GetText():find("Ashenvale - 240 yards south", 1, true), "banner subtitle: " .. tostring(MoonwardensAlertBanner.sub:GetText()))
local _, _, pip = ns.MapMini.Debug()
check(pip:IsShown() and pip._point and math.abs(pip._point[5] + (50 - 6)) < 0.5, "minimap pip on the edge, toward the sender (south)")
-- Spam guard: a new alert from the same sender within 30 s is ignored
alertFrom("Thalanor-Oakheart", "112", 0.5, 0.5)
check(A.Current().id == "111", "spam guard")
-- Out of range / other zone
alertFrom("Caelith-Shade", "200", 0.99, 0.99)
check(A.Current().key == "thalanor oakheart", "far alert ignored")
W.fire("CHAT_MSG_ADDON", "MWG1", "A|1|201|1439|0.5|0.5|0|help", "GUILD", "Caelith-Shade")
check(A.Current().key == "thalanor oakheart", "other zone ignored")
-- Respond
ns.db.autoAccept = true
A.Respond()
W.advance(0.5)
local rm = sentWhere("R")
check(rm and rm.ch == "WHISPER" and rm.to == "Thalanor-Oakheart" and rm.m:match("^R|1|111|1440|"), "R whispered to the sender")
check(MoonwardensAlertBanner.respond:GetText() == "Responded", "button says Responded")
W.fire("PARTY_INVITE_REQUEST", "Caelith-Shade")
check(W.accepted == 0, "no auto-accept from someone else")
W.fire("PARTY_INVITE_REQUEST", "Thalanor-Oakheart")
check(W.accepted == 1 and W.popupsHidden[1] == "PARTY_INVITE", "auto-accept from the sender")
ns.db.autoAccept = false
-- Banner goes 3 s after answering; a ping again doesn't bring it back; E clears the pip
check(MoonwardensAlertBanner:IsShown(), "banner still up just after answering")
W.advance(3)
check(not MoonwardensAlertBanner:IsShown(), "banner gone 3 s after answering")
alertFrom("Thalanor-Oakheart", "111", 0.5, 0.5 + 240 / 3844)
check(not MoonwardensAlertBanner:IsShown() and A.Current().responded, "ping again after answering: no banner")
check(A.Current() ~= nil, "alert still open after the banner")
W.fire("CHAT_MSG_ADDON", "MWG1", "E|1|111", "GUILD", "Thalanor-Oakheart")
W.advance(0.1)
check(A.Current() == nil and not pip:IsShown(), "E ends it, pip gone")
-- Unanswered: the banner fades after 15 s
W.advance(31)
alertFrom("Thalanor-Oakheart", "113", 0.5, 0.5)
W.advance(14)
check(MoonwardensAlertBanner:IsShown(), "unanswered banner up at 14 s")
W.advance(1.1)
check(not MoonwardensAlertBanner:IsShown(), "unanswered banner gone after 15 s")
W.fire("CHAT_MSG_ADDON", "MWG1", "E|1|113", "GUILD", "Thalanor-Oakheart")
-- Direction helper
check(A.Direction(1, 0) == "east" and A.Direction(0, -1) == "north" and A.Direction(-1, 1) == "southwest", "compass")
check(io.open("Moonwardens/Bindings.xml"):read("*a"):find("Moonwardens.Alert.Respond()", 1, true), "keybinds file")

---------------------------------------------------------------------------
-- Phase 5: leaderboard
---------------------------------------------------------------------------
local LB = ns.Leaderboard
local WEEK = 604800
-- Week id: fallback (Tuesday 15:00 UTC), and the client API agreeing with it
local nr = LB.NextReset()
local left = nr - GetServerTime()
check(left > 0 and left <= WEEK and (nr - 1704207600) % WEEK == 0, "fallback reset on the Tuesday grid")
check(os.date("!%A %H:%M", nr) == "Tuesday 15:00", "reset is Tuesday 15:00 UTC: " .. os.date("!%A %H:%M", nr))
local wk = LB.Week()
W.untilReset = left + 3 * 3600   -- a region resetting 3 h later
check(LB.Week() == wk and LB.NextReset() == nr + 3 * 3600, "client reset API used, same week id")
W.untilReset = nil
-- Login HQ went out, and the retry (nobody answered)
local hq1, hq2 = false, false
for _, m in ipairs(W.sent) do
    if m.m == "HQ|1|" .. wk .. "|1" then hq1 = m.ch == "GUILD" end
    if m.m == "HQ|1|" .. wk .. "|2" then hq2 = true end
end
check(hq1 and hq2, "HQ on login, retry when no HS")
-- Counting
W.map, W.instance = 1440, false
W.hk = 30
W.advance(6)
check(LB.Mine() == 0, "kills from before login not counted")
W.hk = 31
W.fire("PLAYER_PVP_KILLS_CHANGED"); W.fire("PLAYER_PVP_KILLS_CHANGED")
check(LB.Mine() == 1, "one kill, event fired twice: counted once")
W.map = 1439; W.hk = 32; W.advance(6)
check(LB.Mine() == 1, "kill in Darkshore not counted")
W.map, W.subzone = 1442, "Sun Rock Retreat"; W.hk = 33; W.advance(6)
check(LB.Mine() == 1, "kill elsewhere in Stonetalon not counted")
W.subzone = "Stonetalon Peak"; W.hk = 34; W.advance(6)
check(LB.Mine() == 2, "kill at Stonetalon Peak counted")
W.subzone = ""; W.map = 1440; W.hk = 35; W.advance(6)
check(LB.Mine() == 3, "back in Ashenvale")
W.map = 1440; W.hk = 0; W.advance(6); W.hk = 2; W.fire("PLAYER_PVP_KILLS_CHANGED")
check(LB.Mine() == 5, "counter reset (new day) handled")
W.instance = true; W.hk = 3; W.advance(6); W.instance = false
check(LB.Mine() == 5, "kill in an instance (Warsong) not counted")
W.map = 2482
check(LB.Counts(), "Mount Hyjal counts (map 2482)")
W.map = 1440
local nH = countSent("H")
W.advance(31)
check(countSent("H") == nH + 1 and lastSent("H").m == "H|1|" .. wk .. "|5", "one debounced H: " .. tostring(lastSent("H") and lastSent("H").m))
W.hk = 4; W.fire("PLAYER_PVP_KILLS_CHANGED"); W.advance(5)
W.hk = 5; W.fire("PLAYER_PVP_KILLS_CHANGED"); W.advance(5)
check(countSent("H") == nH + 1, "no second H within 30 s")
W.advance(25)
check(countSent("H") == nH + 2 and lastSent("H").m == "H|1|" .. wk .. "|7", "then one H with the latest count")
-- Receiving H
recv("H|1|" .. wk .. "|50", "Thalanor-Oakheart")
recv("H|1|" .. wk .. "|40", "Thalanor-Oakheart")
recv("H|1|" .. wk .. "|99", "Random-Stranger")
recv("H|1|" .. (wk + 5) .. "|77", "Caelith-Shade")
local rows = LB.Rows(wk)
check(#rows == 2 and rows[1].name == "Thalanor Oakheart" and rows[1].c == 50 and rows[1].level == 60
    and rows[2].key == "sanalune silverwind", "H stored as max, stranger and far week ignored")
-- Sync: Caelith (online, just heard) is lowest, so she answers attempt 1; I answer attempt 2
recv("H|1|" .. wk .. "|5", "Caelith-Shade")
check(LB.Repliers("thalanor oakheart")[1] == "caelith shade", "elected replier: lowest recent name")
local nHS = countSent("HS")
recv("HQ|1|" .. wk .. "|1", "Thalanor-Oakheart")
W.advance(1)
check(countSent("HS") == nHS, "not elected: no reply")
recv("HQ|1|" .. wk .. "|2", "Thalanor-Oakheart")
W.advance(1)
local hs = lastSent("HS")
check(hs and hs.ch == "WHISPER" and hs.to == "Thalanor-Oakheart" and hs.m:find("Thalanor-Oakheart:50", 1, true)
    and hs.m:find("Sanalune-Silverwind:7", 1, true) and hs.m:find("Caelith-Shade:5", 1, true), "HS reply: " .. tostring(hs and hs.m))
W.fire("CHAT_MSG_ADDON", "MWG1", "HS|1|" .. wk .. "|Velanya-Dawnleaf:12,Sanalune-Silverwind:999,Random-Stranger:7,bad", "WHISPER", "Caelith-Shade")
rows = LB.Rows(wk)
check(#rows == 4 and LB.Mine() == 7, "HS merged; my own count not overwritten; stranger not shown")
-- Chunks stay under 255 bytes and carry everyone
local big = {}
for i = 1, 40 do big["member" .. i .. " longsurname"] = { n = ("Member%d Longsurname"):format(i), c = i } end
ns.db.board[wk - 1] = big
local chunks, total = LB.Chunks(wk - 1), 0
local okLen = true
for _, c in ipairs(chunks) do
    total = total + #c
    if #table.concat({ "HS", 1, wk - 1, table.concat(c, ",") }, "|") > 254 then okLen = false end
end
check(#chunks >= 4 and total == 40 and okLen, "chunks: " .. #chunks .. " messages, " .. total .. " entries")
-- Any kill, not just honorable: PARTY_KILL, matched against the HK counter
local base = LB.Mine()
local function pk(victim) W.fire("PARTY_KILL", "Player-1-0001", victim) end
pk("Player-9-00AA")                     -- a grey-level Horde: no HK
W.advance(11)
check(LB.Mine() == base + 1, "kill with no honour counted")
pk("Player-9-00AB"); W.advance(1); W.hk = W.hk + 1; W.fire("PLAYER_PVP_KILLS_CHANGED")
check(LB.Mine() == base + 2, "honorable kill seen twice (party kill, then HK) counted once")
W.advance(11)
W.hk = W.hk + 1; W.fire("PLAYER_PVP_KILLS_CHANGED"); W.advance(1); pk("Player-9-00AC")
check(LB.Mine() == base + 3, "HK first, then party kill: counted once")
W.advance(11)
pk("Creature-0-7075-1-2-3346-A1")
W.map = 1439; pk("Player-9-00AD"); W.map = 1440
check(LB.Mine() == base + 3, "NPCs and other zones not counted")
W.hk = W.hk + 1; W.fire("PLAYER_PVP_KILLS_CHANGED")
check(LB.Mine() == base + 4, "HK alone still counts (party kill secret or missed)")
W.advance(11)
for k, e in pairs(ns.db.board[wk]) do if k == ns.meKey then e.c = 5 end end   -- back to the numbers below
-- Page
ns.db.board[wk - 1] = { ["thalanor oakheart"] = { n = "Thalanor Oakheart", c = 241 } }
ns.db.board[wk - 6] = { x = { n = "X", c = 1 } }
ns.ToggleWindow(5)
local pg = LB.page
check(MoonwardensFrame.current == 5 and pg and pg:IsShown(), "leaderboard page opens")
check(ns.db.board[wk - 6] == nil, "old weeks pruned")
check(pg.rows[1].name:GetText() == "Thalanor Oakheart" and pg.rows[1].n:GetText() == 50
    and pg.rows[1].class:GetText() == "60 Warrior", "row 1")
local mine
for _, r in ipairs(pg.rows) do if r:IsShown() and r.name:GetText():find("(you)", 1, true) then mine = r end end
check(mine and mine.hl:IsShown(), "my row highlighted")
check(pg.total:GetText() == "Guild Total |cffffd100" .. (50 + 12 + 5 + 5) .. "|r" and pg.sub:GetText():find("Mount Hyjal", 1, true)
    and pg.reset:GetText():find("^Resets Tuesday  %-  .+ left$"), "heading: " .. pg.sub:GetText() .. " / " .. pg.reset:GetText() .. " / " .. pg.total:GetText())
check(pg.foot:GetText():find("Thalanor Oakheart|r (241)", 1, true), "last week's winner in the footer: " .. pg.foot:GetText())
pg.tabs[2]._scripts.OnClick(pg.tabs[2])
check(pg.sub:GetText():find("Final standings", 1, true) and pg.reset:GetText() == "" and pg.total:GetText():find("^Guild Total ")
    and pg.rows[1].n:GetText() == 241 and not pg.rows[2]:IsShown(), "last week view")
pg.tabs[1]._scripts.OnClick(pg.tabs[1])
SlashCmdList.MOONWARDENS("hk")
check(W.prints[#W.prints]:find("5 Horde kills", 1, true), "/mw hk")
ns.ToggleWindow()

---------------------------------------------------------------------------
-- 0.6.0-test's Sunday weeks carried back into Tuesday weeks; the kill log
---------------------------------------------------------------------------
do
    local LBo = ns.Leaderboard
    local cw = LBo.Week()
    -- The Sunday week that starts 2 days before this Tuesday week
    local sunWeek = math.floor((1704207600 + cw * 604800 - 2 * 86400 - 1704639600) / 604800 + 0.5)
    check(1704639600 + sunWeek * 604800 + 2 * 86400 == 1704207600 + cw * 604800, "Sunday week id found")
    local myBefore = LBo.Mine()
    ns.db.weeks = { [sunWeek] = { ["sanalune silverwind"] = { n = "Sanalune Silverwind", c = myBefore + 90, cls = "DRUID" },
                                  ["velanya dawnleaf"] = { n = "Velanya Dawnleaf", c = 3, cls = "PRIEST" } } }
    LBo.CarryBack()
    check(LBo.Mine() == myBefore + 90 and ns.db.board[cw]["velanya dawnleaf"].c >= 3, "Sunday counts carried back to this Tuesday week")
    check(ns.db.weeks == nil, "carried back once")

    -- Kill log: every kill, wherever it happened, with its time
    local log = LBo.Log()
    local n0 = #log
    W.advance(11)
    W.map, W.subzone = 1439, ""
    W.hk = (W.hk or 0) + 1; W.fire("PLAYER_PVP_KILLS_CHANGED")
    local e = log[#log]
    check(#log == n0 + 1 and e.m == 1439 and e.z == "Darkshore" and e.s == "h" and not e.k and e.t == GetServerTime(),
        "kill in Darkshore logged (not counted), with its time")
    W.map = 1440
    local mineNow = LBo.Mine()
    W.advance(11)
    LBo.PartyKill("Player-1-01", "Player-0-7062-ABCD")
    W.hk = W.hk + 1; W.fire("PLAYER_PVP_KILLS_CHANGED")
    e = log[#log]
    check(#log == n0 + 2 and e.s == "ph" and e.k == 1 and e.g == "Player-0-7062-ABCD" and LBo.Mine() == mineNow + 1,
        "party kill + honour counter: one entry, both sources, counted once")
    W.advance(11)
    W.hk = W.hk + 1; W.fire("PLAYER_PVP_KILLS_CHANGED")
    LBo.PartyKill("Player-1-02", "Player-0-7062-EF01")
    e = log[#log]
    check(#log == n0 + 3 and e.s == "ph" and e.g == "Player-0-7062-EF01", "twin the other way round fills in the victim")
    W.advance(11)
    check(ns.db.kills[ns.meKey] == log, "log saved per character")
    SlashCmdList.MOONWARDENS("kills")
    check(W.prints[#W.prints]:find("Ashenvale", 1, true) and table.concat(W.prints, "\n", #W.prints - 5):find("kills logged", 1, true), "/mw kills: " .. W.prints[#W.prints])
end

---------------------------------------------------------------------------
-- Update reminder (V messages)
---------------------------------------------------------------------------
local Ver = ns.Comm.Version
check(Ver.Newer("0.6.0", "0.6.0-test") and not Ver.Newer("0.6.0-test", "0.6.0"), "a release is newer than its test build")
check(Ver.Newer("0.10.0", "0.9.9") and Ver.Newer("0.6.1-test", "0.6.0") and not Ver.Newer("0.6.0", "0.6.0"), "version order")
check(countSent("V") >= 1 and lastSent("V").m == "V|1|" .. ns.VERSION, "my version said after login")
local before = #W.prints
recv("V|1|0.8.0", "Thalanor-Oakheart")
check(#W.prints == before and Ver.Newest() == nil, "one non-officer saying 0.8.0 is not enough")
recv("V|1|9.9.9-test", "Caelith-Shade"); recv("V|1|9.9.9-test", "Thalanor-Oakheart")
check(Ver.Newest() == nil, "test builds never prompt an update")
recv("V|1|0.8.0", "Caelith-Shade")
check(Ver.Newest() == "0.8.0" and W.prints[#W.prints]:find("0.8.0 is out", 1, true), "two guildies: update reminder")
recv("V|1|0.8.1", "Thalanor-Oakheart"); recv("V|1|0.8.1", "Caelith-Shade")
check(#W.prints == before + 1 and Ver.Newest() == "0.8.1", "said once per session; tooltip follows the newest")
local mt = { lines = {}, AddLine = function(self, l) self.lines[#self.lines + 1] = l end }
ns.UI.MinimapTooltip(mt)
check(table.concat(mt.lines, "\n"):find("Update available: 0.8.1", 1, true), "minimap tooltip shows the update")
-- Someone behind me logs in: I answer once (unless someone else does)
W.advance(301)
local nV = countSent("V")
recv("V|1|0.5.4", "Caelith-Shade")
W.advance(31)
check(countSent("V") == nV + 1, "answered a guildie on an old version")
recv("V|1|0.5.4", "Thalanor-Oakheart"); W.advance(31)
check(countSent("V") == nV + 1, "not again within 5 minutes")
W.advance(301)
recv("V|1|0.5.4", "Caelith-Shade"); W.advance(2)
recv("V|1|" .. ns.VERSION, "Thalanor-Oakheart"); W.advance(31)
check(countSent("V") == nV + 1, "someone else answered first: I stay quiet")

check(not W.events["COMBAT_LOG_EVENT_UNFILTERED"], "combat log never registered (forbidden on 12.x)")

---------------------------------------------------------------------------
-- Badge Management (Officers): a window of its own, not a tab
---------------------------------------------------------------------------
check(not ns.UI.pages[6], "no Officers tab any more")
ns.OfficerUI.Toggle()
check(MoonwardensBadgeManagement and MoonwardensBadgeManagement:IsShown(), "Badge Management opens (I'm an officer)")
ns.OfficerUI.Toggle()
check(not MoonwardensBadgeManagement:IsShown(), "and closes")
ns.OfficerUI.Open("thalanor oakheart")
check(MoonwardensBadgeManagement:IsShown(), "Award Badge Progress opens it too")
-- Its Guildie field is the Badge Inspector's (ns.GuildiePicker): the same
-- name shown, the same suggestions, Enter takes the first of them.
do
    local function drive(p, label)
        p.box:SetText("cae")
        p.box._scripts.OnTextChanged(p.box, true)
        local first = p.picks.rows[1]
        check(p.picks:IsShown() and first:IsShown() and first.key == "caelith shade"
            and tostring(first.text:GetText()):find("Caelith Shade", 1, true), label .. ": suggestions while typing")
        p.box._scripts.OnEnterPressed(p.box)
        W.advance(0.3)
        return p.box:GetText()
    end
    local op = ns.OfficerUI.Picker()
    check(op and op.box:GetText() == "Thalanor Oakheart" and op.arrow, "Badge Management: the guildie opened for, in the field, with the list beside it")
    check(drive(op, "Badge Management") == "Caelith Shade", "Badge Management: Enter picks the first suggestion")
    MoonwardensBadgeManagement:Hide()
    ns.BadgeChest.Open("thalanor oakheart")
    local cp = ns.BadgeChest.Picker()
    check(cp and cp.box:GetText() == "Thalanor Oakheart", "Badge Inspector: the same field")
    check(drive(cp, "Badge Inspector") == "Caelith Shade", "Badge Inspector: Enter picks the first suggestion")
    MoonwardensBadgeChest:Hide()
end

-- The Audit Log and Approvals: hovering an entry shows its badge (the top
-- of every badge tooltip), the line in full, and the date.
do
    local B, L = ns.Badges, ns.Ledger
    local realGST = GetServerTime
    GetServerTime = function() return B.FRESH_START + 300000 + W.clock end
    local e = L.Award("thalanor oakheart", "pt1", 1, "tooltip test")
    ns.OfficerUI.Toggle()
    local pg = ns.OfficerUI.Page()
    for _, nb in ipairs(pg.nav) do if nb.id == "log" then nb._scripts.OnClick(nb) end end
    local row = pg.logRows[1]
    check(row and row.event == e and row._scripts.OnEnter, "Audit Log: the newest entry, hoverable")
    row._scripts.OnEnter(row)
    local tip = table.concat(GameTooltip.lines, "\n")
    check(tip:find(B.Title(B.Get("pt1")), 1, true) and tip:find(row.line:GetText(), 1, true)
        and tip:find(date("%B %d, %Y", e.at), 1, true), "Audit Log tooltip: the badge, the full line, the date:\n" .. tip)
    row._scripts.OnLeave(row)
    ns.OfficerUI.Toggle()
    ns.db.ledger[e.id] = nil
    GetServerTime = realGST
end

-- Badge points: hidden, until an officer shows them (/mw test badgepoints)
check(not ns.BadgesUI.ShowPoints(), "badge points hidden")
SlashCmdList.MOONWARDENS("test badgepoints on")
check(ns.BadgesUI.ShowPoints(), "/mw test badgepoints on (an officer)")
SlashCmdList.MOONWARDENS("test badgepoints off")
check(not ns.BadgesUI.ShowPoints(), "/mw test badgepoints off")

-- A tier track: its best tier earned in the Collection, its lowest not
-- earned in the unacquired list (Wrath of the Kaldorei: lt1..lt4)
do
    local B = ns.Badges
    local fake = { badges = {} }
    for _, b in ipairs(B.LIST) do fake.badges[b.id] = { times = 0, value = 0 } end
    fake.badges.lt1.times, fake.badges.lt2.times = 1, 1
    local show, rest = B.Arrange("someone else", fake, "arranged")
    local inCol = {}
    for i = 1, B.SHOWCASE_N do if show[i] then inCol[show[i].b.id] = true end end
    for _, it in ipairs(rest) do inCol[it.b.id] = true end
    check(inCol.lt2 and not inCol.lt1, "Collection: Wrath's best tier earned (Silver) only")
    local un = {}
    for _, it in ipairs(B.Unearned(fake)) do un[it.b.id] = true end
    check(un.lt3 and not un.lt4 and not un.lt1, "unacquired: Wrath's next tier (Gold) only")
end

-- Outposts and forts: only Kalimdor's count (Captures.REGION)
do
    local C, at = ns.Captures, ns.Badges.FRESH_START + 100
    local keep = ns.db.objectiveCaptures
    ns.db.objectiveCaptures = {
        { series = "outposts", zone = "ashenvale", at = at, week = 1 },     -- Shobek'Aran: counts
        { series = "outposts", zone = "tanaris", at = at, week = 1 },       -- Broken Pillar: counts
        { series = "outposts", zone = "elwynn", at = at, week = 1 },        -- Thunder Falls: doesn't
        { series = "forts", zone = "mulgore", at = at, week = 1 },          -- Prairie Keep: counts
        { series = "forts", zone = "wetlands", at = at, week = 1 },         -- Menethil Keep: doesn't
    }
    local _, o = C.Weeks("outposts")
    local _, f = C.Weeks("forts")
    check(o == 2 and f == 1, "only Kalimdor's outposts and forts count")
    local B = ns.Badges
    check(B.Get("ul1").name == "Elune's Reach" and B.Get("fl1").name == "Ancient of War", "outposts: Elune's Reach; forts: Ancient of War")
    check(B.Needs(B.Get("fl2")) == "Requires the Overlord addon." and B.Needs(B.Get("ul4")) and B.Needs(B.Get("ol1")) and not B.Get("bk1")
        and not B.Needs(B.Get("lt1")) and not B.Needs(B.Get("tv")) and not B.Needs(B.Get("lb1")),
        "the Overlord note on captures, outposts and forts only; Bankai! gone")
    -- Kalimdor Defense: Ashenvale Defense and Overlord, one page
    local kal = {}
    for _, b in ipairs(B.InCategory("kalimdor")) do kal[b.name] = true end
    check(B.IsPage("kalimdor") and not B.IsPage("ashenvale") and not B.IsPage("overlord")
        and kal["Wrath of the Kaldorei"] and kal["Chosen of Elune (Weekly)"] and kal["Elune's Reach"] and kal["Ancient of War"],
        "one Kalimdor Defense page with both pages' badges")
    ns.db.objectiveCaptures = keep
end

-- I'm Doing My Part!: inside Dor'Danil Barrow Den or Raynewood Retreat as
-- Splintertree Post falls (a small Overlord, faked)
do
    local keep = ns.db.objectiveCaptures
    ns.db.objectiveCaptures = {}
    local inZone
    local st = { id = "ash_splintertree", name = "Splintertree Post", status = "held", owner = "Horde" }
    local dd = { id = "ash_dor_danil", name = "Dor'Danil Barrow Den", status = "captured", owner = "Alliance", capturedTime = 1 }
    _G.Overlord = {
        PlayerFaction = "Alliance",
        Fronts = { activeFrontId = "ashenvale", ResolveFrontByMapID = function() return {} end },
        Zones = { GetCurrentPlayerZone = function() return inZone end },
        ZoneDatabase = { st, dd },
    }
    inZone = dd
    W.advance(3)                                          -- (inside Dor'Danil; Splintertree seen, not ours)
    st.status, st.owner, st.capturedTime = "captured", "Alliance", time()
    W.advance(2)
    local _, n = ns.Captures.Weeks("support")
    local _, caps = ns.Captures.Weeks("captures")
    check(n == 1 and caps == 0, "I'm Doing My Part!: held Dor'Danil as Splintertree fell (not a capture of it)")
    check(ns.Badges.Needs(ns.Badges.Get("dp")) and ns.Badges.Get("dp").cat == "kalimdor", "I'm Doing My Part! on Kalimdor Defense, needs Overlord")
    do
        local B = ns.Badges
        check(B.Get("dp").tier == "copper" and B.Get("dp2").goal == 3 and B.Get("dp3").goal == 6 and B.Get("dp4").goal == 10
            and B.Get("dp").track == B.Get("dp4").track and B.Needs(B.Get("dp4")),
            "I'm Doing My Part!: tiers 1, 3, 6, 10, one track, copper keeps the id dp, all need Overlord")
        local m = B.Mine().badges
        check(m.dp.times == 1 and m.dp2.times == 0 and m.dp2.value == 1, "I'm Doing My Part! once: copper, silver 1/3")
    end
    -- (the same capture re-stamped a few seconds on, as a guildmate's sync of it does: once)
    st.capturedTime = st.capturedTime + 3; W.advance(2)
    _, n = ns.Captures.Weeks("support")
    check(n == 1, "a capture re-stamped by a guildmate's sync counts once")
    -- (elsewhere when it falls again: nothing)
    inZone = nil
    st.status, st.owner = "held", "Horde"; W.advance(2)
    -- (four minutes on: a real retake, with me inside neither)
    W.advance(240)
    st.status, st.owner, st.capturedTime = "captured", "Alliance", time(); W.advance(2)
    _, n = ns.Captures.Weeks("support")
    check(n == 1, "not inside either approach: doesn't count")
    -- (lost and retaken as fast as Attack allows, 60 s each, me in Dor'Danil: a capture of its own)
    inZone = dd
    W.advance(2)
    st.status, st.owner = "held", "Horde"; W.advance(60); W.advance(58)
    st.status, st.owner, st.capturedTime = "captured", "Alliance", time(); W.advance(2)
    _, n = ns.Captures.Weeks("support")
    check(n == 2, "retaken 2 min on (Attack both ways): counts again")
    _G.Overlord = nil
    ns.db.objectiveCaptures = keep
end

-- Three Moonwardens inside one capture point, outpost or fort as it's
-- taken: me, Thalanor and Caelith. My client credits me once - their
-- clients re-stamp the capture as their syncs of it arrive, a few seconds
-- apart - so my progress goes up by exactly one; at the tier's goal I
-- claim it once, to the guild. Their claims come in: theirs on their
-- boards (a claim sent twice, or twice over, counted once), mine unchanged.
-- (A small Overlord, faked; me one short of each copper tier beforehand.)
do
    local B, C, LB = ns.Badges, ns.Captures, ns.Leaderboard
    local keepCaps, keepClaimed = ns.db.objectiveCaptures, ns.db.badgeClaimed
    local keepDB = _G.OverlordDB
    local me, tha, cae = ns.meKey, ns.key("Thalanor-Oakheart"), ns.key("Caelith-Shade")
    local function claimsSent(badge)
        local n = 0
        for _, m in ipairs(W.sent) do
            if m.m:find("^BL|1|[^|]+|claim|%d+|" .. me .. "|" .. me .. "|" .. badge .. "|") then n = n + 1 end
        end
        return n
    end
    local seq = 0
    local function theirClaim(sender, badge, times, value)
        seq = seq + 1
        local who = ns.key(sender)
        local t = B.FRESH_START + 50000 + seq    -- (the sim's clock is from before the fresh start: a claim then is dropped)
        local id = ("%xab%03x"):format(t, seq)
        local m = ("BL|1|%s|claim|%d|%s|%s|%s|%d|%d|%d|0.6.0||"):format(id, t, who, who, badge, times, LB.WeekOf(t), value)
        W.fire("CHAT_MSG_ADDON", "MWG1", m, "GUILD", sender)
        return m
    end
    local function printed(what, from)
        local n = 0
        for i = from + 1, #W.prints do if W.prints[i]:find(what, 1, true) then n = n + 1 end end
        return n
    end

    -- One kind: `series`, the copper tier `badge`, the place's `zone` (an
    -- objective id or a site key), `take(ct)` takes it for us at `ct`,
    -- `what` the line it prints.
    local function together(label, series, badge, zone, take, what)
        local goal = B.Get(badge).goal
        -- (me one short: goal - 1 of them before, long ago, a place in the region)
        local seeds = {}
        for i = 1, goal - 1 do
            local at = B.FRESH_START + 1000 * i
            seeds[i] = { series = series, zone = zone, name = zone, at = at, week = LB.WeekOf(at) }
        end
        ns.db.objectiveCaptures = seeds
        ns.db.badgeClaimed = {}
        local _, before = C.Weeks(series)
        W.advance(3)                                     -- (inside it a while, before it falls)
        local claims0, from = claimsSent(badge), #W.prints
        local ct = time()
        take(ct); W.advance(2)
        take(ct + 2); W.advance(1)                       -- (Thalanor's sync of it: re-stamped)
        take(ct + 5); W.advance(3)                       -- (Caelith's, later still)
        local _, after = C.Weeks(series)
        check(before == goal - 1 and after == goal, label .. ": taken together, my progress up by one ("
            .. tostring(before) .. " -> " .. tostring(after) .. ")")
        check(printed(what, from) == 1, label .. ": told once")
        local mine = B.Mine().badges[badge]
        check(mine and mine.times == 1, label .. ": my copper tier earned once")
        W.advance(3)                                     -- (the claim goes out)
        check(claimsSent(badge) == claims0 + 1, label .. ": claimed once, to the guild")
        -- Their claims: each on their own board, mine unchanged.
        local m = theirClaim("Thalanor-Oakheart", badge, 1, goal)
        W.fire("CHAT_MSG_ADDON", "MWG1", m, "GUILD", "Thalanor-Oakheart")   -- (the same claim heard twice)
        theirClaim("Thalanor-Oakheart", badge, 1, goal)                   -- (and claimed twice over)
        theirClaim("Caelith-Shade", badge, 1, goal)
        W.advance(1)
        local t, c = B.Of(tha).badges[badge], B.Of(cae).badges[badge]
        check(t and t.times == 1 and c and c.times == 1, label .. ": their copper tiers from their claims, once each")
        local _, still = C.Weeks(series)
        check(still == goal and B.Mine().badges[badge].times == 1, label .. ": their claims don't change mine")
        check(claimsSent(badge) == claims0 + 1, label .. ": no second claim of mine")
    end

    local inZone, onSite
    local node = { id = "ash_forest_song", name = "Forest Song", status = "captured", owner = "Horde", capturedTime = 1 }
    local outpost = { siteKey = "anadora", id = "anadora" }
    local fort = { siteKey = "mulgore", id = "mulgore" }
    _G.OverlordDB = { outposts = {
        anadora = { status = "held", ownerFaction = "Horde", claimedAt = 0 },
        mulgore = { status = "held", ownerFaction = "Horde", claimedAt = 0 },
    } }
    _G.Overlord = {
        PlayerFaction = "Alliance", L = {},
        Fronts = { activeFrontId = "ashenvale", ResolveFrontByMapID = function() return {} end },
        Zones = { GetCurrentPlayerZone = function() return inZone end },
        ZoneDatabase = { node },
        OutpostSites = { anadora = outpost },
        GuildKeepSites = { mulgore = fort },
        Outpost = {
            IsPlayerOnOutpostMap = function() return onSite ~= nil, onSite end,
            IsPlayerInOutpostGeometry = function(_, site) return site == onSite end,
        },
    }

    inZone = node
    together("capture point", "captures", "ol1", node.id, function(ct)
        node.status, node.owner, node.capturedTime = "captured", "Alliance", ct
    end, "Objective taken, with you in it:")
    inZone = nil

    onSite = outpost
    together("outpost", "outposts", "ul1", "anadora", function(ct)
        local st = OverlordDB.outposts.anadora
        st.status, st.ownerFaction, st.claimedAt = "held", "Alliance", ct
    end, "Outpost taken, with you in it:")

    onSite = fort
    together("fort", "forts", "fl1", "mulgore", function(ct)
        local st = OverlordDB.outposts.mulgore
        st.status, st.ownerFaction, st.claimedAt = "held", "Alliance", ct
    end, "Fort taken, with you in it:")
    onSite = nil

    _G.Overlord, _G.OverlordDB = nil, keepDB
    ns.db.objectiveCaptures, ns.db.badgeClaimed = keepCaps, keepClaimed
end

-- Tor ilisar'thera'nal! (Total Victory on Ashenvale), from Overlord's
-- SetVictoryCooldown (a small Overlord, faked). It counts when I'm in
-- Ashenvale and I, or (in a group) a member of it, was inside the
-- capital, Splintertree Post, as it fell; heard of up to 15 min late; once
-- however many tell it, however often. Tiers by how many in all.
do
    local B, C = ns.Badges, ns.Captures
    local keepCaps, keepGroup, keepMap = ns.db.objectiveCaptures, W.group, W.map
    ns.db.objectiveCaptures = {}
    local inZone
    local st = { id = "ash_splintertree", name = "Splintertree Post", status = "captured", owner = "Horde", capturedTime = 1,
        center = { 50, 50 }, radius = 5 }
    local rn = { id = "ash_raynewood", name = "Raynewood Retreat", status = "captured", owner = "Alliance", capturedTime = 1,
        center = { 20, 20 }, radius = 5 }
    local O = {
        PlayerFaction = "Alliance", L = {},
        Fronts = { activeFrontId = "ashenvale", ResolveFrontByMapID = function() return {} end,
            GetEnemyCapitalId = function() return "ash_splintertree" end, GetMapID = function() return 1440 end },
        Zones = { GetCurrentPlayerZone = function() return inZone end, SetVictoryCooldown = function() end,
            GetMapAspectRatio = function() return 1 end },
        ZoneDatabase = { rn, st },
    }
    _G.Overlord = O
    W.fire("ADDON_LOADED", "Overlord")                     -- (Moonwardens hooks its victories)
    W.map = 1440
    local function victories() local _, n = C.Weeks("victory"); return n end
    local function lastLog() local l = ns.db.victoryLog or {}; return l[#l] and l[#l].result or "" end
    local function partySent()
        local n = 0
        for _, m in ipairs(W.sent) do if m.m:find("^TV|") and m.ch == "PARTY" then n = n + 1 end end
        return n
    end
    local function tv(from, t) W.fire("CHAT_MSG_ADDON", "MWG1", "TV|1|ashenvale|" .. t, "PARTY", from) end
    local function fall()                                  -- (Splintertree taken for us, now)
        local t = time()
        st.status, st.owner, st.capturedTime = "captured", "Alliance", t
        return t
    end
    local function nextVictory() W.advance(1900, 1) end   -- (the next one: well apart)

    -- 1. In a party, inside Splintertree as it falls, then gone; another
    -- point re-stamped after it (a guildmate's sync); Overlord hears of the
    -- victory 3 minutes on, dated by the capital's fall.
    W.group = { "Thalanor Oakheart", "Caelith Shade" }
    W.units.party1 = { name = "Thalanor Oakheart" }
    W.units.party2 = { name = "Caelith Shade" }
    inZone = st
    W.advance(3)
    local ct = fall()
    W.advance(2)
    inZone = nil
    rn.capturedTime = ct + 4
    W.advance(180)
    local tv0 = partySent()
    O.Zones:SetVictoryCooldown("ashenvale", "Alliance", ct)
    W.advance(1)
    check(victories() == 1, "victory: counted when heard 3 min late, another point stamped after the capital")
    check(lastLog():find("^counted %(group%), heard %d+ s late"), "victory: logged as counted: " .. lastLog())
    check(partySent() == tv0 + 1, "victory: told to the party")

    -- 2. The whole party reports it, again and again: Overlord records it
    -- three more times (its paths, a few seconds apart), each groupmate
    -- tells it twice with their own stamps. Still one; told once.
    for _, d in ipairs({ 0, 2, 5 }) do O.Zones:SetVictoryCooldown("ashenvale", "Alliance", ct + d) end
    for _, d in ipairs({ 0, 1, 3, 5 }) do tv("Thalanor-Oakheart", ct + d); tv("Caelith-Shade", ct - d) end
    W.advance(1)
    check(victories() == 1, "victory: reported by the whole party, over and over: counted once")
    check(partySent() == tv0 + 1, "victory: told to the party once, not each time it's heard")

    -- 3. Thalanor inside as it falls, me elsewhere in Ashenvale; heard 1 min late.
    nextVictory()
    W.unitPos = { party1 = { 0.5, 0.5 } }
    W.advance(3)
    local ct2 = fall()
    W.advance(3)
    W.unitPos = nil
    W.advance(60)
    O.Zones:SetVictoryCooldown("ashenvale", "Alliance", ct2)
    W.advance(1)
    check(victories() == 2, "victory: a party member inside as it fell counts it for me (in Ashenvale)")

    -- 4. Thalanor inside a minute before it fell, gone by then: not counted.
    nextVictory()
    W.unitPos = { party1 = { 0.5, 0.5 } }
    W.advance(3)
    W.unitPos = nil
    W.advance(60)
    local ct3 = fall()
    W.advance(2)
    O.Zones:SetVictoryCooldown("ashenvale", "Alliance", ct3)
    W.advance(1)
    check(victories() == 2 and lastLog():find("^not counted: no one in my group"), "victory: inside before, not as it fell: not counted (" .. lastLog() .. ")")

    -- 5. Thalanor inside as it fell, but I'm not in Ashenvale: not counted -
    -- from Overlord, nor from his word.
    nextVictory()
    W.unitPos = { party1 = { 0.5, 0.5 } }
    W.advance(3)
    local ct4 = fall()
    W.advance(2)
    W.unitPos = nil
    W.map = 1439
    O.Zones:SetVictoryCooldown("ashenvale", "Alliance", ct4)
    tv("Thalanor-Oakheart", ct4)
    W.advance(1)
    check(victories() == 2 and lastLog():find("^not counted: not in Ashenvale"), "victory: out of Ashenvale: not counted (" .. lastLog() .. ")")
    W.map = 1440

    -- 6. A groupmate's word alone (Overlord saw nothing here), in Ashenvale: counted.
    nextVictory()
    local ct5 = time() - 20
    tv("Caelith-Shade", ct5)
    W.advance(1)
    check(victories() == 3 and lastLog():find("told by", 1, true), "victory: told by a party member, in Ashenvale: counted")

    -- 7. Solo and never inside it: not counted.
    W.group = {}
    W.units.party1, W.units.party2 = nil, nil
    nextVictory()
    local ct6 = fall()
    W.advance(2)
    O.Zones:SetVictoryCooldown("ashenvale", "Alliance", ct6)
    W.advance(1)
    check(victories() == 3 and lastLog():find("^not counted: not inside Splintertree Post"), "victory: solo, never inside: not counted (" .. lastLog() .. ")")
    -- (one from long ago, replayed: nothing)
    nextVictory()
    O.Zones:SetVictoryCooldown("ashenvale", "Alliance", time() - 1000)
    W.advance(1)
    check(victories() == 3, "victory: an old one replayed doesn't count")

    -- The tiers: 1, 5, 10, 20; copper once at three (no "x3").
    local mine = B.Mine().badges
    check(B.Get("tv").tier == "copper" and B.Get("tv2").goal == 5 and B.Get("tv3").goal == 10 and B.Get("tv4").goal == 20
        and B.Get("tv").track == B.Get("tv4").track, "Tor ilisar'thera'nal!: tiers 1, 5, 10, 20, one track, copper keeps the id tv")
    check(mine.tv.times == 1 and mine.tv2.times == 0 and mine.tv2.value == 3, "three victories: copper once, silver 3/5")
    local printed = #W.prints
    SlashCmdList.MOONWARDENS("test victory")
    check(table.concat(W.prints, "\n", printed + 1):find("counted (group)", 1, true), "/mw test victory lists them")

    _G.Overlord = nil
    W.group, W.map = keepGroup, keepMap
    ns.db.objectiveCaptures = keepCaps
end

-- An officer's Grant Badge: the badge, the tiers under it, and (for one
-- counted toward, patrols) its count at the goal - what's added after
-- counts on top; revoked, all of it goes. (The ledger keeps nothing from
-- before the fresh start: the server clock is moved past it here.)
do
    local B, L = ns.Badges, ns.Ledger
    local realGST = GetServerTime
    GetServerTime = function() return B.FRESH_START + 200000 + W.clock end
    local tha = ns.key("Thalanor-Oakheart")
    local g = L.Award(tha, "pt2", 0, "grant test")
    check(g, "officer grants Owl's Vigilance silver")
    local r = B.Of(tha).badges
    check(r.pt1.times == 1 and r.pt2.times == 1 and r.pt3.times == 0 and r.pt3.value == 15,
        "granted silver: copper too, and gold's progress at silver's goal (" .. tostring(r.pt3.value) .. "/30)")
    W.advance(2)
    local p = L.Award(tha, "pt1", 1, "one more patrol")
    r = B.Of(tha).badges
    check(p and r.pt3.value == 16, "a patrol added after the grant counts on top (" .. tostring(r.pt3.value) .. ")")
    W.advance(2)
    local rv = L.Revoke(g.id, "test: a mistake")
    r = B.Of(tha).badges
    check(rv and r.pt2.times == 0 and r.pt1.times == 0 and r.pt3.value == 1, "the grant revoked: its count goes with it")
    -- A track counted by the addon (kills): granting silver gives copper too.
    local k = L.Award(tha, "lt2", 0, "grant test")
    r = B.Of(tha).badges
    check(k and r.lt1.times == 1 and r.lt2.times == 1 and r.lt3.times == 0, "granted kills silver: copper too")
    -- (the test's events: gone again)
    for _, e in ipairs({ g, p, rv, k }) do if e then ns.db.ledger[e.id] = nil end end
    GetServerTime = realGST
end

-- A fresh start in this week (moved here for the check), its week carried
-- over (FRESH_KEEPS_WEEK): my kills this week, all of them, toward the
-- kills badges, and a guildie's from the board too. Without it, only kills
-- after the fresh start ran here.
do
    local B, LB = ns.Badges, ns.Leaderboard
    local keep = { B.FRESH_START, B.FRESH_KEEPS_WEEK, ns.db.freshStart, ns.db.badgeFreshBase, ns.db.badgeClaimed }
    local cur = LB.Week()
    local mine = LB.Mine(cur)
    B.FRESH_START = LB.WeekStart(cur) + 60
    B.FRESH_KEEPS_WEEK = true
    ns.db.freshStart = nil
    ns.db.movedNoticeSeen, ns.db.badgeTabNew, ns.db.badgeUnseen = true, nil, {}
    B.FreshStartLocal()
    check(mine > 0 and B.MyWeeks()[cur] == mine, "fresh start, week carried over: all " .. mine .. " of my kills this week count")
    check(ns.db.movedNoticeSeen == nil and ns.db.badgeKnown == nil and next(ns.db.badgeNew) == nil,
        "fresh start: the moved notice to show again, the new-badge dots as on a first load")
    ns.BadgesUI.New.Check(); W.advance(1)
    check(ns.db.badgeTabNew and next(ns.db.badgeUnseen) ~= nil, "fresh start: the Badges tab's dot, and the badges not earned new to see")
    local tha = ns.key("Thalanor-Oakheart")
    local onBoard = (ns.db.board[cur] or {})[tha]
    check(onBoard and B.WeeksOf(tha)[cur] == onBoard.c, "fresh start, week carried over: a guildie's kills this week, from the board")
    B.FRESH_KEEPS_WEEK = false
    ns.db.freshStart = nil
    B.FreshStartLocal()
    check((B.MyWeeks()[cur] or 0) == 0 and B.WeeksOf(tha)[cur] == nil, "fresh start, week not carried: none of this week's kills before it")
    B.FRESH_START, B.FRESH_KEEPS_WEEK, ns.db.freshStart, ns.db.badgeFreshBase, ns.db.badgeClaimed = unpack(keep)
end

-- Vengeance Abides (the rank of Huntress): only a Huntress's own client
-- files its request, once. An officer (above it), or any other rank,
-- logging in for the first time files none.
do
    local B, L = ns.Badges, ns.Ledger
    local realGST = GetServerTime
    GetServerTime = function() return math.floor(B.FRESH_START + 400000 + W.clock) end   -- (whole seconds, as the game's)
    local keepRank, keepAsked, keepTest = W.roster[1][2], ns.db.rankRequested, ns.db.testMode
    ns.db.testMode = nil
    local function asked()
        local n = 0
        for _, m in ipairs(W.sent) do
            if m.m:find("^BL|1|[^|]+|request|%d+|" .. ns.meKey .. "|" .. ns.meKey .. "|hr|") then n = n + 1 end
        end
        return n
    end
    local function firstLogin(rank)
        W.roster[1][2] = rank
        ns.Roster.Build()
        ns.db.rankRequested = {}                          -- (as on a first login)
        L.CheckClaims()
        W.advance(5)                                      -- (anything sent goes out)
    end
    local n0 = asked()
    firstLogin("Warden-General")
    check(asked() == n0 and not ns.db.rankRequested.hr, "an officer's first login: no Vengeance Abides request")
    firstLogin("Glaivemistress")
    check(asked() == n0, "the guild's top rank: none either")
    firstLogin("Sentinel")
    check(asked() == n0, "a rank below Huntress: none")
    firstLogin("Huntress")
    L.CheckClaims(); W.advance(5)
    check(asked() == n0 + 1, "and not again")
    -- (put back: the rank, and the request made here gone from the ledger)
    for id, e in pairs(ns.db.ledger) do if e.kind == "request" and e.badge == "hr" and e.who == ns.meKey then ns.db.ledger[id] = nil end end
    W.roster[1][2] = keepRank
    ns.Roster.Build()
    ns.db.rankRequested, ns.db.testMode = keepAsked, keepTest
    GetServerTime = realGST
end

-- The "Moonwardens has moved" notice: shown at login, in a window of its
-- own (not the confirm box); Escape doesn't close it, only Okay - for good.
do
    local n = ns.UI.Notice()
    check(n and n == MoonwardensNotice and n:IsShown(), "the moved notice shown at login")
    local esc = false
    for _, name in ipairs(UISpecialFrames or {}) do if name == "MoonwardensNotice" then esc = true end end
    check(not esc, "Escape doesn't close it")
    n.ok._scripts.OnClick(n.ok)
    check(not n:IsShown() and ns.db.movedNoticeSeen == true, "Okay closes it, for good")
    ns.db.movedNoticeSeen = nil
    SlashCmdList.MOONWARDENS("test notice")
    check(n:IsShown(), "/mw test notice shows it again")
    n.ok._scripts.OnClick(n.ok)
end

-- An offline guildie's badges: no whisper (the game would say "No player
-- named ..."); what an online one sends is kept for when they're offline
do
    ns.Roster.Build()
    local vel, tha = ns.key("Velanya-Dawnleaf"), ns.key("Thalanor-Oakheart")
    local before = countSent("BQ")
    ns.Badges.Request(vel); W.advance(2)
    check(countSent("BQ") == before, "offline guildie: badges not asked for")
    W.advance(11)
    ns.Badges.Request(tha); W.advance(2)
    check(countSent("BQ") == before + 1, "online guildie: badges asked for")
    W.fire("CHAT_MSG_ADDON", "MWG1", "BS|1|1|1|2900:7", "WHISPER", "Thalanor-Oakheart")
    local c = ns.db.badgeCache and ns.db.badgeCache[tha]
    check(c and c.weeks and c.weeks[2900] == 7 and ns.Badges.SavedAt(tha), "their answer kept between sessions")
end

local errs = {}
for _, line in ipairs(W.prints) do if line:find("error", 1, true) then errs[#errs + 1] = line end end
check(#errs == 0, "no errors printed by the addon:\n  " .. table.concat(errs, "\n  "))

print(("%d passed, %d failed"):format(passes, fails))
if fails == 0 then print("ALL PASS") else os.exit(1) end
