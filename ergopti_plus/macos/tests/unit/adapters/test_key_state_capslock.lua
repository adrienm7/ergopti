--- tests/unit/adapters/test_key_state_capslock.lua

--- ==============================================================================
--- MODULE: KeyState CapsLock HID contract
--- DESCRIPTION:
--- Verifies the adapter preserves false as a successful toggle-to-off state and
--- converts missing, throwing, or malformed native HID calls into nil + error,
--- for the toggle and for the read-only query the diagnostics window uses.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Loads the real adapter with one isolated HID toggle implementation.
--- @param toggle_impl function|nil Native toggle double.
--- @param get_impl function|nil Native query double.
--- @return table adapter
local function load_adapter(toggle_impl, get_impl)
	package.loaded["adapters.key_state"] = nil
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	return helpers.load_with_stubs("adapters.key_state", {
		hid = {
			capslock = { toggle = toggle_impl, get = get_impl },
		},
	})
end


helpers.describe("key_state: CapsLock HID toggle", function()
	helpers.it("preserves both successful boolean states", function()
		local values = { true, false }
		local calls = 0
		local adapter = load_adapter(function()
			calls = calls + 1
			return values[calls]
		end)

		local on, on_err = adapter.toggle_capslock()
		local off, off_err = adapter.toggle_capslock()
		helpers.assert_eq(on, true)
		helpers.assert_nil(on_err)
		helpers.assert_eq(off, false,
			"false is a successful OFF state, not an operational failure")
		helpers.assert_nil(off_err)
	end)

	helpers.it("contains a native exception and reports its detail", function()
		local adapter = load_adapter(function()
			error("HID permission denied")
		end)

		local call_ok, state, err = pcall(adapter.toggle_capslock)
		helpers.assert_true(call_ok, "the native exception must not escape the adapter")
		helpers.assert_nil(state)
		helpers.assert_contains(err, "HID permission denied")
	end)

	helpers.it("rejects a missing API and a non-boolean native result", function()
		local missing = load_adapter(nil)
		local missing_state, missing_err = missing.toggle_capslock()
		helpers.assert_nil(missing_state)
		helpers.assert_contains(missing_err, "unavailable")

		local malformed = load_adapter(function() return nil end)
		local malformed_state, malformed_err = malformed.toggle_capslock()
		helpers.assert_nil(malformed_state)
		helpers.assert_contains(malformed_err, "no boolean state")
	end)
end)

helpers.describe("key_state: CapsLock HID query", function()
	helpers.it("reads both lock states without toggling", function()
		local toggles = 0
		local locked = false
		local adapter = load_adapter(function() toggles = toggles + 1 end, function() return locked end)

		local off, off_err = adapter.capslock_on()
		locked = true
		local on, on_err = adapter.capslock_on()
		helpers.assert_eq(off, false, "false is a successful unlocked state, not a failure")
		helpers.assert_nil(off_err)
		helpers.assert_eq(on, true)
		helpers.assert_nil(on_err)
		helpers.assert_eq(toggles, 0, "reading the state must never change it")
	end)

	helpers.it("reports a missing API, an exception and a non-boolean answer", function()
		local missing_state, missing_err = load_adapter(nil, nil).capslock_on()
		helpers.assert_nil(missing_state)
		helpers.assert_contains(missing_err, "unavailable")

		local call_ok, raised_state, raised_err = pcall(load_adapter(nil, function() error("HID gone") end).capslock_on)
		helpers.assert_true(call_ok, "the native exception must not escape the adapter")
		helpers.assert_nil(raised_state)
		helpers.assert_contains(raised_err, "HID gone")

		local malformed_state, malformed_err = load_adapter(nil, function() return 1 end).capslock_on()
		helpers.assert_nil(malformed_state)
		helpers.assert_contains(malformed_err, "no boolean state")
	end)
end)
