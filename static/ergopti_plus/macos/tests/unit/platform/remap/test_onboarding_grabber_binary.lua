--- tests/unit/platform/remap/test_onboarding_grabber_binary.lua

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
--- The fix: check the v15 path, v16 path, AND karabiner_cli (stable across all
--- KE versions) so any future daemon rename is also handled by the cli fallback.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads a fresh onboarding module instance.
--- @return table Onboarding module.
local function fresh_onboarding()
	package.loaded["infra.logger"] = nil
	helpers.load_with_stubs("infra.logger")
	package.loaded["infra.i18n"] = { get = function(k) return k end }
	package.loaded["infra.notifications"] = { notify = function() end }
	package.loaded["infra.dialog_util"] = { block_alert = function() return "later" end }
	package.loaded["platform.remap.onboarding"] = nil
	return helpers.load_with_stubs("platform.remap.onboarding")
end

--- Runs fn with io.open replaced by open_fn, then restores it.
--- @param open_fn function Replacement for io.open.
--- @param fn function Code to run under the patched open.
local function with_io(open_fn, fn)
	local orig = io.open
	io.open = open_fn
	local ok, err = pcall(fn)
	io.open = orig
	if not ok then error(err, 2) end
end


-- ======================================================================
-- ======================================================================
-- ======= 1/ is_grabber_binary_present: v15 and v16 coverage ===========
-- ======================================================================
-- ======================================================================

helpers.describe("onboarding.is_grabber_binary_present: v15/v16 detection", function()
	helpers.it("returns true when only the v15 binary (karabiner_grabber) exists", function()
		local mod = fresh_onboarding()
		with_io(function(path, _)
			if path and path:find("karabiner_grabber", 1, true)
				and not path:find("Karabiner-Core-Service", 1, true) then
				return { close = function() end }, nil
			end
			return nil, "no such file"
		end, function()
			helpers.assert_eq(mod.is_grabber_binary_present(), true)
		end)
	end)

	helpers.it("returns true when only the v16 binary (Karabiner-Core-Service) exists", function()
		local mod = fresh_onboarding()
		with_io(function(path, _)
			if path and path:find("Karabiner-Core-Service", 1, true) then
				return { close = function() end }, nil
			end
			return nil, "no such file"
		end, function()
			helpers.assert_eq(mod.is_grabber_binary_present(), true)
		end)
	end)

	helpers.it("returns true when both v15 and v16 binaries exist", function()
		local mod = fresh_onboarding()
		with_io(function(_path, _) return { close = function() end }, nil end, function()
			helpers.assert_eq(mod.is_grabber_binary_present(), true)
		end)
	end)

	helpers.it("returns true when only karabiner_cli exists (stable fallback across all KE versions)", function()
		local mod = fresh_onboarding()
		with_io(function(path, _)
			if path and path:find("karabiner_cli", 1, true) then
				return { close = function() end }, nil
			end
			return nil, "no such file"
		end, function()
			helpers.assert_eq(mod.is_grabber_binary_present(), true)
		end)
	end)

	helpers.it("returns false when no KE binary exists (v15, v16, or cli)", function()
		local mod = fresh_onboarding()
		with_io(function(_path, _) return nil, "no such file" end, function()
			helpers.assert_eq(mod.is_grabber_binary_present(), false)
		end)
	end)
end)
