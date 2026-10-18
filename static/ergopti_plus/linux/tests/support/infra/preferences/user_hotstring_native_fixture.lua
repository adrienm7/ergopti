--- tests/support/infra/preferences/user_hotstring_native_fixture.lua

--- ==============================================================================
--- MODULE: Programmable Native Injection Fixture
--- DESCRIPTION:
--- Keeps the real layout plan/current/view protocol installed before the real
--- injector captures its ports. Only the inverse table, clock and output wire
--- are controlled; this fixture does not qualify native kernel input.
--- ==============================================================================
local M = {}
local helpers = require("tests.helpers")

--- Runs one actual multiphase injection with a scoped real layout and injector.
--- @param f table Runtime fixture with optional phase/output transition callbacks.
--- @param body function Receives the independently recorded output transitions.
function M.with(f, body)
	local names = { "adapters.keyboard_layout", "modules.hotstrings.injector" }
	local previous = {}; for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local Capture = require("adapters.xkb_capture")
	local caps, inject = Capture.caps_locked, f.injector_port.inject
	local injector
	local ok, problem = xpcall(function()
		package.loaded[names[1]] = nil
		local layout = require(names[1])
		layout._set_table_for_test({ ["0"] = { keycode = 11, mods = {} } })
		-- The fixture uses genuine opaque plan receipts and detached plan views.
		-- Do not replace public plan ports after the injector has captured them.
		local plan, _, receipt = layout.plan("0")
		helpers.assert_eq(plan, { { keycode = 11, mods = {} } })
		helpers.assert_true(layout.plan_current(receipt, false) and layout.plan_current(receipt, true))
		helpers.assert_eq(layout.plan_view(receipt), plan)
		helpers.assert_true(not rawequal(layout.plan_view(receipt), plan))
		package.loaded[names[2]] = nil
		injector = require(names[2])
		Capture.caps_locked = function() return false end
		local emitted = {}
		injector._set_uinput({ is_open = function() return true end,
			emit = function(code, value)
				emitted[#emitted + 1] = { code = code, value = value }
				if f.native_emit_hook then f.native_emit_hook(code, value) end
				return true
			end })
		injector._set_nanosleep_for_test(function()
			if f.phase_mutate then f.phase_mutate() end
		end)
		f.injector_port.inject = function(...)
			local result = injector.inject(...)
			f.delivery = result
			return result
		end
		body(emitted)
	end, debug.traceback)
	if injector then injector._set_uinput(nil); injector._set_nanosleep_for_test(nil) end
	Capture.caps_locked, f.injector_port.inject = caps, inject
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	if not ok then error(problem, 0) end
end

return M
