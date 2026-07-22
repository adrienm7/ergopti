--- tests/unit/lib/test_logger_subfile_fallback.lua

--- ==============================================================================
--- MODULE: Logger — Topical Sub-file Routing Always Has a Usable Table
--- DESCRIPTION:
--- Locks down that the topical sub-log fan-out survives a failure to locate the
--- driver root. SUB_LOG_NAMES starts empty and is only populated by
--- _load_sub_files_toml(), which init_log_path() reaches through a block that
--- derives the driver root from debug.getinfo(1, "S").source. That block used to
--- be a BARE pcall whose every early exit — source not "@"-prefixed, path pattern
--- miss, any throw — discarded the error with no Logger call at all.
---
--- ROOT CAUSE ENCODED: on any of those paths SUB_LOG_NAMES stayed `{}`, so
--- _write_to_file()'s fan-out loop iterated nothing and ALL TEN topical logs
--- (mlx, ollama, llm, hotstrings, keylogger, karabiner, gestures, menu, notify,
--- boot) silently stopped existing — with no warning anywhere to explain why.
--- The fix seeds SUB_LOG_NAMES with the built-in fallback list BEFORE the probe
--- and warns when the probe fails (project rule 5.3: fail fast, never swallow).
---
--- This is a BEHAVIORAL test: it makes the logger's own source path
--- unresolvable, then asserts a real topical file appears on disk with the
--- emitted line in it — not merely that a fallback constant exists.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Retention window; irrelevant to this test but required by init_log_path.
local RETENTION_DAYS = 14

--- Creates a directory and every missing ancestor, on both POSIX and Windows.
--- init_log_path() shells its own mkdir through ShellRunner, which is stubbed out
--- under the headless harness, so the test must create the tree itself.
--- @param path string Absolute directory path.
local function mkdir_p(path)
	if package.config:sub(1, 1) == "\\" then
		os.execute('mkdir "' .. path:gsub("/", "\\") .. '" 2>nul')
	else
		os.execute('mkdir -p "' .. path .. '"')
	end
end

helpers.describe("logger — sub-file routing falls back instead of vanishing", function()
	helpers.it("still writes topical logs when the driver root cannot be derived", function()
		local unique    = tostring(os.time()) .. "_" .. tostring(math.random(100000))
		local test_base = "/tmp/ergopti_test_subfile_fallback_" .. unique .. "/"
		local logs_dir  = test_base .. "hammerspoon/logs/"
		pcall(function() mkdir_p(logs_dir) end)

		local L = helpers.load_with_stubs("lib.logger")
		L.set_level("DEBUG")

		-- Pre-load the shell adapter so its own require never runs under the stub.
		pcall(require, "adapters.shell_runner")

		local captured = {}
		L.set_sink(function(line) captured[#captured + 1] = line end)

		-- Make the logger's own source path unresolvable for the duration of the
		-- call, reproducing exactly what a stripped or bytecode-compiled build does.
		local saved_getinfo = debug.getinfo
		debug.getinfo = function() return { source = "=[C]" } end
		local ok_init = pcall(L.init_log_path, test_base, RETENTION_DAYS)
		debug.getinfo = saved_getinfo

		L.error("llm.api_mlx", "boom")
		L.set_sink(nil)

		helpers.assert_true(ok_init, "init_log_path must survive an unresolvable source path")

		local mlx_path = logs_dir .. "ErgoptiPlus_mlx.log"
		local fh = io.open(mlx_path, "r")
		helpers.assert_true(fh ~= nil,
			"the topical mlx log must exist — an empty SUB_LOG_NAMES makes all ten topical logs vanish")

		local content = fh and fh:read("*a") or ""
		if fh then fh:close() end
		helpers.assert_true(content:find("boom", 1, true) ~= nil,
			"the emitted line must be fanned out into the topical mlx log")

		-- The failure must be visible: a silently empty routing table is the bug.
		local warned = false
		for _, line in ipairs(captured) do
			if line:find("[WARNING]", 1, true) and line:find("fell back to the built-in list", 1, true) then
				warned = true
				break
			end
		end
		helpers.assert_true(warned,
			"the failed driver-root derivation must be logged, not swallowed by a bare pcall")

		pcall(function() os.remove(mlx_path) end)
	end)
end)
