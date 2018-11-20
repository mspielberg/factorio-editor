local BaseEditor = {}
local serpent = require "serpent"

---------------------------------------------------------------------------------------------------
-- Abstract methods to be overridden by subclasses

function BaseEditor:is_valid_aboveground_surface(surface)
  return surface.name == "nauvis"
    or surface.name:match("^Nauvis plus ")
end

---------------------------------------------------------------------------------------------------
-- surface handling

local function editor_autoplace_control()
  for control in pairs(game.autoplace_control_prototypes) do
    if control:find("dirt") then
      return control
    end
  end
end

local function editor_surface_name(self, aboveground_surface_name)
  if aboveground_surface_name == "nauvis" then
    return self.name
  end
  return self.name.."-"..aboveground_surface_name
end

local function create_editor_surface(self, name)
  local autoplace_control = editor_autoplace_control()
  local autoplace_controls, tile_settings
  if autoplace_control then
    autoplace_controls = {
      [autoplace_control] = {
        frequency = "very-low",
        size = "very-high",
      }
    }
  else
    tile_settings = {
      ["sand-1"] = {
        frequency = "very-low",
        size = "very-high",
      }
    }
  end
  local surface = game.create_surface(
    name,
    {
      starting_area = "none",
      water = "none",
      cliff_settings = { cliff_elevation_0 = 1024 },
      default_enable_all_autoplace_controls = false,
      autoplace_controls = autoplace_controls,
      autoplace_settings = {
        decorative = { treat_missing_as_default = false },
        entity = { treat_missing_as_default = false },
        tile = { treat_missing_as_default = false, settings = tile_settings },
      },
    }
  )
  surface.daytime = 0.35
  surface.freeze_daytime = true
end

local _editor_surface_cache = {}
function BaseEditor:editor_surface_for_aboveground_surface(aboveground_surface)
  local underground_surface = _editor_surface_cache[aboveground_surface]
  if not underground_surface then
    if not self:is_valid_aboveground_surface(aboveground_surface) then return nil end
    local underground_surface_name = editor_surface_name(self, aboveground_surface.name)
    if not game.surfaces[underground_surface_name] then
      create_editor_surface(self, underground_surface_name)
    end
    underground_surface = game.surfaces[underground_surface_name]
    _editor_surface_cache[aboveground_surface] = underground_surface
  end
  return underground_surface
end

