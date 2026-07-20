--- tests/unit/modules/keylogger/test_secure_app_guard_survives_ax.lua

--- ==============================================================================
--- MODULE: Regression — the known-vault guard must survive an AX focus change
--- DESCRIPTION:
--- CRITICAL privacy leak: keystrokes were logged inside a password manager.
---
--- is_secure_field is written from two places that did NOT agree on how it is
--- computed:
---   * handle_app_switch set it to the UNION of both axes —
---       SecureFieldDetector.isSecureField() or isSecureApp(app_name)
---   * update_secure_field_state, the AX AXFocusedUIElementChanged callback,
---     recomputed it from the AX role/subrole axis ALONE and then assigned
---     unconditionally on any difference.
---
--- So activating 1Password correctly suppressed logging via the app axis, and the
--- very next focus change inside that app — its search box, a note field, anything
--- not carrying AXSecureTextField — flipped the flag back to false and RESUMED
--- keystroke capture inside the vault. The flag also went false whenever focus was
--- lost entirely (the `not element` branch).
---
--- That defeats a defence the detector documents explicitly: its known-app list
--- exists as "a second line of defence" for "vault unlock screens rendered in
--- WebKit" that never expose a secure role. The AX axis returning false for those
--- screens is the NORMAL case, not an edge case, which is why the app axis exists.
---
--- WHY THIS TEST IS BEHAVIOURAL:
--- The defect is a disagreement between two assignment sites, invisible to any
--- single-site source grep. This drives the REAL update_ax_observer with a stubbed
--- AX tree whose focused element is a plain AXTextField, and asserts the flag the
--- keylogger actually gates on.
--- ==============================================================================

local helpers = require("tests.helpers")

-- A name present in SecureFieldDetector's SECURE_APP_IDS list.
local VAULT_APP = "1Password"

-- An app deliberately absent from that list.
local ORDINARY_APP = "TextEdit"

-- Predicate injected as the pause check; this suite never exercises pause.
local NOT_PAUSED = function() return false end





-- =============================================
-- =============================================
-- ======= 1/ Stubbed Accessibility Tree =======
-- =============================================
-- =============================================

--- Builds hs overrides whose focused element is a PLAIN text field — i.e. the AX
--- axis reports "not secure", which is exactly the vault-unlock-screen case.
--- @return table hs_overrides suitable for helpers.load_with_stubs.
local function make_plain_field_overrides()
	local fake_observer = {
		addWatcher    = function() end,
		removeWatcher = function() end,
		callback      = function() end,
		start         = function() end,
		stop          = function() end,
	}
	local plain_field = {
		attributeValue = function(_self, attr)
			if attr == "AXRole"    then return "AXTextField" end
			if attr == "AXSubrole" then return nil end
			if attr == "AXValue"   then return "" end
			return nil
		end,
	}
	local app_element = {
		attributeValue = function(_self, attr)
			if attr == "AXFocusedUIElement" then return plain_field end
			return nil
		end,
	}
	return {
		axuielement = {
			observer           = { new = function(_pid) return fake_observer end },
			applicationElement = function(_pid) return app_element end,
		},
	}
end

--- Loads a fresh context_tracker over a fresh state.
--- @param app_name string Value for _state.active_app_name.
--- @return table tracker, table core_state
local function load_tracker(app_name)
	package.loaded["modules.keylogger.context_tracker"] = nil
	local CT = helpers.load_with_stubs("modules.keylogger.context_tracker", make_plain_field_overrides())
	local core_state = { active_app_name = app_name }
	CT.init(core_state, {}, NOT_PAUSED)
	return CT, core_state
end





-- ==============================================
-- ==============================================
-- ======= 2/ The Guard Survives AX Focus =======
-- ==============================================
-- ==============================================

helpers.describe("known-vault suppression survives an AX focus change", function()
	helpers.it("stays suppressed when focus moves to a non-secure field inside a vault app", function()
		local CT, state = load_tracker(VAULT_APP)
		state.is_secure_field = true  -- as handle_app_switch left it on activation

		CT.update_ax_observer(4242)

		helpers.assert_true(state.is_secure_field == true,
			"focusing an ordinary AXTextField inside a known password manager must NOT resume "
			.. "logging — the known-app list is the documented second line of defence for vault "
			.. "screens that never expose AXSecureTextField")
	end)

	helpers.it("does NOT suppress in an ordinary app whose focused field is plain", function()
		-- The opposite failure: a guard that simply pins the flag to true would pass
		-- the case above while silently disabling metrics everywhere.
		local CT, state = load_tracker(ORDINARY_APP)
		state.is_secure_field = false

		CT.update_ax_observer(4242)

		helpers.assert_true(state.is_secure_field == false,
			"a plain text field in an ordinary app must remain unsuppressed, otherwise the "
			.. "fix would disable keystroke logging everywhere")
	end)
end)
