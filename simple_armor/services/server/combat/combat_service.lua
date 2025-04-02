local Point3 = _radiant.csg.Point3
local rng = _radiant.math.get_default_rng()
local log = radiant.log.create_logger('combat')

CombatService = class()

function CombatService:__init()
end

function CombatService:initialize()
   -- always stun for now
   --self._hit_stun_damage_threshold = radiant.util.get_config('hit_stun_damage_threshold', 0.10)
   self._hit_stun_damage_threshold = 0
end

-- Notify target that an attack has begun and will impact soon.
-- Target has opportunity to defend itself if it can react before the impact time.
function CombatService:begin_assault(context)
   local attacker = context.attacker
   local target = context.target
   local combat_state = self:get_combat_state(target)
   if not combat_state then
      return nil
   end

   combat_state:add_assault_event(context)

   radiant.events.trigger_async(target, 'stonehearth:combat:assault', context)
   self:_trigger_engaged_in_combat(target, attacker)
   self:_set_assaulting(attacker, true)
end

function CombatService:end_assault(context)
   local attacker = context.attacker
   local target = context.target
   local combat_state = self:get_combat_state(target)
   if combat_state then
      combat_state:remove_assault_event(context)
   end

   self:_set_assaulting(attacker, false)
   context.assault_active = false
end

function CombatService:begin_defense(context)
   context.target_defending = true
   self:_set_defending(context.target, true)
   self:_trigger_engaged_in_combat(context.target, context.attacker)
end

function CombatService:end_defense(context)
   if radiant.gamestate.now() < context.impact_time then
      -- we could just do this unconditionally, but might be useful to have the history recorded in the context
      context.target_defending = false
   end
   self:_set_defending(context.target, false)
end

-- Notify target that it has been hit by an attack.
function CombatService:battery(context)
   local attacker = context.attacker
   local target = context.target

   if not target or not target:is_valid() then
      return nil
   end

   local health = radiant.entities.get_health(target)
   local damage = context.damage

   if health ~= nil then
      if health <= 0 then
      -- if monster is already at/below 0 health, it should be considered dead so don't continue battery
         return nil
      end
      health = health - damage
      if health <= 0 then
         self:_on_target_killed(attacker, target)
      end

      -- Modify health after distributing xp and removing components,
      -- so it does not kill the entity before we have a chance to do that
      radiant.entities.modify_health(target, -damage)
   end

   radiant.events.trigger_async(attacker, 'stonehearth:combat:target_hit', context)
   radiant.events.trigger_async(target, 'stonehearth:combat:battery', context)
end

function CombatService:inflict_debuffs(attacker, target, attack_info)
   local inflictable_debuffs = self:get_inflictable_debuffs(attacker, attack_info)
   stonehearth.combat:try_inflict_debuffs(target, inflictable_debuffs)
end

-- Notify target that it has been healed by someone
function CombatService:heal(context)
   local healer = context.healer
   local target = context.target

   if not target or not target:is_valid() then
      return false
   end

   local healing = context.healing
   local health = radiant.entities.get_health(target)
   if health ~= nil then
      if health <= 0 then
      -- if target is already at/below 0 health, it should be considered dead so don't continue healing
         return false
      end
      radiant.entities.modify_health(target, healing)
   end

   radiant.events.trigger_async(healer, 'stonehearth:combat:target_healed', context)
   radiant.events.trigger_async(target, 'stonehearth:combat:healed', context)
   return true
end

-- Notify target that it is now stunned an any action in progress will be cancelled.
function CombatService:hit_stun(context)
   local target = context.target

   if not target or not target:is_valid() then
      return nil
   end

   radiant.events.trigger_async(target, 'stonehearth:combat:hit_stun', context)
end

function CombatService:get_assault_events(target)
   local combat_state = self:get_combat_state(target)
   if not combat_state then
      return nil
   end
   return combat_state:get_assault_events()
end

function CombatService:get_weapon_idle_data(entity)
   local weapon = stonehearth.combat:get_main_weapon(entity)
   if weapon ~= nil and weapon:is_valid() then
      local idle_data = radiant.entities.get_entity_data(weapon, 'stonehearth:combat:idle:ready')
      if idle_data then
         return idle_data.name
      end
   end
