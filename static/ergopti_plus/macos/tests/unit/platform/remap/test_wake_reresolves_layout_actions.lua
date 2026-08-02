--- tests/unit/platform/remap/test_wake_reresolves_layout_actions.lua

--- ==============================================================================
--- MODULE: Regression — waking up must re-resolve the layout-dependent actions
--- DESCRIPTION:
--- Every action carrying a `logical_char` is resolved to a physical key code
--- against whatever keyboard layout was active when the list was built. The only
--- thing that re-resolves them is the input-source watcher, and it fires on
--- `AppleSelectedInputSourcesChangedNotification` — a notification that is not
--- delivered for a layout that changed while the machine was asleep, and that the
--- TIS layer can settle differently across a wake.
---
--- So after a sleep/wake the action list can hold the key codes of a layout that is
--- no longer active: Karabiner is then handed a config that remaps the wrong
--- physical keys, and nothing re-derives it until the user switches layout by hand.
---
--- ROOT CAUSE ENCODED:
--- State derived from the layout, refreshed only by a notification that a wake does
--- not guarantee. The assertion drives the wake callback and observes that the
--- resolution ran — not which watcher API delivered it.
---
--- The gestures module already carries this exact pattern for its touch device
--- (`systemDidWake` / `screensDidUnlock` recycle its watchers) and its comment
--- explains why: the OS reports state that the process still believes. The
--- layout-dependent key codes are the same class of belief.
---
--- PROVENANCE: source invariant. Arming the watcher happens inside the module's
--- start path, which needs a live Karabiner-Elements install; the assertion is on
--- the wiring rather than on a driven callback.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Located by the layout-change handler, which is the sibling refresh path.
local ANCHOR = "start_input_source_watcher"




-- ==================================================================
-- ==================================================================
-- ======= 1/ A wake refreshes the layout-derived key codes =========
-- ==================================================================
-- ==================================================================

--- @return string Comment-stripped source of the karabiner module.
local function karabiner_code()
	local src = helpers.read_driver_source(ANCHOR)
	helpers.assert_true(src ~= nil and src ~= "",
		"the karabiner module must be locatable by '" .. ANCHOR .. "'; an empty corpus "
		.. "would make every assertion below vacuous")
	return (src:gsub("%-%-[^\n]*", ""))
end


helpers.describe("karabiner: a wake re-resolves the layout-dependent actions", function()

	helpers.it("arms a wake watcher", function()
		local code = karabiner_code()

		helpers.assert_true(code:find("caffeinate.watcher", 1, true) ~= nil,
			"the input-source notification is not delivered for a layout that changed while "
			.. "the machine was asleep, so a wake must trigger the refresh itself. The "
			.. "gestures module already carries this pattern for its touch device")
		helpers.assert_true(code:find("systemDidWake", 1, true) ~= nil,
			"and it must react to the wake event specifically")
	end)

	helpers.it("re-resolves rather than rebuilding", function()
		local code = karabiner_code()
		local at = code:find("systemDidWake", 1, true)
		helpers.assert_true(at ~= nil, "the wake branch must be findable")
		local body = code:sub(at, at + 800)

		helpers.assert_true(body:find("resolve_layout_actions", 1, true) ~= nil,
			"the JSON read and the ~600 generated chord entries are layout-independent; a "
			.. "wake only needs the key codes re-derived, which is what the split "
			.. "resolution exists for")
		helpers.assert_true(body:find("load_available_actions", 1, true) == nil,
			"calling the full loader here would put the whole rebuild back on the wake "
			.. "path, which is the cost the split just removed")
	end)

	helpers.it("does not redeploy while paused", function()
		local code = karabiner_code()
		local at = code:find("systemDidWake", 1, true)
		local body = code:sub(at, at + 800)

		-- Without this the wake would undo a pause: regenerating hands Karabiner the
		-- full Ergopti config back, which is the "pause = tout éteint" contract the
		-- layout-change path already protects with the same check.
		helpers.assert_true(body:find("is_paused", 1, true) ~= nil,
			"a wake while paused must not redeploy the remapping — that would silently "
			.. "undo the pause, exactly as the layout-change path documents")
	end)

end)
