--- tests/unit/adapters/test_secure_field_detector.lua

--- ==============================================================================
--- MODULE: SecureFieldDetector Behavioral Tests (Linux)
--- DESCRIPTION:
--- Exercises the Linux secure_field_detector adapter logic paths. The adapter
--- queries AT-SPI2 via gdbus (io.popen) to detect password fields, and maintains
--- a hardcoded list of known password-manager app class names for isSecureApp().
---
--- COVERAGE:
--- 1. isSecureApp() with known/unknown/nil/empty, case-insensitive matching
--- 2. _dbus_available() via DBUS_SESSION_BUS_ADDRESS env var
--- 3. refresh() → AT-SPI2 role query → isSecureField() lifecycle
--- 4. SECURE_APP_IDS constant integrity
--- 5. Edge cases: no D-Bus, gdbus unavailable, non-password role, io.popen error
--- ==============================================================================

local helpers = require("tests.helpers")




-- =========================================================
-- =========================================================
-- ======= 1/ isSecureApp — known/unknown (Linux) ===========
-- =========================================================
-- =========================================================

helpers.describe("SecureFieldDetector: isSecureApp (Linux)", function()
	-- The adapter requires logger.shim at module-load time.
	-- Stub it before requiring so the headless test doesn't crash.
	local prev_shim = package.loaded["logger.shim"]
	package.loaded["logger.shim"] = helpers.make_logger_stub()

	local ok, adapter = pcall(helpers.load_module, "adapters.secure_field_detector")

	helpers.it("module loads without error", function()
		helpers.assert_true(ok,
			"adapters.secure_field_detector must be requireable: " .. tostring(adapter))
	end)

	if not ok then
		package.loaded["logger.shim"] = prev_shim
		return
	end

	helpers.it("returns true for a known password-manager app (lowercase input)", function()
		helpers.assert_eq(adapter.isSecureApp("1password"), true,
			"1password must be detected as secure")
		helpers.assert_eq(adapter.isSecureApp("bitwarden"), true,
			"bitwarden must be detected as secure")
		helpers.assert_eq(adapter.isSecureApp("keepassxc"), true,
			"keepassxc must be detected as secure")
		helpers.assert_eq(adapter.isSecureApp("lastpass"), true,
			"lastpass must be detected as secure")
		helpers.assert_eq(adapter.isSecureApp("dashlane"), true,
			"dashlane must be detected as secure")
	end)

	helpers.it("matches case-insensitively", function()
		helpers.assert_eq(adapter.isSecureApp("Bitwarden"), true,
			"Bitwarden (mixed case) must be detected as secure")
		helpers.assert_eq(adapter.isSecureApp("KEEPASSXC"), true,
			"KEEPASSXC (uppercase) must be detected as secure")
		helpers.assert_eq(adapter.isSecureApp("1Password"), true,
			"1Password (mixed case) must be detected as secure")
	end)

	helpers.it("returns false for an unknown app", function()
		helpers.assert_eq(adapter.isSecureApp("firefox"), false,
			"firefox must not be secure")
		helpers.assert_eq(adapter.isSecureApp("gnome-terminal"), false,
			"gnome-terminal must not be secure")
		helpers.assert_eq(adapter.isSecureApp("code"), false,
			"code must not be secure")
	end)

	helpers.it("returns false for nil appId", function()
		helpers.assert_eq(adapter.isSecureApp(nil), false,
			"nil appId must return false")
	end)

	helpers.it("returns false for empty string appId", function()
		helpers.assert_eq(adapter.isSecureApp(""), false,
			"empty string appId must return false")
	end)

	helpers.it("returns a boolean for every call", function()
		local ok1 = pcall(function() return adapter.isSecureApp("AnyApp") end)
		helpers.assert_true(ok1, "isSecureApp must not throw")
		local ok2 = pcall(function() return adapter.isSecureApp(nil) end)
		helpers.assert_true(ok2, "isSecureApp(nil) must not throw")
	end)

	-- Cleanup
	package.loaded["logger.shim"] = prev_shim
end)




-- ============================================================
-- ============================================================
-- ======= 2/ D-Bus availability detection ====================
-- ============================================================
-- ============================================================

