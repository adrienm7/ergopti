--- tests/unit/adapters/keyboard/test_accessibility_messaging_timeout.lua

--- ==============================================================================
--- MODULE: Bounded Accessibility calls (ax-messaging-timeout)
--- DESCRIPTION:
--- Every Accessibility call runs on the Hammerspoon main thread, where the
--- keyboard event taps run too. macOS lets a call to an application that does
--- not answer wait six seconds: issue #100 logged an ignored-window probe that
--- held the main thread 1.5 s at an application switch, and the 13.4 s freeze
--- of #99 was a scan over such waits. The taps time out meanwhile and every key
--- typed then comes out late, held (the press-and-hold popup) or lost. Boot
--- sets one process-wide messaging timeout before the first input owner.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads a fresh adapter against a stubbed hs.window.timeout.
--- @param native function|nil Replacement for hs.window.timeout.
--- @param body function Receives the adapter and the recorded timeouts.
local function with_timeout(native, body)
	local saved = _G.hs.window.timeout
	local calls = {}
	_G.hs.window.timeout = native and function(seconds)
		calls[#calls + 1] = seconds
		return native(seconds)
	end or nil
	package.loaded["adapters.accessibility_permission"] = nil
	local ok, err = pcall(function()
		body(require("adapters.accessibility_permission"), calls)
	end)
	_G.hs.window.timeout = saved
	package.loaded["adapters.accessibility_permission"] = nil
	if not ok then error(err, 0) end
end

helpers.describe("Accessibility calls are bounded (ax-messaging-timeout)", function()
	helpers.it("sets one process-wide timeout well under the six seconds macOS allows", function()
		with_timeout(function() return true end, function(adapter, calls)
			helpers.assert_eq(adapter.bound_messaging_timeout(), true)
			helpers.assert_eq(#calls, 1)
			helpers.assert_eq(calls[1], adapter.MESSAGING_TIMEOUT_SEC)
			helpers.assert_true(adapter.MESSAGING_TIMEOUT_SEC > 0 and adapter.MESSAGING_TIMEOUT_SEC <= 1.0,
				"a hung application must release the event taps within a second")
		end)
	end)

	helpers.it("reports a refusal or a missing API instead of claiming bounded calls", function()
		with_timeout(function() return false end, function(adapter)
			local bounded, detail = adapter.bound_messaging_timeout()
			helpers.assert_eq(bounded, false)
			helpers.assert_contains(detail, "refused")
		end)
		with_timeout(function() error("AX unavailable") end, function(adapter)
			local bounded, detail = adapter.bound_messaging_timeout()
			helpers.assert_eq(bounded, false)
			helpers.assert_contains(detail, "AX unavailable")
		end)
		with_timeout(nil, function(adapter)
			local bounded, detail = adapter.bound_messaging_timeout()
			helpers.assert_eq(bounded, false)
			helpers.assert_contains(detail, "unavailable")
		end)
	end)

	helpers.it("bounds them at boot before the first input owner starts", function()
		local source, err = helpers.read_driver_unit('Boot.stage("Shortcuts pre-start")')
		helpers.assert_not_nil(source, "the boot sequence must be locatable: " .. tostring(err))
		local bound_at = source:find("AccessibilityPermission.bound_messaging_timeout()", 1, true)
		local prestart_at = source:find('Boot.stage("Shortcuts pre-start")', 1, true)
		local keymap_at = source:find('Boot.stage("Keymap engine started")', 1, true)
		helpers.assert_not_nil(bound_at, "boot must bound Accessibility calls")
		helpers.assert_not_nil(prestart_at)
		helpers.assert_not_nil(keymap_at)
		helpers.assert_true(bound_at < prestart_at and bound_at < keymap_at,
			"the timeout must be in place before any event tap is armed")
	end)
end)
