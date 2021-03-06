if not serpent then
  serpent = require "serpent"
end

local BaseEditor = {}

---------------------------------------------------------------------------------------------------
-- Abstract methods to be overridden by subclasses

local function is_se_planet_or_moon(surface)
  local zone = remote.interfaces["space-exploration"]
    and remote.interfaces["space-exploration"]["get_zone_from_surface_index"]
    and remote.call(
      "space-exploration",
      "get_zone_from_surface_index",
      {surface_index = surface.index})
  return zone and (zone.type == "planet" or zone.type == "moon")
end

function BaseEditor:is_valid_aboveground_surface(surface)
  return false
    or surface.name == "nauvis"            -- base
    or surface.name == "oarc"              -- oarc-mod
    or surface.name == "Game"              -- TeamCoop
    or surface.name:match("^Nauvis plus ") -- NewGamePlus
    or is_se_planet_or_moon(surface)       -- space-exploration
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

local function create_editor_surface(name)
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

  if remote.interfaces["RSO"] and remote.interfaces["RSO"]["ignoreSurface"] then
    remote.call("RSO", "ignoreSurface", name)
  end
end

local _editor_surface_cache = {}
function BaseEditor:editor_surface_for_aboveground_surface(aboveground_surface)
  local underground_surface = _editor_surface_cache[aboveground_surface]
  if not underground_surface then
    if not self:is_valid_aboveground_surface(aboveground_surface) then return nil end
    local underground_surface_name = editor_surface_name(self, aboveground_surface.name)
    if not game.surfaces[underground_surface_name] then
      create_editor_surface(underground_surface_name)
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
  local aboveground_surface = _aboveground_surface_cache[editor_surface]
  if not aboveground_surface then
    local surface_name = aboveground_surface_name(self, editor_surface.name)
    aboveground_surface = game.surfaces[surface_name]
    _aboveground_surface_cache[editor_surface] = aboveground_surface
  end
  return aboveground_surface
end

function BaseEditor:is_editor_surface(surface)
  return surface.name:find("^"..self.name) ~= nil
end

function BaseEditor:get_aboveground_surface(surface)
  if self:is_valid_aboveground_surface(surface) then
    return surface
  elseif self:is_editor_surface(surface) then
    return self:aboveground_surface_for_editor_surface(surface)
  end
  return nil
end

function BaseEditor:get_editor_surface(surface)
  if self:is_editor_surface(surface) then
    return surface
  elseif self:is_valid_aboveground_surface(surface) then
    return self:editor_surface_for_aboveground_surface(surface)
  end
  return nil
end

function BaseEditor:counterpart_surface(surface)
  if self:is_editor_surface(surface) then
    return self:aboveground_surface_for_editor_surface(surface)
  elseif self:is_valid_aboveground_surface(surface) then
    return self:editor_surface_for_aboveground_surface(surface)
  end
  return nil
end

local function delete_existing_surfaces(self)
  for _, surface in pairs(game.surfaces) do
    if self:is_editor_surface(surface) then
      game.delete_surface(surface)
    end
  end
end

---------------------------------------------------------------------------------------------------
-- inventory handling

local _is_item_prototype_valid_for_editor_cache = {}
local function is_item_prototype_valid_for_editor(self, item_prototype)
  local is_valid = _is_item_prototype_valid_for_editor_cache[item_prototype]
  if is_valid == nil then
    is_valid = false
    for _, valid_type in ipairs(self.valid_editor_types) do
      if item_prototype.type == valid_type then
        is_valid = true
        break
      end
    end
    if not is_valid then
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
    end
    _is_item_prototype_valid_for_editor_cache[item_prototype] = is_valid
  end
  return is_valid
end

local _is_item_valid_for_editor_cache = {}
local function is_item_valid_for_editor(self, name)
  local is_valid = _is_item_valid_for_editor_cache[name]
  if is_valid == nil then
    is_valid = is_item_prototype_valid_for_editor(self, game.item_prototypes[name])
    _is_item_valid_for_editor_cache[name] = is_valid
  end
  return is_valid
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

