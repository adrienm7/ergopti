--- adapters/secure_field_detector.lua

--- ==============================================================================
--- MODULE: SecureFieldDetector Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the SecureFieldDetector port contract defined in
--- static/ergopti_plus/_shared/core/ports/SecureFieldDetector.spec.js. Wraps hs.axuielement
--- and a hardcoded list of known password-manager app names to detect whether the
--- user is currently focused on a secure text field or a security-sensitive app.
---
--- FEATURES & RATIONALE:
--- 1. AX role detection: macOS exposes AXSecureTextField for password inputs via
---    the Accessibility API; this is the most reliable signal available without
---    reading the actual field content. Both AXRole and AXSubrole are consulted
---    because native AppKit controls carry the marker on the role while
---    WebKit/Blink browsers carry it on the subrole of a plain AXTextField.
--- 2. Known-app guard: some security apps never expose a secure role (e.g. vault
---    unlock screens rendered in WebKit); the hardcoded list provides a second
---    line of defence for those cases.
--- 3. Fail-safe returns: an incomplete AX classification is treated as secure so
---    neither local metrics nor LLM requests can capture credentials while a
---    browser replaces its focused element.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("infra.logger")

local LOG = "adapters.secure_field_detector"





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

-- The AX value that marks a password input. Native AppKit controls expose it as
-- the element's AXRole, while WebKit/Blink expose it as the AXSubrole of a plain
-- AXTextField — so both attributes must be tested (see M.isSecureField).
local SECURE_ROLE = "AXSecureTextField"

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

-- Cached secure-field verdict for the focused element, populated by refresh().
local _cached_secure = false





-- ==================================
-- ==================================
-- ======= 3/ Adapter Methods =======
-- ==================================
-- ==================================

--- Classifies one focused accessibility element.
--- AXRole and AXSubrole are one privacy decision: WebKit/Blink expose the secure
--- marker only through AXSubrole, so either read failing leaves the classification
--- uncertain and must fail closed.
--- @param element userdata|table|nil Focused accessibility element.
--- @return boolean True for a secure or incompletely classified element.
function M.isElementSecure(element)
	if not element then return false end
	local ok_role, role    = pcall(function() return element:attributeValue("AXRole") end)
	local ok_sub,  subrole = pcall(function() return element:attributeValue("AXSubrole") end)
	if (ok_role and role == SECURE_ROLE) or (ok_sub and subrole == SECURE_ROLE) then
		return true
	end
	if not ok_role or not ok_sub then
		Logger.debug(LOG,
			"AX secure-field classification incomplete (role_read=%s, subrole_read=%s); suppressing input.",
			tostring(ok_role), tostring(ok_sub))
		return true
	end
	return false
end

--- Re-reads the focused element and caches its secure-field verdict.
--- Uses applicationElementForPID + AXFocusedUIElement, the stable Hammerspoon API
--- for reaching the focused accessibility element.
function M.refresh()
	local function clear_cache()
		_cached_secure = false
	end

	local ok, err = pcall(function()
		if not (hs.axuielement and hs.axuielement.applicationElementForPID) then
			clear_cache()
			return
		end

		local app = hs.application.frontmostApplication()
		if not app then clear_cache(); return end

		local pid    = app:pid()
		local app_el = hs.axuielement.applicationElementForPID(pid)
		if not app_el then clear_cache(); return end

		local focused = app_el:attributeValue("AXFocusedUIElement")
		if focused then
			_cached_secure = M.isElementSecure(focused)
		else
			clear_cache()
		end
	end)

	if not ok then
		Logger.debug(LOG, "refresh(): axuielement unavailable — %s", tostring(err))
		clear_cache()
	end
end

--- Returns true if the currently focused element is a secure text field.
--- Both attributes are tested because the two UI toolkits disagree on where the
--- secure marker lives: native AppKit sets AXRole = AXSecureTextField, whereas
--- WebKit/Blink report AXRole = AXTextField and demote the marker to AXSubrole.
--- Testing the role alone therefore fails OPEN on every Chrome/Edge/Brave/Arc
--- login form, letting the keylogger record the user's password characters.
--- @return boolean True when the cached element is secure or classification was incomplete.
function M.isSecureField()
	return _cached_secure
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
