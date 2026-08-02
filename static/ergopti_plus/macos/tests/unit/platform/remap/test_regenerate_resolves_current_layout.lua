--- tests/unit/platform/remap/test_regenerate_resolves_current_layout.lua

--- ==============================================================================
--- MODULE: Karabiner regenerate() — Resolves The Layout It Is Deploying For
--- DESCRIPTION:
--- The layout-dependent part of an action is its karabiner_to[1].key_code, which
--- has to be resolved against whichever keyboard layout is active when the
--- config is written.
---
--- THE BUG THIS PINS:
--- the refresh and the consumer lived on different code paths. The layout
--- watcher refreshed M.AVAILABLE_ACTIONS and then hit the pause guard and
--- returned; M.regenerate() consumed the table and never refreshed it. A layout
--- change while paused is the NORMAL case — the pause-layout feature switches
--- the user off Ergopti as part of pausing — so the table was left resolved for
--- the pause layout, and the resume deployed a Karabiner config built for a
--- layout that was no longer active. Every logical-char binding landed on the
--- wrong physical key until something else happened to trigger another rebuild.
---
--- WHAT IS PINNED: regenerate() re-resolves immediately before the table is
--- consumed, so the key codes belong to the layout being deployed for and not to
--- whichever one was last seen by a different code path.
---
--- The order matters as much as the call: resolving AFTER the build would write
--- the file from the stale table and then fix the table nobody reads again.
--- ==============================================================================

local helpers = require("tests.helpers")




helpers.describe("karabiner.regenerate: resolves against the live layout", function()

	helpers.it("re-resolves the action table before building the config", function()
		-- Selected by a declaration unique to platform/remap/init.lua rather than
		-- by path: a `git mv` of the module must fail this test on its ASSERTION,
		-- not on a missing file. The repo ratchets these reads for that reason.
		local src = helpers.read_driver_source("local function build_paused_ke_config")
		helpers.assert_true(src ~= nil, "platform/remap/init.lua source must be locatable")

		local regen_at = src:find("function M.regenerate(", 1, true)
		helpers.assert_true(regen_at ~= nil, "platform/remap/init.lua must define M.regenerate()")

		local resolve_at = src:find("Config.resolve_layout_actions", regen_at, true)
		helpers.assert_true(resolve_at ~= nil,
			"M.regenerate() must re-resolve the layout-dependent key codes. Without it a "
				.. "resume after a layout change deploys a config built for the layout that "
				.. "was active while paused — every logical-char binding on the wrong key")

		local build_at = src:find("Generator.build_karabiner_json", regen_at, true)
		helpers.assert_true(build_at ~= nil,
			"M.regenerate() must call Generator.build_karabiner_json — this check is "
				.. "measuring nothing otherwise")
		helpers.assert_true(resolve_at < build_at,
			"the re-resolution must come BEFORE the build. After it, the file is written "
				.. "from the stale table and the table nobody reads again is the one fixed")
	end)

	helpers.it("still refuses to deploy while paused", function()
		-- The re-resolution must not be mistaken for a reason to drop the pause
		-- guard: « pause = tout éteint » means a paused script deploys nothing, and
		-- the guard sits in the function that performs the deploy precisely so
		-- every path into it is covered.
		local src = helpers.read_driver_source("local function build_paused_ke_config")
		helpers.assert_true(src ~= nil, "platform/remap/init.lua source must be locatable")

		local regen_at = src:find("function M.regenerate(", 1, true)
		local guard_at = src:find("shortcuts.is_paused()", regen_at, true)
		local build_at = src:find("Generator.build_karabiner_json", regen_at, true)
		helpers.assert_true(guard_at ~= nil and guard_at < build_at,
			"M.regenerate() must check shortcuts.is_paused() before building — a paused "
				.. "script that redeploys has silently undone its own pause")
	end)

end)
