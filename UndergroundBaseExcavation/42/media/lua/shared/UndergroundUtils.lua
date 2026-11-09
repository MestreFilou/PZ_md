--***********************************************************
--  Underground Base Excavation - UndergroundUtils.lua (shared)
--  Configuration + small helpers used by client and server.
--  Every call into the Java API that changed between Build 41
--  and Build 42 sub-versions is wrapped in pcall so a renamed
--  method degrades gracefully instead of throwing.
--***********************************************************

UndergroundUtils = UndergroundUtils or {}

-------------------------------------------------------------
-- Configuration (tweak freely)
-------------------------------------------------------------
UndergroundUtils.Config = {
    ModuleName = "UndergroundExcavation",   -- client/server command module
    ModDataKey = "UndergroundExcavation",   -- global ModData key

    MinZ = -2,                               -- deepest level that can be dug (B42 supports down to -32)

    -- Tools accepted for digging (full types). Tag "DigGrave" is also accepted (see findDigTool).
    DigTools = {
        "Base.Shovel", "Base.Shovel2", "Base.EntrenchingTool",
        "Base.PickAxe", "Base.Pickaxe",
    },
    Hammers = { "Base.Hammer", "Base.HammerStone", "Base.BallPeenHammer", "Base.ClubHammer" },

    -- Materials
    BraceMaterials     = { { type = "Base.Plank", count = 2 }, { type = "Base.Nails", count = 4 } },
    ReinforceMaterials = { { type = "Base.Plank", count = 4 }, { type = "Base.Nails", count = 8 } },

    -- Durations in ticks (scaled down by Fitness/Strength or Carpentry)
    Durations = { access = 600, adjacent = 450, down = 700, brace = 250, reinforce = 400, shaft = 60 },

    -- Stat changes applied when a dig completes (0..1 scale)
    DigStats = { fatigue = 0.03, thirst = 0.04, hunger = 0.03, endurance = -0.15 },
    ToolConditionLoss = 1,

    -- Collapse probabilities
    DefaultCollapseChance  = 0.15,  -- stored on every freshly dug (unbraced) tile
    EnterChanceMultiplier  = 0.20,  -- chance * this when a player walks onto an unbraced tile
    AdjacentChanceMultiplier = 0.50, -- chance * this for unbraced neighbours when digging next to them
    StepCheckCooldownMs    = 10000, -- same tile is not re-rolled more often than this per player

    -- Sprites. IMPORTANT: Floor is a vanilla dirt tile. The wall/rubble/shaft sprites are
    -- placeholders: replace them with tiles from your tileset (or a custom .pack) for visuals.
    -- Wall objects are flagged in ModData so the mod can find and remove them later.
    Sprites = {
        Floor   = "blends_natural_01_64",   -- dirt
        Wall    = "underground_01_0",       -- PLACEHOLDER solid earth block
        Rubble  = "underground_01_1",       -- PLACEHOLDER rubble pile after a cave-in
        Shoring = nil,                      -- optional visual for braced tiles (nil = none)
        Shaft   = nil,                      -- optional visual for the shaft opening (nil = none)
    },

    Sounds = { Dig = "Shoveling", Hammer = "Hammering", Collapse = "HitObjectWithAxe" },
    Anims  = { Dig = "DigShovel", Build = "Build" },

    -- Surface floor sprite prefixes that count as diggable natural ground
    NaturalGroundPrefixes = { "blends_natural_01", "floors_exterior_natural_01" },
}

local Config = UndergroundUtils.Config

-------------------------------------------------------------
-- Keys / directions
-------------------------------------------------------------
function UndergroundUtils.key(x, y, z)
    return tostring(math.floor(x)) .. "_" .. tostring(math.floor(y)) .. "_" .. tostring(math.floor(z))
end

UndergroundUtils.Directions = {
    { id = "N", dx = 0,  dy = -1 },
    { id = "S", dx = 0,  dy = 1  },
    { id = "E", dx = 1,  dy = 0  },
    { id = "W", dx = -1, dy = 0  },
}

-------------------------------------------------------------
-- Environment helpers
-------------------------------------------------------------
-- True when this Lua state is allowed to change the world/ModData:
-- dedicated server, or singleplayer (no client/server split).
function UndergroundUtils.isAuthority()
    return isServer() or not isClient()
end

function UndergroundUtils.startsWith(str, prefix)
    return str ~= nil and string.sub(str, 1, string.len(prefix)) == prefix
end

function UndergroundUtils.getSpriteName(obj)
    if not obj then return nil end
    local ok, sprite = pcall(function() return obj:getSprite() end)
    if ok and sprite then
        local ok2, name = pcall(function() return sprite:getName() end)
        if ok2 then return name end
    end
    return nil
end

-- Is this surface square natural ground (grass/dirt) with nothing built on it?
function UndergroundUtils.isNaturalGround(square)
    if not square or square:getZ() ~= 0 then return false end
    if square:getBuilding() then return false end
    local okTree, hasTree = pcall(function() return square:HasTree() end)
    if okTree and hasTree then return false end
    local floor = square:getFloor()
    local name = UndergroundUtils.getSpriteName(floor)
    if not name then return false end
    for _, prefix in ipairs(Config.NaturalGroundPrefixes) do
        if UndergroundUtils.startsWith(name, prefix) then return true end
    end
    return false
