--- tests/unit/modules/karabiner/test_onboarding_grabber_binary.lua

--- ==============================================================================
--- MODULE: onboarding.is_grabber_binary_present (regression)
--- DESCRIPTION:
--- Locks down the KE version-aware binary detection in is_grabber_binary_present.
---
--- ROOT CAUSE ENCODED: KE v16 (May 2026) renamed karabiner_grabber to
--- Karabiner-Core-Service. The check previously only tested for the v15 binary
--- path, so any machine running KE v16 returned grabber_present=false, causing
--- run_first_run_wizard() to surface a spurious "daemon absent" install dialog
--- on every boot and reload even though KE was fully operational.
--- The fix: check BOTH the v15 and v16 binary paths.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads a fresh onboarding module with io.open controlled by the caller.
--- @param open_fn function Replacement for io.open.
--- @return table Onboarding module instance.
local function fresh_onboarding(open_fn)
	package.loaded["lib.logger"] = nil
	helpers.load_with_stubs("lib.logger")

	package.loaded["lib.i18n"] = { get = function(k) return k end }
	package.loaded["lib.notifications"] = { notify = function() end }
	package.loaded["lib.dialog_util"] = { block_alert = function() return "later" end }

	local orig_io_open = io.open
	io.open = open_fn

	package.loaded["modules.karabiner.onboarding"] = nil
	local ok, mod = pcall(helpers.load_with_stubs, "modules.karabiner.onboarding")

	io.open = orig_io_open

	if not ok then error(mod) end
	return mod
end


-- ======================================================================
-- ======================================================================
-- ======= 1/ is_grabber_binary_present: v15 and v16 coverage ===========
-- ======================================================================
-- ======================================================================

helpers.describe("onboarding.is_grabber_binary_present: v15/v16 detection", function()
	helpers.it("returns true when only the v15 binary (karabiner_grabber) exists", function()
		local mod = fresh_onboarding(function(path, _mode)
			if path and path:find("karabiner_grabber", 1, true)
				and not path:find("Karabiner-Core-Service", 1, true) then
				-- Return a fake file handle — only the nil-check matters
				return {}, nil
			end
			return nil, "no such file"
		end)
		helpers.assert_eq(mod.is_grabber_binary_present(), true)
	end)

	helpers.it("returns true when only the v16 binary (Karabiner-Core-Service) exists", function()
		local mod = fresh_onboarding(function(path, _mode)
			if path and path:find("Karabiner-Core-Service", 1, true) then
				return {}, nil
			end
			return nil, "no such file"
		end)
		helpers.assert_eq(mod.is_grabber_binary_present(), true)
	end)

	helpers.it("returns true when both v15 and v16 binaries exist (dual-install or upgrade)", function()
		local mod = fresh_onboarding(function(_path, _mode)
			return {}, nil
		end)
		helpers.assert_eq(mod.is_grabber_binary_present(), true)
	end)

	helpers.it("returns false when neither v15 nor v16 binary exists (KE not installed)", function()
		local mod = fresh_onboarding(function(_path, _mode)
			return nil, "no such file"
		end)
		helpers.assert_eq(mod.is_grabber_binary_present(), false)
	end)
end)
