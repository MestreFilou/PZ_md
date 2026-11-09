--***********************************************************
--  Underground Base Excavation - UndergroundSystem.lua (shared)
--  Tile state registry (global ModData), cave-in logic and the
--  client <-> server command bridge.
--
--  How Z-level changes are requested:
--   1. The client never edits the world itself. When a timed action
--      finishes it calls UndergroundSystem.sendToServer(player, cmd, args).
--   2. In multiplayer this becomes sendClientCommand(...). The server
--      receives it in UndergroundCommands.lua (Events.OnClientCommand),
--      validates it, creates/edits the squares at Z = -1, -2 ... and
--      transmits the changed objects and the ModData to every client.
--   3. In singleplayer there is no network: the same server handler is
--      called directly, so the logic is identical in both modes.
--   4. The server answers a single player (cave-in damage, relocation)
--      with UndergroundSystem.sendToClient -> sendServerCommand(...).
--***********************************************************

require "UndergroundUtils"

UndergroundSystem = UndergroundSystem or {}

local Utils  = UndergroundUtils
local Config = UndergroundUtils.Config

-- Tile states (spec: State 0..3)
UndergroundSystem.STATE = {
    UNEXCAVATED = 0, -- solid ground (or refilled by a cave-in)
    UNBRACED    = 1, -- dug out, may collapse
    BRACED      = 2, -- wooden shoring, stable
    REINFORCED  = 3, -- permanent structure
}
local STATE = UndergroundSystem.STATE

-------------------------------------------------------------
-- Data access
-- Layout:  data.tiles["x_y_z"] = { state = 1, collapseChance = 0.15,
--                                  shaftUp = bool, shaftDown = bool }
-------------------------------------------------------------
function UndergroundSystem.getData()
    local data = ModData.getOrCreate(Config.ModDataKey)
    data.tiles = data.tiles or {}
    return data
end

function UndergroundSystem.getTile(x, y, z)
    return UndergroundSystem.getData().tiles[Utils.key(x, y, z)]
end

function UndergroundSystem.getState(x, y, z)
    local t = UndergroundSystem.getTile(x, y, z)
    return (t and t.state) or STATE.UNEXCAVATED
end

function UndergroundSystem.isExcavated(x, y, z)
    return UndergroundSystem.getState(x, y, z) >= STATE.UNBRACED
end

-- Server/SP only. Merges fields into a tile record.
function UndergroundSystem.setTile(x, y, z, fields)
    local tiles = UndergroundSystem.getData().tiles
    local k = Utils.key(x, y, z)
    local t = tiles[k] or { state = STATE.UNEXCAVATED, collapseChance = 0 }
    for f, v in pairs(fields) do t[f] = v end
    tiles[k] = t
    return t
end

-- Server/SP only. Pushes the ModData table to every client.
function UndergroundSystem.sync()
    if isServer() then ModData.transmit(Config.ModDataKey) end
end

-------------------------------------------------------------
-- Command bridge
-------------------------------------------------------------
function UndergroundSystem.sendToServer(player, command, args)
    if isClient() then
        sendClientCommand(player, Config.ModuleName, command, args or {})
    elseif UndergroundCommands and UndergroundCommands.handle then
        -- Singleplayer: call the server handler directly.
        UndergroundCommands.handle(player, command, args or {})
    end
end

function UndergroundSystem.sendToClient(player, command, args)
    if isServer() then
        sendServerCommand(player, Config.ModuleName, command, args or {})
    elseif UndergroundSystem.ClientHandlers and UndergroundSystem.ClientHandlers[command] then
        UndergroundSystem.ClientHandlers[command](player, args or {})
    end
end

-------------------------------------------------------------
-- Cave-in logic
-------------------------------------------------------------
-- Rolls a collapse on (x,y,z). Returns true if it collapsed.
-- multiplier lets callers lower the base chance (walking vs digging next to it).
-- Server/SP only: the actual world edit is UndergroundCommands.collapseTile.
function UndergroundSystem.rollCollapse(x, y, z, multiplier)
    local t = UndergroundSystem.getTile(x, y, z)
    if not t or t.state ~= STATE.UNBRACED then return false end
    local chance = (t.collapseChance or Config.DefaultCollapseChance) * (multiplier or 1)
    return ZombRandFloat(0, 1) < chance
end

-- Spec entry point: called when a player enters or acts on a tile.
-- Server/SP only. Returns true if a cave-in happened.
function UndergroundSystem.checkCaveIn(player, square, multiplier)
    if not square then return false end
    local x, y, z = square:getX(), square:getY(), square:getZ()
    if UndergroundSystem.rollCollapse(x, y, z, multiplier or Config.EnterChanceMultiplier) then
        if UndergroundCommands and UndergroundCommands.collapseTile then
            UndergroundCommands.collapseTile(x, y, z)
        end
        return true
    end
    return false
end

-- Client side: hurt the player after a cave-in.
-- severity 1 = debris from a nearby collapse, 2 = buried under it.
local CaveInParts = {
    "Head", "Neck", "Torso_Upper", "Torso_Lower",
    "UpperArm_L", "UpperArm_R", "ForeArm_L", "ForeArm_R",
    "UpperLeg_L", "UpperLeg_R", "LowerLeg_L", "LowerLeg_R",
}

function UndergroundSystem.applyCaveInDamage(player, severity)
    local bd = player and player:getBodyDamage()
    if not bd then return end
    local hits = (severity >= 2) and ZombRand(2, 5) or 1
    for _ = 1, hits do
        local partName = CaveInParts[ZombRand(#CaveInParts) + 1]
        pcall(function()
            local part = bd:getBodyPart(BodyPartType[partName])
            part:AddDamage(severity >= 2 and ZombRand(15, 35) or ZombRand(5, 12))
            if ZombRand(100) < 40 then part:setScratched(true, true) end
            -- Legs/arms may break when buried
            if severity >= 2 and ZombRand(100) < 25 and partName ~= "Head" and partName ~= "Neck" then
                part:setFractureTime(ZombRand(20, 50))
            end
        end)
    end
    Utils.addStat(player, "endurance", -0.25)
    if severity >= 2 then
        pcall(function() player:setKnockedDown(true) end)
    end
end
