--- tests/unit/meta/test_dynamic_hotstrings_manager.lua
---
--- Compliance tests for the Linux dynamic hotstrings manager.
--- Verifies module structure, init/rule registration (without personal_info.toml),
--- on_trigger callback contract, and daemon integration.

local helpers = require("tests.helpers")
local dh      = helpers.load_module("modules.dynamic_hotstrings.manager")

helpers.describe("dynamic hotstrings manager", function()

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

  -- ==========================================================================
  -- 6. Info field count (regression)
  -- ==========================================================================

  helpers.describe("info field count", function()

    helpers.it("logs the real [info] field count, not # of a string-keyed table", function()
      -- Write a personal_info.toml with two [info] fields so the parsed table is
      -- string-keyed; the length operator (#) wrongly reports 0 on such a table
      local tmp_dir   = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
      local toml_path = tmp_dir:gsub("\\", "/") .. "/ergopti_dh_info_count.toml"
      local fh = assert(io.open(toml_path, "w"))
      fh:write('[info]\nfirst_name = "Adrien"\nlast_name = "Moyaux"\n')
      fh:close()

      -- Spy on the logger the manager holds (require returns the cached table) so
      -- the exact field count reported by the init summary line is observable
      local logger    = require("logger.shim")
      local orig_info = logger.info
      local captured  = {}
      logger.info = function(_tag, fmt, ...)
        local n = select("#", ...)
        captured[#captured + 1] = (n > 0) and string.format(fmt, ...) or tostring(fmt)
      end

      local ok = pcall(function()
        dh.init({ trigger_char = "\\", personal_info_path = toml_path })
      end)

      -- Restore the logger and delete the fixture BEFORE asserting so no state
      -- leaks into later tests even when an assertion throws
      logger.info = orig_info
      os.remove(toml_path)

      helpers.assert_true(ok, "init did not crash")

      local summary = nil
      for _, m in ipairs(captured) do
        if m:find("Dynamic hotstrings initialised", 1, true) then summary = m end
      end
      helpers.assert_not_nil(summary, "init logged its summary line")
      -- RED before the fix: "info=0 field(s)" (# of a string-keyed table is 0)
      -- GREEN after the fix: "info=2 field(s)"
      helpers.assert_contains(summary, "info=2 field(s)",
        "init log reports the real [info] field count")
    end)

  end)

  -- ==========================================================================
  -- 7. @-tag personal-info concrete expansion values
  -- ==========================================================================

  helpers.describe("@-tag personal-info concrete expansion", function()

    -- The on_trigger / preview cases above only assert a boolean / non-nil
    -- shape, so a resolver wired to the wrong field, or a letters->info mapping
    -- that silently dropped a key, would still pass them. These cases pin the
    -- exact expanded value for an @-tag so such a regression turns the suite red.

    -- Writes a temp personal_info.toml with known [info] + [letters] so init
    -- registers @-tag rules whose resolvers return concrete values.
    local function write_temp_toml()
      local path = os.tmpname()
      local fh = assert(io.open(path, "w"))
      fh:write(table.concat({
        "[info]",
        'first_name = "Adrien"',
        'last_name = "Moyaux"',
        "",
        "[letters]",
        'p = "first_name"',
        'n = "last_name"',
        "",
      }, "\n"))
      fh:close()
      return path
    end

    helpers.it("preview expands '@p' to the mapped first_name value", function()
      local path = write_temp_toml()
      dh.init({ trigger_char = "\\", personal_info_path = path })
      dh.set_enabled(true)
      -- Buffer ends with the trigger; preview strips it and previews "@p".
      local p = dh.preview("@p\\")
      helpers.assert_eq(p, "Adrien", "preview of '@p' must expand to first_name, not a placeholder")
      os.remove(path)
    end)

    helpers.it("on_trigger injects the mapped last_name value for '@n'", function()
      local path = write_temp_toml()
      dh.init({ trigger_char = "\\", personal_info_path = path })
      dh.set_enabled(true)

      -- Capture the injection in-process instead of shelling out to ydotool
      -- (absent on the test host) so the concrete expanded value is assertable.
      local prev_injector = package.loaded["modules.hotstrings.injector"]
      local captured = nil
      package.loaded["modules.hotstrings.injector"] = {
        inject = function(backspace_count, text)
          captured = { backspace_count = backspace_count, text = text }
        end,
      }

      local ok = dh.on_trigger("@n\\", "\\")

      package.loaded["modules.hotstrings.injector"] = prev_injector
      os.remove(path)

      helpers.assert_true(ok == true, "on_trigger must report a successful expansion")
      helpers.assert_not_nil(captured, "the injector must receive the expansion")
      helpers.assert_eq(captured.text, "Moyaux", "on_trigger must inject last_name, not a placeholder")
      helpers.assert_eq(captured.backspace_count, 3, "must erase '@n' (2) + trigger (1) = 3 chars")
    end)

  end)

  -- ==========================================================================
  -- 8. Malformed personal_info.toml fail-fast
  -- ==========================================================================

  helpers.describe("malformed personal_info.toml fail-fast", function()

    -- Root cause: a syntactically invalid personal_info.toml used to be swallowed
    -- silently — the @-tag shortcuts simply vanished with no log. init() must
    -- instead surface the malformation loudly via Logger.error so the user knows
    -- their file was rejected rather than silently ignored.
    helpers.it("logs Logger.error when personal_info.toml is malformed", function()
      local tmp_dir   = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
      local toml_path = tmp_dir:gsub("\\", "/") .. "/ergopti_dh_malformed.toml"
      local fh = assert(io.open(toml_path, "w"))
      -- Unterminated table header — the shared toml_codec rejects it (decode → nil).
      fh:write("[info\nfirst_name = \"Adrien\"\n")
      fh:close()

      local logger     = require("logger.shim")
      local orig_error = logger.error
      local errors     = {}
      logger.error = function(_tag, fmt, ...)
        errors[#errors + 1] = (select("#", ...) > 0) and string.format(fmt, ...) or tostring(fmt)
      end

      local ok = pcall(function()
        dh.init({ trigger_char = "\\", personal_info_path = toml_path })
      end)

      -- Restore and clean up BEFORE asserting so nothing leaks on failure.
      logger.error = orig_error
      os.remove(toml_path)

      helpers.assert_true(ok, "init must not crash on a malformed TOML")
      local logged = false
      for _, m in ipairs(errors) do
        if m:find("malformed", 1, true) then logged = true end
      end
      helpers.assert_true(logged,
        "init must log an ERROR mentioning the malformed personal_info.toml")
    end)

  end)

end)
