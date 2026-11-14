--- adapters/system_curl.lua

--- ==============================================================================
--- MODULE: System curl Gate (Hammerspoon)
--- DESCRIPTION:
--- `/usr/bin/curl` is a system tool (owned-runtimes row "SYS: check once,
--- refuse with a message"): the driver never ships or replaces it, and checks
--- it before the first transfer that needs it. A missing, unreadable or too
--- old copy refuses every later curl start with one localized reason instead
--- of a bare spawn failure.
---
--- FEATURES & RATIONALE:
--- 1. Checked once: the first point of use reads `curl --version`, and the
---    verdict stays for the session; macOS replaces curl only with an OS update,
---    which restarts the app.
--- 2. One minimum: MINIMUM_VERSION is the curl macOS 11 ships, the oldest
---    system the app bundle declares (LSMinimumSystemVersion 11.0), and it
---    covers every option the driver passes.
--- 3. Told once: the user sees one notification naming the reason; every
---    refused start is still logged as an error.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")

local LOG = "adapters.system_curl"

-- The only curl the driver starts.
M.PATH = "/usr/bin/curl"

-- The curl macOS 11 (the bundle's LSMinimumSystemVersion) ships.
M.MINIMUM_VERSION = "7.64.1"

-- Captured at load: the probe is this module's own native edge, so a caller
-- that replaces hs.execute for its own commands does not answer it.
local popen = io.popen

local DEFAULT_DEPS = {
	--- Reads `curl --version`, or returns nil when it could not run.
	read_version = function()
		local ok, pipe = pcall(popen, M.PATH .. " --version 2>/dev/null", "r")
		if not ok or not pipe then return nil end
		local output = pipe:read("*a")
		local closed, kind, code = pipe:close()
		if closed ~= true or kind ~= "exit" or code ~= 0 or type(output) ~= "string" then return nil end
		return output
	end,
	--- Tells the user, once, why curl is refused.
	notify = function(title, body)
		return require("adapters.notifier").send(title, { body = body, kind = "error" })
	end,
}

local _deps = DEFAULT_DEPS
local _verdict = nil
local _told = false





-- ==================================
-- ==================================
-- ======= 1/ Version reading =======
-- ==================================
-- ==================================

--- Reads the version from the first line of `curl --version`.
--- @param text string|nil
--- @return string|nil version Dotted version, or nil when the text names none.
function M.parse_version(text)
	if type(text) ~= "string" then return nil end
	return text:match("^curl (%d+%.%d+%.?%d*)")
end

--- Compares two dotted versions.
--- @param left string
--- @param right string
--- @return boolean at_least True when left >= right.
local function at_least(left, right)
	local a, b = {}, {}
	for part in left:gmatch("%d+") do a[#a + 1] = tonumber(part) end
	for part in right:gmatch("%d+") do b[#b + 1] = tonumber(part) end
	for i = 1, math.max(#a, #b) do
		local x, y = a[i] or 0, b[i] or 0
		if x ~= y then return x > y end
	end
	return true
end

--- Builds the verdict for one `curl --version` output.
--- @param text string|nil
--- @return table verdict { ok, reason = "missing"|"too_old"|nil, found = string|nil }
function M.verdict_for(text)
	local found = M.parse_version(text)
	if not found then return { ok = false, reason = "missing" } end
	if not at_least(found, M.MINIMUM_VERSION) then
		return { ok = false, reason = "too_old", found = found }
	end
	return { ok = true, found = found }
end





-- ===============================
-- ===============================
-- ======= 2/ Public API =========
-- ===============================
-- ===============================

--- Builds the localized refusal for a verdict.
--- @param verdict table A refused verdict from verdict_for().
--- @return string title, string body
function M.message_for(verdict)
	local I18n = require("core.i18n.engine.i18n")
	if verdict.reason == "too_old" then
		return I18n.get("system.curl.refused_title"),
			I18n.format("system.curl.too_old_body", M.PATH, tostring(verdict.found), M.MINIMUM_VERSION)
	end
	return I18n.get("system.curl.refused_title"), I18n.format("system.curl.missing_body", M.PATH)
end

--- Checks the system curl before a transfer; the first call reads its version.
--- @param purpose string What the refused transfer was for, for the log.
--- @return boolean ok
--- @return string|nil reason The localized refusal when not ok.
function M.check(purpose)
	if _verdict == nil then
		_verdict = M.verdict_for(_deps.read_version())
		if _verdict.ok then
			Logger.info(LOG, "System curl %s accepted (minimum %s).", _verdict.found, M.MINIMUM_VERSION)
		end
	end
	if _verdict.ok then return true end
	local title, body = M.message_for(_verdict)
	Logger.error(LOG, "Refused %s: %s is %s (minimum %s).", tostring(purpose), M.PATH,
		_verdict.reason == "too_old" and ("version " .. tostring(_verdict.found)) or "missing or unreadable",
		M.MINIMUM_VERSION)
	if not _told then
		_told = true
		if _deps.notify(title, body) ~= true then
			Logger.error(LOG, "The curl refusal could not be shown to the user.")
		end
	end
	return false, body
end

--- Replaces the native edges and forgets the verdict (tests only).
--- @param deps table|nil Partial deps; nil restores the native ones.
function M._set_deps(deps)
	_deps = {}
	for key, value in pairs(DEFAULT_DEPS) do _deps[key] = value end
	for key, value in pairs(type(deps) == "table" and deps or {}) do _deps[key] = value end
	_verdict = nil
	_told = false
end

return M
