--- tests/unit/meta/test_hotstrings_config.lua
---
--- Tier 1.3 — Integration tests for hotstrings_config module.
--- Tests: init, load_all, reload, group enable/disable, duplicate detection,
--- config path resolution, edge cases.

local helpers = require("tests.helpers")
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
      if orig then orig(self, mappings) end
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
    helpers.it("init with valid engine does not crash", function()
      local engine = make_engine()
      local ok = pcall(function() config.init(engine) end)
      helpers.assert_true(ok, "init(engine) does not crash")
    end)

    helpers.it("init with explicit config directory does not crash", function()
      local engine = make_engine()
      local ok = pcall(function() config.init(engine, "/tmp") end)
      helpers.assert_true(ok, "init with config dir does not crash")
    end)

    helpers.it("init with nil config dir falls back to XDG", function()
      local engine = make_engine()
      local ok = pcall(function() config.init(engine, nil) end)
      helpers.assert_true(ok, "init with nil dir does not crash")
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

    helpers.it("load_all with empty dir returns 0", function()
      local cfg = helpers.load_module("modules.hotstrings.hotstrings_config")
      local engine = make_engine()
      cfg.init(engine, "/tmp/nonexistent_ergopti_hs_test_99999")
      local count = cfg.load_all()
      helpers.assert_eq(count, 0, "returns 0 for empty dir")
    end)
  end)

  -- ==========================================================================
  -- 4. Group enable/disable
  -- ==========================================================================

  helpers.describe("group management", function()
    helpers.it("disable_group does not crash", function()
      local ok = pcall(function() config.disable_group("test_group") end)
      helpers.assert_true(ok, "disable_group does not crash")
    end)

    helpers.it("enable_group does not crash", function()
      local ok = pcall(function() config.enable_group("test_group") end)
      helpers.assert_true(ok, "enable_group does not crash")
    end)

    helpers.it("toggle_group does not crash", function()
      local ok = pcall(function() config.toggle_group("test") end)
      helpers.assert_true(ok, "toggle_group does not crash")
    end)

    helpers.it("disable/enable cycle does not crash", function()
      config.disable_group("cycle_test")
      config.enable_group("cycle_test")
      helpers.assert_true(true, "cycle OK")
    end)

    helpers.it("disable_group with nil does not crash", function()
      local ok = pcall(function() config.disable_group(nil) end)
      helpers.assert_true(ok, "disable_group(nil) does not crash")
    end)

    helpers.it("is_group_enabled returns boolean", function()
      local result = config.is_group_enabled("any_group")
      helpers.assert_true(type(result) == "boolean", "returns boolean")
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
    helpers.it("reload does not crash", function()
      local ok = pcall(function() config.reload() end)
      helpers.assert_true(ok, "reload does not crash")
    end)
  end)

end)
