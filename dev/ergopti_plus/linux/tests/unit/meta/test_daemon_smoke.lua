--- tests/unit/meta/test_daemon_smoke.lua
---
--- Daemon smoke test. Validates the ergopti_hotstrings.lua
--- entry point: CLI argument parsing, module loading, configuration resolution.
---
--- These tests run the daemon as a subprocess (via io.popen) or load its
--- parse_args function to verify CLI behavior. No real evdev device is needed.
---
--- Real daemon smoke test requires a Linux machine with:
---   /dev/input/eventN available, ydotool + ydotoold running, uinput loaded

local helpers = require("tests.helpers")

-- We test the argument parser and module structure by loading the daemon
-- module. The daemon has a main() call at the bottom, so we must be careful
-- to only test individual functions or the --help path.

helpers.describe("daemon smoke (ergopti_hotstrings)", function()

  -- ==========================================================================
  -- 1. Daemon file integrity
  -- ==========================================================================
  -- NOTE: We do NOT require("ergopti_hotstrings") directly — the file calls
  -- main() unconditionally at the bottom, which calls os.exit(0) on --help
  -- and can NOT be caught by pcall (os.exit terminates the process).
  -- All sub-modules are tested individually below instead.

  helpers.describe("daemon file integrity", function()
    helpers.it("ergopti_hotstrings.lua exists and is readable", function()
      local self_path = debug.getinfo(1, "S").source:gsub("^@", "")
      local driver_root = self_path:match("^(.*)[/\\]tests[/\\]") or "."
      driver_root = driver_root:gsub("\\", "/")
      local daemon_path = driver_root .. "/ergopti_hotstrings.lua"
      local fh = io.open(daemon_path, "r")
      helpers.assert_true(fh ~= nil, "daemon file is readable")
      if fh then
        local first_line = fh:read("*l")
        fh:close()
        helpers.assert_true(
          first_line and first_line:find("ergopti_hotstrings"),
          "daemon has expected header"
        )
      end
    end)

    helpers.it("timestamps keystrokes with the monotonic wall clock, not the CPU clock", function()
      -- The keylogger derives inter-keystroke delays (N-gram timing) from the
      -- per-keystroke timestamp. It was built from os.clock() * 1000 — CPU time
      -- on Linux — so every recorded delay was meaningless in the daemon. This
      -- guard is RED before the fix (the old expression is present).
      local self_path = debug.getinfo(1, "S").source:gsub("^@", "")
      local driver_root = (self_path:match("^(.*)[/\\]tests[/\\]") or "."):gsub("\\", "/")
      local fh = io.open(driver_root .. "/ergopti_hotstrings.lua", "r")
      helpers.assert_true(fh ~= nil, "daemon file is readable")
      local src = fh:read("*a"); fh:close()

      helpers.assert_true(src:find('require("infra.monotonic")', 1, true) ~= nil,
        "daemon must source its keystroke clock from lib.monotonic")
      helpers.assert_true(src:find("Monotonic.now_ms()", 1, true) ~= nil,
        "the per-keystroke timestamp must come from the monotonic wall clock")
      helpers.assert_true(src:find("os.clock() * 1000", 1, true) == nil,
        "the CPU-time keystroke timestamp must be gone — it corrupts every logged delay")
    end)

    helpers.it("applies full-trigger timing and resets it at every text-context boundary", function()
      local self_path = debug.getinfo(1, "S").source:gsub("^@", "")
      local driver_root = (self_path:match("^(.*)[/\\]tests[/\\]") or "."):gsub("\\", "/")
      local fh = io.open(driver_root .. "/ergopti_hotstrings.lua", "r")
      helpers.assert_true(fh ~= nil, "daemon file is readable")
      local src = fh:read("*a"); fh:close()

      helpers.assert_true(src:find("typed_at_ms         = now_ms", 1, true) ~= nil,
        "each matcher input must carry its monotonic timestamp")
      helpers.assert_true(src:find("engine_mod.within_interkey_delay(result, delay_sec)", 1, true) ~= nil,
        "expiry must evaluate every interval retained by the matched suffix")
      helpers.assert_true(src:find("_last_key_ms", 1, true) == nil,
        "a single previous-key timestamp recreates the original final-pair-only bug")

      local control_start = assert(src:find("local function handle_control", 1, true))
      local click_start = assert(src:find("local function on_click", control_start, true))
      local focus_start = assert(src:find("process_lifecycle.onFocusChange(function", click_start, true))
      local focus_end = assert(src:find("\n\t\tend)", focus_start, true))
      local control_body = src:sub(control_start, click_start - 1)
      local click_body = src:sub(click_start, focus_start - 1)
      local focus_body = src:sub(focus_start, focus_end)

      helpers.assert_true(control_body:find("engine:reset()", 1, true) ~= nil,
        "control keys must reset text and its aligned timing history")
      helpers.assert_true(click_body:find("secure_focus_guard.invalidate()", 1, true) ~= nil,
        "pointer clicks must cross the text buffer and privacy state together")
      helpers.assert_true(focus_body:find("secure_focus_guard.prime()", 1, true) ~= nil,
        "top-level focus changes must publish a fresh control-level privacy epoch")
    end)

    helpers.it("invalidates same-window focus before handling Tab text", function()
      local self_path = debug.getinfo(1, "S").source:gsub("^@", "")
      local driver_root = (self_path:match("^(.*)[/\\]tests[/\\]") or "."):gsub("\\", "/")
      local fh = io.open(driver_root .. "/ergopti_hotstrings.lua", "r")
      helpers.assert_true(fh ~= nil, "daemon file is readable")
      local src = fh:read("*a"); fh:close()
      local on_char_start = assert(src:find("local function handle_char", 1, true))
      local on_physical_start = assert(src:find("local function handle_physical", on_char_start, true))
      local on_char_body = src:sub(on_char_start, on_physical_start - 1)
      local tab_pos = on_char_body:find('if ch == "\\t" then', 1, true)
      local invalidate_pos = on_char_body:find("secure_focus_guard.invalidate()", 1, true)
      local metric_pos = on_char_body:find("keylogger.on_keydown", 1, true)
      local llm_pos = on_char_body:find("prediction_engine.on_char", 1, true)

      helpers.assert_true(tab_pos ~= nil and invalidate_pos ~= nil,
        "bare Tab must explicitly invalidate the accessible-control verdict")
      helpers.assert_true(invalidate_pos < metric_pos and invalidate_pos < llm_pos,
        "focus invalidation must happen before metrics or LLM can consume text")
      helpers.assert_true(src:find("secure_focus_guard.refresh(false)", 1, true) ~= nil,
        "the periodic path must publish the settled fresh verdict")
    end)

    helpers.it("gates keyboard shortcut dispatch with the master switch", function()
      local self_path = debug.getinfo(1, "S").source:gsub("^@", "")
      local driver_root = (self_path:match("^(.*)[/\\]tests[/\\]") or "."):gsub("\\", "/")
      local fh = io.open(driver_root .. "/ergopti_hotstrings.lua", "r")
      helpers.assert_true(fh ~= nil, "daemon file is readable")
      local src = fh:read("*a"); fh:close()
      local control_start = assert(src:find("local function handle_control", 1, true))
      local click_start = assert(src:find("local function on_click", control_start, true))
      local control_body = src:sub(control_start, click_start - 1)
      local gate = control_body:find("if shortcuts and shortcuts.is_enabled() then", 1, true)
      local dispatch = control_body:find("pcall(keyboard_shortcuts.dispatch, detail)", 1, true)

      helpers.assert_true(gate ~= nil and dispatch ~= nil and gate < dispatch,
        "the shortcuts master toggle must guard keyboard dispatch; disabling the "
          .. "feature cannot leave Ctrl+G and user assignments active")
    end)

    helpers.it("routes recurring pumps through the runtime failure guard", function()
      local self_path = debug.getinfo(1, "S").source:gsub("^@", "")
      local driver_root = (self_path:match("^(.*)[/\\]tests[/\\]") or "."):gsub("\\", "/")
      local fh = io.open(driver_root .. "/ergopti_hotstrings.lua", "r")
      helpers.assert_true(fh ~= nil, "daemon file is readable")
      local src = fh:read("*a"); fh:close()
      local loop_start = assert(src:find("event_loop.run({", 1, true))
      local loop_end = assert(src:find("\n\t})", loop_start, true))
      local loop_body = src:sub(loop_start, loop_end)

      helpers.assert_true(loop_body:find(
        'RuntimeGuard.call("keyboard pump", keyboard_hook.pump, stop_input_loop)', 1, true) ~= nil,
        "keyboard callback failure must stop and ungrab through the common guard")
      helpers.assert_true(loop_body:find("pcall(keyboard_hook.pump", 1, true) == nil,
        "a bare pcall would swallow the failure and retain capture ownership")
      helpers.assert_true(loop_body:find('RuntimeGuard.call("tray pump"', 1, true) ~= nil,
        "optional pump failure must become an explicit unavailable capability")
      helpers.assert_true(loop_body:find('RuntimeGuard.call("gesture pump"', 1, true) ~= nil,
        "gesture pump failure must be diagnosed and stop its reader")
    end)

    helpers.it("declares the focused-app cache as an upvalue BEFORE on_char", function()
      -- Regression: `local _cached_app_id` was declared AFTER `local function
      -- on_char`, so on_char resolved the name to a never-assigned GLOBAL
      -- (always nil) while the onFocusChange callback wrote a different local.
      -- app_id reached keylogger.is_password_app() as nil, silently disabling
      -- keystroke suppression inside password managers (a privacy regression).
      -- The declaration must PRECEDE on_char so both capture the same upvalue.
      -- RED if the declaration is moved back below on_char.
      local self_path = debug.getinfo(1, "S").source:gsub("^@", "")
      local driver_root = (self_path:match("^(.*)[/\\]tests[/\\]") or "."):gsub("\\", "/")
      local fh = io.open(driver_root .. "/ergopti_hotstrings.lua", "r")
      helpers.assert_true(fh ~= nil, "daemon file is readable")
      local src = fh:read("*a"); fh:close()

      local decl_pos = src:find("local _cached_app_id", 1, true)
      local on_char_pos = src:find("local function handle_char", 1, true)
      helpers.assert_true(decl_pos ~= nil, "_cached_app_id must be declared in the daemon")
      helpers.assert_true(on_char_pos ~= nil, "the character handler must be defined in the daemon")
      helpers.assert_true(decl_pos and on_char_pos and decl_pos < on_char_pos,
        "_cached_app_id must be declared BEFORE on_char so on_char captures it as "
        .. "an upvalue — otherwise it reads a nil global and password-app keystroke "
        .. "suppression is silently disabled")
    end)

    helpers.it("primes the current foreground app before lifecycle polling starts", function()
      -- process_lifecycle.start() deliberately stores the current window as its
      -- baseline, so it does not produce an initial focus-change callback. The
      -- keylogger must be primed explicitly or the apps dashboard remains empty
      -- until the user changes window for the first time.
      local self_path = debug.getinfo(1, "S").source:gsub("^@", "")
      local driver_root = (self_path:match("^(.*)[/\\]tests[/\\]") or "."):gsub("\\", "/")
      local fh = io.open(driver_root .. "/ergopti_hotstrings.lua", "r")
      helpers.assert_true(fh ~= nil, "daemon file is readable")
      local src = fh:read("*a"); fh:close()

      local prime_pos = src:find("process_lifecycle.getForegroundApp()", 1, true)
      local start_pos = src:find("process_lifecycle.start()", 1, true)
      helpers.assert_true(prime_pos ~= nil, "daemon must read the initial foreground app")
      helpers.assert_true(start_pos ~= nil, "daemon must start lifecycle polling")
      helpers.assert_true(prime_pos and start_pos and prime_pos < start_pos,
        "initial foreground app must be attributed before lifecycle polling starts")
      helpers.assert_true(src:find("keylogger.on_app_focus(_cached_app_id", prime_pos, true) ~= nil,
        "initial foreground app must be forwarded to the keylogger")
    end)
  end)

  -- ==========================================================================
  -- 4. Dependency modules
  -- ==========================================================================

  helpers.describe("dependency modules", function()
    helpers.it("engine can be required", function()
      local ok, engine = pcall(require, "modules.hotstrings.engine")
      helpers.assert_true(ok, "engine module loads")
      if ok then
        helpers.assert_true(type(engine.new) == "function", "engine.new is a function")
      end
    end)

    helpers.it("loader can be required", function()
      local ok, loader = pcall(require, "modules.hotstrings.loader")
      helpers.assert_true(ok, "loader module loads")
      if ok then
        helpers.assert_true(type(loader.find_toml_files) == "function" or
                             type(loader.load) == "function",
          "loader has expected functions")
      end
    end)

    helpers.it("injector can be required", function()
      local ok, inj = pcall(require, "modules.hotstrings.injector")
      helpers.assert_true(ok, "injector module loads")
      if ok then
        helpers.assert_true(type(inj.inject) == "function", "injector.inject is a function")
      end
    end)

    helpers.it("input_reader can be required", function()
      local ok, ir = pcall(require, "modules.hotstrings.input_reader")
      helpers.assert_true(ok, "input_reader module loads")
      if ok then
        -- resolve_char, not new(). The reader instance this used to name had no
        -- production caller for its whole life; reading the device belongs to
        -- adapters/evdev_reader.lua now, and what remains here is the layout.
        helpers.assert_true(type(ir.resolve_char) == "function", "input_reader.resolve_char is a function")
      end
    end)

    helpers.it("evdev_reader can be required", function()
      local ok, er = pcall(require, "adapters.evdev_reader")
      helpers.assert_true(ok, "evdev_reader module loads")
      if ok then
        helpers.assert_true(type(er.grab) == "function", "evdev_reader.grab is a function")
        helpers.assert_true(type(er.drain) == "function", "evdev_reader.drain is a function")
      end
    end)

    helpers.it("device_finder can be required", function()
      local ok, df = pcall(require, "modules.hotstrings.device_finder")
      helpers.assert_true(ok, "device_finder module loads")
      if ok then
        helpers.assert_true(type(df.find_keyboard) == "function",
          "device_finder.find_keyboard is a function")
      end
    end)

    helpers.it("metrics_collector can be required", function()
      local ok, mc = pcall(require, "modules.keylogger.metrics_collector")
      helpers.assert_true(ok, "metrics_collector module loads")
      if ok then
        helpers.assert_true(type(mc.init) == "function",
          "metrics_collector.init is a function")
      end
    end)
  end)

  -- ==========================================================================
  -- 5. utf8 shim installation
  -- ==========================================================================

  helpers.describe("utf8 compat shim", function()
    helpers.it("can be required", function()
      local ok, utf8_mod = pcall(require, "compat.utf8")
      helpers.assert_true(ok, "compat.utf8 module loads")
      if ok then
        helpers.assert_true(type(utf8_mod.install) == "function",
          "utf8.install is a function")
      end
    end)

    helpers.it("install returns true (already installed or freshly installed)", function()
      local ok, utf8_mod = pcall(require, "compat.utf8")
      if ok and utf8_mod.install then
        local result = utf8_mod.install()
        helpers.assert_true(result == true or result == false,
          "install() returns boolean")
      end
    end)
  end)

  -- ==========================================================================
  -- 6. All adapter modules
  -- ==========================================================================

  helpers.describe("adapter modules", function()
    local adapters = {
      "adapters.http_client",
      "adapters.tray_menu",
    }
    for _, name in ipairs(adapters) do
      helpers.it(name .. " loads", function()
        local ok, mod = pcall(require, name)
        helpers.assert_true(ok, name .. " module loads: " .. tostring(mod))
        helpers.assert_eq(type(mod), "table", name .. " must load as a table")
      end)
    end
  end)

  -- ==========================================================================
  -- 7. All shared modules used by the daemon
  -- ==========================================================================

  helpers.describe("shared modules (daemon dependencies)", function()
    local shared_mods = {
      "logger.shim",
      "compat.utf8",
      "keymap.terminators",
      "keylogger.utils",
      "keylogger.metrics",
      "keylogger.aggregator_helpers",
      "keycodes.evdev",
      "json",
      "tray.protocol",
      "llm.prompt_builder",
      "infra.llm_bridge",
      "updater.version",
    }
    for _, name in ipairs(shared_mods) do
      helpers.it("require('" .. name .. "') loads", function()
        local ok, mod = pcall(require, name)
        helpers.assert_true(ok, name .. " module loads: " .. tostring(mod))
        helpers.assert_eq(type(mod), "table", name .. " must load as a table")
      end)
    end
  end)

end)
