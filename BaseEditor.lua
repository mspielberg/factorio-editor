local BaseEditor = {}
local serpent = require "serpent"

---------------------------------------------------------------------------------------------------
-- Abstract methods to be overridden by subclasses

function BaseEditor:is_valid_aboveground_surface(surface)
  return surface.name == "nauvis"
end

---------------------------------------------------------------------------------------------------

local function editor_autoplace_control()
  for control in pairs(game.autoplace_control_prototypes) do
    if control:find("dirt") then
      return control
    end
  end
  -- pick one at random
  return next(game.autoplace_control_prototypes)
end

local function editor_surface_name(self, aboveground_surface_name)
  return self.name
end

local function create_editor_surface(self, name)
  local autoplace_control = editor_autoplace_control()
  local surface = game.create_surface(
    name,
    {
      starting_area = "none",
      water = "none",
      cliff_settings = { cliff_elevation_0 = 1024 },
      default_enable_all_autoplace_controls = false,
      autoplace_controls = {
        [autoplace_control] = {
          frequency = "very-low",
          size = "very-high",
        },
      },
      autoplace_settings = {
        decorative = { treat_missing_as_default = false },
        entity = { treat_missing_as_default = false },
      },
    }
  )
  surface.daytime = 0.35
  surface.freeze_daytime = true
end

local _editor_surface_cache = {}
local function editor_surface(self, aboveground_surface)
  local underground_surface = _editor_surface_cache[aboveground_surface]
  if not underground_surface then
    local underground_surface_name = editor_surface_name(self, aboveground_surface.name)
    if not game.surfaces[underground_surface_name] then
      create_editor_surface(self, underground_surface_name)
    end
    underground_surface = game.surfaces[underground_surface_name]
    _editor_surface_cache[aboveground_surface] = underground_surface
  end
  return underground_surface
end

local function aboveground_surface_name(self, editor_surface_name)
  return "nauvis"
end

local _aboveground_surface_cache = {}
local function aboveground_surface(self, editor_surface)
  local surface = _aboveground_surface_cache[editor_surface]
  if not surface then
    local surface_name = aboveground_surface_name(self, editor_surface.name)
    surface = game.surfaces[surface_name]
  end
  return surface
end

local function is_editor_surface(self, surface)
  return surface.name:find("^"..self.name) ~= nil
end

local player_state

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
    elseif character_count < player_count then
      player.remove_item{name = name, count = player_count - character_count}
    end
  end
end

local function sync_player_inventories(self)
  for player_index, state in pairs(player_state) do
    local character = state.character
    if character then
      local player = game.players[player_index]
      if player.connected then
        sync_player_inventory(self, character, player)
      end
    end
  end
end

local function move_player_to_editor(self, player)
  local success = player.clean_cursor()
  if not success then return end
  local player_index = player.index
  local underground_surface = editor_surface(self, player.surface)
  player_state[player_index] = {
    position = player.position,
    surface = player.surface,
    character = player.character,
  }
  player.character = nil
  player.teleport(player.position, underground_surface)
end

local function return_player_from_editor(player)
  local player_index = player.index
  local state = player_state[player_index]
  player.teleport(state.position, state.surface)
  if state.character then
    player.character = state.character
  end
  player_state[player_index] = nil
end

function BaseEditor:toggle_editor_status_for_player(player_index)
  local player = game.players[player_index]
  local surface = player.surface
  if is_editor_surface(self, surface) then
    return_player_from_editor(player)
  elseif self:is_valid_aboveground_surface(surface) then
    move_player_to_editor(self, player)
  else
    player.print({self.name.."-error.bad-surface-for-editor"})
  end
end

local function abort_player_build(player, entity, message)
  for _, product in ipairs(entity.prototype.mineable_properties.products) do
    if product.type == "item" and product.amount then
      player.insert{name = product.name, count = product.amount}
    end
  end
  entity.surface.create_entity{
    name = "flying-text",
    position = entity.position,
    text = message,
  }
  entity.destroy()
end

--- Inserts stack into character's inventory or spills it at the character's position.
-- @param stack SimpleItemStack
local function return_to_character_or_spill(player, character, stack)
  local inserted = character.insert(stack)
  if inserted < stack.count then
    player.print({"inventory-restriction.player-inventory-full", game.item_prototypes[stack.name].localised_name})
    character.surface.spill_item_stack(
      character.position,
      {name = stack.name, count = stack.count - inserted})
  end
  return inserted
end

local function return_buffer_to_character(self, player_index, character, buffer)
  local player = game.players[player_index]
  for i=1,#buffer do
    local stack = buffer[i]
    if stack.valid_for_read then
      local inserted = return_to_character_or_spill(player, character, stack)
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

local function player_built_underground_entity(player_index, stack)
  local state = player_state[player_index]
  local character = state and state.character
  if character then
    character.remove_item(stack)
  end
end

function BaseEditor:on_player_built_entity(event)
  local player_index = event.player_index
  local entity = event.created_entity
  if not entity.valid or entity.name == "entity-ghost" then return end
  local stack = event.stack
  local surface = entity.surface

  if event.mod_name == "upgrade-planner" then
    -- work around https://github.com/Klonan/upgrade-planner/issues/10
    stack = {name = item_for_entity(entity), count = 1}
  end

  if is_editor_surface(self, surface) then
    player_built_underground_entity(player_index, stack)
  end
end

function BaseEditor:on_picked_up_item(event)
  local player = game.players[event.player_index]
  if not is_editor_surface(self, player.surface) then return end
  local character = player_state[event.player_index].character
  if character then
    local stack = event.item_stack
    local inserted = return_to_character_or_spill(player, character, stack)
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
    local character = player_state[event.player_index].character
    if character then
      local stack = event.item_stack
      local count = stack.count
      local inserted = return_to_character_or_spill(player, character, stack)
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
  if is_editor_surface(self, surface) then
    local character = player_state[event.player_index].character
    if character then
      return_buffer_to_character(self, event.player_index, character, event.buffer)
    end
  end
end

---------------------------------------------------------------------------------------------------
-- Blueprint and ghost handling



---------------------------------------------------------------------------------------------------
-- Exports

local M = {}

local meta = {
  __index = BaseEditor
}

function M.new(name)
  local self = {
    name = name,
    valid_editor_types = {},
  }
  global.editor = self
  return M.restore(self)
end

function M.restore(self)
  return setmetatable(self, meta)
end

function M.on_init()
  global.player_state = {}
  M.on_load()
end

function M.on_load()
  player_state = global.player_state
  if global.editor then
    M.restore(global.editor)
  end
end

function M.on_tick(_)
  sync_player_inventories(global.editor)
end

return M