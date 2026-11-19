--- tests/meta/boot/test_daemon_boot_guard.lua

--- ==============================================================================
--- MODULE: Daemon Boot Guard Tests
--- DESCRIPTION:
--- A reload restarts the daemon through a relay that discards stderr. A boot
--- that failed above main() (a module that will not load from a half-updated
--- tree) reached LuaJIT's own handler, which writes to stderr only, so the
--- successor died with nothing in the log. These tests start the real entry
--- point in a private home with one module made to fail, and require the
--- failure in the daily log (after the sink) or in bootstrap.log (before it),
--- with a non-zero exit.
--- ==============================================================================

local helpers = require("tests.helpers")
local NoticeRecorder = require("tests.support.notice_recorder")
local shell_quote = require("core.text.engine.utils_core").shell_quote

local PROBE = "boot guard probe: half-updated tree"

--- The interpreter running this suite.
--- @return string
local function lua_bin()
	return (arg and (arg[-1] or arg[0])) or "luajit"
end

--- Starts the entry point with `module` failing to load, in a fresh private home.
--- @param module string A module the entry point requires at its top level.
--- @return table run { home, output, status }
local function boot_with_failing(module)
	local pipe = assert(io.popen("mktemp -d", "r"))
	local home = assert(pipe:read("*l"))
	pipe:close()
	local prelude = NoticeRecorder.child_prelude(helpers.driver_root())
		.. string.format("\npackage.preload[%q] = function() error(%q, 0) end", module, PROBE)
	local env = string.format("HOME=%s XDG_STATE_HOME=%s XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s XDG_CACHE_HOME=%s",
		shell_quote(home), shell_quote(home .. "/state"), shell_quote(home .. "/config"),
		shell_quote(home .. "/data"), shell_quote(home .. "/cache"))
	local command = string.format("%s %s -e %s %s 2>&1; echo \"exit=$?\"", env, lua_bin(),
		shell_quote(prelude), shell_quote(helpers.driver_root() .. "/ergopti_hotstrings.lua"))
	pipe = assert(io.popen(command, "r"))
	local output = pipe:read("*a")
	pipe:close()
	return { home = home, output = output, status = tonumber(output:match("exit=(%d+)%s*$")) }
end

--- Concatenates every file written under the private home.
--- @param home string
--- @return string
local function written(home)
	local pipe = assert(io.popen("find " .. shell_quote(home) .. " -type f -exec cat {} + 2>/dev/null", "r"))
	local text = pipe:read("*a")
	pipe:close()
	return text
end

helpers.describe("daemon boot guard", function()
	if package.config:sub(1, 1) ~= "/" then
		print("  [boot guard not executed: POSIX shell unavailable]")
		return
	end

	helpers.it("(linux-boot-guard) logs a top-level boot failure after the sink and exits non-zero", function()
		local run = boot_with_failing("hotstrings.engine.magic_key")
		local files = written(run.home)
		os.execute("rm -rf " .. shell_quote(run.home))
		helpers.assert_eq(run.status, 1, "a failed boot must fail for the supervisor:\n" .. run.output)
		helpers.assert_contains(files, "Daemon boot failed before its main loop")
		helpers.assert_contains(files, PROBE)
	end)

	helpers.it("(linux-boot-guard) records a boot failure before the sink in bootstrap.log", function()
		-- Required before the sink, and by nothing the bootstrap record needs.
		local run = boot_with_failing("settings.engine.migration.legacy_folder_migration")
		local files = written(run.home)
		os.execute("rm -rf " .. shell_quote(run.home))
		helpers.assert_eq(run.status, 1, "a failed boot must fail for the supervisor:\n" .. run.output)
		helpers.assert_contains(files, require("core.logger.engine.bootstrap_log").CODES.boot_failed)
		helpers.assert_true(not files:find(PROBE, 1, true), "before the sink only the closed code reaches a file")
		helpers.assert_contains(run.output, PROBE, "the error text stays on stderr")
	end)
end)
