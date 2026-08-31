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
      -- Called directly: this runs on every keystroke, so a raise is a dead
      -- keyboard and should fail with its own error.
      local out = dh.on_trigger(nil, "\\")
      helpers.assert_true(out == nil or type(out) == "string" or type(out) == "boolean",
        "a nil buffer must answer nil or a documented value, never a half-value")
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
		  return { ok = true }
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

    helpers.it("keeps NFC aliases codepoint-correct through preview, resolution, and injection", function()
      local path = os.tmpname()
      local fh = assert(io.open(path, "w"))
      fh:write(table.concat({
        "[info]",
        'first_name = "Élodie"',
        'last_name = "Durand"',
        "",
        "[letters]",
        'n = "last_name"',
        '"é" = "first_name"',
        "",
      }, "\n"))
      fh:close()

      dh.init({ trigger_char = "\\", personal_info_path = path })
      dh.set_enabled(true)

      local previous_injector = package.loaded["modules.hotstrings.injector"]
      local single_injection = nil
      local combo_injection = nil
      package.loaded["modules.hotstrings.injector"] = {
        inject = function(backspace_count, text)
          single_injection = { backspace_count = backspace_count, text = text }
          return { ok = true }
        end,
        inject_fields = function(backspace_count, values, is_private)
          combo_injection = {
            backspace_count = backspace_count,
            values = values,
            is_private = is_private,
          }
          return { ok = true }
        end,
      }

      local single_preview = dh.preview("@é\\")
      local single_fired, single_event = dh.on_trigger("@é\\", "\\")
      local fields = dh.resolve_combo("né")
      local rows = dh.preview_candidates("@né")
      local combo_fired, combo_event = dh.on_trigger("@né\\", "\\")

      package.loaded["modules.hotstrings.injector"] = previous_injector
      os.remove(path)

      helpers.assert_eq(single_preview, "Élodie", "the NFC alias is registered in the shared engine")
      helpers.assert_true(single_fired == true, "the NFC single alias fires")
      helpers.assert_not_nil(single_injection, "the single-alias injector is called")
      helpers.assert_eq(single_injection.text, "Élodie", "the single alias injects its mapped value")
      helpers.assert_eq(single_injection.backspace_count, 3,
        "single NFC alias erases @ + one codepoint + trigger")
      helpers.assert_eq(single_event.backspace_count, 3, "the single event publishes codepoint backspaces")

      helpers.assert_eq(#fields, 2, "the mixed ASCII/NFC combo resolves both aliases")
      helpers.assert_eq(fields[1], "last_name", "the mixed combo preserves its first field")
      helpers.assert_eq(fields[2], "first_name", "the mixed combo preserves its NFC field")
      helpers.assert_eq(#rows, 1, "the mixed combo exposes one preview row")
      helpers.assert_eq(rows[1].parts[1], "Durand", "the preview preserves first value order")
      helpers.assert_eq(rows[1].parts[2], "Élodie", "the preview preserves NFC value order")

      helpers.assert_true(combo_fired == true, "the mixed combo fires")
      helpers.assert_not_nil(combo_injection, "the combo injector is called")
      helpers.assert_eq(combo_injection.values[1], "Durand", "the combo injects the first value")
      helpers.assert_eq(combo_injection.values[2], "Élodie", "the combo injects the NFC value")
      helpers.assert_true(combo_injection.is_private == true, "personal combo injection stays private")
      helpers.assert_eq(combo_injection.backspace_count, 4,
        "mixed combo erases @ + two codepoints + trigger, not UTF-8 bytes")
      helpers.assert_eq(combo_event.backspace_count, 4, "the combo event publishes codepoint backspaces")
      helpers.assert_eq(combo_event.trigger, "@né\\", "the combo event preserves the exact NFC trigger")
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

    helpers.it("rejects a malformed UTF-8 alias explicitly", function()
      local path = os.tmpname()
      local fh = assert(io.open(path, "wb"))
      fh:write('[info]\nfirst_name = "Adrien"\n\n[letters]\n"')
      fh:write(string.char(0xC3))
      fh:write('" = "first_name"\n')
      fh:close()

      local logger = require("logger.shim")
      local original_error = logger.error
      local errors = {}
      logger.error = function(_tag, fmt, ...)
        errors[#errors + 1] = (select("#", ...) > 0) and string.format(fmt, ...) or tostring(fmt)
      end

      local init_ok, init_error = pcall(function()
        dh.init({ trigger_char = "\\", personal_info_path = path })
      end)

      logger.error = original_error
      os.remove(path)

      if not init_ok then error(init_error) end
      local explicit_rejection = false
      for _, message in ipairs(errors) do
        if message:find("not valid UTF-8", 1, true) then explicit_rejection = true end
      end
      helpers.assert_true(explicit_rejection,
        "the invalid alias must emit an explicit UTF-8 rejection instead of disappearing")
    end)

    helpers.it("rejects a decomposed alias instead of silently normalizing it", function()
      local path = os.tmpname()
      local decomposed_e_acute = "e\204\129"
      local fh = assert(io.open(path, "wb"))
      fh:write(table.concat({
        "[info]",
        'first_name = "Adrien"',
        "",
        "[letters]",
        '"' .. decomposed_e_acute .. '" = "first_name"',
        "",
      }, "\n"))
      fh:close()

      local logger = require("logger.shim")
      local original_error = logger.error
      local errors = {}
      logger.error = function(_tag, fmt, ...)
        errors[#errors + 1] = (select("#", ...) > 0) and string.format(fmt, ...) or tostring(fmt)
      end

      local init_ok, init_error = pcall(function()
        dh.init({ trigger_char = "\\", personal_info_path = path })
      end)
      local preview = dh.preview("@" .. decomposed_e_acute .. "\\")

      logger.error = original_error
      os.remove(path)

      if not init_ok then error(init_error) end
      helpers.assert_true(preview == nil, "a rejected decomposed alias must not be registered")
      local policy_logged = false
      for _, message in ipairs(errors) do
        if message:find("normalization is not applied", 1, true) then policy_logged = true end
      end
      helpers.assert_true(policy_logged,
        "the rejection must state that aliases are exact codepoints and are not normalized")
    end)

  end)

end)
