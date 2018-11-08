require "busted"
local serpent = require "serpent"

local function export_mocks(env, args)
  local defines = {
    build_check_type = {
      ghost_type = {},
    },
    inventory = {
      robot_cargo = 1,
    },
  }
  env.defines = defines

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
    validentity = { type = "validtype", items_to_place_this = {}, localised_name = {"validentity-localised"} },
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

  nauvis.find_entities_filtered = function()
    return {
      {
        valid = true,
        name = "validentity",
        position = {x=4, y=4},
        prototype = game.entity_prototypes.validentity,
        surface = nauvis,
      }
    }
  end

  local editor_entity = {
    valid = true,
    name = "validentity",
    localised_name = entity_prototypes.validentity.localised_name,
    position = {x=2, y=2},
    prototype = entity_prototypes.validentity,
    surface = editor_surface,
  }

  editor_surface.find_entities_filtered = spy.new(function()
    return { editor_entity }
  end)

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

  spy.on(game, "create_surface")

  if args and args.create_editor_surface then
    game.surfaces[editor_surface.name] = editor_surface
  end

  return {
    buffer = mock(buffer),
    character = mock(character),
    game = game,
    nauvis = nauvis,
    player = player,
    editor_entity = editor_entity,
    editor_surface = editor_surface,
  }
end

_G.global = {}

