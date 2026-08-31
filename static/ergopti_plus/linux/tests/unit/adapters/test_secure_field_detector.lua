--- tests/unit/adapters/test_secure_field_detector.lua

--- ==============================================================================
--- MODULE: SecureFieldDetector Behavioral Tests (Linux)
--- DESCRIPTION:
--- Locks the tri-state, official role value, fail-closed projection, known-app
--- fallback, focus epoch, and stale-result rejection contracts.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =========================================
-- =========================================
-- ======= 1/ Tri-state Verdicts ===========
-- =========================================
-- =========================================

helpers.describe("SecureFieldDetector: tri-state verdicts", function()
	local previous_logger = package.loaded["logger.shim"]
	package.loaded["logger.shim"] = helpers.make_logger_stub()

	local function fresh(probe)
		package.loaded["adapters.secure_field_detector"] = nil
		local adapter = helpers.load_module("adapters.secure_field_detector")
		if probe then adapter._set_probe_for_test(probe) end
		return adapter
	end

	helpers.it("starts unknown and projects unknown to blocked", function()
		local adapter = fresh()
		helpers.assert_eq(adapter.getVerdict(), "unknown", "startup has no focused-role evidence")
		helpers.assert_eq(adapter.isSecureField(), true,
			"the legacy boolean port must fail closed while the verdict is unknown")
	end)

	helpers.it("recognises official ATSPI_ROLE_PASSWORD_TEXT value 40", function()
		local adapter = fresh(function() return 40, true end)
		local accepted, verdict = adapter.refresh()
		helpers.assert_eq(accepted, true, "a conclusive current role must publish")
		helpers.assert_eq(verdict, "secure", "role 40 is PASSWORD_TEXT")
		helpers.assert_eq(adapter.isSecureField(), true, "password text must be blocked")
	end)

	helpers.it("does not confuse table-column-header role 57 with a password", function()
		local adapter = fresh(function() return 57, true end)
		local accepted, verdict = adapter.refresh()
		helpers.assert_eq(accepted, true, "a valid non-password role is conclusive")
		helpers.assert_eq(verdict, "insecure", "role 57 is TABLE_COLUMN_HEADER")
		helpers.assert_eq(adapter.isSecureField(), false,
			"only a fresh conclusive ordinary role may reopen consumers")
	end)

	helpers.it("keeps missing bus, malformed, and timeout outcomes unknown", function()
		local outcomes = {
			{ nil, false, "missing bus" },
			{ nil, false, "native library unavailable" },
			{ "40", true, "malformed role type" },
		}
		for _, outcome in ipairs(outcomes) do
			local adapter = fresh(function() return outcome[1], outcome[2] end)
			local accepted = adapter.refresh()
			helpers.assert_eq(accepted, false, outcome[3] .. " must not publish")
			helpers.assert_eq(adapter.getVerdict(), "unknown",
				outcome[3] .. " must remain explicit unknown")
			helpers.assert_eq(adapter.isSecureField(), true,
				outcome[3] .. " must fail closed")
		end

		local adapter = fresh(function() error("simulated timeout") end)
		helpers.assert_eq(adapter.refresh(), false, "a timed-out/throwing backend must not escape")
		helpers.assert_eq(adapter.getVerdict(), "unknown", "timeout must remain unknown")
		helpers.assert_eq(adapter.isSecureField(), true, "timeout must fail closed")
	end)

	package.loaded["logger.shim"] = previous_logger
end)





-- =========================================
-- =========================================
-- ======= 2/ Focus Epochs =================
-- =========================================
-- =========================================

helpers.describe("SecureFieldDetector: focus epochs", function()
	local previous_logger = package.loaded["logger.shim"]
	package.loaded["logger.shim"] = helpers.make_logger_stub()

	helpers.it("invalidates immediately and rejects stale conclusive results", function()
		package.loaded["adapters.secure_field_detector"] = nil
		local adapter = helpers.load_module("adapters.secure_field_detector")
		adapter._set_probe_for_test(function() return 57, true end)
		helpers.assert_eq(adapter.refresh(), true, "initial ordinary field must publish")
		helpers.assert_eq(adapter.isSecureField(), false, "initial ordinary field is usable")

		local stale_epoch = adapter.invalidateFocus()
		helpers.assert_eq(adapter.getVerdict(), "unknown", "navigation invalidates synchronously")
		helpers.assert_eq(adapter.isSecureField(), true, "navigation closes privacy synchronously")
		local current_epoch = adapter.invalidateFocus()
		helpers.assert_eq(adapter.refresh(stale_epoch), false,
			"an old control's conclusive result must be discarded")
		helpers.assert_eq(adapter.getVerdict(), "unknown",
			"a stale ordinary-field answer cannot reopen the new control")
		helpers.assert_eq(adapter.refresh(current_epoch), true,
			"the current epoch may publish its fresh verdict")
		helpers.assert_eq(adapter.getVerdict(), "insecure",
			"fresh ordinary proof re-enables consumers")
	end)

	package.loaded["logger.shim"] = previous_logger
end)





-- =========================================
-- =========================================
-- ======= 3/ Secure Applications =========
-- =========================================
-- =========================================

helpers.describe("SecureFieldDetector: secure applications", function()
	local previous_logger = package.loaded["logger.shim"]
	package.loaded["logger.shim"] = helpers.make_logger_stub()
	package.loaded["adapters.secure_field_detector"] = nil
	local adapter = helpers.load_module("adapters.secure_field_detector")

	helpers.it("matches the canonical credential applications case-insensitively", function()
		local required = {
			"1password", "bitwarden", "keepassxc", "lastpass", "dashlane",
			"gnome-keyring-3", "seahorse", "gnome-authenticator",
			"authenticator", "yubikey-manager",
		}
		for _, app in ipairs(required) do
			helpers.assert_eq(adapter.isSecureApp(app:upper()), true,
				"missing canonical secure app: " .. app)
		end
	end)

	helpers.it("does not classify ordinary, empty, or absent app IDs as secure", function()
		helpers.assert_eq(adapter.isSecureApp("firefox"), false, "ordinary app")
		helpers.assert_eq(adapter.isSecureApp(""), false, "empty app")
		helpers.assert_eq(adapter.isSecureApp(nil), false, "absent app")
	end)

	helpers.it("keeps the boolean port and exposes tri-state epoch methods", function()
		for _, name in ipairs({
			"refresh", "isSecureField", "isSecureApp", "invalidateFocus",
			"getVerdict", "currentEpoch",
		}) do
			helpers.assert_eq(type(adapter[name]), "function", name .. " must be callable")
		end
	end)

	package.loaded["logger.shim"] = previous_logger
end)