end

function CombatService:is_in_combat(entity)
   if not entity or not entity:is_valid() then
      return false
   end

   local combat_state = self:get_combat_state(entity)
   return combat_state:is_in_combat()
end

function CombatService:start_cooldown(entity, action_info)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return
   end
   combat_state:start_cooldown(action_info.name, action_info.cooldown)
end

function CombatService:in_cooldown(entity, action_name)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return false
   end
   return combat_state:in_cooldown(action_name)
end

function CombatService:get_cooldown_end_time(entity, action_name)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return nil
   end
   return combat_state:get_cooldown_end_time(action_name)
end

function CombatService:get_main_weapon(entity)
   return radiant.entities.get_equipped_item(entity, 'mainhand')
end

function CombatService:calculate_ranged_damage(attacker, target, attack_info)
   return self:_calculate_damage(attacker, target, attack_info, 'base_ranged_damage')
end

function CombatService:calculate_melee_damage(attacker, target, attack_info)
   return self:_calculate_damage(attacker, target, attack_info, 'base_damage')
end

-- TODO: modify to work with final design
-- TODO: should base damage be a range? Right now it is fixed by weapon.
-- TODO: refactor into combat service
function CombatService:_calculate_damage(attacker, target, attack_info, base_damage_name)
   local weapon = stonehearth.combat:get_main_weapon(attacker)

   if not weapon or not weapon:is_valid() then
      return 0
   end

   local weapon_data = radiant.entities.get_entity_data(weapon, 'stonehearth:combat:weapon_data')
   local base_damage = weapon_data[base_damage_name]

   local total_damage = base_damage
   local attributes_component = attacker:get_component('stonehearth:attributes')
   if not attributes_component then
      return total_damage
   end
   local additive_dmg_modifier = attributes_component:get_attribute('additive_dmg_modifier')
   local multiplicative_dmg_modifier = attributes_component:get_attribute('multiplicative_dmg_modifier')
   local muscle = attributes_component:get_attribute('muscle')

   if muscle then
      local muscle_dmg_modifier = muscle * stonehearth.constants.attribute_effects.MUSCLE_MELEE_MULTIPLIER
      muscle_dmg_modifier = muscle_dmg_modifier + stonehearth.constants.attribute_effects.MUSCLE_MELEE_MULTIPLIER_BASE
      additive_dmg_modifier = additive_dmg_modifier + muscle_dmg_modifier
   end

   if multiplicative_dmg_modifier then
      local dmg_to_add = base_damage * multiplicative_dmg_modifier
      total_damage = dmg_to_add + total_damage
   end
   if additive_dmg_modifier then
      total_damage = total_damage + additive_dmg_modifier
   end

   --Get damage from weapons
   if attack_info.damage_multiplier then
      total_damage = total_damage * attack_info.damage_multiplier
   end

   --Get the damage reduction from armor
   local total_armor = self:calculate_total_armor(target)

   -- Reduce armor if attacker has armor reduction attributes
   local multiplicative_target_armor_modifier = attributes_component:get_attribute('multiplicative_target_armor_modifier', 1)
   local additive_target_armor_modifier = attributes_component:get_attribute('additive_target_armor_modifier', 0)

   if attack_info.target_armor_multiplier then
      multiplicative_target_armor_modifier = multiplicative_target_armor_modifier * attack_info.target_armor_multiplier
   end

   total_armor = total_armor * multiplicative_target_armor_modifier + additive_target_armor_modifier

   local damage = total_damage - total_armor
   damage = radiant.math.round(damage)

   if attack_info.minimum_damage and damage <= attack_info.minimum_damage then
      damage = attack_info.minimum_damage
   elseif damage < 1 then
      -- if attack will do less than 1 damage, then randomly it will do either 1 or 0
      damage = rng:get_int(0, 1)
   end

   return damage
end

