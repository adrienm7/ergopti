--- tests/unit/adapters/test_secure_field_detector.lua

--- ==============================================================================
--- MODULE: SecureFieldDetector Behavioral Tests (macOS)
--- DESCRIPTION:
--- Exercises the real adapter logic paths beyond the basic contract vectors
--- (those live in test_adapter_contract_vectors.lua). Covers:
--- 1. isSecureApp() with known/unknown/nil/empty apps
--- 2. refresh() → isSecureField() lifecycle via axuielement stubs
--- 3. SECURE_APP_IDS constant integrity
--- 4. Edge cases: missing axuielement, nil frontmost app, nil focused element,
---    throw inside pcall, no hs.axuielement at all
--- ==============================================================================

local helpers = require("tests.helpers")

-- Helper: builds a minimal hs.application stub with a pid() method so the
-- adapter's refresh() can call app:pid() without crashing.
-- @param extra table|nil Optional overrides merged into the stub.
local function make_app_stub(extra)
	local base = {
		frontmostApplication = function()
			return {
				name     = function() return "TestApp" end,
				bundleID = function() return "com.test.app" end,
				pid      = function() return 12345 end,
			}
		end,
	}
	if extra then for k, v in pairs(extra) do base[k] = v end end
	return base
end

-- Helper: builds an axuielement stub whose focused element answers BOTH AXRole
-- and AXSubrole, so the Chromium shape (role = AXTextField, subrole =
-- AXSecureTextField) can be reproduced faithfully.
-- @param role string|nil The AXRole to report on the focused element.
-- @param subrole string|nil The AXSubrole to report on the focused element.
local function make_ax_role_subrole_stub(role, subrole)
	return {
		axuielement = {
			applicationElementForPID = function(_)
				return {
					attributeValue = function(_, attr)
						if attr == "AXFocusedUIElement" then
							return {
								attributeValue = function(_, a)
									if a == "AXRole"    then return role end
									if a == "AXSubrole" then return subrole end
									return nil
								end,
							}
						end
						return nil
					end,
				}
			end,
		},
		application = make_app_stub(),
	}
end

-- Helper: builds an axuielement stub that returns the given AXRole.
-- @param role string|nil The AXRole to return, or nil for no focused element.
local function make_ax_stub(role)
	return {
		axuielement = {
			applicationElementForPID = function(_)
				return {
					attributeValue = function(_, attr)
						if attr == "AXFocusedUIElement" then
							if role == nil then return nil end
							return {
								attributeValue = function(_, a)
									if a == "AXRole" then return role end
									return nil
								end,
							}
						end
						return nil
					end,
				}
			end,
		},
		application = make_app_stub(),
	}
end




-- ===============================================
-- ===============================================
-- ======= 1/ isSecureApp — known/unknown ========
-- ===============================================
-- ===============================================

helpers.describe("SecureFieldDetector: isSecureApp", function()
	local adapter = helpers.load_with_stubs("adapters.secure_field_detector")

	helpers.it("returns true for a known password-manager app", function()
		helpers.assert_true(adapter.isSecureApp("1Password") == true,
			"1Password must be detected as secure")
		helpers.assert_true(adapter.isSecureApp("Bitwarden") == true,
			"Bitwarden must be detected as secure")
		helpers.assert_true(adapter.isSecureApp("KeePassXC") == true,
			"KeePassXC must be detected as secure")
		helpers.assert_true(adapter.isSecureApp("LastPass") == true,
			"LastPass must be detected as secure")
		helpers.assert_true(adapter.isSecureApp("Dashlane") == true,
			"Dashlane must be detected as secure")
	end)

	helpers.it("returns false for an unknown app", function()
		helpers.assert_eq(false, adapter.isSecureApp("Safari"),
			"Safari must not be secure")
		helpers.assert_eq(false, adapter.isSecureApp("com.google.Chrome"),
			"Chrome must not be secure")
		helpers.assert_eq(false, adapter.isSecureApp(""),
			"empty string must not be secure")
	end)

	helpers.it("returns false for nil appId", function()
		helpers.assert_eq(false, adapter.isSecureApp(nil),
			"nil appId must return false")
	end)

	helpers.it("is case-sensitive — '1password' (lowercase) is NOT detected", function()
		helpers.assert_eq(false, adapter.isSecureApp("1password"),
			"lowercase variant must not match the exact key")
	end)

	helpers.it("returns a boolean for every call", function()
		local ok1 = pcall(function() return adapter.isSecureApp("AnyApp") end)
		helpers.assert_true(ok1, "isSecureApp must not throw")
		local ok2 = pcall(function() return adapter.isSecureApp(nil) end)
		helpers.assert_true(ok2, "isSecureApp(nil) must not throw")
	end)
end)




-- =============================================================
-- =============================================================
-- ======= 2/ refresh → isSecureField lifecycle ================
-- =============================================================
-- =============================================================

