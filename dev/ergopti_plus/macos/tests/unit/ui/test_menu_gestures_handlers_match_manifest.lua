--- tests/unit/ui/test_menu_gestures_handlers_match_manifest.lua

--- ==============================================================================
--- MODULE: Regression — a gesture menu row vanished from the menu (F-HIGH-5)
--- DESCRIPTION:
--- A gestures_menu entry carrying an `id` with a real registered handler was
--- declared with `type = "feature"` in manifest.toml — the generic path-based
--- idiom for items rendered elsewhere. ManifestMenu.build's "feature" branch is
--- an INTENTIONAL silent no-op reserved for legitimate path-only entries, so the
--- misclassified id-bearing entry produced identical silence: the row never
--- appeared in the rendered menu, with no error or log.
---
--- The row that was lost (the circular Spaces checkbox) is retired since the
--- wrap became its own pair of actions; the class of defect is not. This test
--- therefore holds every id-bearing gestures_menu entry to a rendered type, and
--- drives ManifestMenu.build against the REAL manifest data to prove a
--- declared, command-backed row is built, ticked from its checked_when getter
--- and wired to the command the driver registers.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Builds a dyn_handlers table shaped like menu_gestures.lua's real one.
--- @return table dyn_handlers id -> function(items, ctx)
local function make_dyn_handlers()
	local function noop_handler(items, _ctx)
		table.insert(items, { title = "noop" })
	end

	return {
		gesture_slots_2 = noop_handler,
		gesture_slots_3 = noop_handler,
		gesture_slots_4 = noop_handler,
		gesture_slots_5 = noop_handler,
	}
end

helpers.describe("menu_gestures: every id-bearing row is rendered by the manifest (F-HIGH-5)", function()
	helpers.it("menu_manifest.json declares no id-bearing gestures_menu entry as type=feature", function()
		-- Goes through ManifestMenu.get_array (not a bare hs.json.decode call) so this
		-- test is immune to an earlier test file's load_with_stubs({json = {...}})
		-- override permanently clobbering the shared _G.hs.json stub (test isolation
		-- footgun unrelated to this finding) — load_with_stubs always hands back a
		-- freshly `__reset()` stub regardless of what a previous test left behind.
		local ManifestMenu = helpers.load_with_stubs("infra.manifest_menu")
		local gestures_menu = ManifestMenu.get_array("gestures_menu")
		helpers.assert_true(type(gestures_menu) == "table" and #gestures_menu > 0,
			"menu_manifest.json must have a non-empty gestures_menu array")

		local with_id, misclassified = 0, {}
		for _, e in ipairs(gestures_menu) do
			if type(e) == "table" and type(e.id) == "string" then
				with_id = with_id + 1
				if e.type == "feature" then misclassified[#misclassified + 1] = e.id end
			end
		end
		helpers.assert_true(with_id >= 5, "the gestures menu must declare its id-bearing rows")
		helpers.assert_eq(#misclassified, 0,
			"type=feature is silently skipped by ManifestMenu.build (F-HIGH-5), so these rows "
				.. "would vanish with nothing said: " .. table.concat(misclassified, ", "))
	end)

	helpers.it("ManifestMenu.build renders the category switch from its declaration", function()
		local ManifestMenu = helpers.load_with_stubs("infra.manifest_menu")

		-- The row is built by the RENDERER, so what the driver supplies is the
		-- behaviour and the state — which is exactly what is stubbed here.
		local fired = false
		local built = ManifestMenu.build("gestures_menu", "Gestures", make_dyn_handlers(), nil, {
			commands = { gestures_toggle = function() fired = true end },
			state_getters = {
				gestures_enabled = function() return true end,
			},
		})

		local row = nil
		for _, item in ipairs(built) do
			if type(item.fn) == "function" and item.checked == true then row = item end
		end
		helpers.assert_true(row ~= nil,
			"the gestures switch must be present, ticked from its checked_when getter — " ..
			"a type=feature misclassification makes ManifestMenu.build skip it silently (F-HIGH-5)")

		row.fn()
		helpers.assert_true(fired,
			"and clicking it must run the command the driver registered, not a no-op: a row " ..
			"rendered with no behaviour looks identical to one that works")
	end)

	-- The maintainer's first group (2026-09-30): the switch, « Restaurer les
	-- valeurs conseillées », « Tout effacer », then a separator. The two scope
	-- rows stood below the system rows until then.
	helpers.it("ManifestMenu.build opens the menu with the switch, the restore and the clear", function()
		local ManifestMenu = helpers.load_with_stubs("infra.manifest_menu")
		local i18n = require("infra.i18n")
		local fired = {}
		local function record(name) return function() fired[#fired + 1] = name end end
		local built = ManifestMenu.build("gestures_menu", "Gestures", make_dyn_handlers(), nil, {
			commands = { gestures_toggle = record("toggle"), scope_restore = record("restore"),
				scope_clear = record("clear"), system_gesture_settings = record("settings") },
			state_getters = { gestures_enabled = function() return true end },
		})
		helpers.assert_eq(built[1].title, i18n.get("menu.gestures.enable"))
		helpers.assert_eq(built[2].title, i18n.get("common.restore_recommended"))
		helpers.assert_eq(built[3].title, i18n.get("common.clear_to_system"))
		helpers.assert_eq(built[4].title, "-")
		for index = 5, #built do
			helpers.assert_true(built[index].title ~= built[2].title and built[index].title ~= built[3].title,
				"no scope row may follow the first group")
		end
		built[2].fn()
		built[3].fn()
		helpers.assert_eq(fired, { "restore", "clear" }, "each row runs the command registered under its id")
	end)
end)
