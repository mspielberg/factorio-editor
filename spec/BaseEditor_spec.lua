require "busted"
local serpent = require "serpent"

local function export_mocks(env, args)
  local nauvis = {
    name = "nauvis",
    spill_item_stack = function() end,
  }

  local editor_surface = {
    name = "testeditor",
  }

  local character = {
    insert = function(stack)
      if stack.name == "baditem" then return stack.count
      elseif stack.name == "validitem" then return 0
      end
    end,
    get_item_count = function(name)
      if name == "excessitem" then return 10
      elseif name == "validitem" then return 10
      elseif name == "baditem" then return 10
      end
    end,
    remove_item = function() end,
    surface = nauvis,
  }

  local player
  player = {
    clean_cursor = function() return true end,
    character = character,
    connected = true,
    get_item_count = function(name)
      if player.character then return player.character.get_item_count(name)
      else
        if name == "excessitem" then return 20
        elseif name == "validitem" then return 0
        elseif name == "baditem" then return 0
        end
      end
    end,
    index = 1,
    insert = function(stack)
      if stack.name == "fits" then return stack.count
      else return stack.count / 2 end
    end,
    position = {x=1, y=1},
    print = function() end,
    remove_item = function() end,
    surface = nauvis,
    teleport = function(position, surface)
      player.surface = surface
    end,
  }

  local buffer = {
    {
      name = "validitem",
      count = 1,
      clear = function() end,
      valid_for_read = true,
    },
  }

  local entity_prototypes = {
    validentity = { type = "validtype", items_to_place_this = {} },
  }

  local item_prototypes = {
    baditem = { name = "baditem", type = "item", localised_name = {"baditem-localised"} },
    excessitem = {
      name = "excessitem",
      type = "item",
      localised_name = {"excessitem-localised"},
      place_result = { type = "validtype" },
    },
    validitem = {
      name = "validitem",
      type = "item",
      localised_name = {"validitem-localised"},
      place_result = entity_prototypes.validentity,
    },
  }
  entity_prototypes.validentity.items_to_place_this[1] = item_prototypes.validitem

  local game
  game = {
    autoplace_control_prototypes = {
      dirt = {},
    },
    create_surface = function()
      game.surfaces[editor_surface.name] = editor_surface
      return editor_surface
    end,
    entity_prototypes = entity_prototypes,
    item_prototypes = item_prototypes,
    surfaces = { nauvis = nauvis },
    players = { mock(player) },
  }
  env.game = game

  local validentity = {
    valid = true,
    name = "validentity",
    prototype = game.entity_prototypes.validentity,
    surface = editor_surface,
  }

  spy.on(game, "create_surface")

  if args and args.create_editor_surface then
    game.surfaces[editor_surface.name] = editor_surface
  end

  return {
    buffer = mock(buffer),
    character = mock(character),
    game = game,
    player = player,
    validentity = validentity,
  }
end

_G.global = {}

local BaseEditor = require "BaseEditor"
BaseEditor.on_init()

describe("A BaseEditor", function()
  local mocks
  local c
  local g
  local p
  local uut
  before_each(function()
    mocks = export_mocks(_G, {create_editor_surface = true})
    g, p, c = mocks.game, mocks.player, mocks.player.character
    uut = BaseEditor.new("testeditor")
    uut.valid_editor_types[1] = "validtype"
  end)

  describe("creates editor surfaces", function()
    local g
    local p
    before_each(function()
      mocks = export_mocks(_G)
      g, p = mocks.game, mocks.player
      uut = BaseEditor.new("testeditor")
    end)

    it("creates a surface on first toggle", function()
      uut:toggle_editor_status_for_player(1)
      assert.spy(g.create_surface).was.called_with("testeditor", match._)
    end)

    it("moves player to newly created surface", function()
      uut:toggle_editor_status_for_player(1)
      assert.spy(g.create_surface).was.called_with("testeditor", match._)
      assert.spy(p.teleport).was.called_with(p.position, g.surfaces.testeditor)
    end)
  end)

  describe("moves players between existing surfaces", function()
    it("moves player to preexisting editor surface", function()
      uut:toggle_editor_status_for_player(1)
      assert.spy(g.create_surface).was_not.called()
      assert.spy(p.teleport).was.called_with(p.position, g.surfaces.testeditor)
      assert.is_nil(p.character)
    end)

    it("returns player to their original surface", function()
      uut:toggle_editor_status_for_player(1)
      uut:toggle_editor_status_for_player(1)
      assert.spy(g.create_surface).was_not.called()
      assert.spy(p.teleport).was.called_with(p.position, g.surfaces.testeditor)
      assert.spy(p.teleport).was.called_with(p.position, g.surfaces.nauvis)
      assert.are.equal(p.character, mocks.character)
    end)
  end)

  describe("manages player inventory", function()
    it("adds and removes items to the editor inventory", function()
      uut:toggle_editor_status_for_player(1)
      BaseEditor.on_tick(1)
      assert.spy(p.insert).was.called_with({name="validitem", count=10})
      assert.spy(p.remove_item).was.called_with({name="excessitem", count=10})
    end)

    it("ignores disconnected players", function()
      uut:toggle_editor_status_for_player(1)
      p.connected = false
      BaseEditor.on_tick(1)
      assert.spy(p.insert).was_not.called_with({name="validitem", count=10})
      assert.spy(p.remove_item).was_not.called_with({name="excessitem", count=10})
    end)

    it("flushes invalid items picked up in the editor", function()
      uut:toggle_editor_status_for_player(1)
      uut:on_picked_up_item{
        player_index = 1,
        item_stack = {name="baditem", count=1},
      }
      assert.spy(c.insert).was.called_with({name="baditem", count=1})
      assert.spy(p.remove_item).was.called_with({name="baditem", count=1})
    end)

    it("doesn't allow more in editor than fit in character", function()
      uut:toggle_editor_status_for_player(1)
      uut:on_picked_up_item{
        player_index = 1,
        item_stack = {name="validitem", count=1},
      }
      assert.spy(c.insert).was.called_with{name="validitem", count=1}
      assert.spy(c.surface.spill_item_stack).was.called_with(c.position, {name="validitem", count=1})
      assert.spy(p.remove_item).was.called_with{name="validitem", count=1}
      assert.spy(p.print).was.called_with{"inventory-restriction.player-inventory-full", {"validitem-localised"}}
    end)

    it("returns items mined in the editor", function()
      uut:toggle_editor_status_for_player(1)
      uut:on_player_mined_entity{
        player_index = 1,
        entity = mocks.validentity,
        buffer = mocks.buffer,
      }
      assert.is(mocks.buffer.count, 0)
      mocks.buffer[1].count = 1
      assert.spy(c.insert).was.called_with(mocks.buffer[1])
    end)
  end)

  describe("is compatible with upgrade-planner", function()
    it("returns upgraded entities to the character", function()
      uut:toggle_editor_status_for_player(1)
      uut:on_player_mined_item{
        mod_name = "upgrade-planner",
        player_index = 1,
        item_stack = { name = "validitem", count = 1 },
      }
      assert.spy(c.insert).was.called_with{ name = "validitem", count = 1}
    end)

    it("works around upgrade-planner#10", function()
      uut:toggle_editor_status_for_player(1)
      uut:on_player_built_entity{
        mod_name = "upgrade-planner",
        player_index = 1,
        created_entity = mocks.validentity,
        stack = { name = "upgrade-planner", count = 1 },
      }
      assert.spy(c.remove_item).was.called_with{ name = "validitem", count = 1 }
    end)
  end)
end)