end

-------------------------------------------------------------
-- Inventory helpers
-------------------------------------------------------------
local function isUsable(item)
    if not item then return false end
    local ok, broken = pcall(function() return item:isBroken() end)
    return not (ok and broken)
end

local function hasTag(item, tag)
    local ok, res = pcall(function() return item:hasTag(tag) end)
    return ok and res
end

local function findFirst(player, types, tag)
    -- Hands first, then the main inventory (recursively).
    local hands = { player:getPrimaryHandItem(), player:getSecondaryHandItem() }
    for _, item in ipairs(hands) do
        if isUsable(item) then
            for _, t in ipairs(types) do
                if item:getFullType() == t then return item end
            end
            if tag and hasTag(item, tag) then return item end
        end
    end
    local inv = player:getInventory()
    for _, t in ipairs(types) do
        local item = inv:getFirstTypeEvalRecurse(t, isUsable)
        if item then return item end
    end
    if tag then
        local ok, item = pcall(function() return inv:getFirstTagEvalRecurse(tag, isUsable) end)
        if ok and item then return item end
    end
    return nil
end

function UndergroundUtils.findDigTool(player)
    return findFirst(player, Config.DigTools, "DigGrave")
end

function UndergroundUtils.findHammer(player)
    return findFirst(player, Config.Hammers, "Hammer")
end

function UndergroundUtils.hasMaterials(player, materials)
    local inv = player:getInventory()
    for _, m in ipairs(materials) do
        if inv:getCountTypeRecurse(m.type) < m.count then return false end
    end
    return true
end

-- Removes the materials from the inventory (client side; synced in MP when possible).
function UndergroundUtils.consumeMaterials(player, materials)
    local inv = player:getInventory()
    for _, m in ipairs(materials) do
        for _ = 1, m.count do
            local item = inv:getFirstTypeRecurse(m.type)
            if item then
                local container = item:getContainer()
                container:Remove(item)
                if isClient() then
                    pcall(function() sendRemoveItemFromContainer(container, item) end)
                end
            end
        end
    end
end

function UndergroundUtils.damageTool(player, item, amount)
    if not item then return end
    item:setCondition(math.max(0, item:getCondition() - (amount or 1)))
    if isClient() then
        pcall(function() syncItemFields(player, item) end)
    end
end

-------------------------------------------------------------
-- Stats (B42.0-42.12 used setFatigue/getFatigue, later builds
-- moved to stats:get/set(CharacterStat.X); support both)
-------------------------------------------------------------
local StatMap = {
    fatigue   = { enum = "FATIGUE",   get = "getFatigue",   set = "setFatigue"   },
    thirst    = { enum = "THIRST",    get = "getThirst",    set = "setThirst"    },
    hunger    = { enum = "HUNGER",    get = "getHunger",    set = "setHunger"    },
    endurance = { enum = "ENDURANCE", get = "getEndurance", set = "setEndurance" },
}

function UndergroundUtils.addStat(player, statName, delta)
    local map = StatMap[statName]
    local stats = player and player:getStats()
    if not map or not stats then return end
    -- New API
    if CharacterStat and CharacterStat[map.enum] and stats.get and stats.set then
        local ok = pcall(function()
            local v = stats:get(CharacterStat[map.enum]) + delta
            stats:set(CharacterStat[map.enum], math.max(0, math.min(1, v)))
        end)
        if ok then return end
    end
    -- Legacy API
    pcall(function()
        local v = stats[map.get](stats) + delta
        stats[map.set](stats, math.max(0, math.min(1, v)))
    end)
end

function UndergroundUtils.perkLevel(player, perkName)
    local ok, lvl = pcall(function() return player:getPerkLevel(Perks[perkName]) end)
    return (ok and lvl) or 0
end

-- Scales a base duration: each point of Fitness+Strength (dig) or Carpentry (build)
-- shaves a few percent, never below 40% of the base time.
function UndergroundUtils.scaledDuration(player, base, kind)
    local factor
    if kind == "build" then
        factor = 1 - 0.06 * UndergroundUtils.perkLevel(player, "Woodwork")
    else
        local lvl = UndergroundUtils.perkLevel(player, "Fitness") + UndergroundUtils.perkLevel(player, "Strength")
        factor = 1 - 0.03 * lvl
    end
    return math.floor(base * math.max(0.4, factor))
end

-------------------------------------------------------------
-- Player feedback
-------------------------------------------------------------
function UndergroundUtils.say(player, textKey, red)
    if not player then return end
    local text = getText(textKey)
    if HaloTextHelper and HaloTextHelper.addText then
        local color = red and HaloTextHelper.getColorRed() or HaloTextHelper.getColorWhite()
        local ok = pcall(function() HaloTextHelper.addText(player, text, color) end)
        if ok then return end
    end
    player:Say(text)
end

-- Moves a player to the centre of a tile, on another Z-level if needed.
function UndergroundUtils.teleport(player, x, y, z)
    local tx, ty = math.floor(x) + 0.5, math.floor(y) + 0.5
    if player.teleportTo then
        local ok = pcall(function() player:teleportTo(tx, ty, z) end)
        if ok then return end
    end
    player:setX(tx); player:setY(ty); player:setZ(z)
    pcall(function() player:setLx(tx); player:setLy(ty); player:setLz(z) end)
end