local function item_deltas(before, after)
  local out = {}
  for name, count in pairs(before) do
    out[name] = (after[name] or 0) - count
  end
  for name, count in pairs(after) do
    if not before[name] then
      out[name] = count
    end
  end
  return out
end

local function apply_deltas_to_character(player, character, prev_counts, deltas)
  local new_counts = {}
  for name, count in pairs(prev_counts) do
    new_counts[name] = count
  end

  for name, delta in pairs(deltas) do
    new_counts[name] = (prev_counts[name] or 0) + delta
    if delta < 0 then
      character.remove_item{name = name, count = -delta}
    end
  end

  for name, delta in pairs(deltas) do
    if delta > 0 then
      local inserted = character.insert{name = name, count = delta}
      local excess = delta - inserted
      if excess > 0 then
        player.print({"inventory-restriction.player-inventory-full", game.item_prototypes[name].localised_name})
        player.remove_item{name = name, count = excess}
        character.surface.spill_item_stack(character.position, {name = name, count = excess})
        new_counts[name] = (prev_counts[name] or 0) + inserted
      end
    end
  end
  return new_counts
end

local function apply_deltas_to_player(player, prev_counts, deltas)
  local new_counts = {}
  for name, count in pairs(prev_counts) do
    new_counts[name] = count
  end

  for name, delta in pairs(deltas) do
    if delta < 0 then
      player.remove_item{name = name, count = -delta}
    end
  end

  for name, delta in pairs(deltas) do
    if delta > 0 then
      player.insert{name = name, count = delta}
    end
    new_counts[name] = (prev_counts[name] or 0) + delta
  end
  return new_counts
end

local max_inventory
local function get_all_item_counts(control)
  if not max_inventory then
    for _, inventory_id in pairs(defines.inventory) do
      if not max_inventory or inventory_id > max_inventory then
        max_inventory = inventory_id
      end
    end
  end

  local out = {}
  for inventory_id=1,max_inventory do
    local inventory = control.get_inventory(inventory_id)
    if inventory then
      local contents = inventory.get_contents()
      for name, count in pairs(inventory.get_contents()) do
        out[name] = (out[name] or 0) + count
      end
    end
  end

  local cursor_stack = control.cursor_stack
  if cursor_stack and cursor_stack.valid_for_read then
    local name = cursor_stack.name
    out[name] = (out[name] or 0) + cursor_stack.count
  end

  return out
end

local function get_valid_item_counts(self, control)
  local out = {}
  for name in pairs(valid_editor_items(self)) do
    out[name] = control.get_item_count(name)
    if out[name] == 0 then out[name] = nil end
  end
  return out
end

local function sync_inventories(self, player, state)
  local character = state.character
  if not character then return end

  local character_counts = get_valid_item_counts(self, character)
  local prev_character_counts = state.prev_character_counts or character_counts
  local character_deltas = item_deltas(prev_character_counts, character_counts)

  local player_counts = get_all_item_counts(player)
  local prev_player_counts = state.prev_player_counts or player_counts
  local player_deltas = item_deltas(prev_player_counts, player_counts)

  local new_character_counts = apply_deltas_to_character(player, character, character_counts, player_deltas)
  state.prev_character_counts = new_character_counts

  local new_player_counts = apply_deltas_to_player(player, player_counts, character_deltas)
  state.prev_player_counts = new_player_counts

  for name, count in pairs(new_player_counts) do
    if count > 0 and not is_item_valid_for_editor(self, name) then
      player.remove_item{name = name, count = count}
      -- not interested in tracking changes to this item
      new_player_counts[name] = nil
      new_character_counts[name] = nil
    end
  end
end

local function sync_player_inventories(self, player_index)
  local state = self.player_state[player_index]
  if not state then return end
  sync_inventories(self, game.players[player_index], state)
end

local function sync_connected_players_inventories(self)
  for _, player in pairs(game.connected_players) do
    sync_player_inventories(self, player.index)
  end
end

