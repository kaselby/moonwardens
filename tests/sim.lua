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

-- UI builds and opens
ns.ToggleWindow()
check(MoonwardensFrame and MoonwardensFrame:IsShown(), "window opens")
do
    local texts = {}
    for _, fr in ipairs(W.frames) do if fr._kind == "FontString" and fr._text then texts[#texts + 1] = tostring(fr._text) end end
    local all = table.concat(texts, "\n")
    check(all:find("2  |cff9d9d9d67%|r", 1, true) and all:find("1  |cff9d9d9d25%|r", 1, true) and all:find("\n50%\n", 1, true) , "stats show count and percent")
end
ns.ToggleWindow(9)
check(MoonwardensFrame.current == 9, "settings page")
W.missingTemplates = { PortraitFrameTemplate = true }
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
check(#list == 2 and list[1].layer == 3 and list[1].label == "Layer 1" and list[2].label == "Layer 2" and list[2].mine
    and list[2].n == 2 and unknown == 0, "layers in zone, labelled by rank")
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
check(panel.cards[1].name:GetText() == "Layer 1" and panel.cards[2].name:GetText():find("Layer 2", 1, true)
    and panel.cards[2].name:GetText():find("you", 1, true) and panel.cards[2].count:GetText() == "2 guildies", "layer cards")

-- Hover
GameTooltip:Hide() -- (nobody else's tooltip up: ours steps back for those)
W.cursor = { tdot._cx + 3, tdot._cy - 2 }
W.advance(0.1)
local tip = table.concat(GameTooltip.lines, "\n")
check(GameTooltip:GetOwner() ~= nil and tip:find("Thalanor Oakheart", 1, true) and tip:find("Layer 2 (same as you)", 1, true)
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
-- Minimap hover: the game rebuilds its tooltip every frame; our lines follow it
W.cursor = { md[1]._cx + 2, md[1]._cy }
GameTooltip.lines = {}
Minimap_OnUpdate(Minimap)
local mtip = table.concat(GameTooltip.lines, "\n")
check(GameTooltip:GetOwner() == UIParent and mtip:find("Thalanor Oakheart", 1, true), "minimap hover: name in the game's tooltip: " .. mtip)
W.cursor = { 0, 0 }
Minimap_OnUpdate(Minimap)
check(#GameTooltip.lines == 0, "minimap hover: nothing under the cursor, no lines")
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
SlashCmdList.MOONWARDENS("test")
check(W.prints[#W.prints]:find("2 guildies placed", 1, true) and P.CountInMyZone() == 2, "/mw test")

---------------------------------------------------------------------------
-- Phase 3: layer detector
---------------------------------------------------------------------------
local Lr = ns.Layer
local function npc(server, spawn) return ("Creature-0-%d-1-2-3346-%s"):format(server, spawn) end
local layerEvents = {}
ns.listen("LAYER", function(map, from, to) layerEvents[#layerEvents + 1] = { map, from, to } end)
W.fire("PLAYER_ENTERING_WORLD")
W.advance(2)
check(Lr.Mine(1440) == 0, "unknown at start")
W.units.target = { guid = npc(7075, "A1") }
W.fire("PLAYER_TARGET_CHANGED"); W.fire("PLAYER_TARGET_CHANGED")
check(Lr.Mine(1440) == 0, "same NPC twice is not enough")
W.units.mouseover = { guid = "Pet-0-7052-1-2-1234-B1", pc = true }
W.fire("UPDATE_MOUSEOVER_UNIT")
W.units.mouseover = { guid = npc(7052, "B2"), pc = true }    -- a player's guardian
W.fire("UPDATE_MOUSEOVER_UNIT")
W.units.mouseover = { guid = "Player-0-7052-0001" }
W.fire("UPDATE_MOUSEOVER_UNIT")
check(Lr.Mine(1440) == 0, "pets, guardians and players ignored")
W.units.mouseover = { guid = npc(7075, "A2") }
W.fire("UPDATE_MOUSEOVER_UNIT")
check(Lr.Mine(1440) == 7075 and layerEvents[#layerEvents][3] == 7075, "two NPCs confirm the layer")
check(Lr.Mine(1439) == 0, "layer is per zone")
W.advance(1.5)
check(lastSent("P").m:match("^P|1|1440|[%d.]+|[%d.]+|7075|"), "P carries the layer: " .. lastSent("P").m)
-- A different number: one NPC is not enough, two are
W.units.n1 = { guid = npc(7062, "C1") }
W.plates = { "n1" }
W.advance(2.1)
check(Lr.Mine(1440) == 7075, "one NPC with a new number doesn't switch")
W.fire("NAME_PLATE_UNIT_ADDED", "n1")
check(Lr.Mine(1440) == 7075, "same NPC again doesn't switch")
W.units.target = { guid = npc(7062, "C2") }
W.fire("PLAYER_TARGET_CHANGED")
check(Lr.Mine(1440) == 7062, "second NPC switches")
W.plates = {}
-- Tooltip, panel label
MoonwardensMinimapButton._scripts.OnEnter(MoonwardensMinimapButton)
check(table.concat(GameTooltip.lines, "\n"):find("Your layer: Layer %d+"), "minimap tooltip layer line: " .. table.concat(GameTooltip.lines, " / "))
-- Zone change and shard transfer forget it
W.fire("ZONE_CHANGED_NEW_AREA")
check(Lr.Mine(1440) == 0, "forgotten on zone change")
W.units.target = { guid = npc(7075, "A1") }; W.fire("PLAYER_TARGET_CHANGED")
W.units.target = { guid = npc(7075, "A3") }; W.fire("PLAYER_TARGET_CHANGED")
check(Lr.Mine(1440) == 7075, "re-confirmed")
-- Shard transfer: the layer is kept, and the next NPC settles it.
W.fire("SHARD_TRANSFER")
check(Lr.Mine(1440) == 7075, "kept through shard transfer (rechecking)")
W.units.target = { guid = npc(7062, "B1") }; W.fire("PLAYER_TARGET_CHANGED")
check(Lr.Mine(1440) == 7062, "one NPC replaces it after a shard transfer")
W.fire("SHARD_TRANSFER")
W.units.target = { guid = npc(7075, "A1") }; W.fire("PLAYER_TARGET_CHANGED")
check(Lr.Mine(1440) == 7075, "and back again")
W.units.target = { guid = npc(7062, "B2") }; W.fire("PLAYER_TARGET_CHANGED")
check(Lr.Mine(1440) == 7075, "outside a recheck one NPC still doesn't switch")
W.units.target = { guid = npc(7075, "A3") }; W.fire("PLAYER_TARGET_CHANGED")
W.advance(601)
check(Lr.Mine(1440) == 0, "forgotten after 10 min")
W.units = {}
SlashCmdList.MOONWARDENS("layer")
check(W.prints[#W.prints]:find("experimental", 1, true), "/mw layer")

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
W.map = 1440; W.hk = 0; W.advance(6); W.hk = 2; W.fire("PLAYER_PVP_KILLS_CHANGED")
check(LB.Mine() == 3, "counter reset (new day) handled")
W.instance = true; W.hk = 3; W.advance(6); W.instance = false
check(LB.Mine() == 3, "kill in an instance (Warsong) not counted")
local nH = countSent("H")
W.advance(31)
check(countSent("H") == nH + 1 and lastSent("H").m == "H|1|" .. wk .. "|3", "one debounced H: " .. tostring(lastSent("H") and lastSent("H").m))
W.hk = 4; W.fire("PLAYER_PVP_KILLS_CHANGED"); W.advance(5)
W.hk = 5; W.fire("PLAYER_PVP_KILLS_CHANGED"); W.advance(5)
check(countSent("H") == nH + 1, "no second H within 30 s")
W.advance(25)
check(countSent("H") == nH + 2 and lastSent("H").m == "H|1|" .. wk .. "|5", "then one H with the latest count")
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
    and hs.m:find("Sanalune-Silverwind:5", 1, true) and hs.m:find("Caelith-Shade:5", 1, true), "HS reply: " .. tostring(hs and hs.m))
W.fire("CHAT_MSG_ADDON", "MWG1", "HS|1|" .. wk .. "|Velanya-Dawnleaf:12,Sanalune-Silverwind:999,Random-Stranger:7,bad", "WHISPER", "Caelith-Shade")
rows = LB.Rows(wk)
check(#rows == 4 and LB.Mine() == 5, "HS merged; my own count not overwritten; stranger not shown")
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
check(pg.sub:GetText():find("guild total |cffffd100" .. (50 + 12 + 5 + 5) .. "|r", 1, true) and pg.sub:GetText():find("left", 1, true), "subtitle: " .. pg.sub:GetText())
check(pg.foot:GetText():find("Thalanor Oakheart|r (241)", 1, true), "last week's winner in the footer: " .. pg.foot:GetText())
pg.tabs[2]._scripts.OnClick(pg.tabs[2])
check(pg.sub:GetText():find("Final standings", 1, true) and pg.rows[1].n:GetText() == 241 and not pg.rows[2]:IsShown(), "last week view")
pg.tabs[1]._scripts.OnClick(pg.tabs[1])
SlashCmdList.MOONWARDENS("hk")
check(W.prints[#W.prints]:find("5 Horde kills", 1, true), "/mw hk")
ns.ToggleWindow()

check(not W.events["COMBAT_LOG_EVENT_UNFILTERED"], "combat log never registered (forbidden on 12.x)")

local errs = {}
for _, line in ipairs(W.prints) do if line:find("error", 1, true) then errs[#errs + 1] = line end end
check(#errs == 0, "no errors printed by the addon:\n  " .. table.concat(errs, "\n  "))

print(("%d passed, %d failed"):format(passes, fails))
if fails == 0 then print("ALL PASS") else os.exit(1) end