-- TODO: take different damage types into effect
function CombatService:calculate_total_armor(entity)
   local equipment_component = entity:get_component('stonehearth:equipment')
   local total_armor = 0

   if equipment_component then
      local items = equipment_component:get_all_items()

      for _, item in pairs(items) do
         local item_armor = radiant.entities.get_entity_data(item, 'stonehearth:combat:armor_data')
         if item_armor and item_armor.base_damage_reduction then
            total_armor = total_armor + item_armor.base_damage_reduction
         end
      end
   end

   local attributes_component = entity:get_component('stonehearth:attributes')
   if attributes_component then
      local additive_armor_modifier = attributes_component:get_attribute('additive_armor_modifier', 0)
      local multiplicative_armor_modifier = attributes_component:get_attribute('multiplicative_armor_modifier', 1)
      total_armor = radiant.math.round((total_armor + additive_armor_modifier) * multiplicative_armor_modifier)
      if total_armor < 0 then
         total_armor = 0
      end
   end

   return total_armor
end

function CombatService:calculate_healing(healer, target, heal_info)
   local weapon = stonehearth.combat:get_main_weapon(healer)
   local weapon_data = radiant.entities.get_entity_data(weapon, 'stonehearth:combat:healing_data')
   local base_healing = weapon_data.base_healing

   local total_healing = base_healing
   local attributes_component = healer:get_component('stonehearth:attributes')
   if not attributes_component then
      return total_healing
   end
   local additive_heal_modifier = attributes_component:get_attribute('additive_heal_modifier')
   local multiplicative_heal_modifier = attributes_component:get_attribute('multiplicative_heal_modifier')
   local compassion = attributes_component:get_attribute('compassion')

   if compassion then
      local compassion_heal_modifier = compassion * stonehearth.constants.attribute_effects.COMPASSION_HEAL_MULTIPLIER
      additive_heal_modifier = additive_heal_modifier + compassion_heal_modifier
   end

   if multiplicative_heal_modifier then
      local healing_to_add = base_healing * multiplicative_heal_modifier
      total_healing = healing_to_add + total_healing
   end
   if additive_heal_modifier then
      total_healing = total_healing + additive_heal_modifier
   end

   --Get damage from weapons
   if heal_info.bonus_healing_multiplier then
      local healing_to_add = base_healing * heal_info.bonus_healing_multiplier
      total_healing = healing_to_add + total_healing
   end

   total_healing = radiant.math.round(total_healing)

   return total_healing
end

function CombatService:calculate_aggro_override(damage, attack_info)
   local override = damage
   local has_override = false

   if attack_info.aggro_multiplier then
      override = override * attack_info.aggro_multiplier
      has_override = true
   end

   if attack_info.aggro_addition then
      override = attack_info.aggro_addition + override
      has_override = true
   end

   if has_override then
      return override
   end

   return nil
end

function CombatService:get_melee_range(attacker, weapon_data, target)
   local weapon_reach = weapon_data.reach
   if not weapon_reach then
      return nil, nil
   end

   local attacker_reach = self:get_entity_reach(attacker)
   local target_radius = self:get_entity_radius(target)
   local melee_range_ideal = attacker_reach + weapon_reach + target_radius
   local melee_range_max = melee_range_ideal + 2

   log:detail('attacker %s reach is %.2f (weapon reach:%.2f)', attacker, attacker_reach, weapon_reach)
   log:detail('target %s radius is %.2f', target, target_radius)
   log:detail('ideal range:%.2f   max range:%.2f', melee_range_ideal, melee_range_max)

   return melee_range_ideal, melee_range_max
end

function CombatService:get_entity_reach(entity)
   local entity_reach = 0

   if entity and entity:is_valid() then
      entity_reach = radiant.entities.get_entity_data(entity, 'stonehearth:entity_reach')
      if not entity_reach then
         log:info('%s does not have entity data stonehearth:entity_reach. Using default', entity)
         entity_reach = 1.0
      end
   end

   return entity_reach
end

