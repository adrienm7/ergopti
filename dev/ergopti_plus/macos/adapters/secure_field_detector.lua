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

-- Cached AXRole of the focused element, populated by refresh()
local _cached_role = nil

-- Cached AXSubrole of the focused element, populated by refresh(). Kept beside
-- the role because Chromium-family browsers report a password input as
-- AXRole = AXTextField with the secure marker demoted to the subrole.
local _cached_subrole = nil




-- ==================================
-- ==================================
-- ======= 3/ Adapter Methods =======
-- ==================================
-- ==================================

--- Re-reads the focused element via hs.axuielement and caches its AXRole and AXSubrole.
--- Uses applicationElementForPID + AXFocusedUIElement — the only stable HS API for this.
--- hs.axuielement.focusedElement() does not exist in Hammerspoon; accessing the focused
--- element requires going through the application's accessibility tree (H2 audit fix).
--- Errors are silently ignored; both cached attributes are reset to nil on failure.
function M.refresh()
	-- Every early exit below must clear BOTH attributes: leaving a stale subrole
	-- behind would keep reporting a password field long after focus moved away.
	local function clear_cache()
		_cached_role    = nil
		_cached_subrole = nil
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
			-- Each attribute is read in its OWN pcall. Sharing the outer one meant a
			-- throw on the SECOND read aborted the closure and sent control to the
			-- handler below, which clears BOTH — discarding an "AXSecureTextField"
			-- already stored by the first read. isSecureField() then returned false
			-- for a genuine password field: it failed OPEN, the exact mode this
			-- module's own docstring calls "letting the keylogger record the user's
			-- password characters". AX reads throw on a dead or replaced element, so
			-- one of the two failing is ordinary. Mirrors the per-attribute pcalls
			-- keylogger/context_tracker.lua already uses for the same two reads.
			local ok_role, role    = pcall(function() return focused:attributeValue("AXRole") end)
			local ok_sub,  subrole = pcall(function() return focused:attributeValue("AXSubrole") end)
			_cached_role    = ok_role and role    or nil
			_cached_subrole = ok_sub  and subrole or nil
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
--- @return boolean True when either cached attribute is "AXSecureTextField".
function M.isSecureField()
	return _cached_role == SECURE_ROLE or _cached_subrole == SECURE_ROLE
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
