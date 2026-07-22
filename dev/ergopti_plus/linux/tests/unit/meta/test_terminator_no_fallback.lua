--- static/ergopti_plus/linux/tests/unit/meta/test_terminator_no_fallback.lua

--- ==============================================================================
--- MODULE: Terminator No-Fallback Invariant Test (Linux driver)
--- DESCRIPTION:
--- Regression guard for the fail-fast hardening of the daemon entry point. The
--- terminator catalogue is the single source of truth (shared keymap.terminators)
--- and ships alongside the daemon, so a require failure is a broken install. The
--- daemon must NOT silently degrade to a hardcoded minimal {space . , newline}
--- set — that would produce wrong word-boundary detection and therefore wrong
--- expansions (rule 5.3/5.4). It must Logger.error + error() instead.
---
--- This test text-scans ergopti_hotstrings.lua (it does not require it — the
--- daemon pulls in evdev/uinput bindings unavailable in the headless harness).
--- ==============================================================================

local helpers = require("tests.helpers")

local DRIVER_ROOT = helpers.driver_root()
local DAEMON_PATH = DRIVER_ROOT .. "/ergopti_hotstrings.lua"

local function read_file(path)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local content = fh:read("*a")
	fh:close()
	return content
end


-- ==================================================
-- ==================================================
-- ======= 1/ No Hardcoded Terminator Fallback ======
-- ==================================================
-- ==================================================

helpers.describe("linux: daemon fails fast on a missing terminator catalogue", function()
	local src = read_file(DAEMON_PATH)

	helpers.it("ergopti_hotstrings.lua is readable", function()
		helpers.assert_true(type(src) == "string" and #src > 0,
			"could not read " .. DAEMON_PATH)
	end)

	if type(src) == "string" then
		helpers.it("still loads the shared keymap.terminators single source", function()
			-- Loaded via pcall(require, "keymap.terminators") — match the module ref.
			helpers.assert_true(src:find('"keymap%.terminators"') ~= nil,
				"daemon must require the shared keymap.terminators module")
		end)

		helpers.it("does not declare a hardcoded minimal terminator fallback", function()
			helpers.assert_true(src:find("_fallback") == nil,
				"the minimal {space . , newline} fallback must be gone (fail fast instead)")
		end)

		helpers.it("fails loudly (error) when the catalogue cannot load", function()
			-- The terminators loader block must raise rather than return a stub.
			helpers.assert_true(src:find("keymap%.terminators is required") ~= nil,
				"daemon must error() with a clear message on a terminators load failure")
		end)
	end
end)