function CombatService:get_entity_radius(entity)
   local entity_radius = 0

   if entity and entity:is_valid() then
      entity_radius = radiant.entities.get_entity_data(entity, 'stonehearth:entity_radius')
      if not entity_radius then
         log:info('%s does not have entity data stonehearth:entity_radius. Using default.', entity)
         entity_radius = 0.5
      end
   end

   return entity_radius
end

function CombatService:get_inflictable_debuffs(entity, attack_info)
   local entity_data = radiant.entities.get_entity_data(entity, 'stonehearth:buffs')
   local debuff_list = {}
   if entity_data and entity_data.inflictable_debuffs then
      table.insert(debuff_list, entity_data.inflictable_debuffs)
   end
   if attack_info and attack_info.inflictable_debuffs then
      table.insert(debuff_list, attack_info.inflictable_debuffs)
   end

   local equipment_component = entity:get_component('stonehearth:equipment')
   if equipment_component then
      -- Look through all equipment to see if any equipment can inflict debuffs
      local items = equipment_component:get_all_items()

      for _, item in pairs(items) do
         local item_buff_data = radiant.entities.get_entity_data(item, 'stonehearth:buffs')
         if item_buff_data and item_buff_data.inflictable_debuffs then
            table.insert(debuff_list, item_buff_data.inflictable_debuffs)
         end
      end
   end

   return debuff_list
end

function CombatService:try_inflict_debuffs(target, debuff_list)
   for i, debuff_data in ipairs(debuff_list) do
      for name, debuff in pairs(debuff_data) do
         local infliction_chance = debuff.chance or 1
         local n = 100 * infliction_chance
         local i = rng:get_int(1,100)
         if i <= n then
            target:add_component('stonehearth:buffs'):add_buff(debuff.uri)
         end
      end
   end
end

-- duration is in milliseconds at game speed 1
function CombatService:set_timer(reason, duration, fn)
   local game_seconds = stonehearth.calendar:realtime_to_game_seconds(duration, true)
   return stonehearth.calendar:set_timer(reason, game_seconds, fn)
end

function CombatService:get_primary_target(entity)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return nil
   end
   return combat_state:get_primary_target()
end

function CombatService:set_primary_target(entity, target)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return
   end
   combat_state:set_primary_target(target)

   if target then
      local party = radiant.entities.get_party(entity)
      if party then
         radiant.events.trigger_async(party, 'stonehearth:combat:target_acquired', {
               attacker = entity,
               target = target
            })
      end
   end
end

function CombatService:get_assaulting(entity)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return false
   end
   return combat_state:get_assaulting()
end

-- external parties should be using the begin_assault and end_assault methods
function CombatService:_set_assaulting(entity, assaulting)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return
   end
   combat_state:set_assaulting(assaulting)
end

function CombatService:get_defending(entity)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return false
   end
   return combat_state:get_defending()
end

-- external parties should be using the begin_defense and end_defense methods
function CombatService:_set_defending(entity, defending)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return
   end
   return combat_state:set_defending(defending)
end

function CombatService:get_assisting(entity)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return false
   end
   return combat_state:get_assisting()
end

function CombatService:set_assisting(entity, assisting)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return
   end
   return combat_state:set_assisting(assisting)
end

function CombatService:is_busy(entity)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return false
   end

   return combat_state:get_assaulting() or combat_state:get_defending() or combat_state:get_assisting()
end

function CombatService:get_stance(entity)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return nil
   end
   return combat_state:get_stance()
end

function CombatService:set_stance(entity, stance)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return
   end
   return combat_state:set_stance(stance)
end

function CombatService:get_panicking_from(entity)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return nil
   end
   return combat_state:get_panicking_from()
end

function CombatService:set_panicking_from(entity, threat)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return
   end
   combat_state:set_panicking_from(threat)
   self:_trigger_engaged_in_combat(entity, threat)
end

function CombatService:panicking(entity)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return false
   end
   return combat_state:panicking()
end

function CombatService:get_combat_state(entity)
   if not entity or not entity:is_valid() then
      return nil
   end

   return entity:add_component('stonehearth:combat_state')
end

function CombatService:get_combat_actions(entity, action_type)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return nil
   end
   return combat_state:get_combat_actions(action_type)
end

