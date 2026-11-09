--***********************************************************
--  Underground Base Excavation - UndergroundCommands.lua (server)
--  Authoritative side: validates requests, edits squares on
--  negative Z-levels, keeps ModData in sync, resolves cave-ins.
--  Loaded on the dedicated server and in singleplayer.
--***********************************************************

require "UndergroundUtils"
require "UndergroundSystem"

UndergroundCommands = UndergroundCommands or {}

local Utils  = UndergroundUtils
local Config = UndergroundUtils.Config
local System = UndergroundSystem
local STATE  = UndergroundSystem.STATE

local TAG_WALL    = "UBE_wall"     -- earth wall around dug tiles
local TAG_RUBBLE  = "UBE_rubble"   -- cave-in rubble
local TAG_SHORING = "UBE_shoring"  -- optional shoring visual
local TAG_SHAFT   = "UBE_shaft"    -- optional shaft visual

-------------------------------------------------------------
-- World helpers
-------------------------------------------------------------
-- Gets (or creates) a square. B42 lets us create squares at Z < 0;
-- the square is saved with its chunk once it holds objects.
local function ensureSquare(x, y, z)
    local cell = getCell()
    local sq = cell:getGridSquare(x, y, z)
    if sq then return sq end
    local ok, res = pcall(function() return cell:getOrCreateGridSquare(x, y, z) end)
    if ok and res then return res end
    ok, res = pcall(function() return cell:createNewGridSquare(x, y, z, true) end)
    if ok and res then return res end
    return nil
end

local function refresh(sq)
    pcall(function() sq:RecalcAllWithNeighbours(true) end)
    pcall(function() sq:setSquareChanged() end)
end

local function transmitAdd(obj)
    if isServer() then pcall(function() obj:transmitCompleteItemToClients() end) end
end

local function removeObject(sq, obj)
    if isServer() then
        sq:transmitRemoveItemFromSquare(obj) -- removes locally and on clients
    else
        sq:RemoveTileObject(obj)
    end
end

local function findMarkers(sq, tag)
    local found = {}
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        if obj:getModData()[tag] then table.insert(found, obj) end
    end
    return found
end

local function removeMarkers(sq, tag)
    for _, obj in ipairs(findMarkers(sq, tag)) do removeObject(sq, obj) end
end

local function addMarker(sq, spriteName, tag)
    if not spriteName or #findMarkers(sq, tag) > 0 then return end
    local obj = IsoObject.new(getCell(), sq, spriteName)
    obj:getModData()[tag] = true
    sq:AddTileObject(obj)
    transmitAdd(obj)
end

local function ensureFloor(sq)
    if sq:getFloor() then return end
    local floor = sq:addFloor(Config.Sprites.Floor)
    if floor then transmitAdd(floor) end
end

local function allPlayers()
    local list = {}
    if isServer() then
        local online = getOnlinePlayers()
        for i = 0, online:size() - 1 do table.insert(list, online:get(i)) end
    else
        for i = 0, getNumActivePlayers() - 1 do
            local p = getSpecificPlayer(i)
            if p then table.insert(list, p) end
        end
    end
    return list
end

local function message(player, key, red)
    System.sendToClient(player, "message", { key = key, red = red })
end

-------------------------------------------------------------
-- Excavation
-------------------------------------------------------------
-- Turns (x,y,z) into an open, unbraced tile and surrounds it with
-- earth walls on every neighbour that is still solid ground.
function UndergroundCommands.excavate(x, y, z, extra)
    local sq = ensureSquare(x, y, z)
    if not sq then return false end

    removeMarkers(sq, TAG_WALL)
    removeMarkers(sq, TAG_RUBBLE)
    ensureFloor(sq)

    local fields = { state = STATE.UNBRACED, collapseChance = Config.DefaultCollapseChance, rubble = false }
    if extra then for k, v in pairs(extra) do fields[k] = v end end
    System.setTile(x, y, z, fields)

    for _, d in ipairs(Utils.Directions) do
        local nx, ny = x + d.dx, y + d.dy
        if not System.isExcavated(nx, ny, z) then
            local nsq = ensureSquare(nx, ny, z)
            if nsq then
                addMarker(nsq, Config.Sprites.Wall, TAG_WALL)
                refresh(nsq)
            end
        end
    end
    refresh(sq)
    return true
end

-- Refills a tile with rubble and hurts/relocates players on or near it.
function UndergroundCommands.collapseTile(x, y, z)
    local t = System.getTile(x, y, z)
    if not t then return end

    -- A collapsed shaft blocks the way up/down.
    if t.shaftUp then
        System.setTile(x, y, z + 1, { shaftDown = false })
    end
    if t.shaftDown then
        System.setTile(x, y, z - 1, { shaftUp = false })
    end
    System.setTile(x, y, z, { state = STATE.UNEXCAVATED, collapseChance = 0, rubble = true,
                              shaftUp = false, shaftDown = false })

    local sq = ensureSquare(x, y, z)
    if sq then
        removeMarkers(sq, TAG_SHORING)
        addMarker(sq, Config.Sprites.Rubble, TAG_RUBBLE)
        refresh(sq)
        if isServer() then
            pcall(function() getWorldSoundManager():addSound(nil, x, y, z, 20, 20) end)
        end
    end

    for _, p in ipairs(allPlayers()) do
        local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
        if pz == z then
            if px == x and py == y then
                -- Buried: find a free neighbour to push the player to.
                local safe = nil
                for _, d in ipairs(Utils.Directions) do
                    if System.isExcavated(x + d.dx, y + d.dy, z) then
                        safe = { x = x + d.dx, y = y + d.dy, z = z }
                        break
                    end
                end
                System.sendToClient(p, "caveIn", {
                    severity = 2, x = x, y = y, z = z,
                    safeX = safe and safe.x, safeY = safe and safe.y, safeZ = safe and safe.z,
                    trapped = (safe == nil),
                })
            elseif math.abs(px - x) <= 1 and math.abs(py - y) <= 1 then
                System.sendToClient(p, "caveIn", { severity = 1, x = x, y = y, z = z })
            end
        end
    end
    System.sync()
