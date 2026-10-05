--- tests/unit/adapters/test_user_hotstring_destination.lua

--- ==============================================================================
--- MODULE: Programmable Hotstring Destination Tests
--- DESCRIPTION:
--- Exercises the real bounded AT-SPI adapter and its cached destination receipt.
--- Labels cannot substitute for a native bus and accessible object identity.
--- ==============================================================================

local helpers = require("tests.helpers")
local Atspi = require("adapters.atspi_focus")
local Destination = require("adapters.user_hotstring_destination")

local function response(bus, path, active, role)
	return 'FOCUS:' .. require("json").encode({ role = role or 61, name = "Identical document",
		attributes = {}, native_bus_name = bus, native_object_path = path, active_scope = active })
end

local function with_snapshot(body)
	local state = { bus = ":1.42", path = "/org/a11y/atspi/accessible/7", active = true, role = 61 }
	Atspi._set_backend_for_test(nil)
	Atspi._set_command_runner_for_test(function(command)
		helpers.assert_contains(command, "timeout -s KILL", "real helper isolation remains in use")
		if state.timeout then return false, "FOCUS:{}" end
		return true, response(state.bus, state.path, state.active, state.role)
	end)
	local ok, problem = xpcall(function() body(state) end, debug.traceback)
	Atspi._set_command_runner_for_test(nil)
	if not ok then error(problem, 0) end
end

helpers.describe("programmable native Linux destination", function()
	helpers.it("(user-hotstrings-native) uses an exact detached bus/object receipt and rechecks actual focus", function()
		with_snapshot(function(s)
			helpers.assert_true(select(2, Atspi.get_snapshot()))
			local capture = Destination.capture()
			helpers.assert_eq(capture, { bus = ":1.42", path = "/org/a11y/atspi/accessible/7" })
			local snapshot = Atspi.cached_snapshot()
			snapshot.native_bus_name = ":1.999"
			helpers.assert_eq(Destination.capture(), capture, "caller mutation cannot alter cached native ownership")
			helpers.assert_true(Destination.current(capture))
			s.path = "/org/a11y/atspi/accessible/8"
			helpers.assert_eq(Destination.current(capture), false, "equal window labels cannot hide a field change")
		end)
	end)
	helpers.it("(user-hotstrings-native) rejects absent active scope, password controls and invalid native identities", function()
		with_snapshot(function(s)
			for _, field in ipairs({ "active", "bus", "path", "role" }) do
				local saved = s[field]
				s[field] = ({ active = false, bus = "org.editor", path = "7", role = 40 })[field]
				Atspi.get_snapshot()
				helpers.assert_nil(Destination.capture(), field .. " cannot own programmable execution")
				s[field] = saved
			end
		end)
	end)
	helpers.it("(user-hotstrings-native) retires the cached receipt when the actual bounded helper times out", function()
		with_snapshot(function(s)
			Atspi.get_snapshot()
			local capture = Destination.capture()
			helpers.assert_not_nil(capture)
			s.timeout = true
			helpers.assert_eq(Destination.current(capture), false)
			helpers.assert_nil(Atspi.cached_snapshot())
			helpers.assert_nil(Destination.capture())
		end)
	end)
end)