function CombatService:get_equipment_data(entity, tag)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return false
   end
   return combat_state:get_equipment_data(tag)
end

function CombatService:is_killable_target_of_type(entity, target_type)
   if not entity or not entity:is_valid() then
      return false
   end

   local entity_data = radiant.entities.get_entity_data(entity, 'stonehearth:killable')
   local attributes_component = entity:get_component('stonehearth:attributes')
   if not entity_data or not attributes_component then
      return false --can't kill if doesn't have kill data/no attributes
   end

   if not entity_data.target_type == target_type then
      return false -- entity can't kill this type of target
   end

   local health = radiant.entities.get_health(entity)
   return health and health > 0
end

-- Can this entity target this type of target?
function CombatService:entity_can_target_type(entity, target_type)
   if not entity or not entity:is_valid() then
      return false
   end

   if not target_type then
      log:warning('entity %s checking if it can target target_type but target_type is nil.', entity)
   end

   local can_target_data = self:get_equipment_data(entity, 'stonehearth:combat:can_target')
   if can_target_data and next(can_target_data) then
      if can_target_data[target_type] == true then
         return true
      end
   end

   return false
end

-- get the highest priority action that is ready now
-- assumes actions are sorted by descending priority
function CombatService:choose_attack_action(entity, actions)
   local filter_fn = function(combat_state, action_info)
      return not combat_state:in_cooldown(action_info.name)
   end
   return self:_choose_combat_action(entity, actions, filter_fn)
end

-- get the highest priority action that can take effect before the impact_time
-- assumes actions are sorted by descending priority
function CombatService:choose_defense_action(entity, actions, attack_impact_time)
   local filter_fn = function(combat_state, action_info)
      local ready_time = combat_state:get_cooldown_end_time(action_info.name) or radiant.gamestate.now()
      local defense_impact_time = ready_time + action_info.time_to_impact
      return defense_impact_time <= attack_impact_time
   end
   return self:_choose_combat_action(entity, actions, filter_fn)
end

-- assumes actions are sorted by descending priority
function CombatService:_choose_combat_action(entity, actions, filter_fn)
   local combat_state = self:get_combat_state(entity)
   local candidates = {}
   local priority = nil

   for _, action_info in ipairs(actions) do
      if filter_fn(combat_state, action_info) then
         if not priority or action_info.priority == priority then
            -- add the available action and any other actions at the same priority
            table.insert(candidates, action_info)
            priority = action_info.priority
         else
            -- lower priority action, nothing else to find (recall that actions is sorted by priority)
            assert(action_info.priority < priority)
            break
         end
      end
   end

   local num_candidates = #candidates

   if num_candidates == 0 then
      return nil
   end

   local roll = rng:get_int(1, num_candidates)
   return candidates[roll]
end

-- Split exp among attacking player's combat units
function CombatService:distribute_exp(attacker, target)

   if stonehearth.player:is_npc(attacker) then
      -- no exp for npc players
      return
   end

   local attacker_player_id = radiant.entities.get_player_id(attacker)
   local target_player_id = radiant.entities.get_player_id(target)

   local attributes_component = target:get_component('stonehearth:attributes')
   local exp = attributes_component:get_attribute('exp_reward') or 0 -- exp given from killing target, default is 0
   if exp == 0 then -- if target gives no exp, no need to continue
      return
   end

   -- if player's citizen killed an enemy target then reward xp to nearby combat units
   if attacker_player_id ~= target_player_id then
      -- Get all combat units that we should give xp to
      local combat_units, num_nearby_combatants = self:_get_nearby_non_max_level_combat_units(target, attacker, attacker_player_id)
      if num_nearby_combatants <= 0 then
         num_nearby_combatants = 1
      end
      exp = math.floor(exp) -- TODO(yshan): SHOULD we split exp reward with all nearby combat units? We tried it and xp was too low.
      for _, combat_unit in pairs(combat_units) do
         local job_component = combat_unit:get_component('stonehearth:job')
         job_component:add_exp(exp)
         radiant.events.trigger_async(combat_unit, 'stonehearth:combat_exp_awarded', {exp_awarded = exp, attacker = attacker, target = target})
      end
   end
