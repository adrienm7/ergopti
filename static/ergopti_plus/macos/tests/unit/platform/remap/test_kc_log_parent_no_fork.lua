-- tests/unit/platform/remap/test_kc_log_parent_no_fork.lua

--- ==============================================================================
--- MODULE: Regression - the KC log folder is checked before any mkdir fork
--- DESCRIPTION:
--- The first Karabiner regeneration of every boot forked `mkdir -p` for the
--- physical KC log folder, which exists after the first run. A fork from the
--- Hammerspoon process cost about 40 ms on the Mac (four of them took 161 ms in
--- the 23:33 keystats start). The folder's attributes now answer first.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("remap regeneration: KC log folder", function()
	helpers.it("asks the folder attributes before forking mkdir -p", function()
		local src = helpers.read_driver_source("Ensure the parent directory of the KC physical log exists")
		local start = src:find("Ensure the parent directory of the KC physical log exists", 1, true)
		helpers.assert_true(start ~= nil, "the KC log folder block must be locatable")
		local probe = src:find('hs.fs.attributes, kc_parent, "mode"', start, true)
		local fork = src:find('hs.execute, "mkdir -p "', start, true)
		helpers.assert_true(probe ~= nil and fork ~= nil and probe < fork,
			"an existing KC log folder must be answered without a shell fork")
	end)
end)
