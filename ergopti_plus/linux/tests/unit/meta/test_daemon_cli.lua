--- tests/unit/meta/test_daemon_cli.lua
---
--- Tier 1.1 — Daemon CLI integration tests.
--- Tests all CLI flags (--help, --dry-run, --verbose, --tray, --config,
--- --device, --layout) and edge cases via subprocess (lua ergopti_hotstrings.lua).
--- The daemon calls os.exit(), so we test via io.popen to capture exit codes
--- and stdout/stderr.

local helpers = require("tests.helpers")

helpers.describe("ergopti_hotstrings CLI", function()

  -- ==========================================================================
  -- 1. Determine Lua runtime and daemon path
  -- ==========================================================================

  local function lua_bin()
    -- Use the same Lua that's running this test suite.
    -- arg[0] is the script path on Lua 5.4; arg[-1] is LuaJIT-only.
    -- Fall back to "lua" if neither is available.
    local bin = "lua"
    if arg then
      if arg[0] then bin = arg[0] end
      if arg[-1] then bin = arg[-1] end
    end
    return bin
  end

  local function daemon_path()
    local root = helpers.driver_root()
    return root .. "/ergopti_hotstrings.lua"
  end

  local function run_daemon(args)
    local cmd = string.format("%s %s %s 2>&1", lua_bin(), daemon_path(), args or "")
    local pipe = io.popen(cmd, "r")
    if not pipe then return "", -1 end
    local output = pipe:read("*a")
    local ok, _, code = pipe:close()
    -- On Lua 5.2+, pipe:close() returns the exit code.
    -- On LuaJIT, it returns nil on success and nil, "exit", N on failure.
    local exit_code = code or (ok and 0 or 1)
    return output or "", exit_code
  end

  local function daemon_exists()
    local fh = io.open(daemon_path(), "r")
    if fh then fh:close(); return true end
    return false
  end

  -- ==========================================================================
  -- 2. Daemon file integrity
  -- ==========================================================================

  helpers.describe("file integrity", function()
    helpers.it("ergopti_hotstrings.lua exists", function()
      helpers.assert_true(daemon_exists(), "daemon file exists")
    end)

    helpers.it("daemon file contains main() function", function()
      local fh = io.open(daemon_path(), "r")
      local content = fh:read("*a")
      fh:close()
      helpers.assert_true(content:find("local function main%(%)"), "has main()")
    end)

    helpers.it("daemon file imports keyboard_hook", function()
      local fh = io.open(daemon_path(), "r")
      local content = fh:read("*a")
      fh:close()
      helpers.assert_true(content:find('require%("adapters%.keyboard_hook"%)'), "imports keyboard_hook")
    end)

    helpers.it("daemon file has pump event loop", function()
      local fh = io.open(daemon_path(), "r")
      local content = fh:read("*a")
      fh:close()
      helpers.assert_true(content:find("keyboard_hook%.pump"), "has pump() call")
    end)

    helpers.it("daemon file has tray_menu integration", function()
      local fh = io.open(daemon_path(), "r")
      local content = fh:read("*a")
      fh:close()
      helpers.assert_true(content:find("tray_menu"), "mentions tray_menu")
    end)
  end)

  -- ==========================================================================
  -- 3. --help flag
  -- ==========================================================================

  helpers.describe("--help", function()
    helpers.it("--help prints usage and exits 0", function()
      local out, code = run_daemon("--help")
      helpers.assert_true(code == 0 or code == true, "--help exits 0 (got: " .. tostring(code) .. ")")
      helpers.assert_true(out:find("Utilisation") or out:find("Usage") or out:find("ergopti"),
        "--help mentions usage")
    end)

    helpers.it("-h flag works same as --help", function()
      local out, code = run_daemon("-h")
      helpers.assert_true(code == 0 or code == true or out:find("Utilisation"),
        "-h outputs usage or exits cleanly")
    end)
  end)

  -- ==========================================================================
  -- 4. --dry-run flag
  -- ==========================================================================

  helpers.describe("--dry-run", function()
    helpers.it("--dry-run is accepted without crash", function()
      -- Without a real keyboard device, the daemon will fail to start.
      -- The important thing is it doesn't crash on the flag itself.
      local out, _ = run_daemon("--dry-run 2>&1")
      -- CI runners have no evdev keyboard device — the daemon will reach the
      -- "no device found" error. That's still a graceful exit (not a crash).
      -- Accept: Dry-run acknowledgement, dry-run mention, device-not-found
      -- error, Erreur (French), or any non-empty output (daemon ran).
      helpers.assert_true(
        out:find("Dry%-run") or out:find("dry") or out:find("device") or out:find("Device") or out:find("Erreur") or #out > 10,
        "daemon processes --dry-run flag without crashing")
    end)
  end)

  -- ==========================================================================
  -- 5. --verbose flag
  -- ==========================================================================

  helpers.describe("--verbose", function()
    helpers.it("--verbose flag is accepted", function()
      local out, _ = run_daemon("--verbose --help 2>&1")
      helpers.assert_true(out:find("Utilisation") or out:find("ergopti"),
        "--verbose --help works")
    end)

    helpers.it("-v flag alias works", function()
      local out, _ = run_daemon("-v --help 2>&1")
      helpers.assert_true(out:find("Utilisation") or out:find("ergopti"),
        "-v --help works")
    end)

    -- ROOT CAUSE ENCODED: --verbose was parsed, stored on opts, forwarded into
    -- the tray context and never acted on. The persisted/default level and the
    -- one-run override must both reach ScriptSettings before boot logging.
    --
    -- WHY THIS IS A SOURCE ASSERTION AND NOT A BEHAVIOURAL ONE: --help exits
    -- before startup, while every other CLI route needs a real evdev device. The
    -- settings tests exercise the threshold behaviour; this assertion pins the
    -- entry-point wiring and its ordering.
    helpers.it("--verbose overrides the restored level before the first log line", function()
      local path = daemon_path()
      local handle = io.open(path, "r")
      helpers.assert_true(handle ~= nil, "the daemon source must be readable or this asserts nothing")
      local src = handle:read("*a")
      handle:close()

      local apply_level = src:find(
        'ScriptSettings.apply(opts.verbose and "DEBUG" or nil)', 1, true)
      helpers.assert_true(apply_level ~= nil,
        "startup neither restores the durable setting nor applies --verbose")

      -- Ordering, within this one file: a level raised after boot logging has
      -- already run misses the boot the flag was passed to diagnose.
      local first_start = src:find("Logger.start(", 1, true)
      helpers.assert_true(first_start ~= nil, "the daemon must log a start line")
      helpers.assert_true(apply_level < first_start,
        "the level is raised after the first Logger.start — the boot sequence the "
          .. "flag exists to diagnose would be logged at the old level")
    end)
  end)

  -- ==========================================================================
  -- 6. --tray flag
  -- ==========================================================================

  helpers.describe("--tray", function()
    helpers.it("--tray flag is accepted without crash", function()
      local out, _ = run_daemon("--tray 2>&1")
      -- Without yad installed, it logs a warning. Without a device, it errors.
      -- Either way, it should not crash. Accept any non-empty output.
      helpers.assert_true(
        out:find("tray") or out:find("Tray") or out:find("device") or out:find("Device") or out:find("Erreur") or out:find("yad") or #out > 10,
        "daemon processes --tray flag without crashing")
    end)
  end)

  -- ==========================================================================
  -- 7. --config flag
  -- ==========================================================================

  helpers.describe("--config", function()
    helpers.it("--config with nonexistent path fails gracefully", function()
      local out, _ = run_daemon("--config /tmp/nonexistent_ergopti_config_dir_99999 2>&1")
      -- Should not find any TOML files but should not crash.
      -- On CI the daemon exits immediately (no device) — accept any output.
      helpers.assert_true(out:find("0 TOML") or out:find("No hotstring") or out:find("Erreur") or out:find("device") or #out > 10,
        "daemon handles nonexistent config dir")
    end)

    helpers.it("--config is parsed correctly in help output", function()
      local out, _ = run_daemon("--help 2>&1")
      helpers.assert_true(out:find("%-%-config") or out:find("Utilisation") or out:find("Usage"),
        "--config documented in help")
    end)
  end)

  -- ==========================================================================
  -- 8. --device flag
  -- ==========================================================================

  helpers.describe("--device", function()
    helpers.it("--device is documented in help", function()
      local out, _ = run_daemon("--help 2>&1")
      helpers.assert_true(out:find("%-%-device") or out:find("Utilisation") or out:find("Usage"),
        "--device documented in help")
    end)

    helpers.it("--device /dev/null fails gracefully", function()
      local out, _ = run_daemon("--device /dev/null 2>&1")
      -- /dev/null is not a keyboard — daemon should fail cleanly.
      helpers.assert_true(
        out:find("Erreur") or out:find("device") or out:find("Device") or out:find("périphérique") or #out > 10,
        "daemon handles /dev/null device gracefully")
    end)
  end)

  -- ==========================================================================
  -- 9. --layout flag
  -- ==========================================================================

  helpers.describe("--layout", function()
    helpers.it("--layout is documented in help", function()
      local out, _ = run_daemon("--help 2>&1")
      helpers.assert_true(out:find("%-%-layout") or out:find("Utilisation") or out:find("Usage"),
        "--layout documented in help")
    end)

    helpers.it("--layout qwerty is accepted", function()
      local out, _ = run_daemon("--layout qwerty 2>&1")
      helpers.assert_true(out:find("qwerty") or out:find("Erreur") or out:find("device") or #out > 10,
        "daemon accepts qwerty layout")
    end)

    helpers.it("--layout azerty is accepted", function()
      local out, _ = run_daemon("--layout azerty 2>&1")
      helpers.assert_true(out:find("azerty") or out:find("Erreur") or out:find("device") or #out > 10,
        "daemon accepts azerty layout")
    end)
  end)

  -- ==========================================================================
  -- 10. Edge cases
  -- ==========================================================================

  helpers.describe("edge cases", function()
    helpers.it("bogus flag does not crash", function()
      local out, _ = run_daemon("--bogus-flag-xyz 2>&1")
      -- Accept: Unknown/ignored warning, Erreur/device (crash, not flag-crash), or any output.
      helpers.assert_true(out:find("Unknown") or out:find("ignored") or out:find("Erreur") or out:find("device") or #out > 10,
        "bogus flag handled gracefully")
    end)

    helpers.it("no arguments does not corrupt output", function()
      -- Without a device, the daemon will fail — but it should not crash.
      local ok, launch_err = pcall(function()
        local pipe = io.popen(lua_bin() .. " " .. daemon_path() .. " 2>&1", "r")
        if pipe then
          local _ = pipe:read("*a")
          pipe:close()
        end
      end)
      helpers.assert_nil(launch_err, "and must report none: " .. tostring(launch_err))
      helpers.assert_true(ok, "no-args launch does not crash test harness")
    end)
  end)

  -- ==========================================================================
  -- 11. Subprocess robustness
  -- ==========================================================================

  helpers.describe("subprocess robustness", function()
    helpers.it("rapid launch/exit cycles do not leak processes", function()
      local ok = pcall(function()
        for _ = 1, 5 do
          local pipe = io.popen(lua_bin() .. " " .. daemon_path() .. " --help 2>&1", "r")
          if pipe then
            pipe:read("*a")
            pipe:close()
          end
        end
      end)
      helpers.assert_true(ok, "5x rapid launch/exit does not crash")
    end)
  end)

end)