end

function CombatService:_get_nearby_units(target, attacker, player_id)
   local radius = stonehearth.constants.exp.EXP_REWARD_RADIUS
   local enemy_location = radiant.entities.get_world_grid_location(target)
   local ally_location = radiant.entities.get_world_grid_location(attacker)

   -- check all citizens in population of player and return all combats units within the radius
   local population = stonehearth.population:get_population(player_id)
   local units = {}
   local count = 0
   for id, citizen in population:get_citizens():each() do
      if citizen and citizen:is_valid() then
         local job_component = citizen:get_component('stonehearth:job')
         -- should the citizen be counted as participating?

         local location = radiant.entities.get_world_grid_location(citizen)
         -- Allow unit to participate if the combat unit is in range of the enemy or allied attacker OR
         -- the combat unit has the enemy in its target table -> ranged attackers may be far away but
         -- still may have contributed to killing the target.
         if location then
            local target_table = radiant.entities.get_target_table(citizen, 'aggro')
            if (target_table and target_table:contains(target)) or
               radiant.math.point_within_sphere(location, enemy_location, radius) or
               radiant.math.point_within_sphere(location, ally_location, radius) then
               units[id] = citizen
               count = count + 1
            end
         end
      end
   end
   return units, count
end

function CombatService:_get_nearby_non_max_level_combat_units(target, attacker, player_id)
   local units, _ = self:_get_nearby_units(target, attacker, player_id)
   local count = 0
   local combat_units = {}

   for id, unit in pairs(units) do
      local job_component = unit:get_component('stonehearth:job')
      if not job_component:is_max_level() and job_component:has_role('combat') then
         combat_units[id] = unit
         count = count + 1
      end
   end

   return combat_units, count
end

function CombatService:_notify_combat_participants(attacker, target)
   local attacker_player_id = radiant.entities.get_player_id(attacker)
   local target_player_id = radiant.entities.get_player_id(target)

   -- only alert when slain is not on the attacker's team
   if attacker_player_id ~= target_player_id then
      -- Get all units that participated in combat
      local units = self:_get_nearby_units(target, attacker, attacker_player_id)

      for _, unit in pairs(units) do
         radiant.events.trigger_async(unit, 'stonehearth:combat_participated', { attacker = attacker, target = target })
      end
   end
end

function CombatService:_handle_loot_drop(attacker, target)
   local is_attacker_npc = stonehearth.player:is_npc(attacker)
   local is_target_npc = stonehearth.player:is_npc(target)
   if is_attacker_npc and is_target_npc then
      target:remove_component('stonehearth:loot_drops')
   elseif not is_attacker_npc then
      local loot_drops_component = target:get_component('stonehearth:loot_drops')
      if loot_drops_component then
         local player_id = radiant.entities.get_player_id(attacker)
         loot_drops_component:set_auto_loot_player_id(player_id)
      end
   end
end

function CombatService:_on_target_killed(attacker, target)
   self:distribute_exp(attacker, target)
   self:_notify_combat_participants(attacker, target)
   self:_handle_loot_drop(attacker, target)
end

-- Let entity population know that one of it's entities is engaged in combat
function CombatService:_trigger_engaged_in_combat(entity, target)
   if not target then
      return
   end
   local player_id = radiant.entities.get_player_id(entity)
   local population = stonehearth.population:get_population(player_id)
   if population then
      radiant.events.trigger_async(population, 'stonehearth:population:engaged_in_combat', { entity = target, entity_id = target:get_id() })
   end
end

-- Try to maintain the condition that if A can see B then B can see A.
function CombatService:has_line_of_sight(attacker, target)
   local result = _physics:has_line_of_sight(attacker, target)
   return result
end

function CombatService:get_weapon_range(attacker, weapon)
   local weapon_data = radiant.entities.get_entity_data(weapon, 'stonehearth:combat:weapon_data')
   radiant.assert(weapon_data.range, 'no range on weapon data for weapon %s', weapon)
   local range = weapon_data.range
   local range_modifier = radiant.entities.get_attribute(attacker, 'additive_weapon_range_modifier', 0)
   return range + range_modifier
