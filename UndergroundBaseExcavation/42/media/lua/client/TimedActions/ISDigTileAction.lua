--***********************************************************
--  Underground Base Excavation - ISDigTileAction.lua (client)
--  Timed action for every kind of digging:
--    mode "access"   : surface tile (Z=0) -> opens Z=-1 below it
--    mode "down"     : underground tile -> opens Z-1 below it
--    mode "adjacent" : underground, opens a neighbour (or clears rubble)
--  The world itself is changed by the server (UndergroundCommands.lua).
--***********************************************************

require "TimedActions/ISBaseTimedAction"
require "UndergroundUtils"
require "UndergroundSystem"

ISDigTileAction = ISBaseTimedAction:derive("ISDigTileAction")

local Utils  = UndergroundUtils
local Config = UndergroundUtils.Config

function ISDigTileAction:isValid()
    if not self.tool or not self.character:getInventory():containsRecursive(self.tool) then return false end
    if self.tool:isBroken() then return false end
    if self.mode == "adjacent" then
        return not UndergroundSystem.isExcavated(self.tx, self.ty, self.tz)
    elseif self.mode == "access" then
        local t = UndergroundSystem.getTile(self.tx, self.ty, 0)
        return not (t and t.shaftDown)
    elseif self.mode == "down" then
        local t = UndergroundSystem.getTile(self.tx, self.ty, self.tz)
        return not (t and t.shaftDown) and self.tz - 1 >= Config.MinZ
    end
    return true
end

function ISDigTileAction:waitToStart()
    if self.tx ~= math.floor(self.character:getX()) or self.ty ~= math.floor(self.character:getY()) then
        self.character:faceLocation(self.tx, self.ty)
    end
    return self.character:shouldBeTurning()
end

function ISDigTileAction:update()
    self.tool:setJobDelta(self:getJobDelta())
    self.character:setMetabolicTarget(Metabolics.DiggingSpade)
end

function ISDigTileAction:start()
    self.tool:setJobType(getText("UI_Underground_Digging"))
    self.tool:setJobDelta(0.0)
    self:setActionAnim(Config.Anims.Dig)
    self:setOverrideHandModels(self.tool, nil)
    self.sound = self.character:playSound(Config.Sounds.Dig)
    if self.tz < 0 and self.mode == "adjacent" then
        -- Hint that working next to unbraced earth is risky.
        for _, d in ipairs(Utils.Directions) do
            if UndergroundSystem.getState(self.tx + d.dx, self.ty + d.dy, self.tz) == UndergroundSystem.STATE.UNBRACED then
                Utils.say(self.character, "UI_Underground_Unstable", true)
                break
            end
        end
    end
end

function ISDigTileAction:stopSound()
    if self.sound and self.sound ~= 0 and self.character:getEmitter():isPlaying(self.sound) then
        self.character:stopOrTriggerSound(self.sound)
    end
end

function ISDigTileAction:stop()
    self:stopSound()
    self.tool:setJobDelta(0.0)
    ISBaseTimedAction.stop(self)
end

function ISDigTileAction:perform()
    self:stopSound()
    self.tool:setJobDelta(0.0)

    -- Physical cost of digging
    for stat, delta in pairs(Config.DigStats) do
        Utils.addStat(self.character, stat, delta)
    end
    Utils.damageTool(self.character, self.tool, Config.ToolConditionLoss)

    -- Ask the server to change the world (see UndergroundSystem.lua header).
    local commands = { access = "digAccess", down = "digDown", adjacent = "digAdjacent" }
    UndergroundSystem.sendToServer(self.character, commands[self.mode], { x = self.tx, y = self.ty, z = self.tz })

    ISBaseTimedAction.perform(self)
end

-- B42 server-side completion hook: the world edit already goes through
-- our own command, so nothing else to do here.
function ISDigTileAction:complete()
    return true
end

function ISDigTileAction:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return Utils.scaledDuration(self.character, Config.Durations[self.mode] or 500, "dig")
end

function ISDigTileAction:new(character, tool, mode, tx, ty, tz)
    local o = ISBaseTimedAction.new(self, character)
    o.tool = tool
    o.mode = mode
    o.tx, o.ty, o.tz = tx, ty, tz
    o.maxTime = o:getDuration()
    o.caloriesModifier = 8
    return o
end
