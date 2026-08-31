--- adapters/secure_field_detector.lua

--- ==============================================================================
--- MODULE: SecureFieldDetector Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the SecureFieldDetector port contract defined in
--- static/ergopti_plus/_shared/core/ports/SecureFieldDetector.spec.js. Uses
--- libatspi to detect whether the currently focused element is a password field,
--- and a hardcoded known-app list
--- for apps that render secure views in WebKit or Electron without exposing the
--- AT-SPI role.
---
--- FEATURES & RATIONALE:
--- 1. AT-SPI2 role detection: Linux GTK/Qt apps expose PASSWORD_TEXT via
---    libatspi. Focus is an accessible state, not a Registry.GetFocused method.
--- 2. Known-app guard: some security apps (Bitwarden Electron, KeePassXC WebKit)
---    never set the AT-SPI role; the hardcoded list covers these cases.
--- 3. Tri-state verdict: probe failures remain "unknown" and every privacy
---    consumer treats unknown exactly like secure. Failure can therefore remove
---    automation, never privacy.
--- 4. Focus epochs: navigation invalidates the cached verdict immediately and a
---    result captured for an older control can never be published for the new one.
---
--- NOTE: Full AT-SPI2 integration requires libatspi and a running accessibility
--- bus. Absence is an explicit unknown verdict and therefore fails closed.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local AtspiFocus = require("adapters.atspi_focus")

local LOG = "adapters.secure_field_detector"





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

-- Apps whose entire surface is considered sensitive regardless of AT-SPI role.
-- Keys are lowercase application class names (WM_CLASS second field).
local SECURE_APP_IDS = {
	["1password"]           = true,
	["bitwarden"]           = true,
	["keepassxc"]           = true,
	["lastpass"]            = true,
	["dashlane"]            = true,
	["gnome-keyring-3"]     = true,
	["seahorse"]            = true,   -- GNOME Passwords app
	["gnome-authenticator"] = true,
	["authenticator"]       = true,
	["yubikey-manager"]     = true,
}

-- URL bars are meaningful only inside browsers. Limiting the identity heuristic
-- to these application IDs prevents an ordinary editor field named "location"
-- from being classified as browser chrome.
local BROWSER_APP_IDS = {
	["brave-browser"] = true,
	["com.brave.browser"] = true,
	["com.google.chrome"] = true,
	["com.microsoft.edge"] = true,
	["com.opera.opera"] = true,
	["com.vivaldi.vivaldi"] = true,
	["chromium"] = true,
	["chromium-browser"] = true,
	["firefox"] = true,
	["google-chrome"] = true,
	["io.github.zen_browser.zen"] = true,
	["microsoft-edge"] = true,
	["opera"] = true,
	["org.chromium.chromium"] = true,
	["org.mozilla.firefox"] = true,
	["vivaldi-stable"] = true,
	["zen"] = true,
}

-- AT-SPI roles capable of representing a browser address control: COMBO_BOX,
-- TEXT, AUTOCOMPLETE, EDITBAR and ENTRY. The role narrows the verdict before
-- names/attributes are inspected; a browser page heading containing "URL" is
-- therefore never mistaken for the address bar.
local URL_CONTROL_ROLES = { [11] = true, [61] = true, [76] = true, [77] = true, [79] = true }
local URL_IDENTITY_PATTERNS = {
	"address", "location", "omnibox", "urlbar", "url bar", "url%-bar",
}





-- =================================
-- =================================
-- ======= 2/ Internal State =======
-- =================================
-- =================================

local VERDICT_SECURE   = "secure"
local VERDICT_INSECURE = "insecure"
local VERDICT_UNKNOWN  = "unknown"

-- Official AtspiRole enumeration. 57 is TABLE_COLUMN_HEADER, the value this
-- adapter previously mistook for PASSWORD_TEXT; the password role is 40.
local ROLE_PASSWORD_TEXT = 40

-- Unknown is the only honest answer before the first successful probe. Keeping
-- a boolean here made "the accessibility bus failed" indistinguishable from
-- "this is an ordinary text field", which is the fail-open direction.
local _verdict = VERDICT_UNKNOWN

-- Incremented before any event that can move focus between controls in the same
-- top-level window. refresh() accepts the epoch it is answering for and refuses
-- to publish when the caret moved while that answer was being obtained.
local _focus_epoch = 0

