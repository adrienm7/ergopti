--- modules/shortcuts/open_selection.lua

--- ==============================================================================
--- MODULE: Open the Selection (Linux)
--- DESCRIPTION:
--- The copy_selected_path action on Linux: opens what the primary selection
--- names (a URL, an IP address, localhost, a mail address, a file or a folder)
--- through xdg-open, or searches the web for plain text. The classification is
--- _shared/lua/open_target, shared with macOS and ported to Windows.
---
--- FEATURES & RATIONALE:
--- 1. The target reaches xdg-open as one argument through
---    adapters/desktop_opener, never inside a shell command, so no selected
---    text can run.
--- 2. A recognised target that cannot be opened (a missing path, a bare file
---    name, a registry key or a Windows path) is logged and notified, never
---    searched instead: the user asked to open that thing.
--- 3. The file-manager branch of the action (copying the selected files'
---    paths) is not implemented: a file manager publishes its selection as
---    text/uri-list after Ctrl+C, which the clipboard adapter cannot read by
---    MIME type.
--- ==============================================================================

local M = {}

local OpenTarget = require("open_target")
local Logger = require("logger.shim")

local LOG = "shortcuts.open_selection"

-- The locale key of each report, by the reason the target was not opened.
local REPORT_KEYS = {
	missing = "open_target.missing_path",
	file_name = "open_target.bare_file_name",
	windows_only = "open_target.windows_only",
	failed = "open_target.open_failed",
}

local DEFAULT_DEPS = {
	open = function(target, on_done) return require("adapters.desktop_opener").open(target, on_done) end,
	exists = function(path) return require("adapters.file_system").exists(path) end,
	notify = function(message) return require("adapters.notifier").send(message, { level = "error" }) end,
	message = function(key) return require("infra.i18n").get(key) end,
	getenv = os.getenv,
}
local deps = DEFAULT_DEPS





-- ===================================
-- ===================================
-- ======= 1/ Internal Helpers =======
-- ===================================
-- ===================================

--- Encodes one query component (RFC 3986 unreserved characters kept).
--- @param value string
--- @return string
local function encode_query(value)
	return (value:gsub("[^%w%-%._~]", function(char)
		return string.format("%%%02X", string.byte(char))
	end))
end

--- Logs why a recognised target stayed closed and tells the user.
--- @param reason string A REPORT_KEYS key.
--- @param target string
--- @param detail string English detail for the log.
local function report(reason, target, detail)
	Logger.error(LOG, "Could not open '%s': %s.", target, detail)
	local template = deps.message(REPORT_KEYS[reason])
	local message = (tostring(template):gsub("%%s", function() return target end))
	if deps.notify(message) ~= true then
		Logger.warn(LOG, "The notice for '%s' was not shown.", target)
	end
end

--- Hands one classified target to xdg-open.
--- @param kind string
--- @param target string
--- @return boolean admitted
local function open(kind, target)
	Logger.start(LOG, "Opening the selected %s '%s'…", kind, target)
	local request, refusal = deps.open(target, function(result)
		if result.ok == true then
			Logger.success(LOG, "xdg-open accepted the selected %s '%s'.", kind, target)
		else
			report("failed", target, "xdg-open failed (" .. tostring(result.error or result.code) .. ")")
		end
	end)
	if not request then
		report("failed", target, "the desktop opener refused it (" .. tostring(refusal) .. ")")
		return false
	end
	return true
end





-- ===============================
-- ===============================
-- ======= 2/ Public API =========
-- ===============================
-- ===============================

--- Opens what a selected text names, or searches the web for it.
--- @param text string The primary selection.
--- @return boolean True when something was handed to xdg-open.
function M.open(text)
	local found = OpenTarget.classify(text, deps.getenv)
	local kind, target = found.kind, found.target
	if kind == "empty" then
		Logger.warn(LOG, "copy_selected_path: no primary selection to open — nothing opened.")
		return false
	end
	if kind == "search" then
		return open("search", OpenTarget.DEFAULT_SEARCH_URL .. encode_query(target))
	end
	if kind == "path" then
		if not deps.exists(target) then
			report("missing", target, "no file or folder exists at that path")
			return false
		end
		return open(kind, target)
	end
	if kind == "url" then return open(kind, target) end
	if kind == "file_name" then
		report("file_name", target, "a file name without its folder cannot be located")
		return false
	end
	if kind == "unsupported" then
		report("windows_only", target, "only Windows can open it")
		return false
	end
	report("failed", target, "unexpected target kind " .. tostring(kind))
	return false
end

--- Replaces the native boundaries; nil restores them.
--- @param overrides table|nil
function M._set_deps_for_test(overrides)
	deps = overrides and setmetatable(overrides, { __index = DEFAULT_DEPS }) or DEFAULT_DEPS
end

return M
