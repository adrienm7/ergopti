--- tests/meta/architecture/test_karabiner_capsword_lock_release.lua

--- ==============================================================================
--- MODULE: Karabiner CapsWord Pointer Watcher Meta Test
--- DESCRIPTION:
--- Static source guard for platform/remap/watchers.lua.
---
--- ROOT CAUSE ENCODED:
--- The CapsWord pointer watcher used to spawn karabiner_cli --get-variable
--- to learn whether Karabiner had CapsWord on. No karabiner_cli has that option
--- (cxxopts answers exit 2), so the probe failed on every Mac, warned at every
--- boot and carried a task, watchdog and lock-leak machinery of its own. A
--- pointer event now cancels only a CapsWord the driver knows about.
---
--- This test also verifies the inputSourceChanged single-owner fix: Hammerspoon's
--- setter unsets its predecessor and has no getter, so every consumer must use
--- the process-wide broker.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_source(selector)
	local src = helpers.read_driver_source(selector)
	return src
end

local function strip_comments(src)
	local out = {}
	for line in src:gmatch("[^\n]*") do
		if not line:match("^%s*%-%-") then
			out[#out + 1] = line
		end
	end
	return table.concat(out, "\n")
end


-- ====================================================
-- ====================================================
-- ======= 1/ No karabiner_cli variable reader ========
-- ====================================================
-- ====================================================

helpers.describe("karabiner/watchers.lua: CapsWord pointer watcher spawns no reader", function()

	helpers.it("(capsword-no-cli-reader) the watcher never runs karabiner_cli", function()
		local src = strip_comments(read_source("local function parse_layout_name"))
		helpers.assert_true(src:find("get-variable", 1, true) == nil,
			"karabiner_cli has no --get-variable option; the watcher must not spawn it")
		helpers.assert_true(src:find("platform.remap.ke_paths", 1, true) == nil,
			"the pointer watcher needs no Karabiner executable path")
		helpers.assert_true(src:find("KeVariables.supersede_capsword_activation", 1, true) ~= nil,
			"a pointer event still cancels the CapsWord the driver knows about")
	end)

end)


-- ======================================================================
-- ======================================================================
-- ======= 2/ inputSourceChanged single native broker ====================
-- ======================================================================
-- ======================================================================

helpers.describe("karabiner/watchers.lua: inputSourceChanged broker ownership", function()

	helpers.it("watchers subscribe through the process-wide broker", function()
		local src = strip_comments(read_source("local function parse_layout_name"))
		helpers.assert_true(src:find("InputSourceBroker.subscribe", 1, true) ~= nil,
			"the Karabiner watcher must not replace the setter-only global callback")
		helpers.assert_true(src:find("hs.keycodes.inputSourceChanged", 1, true) == nil,
			"only the adapter broker may call the native global setter")
	end)

	helpers.it("watcher teardown removes only its named broker subscriber", function()
		local src = strip_comments(read_source("local function parse_layout_name"))
		helpers.assert_true(src:find("InputSourceBroker.unsubscribe", 1, true) ~= nil,
			"Karabiner teardown must preserve every sibling subscriber")
	end)

end)