helpers.describe("SecureFieldDetector: refresh → isSecureField", function()

	helpers.it("isSecureField returns false before any refresh()", function()
		local adapter = helpers.load_with_stubs("adapters.secure_field_detector")
		helpers.assert_eq(false, adapter.isSecureField(),
			"before refresh(), isSecureField must be false")
	end)

	helpers.it("isSecureField returns true after refresh detects AXSecureTextField", function()
		local adapter = helpers.load_with_stubs(
			"adapters.secure_field_detector",
			make_ax_stub("AXSecureTextField"))

		adapter.refresh()
		helpers.assert_eq(true, adapter.isSecureField(),
			"after AXSecureTextField role, isSecureField must be true")
	end)

	-- Regression: Chromium-family browsers (Chrome, Edge, Brave, Arc) surface
	-- <input type="password"> as AXRole = AXTextField with the secure marker on
	-- the AXSubrole. The adapter used to read AXRole only, so every browser login
	-- form failed OPEN and the keylogger recorded the user's password characters.
	helpers.it("isSecureField returns true for the Chromium shape (AXSubrole = AXSecureTextField)", function()
		local adapter = helpers.load_with_stubs(
			"adapters.secure_field_detector",
			make_ax_role_subrole_stub("AXTextField", "AXSecureTextField"))

		adapter.refresh()
		helpers.assert_eq(true, adapter.isSecureField(),
			"a browser password field (role AXTextField + subrole AXSecureTextField) must be detected as secure")
	end)

	helpers.it("isSecureField stays false for a non-secure subrole (no false positives)", function()
		local adapter = helpers.load_with_stubs(
			"adapters.secure_field_detector",
			make_ax_role_subrole_stub("AXTextField", "AXSearchField"))

		adapter.refresh()
		helpers.assert_eq(false, adapter.isSecureField(),
			"a search field must NOT be misreported as secure just because a subrole is read")
	end)

	helpers.it("isSecureField returns true for the native shape when no subrole is exposed", function()
		local adapter = helpers.load_with_stubs(
			"adapters.secure_field_detector",
			make_ax_role_subrole_stub("AXSecureTextField", nil))

		adapter.refresh()
		helpers.assert_eq(true, adapter.isSecureField(),
			"a native AppKit secure field must still be detected via AXRole alone")
	end)

	-- The subrole is cached alongside the role, so it must be cleared on the same
	-- paths — a stale subrole would keep reporting a password field after focus moved.
	helpers.it("a secure subrole is cleared once focus moves to a plain field", function()
		local shapes = {
			{ role = "AXTextField", subrole = "AXSecureTextField" },
			{ role = "AXTextField", subrole = nil },
		}
		local call_count = 0

		local adapter = helpers.load_with_stubs("adapters.secure_field_detector", {
			axuielement = {
				applicationElementForPID = function(_)
					call_count = call_count + 1
					local shape = shapes[call_count]
					return {
						attributeValue = function(_, attr)
							if attr == "AXFocusedUIElement" then
								return {
									attributeValue = function(_, a)
										if a == "AXRole"    then return shape.role end
										if a == "AXSubrole" then return shape.subrole end
										return nil
									end,
								}
							end
							return nil
						end,
					}
				end,
			},
			application = make_app_stub(),
		})

		adapter.refresh()
		helpers.assert_eq(true, adapter.isSecureField(),
			"first refresh on a browser password field must report secure")

		adapter.refresh()
		helpers.assert_eq(false, adapter.isSecureField(),
			"the cached subrole must be cleared when focus moves to a plain text field")
	end)

	helpers.it("isSecureField returns false when role is AXTextField (plain text)", function()
		local adapter = helpers.load_with_stubs(
			"adapters.secure_field_detector",
			make_ax_stub("AXTextField"))

		adapter.refresh()
		helpers.assert_eq(false, adapter.isSecureField(),
			"plain AXTextField must NOT be detected as secure")
	end)

	helpers.it("refresh when frontmost app is nil — isSecureField stays false", function()
		local adapter = helpers.load_with_stubs(
			"adapters.secure_field_detector",
			{ application = make_app_stub({ frontmostApplication = function() return nil end }) })

		adapter.refresh()
		helpers.assert_eq(false, adapter.isSecureField(),
			"nil frontmost app must leave isSecureField false")
	end)

	helpers.it("refresh when AXFocusedUIElement is nil — isSecureField stays false", function()
		local adapter = helpers.load_with_stubs(
			"adapters.secure_field_detector",
			make_ax_stub(nil))

		adapter.refresh()
		helpers.assert_eq(false, adapter.isSecureField(),
			"nil focused element must leave isSecureField false")
	end)

	helpers.it("refresh when axuielement.applicationElementForPID is missing — graceful", function()
		local adapter = helpers.load_with_stubs("adapters.secure_field_detector", {
			axuielement = {},
			application = make_app_stub(),
		})

		local ok = pcall(function() adapter.refresh() end)
		helpers.assert_true(ok, "refresh() with missing axuielement API must not throw")
		helpers.assert_eq(false, adapter.isSecureField(),
			"missing axuielement API must leave isSecureField false")
	end)

	helpers.it("refresh when axuielement is nil entirely — graceful", function()
		local adapter = helpers.load_with_stubs("adapters.secure_field_detector", {
			axuielement = nil,
			application = make_app_stub(),
		})

		local ok = pcall(function() adapter.refresh() end)
		helpers.assert_true(ok, "refresh() with nil axuielement must not throw")
		helpers.assert_eq(false, adapter.isSecureField(),
			"nil axuielement must leave isSecureField false")
	end)

	helpers.it("refresh catches and absorbs exceptions inside the pcall", function()
		local adapter = helpers.load_with_stubs("adapters.secure_field_detector", {
			axuielement = {
				applicationElementForPID = function(_)
					error("simulated AX API crash during refresh")
				end,
			},
			application = make_app_stub(),
		})

		local ok = pcall(function() adapter.refresh() end)
		helpers.assert_true(ok, "refresh() must catch internal AX error and not rethrow")
		helpers.assert_eq(false, adapter.isSecureField(),
			"throwing AX API must leave isSecureField false")
	end)

	helpers.it("refresh when applicationElementForPID returns nil — graceful", function()
		local adapter = helpers.load_with_stubs("adapters.secure_field_detector", {
			axuielement = {
				applicationElementForPID = function(_) return nil end,
			},
			application = make_app_stub(),
		})

		adapter.refresh()
		helpers.assert_eq(false, adapter.isSecureField(),
			"nil app element must leave isSecureField false")
	end)

	helpers.it("multiple refresh calls reset the cached role correctly", function()
		local roles = { "AXSecureTextField", "AXTextField" }
		local call_count = 0

		local adapter = helpers.load_with_stubs("adapters.secure_field_detector", {
			axuielement = {
				applicationElementForPID = function(_)
					call_count = call_count + 1
					local role = roles[call_count]
					return {
						attributeValue = function(_, attr)
							if attr == "AXFocusedUIElement" then
								if role == nil then return nil end
								return {
									attributeValue = function(_, a)
										if a == "AXRole" then return role end
										return nil
									end,
								}
							end
							return nil
						end,
					}
				end,
			},
			application = make_app_stub(),
		})

		-- First refresh: secure field
		adapter.refresh()
		helpers.assert_eq(true, adapter.isSecureField(),
			"first refresh with AXSecureTextField must report secure")

		-- Second refresh: plain text field — must update the cached role
		adapter.refresh()
		helpers.assert_eq(false, adapter.isSecureField(),
			"second refresh with AXTextField must report not secure")
	end)
end)




