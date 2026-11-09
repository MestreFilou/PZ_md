--***********************************************************
--  Underground Base Excavation - ISUseShaftAction.lua (client)
--  Short timed action to climb up or down a dug shaft.
--  Moving between Z-levels is client-authoritative in PZ (the
--  client owns its player's position), so no server command is
--  needed: we simply teleport to the linked tile.
--***********************************************************

require "TimedActions/ISBaseTimedAction"
require "UndergroundUtils"
require "UndergroundSystem"

ISUseShaftAction = ISBaseTimedAction:derive("ISUseShaftAction")

local Utils  = UndergroundUtils
local Config = UndergroundUtils.Config

function ISUseShaftAction:isValid()
    local t = UndergroundSystem.getTile(self.x, self.y, self.z)
    if not t then return false end
    if self.direction == "down" then return t.shaftDown == true end
    return t.shaftUp == true
end

function ISUseShaftAction:start()
    self:setActionAnim("Loot")
end

function ISUseShaftAction:perform()
    local dz = (self.direction == "down") and -1 or 1
    Utils.teleport(self.character, self.x, self.y, self.z + dz)
    ISBaseTimedAction.perform(self)
end

function ISUseShaftAction:complete()
    return true
end

function ISUseShaftAction:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return Config.Durations.shaft
end

-- direction: "up" or "down"; (x,y,z) is the tile holding the shaft link.
function ISUseShaftAction:new(character, x, y, z, direction)
    local o = ISBaseTimedAction.new(self, character)
    o.x, o.y, o.z = x, y, z
    o.direction = direction
    o.maxTime = o:getDuration()
    return o
end
