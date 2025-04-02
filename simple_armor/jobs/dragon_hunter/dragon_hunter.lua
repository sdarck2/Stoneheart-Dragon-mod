local DragonHunterClass = class()
local CombatJob = require 'stonehearth.jobs.combat_job'
radiant.mixin(DragonHunterClass, CombatJob)
return DragonHunterClass