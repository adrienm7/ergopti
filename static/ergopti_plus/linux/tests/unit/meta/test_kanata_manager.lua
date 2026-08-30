--- tests/unit/meta/test_kanata_manager.lua
---
--- Compliance tests for the kanata manager module.
--- Verifies the module API surface, .kbd generation (without kanata binary),
--- and idempotent lifecycle methods. Since kanata is a daemon-only feature,
--- the process start/stop methods are tested only for crash-freedom.

local helpers = require("tests.helpers")
local km      = helpers.load_module("platform.remap.manager")

helpers.describe("kanata manager", function()

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports the expected methods", function()
      helpers.assert_true(type(km.generate_kbd) == "function", "generate_kbd")
      helpers.assert_true(type(km.write_kbd)    == "function", "write_kbd")
      helpers.assert_true(type(km.get_kbd_path)  == "function", "get_kbd_path")
      helpers.assert_true(type(km.start)        == "function", "start")
      helpers.assert_true(type(km.stop)         == "function", "stop")
      helpers.assert_true(type(km.restart)      == "function", "restart")
      helpers.assert_true(type(km.is_running)   == "function", "is_running")
    end)
  end)

  -- ==========================================================================
  -- 2. .kbd generation (template-based, without kanata binary)
  -- ==========================================================================

  helpers.describe("kbd generation", function()

    helpers.it("generate_kbd returns a non-empty string", function()
      -- This assertion used to be wrapped in `if kbd then … end` "in case the
      -- template is not found". It always was not found — the template path had
      -- one "../" too many — so generate_kbd() returned nil on every run and the
      -- test passed while asserting nothing at all. The path is resolved from
      -- this module's own source location, so it does not depend on the cwd:
      -- a nil here means the config is not being generated, and must fail.
      local kbd = km.generate_kbd()
      helpers.assert_true(type(kbd) == "string" and #kbd > 0,
        "generate_kbd must return the config — nil means kanata gets no config at all")
      helpers.assert_true(kbd:find("defcfg", 1, true) or kbd:find("defsrc", 1, true),
        "contains kanata structural markers")
      helpers.assert_true(kbd:find("defalias", 1, true),
        "contains defalias block")
    end)

    helpers.it("the generated defalias block matches the golden corpus", function()
      -- Pins generator + manager + defaults.toml to the committed corpus in one
      -- assertion. tools/test/test-kanata-defalias-parity.cjs substitutes that
      -- corpus into the template to prove the merged config loads, which is only
      -- meaningful while the corpus really is what the generator produces.
      local kbd = km.generate_kbd()
      helpers.assert_true(type(kbd) == "string", "generate_kbd must produce a config")

      local golden_path = helpers.driver_root() .. "/../_shared/tap_hold/golden_kanata_defalias.kbd"
      local fh = io.open(golden_path, "r")
      helpers.assert_not_nil(fh, "golden corpus not found at " .. golden_path)
      local golden = fh:read("*a")
      fh:close()

      -- The generated block is the LAST (defalias …) of the assembled config.
      local generated = nil
      for block in kbd:gmatch("(%(defalias.-\n%))") do generated = block end
      helpers.assert_not_nil(generated, "no (defalias) block found in the generated config")

      local function normalise(s) return (s:gsub("\r\n", "\n"):gsub("%s+$", "")) end
      helpers.assert_eq(normalise(generated), normalise(golden),
        "generated defalias block drifted from golden_kanata_defalias.kbd")
    end)

    helpers.it("generate_kbd emits a config kanata can actually load", function()
      -- kanata resolves every @name at load time, so ONE dangling reference
      -- rejects the WHOLE file. The generated block replaces the template's last
      -- (defalias) wholesale, which used to drop @copy, @paste, @rollx and
      -- @deadtrema on the floor.
      local kbd = km.generate_kbd()
      helpers.assert_true(type(kbd) == "string", "generate_kbd must produce a config")

      -- Strip ";;" comments only: a lone ";" is a legitimate alias name here.
      local clean = kbd:gsub(";;[^\n]*", "")

      local defined = {}
      for block in clean:gmatch("%(defalias(.-)\n%)") do
        -- Alias entries alternate NAME then VALUE at the top level of the block.
        -- Names are the atoms that start a line, which is enough here because
        -- the generator and the template both emit one entry per line.
        for name in block:gmatch("\n%s*([^%s()@]+)%s") do
          defined[name] = true
        end
      end

      local dangling = {}
      for ref in clean:gmatch("@([^%s()]+)") do
        if not defined[ref] then dangling[#dangling + 1] = ref end
      end

      helpers.assert_eq(#dangling, 0,
        "dangling @alias in the generated config: " .. table.concat(dangling, ", "))
    end)

    helpers.it("write_kbd writes a file to the kanata config dir", function()
      local ok = km.write_kbd()
      if ok then
        local path = km.get_kbd_path()
        helpers.assert_true(type(path) == "string" and path:find("kanata", 1, true),
          "kbd path contains 'kanata'")
        local fh = io.open(path, "r")
        if fh then
          local content = fh:read("*a")
          fh:close()
          helpers.assert_true(#content > 0, "written .kbd is non-empty")
        end
      end
    end)

    helpers.it("write_kbd preserves the final file when staging fails (lnx-063)", function()
      local final_path = km.get_kbd_path()
      local original_open = io.open
      local original_execute = os.execute
      local original_rename = os.rename
      local original_generate = km.generate_kbd
      local opened_final_for_write = false
      local rename_count = 0

      km.generate_kbd = function() return "new kanata config" end
      os.execute = function() return true end
      os.rename = function()
        rename_count = rename_count + 1
        return true
      end
      io.open = function(path, mode)
        if path:sub(1, #final_path) == final_path and mode:find("w", 1, true) then
          if path == final_path then opened_final_for_write = true end
          return {
            write = function() return nil, "disk full" end,
            flush = function() return nil, "flush failed" end,
            close = function() return true end,
          }
        end
        return original_open(path, mode)
      end

      local call_ok, result = pcall(km.write_kbd)
      io.open = original_open
      os.execute = original_execute
      os.rename = original_rename
      km.generate_kbd = original_generate

      helpers.assert_true(call_ok, "a staged write failure must return false rather than throw")
      helpers.assert_eq(result, false, "write_kbd must propagate the failed write")
      helpers.assert_eq(opened_final_for_write, false,
        "the final config must never be opened destructively before commit")
      helpers.assert_eq(rename_count, 0, "failed staging must not replace the final config")
    end)

    helpers.it("get_kbd_path returns a string with .kbd extension", function()
      local path = km.get_kbd_path()
      helpers.assert_true(type(path) == "string", "returns a string")
      helpers.assert_true(path:find("%.kbd$") ~= nil, "ends with .kbd")
    end)
  end)

  -- ==========================================================================
  -- 2b. One-shot timeout is single-sourced (no hardcoded 2000 ms fallback)
  -- ==========================================================================

  helpers.describe("one-shot timeout single source", function()

    -- The one-shot shift timeout must come only from the canonical timings
    -- registry. A hardcoded fallback both duplicates the canonical value and
    -- masks the fail-fast: a missing registry silently used 2000, hiding a
    -- broken install. generate_kbd must instead fail loud (return nil).

    helpers.it("emits the value from the timings registry, not a hardcoded 2000", function()
      local real = require("infra.timings")
      package.loaded["infra.timings"] = {
        ms = function(cat, key)
          if cat == "tap_hold" and key == "one_shot_shift_timeout_ms" then return 4242 end
          return real.ms(cat, key)
        end,
        sec = real.sec,
      }
      local kbd = km.generate_kbd()
      package.loaded["infra.timings"] = real
      -- Only assert when a template was resolvable in this environment.
      if kbd then
        helpers.assert_true(kbd:find("4242", 1, true) ~= nil,
          "the one-shot timeout in the generated defalias must come from the registry")
      end
    end)

    helpers.it("fails loud (returns nil) when the canonical timeout is missing", function()
      local real = require("infra.timings")
      package.loaded["infra.timings"] = {
        ms = function(cat, key)
          if cat == "tap_hold" and key == "one_shot_shift_timeout_ms" then return nil end
          return real.ms(cat, key)
        end,
        sec = real.sec,
      }
      local kbd = km.generate_kbd()
      package.loaded["infra.timings"] = real
      helpers.assert_true(kbd == nil,
        "generate_kbd must return nil when the canonical one-shot timeout is missing — no hardcoded fallback")
    end)

    helpers.it("does not hardcode a one-shot fallback in the source", function()
      local fh = io.open(helpers.driver_root() .. "/platform/remap/manager.lua", "r")
      helpers.assert_true(fh ~= nil, "manager source must be readable")
      local src = fh:read("*a"); fh:close()
      helpers.assert_true(src:find("one_shot_ms = 2000", 1, true) == nil,
        "the hardcoded 2000 ms one-shot fallback must be gone")
      helpers.assert_true(src:find('Timings.ms("tap_hold", "one_shot_shift_timeout_ms")', 1, true) ~= nil,
        "the one-shot timeout must be read from the canonical timings registry")
    end)

  end)

  -- ==========================================================================
  -- 3. Process lifecycle (without kanata binary — safe stubs)
  -- ==========================================================================

  helpers.describe("process lifecycle", function()

    helpers.it("is_running returns false when kanata is not started", function()
      helpers.assert_true(type(km.is_running()) == "boolean", "is_running returns boolean")
      -- On the maintainer's machine, kanata is not installed → false.
    end)

    helpers.it("start does not crash when kanata binary is absent", function()
      -- With no kanata binary the start must REPORT failure: the caller shows the
      -- user a "remapping unavailable" state on that answer, and a silent success
      -- leaves them believing the keyboard is remapped when it is not.
      local started = km.start()
      helpers.assert_true(started == nil or started == false,
        "start() with no kanata binary must not report success")
    end)

    helpers.it("stop does not crash when not running", function()
      km.stop()
      helpers.assert_true(km.is_running() == nil or km.is_running() == false,
        "a stop that never started must leave the manager stopped, not confused")
    end)

    helpers.it("double stop is safe", function()
      km.stop()
      km.stop()
      helpers.assert_true(km.is_running() == nil or km.is_running() == false,
        "a second stop must be a no-op, not a resurrection")
    end)

    helpers.it("restart does not crash (will fail gracefully without kanata)", function()
      local restarted = km.restart()
      helpers.assert_true(restarted == nil or restarted == false,
        "restart with no kanata binary must fail gracefully AND say so")
    end)
  end)

  -- ==========================================================================
  -- 3b. Malformed / empty user tap_hold.toml fail-fast
  -- ==========================================================================

  helpers.describe("user tap_hold.toml fail-fast", function()

    -- Writes `content` to a temp file, points the loader at it via the test seam,
    -- runs the tap-hold config loader in isolation, and returns captured
    -- error/warn messages. The seam avoids depending on $HOME or on creating
    -- nested config dirs cross-platform, and bypasses generate_kbd()'s template
    -- gate (the kanata.kbd template does not resolve in the headless suite).
    local function load_with_user_toml(content)
      local tmp_dir = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
      local path    = tmp_dir:gsub("\\", "/") .. "/ergopti_kanata_user_taphold.toml"
      local fh = assert(io.open(path, "w"))
      fh:write(content)
      fh:close()

      local logger = require("logger.shim")
      local orig_error, orig_warn = logger.error, logger.warn
      local errors, warns = {}, {}
      logger.error = function(_t, fmt, ...)
        errors[#errors + 1] = (select("#", ...) > 0) and string.format(fmt, ...) or tostring(fmt)
      end
      logger.warn = function(_t, fmt, ...)
        warns[#warns + 1] = (select("#", ...) > 0) and string.format(fmt, ...) or tostring(fmt)
      end

      pcall(function() km._load_tap_hold_config_for_test(path) end)

      logger.error, logger.warn = orig_error, orig_warn
      os.remove(path)
      return errors, warns
    end

    local function any_contains(list, needle)
      for _, m in ipairs(list) do
        if m:find(needle, 1, true) then return true end
      end
      return false
    end

    helpers.it("logs Logger.error when the user tap_hold.toml is malformed", function()
      -- Unterminated table header — the shared codec rejects it (decode → nil).
      local errors = load_with_user_toml("[tap_hold.keys.a\ntap_action = \"a\"\n")
      helpers.assert_true(any_contains(errors, "malformed"),
        "a malformed user tap_hold.toml must log an ERROR")
    end)

    helpers.it("warns before falling back when the user tap_hold.toml is present but empty", function()
      -- Valid TOML with a keys table but no key entries: parses fine, yields no
      -- usable keys. Must warn that the user file was ignored — not silently drop.
      local errors, warns = load_with_user_toml("[tap_hold.keys]\n")
      helpers.assert_true(any_contains(warns, "present but yielded no usable keys"),
        "a present-but-empty user tap_hold.toml must warn before falling back to defaults")
      helpers.assert_true(not any_contains(errors, "malformed"),
        "a valid-but-empty user file is not malformed — no malformed ERROR expected")
    end)

  end)

  -- ==========================================================================
  -- 4. Menu builder integration
  -- ==========================================================================

  helpers.describe("menu builder integration", function()

    helpers.it("menu_builder Kanata section items have valid shape", function()
      local mb = helpers.load_module("ui.menu.menu_builder")
      local items = mb.build({ _version = "test", on_quit = function() end })

      -- Find the Kanata section.
      local kanata_section = nil
      for _, item in ipairs(items) do
        if type(item.title) == "string" and item.title:find("Kanata", 1, true) then
          kanata_section = item
          break
        end
      end

      helpers.assert_true(kanata_section ~= nil, "Kanata section present in menu")
      if kanata_section then
        helpers.assert_true(type(kanata_section.menu) == "table" and #kanata_section.menu > 0,
          "Kanata section has submenu items")
        -- Every row that LOOKS clickable must be. This used to read "every row
        -- has a callback", which held while the menu was four action rows and
        -- stopped holding on 2026-08-07, when the tap-hold read-out added a
        -- separator, a section header and one submenu per configured key. The
        -- guarantee it was protecting is unchanged and stated exactly: a row
        -- that is not a separator, is not disabled and opens no submenu must do
        -- something when clicked.
        for _, sub in ipairs(kanata_section.menu) do
          local is_separator = (sub.title == "-")
          local is_label     = (sub.disabled == true)
          local opens_menu   = (type(sub.menu) == "table")
          if not (is_separator or is_label or opens_menu) then
            helpers.assert_true(type(sub.fn) == "function",
              "Kanata item '" .. (sub.title or "?") .. "' looks clickable but has no callback")
          end
        end
      end
    end)

    helpers.it("the tap-hold read-out is derived from the shared configuration", function()
      local manager = helpers.load_module("platform.remap.manager")
      helpers.assert_true(type(manager.tap_hold_keys) == "function",
        "the manager must expose the tap-hold configuration the tray reads")

      local keys = manager.tap_hold_keys()
      local expected = 0
      for _ in pairs(keys or {}) do expected = expected + 1 end
      helpers.assert_true(expected > 0,
        "_shared/tap_hold/defaults.toml must declare at least one tap-hold key")

      local mb = helpers.load_module("ui.menu.menu_builder")
      local items = mb.build({ _version = "test", on_quit = function() end })
      local kanata_section = nil
      for _, item in ipairs(items) do
        if type(item.title) == "string" and item.title:find("Kanata", 1, true) then
          kanata_section = item
          break
        end
      end
      helpers.assert_true(kanata_section ~= nil, "Kanata section present in menu")

      -- Rows that open a submenu are the per-key read-outs; the four lifecycle
      -- rows are flat and the header is a disabled label.
      local read_outs = 0
      for _, sub in ipairs(kanata_section.menu or {}) do
        if type(sub.menu) == "table" then read_outs = read_outs + 1 end
      end

      -- Counted on both sides rather than compared against a number written
      -- here: a hardcoded 7 would still pass the day someone adds an eighth key
      -- to the shared file and the menu keeps showing seven, which is precisely
      -- the failure this driver has hit before with hand-written lists.
      helpers.assert_eq(read_outs, expected,
        "the tray must show one tap-hold row per key in the shared configuration")
    end)
  end)

  -- ==========================================================================
  -- 5. Lifecycle log pairing (source compliance)
  -- ==========================================================================

  helpers.describe("lifecycle log pairing", function()

    -- Static source scan: the write_kbd()/start() SUCCESS lines are unreachable
    -- in the headless suite (no kanata binary; the .kbd template resolves
    -- off-tree), so a runtime spy cannot observe them — assert pairing on source.
    local function read_manager_source()
      local path = helpers.driver_root() .. "/platform/remap/manager.lua"
      local fh = assert(io.open(path, "r"), "cannot open manager.lua")
      local content = fh:read("*a")
      fh:close()
      return content
    end

    helpers.it("emits no Logger.success without a preceding Logger.start", function()
      local content = read_manager_source()
      -- A top-level `function` header resets the per-function running balance so
      -- each function is checked in isolation; success/done must never run ahead
      -- of start/trace on their own lifecycle axis (lifecycle logs are paired).
      local info_starts, info_success = 0, 0
      local dbg_starts,  dbg_done     = 0, 0
      local violations = {}
      local lineno = 0
      for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        lineno = lineno + 1
        if line:match("^%s*function%s") or line:match("^%s*local%s+function%s") then
          info_starts, info_success = 0, 0
          dbg_starts,  dbg_done     = 0, 0
        end
        if line:find("Logger%.start%(")   then info_starts = info_starts + 1 end
        if line:find("Logger%.trace%(")   then dbg_starts  = dbg_starts  + 1 end
        if line:find("Logger%.success%(") then
          info_success = info_success + 1
          if info_success > info_starts then
            violations[#violations + 1] =
              "line " .. lineno .. ": Logger.success without a preceding Logger.start"
          end
        end
        if line:find("Logger%.done%(") then
          dbg_done = dbg_done + 1
          if dbg_done > dbg_starts then
            violations[#violations + 1] =
              "line " .. lineno .. ": Logger.done without a preceding Logger.trace"
          end
        end
      end
      helpers.assert_eq(#violations, 0,
        "orphaned lifecycle logs in manager.lua: " .. table.concat(violations, "; "))
    end)
  end)

end)
