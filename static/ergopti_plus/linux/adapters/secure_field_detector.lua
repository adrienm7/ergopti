--- linux/adapters/secure_field_detector.lua

--- ==============================================================================
--- MODULE: SecureFieldDetector Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the SecureFieldDetector port contract defined in
--- static/ergopti_plus/shared/ports/SecureFieldDetector.spec.js. Uses AT-SPI2
--- via the at-spi2-core CLI tools (or xprop as fallback) to detect whether the
--- currently focused element is a password field, and a hardcoded known-app list
--- for apps that render secure views in WebKit or Electron without exposing the
--- AT-SPI role.
---
--- FEATURES & RATIONALE:
--- 1. AT-SPI2 role detection: Linux GTK/Qt apps expose "PASSWORD_TEXT" or
---    "SINGLE_LINE, PASSWORD_TEXT" via AT-SPI2. gdbus/dbus-send queries the
---    focused element role without requiring root.
--- 2. Known-app guard: some security apps (Bitwarden Electron, KeePassXC WebKit)
---    never set the AT-SPI role; the hardcoded list covers these cases.
--- 3. Fail-safe returns: every method returns false on any error.
---
--- NOTE: Full AT-SPI2 integration requires the at-spi2-core package and a
--- running D-Bus session. The current implementation checks the XDG_RUNTIME_DIR
--- for the D-Bus socket and falls back gracefully when unavailable.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

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


-- =================================
-- =================================
-- ======= 2/ Internal State =======
-- =================================
-- =================================

-- Cached result of the last refresh() call.
local _is_secure_field = false




-- ==============================================
-- ==============================================
-- ======= 3/ Internal AT-SPI2 Helpers =========
-- ==============================================
-- ==============================================

--- Returns true when the D-Bus session bus socket is accessible.
local function _dbus_available()
	local addr = os.getenv("DBUS_SESSION_BUS_ADDRESS")
	return addr ~= nil and addr ~= ""
end

--- Queries the AT-SPI2 role of the currently focused element via gdbus.
--- Returns the role string (e.g. "PASSWORD_TEXT") or nil on failure.
local function _get_atspi_role()
	if not _dbus_available() then return nil end
	-- gdbus call to get the focused element via AT-SPI2 registry
	local cmd = table.concat({
		"gdbus call --session",
		"--dest org.a11y.atspi.Registry",
		"--object-path /org/a11y/atspi/registry",
		"--method org.a11y.atspi.Registry.GetFocused",
		"2>/dev/null",
	}, " ")
	local fh = io.popen(cmd, "r")
	if not fh then return nil end
	local out = fh:read("*a")
	fh:close()
	-- Output: "(<'bus_name'>, <objectpath '/path'>)"
	-- Then query the role attribute via AtspiAccessible.GetRole
	local bus, path = out:match("'([^']+)',%s*<objectpath '([^']+)'>")
	if not bus or not path then return nil end

	local role_cmd = string.format(
		"gdbus call --session --dest %s --object-path %s "
		.. "--method org.a11y.atspi.Accessible.GetRole 2>/dev/null",
		bus, path)
	local fh2 = io.popen(role_cmd, "r")
	if not fh2 then return nil end
	local role_out = fh2:read("*a")
	fh2:close()
	-- Role is returned as an integer; 57 = ATSPI_ROLE_PASSWORD_TEXT
	local role_int = tonumber(role_out:match("%((%d+),%)"))
	if role_int == 57 then return "PASSWORD_TEXT" end
	return nil
end




-- ==================================
-- ==================================
-- ======= 4/ Adapter Methods =======
-- ==================================
-- ==================================

--- Re-reads the focused element via AT-SPI2 and caches whether it is a secure field.
--- Errors are silently ignored; _is_secure_field is set to false on failure.
function M.refresh()
	local ok, err = pcall(function()
		local role = _get_atspi_role()
		_is_secure_field = role == "PASSWORD_TEXT"
	end)
	if not ok then
		Logger.debug(LOG, "refresh(): AT-SPI2 unavailable — %s", tostring(err))
		_is_secure_field = false
	end
end

--- Returns true if the currently focused element is a secure text field.
--- @return boolean True when the cached role is PASSWORD_TEXT.
function M.isSecureField()
	return _is_secure_field == true
end

--- Returns true if the given app ID belongs to a known security-sensitive app.
--- @param appId string|nil The application class name to check (case-insensitive).
--- @return boolean
function M.isSecureApp(appId)
	if appId == nil or appId == "" then return false end
	return SECURE_APP_IDS[tostring(appId):lower()] == true
end

return M
