--***********************************************************
--  Underground Base Excavation - ISDigUndergroundMenu.lua (client)
--  Right-click options:
--   Surface (Z=0)  : Dig Underground Access / Climb Down
--   Underground    : Excavate Adjacent Tile (N/S/E/W), Clear Rubble,
--                    Erect Wooden Shoring, Reinforce, Dig Shaft Deeper,
--                    Climb Up / Climb Down
--  Underground options are built from the player's own tile, because
--  unexcavated squares below ground often do not exist yet and so
--  cannot be right-clicked.
--***********************************************************

require "ISUI/ISWorldObjectContextMenu"
require "UndergroundUtils"
require "UndergroundSystem"
require "TimedActions/ISDigTileAction"
require "TimedActions/ISBraceTileAction"
require "TimedActions/ISUseShaftAction"

ISDigUndergroundMenu = ISDigUndergroundMenu or {}

local Utils  = UndergroundUtils
local Config = UndergroundUtils.Config
local STATE  = UndergroundSystem.STATE

-------------------------------------------------------------
-- Helpers
-------------------------------------------------------------
local function equip(player, item)
    if not item then return end
    if player:getPrimaryHandItem() ~= item then
        ISTimedActionQueue.add(ISEquipWeaponAction:new(player, item, 50, true, item:isTwoHandWeapon()))
    end
end

local function materialsText(materials)
    local parts = {}
    for _, m in ipairs(materials) do
        local name = getItemNameFromFullType(m.type) or m.type
        table.insert(parts, tostring(m.count) .. " x " .. name)
    end
    return table.concat(parts, ", ")
end

local function disable(option, textKey, extra)
    option.notAvailable = true
    local tip = ISWorldObjectContextMenu.addToolTip()
    tip.description = getText(textKey) .. (extra and (" " .. extra) or "")
    option.toolTip = tip
end

local function clickedSquare(worldobjects)
    for _, obj in ipairs(worldobjects) do
        local sq = obj:getSquare()
        if sq then return sq end
    end
    return nil
end

-------------------------------------------------------------
-- Callbacks
-------------------------------------------------------------
function ISDigUndergroundMenu.onDigAccess(worldobjects, player, square, tool)
    if luautils.walkAdj(player, square, true) then
        equip(player, tool)
        ISTimedActionQueue.add(ISDigTileAction:new(player, tool, "access", square:getX(), square:getY(), 0))
    end
end

function ISDigUndergroundMenu.onDig(worldobjects, player, tool, mode, x, y, z)
    equip(player, tool)
    ISTimedActionQueue.add(ISDigTileAction:new(player, tool, mode, x, y, z))
end

function ISDigUndergroundMenu.onBrace(worldobjects, player, hammer, x, y, z, level)
    equip(player, hammer)
    ISTimedActionQueue.add(ISBraceTileAction:new(player, hammer, x, y, z, level))
end

function ISDigUndergroundMenu.onShaft(worldobjects, player, square, direction)
    if square:getZ() == 0 and not luautils.walkAdj(player, square, true) then return end
    if square:getZ() == 0 then
        -- Step onto the opening itself before climbing down.
        ISTimedActionQueue.add(ISWalkToTimedAction:new(player, square))
    end
    ISTimedActionQueue.add(ISUseShaftAction:new(player, square:getX(), square:getY(), square:getZ(), direction))
end

-------------------------------------------------------------
-- Menu builders
-------------------------------------------------------------
local function addSurfaceOptions(context, worldobjects, player, square, tool)
    local tile = UndergroundSystem.getTile(square:getX(), square:getY(), 0)
    if tile and tile.shaftDown then
        context:addOption(getText("UI_Underground_Menu_ClimbDown"), worldobjects,
            ISDigUndergroundMenu.onShaft, player, square, "down")
        return
    end
    if not Utils.isNaturalGround(square) then return end
    local opt = context:addOption(getText("UI_Underground_Menu_DigAccess"), worldobjects,
        ISDigUndergroundMenu.onDigAccess, player, square, tool)
    if not tool then disable(opt, "UI_Underground_Tip_NeedDigTool") end
end

