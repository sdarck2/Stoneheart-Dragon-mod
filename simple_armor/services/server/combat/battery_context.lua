local log = radiant.log.create_logger('combat')

BatteryContext = class()

-- placeholder
function BatteryContext:__init(attacker, target, damage, aggro_override)
   self.attacker = attacker
   self.target = target
   self.damage = damage
   self.aggro_override = aggro_override
end

return BatteryContext