describe("A BaseEditor", function()
  local BaseEditor
  local mocks
  local c
  local g
  local p
  local uut
  local editor_surface
  local nauvis
  before_each(function()
    package.loaded["BaseEditor"] = nil
    BaseEditor = require "BaseEditor"
    BaseEditor.on_init()

    mocks = export_mocks(_G, {create_editor_surface = true})
    g, p, c = mocks.game, mocks.player, mocks.player.character
    editor_surface = mocks.editor_surface
    nauvis = mocks.nauvis
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
        entity = mocks.editor_entity,
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
      uut:on_built_entity{
        mod_name = "upgrade-planner",
        player_index = 1,
        created_entity = mocks.editor_entity,
        stack = { name = "upgrade-planner", count = 1 },
      }
      assert.spy(c.remove_item).was.called_with{ name = "validitem", count = 1 }
    end)
  end)

  describe("captures underground entities as bpproxies in blueprints", function()
    local bp = {
      valid = true,
      valid_for_read = true,
      get_blueprint_entities = function()
        return {
          {
            entity_number = 1,
            name = "validentity",
            position = {x=0, y=0},
          }
        }
      end,
      set_blueprint_entities = function() end,
    }
    spy.on(bp, "set_blueprint_entities")

    it("translates position correctly", function()
      p.blueprint_to_setup = bp
      local area = { left_top = {x=-10, y=-10}, right_bottom = {x=10, y=10} }
      uut:capture_underground_entities_in_blueprint{ player_index = 1, area = area }
      assert.spy(editor_surface.find_entities_filtered).was.called_with{ area = area }
      assert.spy(bp.set_blueprint_entities).was.called_with{
        {
          entity_number = 1,
          name = "validentity",
          position = {x=0, y=0},
        },
        {
          entity_number = 2,
          name = "testeditor-bpproxy-validentity",
          -- anchor at 4,4, underground entity at 2,2, relative offset to anchor is -2,-2
          position = {x=-2, y=-2},
        },
      }
    end)

    it("handles blueprints with no entities", function()
      bp.get_blueprint_entities = function() return nil end
      p.blueprint_to_setup = bp
      local area = { left_top = {x=-10, y=-10}, right_bottom = {x=10, y=10} }
      uut:capture_underground_entities_in_blueprint{ player_index = 1, area = area }
      assert.spy(editor_surface.find_entities_filtered).was_not.called()
    end)
  end)

  describe("manages ghosts", function()
    local surface_ghost
    local editor_ghost
    before_each(function()
        surface_ghost = {
        valid = true,
        surface = mocks.nauvis,
        name = "entity-ghost",
        type = "entity-ghost",
        ghost_name = "testeditor-bpproxy-validentity",
        ghost_type = "validtype",
        position = {x=0, y=0},
        force = "player",
        direction = 0,
        destroy = stub(),
      }
      editor_ghost = {
        valid = true,
        surface = editor_surface,
        name = "entity-ghost",
        type = "entity-ghost",
        ghost_name = "validentity",
        ghost_type = "validtype",
        position = {x=0, y=0},
        force = "player",
        direction = 0,
        destroy = stub(),
      }
    end)

    describe("new ghost creation", function()
      it("places underground ghosts when aboveground bpproxy ghosts are placed", function()
        editor_surface.find_entity = spy.new(function() return nil end)
        editor_surface.can_place_entity = spy.new(function() return true end)
        editor_surface.create_entity = spy.new(function() return editor_ghost end)

        uut:on_built_entity{
          player_index = 1,
          created_entity = surface_ghost,
        }

        assert.spy(editor_surface.can_place_entity).was.called_with{
          name = "validentity",
          position = {x=0, y=0},
          force = "player",
          direction = 0,
          build_check_type = _G.defines.build_check_type.ghost_place,
        }
        assert.spy(editor_surface.create_entity).was.called_with{
          name = "entity-ghost",
          inner_name = "validentity",
          position = {x=0, y=0},
          force = "player",
          direction = 0,
        }
      end)

      it("destroys newly placed aboveground bpproxy ghosts if underground is blocked", function()
        editor_surface.find_entity = spy.new(function() return nil end)
        editor_surface.can_place_entity = spy.new(function() return false end)

        uut:on_built_entity{
          player_index = 1,
          created_entity = surface_ghost,
        }

        assert.spy(editor_surface.can_place_entity).was.called_with{
          name = "validentity",
          position = {x=0, y=0},
          force = "player",
          direction = 0,
          build_check_type = _G.defines.build_check_type.ghost_place,
        }
        assert.stub(surface_ghost.destroy).was.called()
      end)

      it("places aboveground bpproxy ghosts when underground ghosts are placed", function()
        nauvis.create_entity = spy.new(function() return surface_ghost end)
        uut:on_built_entity{
          player_index = 1,
          created_entity = editor_ghost,
        }
        assert.spy(nauvis.create_entity).was.called_with{
          name = "entity-ghost",
          inner_name = "testeditor-bpproxy-validentity",
          position = {x=0, y=0},
          direction = 0,
          force = "player",
        }
      end)

      it("prevents bpproxy ghosts from being placed underground", function()
        local underground_bpproxy_ghost = {
          valid = true,
          name = "entity-ghost",
          ghost_name = "testeditor-bpproxy-validentity",
          position = {x=0,y=0},
          direction = 0,
          force = "player",
          surface = editor_surface,
          destroy = stub(),
        }

        uut:on_built_entity{ player_index = 1, created_entity = underground_bpproxy_ghost }
        assert.stub(underground_bpproxy_ghost.destroy).was.called()
      end)
    end)

    describe("ghost removal", function()
      describe("destroys aboveground ghosts when underground ghosts are removed", function()
        it("by mining or entity placement", function()
          nauvis.find_entities_filtered = spy.new(function() return {surface_ghost} end)
          uut:on_pre_player_mined_item{entity = editor_ghost}
          assert.spy(nauvis.find_entities_filtered).was.called_with{
            name = "entity-ghost",
            position = editor_ghost.position,
          }
          assert.stub(surface_ghost.destroy).was.called()
        end)

        it("by deconstruction planner", function()
          nauvis.find_entities_filtered = spy.new(function() return {surface_ghost} end)
          uut:on_pre_ghost_deconstructed{ghost = editor_ghost}
          assert.spy(nauvis.find_entities_filtered).was.called_with{
            name = "entity-ghost",
            position = editor_ghost.position,
          }
          assert.stub(surface_ghost.destroy).was.called()
        end)
      end)

      describe("destroys underground ghosts when aboveground ghosts are removed", function()
        it("by mining or entity placement", function()
          editor_surface.find_entities_filtered = spy.new(function() return {editor_ghost} end)
          uut:on_pre_player_mined_item{entity = surface_ghost}
          assert.spy(editor_surface.find_entities_filtered).was.called_with{
            name = "entity-ghost",
            position = surface_ghost.position,
          }
          assert.stub(editor_ghost.destroy).was.called()
        end)

        it("by deconstruction planner", function()
          editor_surface.find_entities_filtered = spy.new(function() return {editor_ghost} end)
          uut:on_pre_ghost_deconstructed{ghost = surface_ghost}
          assert.spy(editor_surface.find_entities_filtered).was.called_with{
            name = "entity-ghost",
            position = surface_ghost.position,
          }
          assert.stub(editor_ghost.destroy).was.called()
        end)
      end)
    end)

    describe("handles bpproxy construction", function()
      local bpproxy_entity = {
        valid = true,
        name = "testeditor-bpproxy-validentity",
        position = surface_ghost.position,
        direction = surface_ghost.direction,
        surface = nauvis,
        destroy = stub(),
      }

      describe("constructs underground entity when bpproxy is built", function()
        local function validate()
          assert.spy(editor_surface.create_entity).was.called_with{
            name = "validentity",
            position = surface_ghost.position,
            direction = surface_ghost.direction,
            force = surface_ghost.ghost,
          }
          assert.stub(nauvis.create_entity).was.called_with{
            name = "flying-text",
            position = bpproxy_entity.position,
            text = {"testeditor-message.created-underground", {"validentity-localised"}}
          }
          assert.stub(bpproxy_entity.destroy).was.called()
        end

        it("by player", function()
          editor_surface.create_entity = spy.new(function() return mocks.editor_entity end)
          bpproxy_entity.surface = nauvis
          nauvis.create_entity = stub()
          uut:on_built_entity{
            player_index = 1,
            created_entity = bpproxy_entity,
            stack = { name = "validitem", count = 1},
          }
          validate()
        end)

        it("by robot", function()
          editor_surface.create_entity = spy.new(function() return mocks.editor_entity end)
          bpproxy_entity.surface = nauvis
          nauvis.create_entity = stub()
          uut:on_robot_built_entity{
            robot = stub(),
            created_entity = bpproxy_entity,
            stack = { name = "validitem", count = 1},
          }
          validate()
        end)

        it("by Nanobots/Bluebuild", function()
          editor_surface.create_entity = spy.new(function() return mocks.editor_entity end)
          bpproxy_entity.surface = nauvis
          nauvis.create_entity = stub()
          uut:on_built_entity{
            player_index = 1,
            created_entity = bpproxy_entity,
            revive = true,
            revived = true,
          }
          validate()
        end)
      end)
    end)
  end)
end)