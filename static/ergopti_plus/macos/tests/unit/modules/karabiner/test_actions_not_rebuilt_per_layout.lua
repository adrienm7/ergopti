--- tests/unit/modules/karabiner/test_actions_not_rebuilt_per_layout.lua

--- ==============================================================================
--- MODULE: Regression — a layout change re-resolves the actions, it does not
---         rebuild them
--- DESCRIPTION:
--- `load_available_actions` did three things on every call: read and decode a 20 kB
--- actions.json, generate ~600 modifier-chord entries from the shared catalogue,
--- and resolve ~548 logical characters to physical key codes. Only the LAST of
--- those depends on the keyboard layout — and the whole function was re-run on
--- every layout change, from inside an hs.timer body on the single runloop,
--- immediately before regenerating and writing the 100 kB Karabiner config.
---
--- ROOT CAUSE ENCODED:
--- One function conflating a layout-independent build with a layout-dependent
--- resolution. The assertion counts how many times the FILE is read across two
--- calls, so it is about the redundant work rather than about the shape of the
--- cache.
---
--- The split is also the seam the stale-layout-on-resume finding needs: it makes
--- "re-resolve what is already in memory against the current layout" expressible
--- without rebuilding, which previously had no API at all.
--- ==============================================================================

local helpers = require("tests.helpers")

local ACTIONS_FILE = "/fake/actions.json"




-- ==================================================================
-- ==================================================================
-- ======= 1/ The second load does not re-read the file =============
-- ==================================================================
-- ==================================================================

--- Loads a fresh karabiner config module with the JSON read counted.
--- @return table Config, function read_count
local function load_config()
	package.loaded["modules.karabiner.config"] = nil
	package.loaded["infra.logger"] = nil
	_ = helpers.load_with_stubs("infra.logger")

	local reads = { n = 0 }
	local real_open = io.open
	io.open = function(path, mode)
		if type(path) == "string" and path:find("actions.json", 1, true) then
			reads.n = reads.n + 1
			local consumed = false
			return {
				read = function()
					if consumed then return nil end
					consumed = true
					-- One logical_char action is enough: the resolution loop is what must
					-- keep running, and the build is what must not.
					return '[{"id":"a","logical_char":"e"}]'
				end,
				close = function() end,
			}
		end
		return real_open(path, mode)
	end

	local Config = helpers.load_with_stubs("modules.karabiner.config")
	io.open = real_open
	return Config, function() return reads.n end, real_open
end


helpers.describe("karabiner actions: a layout change re-resolves, not rebuilds", function()

	helpers.it("reads actions.json once across two loads", function()
		local Config, read_count, real_open = load_config()
		helpers.assert_type(Config.load_available_actions, "function",
			"the config module must expose load_available_actions")

		-- Re-arm the counter for the calls themselves.
		local reads = { n = 0 }
		io.open = function(path, mode)
			if type(path) == "string" and path:find("actions.json", 1, true) then
				reads.n = reads.n + 1
				local consumed = false
				return {
					read = function()
						if consumed then return nil end
						consumed = true
						return '[{"id":"a","logical_char":"e"}]'
					end,
					close = function() end,
				}
			end
			return real_open(path, mode)
		end

		local first = Config.load_available_actions(ACTIONS_FILE)
		local after_first = reads.n
		helpers.assert_true(after_first >= 1,
			"the first load must actually read the file, or the assertion below would pass "
			.. "against a loader that reads nothing at all")

		-- What a layout change does.
		local second = Config.load_available_actions(ACTIONS_FILE)
		io.open = real_open

		helpers.assert_eq(reads.n, after_first,
			"the JSON read and the ~600 generated modifier-chord entries are "
			.. "layout-INDEPENDENT, and a layout change re-ran both to change only the key "
			.. "codes — inside an hs.timer body on the single runloop, immediately before "
			.. "writing the 100 kB Karabiner config")
		helpers.assert_type(second, "table", "and the second call must still return the list")
		helpers.assert_true(second == first,
			"the same table identity, so callers holding a reference see the re-resolved "
			.. "key codes without having to re-read M.AVAILABLE_ACTIONS")
	end)

	helpers.it("exposes the resolution on its own", function()
		local Config = load_config()

		-- The seam the resume path needs: re-resolve what is already in memory against
		-- the current layout, without rebuilding it.
		helpers.assert_type(Config.resolve_layout_actions, "function",
			"re-resolving an in-memory list against the current layout had no API at all, "
			.. "so the only way to fix stale key codes was to re-run the whole loader")

		local list = { { id = "x", logical_char = "e" }, { id = "y" } }
		local n = Config.resolve_layout_actions(list)
		helpers.assert_eq(n, 1, "only the logical_char action is layout-dependent")
		helpers.assert_type(list[1].karabiner_to, "table",
			"and it must have been given a physical key code")
	end)

	helpers.it("rejects a non-table without raising", function()
		-- Without this case the assertion above would pass against a function that
		-- indexes its argument blindly — and it is called from a timer body, where a
		-- throw is swallowed whole.
		local Config = load_config()
		local ok, n = pcall(Config.resolve_layout_actions, nil)
		helpers.assert_true(ok, "a nil list must not raise")
		helpers.assert_eq(n, 0, "and must report that nothing was resolved")
	end)

end)
