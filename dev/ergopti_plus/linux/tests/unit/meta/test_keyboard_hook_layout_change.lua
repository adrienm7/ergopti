--- tests/unit/meta/test_keyboard_hook_layout_change.lua

--- ==============================================================================
--- MODULE: Choosing A Layout Changes What Keys Mean
--- DESCRIPTION:
--- That the tray's layout submenu changes the physical keyboard family used by
--- metrics while capture and injection refresh from the same active XKB dump.
---
--- THE DEFECT THIS PINS:
--- The daemon's on_layout_change handler used to log "restart daemon to apply"
--- and return. The physical family never reached heatmap/finger-map metrics, and
--- the capture/injection keymap was not refreshed after a live system change.
---
--- WHY AN UNKNOWN NAME MUST BE REFUSED RATHER THAN ACCEPTED:
--- `LAYOUTS[layout] or LAYOUTS["qwerty"]` silently falls back. A name that is
--- stored but unknown therefore reports as applied and resolves every key
--- through the other table — the same failure as before, with the daemon now
--- claiming to have fixed it.
---
--- WHY THE ACTIVE KEYMAP IS CHECKED:
--- Text capture no longer trusts this two-value physical label. keyboard_layout
--- dumps the actual server keymap once, gives it to XKB capture, then builds the
--- inverse injection table from that same text.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Restored afterwards: load_module wipes the named module, not its dependencies,
-- so a recording stub left in place would follow every later test file.
local _saved_reader = package.loaded["modules.hotstrings.input_reader"]

--- Installs an input_reader that records which layout name it is asked for.
--- @return table The layout names seen, in order.
local function install_recording_reader()
	local seen = {}
	package.loaded["modules.hotstrings.input_reader"] = {
		get_layouts = function() return { qwerty = {}, azerty = {} } end,
		resolve_char = function(_code, layout)
			seen[#seen + 1] = layout
			return "x"
		end,
	}
	return seen
end

-- =================================================================
-- =================================================================
-- ======= 1/ The change reaches the resolver ======================
-- =================================================================
-- =================================================================

helpers.describe("keyboard hook: a physical layout-family change", function()

	helpers.it("publishes the chosen family for metrics without resolving text", function()
		install_recording_reader()
		local hook = helpers.load_module("adapters.keyboard_hook")

		helpers.assert_true(hook.set_layout("azerty"),
			"a layout the driver knows must be accepted")
		package.loaded["modules.hotstrings.input_reader"] = _saved_reader
		helpers.assert_eq(hook.get_layout(), "azerty",
			"aggregate and heatmap readers must see the new physical family")
	end)

	helpers.it("refuses a name it cannot honour instead of falling back", function()
		install_recording_reader()
		local hook = helpers.load_module("adapters.keyboard_hook")

		helpers.assert_true(hook.set_layout("qwerty"), "the known name must be accepted first")
		local accepted = hook.set_layout("dvorak-imaginary")
		package.loaded["modules.hotstrings.input_reader"] = _saved_reader

		helpers.assert_true(not accepted,
			"the resolver falls back to qwerty for an unknown name, so storing one "
				.. "would report the change as applied while resolving every key "
				.. "through the other table — the original bug, now with the daemon "
				.. "claiming to have fixed it")
	end)

	helpers.it("rejects a non-string without changing anything", function()
		install_recording_reader()
		local hook = helpers.load_module("adapters.keyboard_hook")
		local accepted = hook.set_layout(nil)
		package.loaded["modules.hotstrings.input_reader"] = _saved_reader
		helpers.assert_true(not accepted,
			"a menu row wired to the wrong argument must not silently blank the "
				.. "layout — that is how the forty-one bridge calls failed")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ Both directions move together ========================
-- =================================================================
-- =================================================================

helpers.describe("keyboard hook: the daemon refreshes the active XKB keymap", function()

	helpers.it("calls the reading side and the writing side from one handler", function()
		-- A source assertion, because the handler lives in the daemon entry point
		-- and loading that starts a device hook. The behaviour above carries the
		-- weight; this pins that the handler is wired to it at all, which is what
		-- was missing — it logged and returned.
		local handle = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
		local source = handle:read("*a")
		handle:close()

		local handler = source:match("on_layout_change = function.-\n\t\t\t\tend,")
		helpers.assert_not_nil(handler,
			"the handler must be findable, or this check passes against any file")
		helpers.assert_true(handler:find("set_layout", 1, true) ~= nil,
			"the physical family must still reach heatmap and aggregate metrics")
		helpers.assert_true(handler:find("keyboard_layout.refresh", 1, true) ~= nil,
			"the active server dump must refresh both capture and injection")

		local layout_handle = assert(io.open(
			helpers.driver_root() .. "/adapters/keyboard_layout.lua", "r"))
		local layout_source = layout_handle:read("*a")
		layout_handle:close()
		helpers.assert_true(layout_source:find("XkbCapture.load(text)", 1, true) ~= nil,
			"refresh must load capture from the exact text used to build injection")
	end)

end)
