--***********************************************************
--  Underground Base Excavation - ISBraceTileAction.lua (client)
--  Installs wooden shoring on an unbraced tile (State 1 -> 2),
--  or reinforces a braced tile (State 2 -> 3) when level == "reinforce".
--***********************************************************

require "TimedActions/ISBaseTimedAction"
require "UndergroundUtils"
require "UndergroundSystem"

ISBraceTileAction = ISBaseTimedAction:derive("ISBraceTileAction")

local Utils  = UndergroundUtils
local Config = UndergroundUtils.Config
local STATE  = UndergroundSystem.STATE

function ISBraceTileAction:materials()
    return self.level == "reinforce" and Config.ReinforceMaterials or Config.BraceMaterials
end

function ISBraceTileAction:isValid()
    if not self.hammer or not self.character:getInventory():containsRecursive(self.hammer) then return false end
    if not Utils.hasMaterials(self.character, self:materials()) then return false end
    local expected = (self.level == "reinforce") and STATE.BRACED or STATE.UNBRACED
    return UndergroundSystem.getState(self.tx, self.ty, self.tz) == expected
end

function ISBraceTileAction:waitToStart()
    if self.tx ~= math.floor(self.character:getX()) or self.ty ~= math.floor(self.character:getY()) then
        self.character:faceLocation(self.tx, self.ty)
    end
    return self.character:shouldBeTurning()
end

function ISBraceTileAction:update()
    self.hammer:setJobDelta(self:getJobDelta())
    self.character:setMetabolicTarget(Metabolics.MediumWork)
end

function ISBraceTileAction:start()
    self.hammer:setJobType(getText("UI_Underground_Shoring"))
    self.hammer:setJobDelta(0.0)
    self:setActionAnim(Config.Anims.Build)
    self:setOverrideHandModels(self.hammer, nil)
    self.sound = self.character:playSound(Config.Sounds.Hammer)
end

function ISBraceTileAction:stopSound()
    if self.sound and self.sound ~= 0 and self.character:getEmitter():isPlaying(self.sound) then
        self.character:stopOrTriggerSound(self.sound)
    end
end

function ISBraceTileAction:stop()
    self:stopSound()
    self.hammer:setJobDelta(0.0)
    ISBaseTimedAction.stop(self)
end

function ISBraceTileAction:perform()
    self:stopSound()
    self.hammer:setJobDelta(0.0)
    Utils.consumeMaterials(self.character, self:materials())
    pcall(function() self.character:getXp():AddXP(Perks.Woodwork, 3) end)
    -- The server marks the tile Braced/Reinforced in ModData.
    UndergroundSystem.sendToServer(self.character, self.level, { x = self.tx, y = self.ty, z = self.tz })
    ISBaseTimedAction.perform(self)
end

function ISBraceTileAction:complete()
    return true
end

function ISBraceTileAction:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return Utils.scaledDuration(self.character, Config.Durations[self.level] or 300, "build")
end

-- level: "brace" (default) or "reinforce"
function ISBraceTileAction:new(character, hammer, tx, ty, tz, level)
    local o = ISBaseTimedAction.new(self, character)
    o.hammer = hammer
    o.tx, o.ty, o.tz = tx, ty, tz
    o.level = level or "brace"
    o.maxTime = o:getDuration()
    return o
end
