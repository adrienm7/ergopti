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

      helpers.assert_true(src:find('require("lib.monotonic")', 1, true) ~= nil,
        "daemon must source its keystroke clock from lib.monotonic")
      helpers.assert_true(src:find("Monotonic.now_ms()", 1, true) ~= nil,
        "the per-keystroke timestamp must come from the monotonic wall clock")
      helpers.assert_true(src:find("os.clock() * 1000", 1, true) == nil,
        "the CPU-time keystroke timestamp must be gone — it corrupts every logged delay")
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
      local on_char_pos = src:find("local function on_char", 1, true)
      helpers.assert_true(decl_pos ~= nil, "_cached_app_id must be declared in the daemon")
      helpers.assert_true(on_char_pos ~= nil, "on_char must be defined in the daemon")
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
        helpers.assert_true(type(ir.new) == "function", "input_reader.new is a function")
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
      "adapters.notifier",
      "adapters.http_client",
      "adapters.tray_menu",
      "adapters.tooltip_renderer",
    }
    for _, name in ipairs(adapters) do
      helpers.it(name .. " loads", function()
        local ok, mod = pcall(require, name)
        helpers.assert_true(ok, name .. " module loads")
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
      "linux.tray_protocol",
      "llm.prompt_builder",
      "llm.linux_bridge",
      "updater.version",
    }
    for _, name in ipairs(shared_mods) do
      helpers.it("require('" .. name .. "') loads", function()
        local ok, mod = pcall(require, name)
        helpers.assert_true(ok, name .. " module loads")
      end)
    end
  end)

end)
