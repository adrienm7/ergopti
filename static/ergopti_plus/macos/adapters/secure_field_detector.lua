--- adapters/secure_field_detector.lua

--- ==============================================================================
--- MODULE: SecureFieldDetector Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the SecureFieldDetector port contract defined in
--- static/ergopti_plus/_shared/ports/SecureFieldDetector.spec.js. Wraps hs.axuielement
--- and a hardcoded list of known password-manager app names to detect whether the
--- user is currently focused on a secure text field or a security-sensitive app.
---
--- FEATURES & RATIONALE:
--- 1. AX role detection: macOS exposes AXSecureTextField for password inputs via
---    the Accessibility API; this is the most reliable signal available without
---    reading the actual field content.
--- 2. Known-app guard: some security apps never expose a secure role (e.g. vault
---    unlock screens rendered in WebKit); the hardcoded list provides a second
---    line of defence for those cases.
--- 3. Fail-safe returns: every public method returns a safe default (false) on
---    any error so the caller can always treat the result as a plain boolean.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")

local LOG = "adapters.secure_field_detector"




-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

-- Apps whose entire surface is considered sensitive regardless of AX role
local SECURE_APP_IDS = {
	["1Password 7 - Password Manager"] = true,
	["1Password"]                       = true,
	["Keychain Access"]                 = true,
	["Bitwarden"]                       = true,
	["LastPass"]                        = true,
	["Dashlane"]                        = true,
	["KeePassXC"]                       = true,
	["Authy Desktop"]                   = true,
	["Google Authenticator"]            = true,
	["Touch ID & Password"]             = true,
}




-- =================================
-- =================================
-- ======= 2/ Internal State =======
-- =================================
-- =================================

-- Cached AXRole of the focused element, populated by refresh()
local _cached_role = nil




-- ==================================
-- ==================================
-- ======= 3/ Adapter Methods =======
-- ==================================
-- ==================================

--- Re-reads the focused element via hs.axuielement and caches its AXRole and AXSubrole.
--- Uses applicationElementForPID + AXFocusedUIElement — the only stable HS API for this.
--- hs.axuielement.focusedElement() does not exist in Hammerspoon; accessing the focused
--- element requires going through the application's accessibility tree (H2 audit fix).
--- Errors are silently ignored; _cached_role is set to nil on failure.
function M.refresh()
	local ok, err = pcall(function()
		if not (hs.axuielement and hs.axuielement.applicationElementForPID) then
			_cached_role = nil
			return
		end

		local app = hs.application.frontmostApplication()
		if not app then _cached_role = nil; return end

		local pid    = app:pid()
		local app_el = hs.axuielement.applicationElementForPID(pid)
		if not app_el then _cached_role = nil; return end

		local focused = app_el:attributeValue("AXFocusedUIElement")
		if focused then
			_cached_role = focused:attributeValue("AXRole")
		else
			_cached_role = nil
		end
	end)

	if not ok then
		Logger.debug(LOG, "refresh(): axuielement unavailable — %s", tostring(err))
		_cached_role = nil
	end
end

--- Returns true if the currently focused element is a secure text field.
--- @return boolean True when the cached AXRole is "AXSecureTextField".
function M.isSecureField()
	return _cached_role == "AXSecureTextField"
end

--- Returns true if the given app ID belongs to a known security-sensitive app.
--- @param appId string|nil The application name to check.
--- @return boolean True when appId is in the SECURE_APP_IDS list.
function M.isSecureApp(appId)
	if appId == nil or appId == "" then return false end
	local key = tostring(appId)
	return SECURE_APP_IDS[key] == true
end

return M
