--- tests/unit/adapters/test_accessibility_permission.lua

--- ==============================================================================
--- MODULE: Accessibility permission adapter (accessibility-before-eventtaps)
--- DESCRIPTION:
--- The packaged runtime is its own app identity. v0.0.0-dev.128 reached the
--- first eventtap without Accessibility trust on a Mac whose onboarding had been
--- skipped, and died with a generic pre-start refusal. Boot now asks this
--- adapter first; it must report the native state exactly and prompt only on
--- request.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads a fresh adapter against a stubbed native accessibilityState.
--- @param native function|nil Replacement for hs.accessibilityState.
--- @param body function Receives the adapter and the recorded prompt flags.
local function with_native(native, body)
	local saved = _G.hs.accessibilityState
	local calls = {}
	_G.hs.accessibilityState = native and function(prompt)
		calls[#calls + 1] = prompt
		return native(prompt)
	end or nil
	package.loaded["adapters.accessibility_permission"] = nil
	local ok, err = pcall(function()
		body(require("adapters.accessibility_permission"), calls)
	end)
	_G.hs.accessibilityState = saved
	package.loaded["adapters.accessibility_permission"] = nil
	if not ok then error(err, 0) end
end

helpers.describe("accessibility permission adapter (accessibility-before-eventtaps)", function()
	helpers.it("reports an untrusted process without prompting", function()
		with_native(function() return false end, function(adapter, calls)
			helpers.assert_eq(adapter.is_trusted(), false)
			helpers.assert_eq(calls[1], false)
		end)
	end)

	helpers.it("reports a trusted process", function()
		with_native(function() return true end, function(adapter)
			helpers.assert_eq(adapter.is_trusted(), true)
		end)
	end)

	helpers.it("keeps a failed native query distinct from a refusal", function()
		with_native(function() error("tcc unavailable") end, function(adapter)
			local trusted, detail = adapter.is_trusted()
			helpers.assert_nil(trusted)
			helpers.assert_contains(detail, "tcc unavailable")
		end)
		with_native(nil, function(adapter)
			local trusted, detail = adapter.is_trusted()
			helpers.assert_nil(trusted)
			helpers.assert_contains(detail, "unavailable")
		end)
	end)

	helpers.it("asks macOS for its prompt only through request_prompt", function()
		with_native(function() return false end, function(adapter, calls)
			helpers.assert_eq(adapter.request_prompt(), true)
			helpers.assert_eq(calls[1], true)
		end)
	end)
end)