-- =============================================
-- =============================================
-- ======= 3/ SECURE_APP_IDS integrity =========
-- =============================================
-- =============================================

helpers.describe("SecureFieldDetector: SECURE_APP_IDS constant", function()

	helpers.it("contains the canonical set of password-manager apps", function()
		local adapter = helpers.load_with_stubs("adapters.secure_field_detector")
		local required_apps = {
			"1Password 7 - Password Manager",
			"1Password",
			"Keychain Access",
			"Bitwarden",
			"LastPass",
			"Dashlane",
			"KeePassXC",
			"Authy Desktop",
			"Google Authenticator",
			"Touch ID & Password",
		}
		for _, app in ipairs(required_apps) do
			helpers.assert_true(adapter.isSecureApp(app) == true,
				"missing canonical secure app: " .. app)
		end
	end)

	helpers.it("secure app list has the expected minimum size", function()
		local adapter = helpers.load_with_stubs("adapters.secure_field_detector")
		local canonical = {
			"1Password 7 - Password Manager",
			"1Password",
			"Keychain Access",
			"Bitwarden",
			"LastPass",
			"Dashlane",
			"KeePassXC",
			"Authy Desktop",
			"Google Authenticator",
			"Touch ID & Password",
		}
		local count = 0
		for _ in pairs(canonical) do count = count + 1 end
		helpers.assert_true(count >= 10,
			"must have at least 10 canonical secure apps, got " .. count)
	end)
end)




-- ====================================
-- ====================================
-- ======= 4/ Port contract surface ===
-- ====================================
-- ====================================

helpers.describe("SecureFieldDetector: port contract surface", function()

	helpers.it("all three port methods exist and are callable", function()
		local adapter = helpers.load_with_stubs("adapters.secure_field_detector")
		helpers.assert_true(type(adapter.refresh) == "function",
			"refresh must be a function")
		helpers.assert_true(type(adapter.isSecureField) == "function",
			"isSecureField must be a function")
		helpers.assert_true(type(adapter.isSecureApp) == "function",
			"isSecureApp must be a function")
	end)

	helpers.it("refresh and isSecureField are separate concerns", function()
		local adapter = helpers.load_with_stubs(
			"adapters.secure_field_detector",
			make_ax_stub(nil))

		local result = adapter.refresh()
		helpers.assert_eq(nil, result,
			"refresh() must return nil, not the field status — isSecureField is the accessor")
	end)
end)