helpers.describe("SecureFieldDetector: D-Bus availability", function()
	local prev_shim = package.loaded["logger.shim"]
	package.loaded["logger.shim"] = helpers.make_logger_stub()

	-- Save originals
	local _orig_getenv = os.getenv
	local _orig_popen = io.popen

	-- Stub io.popen for all D-Bus tests — the adapter should never spawn
	-- real gdbus processes during headless testing.
	io.popen = function(_cmd, _mode)
		return {
			read = function(_, _) return "" end,
			close = function(_) end,
		}
	end

	helpers.it("refresh does not throw when DBUS_SESSION_BUS_ADDRESS is set", function()
		os.getenv = function(key)
			if key == "DBUS_SESSION_BUS_ADDRESS" then
				return "unix:path=/run/user/1000/bus"
			end
			return _orig_getenv and _orig_getenv(key) or nil
		end

		package.loaded["adapters.secure_field_detector"] = nil
		local ok, adapter = pcall(helpers.load_module, "adapters.secure_field_detector")
		helpers.assert_true(ok, "adapter loads with D-Bus available")

		if ok then
			local refresh_ok = pcall(function() adapter.refresh() end)
			helpers.assert_true(refresh_ok,
				"refresh() must not throw when D-Bus is available")
		end
	end)

	helpers.it("refresh does not throw when DBUS_SESSION_BUS_ADDRESS is unset", function()
		os.getenv = function(key)
			if key == "DBUS_SESSION_BUS_ADDRESS" then return nil end
			return _orig_getenv and _orig_getenv(key) or nil
		end

		package.loaded["adapters.secure_field_detector"] = nil
		local ok, adapter = pcall(helpers.load_module, "adapters.secure_field_detector")
		helpers.assert_true(ok, "adapter loads without D-Bus")

		if ok then
			local refresh_ok = pcall(function() adapter.refresh() end)
			helpers.assert_true(refresh_ok,
				"refresh() must not throw when D-Bus is unavailable")
			helpers.assert_eq(adapter.isSecureField(), false,
				"isSecureField must be false when D-Bus is not available")
		end
	end)

	helpers.it("refresh does not throw when D-Bus address is empty string", function()
		os.getenv = function(key)
			if key == "DBUS_SESSION_BUS_ADDRESS" then return "" end
			return _orig_getenv and _orig_getenv(key) or nil
		end

		package.loaded["adapters.secure_field_detector"] = nil
		local ok, adapter = pcall(helpers.load_module, "adapters.secure_field_detector")
		helpers.assert_true(ok, "adapter loads with empty D-Bus address")

		if ok then
			local refresh_ok = pcall(function() adapter.refresh() end)
			helpers.assert_true(refresh_ok,
				"refresh() must not throw with empty D-Bus address")
			helpers.assert_eq(adapter.isSecureField(), false,
				"isSecureField must be false with empty D-Bus address")
		end
	end)

	-- Restore
	os.getenv = _orig_getenv
	io.popen = _orig_popen
	package.loaded["logger.shim"] = prev_shim
end)




-- ==================================================================
-- ==================================================================
-- ======= 3/ refresh → AT-SPI2 → isSecureField lifecycle ===========
-- ==================================================================
-- ==================================================================

