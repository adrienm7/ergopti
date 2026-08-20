--- tests/unit/meta/test_keyboard_hook_layout_change.lua

--- ==============================================================================
--- MODULE: Choosing A Layout Changes What Keys Mean
--- DESCRIPTION:
--- That the tray\'s layout submenu reaches the running hook, and refuses a name
--- it cannot honour.
---
--- THE DEFECT THIS PINS:
--- The daemon\'s on_layout_change handler logged "restart daemon to apply" and
--- returned. The hook read the layout name once in start() and never again, so
--- a user who picked azerty carried on having their keys resolved through the
--- qwerty table: every key the two layouts disagree on came back as the wrong
--- character, triggers stopped matching, and the engine\'s model of the text
--- drifted from the document — all while the menu showed a tick beside azerty.
---
--- WHY AN UNKNOWN NAME MUST BE REFUSED RATHER THAN ACCEPTED:
--- `LAYOUTS[layout] or LAYOUTS["qwerty"]` silently falls back. A name that is
--- stored but unknown therefore reports as applied and resolves every key
--- through the other table — the same failure as before, with the daemon now
--- claiming to have fixed it.
---
--- WHY BOTH DIRECTIONS ARE CHECKED:
--- The hook READS keycodes through the layout; keyboard_layout WRITES characters
--- back as keystrokes. Changing one and not the other swaps which half is wrong
--- instead of fixing it, and the symptom of each half is the same: text that
--- does not match what was typed.
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

--- One EV_KEY event.
--- @param code integer
--- @param value integer
--- @return table
local function key(code, value)
	return { type = 1, code = code, value = value }
end




-- =================================================================
-- =================================================================
-- ======= 1/ The change reaches the resolver ======================
-- =================================================================
-- =================================================================

helpers.describe("keyboard hook: a live layout change", function()

	helpers.it("resolves later keys through the layout that was chosen", function()
		local seen = install_recording_reader()
		local hook = helpers.load_module("adapters.keyboard_hook")

		helpers.assert_true(hook.set_layout("azerty"),
			"a layout the driver knows must be accepted")
		hook._test_drive({ key(30, 1) }, { onChar = function() end, onEmitRaw = function() end }, true)

		package.loaded["modules.hotstrings.input_reader"] = _saved_reader
		helpers.assert_true(#seen > 0, "a key must have been resolved")
		helpers.assert_eq(seen[1], "azerty",
			"the name was read once at start() and never again, so picking a layout "
				.. "logged an intention and changed nothing: every key the two layouts "
				.. "disagree on kept coming back as the wrong character")
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

helpers.describe("keyboard hook: the daemon applies the change on both sides", function()

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
			"the reading side: without it the hook keeps resolving keycodes through "
				.. "the previous layout")
		helpers.assert_true(handler:find("keyboard_layout.refresh", 1, true) ~= nil,
			"and the writing side: without it replacements are still typed as the "
				.. "previous layout would produce them, so changing one and not the "
				.. "other swaps which half is wrong instead of fixing it")
	end)

end)
