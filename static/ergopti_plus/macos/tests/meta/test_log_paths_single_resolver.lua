--- tests/meta/test_log_paths_single_resolver.lua

--- ==============================================================================
--- MODULE: Log paths have one resolver (log-paths-single-resolver)
--- DESCRIPTION:
--- Class guard for the whole macOS driver: nothing reads a log path fixed at
--- boot, and nothing rebuilds the logs or crash-reports folder from the
--- configuration folder.
---
--- ROOT CAUSE ENCODED:
--- The logs folder was re-derived as <config>/hammerspoon/logs/ in four files
--- and the crash reports as <config>/hammerspoon/crash_reports/ in a fifth,
--- while today's files were read from Logger.UNIFIED_LOG_FILE and
--- ERRORS_LOG_FILE, fields set once at boot. The native worker rolls its files
--- at midnight, so every consumer of those fields opened yesterday's file, and
--- moving the logs folder meant finding every copy of the formula. The logger
--- (logs_dir, today_log_path, today_errors_path, crash_reports_dir) is now the
--- only resolver; the file-name prefixes are guarded separately by
--- tools/test/test-log-file-names-single-source.cjs.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Removes Lua line and long-bracket comments so prose cannot trip the guard.
--- @param source string
--- @return string
local function strip_lua_comments(source)
	local code = source:gsub("%-%-%[(=*)%[.-%]%1%]", "")
	return (code:gsub("%-%-[^\n]*", ""))
end

helpers.describe("log paths: one resolver per driver (log-paths-single-resolver)", function()
	local source = helpers.read_driver_source()
	helpers.assert_not_nil(source, "the production tree must be readable")
	local code = strip_lua_comments(source)

	helpers.it("scans the real production tree", function()
		helpers.assert_true(#code > 500000, "the scan must cover the whole driver, got " .. #code .. " bytes")
		for _, resolver in ipairs({ "function M.logs_dir(", "function M.today_log_path(",
			"function M.today_errors_path(", "function M.crash_reports_dir(" }) do
			helpers.assert_true(code:find(resolver, 1, true) ~= nil, resolver .. " must exist")
		end
	end)

	helpers.it("never reads a log path fixed at boot", function()
		for _, stale in ipairs({ "UNIFIED_LOG_FILE", "ERRORS_LOG_FILE" }) do
			helpers.assert_nil(code:find(stale, 1, true),
				stale .. " was set once at boot and went stale at midnight; ask the logger instead")
		end
	end)

	helpers.it("never rebuilds the logs or crash-reports folder from the config folder", function()
		for _, formula in ipairs({ "hammerspoon/logs", "hammerspoon/crash_reports" }) do
			helpers.assert_nil(code:find(formula, 1, true),
				"'" .. formula .. "' is a second copy of the logs-folder resolver")
		end
	end)
end)
