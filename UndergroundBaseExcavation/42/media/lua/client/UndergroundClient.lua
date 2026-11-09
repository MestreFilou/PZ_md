--***********************************************************
--  Underground Base Excavation - UndergroundClient.lua (client)
--  - Receives the tile registry (global ModData) from the server.
--  - Handles server -> client commands (cave-in damage, messages).
--  - Detects when the local player steps onto an unbraced tile and
--    asks the server to roll a cave-in.
--***********************************************************

require "UndergroundUtils"
require "UndergroundSystem"

local Utils  = UndergroundUtils
local Config = UndergroundUtils.Config
local STATE  = UndergroundSystem.STATE

-------------------------------------------------------------
-- Server -> client handlers (also called directly in singleplayer)
-------------------------------------------------------------
UndergroundSystem.ClientHandlers = UndergroundSystem.ClientHandlers or {}
local Handlers = UndergroundSystem.ClientHandlers

function Handlers.caveIn(player, args)
    player:playSound(Config.Sounds.Collapse)
    pcall(function() addSound(player, args.x, args.y, args.z, 20, 20) end)
    UndergroundSystem.applyCaveInDamage(player, args.severity or 1)
    if args.severity and args.severity >= 2 then
        if args.safeX then
            Utils.teleport(player, args.safeX, args.safeY, args.safeZ)
            Utils.say(player, "UI_Underground_CaveIn", true)
        else
            Utils.say(player, "UI_Underground_Trapped", true)
        end
    else
        Utils.say(player, "UI_Underground_CaveInNearby", true)
    end
end

function Handlers.message(player, args)
    if args.key then Utils.say(player, args.key, args.red) end
end

local function onServerCommand(module, command, args)
    if module ~= Config.ModuleName then return end
    local h = Handlers[command]
    if not h then return end
    -- Server commands are sent to one player; in split-screen apply to the local players.
    for i = 0, getNumActivePlayers() - 1 do
        local p = getSpecificPlayer(i)
        if p then h(p, args or {}) end
    end
end
Events.OnServerCommand.Add(onServerCommand)

-------------------------------------------------------------
-- Global ModData sync (multiplayer)
-------------------------------------------------------------
local function onInitGlobalModData()
    if isClient() then ModData.request(Config.ModDataKey) end
end
Events.OnInitGlobalModData.Add(onInitGlobalModData)

local function onReceiveGlobalModData(key, data)
    if key == Config.ModDataKey and type(data) == "table" then
        ModData.add(key, data)
    end
end
Events.OnReceiveGlobalModData.Add(onReceiveGlobalModData)

-------------------------------------------------------------
-- Step detection: roll a cave-in when entering an unbraced tile
-------------------------------------------------------------
local lastTile = {}   -- [playerNum] = key
local lastRoll = {}   -- [playerNum .. key] = timestamp ms

local function onPlayerUpdate(player)
    if not player or player:getZ() >= 0 or not player:isLocalPlayer() then return end
    local num = player:getPlayerNum()
    local x, y, z = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    local k = Utils.key(x, y, z)
    if lastTile[num] == k then return end
    lastTile[num] = k

    if UndergroundSystem.getState(x, y, z) ~= STATE.UNBRACED then return end
    local now = getTimestampMs()
    local rk = tostring(num) .. k
    if lastRoll[rk] and now - lastRoll[rk] < Config.StepCheckCooldownMs then return end
    lastRoll[rk] = now

    Utils.say(player, "UI_Underground_Unstable", true)
    UndergroundSystem.sendToServer(player, "stepOn", { x = x, y = y, z = z })
end
Events.OnPlayerUpdate.Add(onPlayerUpdate)
