--- tests/unit/ui/test_menu_gestures_handlers_match_manifest.lua

--- ==============================================================================
--- MODULE: Regression — circular_spaces gesture toggle vanished from the menu (F-HIGH-5)
--- DESCRIPTION:
--- The gestures_menu "circular_spaces" entry was declared with `type = "feature"`
--- in manifest.toml — the generic path-based idiom for items rendered elsewhere —
--- even though it carries an `id` with a real registered handler
--- (`dyn_circular_spaces` in menu_gestures.lua's dyn_handlers). ManifestMenu.build's
--- "feature" branch is an INTENTIONAL silent no-op reserved for legitimate
--- path-only entries, so the misclassified id-bearing entry produced identical
--- silence: the toggle never appeared in the rendered menu, with no error or log.
---
--- Fix: reclassify the manifest entry as `type = "dynamic"` (mirroring every
--- sibling gesture_slots_* entry) and regenerate menu_manifest.json so the
--- "dynamic" dispatch branch in ManifestMenu.build actually calls the handler.
---
--- This test drives ManifestMenu.build against the REAL manifest data with a
--- dyn_handlers table shaped exactly like menu_gestures.lua's real one, and
--- asserts the circular_spaces item is present in the built result — it fails
--- before the fix (type="feature" is skipped) and passes after.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Builds a dyn_handlers table shaped like menu_gestures.lua's real one, with a
--- circular_spaces handler that appends a single sentinel item.
--- @return table dyn_handlers id -> function(items, ctx)
local function make_dyn_handlers()
	local function noop_handler(items, _ctx)
		table.insert(items, { title = "noop" })
	end

	return {
		disable_all      = noop_handler,
		restore_defaults = noop_handler,
		gesture_slots_2 = noop_handler,
		gesture_slots_3 = noop_handler,
		gesture_slots_4 = noop_handler,
		gesture_slots_5 = noop_handler,
	}
end

helpers.describe("menu_gestures: circular_spaces handler is dispatched by the manifest (F-HIGH-5)", function()
	helpers.it("menu_manifest.json declares circular_spaces as type=dynamic, not type=feature", function()
		-- Goes through ManifestMenu.get_array (not a bare hs.json.decode call) so this
		-- test is immune to an earlier test file's load_with_stubs({json = {...}})
		-- override permanently clobbering the shared _G.hs.json stub (test isolation
		-- footgun unrelated to this finding) — load_with_stubs always hands back a
		-- freshly `__reset()` stub regardless of what a previous test left behind.
		local ManifestMenu = helpers.load_with_stubs("infra.manifest_menu")
		local gestures_menu = ManifestMenu.get_array("gestures_menu")
		helpers.assert_true(type(gestures_menu) == "table" and #gestures_menu > 0,
			"menu_manifest.json must have a non-empty gestures_menu array")

		local entry = nil
		for _, e in ipairs(gestures_menu) do
			if type(e) == "table" and e.id == "circular_spaces" then entry = e end
		end
		helpers.assert_true(entry ~= nil, "gestures_menu must declare a circular_spaces item")
		-- `check` since 2026-08-06: the row is declarative now — label, tick
		-- predicate and greying predicate all in the manifest, with the driver
		-- supplying only the behaviour. What must never come back is `feature`,
		-- which ManifestMenu.build skips in SILENCE; that is the finding this
		-- test was written for, and it is a property of the type, not of which
		-- non-feature type happens to be in use.
		helpers.assert_true(entry.type == "check" or entry.type == "dynamic",
			"circular_spaces must be type=check (or dynamic) — type=feature is silently skipped by ManifestMenu.build (F-HIGH-5), so the row would vanish with nothing said")
	end)

	helpers.it("ManifestMenu.build renders the circular_spaces row from its declaration", function()
		local ManifestMenu = helpers.load_with_stubs("infra.manifest_menu")

		-- The row is built by the RENDERER now, so what the driver supplies is the
		-- behaviour and the state — which is exactly what is stubbed here. The old
		-- version of this case handed over a row-builder; that shape no longer
		-- exists, and asserting on it would have made a row built by MORE shared
		-- code read as a row that vanished.
		local fired = false
		local built = ManifestMenu.build("gestures_menu", "Gestures", make_dyn_handlers(), nil, {
			commands = { circular_spaces = function() fired = true end },
			state_getters = {
				gesture_space_wrap = function() return true end,
				gestures_enabled   = function() return true end,
			},
		})

		local row = nil
		for _, item in ipairs(built) do
			if type(item.fn) == "function" and item.checked == true then row = item end
		end
		helpers.assert_true(row ~= nil,
			"the circular_spaces row must be present, ticked from its checked_when getter — " ..
			"a type=feature misclassification makes ManifestMenu.build skip it silently (F-HIGH-5)")

		row.fn()
		helpers.assert_true(fired,
			"and clicking it must run the command the driver registered, not a no-op: a row " ..
			"rendered with no behaviour looks identical to one that works")
	end)
end)