-- Test seam for deterministic role/failure and stale-epoch coverage. Production
-- keeps this nil and uses the AT-SPI query below.
local _probe_for_test = nil





-- ==================================
-- ==================================
-- ======= 3/ Adapter Methods =======
-- ==================================
-- ==================================

--- Invalidates the verdict before focus may move to another accessible control.
--- @return number New focus epoch.
function M.invalidateFocus()
	_focus_epoch = _focus_epoch + 1
	_verdict = VERDICT_UNKNOWN
	return _focus_epoch
end

--- Re-reads the focused element and publishes only a conclusive current answer.
--- @param epoch number|nil Focus epoch captured when this probe was scheduled.
--- @return boolean accepted True only when a current conclusive verdict was stored.
--- @return string verdict Current tri-state verdict.
function M.refresh(epoch)
	local requested_epoch = tonumber(epoch) or _focus_epoch
	local probe = _probe_for_test or AtspiFocus.get_role
	local ok, role, conclusive = pcall(probe)

	-- Check AFTER the probe: a focus event can arrive while a real asynchronous
	-- backend is resolving. The synchronous CLI backend cannot race today, but the
	-- contract prevents a future watcher from reintroducing this privacy defect.
	if requested_epoch ~= _focus_epoch then
		Logger.debug(LOG, "refresh(): discarded stale focus epoch %d (current=%d).",
			requested_epoch, _focus_epoch)
		return false, _verdict
	end

	if not ok or conclusive ~= true or type(role) ~= "number" then
		_verdict = VERDICT_UNKNOWN
		Logger.debug(LOG, "refresh(): AT-SPI2 verdict unknown — %s",
			ok and "inconclusive response" or tostring(role))
		return false, _verdict
	end

	_verdict = role == ROLE_PASSWORD_TEXT and VERDICT_SECURE or VERDICT_INSECURE
	return true, _verdict
end

--- Returns whether text must be withheld from automation and persistence.
--- Unknown deliberately returns true: callers of the legacy boolean port do not
--- have a third branch, so its safe projection is secure-or-unknown.
--- @return boolean True unless a current probe proved the field non-secure.
function M.isSecureField()
	return _verdict ~= VERDICT_INSECURE
end

--- Returns the exact cached tri-state verdict.
--- @return string "secure", "insecure", or "unknown".
function M.getVerdict()
	return _verdict
end

--- Returns the current focus epoch.
--- @return number
function M.currentEpoch()
	return _focus_epoch
end

--- Returns true if the given app ID belongs to a known security-sensitive app.
--- @param appId string|nil The application class name to check (case-insensitive).
--- @return boolean
function M.isSecureApp(appId)
	if appId == nil or appId == "" then return false end
	return SECURE_APP_IDS[tostring(appId):lower()] == true
end

--- Returns true only when the focused accessible is a browser address control.
--- An inconclusive accessibility query inside a known browser fails closed: the
--- caller explicitly enabled this privacy filter, so lack of evidence may remove
--- a suggestion but may never send a possible URL to the model.
--- @param appId string|nil
--- @return boolean
function M.isUrlBar(appId)
	local normalized_app = type(appId) == "string" and appId:lower():gsub("%.desktop$", "") or ""
	if not BROWSER_APP_IDS[normalized_app] then return false end

	local snapshot, conclusive = AtspiFocus.get_snapshot()
	if conclusive ~= true or type(snapshot) ~= "table" then return true end
	if not URL_CONTROL_ROLES[tonumber(snapshot.role)] then return false end
	-- AUTOCOMPLETE and EDITBAR are browser-chrome-specific enough to classify
	-- directly; generic TEXT/ENTRY/COMBO_BOX need a stable identity signal.
	if snapshot.role == 76 or snapshot.role == 77 then return true end

	local identity = { tostring(snapshot.name or ""):lower() }
	for key, value in pairs(snapshot.attributes or {}) do
		identity[#identity + 1] = tostring(key):lower()
		identity[#identity + 1] = tostring(value):lower()
	end
	local joined = table.concat(identity, " ")
	for _, pattern in ipairs(URL_IDENTITY_PATTERNS) do
		if joined:find(pattern) then return true end
	end
	return false
end

--- Installs a deterministic probe for tests.
--- @param fn function|nil Returns role_number, conclusive_boolean.
function M._set_probe_for_test(fn)
	_probe_for_test = type(fn) == "function" and fn or nil
end

return M