end

function CombatService:in_range(attacker, target, weapon)
   if not (target and target:is_valid()) then
      return false
   end

   local attacker_location = attacker:add_component('mob'):get_world_grid_location()
   local target_location = target:add_component('mob'):get_world_grid_location()
   if not (attacker_location and target_location) then
      return false
   end

   local distance = attacker_location:distance_to(target_location)
   local range = self:get_weapon_range(attacker, weapon)
   local result = distance <= range
   return result
end

function CombatService:in_range_and_has_line_of_sight(attacker, target, weapon)
   if not self:in_range(attacker, target, weapon) then
      return false
   end

   if not self:has_line_of_sight(attacker, target) then
      return false
   end

   return true
end

function CombatService:get_default_defense_radius()
   return stonehearth.terrain:get_default_sight_radius() / 2
end

function CombatService:get_default_defense_radius_command(session, response)
   response:resolve({ radius = self:get_default_defense_radius() })
end

function CombatService:set_leash(entity, center, range)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return
   end
   combat_state:_set_leash(center, range)
end

function CombatService:leash_to_defense_zone(entity, defense_zone)
   if defense_zone and defense_zone:is_valid() then
      local combat_state = self:get_combat_state(entity)
      if not combat_state then
         return
      end
      combat_state:_leash_to_defense_zone(defense_zone)
   end
end

function CombatService:set_defense_zone_leash(defense_zone, range, enable_visualization)
   if defense_zone and defense_zone:is_valid() then
      local defense_zone_component = defense_zone:add_component('stonehearth:defense_zone')
      defense_zone_component:create_leash(range)
      if enable_visualization ~= nil then
         defense_zone_component:set_enable_visualization(enable_visualization)
      end
   end
end

function CombatService:clear_defense_zone_leash(defense_zone)
   if defense_zone and defense_zone:is_valid() then
      defense_zone:remove_component('stonehearth:defense_zone')
   end
end

function CombatService:leash_to_defense_zone(entity, defense_zone)
   if defense_zone and defense_zone:is_valid() then
      local combat_state = self:get_combat_state(entity)
      if not combat_state then
         return
      end
      combat_state:_leash_to_defense_zone(defense_zone)
   end
end

function CombatService:update_defense_zone_leash_area(entity)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return
   end
   combat_state:update_defense_zone_leash_area()
end

-- TODO: Reconcile combat leashes with LeashComponent
-- Do not manually test leash proximity using center and range. Leashes are square and
-- don't use euclidian distance metrics. Use the methods:
--    is_point_outside_leash()
--    is_entity_outside_leash()
--    get_distance_outside_leash()
function CombatService:get_leash_data(entity)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return nil, nil
   end
   return combat_state:get_leash_data()
end

function CombatService:has_leash(entity)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return false
   end
   local leash = combat_state:get_leash_data()
   return leash ~= nil
end

function CombatService:clear_leash(entity)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return
   end
   combat_state:_clear_leash()
end

-- Leashes are now square so that the defended area meshes neatly with
-- walls, fences, and buildings
function CombatService:is_point_outside_leash(entity, point)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return false
   end
   local leash = combat_state:get_leash_data()
   if not leash then
      return false
   end

   local delta = point - leash.center
   local range = leash.range

   local dx = math.abs(delta.x)
   if dx > range then
      return true
   end

   local dz = math.abs(delta.z)
   if dz > range then
      return true
   end

   return false
end

function CombatService:is_entity_outside_leash(entity)
   local location = radiant.entities.get_world_grid_location(entity)
   return self:is_point_outside_leash(entity, location)
end

function CombatService:get_distance_outside_leash(entity, point)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return 0
   end
   local leash = combat_state:get_leash_data()
   if not leash then
      return 0
   end

   local projected_point = Point3(point)
   projected_point.y = leash.center.y
   local closest_point = leash.cube:get_closest_point(projected_point)
   return closest_point:distance_to(point)
end

return CombatService
