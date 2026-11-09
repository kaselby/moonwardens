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
check(s.level[7] == 2 and s.level[5] == 1 and s.level[4] == 1, "level bands")
check(ns.Roster.Stats(true).total == 3, "online-only stats")

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
ns.ToggleWindow(9)
check(MoonwardensFrame.current == 9, "settings page")
W.missingTemplates = { PortraitFrameTemplate = true }
SlashCmdList.MOONWARDENS("comm")
check(W.prints[#W.prints]:find("sent"), "slash comm")
MoonwardensMinimapButton._scripts.OnEnter(MoonwardensMinimapButton)
check(#GameTooltip.lines >= 3, "minimap tooltip")

W.advance(130)
check(W.rosterRequests >= 2, "roster re-requested")

print(("%d passed, %d failed"):format(passes, fails))
if fails == 0 then print("ALL PASS") else os.exit(1) end