local function addUndergroundOptions(context, worldobjects, player, tool, hammer)
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    local here = UndergroundSystem.getTile(px, py, pz)

    -- Shaft links
    if here and here.shaftUp then
        context:addOption(getText("UI_Underground_Menu_ClimbUp"), worldobjects,
            ISDigUndergroundMenu.onShaft, player, player:getCurrentSquare(), "up")
    end
    if here and here.shaftDown then
        context:addOption(getText("UI_Underground_Menu_ClimbDown"), worldobjects,
            ISDigUndergroundMenu.onShaft, player, player:getCurrentSquare(), "down")
    end

    local hereState = UndergroundSystem.getState(px, py, pz)

    -- Buried under rubble: the only way out is to dig it away.
    if here and here.rubble and hereState == STATE.UNEXCAVATED then
        local opt = context:addOption(getText("UI_Underground_Menu_ClearRubble"), worldobjects,
            ISDigUndergroundMenu.onDig, player, tool, "adjacent", px, py, pz)
        if not tool then disable(opt, "UI_Underground_Tip_NeedDigTool") end
    end

    -- Excavate adjacent tiles
    if hereState >= STATE.UNBRACED or (here and here.rubble) then
        local sub = nil
        for _, d in ipairs(Utils.Directions) do
            local nx, ny = px + d.dx, py + d.dy
            if not UndergroundSystem.isExcavated(nx, ny, pz) then
                if not sub then
                    local parent = context:addOption(getText("UI_Underground_Menu_ExcavateAdjacent"), worldobjects, nil)
                    sub = ISContextMenu:getNew(context)
                    context:addSubMenu(parent, sub)
                end
                local opt = sub:addOption(getText("UI_Underground_Menu_Dir_" .. d.id), worldobjects,
                    ISDigUndergroundMenu.onDig, player, tool, "adjacent", nx, ny, pz)
                if not tool then disable(opt, "UI_Underground_Tip_NeedDigTool") end
            end
        end
    end

    -- Shoring / reinforcing: own tile + cardinal neighbours
    local candidates = { { id = "Here", dx = 0, dy = 0 } }
    for _, d in ipairs(Utils.Directions) do table.insert(candidates, d) end

    local braceSub, reinforceSub = nil, nil
    for _, d in ipairs(candidates) do
        local nx, ny = px + d.dx, py + d.dy
        local state = UndergroundSystem.getState(nx, ny, pz)
        local label = getText("UI_Underground_Menu_Dir_" .. d.id)
        if state == STATE.UNBRACED then
            if not braceSub then
                local parent = context:addOption(getText("UI_Underground_Menu_Brace"), worldobjects, nil)
                braceSub = ISContextMenu:getNew(context)
                context:addSubMenu(parent, braceSub)
            end
            local opt = braceSub:addOption(label, worldobjects, ISDigUndergroundMenu.onBrace, player, hammer, nx, ny, pz, "brace")
            if not hammer then
                disable(opt, "UI_Underground_Tip_NeedHammer")
            elseif not Utils.hasMaterials(player, Config.BraceMaterials) then
                disable(opt, "UI_Underground_Tip_NeedMaterials", materialsText(Config.BraceMaterials))
            end
        elseif state == STATE.BRACED then
            if not reinforceSub then
                local parent = context:addOption(getText("UI_Underground_Menu_Reinforce"), worldobjects, nil)
                reinforceSub = ISContextMenu:getNew(context)
                context:addSubMenu(parent, reinforceSub)
            end
            local opt = reinforceSub:addOption(label, worldobjects, ISDigUndergroundMenu.onBrace, player, hammer, nx, ny, pz, "reinforce")
            if not hammer then
                disable(opt, "UI_Underground_Tip_NeedHammer")
            elseif not Utils.hasMaterials(player, Config.ReinforceMaterials) then
                disable(opt, "UI_Underground_Tip_NeedMaterials", materialsText(Config.ReinforceMaterials))
            end
        end
    end

    -- Dig a shaft one level deeper
    if hereState >= STATE.UNBRACED and not (here and here.shaftDown) and not (here and here.shaftUp)
        and pz - 1 >= Config.MinZ then
        local opt = context:addOption(getText("UI_Underground_Menu_DigDown"), worldobjects,
            ISDigUndergroundMenu.onDig, player, tool, "down", px, py, pz)
        if not tool then
            disable(opt, "UI_Underground_Tip_NeedDigTool")
        elseif hereState < STATE.BRACED then
            disable(opt, "UI_Underground_Tip_NeedShoringFirst")
        end
    end
end

-------------------------------------------------------------
-- Event
-------------------------------------------------------------
function ISDigUndergroundMenu.onFillWorldObjectContextMenu(playerNum, context, worldobjects, test)
    if test and ISWorldObjectContextMenu.Test then return true end
    local player = getSpecificPlayer(playerNum)
    if not player or player:getVehicle() then return end

    local tool   = Utils.findDigTool(player)
    local hammer = Utils.findHammer(player)

    if player:getZ() < 0 then
        addUndergroundOptions(context, worldobjects, player, tool, hammer)
    else
        local square = clickedSquare(worldobjects)
        if square and square:getZ() == 0 then
            addSurfaceOptions(context, worldobjects, player, square, tool)
        end
    end
end

Events.OnFillWorldObjectContextMenu.Add(ISDigUndergroundMenu.onFillWorldObjectContextMenu)
