--- adapters/privacy_settings.lua

--- ==============================================================================
--- MODULE: Privacy Settings URLs
--- DESCRIPTION:
--- Builds the System Settings URL of one privacy pane (Accessibility,
--- Automation, Input Monitoring, Screen Recording) from data/privacy_panes.json,
--- the one table every privacy-pane URL of the driver comes from.
---
--- FEATURES & RATIONALE:
--- 1. Version-aware form: macOS 26 refused the legacy
---    com.apple.preference.security form for Screen Recording (ledger L29,
---    openURL returned false), so from the declared major version on the
---    PrivacySecurity extension form is used. The field report collector opens
---    every form on the Mac and records which one macOS accepts.
--- 2. Pure choice: M.url_for(pane, major) takes the version, so the decision is
---    tested without a Mac; M.url(pane) reads the running version.
--- 3. Fail fast: an unknown pane or a malformed table raises. An unreadable
---    macOS version is logged and keeps the legacy form, which every release
---    before 26 accepts.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local Json = require("json")

local LOG = "adapters.privacy_settings"

local _table = nil





-- ============================
-- ============================
-- ======= 1/ The table =======
-- ============================
-- ============================

--- The folder of this source file.
--- @return string folder
local function source_dir()
	local source = debug.getinfo(1, "S").source
	return (source:sub(1, 1) == "@" and source:sub(2) or source):match("^(.*)/[^/]*$") or "."
end

--- Validates a decoded pane table; a malformed one raises.
--- @param spec table Decoded data/privacy_panes.json.
--- @return table spec
function M.validate(spec)
	if type(spec) ~= "table" or spec.schema ~= 1 then error("privacy panes: unsupported table", 2) end
	if type(spec.forms) ~= "table" or type(spec.forms.legacy) ~= "string" or type(spec.forms.extension) ~= "string" then
		error("privacy panes: forms.legacy and forms.extension are required", 2)
	end
	if type(spec.extension_from_major) ~= "number" or spec.extension_from_major % 1 ~= 0 then
		error("privacy panes: extension_from_major must be an integer", 2)
	end
	if type(spec.panes) ~= "table" or next(spec.panes) == nil then error("privacy panes: panes must be nonempty", 2) end
	for id, anchor in pairs(spec.panes) do
		if type(id) ~= "string" or type(anchor) ~= "string" or not anchor:match("^Privacy_%w+$") then
			error("privacy panes: pane " .. tostring(id) .. " has an invalid anchor", 2)
		end
	end
	return spec
end

--- The pane table, read once from data/privacy_panes.json.
--- @return table spec
function M.table()
	if _table then return _table end
	local path = source_dir() .. "/../data/privacy_panes.json"
	local file = assert(io.open(path, "r"), "privacy panes: cannot open " .. path)
	local text = file:read("*a")
	file:close()
	_table = M.validate(Json.decode(text))
	return _table
end





-- =======================
-- =======================
-- ======= 2/ URLs =======
-- =======================
-- =======================

--- The URL of one pane for a macOS major version.
--- @param pane string Pane id of the table.
--- @param major number|nil macOS major version; nil keeps the legacy form.
--- @return string url
function M.url_for(pane, major)
	local spec = M.table()
	local anchor = spec.panes[pane]
	if not anchor then error("privacy panes: unknown pane " .. tostring(pane), 2) end
	local form = (type(major) == "number" and major >= spec.extension_from_major) and "extension" or "legacy"
	return spec.forms[form] .. anchor
end

--- The running macOS major version, or nil when it cannot be read.
--- @return number|nil major
function M.os_major()
	local root = rawget(_G, "hs")
	local host = type(root) == "table" and root.host or nil
	if type(host) ~= "table" or type(host.operatingSystemVersion) ~= "function" then return nil end
	local ok, version = pcall(host.operatingSystemVersion)
	return ok and type(version) == "table" and tonumber(version.major) or nil
end

--- The URL of one pane for the running macOS.
--- @param pane string Pane id of the table.
--- @return string url
function M.url(pane)
	local major = M.os_major()
	if major == nil then
		Logger.warn(LOG, "The macOS version could not be read; the %s pane uses the legacy settings URL.", pane)
	end
	return M.url_for(pane, major)
end

--- Forgets the cached table; tests only.
function M._reset()
	_table = nil
end

return M
