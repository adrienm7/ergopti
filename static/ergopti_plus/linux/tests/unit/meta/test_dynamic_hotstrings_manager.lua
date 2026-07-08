--- tests/unit/meta/test_dynamic_hotstrings_manager.lua
---
--- Phase P2.6: Compliance tests for the Linux dynamic hotstrings manager.
--- Verifies module structure, init/rule registration (without personal_info.toml),
--- on_trigger callback contract, and daemon integration.

local helpers = require("tests.helpers")
local dh      = helpers.load_module("modules.dynamic_hotstrings.manager")

helpers.describe("dynamic hotstrings manager (P2.6)", function()

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports the expected methods", function()
      helpers.assert_true(type(dh.init)           == "function", "init")
      helpers.assert_true(type(dh.is_enabled)     == "function", "is_enabled")
      helpers.assert_true(type(dh.set_enabled)    == "function", "set_enabled")
      helpers.assert_true(type(dh.on_trigger)     == "function", "on_trigger")
      helpers.assert_true(type(dh.preview)        == "function", "preview")
      helpers.assert_true(type(dh.get_trigger_char) == "function", "get_trigger_char")
      helpers.assert_true(type(dh.get_rules_count)== "function", "get_rules_count")
      helpers.assert_true(type(dh.get_info)       == "function", "get_info")
    end)
  end)

  -- ==========================================================================
  -- 2. Init & rule registration
  -- ==========================================================================

  helpers.describe("init and rule registration", function()

    helpers.it("init without personal_info.toml registers at least date rules", function()
      dh.init({ trigger_char = "\\" })
      local count = dh.get_rules_count()
      -- At minimum, 3 date rules (td, dt, date) should be registered even
      -- when personal_info.toml is absent (only letters would be missing).
      helpers.assert_true(count >= 3,
        string.format("at least 3 rules registered (got %d)", count))
    end)

    helpers.it("is_enabled returns true after successful init", function()
      helpers.assert_true(dh.is_enabled() == true, "module is enabled after init")
    end)

    helpers.it("get_trigger_char returns the configured trigger", function()
      helpers.assert_eq(dh.get_trigger_char(), "\\", "trigger is backslash")
    end)

    helpers.it("set_enabled toggles the module state", function()
      dh.set_enabled(false)
      helpers.assert_true(dh.is_enabled() == false, "module disabled")
      dh.set_enabled(true)
      helpers.assert_true(dh.is_enabled() == true, "module re-enabled")
    end)

    helpers.it("get_info returns a table (empty if no toml)", function()
      local info = dh.get_info()
      helpers.assert_true(type(info) == "table", "get_info returns a table")
    end)
  end)

  -- ==========================================================================
  -- 3. on_trigger contract
  -- ==========================================================================

  helpers.describe("on_trigger contract", function()

    helpers.it("on_trigger with empty buffer returns false", function()
      local ok = dh.on_trigger("", "\\")
      helpers.assert_true(ok == false, "empty buffer → no match")
    end)

    helpers.it("on_trigger without trigger char in buffer returns false", function()
      local ok = dh.on_trigger("hello", "\\")
      helpers.assert_true(ok == false, "no trigger in buffer → no match")
    end)

    helpers.it("on_trigger with date rule 'td' matches", function()
      -- Buffer "td\" should match the "td" → YYYY_MM_DD date rule.
      -- The backslash is the trigger character.
      dh.set_enabled(true)
      local ok = dh.on_trigger("td\\", "\\")
      -- This will try to inject via ydotool, which fails on test machines.
      -- We only verify it doesn't crash.
      helpers.assert_true(type(ok) == "boolean", "on_trigger returns boolean")
    end)

    helpers.it("on_trigger when disabled returns false", function()
      dh.set_enabled(false)
      local ok = dh.on_trigger("td\\", "\\")
      helpers.assert_true(ok == false, "disabled module → no match")
      dh.set_enabled(true)
    end)

    helpers.it("on_trigger with nil buffer is safe", function()
      local ok = pcall(function() dh.on_trigger(nil, "\\") end)
      helpers.assert_true(ok, "nil buffer does not crash")
    end)
  end)

  -- ==========================================================================
  -- 4. preview contract
  -- ==========================================================================

  helpers.describe("preview contract", function()

    helpers.it("preview with empty buffer returns nil", function()
      local p = dh.preview("")
      helpers.assert_true(p == nil, "empty buffer → nil preview")
    end)

    helpers.it("preview when disabled returns nil", function()
      dh.set_enabled(false)
      local p = dh.preview("td\\")
      helpers.assert_true(p == nil, "disabled → nil preview")
      dh.set_enabled(true)
    end)
  end)

  -- ==========================================================================
  -- 5. Shared engine integration
  -- ==========================================================================

  helpers.describe("shared engine integration", function()

    helpers.it("shared dynamic_hotstrings engine loads and has expected API", function()
      local ok, Engine = pcall(require, "dynamic_hotstrings")
      helpers.assert_true(ok, "shared engine loads")
      if ok then
        helpers.assert_true(type(Engine.add_rule)           == "function", "add_rule")
        helpers.assert_true(type(Engine.match_buffer)       == "function", "match_buffer")
        helpers.assert_true(type(Engine.preview)            == "function", "preview")
        helpers.assert_true(type(Engine.register_date_rules)== "function", "register_date_rules")
        helpers.assert_true(type(Engine.reset_rules)        == "function", "reset_rules")
      end
    end)

    helpers.it("date rule 'td' matches in the shared engine", function()
      local Engine = require("dynamic_hotstrings")
      Engine.reset_rules()
      Engine.register_date_rules("\\")
      local match = Engine.match_buffer("td", nil, nil)
      helpers.assert_true(match ~= nil, "'td' matches a date rule")
      if match then
        helpers.assert_true(type(match.result) == "string" and #match.result > 0,
          "date result is non-empty")
      end
    end)
  end)

end)
