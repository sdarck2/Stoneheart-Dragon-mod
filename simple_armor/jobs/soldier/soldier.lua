local SoldierClass = class()
local CombatJob = require 'stonehearth.jobs.combat_job'
radiant.mixin(SoldierClass, CombatJob)
return SoldierClass