local function aboveground_surface_name(self, underground_surface_name)
  if underground_surface_name == self.name then
    return "nauvis"
  end
  return underground_surface_name:sub(#self.name + 2)
end

local _aboveground_surface_cache = {}
function BaseEditor:aboveground_surface_for_editor_surface(editor_surface)
  local surface = _aboveground_surface_cache[editor_surface]
  if not surface then
    local surface_name = aboveground_surface_name(self, editor_surface.name)
    surface = game.surfaces[surface_name]
    _aboveground_surface_cache[editor_surface] = surface
  end
  return surface
end

function BaseEditor:is_editor_surface(surface)
  return surface.name:find("^"..self.name) ~= nil
end

local function counterpart_surface(self, surface)
  if self:is_editor_surface(surface) then
    return self:aboveground_surface_for_editor_surface(surface)
  else
    return self:editor_surface_for_aboveground_surface(surface)
  end
end

---------------------------------------------------------------------------------------------------
-- player/character handling

local function move_player_to_editor(self, player)
  local success = player.clean_cursor()
  if not success then return end
  local player_index = player.index
  local underground_surface = self:editor_surface_for_aboveground_surface(player.surface)
  self.player_state[player_index] = {
    position = player.position,
    surface = player.surface,
    character = player.character,
  }
  player.character = nil
  player.teleport(player.position, underground_surface)
end

local function return_player_from_editor(self, player)
  local player_index = player.index
  local state = self.player_state[player_index]
  player.teleport(state.position, state.surface)
  if state.character then
    player.character = state.character
  end
  self.player_state[player_index] = nil
end

function BaseEditor:toggle_editor_status_for_player(player_index)
  local player = game.players[player_index]
  local surface = player.surface
  if self:is_editor_surface(surface) then
    return_player_from_editor(self, player)
  elseif self:is_valid_aboveground_surface(surface) then
    move_player_to_editor(self, player)
  else
    player.print({self.name.."-error.bad-surface-for-editor"})
  end
end

---------------------------------------------------------------------------------------------------
-- inventory handling

local _is_item_prototype_valid_for_editor_cache = {}
local function is_item_prototype_valid_for_editor(self, item_prototype)
  local is_valid = _is_item_prototype_valid_for_editor_cache[item_prototype]
  if is_valid == nil then
    is_valid = false
    local place_result = item_prototype.place_result
    local entity_type = place_result and place_result.type
    if entity_type then
      for _, valid_type in ipairs(self.valid_editor_types) do
        if entity_type == valid_type then
          is_valid = true
          break
        end
      end
    end
    _is_item_prototype_valid_for_editor_cache[item_prototype] = is_valid
  end
  return is_valid
end

local function is_item_valid_for_editor(self, name)
  return is_item_prototype_valid_for_editor(self, game.item_prototypes[name])
end

local function is_stack_valid_for_editor(self, stack)
  return is_item_valid_for_editor(self, stack.name)
end

local _valid_editor_items_cache
local function valid_editor_items(self)
  if not _valid_editor_items_cache then
    _valid_editor_items_cache = {}
    for name, proto in pairs(game.item_prototypes) do
      if is_item_prototype_valid_for_editor(self, proto) then
        _valid_editor_items_cache[name] = true
      end
    end
  end
  return _valid_editor_items_cache
end

local function sync_player_inventory(self, character, player)
  for name in pairs(valid_editor_items(self)) do
    local character_count = character.get_item_count(name)
    local player_count = player.get_item_count(name)
    if character_count > player_count then
      player.insert{name = name, count = character_count - player_count}
    elseif character_count < player_count and not player.cheat_mode then
      player.remove_item{name = name, count = player_count - character_count}
    end
  end
end

local function sync_player_inventories(self)
  for player_index, state in pairs(self.player_state) do
    local character = state.character
    if character then
      local player = game.players[player_index]
      if player.connected then
        sync_player_inventory(self, character, player)
      end
    end
  end
end

local transport_line_counts = {
  ["loader"] = 2,
  ["splitter"] = 8,
  ["transport-belt"] = 2,
  ["underground-belt"] = 4,
}

local function return_transport_line_to_buffer(tl, buffer)
  for j=1,#tl do
    buffer.insert(tl[j])
  end
  tl.clear()
end

local function return_contents_to_buffer(entity, buffer)
  local n = transport_line_counts[entity.type]
  if n then
    for i=1,n do
      return_transport_line_to_buffer(entity.get_transport_line(i), buffer)
    end
  end
end

---------------------------------------------------------------------------------------------------
-- ghost handling

local function proxy_name(self, name)
  return self.proxy_prefix..name
end

local function nonproxy_name(self, name)
  local prefix = self.proxy_prefix
  if name:sub(1, #prefix) ~= prefix then
    return nil
  end
  return name:sub(#prefix+1)
end

local function has_proxy(self, name)
  return game.entity_prototypes[proxy_name(self, name)] ~= nil
end

--- Inserts stack into character's inventory or spills it at the character's position.
-- @param stack SimpleItemStack
function BaseEditor.return_to_character_or_spill(player, character, stack)
  local inserted = character.insert(stack)
  if inserted < stack.count then
    player.print({"inventory-restriction.player-inventory-full", game.item_prototypes[stack.name].localised_name})
    character.surface.spill_item_stack(
      character.position,
      {name = stack.name, count = stack.count - inserted})
  end
  return inserted
end

function BaseEditor:return_buffer_to_character(player_index, character, buffer)
  local player = game.players[player_index]
  for i=1,#buffer do
    local stack = buffer[i]
    if stack.valid_for_read then
      local inserted = self.return_to_character_or_spill(player, character, stack)
      if is_stack_valid_for_editor(self, stack) then
        -- match editor player inventory to character inventory
        stack.count = inserted
      else
        stack.clear()
      end
    end
  end
end

local function item_for_entity(entity)
  local _, item_prototype = next(entity.prototype.items_to_place_this)
  return item_prototype.name
end

local function on_player_built_underground_entity(self, player_index, entity, stack)
  local state = self.player_state[player_index]
  local character = state and state.character
  if character then
    character.remove_item(stack)
  end

  -- look for bpproxy ghost on the surface
  local surface = self:aboveground_surface_for_editor_surface(entity.surface)
  local bpproxy_ghosts = surface.find_entities_filtered{
    ghost_name = proxy_name(self, entity.name),
    position = entity.position,
  }
  for _, bpproxy_ghost in ipairs(bpproxy_ghosts) do
    bpproxy_ghost.destroy()
  end
end

local function create_underground_entity(self, entity)
  local underground_surface = self:editor_surface_for_aboveground_surface(entity.surface)
  if not underground_surface then return end
  local create_args = {
    name = nonproxy_name(self, entity.name),
    position = entity.position,
    force = entity.force,
    direction = entity.direction,
  }
  if entity.type == "underground-belt" then
    create_args.type = entity.belt_to_ground_type
  elseif entity.type == "loader" then
    create_args.type = entity.loader_type
  end

  local underground_entity = underground_surface.create_entity(create_args)
  entity.surface.create_entity{
    name = "flying-text",
    position = entity.position,
    text = {self.name.."-message.created-underground", underground_entity.localised_name},
  }

  return underground_entity
end

function BaseEditor.abort_build(creator, entity, stack, message)
  local inserted = creator.insert(stack)
  -- cannot insert directly into robots
  if inserted == 0 then creator.get_inventory(defines.inventory.robot_cargo).insert(stack) end
  entity.surface.create_entity{
    name = "flying-text",
    position = entity.position,
    text = message,
  }
  entity.destroy()
end

local function on_built_bpproxy(self, creator, bpproxy, stack)
  local underground_entity = create_underground_entity(self, bpproxy)
  if underground_entity then
    bpproxy.destroy()
  else
    self.abort_build(
      creator,
      bpproxy,
      stack,
      {self.name.."-error.underground-obstructed"})
  end
end

-- converts overworld bpproxy ghost to regular ghost underground
local function on_player_built_surface_bpproxy_ghost(self, ghost, name)
  local editor_surface = self:editor_surface_for_aboveground_surface(ghost.surface)
  if editor_surface.find_entity("entity-ghost", ghost.position) then
    ghost.destroy()
    return
  end

  local position = ghost.position
  local create_entity_args = {
    name = name,
    position = position,
    force = ghost.force,
    direction = ghost.direction,
    build_check_type = defines.build_check_type.ghost_place,
  }
  if ghost.ghost_type == "underground-belt" then
    create_entity_args.type = ghost.belt_to_ground_type
  elseif ghost.ghost_type == "loader" then
    create_entity_args.type = ghost.loader_type
  end

  if editor_surface.can_place_entity(create_entity_args) then
    create_entity_args.name = "entity-ghost"
    create_entity_args.inner_name = name
    create_entity_args.build_check_type = nil
    local editor_ghost = editor_surface.create_entity(create_entity_args)
    editor_ghost.last_user = ghost.last_user
  else
    ghost.destroy()
  end
end

local function on_player_built_underground_ghost(self, ghost)
  local surface = self:aboveground_surface_for_editor_surface(ghost.surface)
  local create_entity_args = {
    name = "entity-ghost",
    inner_name = proxy_name(self, ghost.ghost_name),
    position = ghost.position,
    force = ghost.force,
    direction = ghost.direction
  }
  if ghost.ghost_type == "underground-belt" then
    create_entity_args.type = ghost.belt_to_ground_type
  elseif ghost.ghost_type == "loader" then
    create_entity_args.type = ghost.loader_type
  end
  surface.create_entity(create_entity_args)
end

local function on_player_built_ghost(self, ghost)
  local name = nonproxy_name(self, ghost.ghost_name)
  if name then
    if self:is_editor_surface(ghost.surface) then
      ghost.destroy()
      return
    else
      return on_player_built_surface_bpproxy_ghost(self, ghost, name)
    end
  end
  if self:is_editor_surface(ghost.surface) then
    return on_player_built_underground_ghost(self, ghost)
  end
end

local function counterpart_ghosts(self, ghost)
  local surface = counterpart_surface(self, ghost.surface)
  if not surface then return {} end
  local ghosts = surface.find_entities_filtered{
    name = "entity-ghost",
    position = ghost.position,
  }
  local out = {}
  local ghost_name = ghost.ghost_name
  local nonproxy = nonproxy_name(self, ghost_name)
  for _, other_ghost in ipairs(ghosts) do
    if other_ghost.ghost_name == nonproxy
       or nonproxy_name(self, other_ghost.ghost_name) == ghost_name then
      out[#out+1] = other_ghost
    end
  end
  return out
end

local function on_player_mined_ghost(self, ghost)
  for _, counterpart in ipairs(counterpart_ghosts(self, ghost)) do
    counterpart.destroy()
  end
end

---------------------------------------------------------------------------------------------------
-- Blueprint capture

local function find_in_area(args)
  local area = args.area
  if area.left_top.x >= area.right_bottom.x or area.left_top.y >= area.right_bottom.y then
    args.position = area.left_top
    args.area = nil
  end
  local surface = args.surface
  args.surface = nil
  return surface.find_entities_filtered(args)
end

local function bp_position_transforms(bp_entities, surface, area)
  local bp_anchor = bp_entities[1]
  local world_anchor = find_in_area{surface = surface, area = area, name = bp_anchor.name, limit = 1}[1]
  if not world_anchor then return nil end

  local x_offset = world_anchor.position.x - bp_anchor.position.x
  local y_offset = world_anchor.position.y - bp_anchor.position.y
  local bp_to_world = function(p)
    return { x = p.x + x_offset, y = p.y + y_offset }
  end
  local world_to_bp = function(p)
    return { x = p.x - x_offset, y = p.y - y_offset }
  end

  return bp_to_world, world_to_bp
end

function BaseEditor:capture_underground_entities_in_blueprint(event)
  local player = game.players[event.player_index]
  local bp_surface = player.surface
  local underground_surface = self:editor_surface_for_aboveground_surface(bp_surface)

  local bp = player.blueprint_to_setup
  if not bp or not bp.valid_for_read then bp = player.cursor_stack end
  local bp_entities = bp.get_blueprint_entities()
  if not bp_entities or not next(bp_entities) then return end
  local area = event.area

  local _, world_to_bp = bp_position_transforms(bp_entities, bp_surface, area)

  local ug_entities = find_in_area{surface = underground_surface, area = area}
  for _, ug_entity in ipairs(ug_entities) do
    if ug_entity.name ~= "entity-ghost" then
      local name_in_bp = proxy_name(self, ug_entity.name)
      local entity_type = ug_entity.type

      local bp_entity = {
        entity_number = #bp_entities + 1,
        name = name_in_bp,
        position = world_to_bp(ug_entity.position),
        direction = ug_entity.direction,
      }

      if entity_type == "underground-belt" then
        bp_entity.type = ug_entity.belt_to_ground_type
      elseif entity_type == "loader" then
        bp_entity.type = ug_entity.loader_type
      end

      bp_entities[#bp_entities + 1] = bp_entity
    end
  end
  bp.set_blueprint_entities(bp_entities)

  return bp
end

---------------------------------------------------------------------------------------------------
-- deconstruction

function BaseEditor:surface_counterpart_bpproxy(entity)
  local name = proxy_name(self, entity.name)
  local aboveground_surface = self:aboveground_surface_for_editor_surface(entity.surface)
  return aboveground_surface.find_entity(name, entity.position)
end

local function underground_counterpart_entity(self, entity)
  local name = nonproxy_name(self, entity.name)
  if not name then return nil end
  local editor_surface = self:editor_surface_for_aboveground_surface(entity.surface)
  return editor_surface.find_entity(name, entity.position)
end

local function create_deconstruction_proxy(self, entity, player)
  local surface = self:aboveground_surface_for_editor_surface(entity.surface)
  local args = {
    name = proxy_name(self, entity.name),
    position = entity.position,
    direction = entity.direction,
    force = entity.force,
  }
  if entity.type == "underground-belt" then
    args.type = entity.belt_to_ground_type
  elseif entity.type == "loader" then
    args.type = entity.loader_type
  end
  local bpproxy_entity = surface.create_entity(args)
  bpproxy_entity.destructible = false
  bpproxy_entity.order_deconstruction(player.force, player)
end

local function on_canceled_bpproxy_deconstruction(self, entity, player)
  local counterpart = underground_counterpart_entity(self, entity)
  if counterpart and counterpart.to_be_deconstructed(counterpart.force) then
    local force = player and player.force or counterpart.force
    counterpart.cancel_deconstruction(force, player)
  end
  entity.destroy()
end

local function on_canceled_underground_deconstruction(self, entity)
  local counterpart = self:surface_counterpart_bpproxy(entity)
  if counterpart then
    counterpart.destroy()
  end
end

local function create_entity_filter(tool)
  local set = {}
  for _, item in pairs(tool.entity_filters) do
    set[item] = true
  end
  if not next(set) then
    return function(_) return true end
  elseif tool.entity_filter_mode == defines.deconstruction_item.entity_filter_mode.blacklist then
    return function(entity)
      if entity.name == "entity-ghost" then
        return not set[entity.ghost_name]
      else
        return not set[entity.name]
      end
    end
  else
    return function(entity)
      if entity.name == "entity-ghost" then
        return set[entity.ghost_name]
      else
        return set[entity.name]
      end
    end
  end
end

function BaseEditor:order_underground_deconstruction(player, editor_surface, area, tool)
  local filter = create_entity_filter(tool)
  local aboveground_surface = self:aboveground_surface_for_editor_surface(editor_surface)
  local underground_entities = find_in_area{surface = editor_surface, area = area}
  local to_deconstruct = {}
  for _, entity in ipairs(underground_entities) do
    if filter(entity) then
      if entity.name == "entity-ghost" then
        local ghosts = aboveground_surface.find_entities_filtered{
          ghost_name = proxy_name(entity.name),
          position = entity.position,
        }
        if ghosts[1] then ghosts[1].destroy() end
        entity.destroy()
      elseif has_proxy(self, entity.name) then
        create_deconstruction_proxy(self, entity, player)
        entity.order_deconstruction(player.force, player)
        to_deconstruct[#to_deconstruct+1] = entity
      end
    end
  end
  return to_deconstruct
end

---------------------------------------------------------------------------------------------------
-- event handlers

function BaseEditor:on_built_entity(event)
  local player_index = event.player_index
  local entity = event.created_entity
  if not entity.valid then return end
  if entity.name == "entity-ghost" then return on_player_built_ghost(self, entity) end
  local stack = event.stack
  local surface = entity.surface

  if event.mod_name == "upgrade-planner" then
    -- work around https://github.com/Klonan/upgrade-planner/issues/10
    stack = {name = item_for_entity(entity), count = 1}
  end

  if self:is_editor_surface(surface) then
    on_player_built_underground_entity(self, player_index, entity, stack)
  elseif nonproxy_name(self, entity.name) then
    on_built_bpproxy(self, game.players[player_index], entity, stack)
  end
end

function BaseEditor:on_picked_up_item(event)
  local player = game.players[event.player_index]
  if not self:is_editor_surface(player.surface) then return end
  local character = self.player_state[event.player_index].character
  if character then
    local stack = event.item_stack
    local inserted = self.return_to_character_or_spill(player, character, stack)
    local excess = stack.count - inserted
    if not is_stack_valid_for_editor(self, stack) then
      player.remove_item(stack)
    elseif excess > 0 then
      player.remove_item{name = stack.name, count = excess}
    end
  end
end

function BaseEditor:on_player_mined_item(event)
  if event.mod_name == "upgrade-planner" then
    -- upgrade-planner won't insert to character inventory
    local player = game.players[event.player_index]
    local character = self.player_state[event.player_index].character
    if character then
      local stack = event.item_stack
      local count = stack.count
      local inserted = self.return_to_character_or_spill(player, character, stack)
      local excess = count - inserted
      if excess > 0 then
        -- try to match editor inventory to character inventory
        player.remove_item{name = stack.name, count = excess}
      end
    end
  end
end

function BaseEditor:on_player_mined_entity(event)
  local entity = event.entity
  local surface = entity.surface
  if self:is_editor_surface(surface) then
    local character = self.player_state[event.player_index].character
    if character then
      self:return_buffer_to_character(event.player_index, character, event.buffer)
    end
    if entity.to_be_deconstructed(entity.force) then
      on_canceled_underground_deconstruction(self, entity)
    end
  elseif self:is_valid_aboveground_surface(surface) then
    local editor_entity = underground_counterpart_entity(self, entity)
    if editor_entity then
      return_contents_to_buffer(editor_entity, event.buffer)
      editor_entity.destroy()
    end
  end
end

function BaseEditor:on_robot_mined_entity(event)
  local entity = event.entity
  local surface = entity.surface
  if self:is_valid_aboveground_surface(surface) then
    local editor_entity = underground_counterpart_entity(self, entity)
    if editor_entity then
      return_contents_to_buffer(editor_entity, event.buffer)
      editor_entity.destroy()
    end
  end
end

function BaseEditor:on_pre_ghost_deconstructed(event)
  on_player_mined_ghost(self, event.ghost)
end

function BaseEditor:on_pre_player_mined_item(event)
  local entity = event.entity
  if not entity.valid then return end
  if entity.name == "entity-ghost" then
    return on_player_mined_ghost(self, entity)
  end
end

function BaseEditor:on_robot_built_entity(event)
  local entity = event.created_entity
  if nonproxy_name(self, entity.name) then
    on_built_bpproxy(self, event.robot, entity, event.stack)
  end
end

function BaseEditor:on_marked_for_deconstruction(event)
  local entity = event.entity
  if self:is_editor_surface(entity.surface) and has_proxy(self, entity.name) then
    create_deconstruction_proxy(self, entity, game.players[event.player_index])
  end
end

function BaseEditor:on_canceled_deconstruction(event)
  local entity = event.entity
  if nonproxy_name(self, entity.name) then
    on_canceled_bpproxy_deconstruction(self, entity, game.players[event.player_index])
  elseif self:is_editor_surface(entity.surface) then
    on_canceled_underground_deconstruction(self, entity)
  end
end

---------------------------------------------------------------------------------------------------
-- Exports

local M = {
  class = BaseEditor
}

local meta = {
  __index = BaseEditor
}

function M.new(name)
  local self = {
    name = name,
    proxy_prefix = name.."-bpproxy-",
    player_state = {},
    valid_editor_types = {},
  }
  global.editor = self
  return M.restore(self)
end

function M.instance(name)
  if global.editor then
    return global.editor
  else
    return M.new(name)
  end
end

function M.restore(self)
  return setmetatable(self, meta)
end

function M.on_init()
  M.on_load()
end

function M.on_load()
  if global.editor then
    M.restore(global.editor)
  end
end

function M.on_tick(_)
  sync_player_inventories(global.editor)
end

return M