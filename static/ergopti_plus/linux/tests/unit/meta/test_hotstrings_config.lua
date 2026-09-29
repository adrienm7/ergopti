--- tests/unit/meta/test_hotstrings_config.lua
---
--- Tier 1.3 — Integration tests for hotstrings_config module.
--- Tests: init, load_all, reload, group enable/disable, duplicate detection,
--- config path resolution, edge cases.

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")
local config  = helpers.load_module("modules.hotstrings.hotstrings_config")
local engine_mod = helpers.load_module("modules.hotstrings.engine")

helpers.describe("hotstrings_config", function()

  -- Create a minimal engine stub for testing.
  local function make_engine()
    local e = engine_mod.new()
    -- Track what was loaded for assertions.
    e._loaded = {}
    local orig = e.load_mappings
    e.load_mappings = function(self, mappings)
      e._loaded = mappings
      if orig then return orig(self, mappings) end
    end
    return e
  end

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports init", function()
      helpers.assert_true(type(config.init) == "function", "init is a function")
    end)
    helpers.it("exports load_all", function()
      helpers.assert_true(type(config.load_all) == "function", "load_all is a function")
    end)
    helpers.it("exports reload", function()
      helpers.assert_true(type(config.reload) == "function", "reload is a function")
    end)
    helpers.it("exports disable_group", function()
      helpers.assert_true(type(config.disable_group) == "function", "disable_group is a function")
    end)
    helpers.it("exports enable_group", function()
      helpers.assert_true(type(config.enable_group) == "function", "enable_group is a function")
    end)
    helpers.it("exports toggle_group", function()
      helpers.assert_true(type(config.toggle_group) == "function", "toggle_group is a function")
    end)
    helpers.it("exports get_groups", function()
      helpers.assert_true(type(config.get_groups) == "function", "get_groups is a function")
    end)
    helpers.it("exports mapping_count", function()
      helpers.assert_true(type(config.mapping_count) == "function", "mapping_count is a function")
    end)
  end)

  -- ==========================================================================
  -- 2. init()
  -- ==========================================================================

  helpers.describe("init()", function()
    -- Called directly, not through pcall: a raise fails the case with the real
    -- error, which says more than a boolean. What each case asserts instead is
    -- what init LEFT BEHIND — a config module that swallowed its engine and
    -- initialised nothing passes "does not crash" and expands nothing at runtime.
    helpers.it("init with a valid engine leaves the module usable", function()
      local engine = make_engine()
      config.init(engine)
      helpers.assert_eq(type(config.is_group_enabled("anything")), "boolean",
        "after init the group reader must answer")
    end)

    helpers.it("init with an explicit config directory leaves the module usable", function()
      local engine = make_engine()
      config.init(engine, "/tmp")
      helpers.assert_eq(type(config.is_group_enabled("anything")), "boolean",
        "an explicit directory must not change whether the module answers")
    end)

    helpers.it("init with a nil config dir falls back to XDG and still answers", function()
      local engine = make_engine()
      config.init(engine, nil)
      helpers.assert_eq(type(config.is_group_enabled("anything")), "boolean",
        "the XDG fallback is the default path — if it left the module mute, every "
          .. "install with no explicit directory would silently expand nothing")
    end)
  end)

  -- ==========================================================================
  -- 3. load_all() — no TOML files case (tests robustness, not correctness)
  -- ==========================================================================

  helpers.describe("load_all()", function()
    helpers.it("load_all without init returns 0 gracefully", function()
      -- Reset module state by re-requiring.
      local cfg = helpers.load_module("modules.hotstrings.hotstrings_config")
      local count = cfg.load_all()
      helpers.assert_eq(count, 0, "returns 0 without init")
    end)

    helpers.it("a user directory that does not exist still loads the bundled packs", function()
      -- Discovery is independent of opt-in. Isolate the preference adapter so
      -- explicit activation cannot leak into other cases or depend on their state.
      local previous_storage = package.loaded["adapters.storage"]
      local previous_config = package.loaded["modules.hotstrings.hotstrings_config"]
      package.loaded["adapters.storage"] = Fakes.storage()
      local ok, err = pcall(function()
        local cfg = helpers.load_module("modules.hotstrings.hotstrings_config")
        local engine = make_engine()
        cfg.init(engine, os.tmpname() .. "_absent_hotstring_directory")
        cfg.load_all()

        local Loader = require("modules.hotstrings.loader")
        local Paths = require("infra.paths")
        local bundled = Loader.find_toml_files(Paths.shared("modules/hotstrings"))
        helpers.assert_true(#bundled > 0, "fixture requires the actual bundled TOML inventory")
        helpers.assert_true(cfg.mapping_count() > 0,
          "an absent personal directory must not hide discovered bundled mappings")

        helpers.assert_true(cfg.disable_all() ~= false, "explicit group disable must commit")
        helpers.assert_eq(#engine._loaded, 0, "disabled groups must leave no effective engine mappings")
        helpers.assert_true(cfg.mapping_count() > 0,
          "the discovered inventory must remain available while its groups are disabled")
        helpers.assert_true(cfg.enable_all() ~= false, "explicit group and section activation must commit")
        helpers.assert_true(#engine._loaded > 0,
          "explicit activation must hand the discovered mappings to the real engine")

        -- Replay an actual bundled trigger through the real matcher: recording a
        -- non-empty argument alone would miss an engine that ignores publication.
        local matched = false
        for _, mapping in ipairs(engine._loaded) do
          if mapping.auto_expand then
            engine:reset()
            local result
            for char in mapping.trigger:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
              result = engine:on_char(char)
            end
            if result and result.trigger == mapping.trigger and result.group == mapping.group then
              matched = true
              break
            end
          end
        end
        helpers.assert_true(matched, "the real engine must execute an explicitly activated bundled trigger")
      end)
      package.loaded["adapters.storage"] = previous_storage
      package.loaded["modules.hotstrings.hotstrings_config"] = previous_config
      if not ok then error(err, 0) end
    end)
  end)

  -- ==========================================================================
  -- 4. Group enable/disable
  -- ==========================================================================

  helpers.describe("group management", function()
    helpers.it("disable_group disables the group it names", function()
      config.disable_group("test_group")
      helpers.assert_eq(config.is_group_enabled("test_group"), false,
        "a disable that does not disable is the whole bug this reader exists to catch")
    end)

    helpers.it("enable_group enables the group it names", function()
      config.enable_group("test_group")
      helpers.assert_eq(config.is_group_enabled("test_group"), true,
        "and the other direction")
    end)

    helpers.it("toggle_group inverts the state it found", function()
      local before = config.is_group_enabled("test")
      config.toggle_group("test")
      helpers.assert_eq(config.is_group_enabled("test"), not before,
        "a toggle that lands on the same state is a menu row that does nothing")
    end)

    helpers.it("a disable/enable cycle ends where it started", function()
      -- "cycle OK" asserted with true. The point of a cycle is that it returns
      -- the state it found: a disable that persisted past the enable leaves a
      -- group silently off, which the user reads as expansions that stopped
      -- working for no reason.
      local before = config.is_group_enabled("cycle_test")
      config.disable_group("cycle_test")
      helpers.assert_eq(config.is_group_enabled("cycle_test"), false,
        "disable must actually disable, or the cycle below proves nothing")
      config.enable_group("cycle_test")
      helpers.assert_eq(config.is_group_enabled("cycle_test"), true,
        "and enable must undo it")
      if not before then config.disable_group("cycle_test") end
    end)

    helpers.it("disable_group(nil) changes nothing", function()
      config.enable_group("nil_probe")
      config.disable_group(nil)
      helpers.assert_eq(config.is_group_enabled("nil_probe"), true,
        "a nil group name must be refused, not applied to whatever was last touched")
    end)

    helpers.it("is_group_enabled returns boolean", function()
      local result = config.is_group_enabled("any_group")
      helpers.assert_true(type(result) == "boolean", "returns boolean")
    end)

    helpers.it("keeps the durable group state when persistence fails", function()
      local previous_storage = package.loaded["adapters.storage"]
      local previous_config = package.loaded["modules.hotstrings.hotstrings_config"]
      local storage = Fakes.storage({ writes_fail = true })
      package.loaded["adapters.storage"] = storage
      package.loaded["modules.hotstrings.hotstrings_config"] = nil
      local failing = require("modules.hotstrings.hotstrings_config")
      failing.init(make_engine(), "/tmp/nonexistent_ergopti_hs_transaction")

      local changed = failing.disable_group("transaction_probe")
      local enabled = failing.is_group_enabled("transaction_probe")

      package.loaded["adapters.storage"] = previous_storage
      package.loaded["modules.hotstrings.hotstrings_config"] = previous_config
      helpers.assert_eq(changed, false, "a failed write must be reported")
      helpers.assert_eq(enabled, true,
        "a failed write must not publish a disabled group only for this session")
      helpers.assert_eq(storage.get("hotstrings.disabled_groups", nil), nil)
    end)
  end)

  -- ==========================================================================
  -- 5. Queries
  -- ==========================================================================

  helpers.describe("queries", function()
    helpers.it("mapping_count returns number", function()
      local n = config.mapping_count()
      helpers.assert_true(type(n) == "number", "returns number")
    end)

    helpers.it("parse_error_count returns number", function()
      local n = config.parse_error_count()
      helpers.assert_true(type(n) == "number", "returns number")
    end)

    helpers.it("get_config_dir returns string or nil", function()
      local d = config.get_config_dir()
      helpers.assert_true(d == nil or type(d) == "string", "returns string or nil")
    end)

    helpers.it("get_groups returns table", function()
      local groups = config.get_groups()
      helpers.assert_true(type(groups) == "table", "returns table")
    end)
  end)

  -- ==========================================================================
  -- 6. reload()
  -- ==========================================================================

  helpers.describe("reload()", function()
    helpers.it("reload leaves the module answering", function()
      config.reload()
      helpers.assert_eq(type(config.is_group_enabled("anything")), "boolean",
        "reload runs on every config-file change; one that left the module mute would "
          .. "stop every expansion until the next restart")
    end)
  end)

end)
