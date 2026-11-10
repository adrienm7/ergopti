--- modules/shortcuts/open_selection.lua

--- ==============================================================================
--- MODULE: Open the Selection (Linux)
--- DESCRIPTION:
--- The copy_selected_path action on Linux. In a file manager it copies the
--- selected files' paths, as Explorer and Finder do on the other drivers;
--- elsewhere it opens what the primary selection names (a URL, an IP address,
--- localhost, a mail address, a file or a folder) through xdg-open, or searches
--- the web for plain text. The classification is _shared/lua/open_target,
--- shared with macOS and ported to Windows.
---
--- FEATURES & RATIONALE:
--- 1. The target reaches xdg-open as one argument through
---    adapters/desktop_opener, never inside a shell command, so no selected
---    text can run.
--- 2. A recognised target that cannot be opened (a missing path, a bare file
---    name, a registry key or a Windows path) is logged and notified, never
---    searched instead: the user asked to open that thing.
--- 3. A file manager publishes its selection as text/uri-list after Ctrl+C.
---    The clipboard adapter reads that target, _shared/lua/file_selection
---    decodes its file: URIs, and the clipboard keeps the paths, one per line.
---    Ctrl+C is sent only to a known file manager: in a terminal it would
---    interrupt the running program. A compositor that names no focused
---    application (GNOME and KDE under Wayland) therefore keeps the opening
---    behaviour unless the AT-SPI active frame names the application: the window
---    manager's ACTIVE frame is the one window the user is in, and its process
---    name is the identity the X11 path reports.
--- ==============================================================================

local M = {}
local TextUtils = require("text_utils")

local OpenTarget = require("open_target")
local FileSelection = require("file_selection")
local Logger = require("logger.shim")
local FileManagerFolder = require("adapters.file_manager_folder")

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
	path_status = function(path) return require("adapters.file_system").path_status(path) end,
	notify = function(message) return require("adapters.notifier").send(message, { level = "error" }) end,
	message = function(key) return require("infra.i18n").get(key) end,
	getenv = os.getenv,
	focused_app = function() return require("adapters.window_info").getFocused().appId end,
	focused_context = function()
		local info, identity = require("adapters.window_info").focused_snapshot()
		local app = info and type(info.appId) == "string" and info.appId ~= "" and info.appId or nil
		if app and type(identity) == "string" and identity ~= "" then return app, identity end
		local snapshot, conclusive = require("adapters.atspi_focus").get_context_snapshot()
		if conclusive == true and snapshot and type(snapshot.window_bus_name) == "string"
			and type(snapshot.window_object_path) == "string" then
			if app and snapshot.app_id ~= app then return app, nil end
			return snapshot.app_id, "atspi:" .. snapshot.window_bus_name .. ":" .. snapshot.window_object_path
		end
		return app, nil
	end,
	-- Bounded helper process with a hard deadline; needs a desktop session.
	active_frame_app = function()
		local snapshot = require("adapters.atspi_focus").get_context_snapshot()
		return snapshot and snapshot.app_id or nil
	end,
	read_uri_list = function(admitted)
		local function guarded_press(combo)
			if admitted() ~= true then return false end
			return require("modules.gestures.combo_emitter").press(combo)
		end
		return require("adapters.clipboard").read_selection_uri_list(
			guarded_press, require("adapters.event_loop").sleep_ms)
	end,
	write_clipboard = function(text) return require("adapters.clipboard").write(text) end,
	notify_success = function(message)
		return require("adapters.notifier").send(message, { level = "success" })
	end,
}
local deps = DEFAULT_DEPS





-- ===================================
-- ===================================
-- ======= 1/ Internal Helpers =======
-- ===================================
-- ===================================

--- Encodes one query component (RFC 3986 unreserved characters kept).
local encode_query = TextUtils.percent_encode

--- Logs why a recognised target stayed closed and tells the user.
--- @param reason string A REPORT_KEYS key.
local function report(reason)
	-- Both the selected target and native error strings can contain user text.
	Logger.error(LOG, "Could not open the selected target (%s).", reason)
	local template = deps.message(REPORT_KEYS[reason])
	-- The notifier may log its message when the desktop service is absent or
	-- refuses it, so the notice must not carry the selected target either.
	local message = (tostring(template):gsub("%%s", "…"))
	if deps.notify(message) ~= true then
		Logger.warn(LOG, "The selected-target notice was not shown.")
	end
end

