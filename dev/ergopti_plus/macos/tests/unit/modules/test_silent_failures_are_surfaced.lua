--- tests/unit/modules/test_silent_failures_are_surfaced.lua

--- ==============================================================================
--- MODULE: Regression — three writers must stop reporting success they did not get
--- DESCRIPTION:
--- Convention 5.3 is fail-fast: a function that cannot complete its contract must
--- say so. Three sites reported success unconditionally instead.
---
--- ROOT CAUSE ENCODED:
--- Each had the same shape — the operation that actually decides the outcome was
--- performed, its result discarded, and a success line logged regardless. The
--- assertions below are on WHAT WAS LOGGED for a failing operation, not on the
--- presence of a particular call, so a rewrite that reaches the guarantee some
--- other way still satisfies them.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Installs a capturing logger and returns the captured lines per level.
--- @return table captured Fields: error, warn, success, debug — arrays of strings.
local function capture_logger()
	local captured = { error = {}, warn = {}, success = {}, debug = {}, info = {}, start = {} }
	local function sink(level)
		return function(_log, fmt, ...)
			local ok, line = pcall(string.format, fmt, ...)
			table.insert(captured[level], ok and line or tostring(fmt))
		end
	end
	package.loaded["lib.logger"] = {
		error = sink("error"), warn = sink("warn"), success = sink("success"),
		debug = sink("debug"), info = sink("info"), start = sink("start"),
		trace = function() end, done = function() end,
		pcall = function(_l, fn, ...) return pcall(fn, ...) end,
	}
	return captured
end


--- @param lines table Array of captured log lines.
--- @param needle string Substring to look for.
--- @return boolean
local function any_contains(lines, needle)
	for _, l in ipairs(lines) do
		if l:find(needle, 1, true) then return true end
	end
	return false
end




-- ==================================================================
-- ==================================================================
-- ======= 1/ A group that registers nothing says so ================
-- ==================================================================
-- ==================================================================

helpers.describe("registry: loading a mapping file that yields nothing is not a success", function()

	helpers.it("warns instead of pairing its start with a success", function()
		local captured = capture_logger()
		package.loaded["modules.keymap.registry_groups"] = nil
		local Groups = helpers.load_with_stubs("modules.keymap.registry_groups")

		local state = {
			mappings = {}, mappings_lookup = {}, groups = {},
			mappings_by_tail_char = {}, mappings_by_star_tail_char = {},
			seq_counter = 0, current_group = nil,
		}
		Groups.init(state, { add = function() end, sort_mappings = function() end })

		-- A path that cannot be read. The shared reader never raises for this: it
		-- returns an empty table, which is exactly why the caller could not tell
		-- an empty file from a missing one.
		pcall(Groups.load_toml, "ghost_group", "/nonexistent/ghost.toml")

		helpers.assert_true(
			any_contains(captured.warn, "ZERO") or any_contains(captured.error, "ghost.toml"),
			"a group that registers no mappings must report it: the reader does not raise, so "
			.. "an unreadable path otherwise produced a start/success pair whose count came "
			.. "from every OTHER group — the one number guaranteed to look healthy")
		helpers.assert_true(not any_contains(captured.success, "ghost_group"),
			"and it must not claim success for a file it did not load")
	end)

end)




-- ==================================================================
-- ==================================================================
-- ======= 2/ A user-facing toggle records what it applied ==========
-- ==================================================================
-- ==================================================================

helpers.describe("registry: the repeat-engine toggle logs its new value", function()

	helpers.it("logs on both transitions", function()
		local captured = capture_logger()
		package.loaded["modules.keymap.registry_index"] = nil
		local RI = helpers.load_with_stubs("modules.keymap.registry_index")

		RI.set_repeat_feature_enabled(false)
		RI.set_repeat_feature_enabled(true)

		helpers.assert_true(#captured.debug >= 2,
			"convention 5.5: a public setter must log its new value, or the applied state of "
			.. "this feature cannot be read back from the logs like every other setting's")
	end)

end)
