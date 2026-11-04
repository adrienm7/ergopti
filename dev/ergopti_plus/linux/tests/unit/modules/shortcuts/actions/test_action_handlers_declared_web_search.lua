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

	--- Runs body with xclip absent (io.popen returns nil).
	local function without_xclip(body)
		local real_popen = io.popen
		io.popen = function() return nil end
		local ok, err = pcall(body)
		io.popen = real_popen
		if not ok then error(err, 0) end
	end

	--- Runs body with xclip returning `selection`.
	local function with_selection(selection, body)
		local real_popen = io.popen
		io.popen = function()
			return {
				read = function() return selection end,
				close = function() return true end,
			}
		end
		local ok, err = pcall(body)
		io.popen = real_popen
		if not ok then error(err, 0) end
	end

	helpers.it("search-web: refuses an empty selection instead of opening a blank search", function()
		-- Regression: with xclip missing (notably every Wayland session
		-- without it), primary_selection() answered "" and the gesture opened
		-- the engine with an empty query ÔÇö a wasted tab that answers nothing.
		local G = helpers.load_module("modules.gestures.manager")
		G.init({ enabled = false })
		helpers.assert_true(
			G.set_action_parameter("tap_3", "search_web", "https://duckduckgo.com/?q=%s"),
			"the parameter must store before the gesture can run")
		without_xclip(function()
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
		with_selection("hello world", function()
			with_recorded_shell(function(commands)
				G.execute_action("search_web", "tap_3")
				helpers.assert_eq(#commands, 1, "a real selection must open exactly one search")
				helpers.assert_true(commands[1]:find("q=hello%20world", 1, true) ~= nil,
					"the selection must reach the engine URL-encoded")
			end)
		end)
	end)

end)

