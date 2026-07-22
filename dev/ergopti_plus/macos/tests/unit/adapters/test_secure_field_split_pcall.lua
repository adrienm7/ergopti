--- tests/unit/adapters/test_secure_field_split_pcall.lua

--- ==============================================================================
--- MODULE: Regression — a throwing AXSubrole read must not discard a secure AXRole
--- DESCRIPTION:
--- Privacy leak that FAILS OPEN, which this module's own docstring names as the
--- disaster mode: "letting the keylogger record the user's password characters".
---
--- ROOT CAUSE ENCODED:
--- refresh() read both AX attributes inside ONE pcall:
---   _cached_role    = focused:attributeValue("AXRole")      -- may be AXSecureTextField
---   _cached_subrole = focused:attributeValue("AXSubrole")   -- may THROW
--- Lua's pcall abandons the whole closure on the first error, so a throw on the
--- SECOND read sent control to the error handler, which calls clear_cache() and
--- nils BOTH cached attributes — including the correct "AXSecureTextField" stored
--- one line earlier. isSecureField() then returned false for a field that IS a
--- password field.
---
--- AX reads throw routinely: the element can die or be replaced between the two
--- calls. keylogger/context_tracker.lua already reads these same two attributes
--- with SEPARATE pcalls for exactly this reason — this adapter was the sibling
--- that did not.
---
--- The test drives the real M.refresh() with an element whose AXRole reports a
--- secure field and whose AXSubrole raises, then asserts the public predicate the
--- keylogger actually gates on.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The marker both UI toolkits use, on whichever attribute they choose.
local SECURE_ROLE = "AXSecureTextField"




-- ==============================================
-- ==============================================
-- ======= 1/ Accessibility Tree Doubles ========
-- ==============================================
-- ==============================================

--- Builds hs overrides whose focused element answers `role` for AXRole and either
--- answers or RAISES for AXSubrole.
--- @param role string|nil Value returned for AXRole.
--- @param subrole_throws boolean When true, reading AXSubrole raises.
--- @param subrole string|nil Value returned for AXSubrole when it does not raise.
--- @return table hs_overrides for helpers.load_with_stubs.
local function make_overrides(role, subrole_throws, subrole)
	local focused = {
		attributeValue = function(_self, attr)
			if attr == "AXRole" then return role end
			if attr == "AXSubrole" then
				if subrole_throws then error("simulated AX failure reading AXSubrole") end
				return subrole
			end
			return nil
		end,
	}
	local app_el = {
		attributeValue = function(_self, attr)
			if attr == "AXFocusedUIElement" then return focused end
			return nil
		end,
	}
	return {
		application = {
			frontmostApplication = function()
				return { pid = function() return 4242 end, title = function() return "Safari" end }
			end,
		},
		axuielement = {
			applicationElementForPID = function(_pid) return app_el end,
			applicationElement       = function(_pid) return app_el end,
		},
	}
end

--- Loads a fresh detector over the supplied AX tree.
--- @return table The detector module.
local function load_detector(role, subrole_throws, subrole)
	package.loaded["adapters.secure_field_detector"] = nil
	return helpers.load_with_stubs("adapters.secure_field_detector",
		make_overrides(role, subrole_throws, subrole))
end




-- ===============================================
-- ===============================================
-- ======= 2/ The Secure Verdict Survives ========
-- ===============================================
-- ===============================================

helpers.describe("secure-field detection survives a throwing AX attribute read", function()
	helpers.it("keeps a secure AXRole when the AXSubrole read raises", function()
		local Detector = load_detector(SECURE_ROLE, true, nil)

		Detector.refresh()

		helpers.assert_true(Detector.isSecureField() == true,
			"a successful AXRole = AXSecureTextField must survive a throw on the following "
			.. "AXSubrole read — sharing one pcall discarded it and made the guard fail OPEN, "
			.. "which is what lets the keylogger record password characters")
	end)

	helpers.it("keeps a secure AXSubrole when the AXRole read raises is not applicable, but a plain role still reports false", function()
		-- Negative control: an ordinary field must NOT be reported secure, so a fix
		-- that simply latched the verdict on would fail here.
		local Detector = load_detector("AXTextField", false, nil)

		Detector.refresh()

		helpers.assert_true(Detector.isSecureField() == false,
			"an ordinary AXTextField with no secure subrole must not be reported as secure")
	end)

	helpers.it("still detects the WebKit shape where only AXSubrole carries the marker", function()
		-- The case the two-attribute read exists for: Chrome/Edge/Brave report
		-- AXRole = AXTextField and demote the marker to AXSubrole.
		local Detector = load_detector("AXTextField", false, SECURE_ROLE)

		Detector.refresh()

		helpers.assert_true(Detector.isSecureField() == true,
			"a WebKit/Blink login field carries the marker on AXSubrole and must be detected")
	end)
end)
