--- tests/unit/modules/shortcuts/actions/test_action_handlers_declared_web_search.lua

---
--- ==============================================================================
--- MODULE: Regression — actions the shared catalogue declares for Linux must
---         actually do something (linux-declared-actions-unhandled)
--- DESCRIPTION:
--- `_shared/modules/actions/actions.toml` declared 79 actions for Linux and the
--- driver implemented 40 of them. The other 39 were not broken in a way anyone
--- could see: the picker offers every DECLARED action as bindable, so the user
--- bound one, the assignment was stored, the chord fired — and `_execute_action`
--- fell through to `Logger.debug("Unknown action")`. No error at bind time, none
--- at fire time, and DEBUG is not where a user looks.
---
--- ROOT CAUSE ENCODED: a catalogue is a promise. Ten of the first eleven closed
--- were not missing code at all — the shared row described the chord for
--- AutoHotkey and Hammerspoon and had no `emit_linux` column, so the generator
--- emitted no row for it. A driver-shaped gap is worth checking in the DATA
--- before it is checked in the driver.
---
--- These tests drive the REAL dispatcher with a recording shell so what is
--- asserted is the command that would run, not the presence of a table key.
--- ==============================================================================

package.loaded["tests.support.modules.shortcuts.actions.action_handlers_declared_fixture"] = nil
local Fixture = require("tests.support.modules.shortcuts.actions.action_handlers_declared_fixture")
local helpers, with_recorded_shell =
	Fixture.helpers, Fixture.with_recorded_shell




-- =========================================================
-- =========================================================
-- ======= 7/ Search needs something to search =============
-- =========================================================
-- =========================================================

helpers.describe("linux actions: web search", function()

	--- Supplies the platform PRIMARY reader during the action.
	local function with_primary(ok, selection, body)
		local saved = package.loaded["adapters.clipboard"]
		package.loaded["adapters.clipboard"] = { read_primary = function() return ok, selection end }
		local ran, err = pcall(body)
		package.loaded["adapters.clipboard"] = saved
		if not ran then error(err, 0) end
	end

	helpers.it("search-web: refuses an empty selection instead of opening a blank search", function()
		-- Regression: when the PRIMARY reader fails, the gesture opened
		-- the engine with an empty query ÔÇö a wasted tab that answers nothing.
		local G = helpers.load_module("modules.gestures.manager")
		G.init({ enabled = false })
		helpers.assert_true(
			G.set_action_parameter("tap_3", "search_web", "https://duckduckgo.com/?q=%s"),
			"the parameter must store before the gesture can run")
		with_primary(false, "", function()
			with_recorded_shell(function(commands)
				G.execute_action("search_web", "tap_3")
				helpers.assert_eq(#commands, 0,
					"with no selection there is no query ÔÇö opening the engine on "
						.. "an empty q= wastes a tab and answers nothing")
			end)
		end)
	end)

	helpers.it("search-web: searches the selected text when there is some", function()
		-- Lock-in against over-correction: refusing everything would also make
		-- this green, while breaking the action's entire purpose.
		local G = helpers.load_module("modules.gestures.manager")
		G.init({ enabled = false })
		G.set_action_parameter("tap_3", "search_web", "https://duckduckgo.com/?q=%s")
		with_primary(true, "hello world", function()
			with_recorded_shell(function(commands)
				G.execute_action("search_web", "tap_3")
				helpers.assert_eq(#commands, 1, "a real selection must open exactly one search")
				helpers.assert_true(commands[1]:find("q=hello%20world", 1, true) ~= nil,
					"the selection must reach the engine URL-encoded")
			end)
		end)
	end)

	helpers.it("search-web reads Wayland PRIMARY through the bounded native adapter", function()
		local names = { "adapters.clipboard", "adapters.shell_runner", "infra.display_server" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local read_command
		package.loaded[names[1]] = nil
		package.loaded[names[2]] = {
			has_command = function(name) return name == "wl-paste" end,
			exec_checked = function(command) read_command = command; return true, "bonjour été" end,
		}
		package.loaded[names[3]] = { is_wayland = function() return true end, is_x11 = function() return false end }
		local ok, err = pcall(function()
			local G = helpers.load_module("modules.gestures.manager")
			G.init({ enabled = false })
			helpers.assert_true(G.set_action_parameter("tap_3", "search_web", "https://duckduckgo.com/?q=%s"))
			with_recorded_shell(function(commands)
				G.execute_action("search_web", "tap_3")
				helpers.assert_eq(#commands, 1)
				helpers.assert_true(commands[1]:find("q=bonjour%20%C3%A9t%C3%A9", 1, true) ~= nil)
			end)
			helpers.assert_true(read_command:find("timeout ", 1, true) ~= nil)
			helpers.assert_true(read_command:find("wl-paste --primary", 1, true) ~= nil)
		end)
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		if not ok then error(err, 0) end
	end)

end)

