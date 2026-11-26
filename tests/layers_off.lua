-- Loads the addon from the .toc under the mock as it ships, layers off
-- (ns.LAYERS = false, Core.lua), and checks nothing reads, sends or shows a
-- layer. (tests/sim.lua turns them on to check their code.)
-- Run from repo root: luajit tests/layers_off.lua
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

local function sent(kind)
    local n, last = 0, nil
    for _, m in ipairs(W.sent) do
        if m.m:sub(1, #kind + 1) == kind .. "|" then n = n + 1; last = m end
    end
    return n, last
end

check(ns.LAYERS == false, "layers off as shipped")
check(ns.Layer == nil and ns.LayerLink == nil, "no layer detector, no LayerLink")
check(ns.slash.layer == nil and ns.slash.debug ~= nil, "no /mw layer; /mw debug still there")
local keys = {}
for _, s in ipairs(ns.UI.SETTINGS) do if s[2] then keys[s[1]] = true end end
check(keys.worldDots and keys.minimapDots and not keys.otherLayers and not keys.layerPlates,
    "Settings > Map: no layer settings")

-- My position goes out with layer 0 ("not known"); nothing else of layers.
W.pos = { 0.52, 0.5 }
W.advance(40)
local _, p = sent("P")
check(p and p.m:match("^P|1|1440|[%d.]+|[%d.]+|0|"), "P carries layer 0: " .. tostring(p and p.m))
check(sent("F") == 0 and sent("LR") == 0 and sent("LN") == 0, "no sightings or layer numbers sent")

-- A guildie's position with a layer, and an older client's layer messages:
-- read without error, and their dot drawn plain, whatever their layer.
local function recv(text, from) W.fire("CHAT_MSG_ADDON", "MWG1", text, "GUILD", from) end
ns.db.otherLayers = false           -- (an old setting left unticked: no effect now)
recv("P|1|1440|0.4000|0.6000|3|0|60", "Thalanor-Oakheart")
recv("F|1|1440|1|abcd|efgh", "Thalanor-Oakheart")
recv("LR|1|1440|||", "Thalanor-Oakheart")
recv("LN|1|1440|1=abcd", "Thalanor-Oakheart")
local g = ns.Position.Get("thalanor oakheart")
check(g and ns.Position.Relation(g) == "na" and ns.Position.LayerText(g) == nil, "no layer relation or text")

-- The world map: dots, no layer panel.
WorldMapFrame:Show()
W.advance(0.3)
local dots, used, panel = ns.MapWorld.Debug()
check(used == 1 and dots[1].g.key == "thalanor oakheart", "their dot drawn: " .. tostring(used))
check(panel == nil, "no layer panel on the world map")
WorldMapFrame:Hide()

-- The minimap button's tooltip: no layer line.
MoonwardensMinimapButton._scripts.OnEnter(MoonwardensMinimapButton)
check(not table.concat(GameTooltip.lines, "\n"):lower():find("layer", 1, true), "minimap button tooltip: no layer line")

local errs = {}
for _, line in ipairs(W.prints) do if line:find("error", 1, true) then errs[#errs + 1] = line end end
check(#errs == 0, "no errors printed by the addon:\n  " .. table.concat(errs, "\n  "))

print(("%d passed, %d failed"):format(passes, fails))
if fails > 0 then os.exit(1) end
print("ALL PASS")