end

-- Rolls a collapse on unbraced tiles around (x,y,z) after noisy work.
local function shakeNeighbours(x, y, z)
    local collapsed = false
    for _, d in ipairs(Utils.Directions) do
        local nx, ny = x + d.dx, y + d.dy
        if System.rollCollapse(nx, ny, z, Config.AdjacentChanceMultiplier) then
            UndergroundCommands.collapseTile(nx, ny, z)
            collapsed = true
        end
    end
    return collapsed
end

-------------------------------------------------------------
-- Command handlers  (args always carry integer tile coords)
-------------------------------------------------------------
local Handlers = {}

local function near(player, x, y, maxDist)
    return math.abs(player:getX() - (x + 0.5)) <= maxDist and math.abs(player:getY() - (y + 0.5)) <= maxDist
end

-- Surface (Z=0) -> creates the first underground tile at Z=-1 with a
-- vertical link (shaft). The surface tile itself stays walkable; players
-- go down through the "Climb down" context option.
function Handlers.digAccess(player, args)
    local x, y = args.x, args.y
    local surface = getCell():getGridSquare(x, y, 0)
    if not surface or not Utils.isNaturalGround(surface) or not near(player, x, y, 2.5) then
        return message(player, "UI_Underground_CannotDigHere", true)
    end
    local top = System.getTile(x, y, 0)
    if top and top.shaftDown then return end

    if UndergroundCommands.excavate(x, y, -1, { shaftUp = true }) then
        System.setTile(x, y, 0, { state = STATE.REINFORCED, shaftDown = true })
        addMarker(surface, Config.Sprites.Shaft, TAG_SHAFT)
        System.sync()
        message(player, "UI_Underground_AccessDug", false)
    end
end

-- Underground -> digs a shaft one level deeper (needs a stable tile).
function Handlers.digDown(player, args)
    local x, y, z = args.x, args.y, args.z
    if z - 1 < Config.MinZ then return message(player, "UI_Underground_TooDeep", true) end
    if System.getState(x, y, z) < STATE.BRACED then
        return message(player, "UI_Underground_NeedsShoring", true)
    end
    local t = System.getTile(x, y, z)
    if t and (t.shaftDown or t.shaftUp) then return end
    if UndergroundCommands.excavate(x, y, z - 1, { shaftUp = true }) then
        System.setTile(x, y, z, { shaftDown = true })
        System.sync()
        message(player, "UI_Underground_AccessDug", false)
    end
end

-- Underground -> opens a cardinal neighbour (or clears rubble on the
-- player's own tile when target == player's tile).
function Handlers.digAdjacent(player, args)
    local x, y, z = args.x, args.y, args.z
    if z >= 0 or math.floor(player:getZ()) ~= z or System.isExcavated(x, y, z) then return end
    local px, py = math.floor(player:getX()), math.floor(player:getY())
    local fromOk = System.isExcavated(px, py, z)
    local t = System.getTile(px, py, z)
    if not fromOk and not (t and t.rubble) then return end
    if math.abs(px - x) + math.abs(py - y) > 1 then return end

    if UndergroundCommands.excavate(x, y, z) then
        System.sync()
        shakeNeighbours(x, y, z)
    end
end

function Handlers.brace(player, args)
    local x, y, z = args.x, args.y, args.z
    if System.getState(x, y, z) ~= STATE.UNBRACED then return end
    System.setTile(x, y, z, { state = STATE.BRACED, collapseChance = 0 })
    local sq = ensureSquare(x, y, z)
    if sq then addMarker(sq, Config.Sprites.Shoring, TAG_SHORING); refresh(sq) end
    System.sync()
    message(player, "UI_Underground_Braced", false)
end

function Handlers.reinforce(player, args)
    local x, y, z = args.x, args.y, args.z
    if System.getState(x, y, z) ~= STATE.BRACED then return end
    System.setTile(x, y, z, { state = STATE.REINFORCED, collapseChance = 0 })
    System.sync()
    message(player, "UI_Underground_Reinforced", false)
end

-- Sent by the client when a player walks onto an unbraced tile.
function Handlers.stepOn(player, args)
    local sq = getCell():getGridSquare(args.x, args.y, args.z)
    System.checkCaveIn(player, sq, Config.EnterChanceMultiplier)
end

function UndergroundCommands.handle(player, command, args)
    local h = Handlers[command]
    if h and player and args then h(player, args) end
end

local function onClientCommand(module, command, player, args)
    if module ~= Config.ModuleName then return end
    UndergroundCommands.handle(player, command, args)
end

Events.OnClientCommand.Add(onClientCommand)