--- Hands one classified target to xdg-open.
--- @param kind string
--- @param target string
--- @return boolean admitted
local function open(kind, target)
	Logger.start(LOG, "Opening the selected %s…", kind)
	local request = deps.open(target, function(result)
		if result.ok == true then
			Logger.success(LOG, "xdg-open accepted the selected %s.", kind)
		else
			report("failed")
		end
	end)
	if not request then
		report("failed")
		return false
	end
	return true
end





--- Whether a focused application identity names a known file manager.
--- @param app any
--- @return boolean
local function is_file_manager(app)
	return FileManagerFolder.file_manager_name(app) ~= nil
end

local function capture_manager(app, identity)
	if type(identity) ~= "string" or identity == "" then return nil end
	return function()
		local ok, current, observed = pcall(deps.focused_context)
		return ok and current == app and is_file_manager(current) and observed == identity
	end
end

--- Retains the currently focused known file manager for a later copy chord.
--- @return function|nil Checks that the same native window is still focused.
function M.capture_file_manager()
	local captured, app, identity = pcall(deps.focused_context)
	if not captured or not is_file_manager(app) then return nil end
	return capture_manager(app, identity)
end

--- Copies the file manager's selected paths to the clipboard.
--- @return boolean|nil copied True when copied, false when refused, nil when
---   no file is selected (the caller then opens the primary selection).
local function copy_file_selection(admitted)
	local ok, uri_list, reason = deps.read_uri_list(admitted)
	if admitted() ~= true then return false end
	if not ok then
		if reason == "no_file_selection" then return nil end
		Logger.error(LOG, "copy_selected_path: the file manager's selection could not be read (%s).", tostring(reason))
		return false
	end
	local paths, why = FileSelection.parse_uri_list(uri_list)
	if not paths then
		Logger.error(LOG, "copy_selected_path refused: the selection is not a list of local files (%s).", tostring(why))
		return false
	end
	if #paths == 0 then return nil end
	local text = table.concat(paths, "\n")
	if deps.write_clipboard(text) ~= true then
		Logger.error(LOG, "copy_selected_path: the %d selected path(s) could not be written to the clipboard.", #paths)
		return false
	end
	Logger.success(LOG, "Copied the path of %d selected item(s) from the file manager.", #paths)
	-- The notifier can fall back to logging its message; keep file paths out.
	local message = (tostring(deps.message("shortcuts.copy_path_notif")):gsub("%%s", "…"))
	if deps.notify_success(message) ~= true then
		Logger.warn(LOG, "The copied-path notice was not shown.")
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
		if found.exact_path then
			local called, status = pcall(deps.path_status, found.exact_path)
			if not called or (status ~= "present" and status ~= "absent") then
				report("failed")
				return false
			end
			if status == "present" then target = found.exact_path end
		end
		if not deps.exists(target) then
			report("missing")
			return false
		end
		return open(kind, target)
	end
	if kind == "url" then return open(kind, target) end
	if kind == "file_name" then
		report("file_name")
		return false
	end
	if kind == "unsupported" then
		report("windows_only")
		return false
	end
	report("failed")
	return false
end

--- Runs the copy_selected_path action: copies the selected files' paths in a
--- file manager, otherwise opens what the primary selection names.
--- @param read_primary function () -> string, read only when it is needed.
--- @return boolean True when paths were copied or a target was opened.
function M.copy_selected_path(read_primary)
	local captured, app, identity = pcall(deps.focused_context)
	if not captured then app, identity = nil, nil end
	if type(app) ~= "string" or app == "" then
		-- GNOME and KDE on Wayland name no foreground application.
		app = deps.active_frame_app()
		if app ~= nil then
			Logger.info(LOG, "copy_selected_path: the AT-SPI active frame names the application '%s'.", tostring(app))
		end
	end
	if is_file_manager(app) then
		local admitted = capture_manager(app, identity)
		if not admitted then
			Logger.warn(LOG, "copy_selected_path: the file-manager window identity is unavailable.")
			return false
		end
		local copied = copy_file_selection(admitted)
		if copied ~= nil then return copied end
		Logger.info(LOG, "copy_selected_path: no file is selected in %s — opening the primary selection.", app)
	end
	return M.open(read_primary())
end

--- Replaces the native boundaries; nil restores them.
--- @param overrides table|nil
function M._set_deps_for_test(overrides)
	deps = overrides and setmetatable(overrides, { __index = DEFAULT_DEPS }) or DEFAULT_DEPS
end

return M