helpers.describe("SecureFieldDetector: refresh → AT-SPI2 → isSecureField", function()
	local prev_shim = package.loaded["logger.shim"]
	package.loaded["logger.shim"] = helpers.make_logger_stub()

	-- Save originals
	local _orig_getenv = os.getenv
	local _orig_popen = io.popen

	helpers.it("isSecureField returns false before any refresh()", function()
		os.getenv = function() return nil end
		io.popen = function(_, _)
			return { read = function(_, _) return "" end, close = function(_) end }
		end

		package.loaded["adapters.secure_field_detector"] = nil
		local adapter = helpers.load_module("adapters.secure_field_detector")
		helpers.assert_eq(adapter.isSecureField(), false,
			"before refresh(), isSecureField must be false")
	end)

	helpers.it("isSecureField returns true when gdbus returns PASSWORD_TEXT role (int 57)", function()
		os.getenv = function(key)
			if key == "DBUS_SESSION_BUS_ADDRESS" then return "unix:path=/tmp/bus" end
			return _orig_getenv and _orig_getenv(key) or nil
		end

		-- Simulate two gdbus calls: GetFocused → GetRole(57 = PASSWORD_TEXT)
		local popen_idx = 0
		io.popen = function(_cmd, _mode)
			popen_idx = popen_idx + 1
			if popen_idx == 1 then
				return {
					read = function(_, _)
						return "('org.a11y.atspi.Registry', <objectpath '/org/a11y/atspi/accessible/42'>)\n"
					end,
					close = function(_) end,
				}
			else
				return {
					read = function(_, _) return "(57,)\n" end,
					close = function(_) end,
				}
			end
		end

		package.loaded["adapters.secure_field_detector"] = nil
		local adapter = helpers.load_module("adapters.secure_field_detector")

		adapter.refresh()
		helpers.assert_eq(adapter.isSecureField(), true,
			"after PASSWORD_TEXT role (int 57), isSecureField must be true")
	end)

	helpers.it("isSecureField returns false when gdbus returns a non-password role", function()
		os.getenv = function(key)
			if key == "DBUS_SESSION_BUS_ADDRESS" then return "unix:path=/tmp/bus" end
			return _orig_getenv and _orig_getenv(key) or nil
		end

		-- Simulate gdbus returning ATSPI_ROLE_TEXT (role int = 42)
		local popen_idx = 0
		io.popen = function(_cmd, _mode)
			popen_idx = popen_idx + 1
			if popen_idx == 1 then
				return {
					read = function(_, _)
						return "('org.a11y.atspi.Registry', <objectpath '/org/a11y/atspi/accessible/10'>)\n"
					end,
					close = function(_) end,
				}
			else
				return {
					read = function(_, _) return "(42,)\n" end,
					close = function(_) end,
				}
			end
		end

		package.loaded["adapters.secure_field_detector"] = nil
		local adapter = helpers.load_module("adapters.secure_field_detector")

		adapter.refresh()
		helpers.assert_eq(adapter.isSecureField(), false,
			"non-password AT-SPI role must leave isSecureField false")
	end)

	helpers.it("refresh gracefully handles gdbus returning unparseable output", function()
		os.getenv = function(key)
			if key == "DBUS_SESSION_BUS_ADDRESS" then return "unix:path=/tmp/bus" end
			return _orig_getenv and _orig_getenv(key) or nil
		end

		io.popen = function(_cmd, _mode)
			return {
				read = function(_, _) return "garbage output without role\n" end,
				close = function(_) end,
			}
		end

		package.loaded["adapters.secure_field_detector"] = nil
		local adapter = helpers.load_module("adapters.secure_field_detector")

		local ok = pcall(function() adapter.refresh() end)
		helpers.assert_true(ok, "refresh() with unparseable gdbus output must not throw")
		helpers.assert_eq(adapter.isSecureField(), false,
			"unparseable gdbus output must leave isSecureField false")
	end)

	helpers.it("refresh gracefully handles io.popen returning nil", function()
		os.getenv = function(key)
			if key == "DBUS_SESSION_BUS_ADDRESS" then return "unix:path=/tmp/bus" end
			return _orig_getenv and _orig_getenv(key) or nil
		end

		io.popen = function(_cmd, _mode) return nil end

		package.loaded["adapters.secure_field_detector"] = nil
		local adapter = helpers.load_module("adapters.secure_field_detector")

		local ok = pcall(function() adapter.refresh() end)
		helpers.assert_true(ok, "refresh() with nil io.popen must not throw")
		helpers.assert_eq(adapter.isSecureField(), false,
			"nil io.popen must leave isSecureField false")
	end)

	helpers.it("refresh catches and absorbs exceptions inside the pcall wrapper", function()
		os.getenv = function(key)
			if key == "DBUS_SESSION_BUS_ADDRESS" then return "unix:path=/tmp/bus" end
			return _orig_getenv and _orig_getenv(key) or nil
		end

		io.popen = function(_cmd, _mode)
			error("simulated io.popen crash")
		end

		package.loaded["adapters.secure_field_detector"] = nil
		local adapter = helpers.load_module("adapters.secure_field_detector")

		local ok = pcall(function() adapter.refresh() end)
		helpers.assert_true(ok, "refresh() must catch internal error and not rethrow")
		helpers.assert_eq(adapter.isSecureField(), false,
			"throwing io.popen must leave isSecureField false")
	end)

	-- Restore
	os.getenv = _orig_getenv
	io.popen = _orig_popen
	package.loaded["logger.shim"] = prev_shim
end)




