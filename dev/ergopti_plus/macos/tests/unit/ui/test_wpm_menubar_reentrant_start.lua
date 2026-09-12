--- tests/unit/ui/test_wpm_menubar_reentrant_start.lua

--- ==============================================================================
--- MODULE: WPM Menubar Reentrant Start Tests
--- DESCRIPTION:
--- A retired startup cannot claim success or mutate a successor's native item.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_menubar = require("tests.support.wpm_menubar_fixture")

helpers.describe("WPM menubar reentrant startup", function()
	helpers.it("(wpm-menubar-reentry) failed pause resume retains inventory intent until retry commits", function()
		with_menubar(function(module, state)
			state.new_failure = "nil"
			helpers.assert_eq(module.resume_after_pause(), false)
			helpers.assert_eq(module.is_running(), true, "pause inventory must retain unpaid restoration intent")
			state.new_failure = nil
			helpers.assert_eq(module.start(), true)
			helpers.assert_eq(module.is_running(), true)
			helpers.assert_eq(module.stop(), true)
			helpers.assert_eq(module.is_running(), false, "committed retry must discharge restoration intent")
		end)
	end)
	for _, mode in ipairs({ "nil", "throw" }) do
		helpers.it("(wpm-menubar-reentry) failed native creation " .. mode .. " rolls back startup", function()
			with_menubar(function(module, state)
				state.new_failure = mode
				helpers.assert_eq(module.start(), false)
				helpers.assert_eq(module.is_running(), false)
				helpers.assert_nil(state.timers[1].timer)
				local errors = 0
				for _, entry in ipairs(state.logs) do
					if entry.level == "error" then errors = errors + 1 end
					helpers.assert_nil(entry.message:find("PRIVATE_DETAIL", 1, true))
					helpers.assert_true(entry.message ~= "Menubar item created.")
					helpers.assert_true(entry.message ~= "WPM menubar widget started successfully.")
				end
				helpers.assert_eq(errors, 1)
			end)
		end)
	end
	helpers.it("(wpm-menubar-reentry) stopped log can start an independently owned successor", function()
		with_menubar(function(module, state)
			helpers.assert_eq(module.start(), true)
			state.on_log = function(_, message)
				if message == "Stopping WPM menubar widget…" then
					state.on_log = nil
					helpers.assert_eq(module.start(), true)
				end
			end
			helpers.assert_eq(module.stop(), false)
			helpers.assert_eq(module.is_running(), true)
			helpers.assert_eq(state.items[1].deleted, true)
			helpers.assert_eq(state.items[2].deleted, false)
			helpers.assert_eq(state.items[2].titles, 1)
			for _, entry in ipairs(state.logs) do helpers.assert_true(entry.level ~= "error") end
		end)
	end)
	for _, restart in ipairs({ false, true }) do
		helpers.it("(wpm-menubar-reentry) item creation log retires startup; restart=" .. tostring(restart), function()
			with_menubar(function(module, state)
				local entered = false
				state.on_log = function(_, message)
					if message == "Menubar item created." and not entered then
						entered = true
						helpers.assert_eq(module.stop(), true)
						if restart then helpers.assert_eq(module.start(), true) end
					end
				end
				helpers.assert_eq(module.start(), false)
				helpers.assert_eq(module.is_running(), restart)
				helpers.assert_eq(state.items[1].deleted, true)
				helpers.assert_eq(state.items[1].titles, 0)
				helpers.assert_nil(state.timers[1].timer)
				state.timers[1].run()
				if restart then
					helpers.assert_eq(state.items[2].titles, 1)
					helpers.assert_eq(state.items[2].deleted, false)
				end
				local successes = 0
				for _, entry in ipairs(state.logs) do
					helpers.assert_true(entry.level ~= "error")
					if entry.message == "WPM menubar widget started successfully." then successes = successes + 1 end
				end
				helpers.assert_eq(successes, restart and 1 or 0)
			end)
		end)
	end
end)