local transport_line_counts = {
  ["loader"] = 2,
  ["loader-1x1"] = 2,
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
-- player/character handling

local function move_player_to_editor(self, player)
  local success = player.clear_cursor()
  if not success then return end
  local player_index = player.index
  local position = player.position

  local editor_surface = self:editor_surface_for_aboveground_surface(player.surface)
  if not editor_surface.is_chunk_generated(position) then
    editor_surface.request_to_generate_chunks(position, 1)
    editor_surface.force_generate_chunk_requests()
  end

  self.player_state[player_index] = {
    position = position,
    surface = player.surface,
    character = player.character,
    prev_character_counts = {},
    prev_player_counts = {},
  }
  player.character = nil
  player.teleport(player.position, editor_surface)
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
-- ghost handling

function BaseEditor:proxy_name(entity)
  if entity.type == "entity-ghost" then
    return self.proxy_prefix..entity.ghost_name
  end
  return self.proxy_prefix..entity.name
end

function BaseEditor:nonproxy_name(entity)
  local prefix = self.proxy_prefix
  local name = entity.name
  if name == "entity-ghost" then
    name = entity.ghost_name
  end
  if name:sub(1, #prefix) ~= prefix then
    return nil
  end
  return name:sub(#prefix+1)
end

function BaseEditor:upgrade_name(entity_to_upgrade, target_proto)
  return target_proto.name
end

---@param bpproxy LuaEntity Either a bpproxy or a bpproxy ghost
function BaseEditor:create_entity_args_for_editor_entity(bpproxy)
  return {
    name = self:nonproxy_name(bpproxy),
    position = bpproxy.position,
    force = bpproxy.force,
    player = bpproxy.last_user,
  }
end

local function has_proxy(self, entity)
  return game.entity_prototypes[self:proxy_name(entity)] ~= nil
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

  -- look for bpproxy ghost on the surface
  local surface = self:aboveground_surface_for_editor_surface(entity.surface)
  local bpproxy_ghosts = surface.find_entities_filtered{
    ghost_name = self:proxy_name(entity),
    position = entity.position,
  }
  for _, bpproxy_ghost in ipairs(bpproxy_ghosts) do
    bpproxy_ghost.destroy()
  end
end

local function create_editor_entity(self, bpproxy)
  local editor_surface = self:editor_surface_for_aboveground_surface(bpproxy.surface)
  if not editor_surface then return end
  local create_args = self:create_entity_args_for_editor_entity(bpproxy)
  return editor_surface.create_entity(create_args)
end

function BaseEditor.abort_build(creator, entity, stack, message)
  if creator and stack and stack.valid_for_read then
    local inserted = creator.insert(stack)
    -- cannot insert directly into robots
    if inserted == 0 then creator.get_inventory(defines.inventory.robot_cargo).insert(stack) end
  end
  entity.surface.create_entity{
    name = "flying-text",
    position = entity.position,
    text = message,
  }
  entity.destroy()
end

local function on_built_bpproxy(self, creator, bpproxy, stack)
  local editor_entity = create_editor_entity(self, bpproxy)
  if editor_entity then
    bpproxy.surface.create_entity{
      name = "flying-text",
      position = bpproxy.position,
      text = {self.name.."-message.created-underground", editor_entity.localised_name},
    }
    bpproxy.destroy()
  else
    self.abort_build(
      creator,
      bpproxy,
      stack,
      {self.name.."-error.underground-obstructed"})
  end
end

local player_placing_blueprint_with_bpproxy

local function try_to_create_ghost(surface, create_entity_args)
  local entity_name = create_entity_args.name
  create_entity_args.build_check_type = defines.build_check_type.ghost_place

  if not surface.can_place_entity(create_entity_args) then
    return nil
  end

  create_entity_args.name = "entity-ghost"
  create_entity_args.inner_name = entity_name
  create_entity_args.build_check_type = nil

  local ghost = surface.create_entity(create_entity_args)
  return ghost
end

-- converts overworld bpproxy ghost to regular ghost underground
local function on_player_built_surface_bpproxy_ghost(self, ghost, name)
  local editor_surface = self:editor_surface_for_aboveground_surface(ghost.surface)
  local create_entity_args = self:create_entity_args_for_editor_entity(ghost)
  create_entity_args.name = name
  local editor_ghost = editor_surface and try_to_create_ghost(editor_surface, create_entity_args)
  if not editor_ghost then
    -- position was blocked in editor
    ghost.destroy()
  end
end

local function on_player_built_underground_ghost(self, ghost, name)
  local editor_surface = ghost.surface
  local aboveground_surface = self:aboveground_surface_for_editor_surface(editor_surface)
  local create_entity_args = self:create_entity_args_for_editor_entity(ghost)

  if name then
    -- this is a bpproxy ghost, move it above ground and create regular ghost in editor
    ghost.destroy()
    -- try to create editor ghost first, since it has a collision_mask
    local editor_ghost = try_to_create_ghost(editor_surface, create_entity_args)
    if editor_ghost then
      -- succeeded creating editor ghost, so create matching bpproxy ghost above ground
      create_entity_args.name = ghost.ghost_name
      try_to_create_ghost(aboveground_surface, create_entity_args)
    end
  elseif player_placing_blueprint_with_bpproxy then
    -- regular ghost in editor, force to be regular ghost above ground
    create_entity_args.name = ghost.ghost_name
    try_to_create_ghost(aboveground_surface, create_entity_args)
    ghost.destroy()
  elseif has_proxy(self, ghost) then
    -- regular ghost in editor, create surface bpproxy ghost
    create_entity_args.name = self:proxy_name(ghost)
    try_to_create_ghost(aboveground_surface, create_entity_args)
  else
    -- regular ghost in editor without a proxy, just clear it away
    ghost.destroy()
  end
end

local function on_player_built_ghost(self, ghost)
  local name = self:nonproxy_name(ghost)
  if self:is_editor_surface(ghost.surface) then
    return on_player_built_underground_ghost(self, ghost, name)
  elseif name then
    return on_player_built_surface_bpproxy_ghost(self, ghost, name)
  end
end

local function counterpart_ghosts(self, ghost)
  local surface = self:counterpart_surface(ghost.surface)
  if not surface then return {} end
  local ghosts = surface.find_entities_filtered{
    name = "entity-ghost",
    position = ghost.position,
  }
  local out = {}
  local ghost_name = ghost.ghost_name
  local nonproxy = self:nonproxy_name(ghost)
  for _, other_ghost in ipairs(ghosts) do
    if other_ghost.ghost_name == nonproxy
       or self:nonproxy_name(other_ghost) == ghost_name then
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

local function on_player_placing_blueprint(self, player_index, bp)
  local bp_entities = bp.get_blueprint_entities()
  if not bp_entities then return end
  for _, bp_entity in pairs(bp_entities) do
    if self:nonproxy_name(bp_entity) then
      player_placing_blueprint_with_bpproxy = true
      return
    end
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
  if not bp_anchor then return end
  local world_anchor = find_in_area{surface = surface, area = area, name = bp_anchor.name, limit = 1}[1]
  if not world_anchor then
    world_anchor = find_in_area{surface = surface, area = area, ghost_name = bp_anchor.name, limit = 1}[1]
  end
  if not world_anchor then return end

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

local function convert_bp_entities_to_bpproxies(self, bp_entities, editor_surface, editor_bp_to_world)
  local write_cursor = 1
  for read_cursor, bp_entity in ipairs(bp_entities) do
    bp_entities[read_cursor] = nil
    local entity = editor_surface.find_entity(bp_entity.name, editor_bp_to_world(bp_entity.position))
    local name_in_bp = self:proxy_name(entity)
    if game.entity_prototypes[name_in_bp] then
      bp_entity.name = name_in_bp
      bp_entity.entity_number = write_cursor
      bp_entities[write_cursor] = bp_entity
      write_cursor = write_cursor + 1
    end
  end
end

local function create_temporary_stack()
  local chest = game.surfaces.nauvis.create_entity{
    name = "wooden-chest",
    position = {0, 0},
  }
  local stack = chest.get_inventory(defines.inventory.chest)[1]
  stack.set_stack{name = "blueprint", count = 1}
  return chest, stack
end

local function merge_bp_entities(bp1_entities, bp2_entities, bp2_to_world, world_to_bp1)
  local last_bp1_entity_number = #bp1_entities
  for i, bp2_entity in ipairs(bp2_entities) do
    local world_position = bp2_to_world(bp2_entity.position)
    local bp1_position = world_to_bp1(world_position)
    local entity_number = last_bp1_entity_number + i
    bp2_entity.entity_number = entity_number
    bp2_entity.position = bp1_position
    bp1_entities[entity_number] = bp2_entity
  end
end

--- Captures all entities both above ground and in the editor in a single blueprint.
function BaseEditor:capture_underground_entities_in_blueprint(event)
  local player = game.players[event.player_index]
  local bp_surface = player.surface
  local bp = player.blueprint_to_setup
  if not bp or not bp.valid_for_read then bp = player.cursor_stack end
  local area = event.area

  local aboveground_bp, editor_bp, temporary_chest, aboveground_surface, editor_surface
  if self:is_editor_surface(bp_surface) then
    aboveground_surface = self:aboveground_surface_for_editor_surface(bp_surface)
    editor_surface = bp_surface
    editor_bp = bp
    temporary_chest, aboveground_bp = create_temporary_stack()
    aboveground_bp.create_blueprint{
      surface = aboveground_surface,
      area = area,
      force = player.force,
    }
  elseif self:is_valid_aboveground_surface(bp_surface) then
    aboveground_surface = bp_surface
    editor_surface = self:editor_surface_for_aboveground_surface(bp_surface)
    aboveground_bp = bp
    temporary_chest, editor_bp = create_temporary_stack()
    editor_bp.create_blueprint{
      surface = editor_surface,
      area = area,
      force = player.force,
    }
  end

  -- try to find anchors
  local aboveground_bp_entities = aboveground_bp.get_blueprint_entities() or {}
  local aboveground_bp_to_world, aboveground_world_to_bp =
    bp_position_transforms(aboveground_bp_entities, aboveground_surface, area)

  local editor_bp_entities = editor_bp.get_blueprint_entities() or {}
  local editor_bp_to_world, editor_world_to_bp =
    bp_position_transforms(editor_bp_entities, editor_surface, area)

  convert_bp_entities_to_bpproxies(self, editor_bp_entities, editor_surface, editor_bp_to_world)

  -- merge entities from both blueprints
  if next(aboveground_bp_entities) and next(editor_bp_entities) then
    merge_bp_entities(
      aboveground_bp_entities,
      editor_bp_entities,
      editor_bp_to_world,
      aboveground_world_to_bp)
  elseif next(editor_bp_entities) then
    aboveground_bp_entities = editor_bp_entities
  end

  if next(aboveground_bp_entities) then
    bp.set_blueprint_entities(aboveground_bp_entities)
  end

  temporary_chest.destroy()
  return bp, aboveground_bp_to_world
end

---------------------------------------------------------------------------------------------------
-- deconstruction

function BaseEditor:surface_counterpart_bpproxy(entity)
  if not has_proxy(self, entity) then return nil end
  local aboveground_surface = self:aboveground_surface_for_editor_surface(entity.surface)
  return aboveground_surface.find_entity(self:proxy_name(entity), entity.position)
end

local function underground_counterpart_entity(self, entity)
  local name = self:nonproxy_name(entity)
  if not name then return nil end
  local editor_surface = self:editor_surface_for_aboveground_surface(entity.surface)
  return editor_surface.find_entity(name, entity.position)
end

local function create_deconstruction_proxy(self, entity, player)
  if not has_proxy(self, entity) then return end
  local name = self:proxy_name(entity)
  local position = entity.position
  local surface = self:aboveground_surface_for_editor_surface(entity.surface)
  if surface.find_entity(name, position) then return end

  local bpproxy_entity = surface.create_entity{
    name = name,
    position = position,
    direction = entity.direction,
    force = entity.force,
    player = player,
  }
  bpproxy_entity.destructible = false
  bpproxy_entity.operable = false
  bpproxy_entity.order_deconstruction(player.force, player)
end

local function on_cancelled_bpproxy_deconstruction(self, entity, player)
  local counterpart = underground_counterpart_entity(self, entity)
  if counterpart and counterpart.to_be_deconstructed(counterpart.force) then
    local force = player and player.force or counterpart.force
    counterpart.cancel_deconstruction(force, player)
  end
  entity.destroy()
end

local function on_cancelled_underground_deconstruction(self, entity)
  local counterpart = self:surface_counterpart_bpproxy(entity)
  if counterpart then
    counterpart.destroy()
  end
end

local function create_entity_filter(tool)
  if not (tool and tool.valid_for_read and tool.is_deconstruction_item) then
    return function(_) return true end
  end

  if tool.trees_and_rocks_only then
    if tool.entity_filter_mode == defines.deconstruction_item.entity_filter_mode.whitelist then
      return function(_) return false end
    else
      return function(_) return true end
    end
  end

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
          ghost_name = self:proxy_name(entity),
          position = entity.position,
        }
        if ghosts[1] then ghosts[1].destroy() end
        entity.destroy()
      elseif has_proxy(self, entity) then
        local was_minable = entity.minable
        entity.minable = true
        -- This will fire an on_marked_for_deconstruction event, and that handler
        -- will create the aboveground bpproxy.
        entity.order_deconstruction(player.force, player)
        if entity.valid then -- event handler of another mod may have destroyed entity
          entity.minable = was_minable
          to_deconstruct[#to_deconstruct+1] = entity
        end
      end
    end
  end
  return to_deconstruct
end

---------------------------------------------------------------------------------------------------
-- upgrade

local function create_upgrade_proxy(self, entity, target, player)
  local surface = self:aboveground_surface_for_editor_surface(entity.surface)
  local args = {
    name = self:proxy_name(entity),
    position = entity.position,
    direction = entity.direction,
    force = entity.force,
    player = player,
  }
  local bpproxy_entity = surface.create_entity(args)
  bpproxy_entity.destructible = false
  bpproxy_entity.order_upgrade{
    force = player and player.force or entity.force,
    target = self:upgrade_name(entity, target),
    player = player,
  }
end

local function on_cancelled_aboveground_upgrade(self, event)
  local player = event.player_index and game.players[event.player_index]
  local bpproxy = event.entity
  local name = self:nonproxy_name(bpproxy)
  if not name then return end

  local editor_surface = self:editor_surface_for_aboveground_surface(bpproxy.surface)
  local editor_entity = editor_surface.find_entity(name, bpproxy.position)
  if editor_entity and editor_entity.to_be_upgraded() then
    editor_entity.cancel_upgrade(editor_entity.force, player)
    bpproxy.destroy()
  end
end

local function on_cancelled_editor_upgrade(self, event)
  local player = event.player_index and game.players[event.player_index]
  local editor_entity = event.entity
  local name = self:proxy_name(editor_entity)
  if not has_proxy(self, editor_entity) then return end

  local aboveground_surface = self:aboveground_surface_for_editor_surface(editor_entity.surface)
  local bpproxy = aboveground_surface.find_entity(name, editor_entity.position)
  if bpproxy and bpproxy.to_be_upgraded() then
    bpproxy.destroy()
  end
end

---------------------------------------------------------------------------------------------------
-- mining handling

local function on_mined_entity(self, entity, buffer)
  local surface = entity.surface
  if self:is_editor_surface(surface) then
    if entity.to_be_deconstructed(entity.force) then
      on_cancelled_underground_deconstruction(self, entity)
    end
  elseif self:is_valid_aboveground_surface(surface) then
    local editor_entity = underground_counterpart_entity(self, entity)
    if editor_entity then
      if buffer then
        return_contents_to_buffer(editor_entity, buffer)
      end
      editor_entity.destroy()
    end
  end
end

---------------------------------------------------------------------------------------------------
-- event handlers

function BaseEditor:on_built_entity(event)
  local player_index = event.player_index
  local player = player_index and game.players[player_index]
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
  elseif self:nonproxy_name(entity) then
    on_built_bpproxy(self, player, entity, stack)
  end
end

function BaseEditor:on_cancelled_upgrade(event)
  local surface = event.entity.surface
  if self:is_editor_surface(surface) then
    return on_cancelled_editor_upgrade(self, event)
  elseif self:is_valid_aboveground_surface(surface) then
    return on_cancelled_aboveground_upgrade(self, event)
  end
end

function BaseEditor:on_marked_for_upgrade(event)
  local entity = event.entity
  local type = entity.type
  local target_proto = event.target
  local player = event.player_index and game.players[event.player_index]
  local fake_target_entity = {
    name = target_proto.name,
    type = type,
    direction = entity.direction,
    belt_to_ground_type = type == "underground-belt" and entity.belt_to_ground_type,
  }
  if self:is_editor_surface(entity.surface)
  and has_proxy(self, entity)
  and has_proxy(self, fake_target_entity) then
    create_upgrade_proxy(self, entity, event.target, player)
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
    local state = self.player_state[event.player_index]
    if not state then return end
    local character = state.character
    if not character then return end

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

function BaseEditor:on_player_mined_entity(event)
  on_mined_entity(self, event.entity, event.buffer)
end

function BaseEditor:on_robot_mined_entity(event)
  on_mined_entity(self, event.entity, event.buffer)
end

function BaseEditor:on_pre_ghost_deconstructed(event)
  if event.ghost.type == "entity-ghost" then
    on_player_mined_ghost(self, event.ghost)
  end
end

function BaseEditor:on_pre_player_mined_item(event)
  local entity = event.entity
  if not entity.valid then return end
  if entity.name == "entity-ghost" then
    return on_player_mined_ghost(self, entity)
  end
end

function BaseEditor:on_player_main_inventory_changed(event)
  sync_player_inventories(self, event.player_index)
end

function BaseEditor:on_robot_built_entity(event)
  local entity = event.created_entity
  if self:nonproxy_name(entity) then
    on_built_bpproxy(self, event.robot, entity, event.stack)
  end
end

function BaseEditor:on_marked_for_deconstruction(event)
  local entity = event.entity
  if self:is_editor_surface(entity.surface) then
    create_deconstruction_proxy(self, entity, game.players[event.player_index])
  end
end

function BaseEditor:on_cancelled_deconstruction(event)
  local entity = event.entity
  if self:nonproxy_name(entity) then
    local player = event.player_index and game.players[event.player_index]
    on_cancelled_bpproxy_deconstruction(self, entity, player)
  elseif self:is_editor_surface(entity.surface) then
    on_cancelled_underground_deconstruction(self, entity)
  end
end

local function get_blueprint(stack)
  if not stack or not stack.valid_for_read then return nil end
  if stack.is_blueprint and stack.is_blueprint_setup() then
    return stack
  end
  if stack.is_blueprint_book and stack.active_index then
    stack = stack.get_inventory(defines.inventory.item_main)[stack.active_index]
    return get_blueprint(stack)
  end
  return nil
end

function BaseEditor:on_pre_build(event)
  local player = game.players[event.player_index]
  local stack = player.cursor_stack
  local bp = get_blueprint(stack)
  if bp then
    player_placing_blueprint_with_bpproxy = false
    on_player_placing_blueprint(self, event.player_index, bp)
  end
end

function BaseEditor:on_configuration_changed(data)
  if remote.interfaces["RSO"] and remote.interfaces["RSO"]["ignoreSurface"] then
    for name, surface in pairs(game.surfaces) do
      if self:is_editor_surface(surface) then
        remote.call("RSO", "ignoreSurface", name)
      end
    end
  end
end

function BaseEditor:on_script_raised_built(event)
  local entity = event.entity
  if self:nonproxy_name(entity) then
    on_built_bpproxy(self, nil, entity, nil)
  end
end

function BaseEditor:on_script_raised_destroy(event)
  local entity = event.entity
  if entity.name == "entity-ghost" then
    return on_player_mined_ghost(self, entity)
  end
  on_mined_entity(self, entity, nil)
end

function BaseEditor:on_script_raised_revive(event)
  local entity = event.entity
  if self:nonproxy_name(entity) then
    on_built_bpproxy(self, nil, entity, nil)
  end
end

function BaseEditor:on_tick(event)
  player_placing_blueprint_with_bpproxy = false
  sync_connected_players_inventories(self)
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
  M.restore(self)
  delete_existing_surfaces(self)
  return self
end

function M.restore(self)
  return setmetatable(self, meta)
end

return M