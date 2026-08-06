--- tests/meta/test_shutdown_armed_before_risky_requires.lua

--- ==============================================================================
--- MODULE: Guard — the teardown must be armed before anything that can throw
--- DESCRIPTION:
--- hs.shutdownCallback was deliberately moved early in boot, because a reload
--- whose new boot threw before it was installed left the previous session's
--- teardown gone and the new one absent: Karabiner kept remapping the keyboard
--- with ZERO teardown on the next quit.
---
--- It was still armed AFTER the config-dependent requires, and one of those can
--- raise by design — platform/remap/defaults.lua calls error() when the
--- shared tap-hold TOML is unreadable or missing a key, which is the intended
--- fail-fast behaviour. So the one module whose teardown matters most was also
--- the one whose failure to load prevented that teardown from existing.
---
--- ROOT CAUSE ENCODED:
--- Ordering, asserted as ordering: the callback's assignment must appear before
--- the requires that can raise, not merely somewhere in the file.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("boot: the shutdown teardown is armed before the risky requires", function()

	helpers.it("hs.shutdownCallback is assigned before platform.remap is required", function()
		-- read_driver_unit, not read_driver_source: the latter concatenates EVERY
		-- file carrying the symbol, and this compares two byte offsets. Four files
		-- mention hs.shutdownCallback; two of them carry `"platform.remap"` without
		-- the assignment, so whichever the scan reached first decided the verdict
		-- and the same commit produced a green run and a red one. The assignment is
		-- unique to the boot file, which is the only file this ordering is about.
		local src, err = helpers.read_driver_unit("hs.shutdownCallback = function")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the boot file must be readable or this asserts nothing: " .. tostring(err))

		local armed = src:find("hs.shutdownCallback = function", 1, true)

		-- Matched on the MODULE NAME, not on a call spelling. That require is now
		-- `pcall(require, "platform.remap")` — the chain below it reaches a
		-- top-level error() — and pinning `require("platform.remap")` would reject
		-- the guarded form, i.e. reject a change that makes this invariant matter
		-- less rather than more. The ordering it asserts is unaffected either way.
		local require_kb = src:find('"platform.remap"', 1, true)
		helpers.assert_not_nil(armed, "the shutdown callback must be armed")
		helpers.assert_not_nil(require_kb, "platform.remap must be required")
		helpers.assert_true(armed < require_kb,
			"platform/remap/defaults.lua raises at require time when the shared tap-hold "
			.. "TOML is missing a key — by design. Arming the teardown after that require "
			.. "means the one failure that leaves the keyboard remapped is also the one that "
			.. "prevents the teardown from ever being installed")
	end)

end)
