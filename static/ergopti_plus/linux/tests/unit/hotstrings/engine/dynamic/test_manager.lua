--- tests/unit/hotstrings/engine/dynamic/test_manager.lua
---
--- Compliance tests for the Linux dynamic hotstrings manager.
--- Verifies module structure, init/rule registration (without personal_info.toml),
--- on_trigger callback contract, and daemon integration.

local helpers = require("tests.helpers")
local restore_family_preferences = require("tests.support.dynamic_hotstrings_fixture").install()
local dh      = helpers.load_module("hotstrings.engine.dynamic.manager")

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
      helpers.assert_true(type(dh.get_letters)    == "function", "get_letters")
      helpers.assert_true(type(dh.save_info)      == "function", "save_info")
    end)
  end)

  -- ==========================================================================
  -- 2. Init & rule registration
  -- ==========================================================================

  helpers.describe("init and rule registration", function()

    helpers.it("linux-dynamic-init-cancel: refuses reinitialization when programmable cancellation fails", function()
      local UserCode = require("hotstrings.engine.dynamic.user_code")
      local Engine = require("hotstrings.engine.dynamic.core")
      local old_invalidate, old_reset = UserCode.invalidate, Engine.reset_rules
      local old_manager = package.loaded["hotstrings.engine.dynamic.manager"]
      local manager = helpers.load_module("hotstrings.engine.dynamic.manager")
      local previous_trigger = manager.get_trigger_char()
      local resets = 0
      UserCode.invalidate = function() return false end
      Engine.reset_rules = function(...) resets = resets + 1; return old_reset(...) end
      local ok, result = pcall(manager.init, { trigger_char = "§" })
      UserCode.invalidate, Engine.reset_rules = old_invalidate, old_reset
      package.loaded["hotstrings.engine.dynamic.manager"] = old_manager
      helpers.assert_true(ok)
      helpers.assert_eq(result, false)
      helpers.assert_eq(manager.get_trigger_char(), previous_trigger)
      helpers.assert_eq(resets, 0, "a refused programmable cancellation must preserve the active rules")
    end)

    helpers.it("personal info FIFO is refused without blocking dynamic initialization", function()
      local uv = require("luv")
      local shell = require("core.process.adapters.shell_runner")
      local path = os.tmpname()
      os.remove(path)
      assert(shell.run("mkfifo -- " .. shell.quote(path)))
      local code = string.format([[package.path = %q
local manager = require("hotstrings.engine.dynamic.manager")
assert(manager.init({ personal_info_path = %q }))
assert(next(manager.get_info()) == nil)
]], package.path, path)
      local exited, expired, status, signal = false, false, nil, nil
      local timer = assert(uv.new_timer())
      local child
      child = assert(uv.spawn(assert(arg[-1]), { args = { "-e", code } }, function(code, sig)
        exited, status, signal = true, code, sig
        uv.timer_stop(timer); uv.close(timer); uv.close(child)
      end))
      assert(require("core.timing.engine.native_timer").start(uv, timer, 2000, 0, function()
        expired = true; child:kill("sigkill")
      end))
      while not exited do uv.run("once") end
      uv.run("nowait")
      os.remove(path)
      helpers.assert_eq(expired, false, "initialization must never wait for a FIFO writer")
      helpers.assert_eq(status, 0)
      helpers.assert_eq(signal, 0)
    end)

    helpers.it("init without personal_info.toml registers at least date rules", function()
      dh.init({ trigger_char = "\\" })
      local count = dh.get_rules_count()
      -- At minimum, 3 date rules (td, dt, date) should be registered even
      -- when personal_info.toml is absent (only letters would be missing).
      helpers.assert_true(count >= 3,
        string.format("at least 3 rules registered (got %d)", count))
    end)

    helpers.it("seeds personal_info.toml in a configuration folder a fresh install has not created", function()
      -- A fresh install starts before anything made the folder; the exclusive
      -- create alone failed with ENOENT and the editor had no source.
      local root = os.tmpname(); os.remove(root)
      local path = root .. "/ergopti/personal_info.toml"
      local ok, err = pcall(function()
        dh.init({ trigger_char = "\\", personal_info_path = path })
        local seeded = io.open(path, "rb")
        helpers.assert_true(seeded ~= nil, "the default personal_info.toml must be written")
        local text = seeded:read("*a"); seeded:close()
        helpers.assert_true(text:find("[info]", 1, true) ~= nil, "the seed holds the shared placeholders")
      end)
      os.remove(path); os.remove(root .. "/ergopti"); os.remove(root)
      dh.init({ trigger_char = "\\", personal_info_path = "/definitely/missing/personal_info.toml" })
      if not ok then error(err, 0) end
    end)

    helpers.it("is_enabled remains false until explicit activation", function()
      helpers.assert_true(dh.is_enabled() == false, "rule registration does not enable the master")
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

    helpers.it("preserves multiline personal info when another field is saved", function()
      local path = os.tmpname()
      local fh = assert(io.open(path, "wb"))
      fh:write('[info]\nstreet_address = "first\\r\\nsecond\\rthird\\nfourth"\ncity = "Puteaux"\n\n[letters]\na = "street_address"\n')
      fh:close()
      local ok, err = pcall(function()
        helpers.assert_true(dh.init({ trigger_char = "★", personal_info_path = path }))
        local original = "first\r\nsecond\rthird\nfourth"
        helpers.assert_eq(dh.get_info().street_address, original)
        helpers.assert_true(dh.save_info({ street_address = original, city = "Paris" }))
        local saved = assert(io.open(path, "rb"))
        local decoded = require("core.text.engine.toml_codec").decode(saved:read("*a")); saved:close()
        helpers.assert_eq(decoded.info.street_address, original)
        helpers.assert_eq(decoded.info.city, "Paris")
      end)
      os.remove(path); os.remove(path .. ".tmp")
      dh.init({ trigger_char = "\\", personal_info_path = "/definitely/missing/personal_info.toml" })
      if not ok then error(err, 0) end
    end)

    helpers.it("persists a custom personal-info key named __proto__", function()
      local path = os.tmpname()
      local fh = assert(io.open(path, "wb"))
      fh:write('[info]\n__proto__ = "before"\n\n[letters]\na = "__proto__"\n'); fh:close()
      local ok, err = pcall(function()
        helpers.assert_true(dh.init({ trigger_char = "★", personal_info_path = path }))
        local values = assert(require("core.text.engine.json").decode('{"__proto__":"after"}'))
        helpers.assert_true(dh.save_info(values))
        local saved = assert(io.open(path, "rb"))
        local decoded = require("core.text.engine.toml_codec").decode(saved:read("*a")); saved:close()
        helpers.assert_eq(decoded.info["__proto__"], "after")
      end)
      os.remove(path); os.remove(path .. ".tmp")
      dh.init({ trigger_char = "\\", personal_info_path = "/definitely/missing/personal_info.toml" })
      if not ok then error(err, 0) end
    end)

    helpers.it("reads and saves the personal file in the effective configuration directory (PIL-002)", function()
      local directory = os.tmpname()
      os.remove(directory)
      assert(os.execute("mkdir -p '" .. directory .. "'"))
      local path = directory .. "/personal_info.toml"
      local fh = assert(io.open(path, "w"))
      fh:write('[info]\nfirst_name = "Effective"\n\n[letters]\np = "first_name"\n')
      fh:close()
      local previous = package.loaded["core.fs.adapters.storage"]
      package.loaded["core.fs.adapters.storage"] = { get = function() return directory end }
      local ok, err = pcall(function()
        helpers.assert_true(dh.init({ trigger_char = "★" }))
        helpers.assert_eq(dh.get_info().first_name, "Effective",
          "init without an explicit path must follow the configuration-directory override")
        helpers.assert_true(dh.save_info({ first_name = "Saved" }))
        local saved = assert(io.open(path, "r"))
        local decoded = require("core.text.engine.toml_codec").decode(saved:read("*a"))
        saved:close()
        helpers.assert_eq(decoded.info.first_name, "Saved")
      end)
      package.loaded["core.fs.adapters.storage"] = previous
      os.remove(path)
      os.remove(path .. ".tmp")
      os.execute("rmdir '" .. directory .. "'")
      dh.init({ trigger_char = "\\", personal_info_path = "/definitely/missing/personal_info.toml" })
      if not ok then error(err, 0) end
    end)

    helpers.it("atomically persists editor values and refreshes live aliases", function()
      local path = os.tmpname()
      local fh = assert(io.open(path, "w"))
      fh:write('[info]\nfirst_name = "Ada"\n\n[letters]\np = "first_name"\n')
      fh:close()

      local ok, err = pcall(function()
        helpers.assert_true(dh.init({ trigger_char = "★", personal_info_path = path }))
        dh.set_enabled(false)
        helpers.assert_eq(dh.save_info({ unknown_field = "refused" }), false)
        helpers.assert_true(dh.save_info({ first_name = "Grace" }))
        helpers.assert_eq(dh.get_info().first_name, "Grace")
        helpers.assert_eq(dh.get_letters().p, "first_name")
        helpers.assert_eq(dh.is_enabled(), false,
          "refreshing edited fields must not override the category master state")

        local saved = assert(io.open(path, "r"))
        local decoded = require("core.text.engine.toml_codec").decode(saved:read("*a"))
        saved:close()
        helpers.assert_eq(decoded.info.first_name, "Grace")
        helpers.assert_eq(decoded.letters.p, "first_name")
      end)
      os.remove(path)
      os.remove(path .. ".tmp")
      dh.init({ trigger_char = "\\", personal_info_path = "/definitely/missing/personal_info.toml" })
      if not ok then error(err, 0) end
    end)
  end)

  -- ==========================================================================
  -- 3. on_trigger contract
  -- ==========================================================================

  helpers.describe("on_trigger contract", function()

    helpers.it("on_trigger with empty buffer returns false", function()
      local ok = require("tests.support.dynamic_hotstrings_fixture").trigger(dh, "", "\\")
      helpers.assert_true(ok == false, "empty buffer → no match")
    end)

    helpers.it("on_trigger without trigger char in buffer returns false", function()
      local ok = require("tests.support.dynamic_hotstrings_fixture").trigger(dh, "hello", "\\")
      helpers.assert_true(ok == false, "no trigger in buffer → no match")
    end)

    helpers.it("on_trigger with date rule 'td' matches", function()
      -- Buffer "td\" should match the "td" → YYYY_MM_DD date rule.
      -- The backslash is the trigger character.
      dh.set_enabled(true)
      local ok = require("tests.support.dynamic_hotstrings_fixture").trigger(dh, "td\\", "\\", true)
      -- This will try to inject via ydotool, which fails on test machines.
      -- We only verify it doesn't crash.
      helpers.assert_true(type(ok) == "boolean", "on_trigger returns boolean")
    end)

    helpers.it("uses one calendar instant across a date expansion at midnight", function()
      local info_path = os.tmpname(); os.remove(info_path)
      dh.init({ trigger_char = "\\", personal_info_path = info_path })
      local old_date, old_time = os.date, os.time
      local boundary = old_time({ year = 2024, month = 12, day = 31, hour = 23, min = 59, sec = 59 })
      local previous = package.loaded["hotstrings.engine.injector"]
      local injected
      package.loaded["hotstrings.engine.injector"] = { inject = function(_, text) injected = text; return { ok = true } end }
      local calls = 0
      os.time = function() return boundary end
      os.date = function(format, instant)
        if instant == nil then calls = calls + 1; instant = boundary + (calls > 1 and 1 or 0) end
        return old_date(format, instant)
      end
      local ok, err = pcall(function()
        dh.set_enabled(true)
        local fired = require("tests.support.dynamic_hotstrings_fixture").trigger(dh, "date\\", "\\", true)
        helpers.assert_true(fired)
        helpers.assert_eq(injected, "mardi 31 décembre 2024", "a single expansion cannot mix calendar dates")
        calls = 0
        local dates = require("hotstrings.engine.dynamic.core").today_date_strings()
        helpers.assert_eq(dates.iso, "2024_12_31")
        helpers.assert_eq(dates.fr, "31/12/2024")
        helpers.assert_eq(dates.long_fr, "mardi 31 décembre 2024")
      end)
      os.date, os.time = old_date, old_time
      package.loaded["hotstrings.engine.injector"] = previous
      if not ok then error(err, 0) end
    end)

    helpers.it("on_trigger when disabled returns false", function()
      dh.set_enabled(false)
      local ok = require("tests.support.dynamic_hotstrings_fixture").trigger(dh, "td\\", "\\", true)
      helpers.assert_true(ok == false, "disabled module → no match")
      dh.set_enabled(true)
    end)

    helpers.it("on_trigger with nil buffer is safe", function()
      -- Called directly: this runs on every keystroke, so a raise is a dead
      -- keyboard and should fail with its own error.
      local out = require("tests.support.dynamic_hotstrings_fixture").trigger(dh, nil, "\\")
      helpers.assert_true(out == nil or type(out) == "string" or type(out) == "boolean",
        "a nil buffer must answer nil or a documented value, never a half-value")
    end)
  end)

  -- ==========================================================================
  -- 4. preview contract
  -- ==========================================================================

  helpers.describe("preview contract", function()

    helpers.it("preview with empty buffer returns nil", function()
      local p = dh.preview("", true)
      helpers.assert_true(p == nil, "empty buffer → nil preview")
    end)

    helpers.it("preview when disabled returns nil", function()
      dh.set_enabled(false)
      local p = dh.preview("td\\", true)
      helpers.assert_true(p == nil, "disabled → nil preview")
      dh.set_enabled(true)
    end)
  end)

  -- ==========================================================================
  -- 5. Shared engine integration
  -- ==========================================================================

  helpers.describe("shared engine integration", function()

    helpers.it("shared dynamic_hotstrings engine loads and has expected API", function()
      local ok, Engine = pcall(require, "hotstrings.engine.dynamic.core")
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
      local Engine = require("hotstrings.engine.dynamic.core")
      Engine.reset_rules()
      Engine.register_date_rules("\\")
      local match = Engine.match_buffer("td", nil, nil, true)
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
      local logger    = require("core.logger.engine.shim")
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
      local p = dh.preview("@p\\", true)
      helpers.assert_eq(p, "Adrien", "preview of '@p' must expand to first_name, not a placeholder")
      os.remove(path)
    end)

    helpers.it("on_trigger injects the mapped last_name value for '@n'", function()
      local path = write_temp_toml()
      dh.init({ trigger_char = "\\", personal_info_path = path })
      dh.set_enabled(true)

      -- Capture the injection in-process instead of shelling out to ydotool
      -- (absent on the test host) so the concrete expanded value is assertable.
      local prev_injector = package.loaded["hotstrings.engine.injector"]
      local captured = nil
      package.loaded["hotstrings.engine.injector"] = {
        inject = function(backspace_count, text)
          captured = { backspace_count = backspace_count, text = text }
		  return { ok = true }
        end,
      }

      local ok = require("tests.support.dynamic_hotstrings_fixture").trigger(dh, "@n\\", "\\")

      package.loaded["hotstrings.engine.injector"] = prev_injector
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

      local previous_injector = package.loaded["hotstrings.engine.injector"]
      local single_injection = nil
      local combo_injection = nil
      package.loaded["hotstrings.engine.injector"] = {
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

      local single_preview = dh.preview("@é\\", true)
      local single_fired, single_event = require("tests.support.dynamic_hotstrings_fixture").trigger(dh, "@é\\", "\\")
      local fields = dh.resolve_combo("né")
      local uppercase_fields = dh.resolve_combo("NÉ")
      local uppercase_rows = dh.preview_candidates("@NÉ")
      local rows = dh.preview_candidates("@né")
      local combo_fired, combo_event = require("tests.support.dynamic_hotstrings_fixture").trigger(dh, "@né\\", "\\")
      local uppercase_fired, uppercase_event = require("tests.support.dynamic_hotstrings_fixture").trigger(dh, "@NÉ\\", "\\")

      package.loaded["hotstrings.engine.injector"] = previous_injector
      os.remove(path)

      helpers.assert_eq(single_preview, "Élodie", "the NFC alias is registered in the shared engine")
      helpers.assert_true(single_fired == true, "the NFC single alias fires")
      helpers.assert_not_nil(single_injection, "the single-alias injector is called")
      helpers.assert_eq(single_injection.text, "Élodie", "the single alias injects its mapped value")
      helpers.assert_eq(single_injection.backspace_count, 3,
        "single NFC alias erases @ + one codepoint + trigger")
      helpers.assert_eq(single_event.backspace_count, 3, "the single event publishes codepoint backspaces")

      helpers.assert_eq(#uppercase_fields, 2, "uppercase accented aliases resolve like lowercase aliases")
      helpers.assert_eq(#uppercase_rows, 1, "uppercase accented combo is offered before typing the trigger")
      helpers.assert_true(uppercase_fired == true, "uppercase accented combo fires")
      helpers.assert_eq(uppercase_event.backspace_count, 4)
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

    helpers.it("resolves configured uppercase accented aliases in combinations", function()
      local path = os.tmpname()
      local fh = assert(io.open(path, "w"))
      fh:write('[info]\nfirst_name = "Élodie"\nlast_name = "Durand"\n[letters]\nn = "last_name"\n"É" = "first_name"\n')
      fh:close()
      dh.init({ trigger_char = "\\", personal_info_path = path }); dh.set_enabled(true)
      local previous = package.loaded["hotstrings.engine.injector"]
      package.loaded["hotstrings.engine.injector"] = { inject_fields = function() return { ok = true } end }
      local values = dh.resolve_combo_values("né")
      local rows = dh.preview_candidates("@NÉ")
      local fired = require("tests.support.dynamic_hotstrings_fixture").trigger(dh, "@NÉ\\", "\\")
      package.loaded["hotstrings.engine.injector"] = previous
      os.remove(path)
      helpers.assert_eq(values, { "Durand", "Élodie" })
      helpers.assert_eq(#rows, 1)
      helpers.assert_true(fired)
    end)

    helpers.it("refuses conflicting aliases and multi-codepoint case expansions", function()
      local path = os.tmpname()
      local text = '[info]\nfirst_name = "Élodie"\nlast_name = "Durand"\n'
        .. '[letters]\nn = "last_name"\n"é" = "first_name"\n"É" = "last_name"\n'
        .. 'i = "last_name"\n"i̇" = "first_name"\n'
      local function write(value)
        local file = assert(io.open(path, "w")); file:write(value); file:close()
        dh.init({ trigger_char = "\\", personal_info_path = path }); dh.set_enabled(true)
      end
      local previous = package.loaded["hotstrings.engine.injector"]
      local injected, single = {}, nil
      package.loaded["hotstrings.engine.injector"] = { inject_fields = function(_, values)
        injected[#injected + 1] = values; return { ok = true }
      end, inject = function(_, value) single = value; return { ok = true } end }
      write(text)
      local single_preview = dh.preview("@É\\", true)
      local single_fired = require("tests.support.dynamic_hotstrings_fixture").trigger(dh, "@É\\", "\\")
      local rejected_rows = dh.preview_candidates("@nİ")
      local rejected = require("tests.support.dynamic_hotstrings_fixture").trigger(dh, "@nİ\\", "\\")
      write(text .. '"İ" = "first_name"\n')
      local collision_rows = dh.preview_candidates("@NÉ")
      local collision_fired = require("tests.support.dynamic_hotstrings_fixture").trigger(dh, "@NÉ\\", "\\")
      local exact_rows = dh.preview_candidates("@nİ")
      local exact_fired = require("tests.support.dynamic_hotstrings_fixture").trigger(dh, "@nİ\\", "\\")
      package.loaded["hotstrings.engine.injector"] = previous; os.remove(path)
      helpers.assert_eq(single_preview, "Durand"); helpers.assert_true(single_fired); helpers.assert_eq(single, "Durand")
      helpers.assert_eq(#rejected_rows, 0); helpers.assert_eq(rejected, false)
      helpers.assert_eq(#collision_rows, 0); helpers.assert_eq(collision_fired, false)
      helpers.assert_eq(#exact_rows, 1); helpers.assert_true(exact_fired)
      helpers.assert_eq(injected[1], { "Durand", "Élodie" }, "exact İ remains distinct from the invalid decomposed key")
    end)

    helpers.it("independent: final sigma simple stays exact while a combo resolves uppercase", function()
      local path = os.tmpname()
      local file = assert(io.open(path, "w"))
      file:write('[info]\nfirst_name = "Anna"\nlast_name = "Demos"\n[letters]\nn = "last_name"\n"ς" = "first_name"\n'); file:close()
      dh.init({ trigger_char = "\\", personal_info_path = path }); dh.set_enabled(true)
      local previous = package.loaded["hotstrings.engine.injector"]
      local single, values
      package.loaded["hotstrings.engine.injector"] = {
        inject = function(_, value) single = value; return { ok = true } end,
        inject_fields = function(_, result) values = result; return { ok = true } end,
      }
      local missing = dh.preview("@Σ\\", true)
      local missing_fired = require("tests.support.dynamic_hotstrings_fixture").trigger(dh, "@Σ\\", "\\")
      local exact = dh.preview("@ς\\", true)
      local exact_fired = require("tests.support.dynamic_hotstrings_fixture").trigger(dh, "@ς\\", "\\")
      local rows = dh.preview_candidates("@nΣ")
      local fired = require("tests.support.dynamic_hotstrings_fixture").trigger(dh, "@nΣ\\", "\\")
      package.loaded["hotstrings.engine.injector"] = previous; os.remove(path)
      helpers.assert_nil(missing); helpers.assert_eq(missing_fired, false)
      helpers.assert_eq(exact, "Anna"); helpers.assert_true(exact_fired); helpers.assert_eq(single, "Anna")
      helpers.assert_eq(rows[1].parts, { "Demos", "Anna" }); helpers.assert_true(fired)
      helpers.assert_eq(values, { "Demos", "Anna" })
    end)

    helpers.it("resolves uppercase Greek final-sigma aliases and refuses conflicts", function()
      local path = os.tmpname()
      local text = '[info]\nfirst_name = "Anna"\nlast_name = "Demos"\n'
        .. '[letters]\nn = "last_name"\n"ς" = "first_name"\n'
      local function write(value)
        local file = assert(io.open(path, "w")); file:write(value); file:close()
        dh.init({ trigger_char = "\\", personal_info_path = path }); dh.set_enabled(true)
      end
      local previous = package.loaded["hotstrings.engine.injector"]
      local injected = {}
      package.loaded["hotstrings.engine.injector"] = { inject_fields = function(_, values)
        injected[#injected + 1] = values; return { ok = true }
      end }
      write(text)
      local rows = dh.preview_candidates("@nΣ")
      local fired = require("tests.support.dynamic_hotstrings_fixture").trigger(dh, "@nΣ\\", "\\")
      write(text .. '"σ" = "last_name"\n')
      local preferred = dh.preview_candidates("@nΣ")
      local preferred_fired = require("tests.support.dynamic_hotstrings_fixture").trigger(dh, "@nΣ\\", "\\")
      write('[info]\nfirst_name = "Anna"\nlast_name = "Demos"\n[letters]\nn = "last_name"\n'
        .. '"ᲄ" = "first_name"\n"ᲅ" = "last_name"\n')
      local ambiguous = dh.preview_candidates("@nТ")
      local ambiguous_fired = require("tests.support.dynamic_hotstrings_fixture").trigger(dh, "@nТ\\", "\\")
      package.loaded["hotstrings.engine.injector"] = previous; os.remove(path)
      helpers.assert_eq(#rows, 1); helpers.assert_true(fired); helpers.assert_eq(injected[1], { "Demos", "Anna" })
      helpers.assert_eq(#preferred, 0); helpers.assert_eq(preferred_fired, false)
      helpers.assert_eq(#ambiguous, 0); helpers.assert_eq(ambiguous_fired, false)
      helpers.assert_eq(#injected, 1, "ambiguous aliases cannot shift fields")
    end)

    helpers.it("resolves Kelvin and Angstrom aliases without normalizing their configuration", function()
      local path = os.tmpname()
      local file = assert(io.open(path, "w"))
      file:write('[info]\nfirst_name = "Kelvin"\nlast_name = "Durand"\n[letters]\nn = "last_name"\n"K" = "first_name"\n"Å" = "first_name"\n'); file:close()
      dh.init({ trigger_char = "\\", personal_info_path = path }); dh.set_enabled(true)
      local previous = package.loaded["hotstrings.engine.injector"]
      local injected = {}
      package.loaded["hotstrings.engine.injector"] = { inject_fields = function(_, values)
        injected[#injected + 1] = values; return { ok = true }
      end }
      local rows = dh.preview_candidates("@nk")
      local fired = require("tests.support.dynamic_hotstrings_fixture").trigger(dh, "@nk\\", "\\")
      local upper_rows = dh.preview_candidates("@nK")
      local upper_fired = require("tests.support.dynamic_hotstrings_fixture").trigger(dh, "@nK\\", "\\")
      local angstrom_rows = dh.preview_candidates("@nå")
      local angstrom_fired = require("tests.support.dynamic_hotstrings_fixture").trigger(dh, "@nå\\", "\\")
      local angstrom_upper = dh.preview_candidates("@nÅ")
      local angstrom_upper_fired = require("tests.support.dynamic_hotstrings_fixture").trigger(dh, "@nÅ\\", "\\")
      package.loaded["hotstrings.engine.injector"] = previous; os.remove(path)
      helpers.assert_eq(#rows, 1); helpers.assert_true(fired)
      helpers.assert_eq(#upper_rows, 1); helpers.assert_true(upper_fired)
      helpers.assert_eq(#angstrom_rows, 1); helpers.assert_true(angstrom_fired)
      helpers.assert_eq(#angstrom_upper, 1); helpers.assert_true(angstrom_upper_fired)
      helpers.assert_eq(injected[1], { "Durand", "Kelvin" }); helpers.assert_eq(injected[2], injected[1])
      helpers.assert_eq(injected[3], injected[1]); helpers.assert_eq(injected[4], injected[1])
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

      local logger     = require("core.logger.engine.shim")
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

      local logger = require("core.logger.engine.shim")
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

      local logger = require("core.logger.engine.shim")
      local original_error = logger.error
      local errors = {}
      logger.error = function(_tag, fmt, ...)
        errors[#errors + 1] = (select("#", ...) > 0) and string.format(fmt, ...) or tostring(fmt)
      end

      local init_ok, init_error = pcall(function()
        dh.init({ trigger_char = "\\", personal_info_path = path })
      end)
      local preview = dh.preview("@" .. decomposed_e_acute .. "\\", true)

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

restore_family_preferences()