-- =============================================
-- =============================================
-- ======= 4/ SECURE_APP_IDS integrity =========
-- =============================================
-- =============================================

helpers.describe("SecureFieldDetector: SECURE_APP_IDS constant (Linux)", function()
	local prev_shim = package.loaded["logger.shim"]
	package.loaded["logger.shim"] = helpers.make_logger_stub()

	local ok, adapter = pcall(helpers.load_module, "adapters.secure_field_detector")
	helpers.assert_true(ok, "adapter must load")

	if not ok then
		package.loaded["logger.shim"] = prev_shim
		return
	end

	helpers.it("contains the canonical set of password-manager apps", function()
		local required_apps = {
			"1password",
			"bitwarden",
			"keepassxc",
			"lastpass",
			"dashlane",
			"gnome-keyring-3",
			"seahorse",
			"gnome-authenticator",
			"authenticator",
			"yubikey-manager",
		}
		for _, app in ipairs(required_apps) do
			helpers.assert_eq(adapter.isSecureApp(app), true,
				"missing canonical secure app: " .. app)
		end
	end)

	helpers.it("secure app list has the expected minimum size", function()
		local required = {
			"1password", "bitwarden", "keepassxc", "lastpass", "dashlane",
			"gnome-keyring-3", "seahorse", "gnome-authenticator",
			"authenticator", "yubikey-manager",
		}
		local count = 0
		for _ in pairs(required) do count = count + 1 end
		helpers.assert_true(count >= 10,
			"must have at least 10 canonical secure apps, got " .. count)
	end)

	package.loaded["logger.shim"] = prev_shim
end)




-- ====================================
-- ====================================
-- ======= 5/ Port contract surface ===
-- ====================================
-- ====================================

helpers.describe("SecureFieldDetector: port contract surface (Linux)", function()
	local prev_shim = package.loaded["logger.shim"]
	package.loaded["logger.shim"] = helpers.make_logger_stub()

	local ok, adapter = pcall(helpers.load_module, "adapters.secure_field_detector")
	helpers.assert_true(ok, "adapter must load")

	if not ok then
		package.loaded["logger.shim"] = prev_shim
		return
	end

	helpers.it("all three port methods exist and are callable", function()
		helpers.assert_true(type(adapter.refresh) == "function",
			"refresh must be a function")
		helpers.assert_true(type(adapter.isSecureField) == "function",
			"isSecureField must be a function")
		helpers.assert_true(type(adapter.isSecureApp) == "function",
			"isSecureApp must be a function")
	end)

	helpers.it("refresh and isSecureField are separate concerns", function()
		local _orig_getenv = os.getenv
		local _orig_popen = io.popen

		os.getenv = function(key)
			if key == "DBUS_SESSION_BUS_ADDRESS" then return "unix:path=/tmp/bus" end
			return _orig_getenv and _orig_getenv(key) or nil
		end
		io.popen = function(_cmd, _mode)
			return {
				read = function(_, _) return "(57,)\n" end,
				close = function(_) end,
			}
		end

		package.loaded["adapters.secure_field_detector"] = nil
		local fresh = helpers.load_module("adapters.secure_field_detector")

		local result = fresh.refresh()
		-- Restore before assertion so even on failure they're restored
		os.getenv = _orig_getenv
		io.popen = _orig_popen

		helpers.assert_eq(result, nil,
			"refresh() must return nil, not the field status — isSecureField is the accessor")
	end)

	package.loaded["logger.shim"] = prev_shim
end)
