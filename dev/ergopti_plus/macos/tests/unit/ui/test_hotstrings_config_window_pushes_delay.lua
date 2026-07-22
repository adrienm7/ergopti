--- tests/unit/ui/test_hotstrings_config_window_pushes_delay.lua

--- ==============================================================================
--- MODULE: Hotstrings Config Window — Live Engine Delay Push (regression)
--- DESCRIPTION:
--- Locks down that a file-level delay edit made in the configuration window is
--- applied to the RUNNING keymap engine, not merely persisted and redrawn.
---
--- ROOT CAUSE ENCODED — PERSISTED AND DISPLAYED BUT NEVER APPLIED:
--- The window wrote the override to hotstrings_config and (since the menubar
--- refresh fix) told the menubar to redraw, so the row correctly showed the new
--- number and dropped its "(default)" tag. But the expansion hot path
--- (modules/keymap/init.lua mapping_fires) reads CoreState.DELAYS, which is
--- populated at boot and afterwards written ONLY by keymap.set_delay. The window
--- never called it, so the engine kept enforcing the PREVIOUS threshold for the
--- rest of the session while every UI claimed the new one was in force.
---
--- The proof it was unintended is the quick-edit sibling doing the same job in
--- ui/menu/menu_hotstrings_management.lua make_category_delay_item, which performs
--- three obligations — set_override, keymap.set_delay ("apply to the running
--- engine so the new delay takes effect without a restart"), then save_prefs +
--- updateMenu. The window replicated the first and third and dropped the second.
---
--- WHY THIS TEST IS BEHAVIOURAL:
--- The defect is invisible to a source scan and to the existing sibling guard
--- (test_hotstrings_config_window_refreshes_menu.lua), which asserts only that the
--- refresh CHANNEL fires — an assertion the broken build satisfies perfectly. This
--- test drives the real bridge handler and observes the engine call itself.
---
--- SCOPE: file-level delays only. Per-section delays live in
--- CoreState.SECTION_DELAYS, rebuilt during hotstring registration rather than
--- through a setter, so they legitimately do not push — asserted explicitly below
--- so a future change cannot quietly widen or narrow the contract.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Category driven through the bridge, and the DELAYS key it maps to.
local TEST_CATEGORY = "magickey"
local TEST_KEY      = "STAR_TRIGGER"

-- Delay the override store resolves to. The push must forward THIS resolved value,
-- not the raw message payload, so clearing an override applies the TOML default.
local RESOLVED_DELAY_SEC = 0.42





-- ================================================
-- ================================================
-- ======= 1/ Engine And Store Test Doubles =======
-- ================================================
-- ================================================

--- Installs spying hotstrings_config + keymap doubles and loads the window.
--- Both are installed BEFORE load_with_stubs so the window captures them at
--- require time (load_with_stubs does not evict modules.* entries).
--- @return table window_module, table engine_spy, table store_spy
local function load_window()
	local store = { sets = 0, clears = 0 }
	package.loaded["modules.hotstrings.hotstrings_config"] = {
		set_override   = function() store.sets   = store.sets   + 1 end,
		clear_override = function() store.clears = store.clears + 1 end,
		get_sections   = function() return {} end,
		resolve        = function() return { delay = RESOLVED_DELAY_SEC, color = "#000000" } end,
		resolve_ext    = function() return { delay = RESOLVED_DELAY_SEC, color = "#000000" } end,
	}

	local engine = { calls = {} }
	package.loaded["modules.keymap"] = {
		DELAY_KEY_TO_CATEGORY = { [TEST_KEY] = TEST_CATEGORY },
		set_delay = function(key, val)
			engine.calls[#engine.calls + 1] = { key = key, val = val }
		end,
		source_priority = function() return nil end,
	}

	local win = helpers.load_with_stubs("ui.hotstrings_config_window")
	return win, engine, store
end

--- Drives one bridge message through the window's handler.
--- @param win table The window module.
--- @param body table The message body.
local function send(win, body)
	win._on_message({ body = body })
end





-- ==============================================
-- ==============================================
-- ======= 2/ The Edit Reaches The Engine =======
-- ==============================================
-- ==============================================

helpers.describe("hotstrings config window applies delay edits to the running engine", function()
	helpers.it("pushes a file-level set_delay into keymap.set_delay", function()
		local win, engine, store = load_window()

		send(win, { action = "set_delay", category = TEST_CATEGORY, ms = 420 })

		helpers.assert_eq(store.sets, 1, "the override must still be persisted")
		helpers.assert_eq(#engine.calls, 1,
			"the window must call keymap.set_delay — CoreState.DELAYS is the only thing the "
			.. "expansion hot path reads, and nothing else writes it after boot")
		helpers.assert_eq(engine.calls[1].key, TEST_KEY,
			"the category must be mapped to its DELAYS key via DELAY_KEY_TO_CATEGORY")
		helpers.assert_eq(engine.calls[1].val, RESOLVED_DELAY_SEC,
			"the RESOLVED delay must be pushed, so a cleared override applies the TOML default")
	end)

	helpers.it("pushes after a file-level clear_delay so the default takes effect", function()
		local win, engine, store = load_window()

		send(win, { action = "clear_delay", category = TEST_CATEGORY })

		helpers.assert_eq(store.clears, 1, "the override must still be cleared")
		helpers.assert_eq(#engine.calls, 1,
			"clearing an override must re-resolve and push the fallback value, otherwise the "
			.. "engine keeps enforcing the override the user just removed")
		helpers.assert_eq(engine.calls[1].val, RESOLVED_DELAY_SEC,
			"the value pushed after a clear must be the re-resolved default")
	end)

	helpers.it("pushes for every category on reset_all", function()
		local win, engine = load_window()

		send(win, { action = "reset_all" })

		helpers.assert_true(#engine.calls >= 1,
			"reset_all wipes file-level delays too, so the engine must be told the categories "
			.. "are back to their TOML defaults")
		helpers.assert_eq(engine.calls[1].key, TEST_KEY,
			"the mapped category must be pushed by its DELAYS key")
	end)

	helpers.it("does NOT push for a per-section delay edit", function()
		local win, engine, store = load_window()

		send(win, { action = "set_delay", category = TEST_CATEGORY, section = "abbreviations", ms = 420 })

		helpers.assert_eq(store.sets, 1, "the section-level override must still be persisted")
		helpers.assert_eq(#engine.calls, 0,
			"per-section delays live in CoreState.SECTION_DELAYS, which is rebuilt at hotstring "
			.. "registration rather than through set_delay — pushing here would write the wrong key")
	end)
end)
