require "busted"
local serpent = require "serpent"

local function export_mocks(env, args)
  local defines = {
    build_check_type = {
      ghost_place = {},
    },
    deconstruction_item = {
      entity_filter_mode = {
        blacklist = {},
        whitelist = {},
      }
    },
    inventory = {
      robot_cargo = 1,
    },
  }
  env.defines = defines

  local temporary_stack = {
    create_blueprint = function() end,
    set_stack = function() end,
  }
  local temporary_inventory = {
    temporary_stack
  }
  local temporary_chest = {
    destroy = function() end,
    get_inventory = function() return temporary_inventory end,
  }
  mock(temporary_chest)

  local nauvis = {
    name = "nauvis",
    spill_item_stack = function() end,
    create_entity = function() return temporary_chest end,
  }

  local editor_surface = {
    name = "testeditor",
    is_chunk_generated = function() return true end,
    request_to_generate_chunks = stub(),
    force_generate_chunk_requests = stub(),
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
    force = "player",
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
    name = "testplayer",
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
    ["testeditor-bpproxy-validentity"] = { type = "validtype", items_to_place_this = {}, localised_name = {"validentity-localised"} },
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
    to_be_deconstructed = function() return false end,
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
    temporary_stack = temporary_stack,
  }
end

_G.global = {}
_G.remote = {
  interfaces = {}
}

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
    -- force reload to clear caches between test cases
    package.loaded["BaseEditor"] = nil
    BaseEditor = require "BaseEditor"
    BaseEditor.on_init()

    mocks = export_mocks(_G, {create_editor_surface = true})
    g, p, c = mocks.game, mocks.player, mocks.player.character
    editor_surface = mocks.editor_surface
    nauvis = mocks.nauvis
    uut = BaseEditor.new("testeditor")
    uut.valid_editor_types = {"validtype"}
  end)

  describe("creates editor surfaces", function()
    before_each(function()
      -- override with mocks that don't have the editor surface created
      mocks = export_mocks(_G, {create_editor_surface = false})
      editor_surface = mocks.editor_surface
      g, p = mocks.game, mocks.player
      uut = BaseEditor.new("testeditor")
    end)

    it("creates a surface on first toggle", function()
      uut:toggle_editor_status_for_player(1)
      assert.spy(g.create_surface).was.called_with("testeditor", match._)
    end)

    it("requests and waits for chunk to be generated", function()
      editor_surface.is_chunk_generated = function() return false end
      uut:toggle_editor_status_for_player(1)
      assert.stub(editor_surface.request_to_generate_chunks).was.called_with(p.position, 1)
      assert.stub(editor_surface.force_generate_chunk_requests).was.called()
    end)

    it("moves player to newly created surface", function()
      uut:toggle_editor_status_for_player(1)
      assert.spy(g.create_surface).was.called_with("testeditor", match._)
      assert.spy(p.teleport).was.called_with(p.position, g.surfaces.testeditor)
    end)

    it("uses sand tiles as fallback if no dirt autoplace control is available", function()
      g.autoplace_control_prototypes = {}
      uut:toggle_editor_status_for_player(1)
      local has_tile_setting = function(state, arguments)
        local tile_name = arguments[1]
        return function(value)
          return type(value) == "table" and
            value.autoplace_settings and
            value.autoplace_settings.tile and
            value.autoplace_settings.tile.settings and
            type(value.autoplace_settings.tile.settings[tile_name]) == "table"
        end
      end
      assert:register("matcher", "has_tile_setting", has_tile_setting)
      assert.spy(g.create_surface).was_called_with("testeditor", match.has_tile_setting("sand-1"))
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
      assert.are.equal(mocks.buffer[1].count, 0)
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
      nauvis.find_entities_filtered = function() return {} end
      uut:on_built_entity{
        mod_name = "upgrade-planner",
        player_index = 1,
        created_entity = mocks.editor_entity,
        stack = { name = "upgrade-planner", count = 1 },
      }
      assert.spy(c.remove_item).was.called_with{ name = "validitem", count = 1 }
    end)

    it("ignores upgrade planner actions not on an editor surface", function()
      uut:on_player_mined_item{
        mod_name = "upgrade-planner",
        player_index = 1,
        item_stack = { name = "validitem", count = 1 },
      }
      assert.spy(c.insert).was_not.called()
    end)
  end)

  describe("captures underground entities as bpproxies in blueprints", function()
    local area = { left_top = {x=-10, y=-10}, right_bottom = {x=10, y=10} }
    local bp, aboveground_bp_entities, editor_bp_entities
    before_each(function()
      bp = {
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
      p.blueprint_to_setup = bp

      aboveground_bp_entities = {
        {
          entity_number = 1,
          name = "validentity",
          position = {x=0, y=0},
        }
      }
      editor_bp_entities = {
        {
          entity_number = 1,
          name = "validentity",
          position = {x=0, y=0},
        }
      }
    end)

    it("translates position correctly", function()
      mocks.temporary_stack.get_blueprint_entities = function() return editor_bp_entities end 
      uut:capture_underground_entities_in_blueprint{ player_index = 1, area = area }
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
      mocks.temporary_stack.get_blueprint_entities = function() return nil end
      uut:capture_underground_entities_in_blueprint{ player_index = 1, area = area }
      assert.spy(editor_surface.find_entities_filtered).was_not.called()
    end)

    it("ignores entities like connectors with no bpproxy", function()
      bp.get_blueprint_entities = function()
        return {
          {
            entity_number = 1,
            name = "badentity",
            position = {x=0, y=0},
          }
        }
      end
      spy.on(bp, "set_blueprint_entities")
      mocks.temporary_stack.get_blueprint_entities = function() return {
          {
            entity_number = 1,
            name = "badentity",
            position = {x=2, y=2},
          }
        }
      end
      uut:capture_underground_entities_in_blueprint{ player_index = 1, area = area }
      assert.spy(bp.set_blueprint_entities).was.called_with{
        {
          entity_number = 1,
          name = "badentity",
          position = {x=0, y=0},
        },
      }
    end)

    it("and surface entities when taking a blueprint from an editor", function()
      p.surface = editor_surface
      mocks.temporary_stack.get_blueprint_entities = function() return {
          {
            entity_number = 1,
            name = "validentity",
            position = {x=0, y=0},
          }
        }
      end
      uut:capture_underground_entities_in_blueprint{ player_index = 1, area = area }
      assert.spy(bp.set_blueprint_entities).was.called_with{
        {
          entity_number = 1,
          name = "validentity",
          position = {x=0, y=0},
        },
        {
          entity_number = 2,
          name = "testeditor-bpproxy-validentity",
          position = {x=-2, y=-2},
        },
      }
    end)
  end)

  describe("manages ghosts", function()
    local surface_ghost_invalid_access
    local surface_ghost
    local editor_ghost_invalid_access
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
        last_user = p,
        destroy = stub(),
      }
      surface_ghost_invalid_access = spy.new(function(t, k) print("invalid key "..k.." accessed") end)
      setmetatable(surface_ghost, {
        __index = function(...) surface_ghost_invalid_access(...) end,
      })


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
        last_user = p,
        destroy = stub(),
      }
      editor_ghost_invalid_access = spy.new(function(t, k) print("invalid key "..k.." accessed") end)
      setmetatable(editor_ghost, {
        __index = function(...) editor_ghost_invalid_access(...) end,
      })
    end)

    describe("new ghost creation", function()
      it("places underground ghosts when aboveground bpproxy ghosts are placed", function()
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
        assert.are.equal(editor_ghost.last_user, surface_ghost.last_user)
        assert.stub(surface_ghost_invalid_access).was_not.called()
      end)

      it("copies belt_to_ground_type from underground-belt bpproxies", function()
        editor_surface.can_place_entity = spy.new(function() return true end)
        editor_surface.create_entity = spy.new(function() return editor_ghost end)

        surface_ghost.ghost_type = "underground-belt"
        surface_ghost.belt_to_ground_type = "output"
        uut:on_built_entity{
          player_index = 1,
          created_entity = surface_ghost,
        }

        assert.spy(editor_surface.can_place_entity).was.called_with{
          name = "validentity",
          position = {x=0, y=0},
          force = "player",
          direction = 0,
          type = "output",
          build_check_type = _G.defines.build_check_type.ghost_place,
        }
        assert.spy(editor_surface.create_entity).was.called_with{
          name = "entity-ghost",
          inner_name = "validentity",
          position = {x=0, y=0},
          force = "player",
          direction = 0,
          type = "output",
        }
        assert.are.equal(editor_ghost.last_user, surface_ghost.last_user)
        assert.stub(surface_ghost_invalid_access).was_not.called()
      end)

      it("copies loader_type from loader bpproxies", function()
        editor_surface.can_place_entity = spy.new(function() return true end)
        editor_surface.create_entity = spy.new(function() return editor_ghost end)

        surface_ghost.ghost_type = "loader"
        surface_ghost.loader_type = "output"
        uut:on_built_entity{
          player_index = 1,
          created_entity = surface_ghost,
        }

        assert.spy(editor_surface.can_place_entity).was.called_with{
          name = "validentity",
          position = {x=0, y=0},
          force = "player",
          direction = 0,
          type = "output",
          build_check_type = _G.defines.build_check_type.ghost_place,
        }
        assert.spy(editor_surface.create_entity).was.called_with{
          name = "entity-ghost",
          inner_name = "validentity",
          position = {x=0, y=0},
          force = "player",
          direction = 0,
          type = "output",
        }
        assert.are.equal(editor_ghost.last_user, surface_ghost.last_user)
        assert.stub(surface_ghost_invalid_access).was_not.called()
      end)

      it("destroys newly placed aboveground bpproxy ghosts if underground is blocked", function()
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
        assert.stub(surface_ghost_invalid_access).was_not.called()
      end)

      it("places aboveground bpproxy ghosts when underground ghosts are placed", function()
        nauvis.can_place_entity = spy.new(function() return true end)
        nauvis.create_entity = spy.new(function() return surface_ghost end)
        uut:on_built_entity{
          player_index = 1,
          created_entity = editor_ghost,
        }
        assert.spy(nauvis.can_place_entity).was.called_with{
          name = "testeditor-bpproxy-validentity",
          position = {x=0, y=0},
          direction = 0,
          force = "player",
          build_check_type = _G.defines.build_check_type.ghost_place,
        }
        assert.spy(nauvis.create_entity).was.called_with{
          name = "entity-ghost",
          inner_name = "testeditor-bpproxy-validentity",
          position = {x=0, y=0},
          direction = 0,
          force = "player",
        }
        assert.stub(editor_ghost_invalid_access).was_not.called()
      end)

      it("copies belt_to_ground_type for underground underground-belt ghosts", function()
        editor_ghost.ghost_type = "underground-belt"
        editor_ghost.belt_to_ground_type = "output"
        nauvis.can_place_entity = spy.new(function() return true end)
        nauvis.create_entity = spy.new(function() return surface_ghost end)
        uut:on_built_entity{
          player_index = 1,
          created_entity = editor_ghost,
        }
        assert.spy(nauvis.can_place_entity).was.called_with{
          name = "testeditor-bpproxy-validentity",
          position = {x=0, y=0},
          direction = 0,
          force = "player",
          type = "output",
          build_check_type = _G.defines.build_check_type.ghost_place,
        }
        assert.spy(nauvis.create_entity).was.called_with{
          name = "entity-ghost",
          inner_name = "testeditor-bpproxy-validentity",
          position = {x=0, y=0},
          direction = 0,
          force = "player",
          type = "output",
        }
        assert.stub(editor_ghost_invalid_access).was_not.called()
      end)

      it("copies loader_type for underground loader ghosts", function()
        editor_ghost.ghost_type = "loader"
        editor_ghost.loader_type = "output"
        nauvis.can_place_entity = spy.new(function() return true end)
        nauvis.create_entity = spy.new(function() return surface_ghost end)
        uut:on_built_entity{
          player_index = 1,
          created_entity = editor_ghost,
        }
        assert.spy(nauvis.can_place_entity).was.called_with{
          name = "testeditor-bpproxy-validentity",
          position = {x=0, y=0},
          direction = 0,
          force = "player",
          type = "output",
          build_check_type = _G.defines.build_check_type.ghost_place,
        }
        assert.spy(nauvis.create_entity).was.called_with{
          name = "entity-ghost",
          inner_name = "testeditor-bpproxy-validentity",
          position = {x=0, y=0},
          direction = 0,
          force = "player",
          type = "output",
        }
        assert.stub(editor_ghost_invalid_access).was_not.called()
      end)
    end)

    describe("handles placing a blueprint", function()
      local bp, nonproxy_ghost, proxy_ghost, editor_ghost
      before_each(function()
        bp = {
          valid = true,
          valid_for_read = true,
          is_blueprint = true,
          is_blueprint_setup = function() return true end,
          get_blueprint_entities = function()
            return {
              {
                entity_number = 1,
                name = "validentity",
                position = {x=0, y=0},
              },
              {
                entity_number = 2,
                name = "testeditor-bpproxy-validentity",
                position = {x=1, y=1},
              },
            }
          end,
        }
        p.cursor_stack = bp
        nonproxy_ghost = {
          valid = true,
          name = "entity-ghost",
          ghost_name = "validentity",
          force = "player",
          position = {x=10, y=10},
          direction = 4,
          last_user = p,
          destroy = stub(),
        }
        proxy_ghost = {
          valid = true,
          name = "entity-ghost",
          ghost_name = "testeditor-bpproxy-validentity",
          force = "player",
          position = {x=12, y=12},
          direction = 4,
          last_user = p,
          destroy = stub(),
        }
        editor_ghost = {
          valid = true,
          name = "entity-ghost",
          ghost_name = "validentity",
          force = "player",
          position = {x=12, y=12},
          direction = 4,
          last_user = p,
          destroy = stub(),
        }
      end)

      describe("with bpproxies", function()
        describe("above ground", function()
          it("when there is room in the editor", function()
            nonproxy_ghost.surface = nauvis
            proxy_ghost.surface = nauvis
            editor_surface.can_place_entity = function() return true end
            editor_surface.create_entity = spy.new(function() return editor_ghost end)
            uut:on_put_item{ player_index = 1 }
            uut:on_built_entity{ created_entity = nonproxy_ghost }
            uut:on_built_entity{ created_entity = proxy_ghost }
            assert.spy(editor_surface.create_entity).was.called_with{
              name = "entity-ghost",
              inner_name = "validentity",
              position = {x=12, y=12},
              force = "player",
              direction = 4,
            }
            assert.is_same(p, editor_ghost.last_user)
          end)

          it("when there is no room in the editor", function()
            nonproxy_ghost.surface = nauvis
            proxy_ghost.surface = nauvis
            editor_surface.can_place_entity = function() return false end
            editor_surface.create_entity = spy.new(function() return editor_ghost end)
            uut:on_put_item{ player_index = 1 }
            uut:on_built_entity{ created_entity = nonproxy_ghost }
            uut:on_built_entity{ created_entity = proxy_ghost }
            assert.spy(editor_surface.create_entity).was_not.called()
            assert.stub(proxy_ghost.destroy).was.called()
          end)
        end)

        describe("in an editor", function()
          it("when there is room in the editor", function()
            nonproxy_ghost.surface = editor_surface
            proxy_ghost.surface = editor_surface
            nauvis.can_place_entity = function() return true end
            nauvis.create_entity = spy.new(function() return nonproxy_ghost end)
            editor_surface.can_place_entity = spy.new(function() return true end)
            editor_surface.create_entity = spy.new(function() return editor_ghost end)
            uut:on_put_item{ player_index = 1 }
            uut:on_built_entity{ created_entity = nonproxy_ghost }
            uut:on_built_entity{ created_entity = proxy_ghost }
            assert.spy(nauvis.create_entity).was.called_with{
              name = "entity-ghost",
              inner_name = "validentity",
              position = {x=10, y=10},
              force = "player",
              direction = 4,
            }
            assert.stub(nonproxy_ghost.destroy).was.called()
            assert.spy(nauvis.create_entity).was.called_with{
              name = "entity-ghost",
              inner_name = "testeditor-bpproxy-validentity",
              position = {x=12, y=12},
              force = "player",
              direction = 4,
            }
            assert.spy(editor_surface.create_entity).was.called_with{
              name = "entity-ghost",
              inner_name = "validentity",
              position = {x=12, y=12},
              force = "player",
              direction = 4,
            }
            assert.is_equal(p, editor_ghost.last_user)
            assert.stub(proxy_ghost.destroy).was.called()
          end)

          it("when there is no room in the editor", function()
            nonproxy_ghost.surface = editor_surface
            proxy_ghost.surface = editor_surface
            nauvis.can_place_entity = function() return true end
            nauvis.create_entity = spy.new(function() return nonproxy_ghost end)
            editor_surface.can_place_entity = spy.new(function() return false end)
            editor_surface.create_entity = stub()
            uut:on_put_item{ player_index = 1 }
            uut:on_built_entity{ created_entity = nonproxy_ghost }
            uut:on_built_entity{ created_entity = proxy_ghost }
            assert.spy(nauvis.create_entity).was.called_with{
              name = "entity-ghost",
              inner_name = "validentity",
              position = {x=10, y=10},
              force = "player",
              direction = 4,
            }
            assert.stub(nonproxy_ghost.destroy).was.called()
            -- make sure only called once, as above, and not called to create bpproxy ghost
            assert.spy(nauvis.create_entity).was.called(1)
            assert.stub(editor_surface.create_entity).was_not.called()
            assert.stub(proxy_ghost.destroy).was.called()
          end)
        end)
      end)

      describe("without bpproxies", function()
        before_each(function()
          bp.get_blueprint_entities = function()
            return {
              {
                entity_number = 1,
                name = "validentity",
                position = {x=0, y=0},
              },
            }
          end
        end)

        it("in an editor should leave regular ghost in editor and create bpproxy for it", function()
          nonproxy_ghost.surface = editor_surface
          proxy_ghost.surface = nauvis
          nauvis.can_place_entity = function() return true end
          nauvis.create_entity = spy.new(function() return proxy_ghost end)
          editor_surface.create_entity = spy.new(function() return editor_ghost end)
          uut:on_put_item{ player_index = 1 }
          uut:on_built_entity{ created_entity = nonproxy_ghost }
          assert.spy(nauvis.create_entity).was.called_with{
            name = "entity-ghost",
            inner_name = "testeditor-bpproxy-validentity",
            position = {x=10, y=10},
            force = "player",
            direction = 4,
          }
          assert.stub(nonproxy_ghost.destroy).was_not.called()
        end)
      end)

      describe("with entities that are not valid for the editor", function()
        local bp, ghost
        before_each(function()
          bp = {
            valid_for_read = true,
            is_blueprint = true,
            is_blueprint_setup = function() return true end,
            get_blueprint_entities = function()
              return {
                {
                  entity_number = 1,
                  name = "badentity",
                  position = {x=0, y=0},
                },
                {
                  entity_number = 2,
                  name = "testeditor-bpproxy-validentity",
                  position = {x=1, y=1},
                },
              }
            end,
          }
          p.cursor_stack = bp
          ghost = {
            valid = true,
            name = "entity-ghost",
            ghost_name = "badentity",
            surface = editor_surface,
            position = {x=5, y=5},
            force = "player",
            direction = 2,
            destroy = stub(),
          }
        end)

        describe("with bpproxies", function()
          it("creates ghosts above ground and removes editor ghosts", function()
            nauvis.can_place_entity = function() return true end
            uut:on_put_item{ player_index = 1 }
            uut:on_built_entity{ created_entity = ghost }
            assert.spy(nauvis.create_entity).was.called_with{
              name = "entity-ghost",
              inner_name = "badentity",
              position = {x=5, y=5},
              force = "player",
              direction = 2,
            }
            assert.stub(ghost.destroy).was.called()
          end)
        end)

        describe("without bpproxies", function()
          it("destroys the editor ghosts", function()
            bp.get_blueprint_entities = function()
              return {
                {
                  entity_number = 1,
                  name = "badentity",
                  position = {x=0, y=0},
                },
              }
            end
            uut:on_put_item{ player_index = 1 }
            uut:on_built_entity{ created_entity = ghost }
            assert.spy(nauvis.create_entity).was_not.called()
            assert.stub(ghost.destroy).was.called()
          end)
        end)
      end)
    end)

    describe("ghost removal", function()
      describe("destroys aboveground ghosts when underground ghosts are removed", function()
        it("by mining", function()
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

        it("by entity placement", function()
          local matching_entity = {
            valid = true,
            name = "validentity",
            type = "validtype",
            position = editor_ghost.position,
            direction = editor_ghost.position,
            force = editor_ghost.force,
            surface = editor_surface,
          }
          nauvis.find_entities_filtered = spy.new(function() return {surface_ghost} end)
          uut:on_built_entity{created_entity = matching_entity}
          assert.spy(nauvis.find_entities_filtered).was.called_with{
            ghost_name = "testeditor-bpproxy-validentity",
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
      local invalid_field_access_stub
      local bpproxy_entity

      before_each(function()
        invalid_field_access_stub = spy.new(function(t,k) print("field "..k.." accessed on "..(t.name)) end)
        bpproxy_entity = {
          valid = true,
          name = "testeditor-bpproxy-validentity",
          type = "validtype",
          force = surface_ghost.force,
          position = surface_ghost.position,
          direction = surface_ghost.direction,
          surface = nauvis,
          destroy = stub(),
        }
        setmetatable(bpproxy_entity, {
           __index = function(t, k) invalid_field_access_stub(t, k) end
        })
      end)

      describe("constructs underground entity when bpproxy is built", function()
        local function validate(type)
          assert.spy(editor_surface.create_entity).was.called_with{
            name = "validentity",
            position = surface_ghost.position,
            direction = surface_ghost.direction,
            force = surface_ghost.force,
            type = type,
          }
          assert.stub(nauvis.create_entity).was.called_with{
            name = "flying-text",
            position = bpproxy_entity.position,
            text = {"testeditor-message.created-underground", {"validentity-localised"}}
          }
          assert.stub(bpproxy_entity.destroy).was.called()
          assert.stub(invalid_field_access_stub).was_not.called()
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

        it("copies belt_to_ground_type for underground-belt entities", function()
          editor_surface.create_entity = spy.new(function() return mocks.editor_entity end)
          bpproxy_entity.surface = nauvis
          bpproxy_entity.type = "underground-belt"
          bpproxy_entity.belt_to_ground_type = "input"
          nauvis.create_entity = stub()
          uut:on_built_entity{
            player_index = 1,
            created_entity = bpproxy_entity,
            stack = { name = "validitem", count = 1},
          }
          validate("input")
        end)

        it("copies loader_type for loader entities", function()
          editor_surface.create_entity = spy.new(function() return mocks.editor_entity end)
          bpproxy_entity.surface = nauvis
          bpproxy_entity.type = "loader"
          bpproxy_entity.loader_type = "input"
          nauvis.create_entity = stub()
          uut:on_built_entity{
            player_index = 1,
            created_entity = bpproxy_entity,
            stack = { name = "validitem", count = 1},
          }
          validate("input")
        end)
      end)
    end)
  end)

  describe("handles deconstruction", function()
    local position = {x = 0, y = 0}
    local bpproxy_entity
    local editor_entity
    before_each(function()
      bpproxy_entity = {
        valid = true,
        name = "testeditor-bpproxy-validentity",
        type = "validtype",
        force = "player",
        surface = nauvis,
        position = position,
        direction = 0,
        to_be_deconstructed = spy.new(function() return true end),
        order_deconstruction = stub(),
        destroy = stub(),
      }
      editor_entity = {
        valid = true,
        name = "validentity",
        type = "validtype",
        force = "player",
        surface = editor_surface,
        position = position,
        direction = 0,
        destroy = stub(),
        to_be_deconstructed = spy.new(function() return true end),
        order_deconstruction = stub(),
        cancel_deconstruction = stub(),
      }
      editor_surface.find_entities_filtered = spy.new(function() return {editor_entity} end)
    end)

    describe("creates bpproxy entities when", function()
      describe("using a deconstruction item above ground", function()
        local tool
        before_each(function()
          tool = {
            valid = true,
            valid_for_read = true,
            is_deconstruction_item = true,
            entity_filter_mode = defines.deconstruction_item.entity_filter_mode.whitelist,
            entity_filters = {},
          }
        end)
        local function test_with_tool(should_deconstruct)
          nauvis.create_entity = spy.new(function() return bpproxy_entity end)
          local area = {left_top = {x=-10, y=-10}, right_bottom = {x=10,y=10}}
          uut:order_underground_deconstruction(p, editor_surface, area, tool)
          assert.spy(editor_surface.find_entities_filtered).was.called_with{
            area = area,
          }

          if should_deconstruct then
            assert.spy(nauvis.create_entity).was.called_with{
              name = "testeditor-bpproxy-validentity",
              position = position,
              force = "player",
              direction = 0,
            }
            assert.spy(bpproxy_entity.order_deconstruction).was.called_with(p.force, p)
            assert.spy(editor_entity.order_deconstruction).was.called_with(p.force, p)
          else
            assert.spy(nauvis.create_entity).was_not.called()
            assert.spy(bpproxy_entity.order_deconstruction).was_not.called()
            assert.spy(editor_entity.order_deconstruction).was_not.called()
          end
        end

        it("with no filter set", function()
          test_with_tool(true)
        end)

        it("with matching whitelist", function()
          tool.entity_filters = {"validentity"}
          test_with_tool(true)
        end)

        it("with whitelist that does not match", function()
          tool.entity_filters = {"badentity"}
          test_with_tool(false)
        end)

        it("with empty blacklist", function()
          tool.entity_filter_mode = defines.deconstruction_item.entity_filter_mode.blacklist
          test_with_tool(true)
        end)

        it("with entity blacklisted", function()
          tool.entity_filter_mode = defines.deconstruction_item.entity_filter_mode.blacklist
          tool.entity_filters = {"validentity"}
          test_with_tool(false)
        end)

        it("ignores underground entities have no available proxy (e.g. connectors)", function()
          local badentity = {
            valid = true,
            name = "badentity",
            position = position,
            surface = editor_surface,
          }
          editor_surface.find_entities_filtered = spy.new(function() return {badentity} end)
          test_with_tool(false)
        end)
      end)

      describe("using a deconstruction item underground", function()
        it("on standard entity", function()
          nauvis.create_entity = spy.new(function() return bpproxy_entity end)
          uut:on_marked_for_deconstruction{
            player_index = 1,
            entity = editor_entity,
          }
          assert.spy(nauvis.create_entity).was.called_with{
            name = "testeditor-bpproxy-validentity",
            position = position,
            force = "player",
            direction = 0,
          }
          assert.spy(bpproxy_entity.order_deconstruction).was.called_with(p.force, p)
        end)

        it("on underground-belt", function()
          editor_entity.type = "underground-belt"
          editor_entity.belt_to_ground_type = "input"
          nauvis.create_entity = spy.new(function() return bpproxy_entity end)
          uut:on_marked_for_deconstruction{
            player_index = 1,
            entity = editor_entity,
          }
          assert.spy(nauvis.create_entity).was.called_with{
            name = "testeditor-bpproxy-validentity",
            position = position,
            force = "player",
            direction = 0,
            type = "input",
          }
        end)

        it("on loader", function()
          editor_entity.type = "loader"
          editor_entity.loader_type = "input"
          nauvis.create_entity = spy.new(function() return bpproxy_entity end)
          uut:on_marked_for_deconstruction{
            player_index = 1,
            entity = editor_entity,
          }
          assert.spy(nauvis.create_entity).was.called_with{
            name = "testeditor-bpproxy-validentity",
            position = position,
            force = "player",
            direction = 0,
            type = "input",
          }
        end)
      end)
    end)

    describe("does not create bpproxy entities when", function()
      it("an underground entity with no proxy (e.g. a connector) is marked", function()
        local badentity = {
          valid = true,
          name = "badentity",
          position = position,
          surface = editor_surface,
        }
        nauvis.create_entity = stub()
        uut:on_marked_for_deconstruction{ entity = badentity }
        assert.stub(nauvis.create_entity).was_not.called()
      end)
    end)

    describe("destroys bpproxy entities when", function()
      it("unmarking underground entities", function()
        nauvis.find_entity = spy.new(function() return bpproxy_entity end)
        uut:on_canceled_deconstruction{
          player_index = 1,
          entity = editor_entity,
        }
        assert.spy(nauvis.find_entity).was.called_with("testeditor-bpproxy-validentity", position)
        assert.stub(bpproxy_entity.destroy).was.called()
      end)

      it("mining marked underground entities", function()
        uut:toggle_editor_status_for_player(1)
        nauvis.find_entity = spy.new(function() return bpproxy_entity end)
        uut:on_player_mined_entity{
          player_index = 1,
          entity = editor_entity,
          buffer = mocks.buffer,
        }
        assert.spy(nauvis.find_entity).was.called_with("testeditor-bpproxy-validentity", position)
        assert.stub(bpproxy_entity.destroy).was.called()
      end)

      it("unmarking bpproxy entities", function()
        editor_surface.find_entity = spy.new(function() return editor_entity end)
        uut:on_canceled_deconstruction{
          player_index = 1,
          entity = bpproxy_entity,
        }
        assert.spy(editor_surface.find_entity).was.called_with("validentity", position)
        assert.stub(bpproxy_entity.destroy).was.called()
        assert.spy(editor_entity.cancel_deconstruction).was.called_with(p.force, p)
      end)
    end)

    describe("destroys underground entity when mining a bpproxy", function()
      it("by hand", function()
        editor_surface.find_entity = spy.new(function() return editor_entity end)
        uut:on_player_mined_entity{
          player_index = 1,
          entity = bpproxy_entity,
          buffer = mocks.buffer
        }
        assert.spy(editor_surface.find_entity).was.called_with("validentity", position)
        assert.spy(editor_entity.destroy).was.called()
      end)

      it("by robot", function()
        editor_surface.find_entity = spy.new(function() return editor_entity end)
        uut:on_robot_mined_entity{
          player_index = 1,
          entity = bpproxy_entity,
          buffer = mocks.buffer
        }
        assert.spy(editor_surface.find_entity).was.called_with("validentity", position)
        assert.stub(editor_entity.destroy).was.called()
      end)
    end)

    describe("ignores surface entities that are not proxies when mined", function()
      local badentity = {
        valid = true,
        name = "badentity",
        surface = nauvis,
        position = position,
      }
      before_each(function()
        editor_surface.find_entity = stub()
      end)

      it("by hand", function()
        uut:on_player_mined_entity{entity = badentity}
        assert.spy(editor_surface.find_entity).was_not.called()
      end)

      it("by robot", function()
        uut:on_robot_mined_entity{entity = badentity}
        assert.spy(editor_surface.find_entity).was_not.called()
      end)
    end)
  end)

  describe("returns contents of mined", function()
    local buffer
    local position = {}
    local bpproxy = {
      name = "testeditor-bpproxy-transport-belt",
      surface = nauvis,
      position = position,
    }
    before_each(function()
      buffer = mocks.buffer
      buffer.insert = stub()
    end)
    local function create_tl()
      return {
        [1] = {
          valid = true,
          valid_for_read = true,
          name = "iron-plate",
          count = 1,
        },
        clear = stub(),
      }
    end

    local belt_entity
    local transport_lines
    local function validate()
      assert.spy(editor_surface.find_entity).was.called_with(belt_entity.name, position)
      for _, line in ipairs(transport_lines) do
        assert.spy(mocks.buffer.insert).was.called_with(line[1])
        assert.stub(line.clear).was.called()
      end
      assert.stub(belt_entity.destroy).was.called()
    end

    describe("transport belt", function()
      before_each(function()
        transport_lines = {create_tl(), create_tl()}
        belt_entity = {
          valid = true,
          name = "transport-belt",
          type = "transport-belt",
          surface = editor_surface,
          position = position,
          get_transport_line = function(i) return transport_lines[i] end,
          destroy = stub(),
        }
        editor_surface.find_entity = spy.new(function() return belt_entity end)
      end)

      it("when mined by hand", function()
        uut:on_player_mined_entity{
          entity = bpproxy,
          buffer = mocks.buffer,
        }
        validate()
      end)

      it("when mined by robot", function()
        uut:on_robot_mined_entity{
          entity = bpproxy,
          buffer = mocks.buffer,
        }
        validate()
      end)
    end)

    describe("underground belt", function()
      before_each(function()
        bpproxy.name = "testeditor-bpproxy-underground-belt"
        transport_lines = {create_tl(), create_tl(), create_tl(), create_tl()}
        belt_entity = {
          valid = true,
          name = "underground-belt",
          type = "underground-belt",
          surface = editor_surface,
          position = position,
          get_transport_line = function(i) return transport_lines[i] end,
          destroy = stub(),
        }
        editor_surface.find_entity = spy.new(function() return belt_entity end)
      end)

      it("when mined by hand", function()
        uut:on_player_mined_entity{
          entity = bpproxy,
          buffer = mocks.buffer,
        }
        validate()
      end)

      it("when mined by robot", function()
        uut:on_robot_mined_entity{
          entity = bpproxy,
          buffer = mocks.buffer,
        }
        validate()
      end)
    end)

    describe("splitter", function()
      before_each(function()
        bpproxy.name = "testeditor-bpproxy-splitter"
        transport_lines = {}
        for i=1,8 do transport_lines[i] = create_tl() end
        belt_entity = {
          valid = true,
          name = "splitter",
          type = "splitter",
          surface = editor_surface,
          position = position,
          get_transport_line = function(i) return transport_lines[i] end,
          destroy = stub(),
        }
        editor_surface.find_entity = spy.new(function() return belt_entity end)
      end)

      it("when mined by hand", function()
        uut:on_player_mined_entity{
          entity = bpproxy,
          buffer = mocks.buffer,
        }
        validate()
      end)

      it("when mined by robot", function()
        uut:on_robot_mined_entity{
          entity = bpproxy,
          buffer = mocks.buffer,
        }
        validate()
      end)
    end)
  end)
end)