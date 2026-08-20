--- tests/unit/adapters/test_event_tap_guard.lua

--- ==============================================================================
--- MODULE: Hammerspoon 1.1.1 Event-Tap Native Contract
--- DESCRIPTION:
--- Prevents tests from manufacturing CoreGraphics disable notifications that
--- the bundled Hammerspoon runtime never exposes to a Lua eventtap callback.
--- Hammerspoon 1.1.1 handles both disable event types in Objective-C, re-enables
--- the tap, and returns before invoking the registered Lua callback.
---
--- ROOT CAUSE ENCODED:
--- The previous test added native-only constants to the shared `hs` stub and
--- drove an impossible Lua path. These assertions pin the reviewed runtime,
--- keep the stub faithful, and ensure the obsolete adapter cannot return.
--- ==============================================================================

local helpers = require("tests.helpers")

local CONTRACT_VERSION = "1.1.1"


--- Reads one UTF-8 text file and fails loudly when the fixture path is wrong.
--- @param path string Absolute path.
--- @return string File contents.
local function read_text(path)
	local handle, err = io.open(path, "rb")
	helpers.assert_not_nil(handle, "expected readable contract source: " .. tostring(err))
	local content = handle:read("*a")
	handle:close()
	return content
end


--- Resolves the repository root from the test helper's move-stable driver root.
--- @return string Absolute repository root.
local function repository_root()
	local driver_root = helpers.driver_root():gsub("\\", "/"):gsub("/$", "")
	local root = driver_root:match("^(.*)/static/ergopti_plus/macos$")
	helpers.assert_not_nil(root, "driver root must resolve beneath static/ergopti_plus/macos")
	return root
end


helpers.describe("event tap: bundled native contract", function()

	helpers.it("pins the reviewed contract to the build's default runtime", function()
		local build = read_text(repository_root() .. "/tools/build/build_macos_app.sh")
		local version = build:match(
			'HAMMERSPOON_VERSION="%$%{HAMMERSPOON_VERSION:%-([^}]+)%}"')

		helpers.assert_eq(CONTRACT_VERSION, version,
			"a runtime bump requires reviewing extensions/eventtap/libeventtap.m again")
	end)

	helpers.it("keeps native-only timeout events out of the Lua hs stub", function()
		package.loaded["tests.stubs.hs"] = nil
		local types = require("tests.stubs.hs").eventtap.event.types

		helpers.assert_nil(types.tapDisabledByTimeout,
			"Hammerspoon 1.1.1 does not publish this CoreGraphics value to Lua")
		helpers.assert_nil(types.tapDisabledByUserInput,
			"the stub must mirror the Lua surface, not Objective-C internals")
	end)

	helpers.it("retains ordinary event types while excluding native-only ones", function()
		package.loaded["tests.stubs.hs"] = nil
		local types = require("tests.stubs.hs").eventtap.event.types

		helpers.assert_not_nil(types.keyDown,
			"an empty event-types table would make the absence assertions vacuous")
	end)

	helpers.it("does not expose the removed Lua guard adapter", function()
		package.loaded["adapters.event_tap_guard"] = nil
		local ok = pcall(require, "adapters.event_tap_guard")

		helpers.assert_true(not ok,
			"restoring the adapter would invite production callbacks back onto an unreachable path")
	end)

end)
