--- tests/meta/shutdown/test_shutdown_stops_script_watchers.lua

--- ==============================================================================
--- MODULE: Shutdown stops the script watchers (meta)
--- DESCRIPTION:
--- init.lua shutdownCallback must stop every script watcher explicitly.
--- Source-scan guard split out of the audit-named regression file it came from.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_source(selector)
	local src = helpers.read_driver_source(selector)
	return src
end

helpers.describe("shutdown stops the script watchers", function()

	-- ==================================================
	-- ===== 2) script_watchers — explicit :stop() loop
	-- ==================================================

	helpers.it("init.lua shutdownCallback must stop all script_watchers", function()
		local src = read_source("local function has_common_hotstring_groups") -- init.lua
		assert(src, "init.lua must be readable")
		-- The bug: _G.script_watchers pinned to prevent GC but never :stop()'d.
		-- The fix: loop over the table and pcall w:stop() in shutdownCallback.
		assert(
			src:find("script_watchers", 1, true) and src:find(":stop()", 1, true),
			"init.lua: shutdownCallback must iterate _G.script_watchers and call :stop() on each"
		)
	end)

end)
