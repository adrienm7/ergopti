--- adapters/window_info.lua

--- ==============================================================================
--- MODULE: WindowInfo Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the WindowInfo port contract defined in
--- static/ergopti_plus/_shared/core/ports/WindowInfo.spec.js. Answers "which
--- window has focus" through whatever the running session actually offers.
---
--- WHY THE WAYLAND SIDE IS A LIST AND NOT A PATH:
--- There is no cross-compositor way to ask this question. X11 has one answer that
--- works everywhere; Wayland has one answer per compositor, and the two biggest
--- desktops offer none at all:
---   - sway and other wlroots compositors answer `swaymsg -t get_tree`.
---   - Hyprland answers `hyprctl activewindow -j`.
---   - niri answers `niri msg --json focused-window`.
---   - GNOME removed Shell.Eval in 41, so there is no unprivileged way to ask.
---   - KDE, COSMIC and Weston expose nothing equivalent.
--- That is a deliberate security posture, not an oversight to work around, and
--- it is why per-application rules cannot be promised under Wayland. The failure
--- is honest: an empty appId, logged once, rather than a wrong one.
---
--- WHAT THIS FEEDS:
--- The focused-window identity gates password-field suppression and per-app
--- behaviour. An empty appId therefore has to mean "unknown", never "no app" —
--- callers that treat it as an identity would apply the wrong rules everywhere.
---
--- FEATURES & RATIONALE:
--- 1. Fail-safe returns: getFocused() always returns a WindowInfo table, never
---    nil — every field defaults to "" when the session cannot be queried.
--- 2. One detection, shared: which server is running comes from
---    infra/display_server.lua rather than from a local getenv, because this
---    adapter was one of two files that each carried their own X11-only answer.
--- 3. Every shell-out goes through adapters/shell_runner: window titles are
---    attacker-influenced strings that end up in a command line, and quoting
---    re-derived per call site is quoting that is eventually wrong.
--- 4. The unsupported case is stated once. A compositor with no query interface
---    logs a single line naming itself, so "per-app rules do nothing here" is a
---    fact in the log rather than a silence to debug.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Shell = require("adapters.shell_runner")
local DisplayServer = require("infra.display_server")

local LOG = "adapters.window_info"

-- Compositors that answer a focused-window query, and how to ask. Order is
-- deliberate: the probe tries each in turn, so a session running more than one
-- IPC socket resolves the same way every time rather than by chance.
local WAYLAND_BACKENDS = { "sway", "hyprland", "niri" }

-- Set once when no query interface exists, so the log states the limitation
-- rather than repeating it on every keystroke's context refresh.
local _reported_unsupported = false

-- Set once when wmctrl is missing, for the same reason.
local _reported_no_window_list = false

-- The /proc process-name reader getAll() uses; a test seam replaces it.
local _read_proc_comm = nil




-- =========================================
-- =========================================
-- ======= 1/ Internal Helpers =============
-- =========================================
-- =========================================

--- Returns an empty WindowInfo table (all fields "").
--- @return table
local function empty_info()
	return { appId = "", windowTitle = "", bundleId = "", executablePath = "" }
end

--- Decodes JSON, returning nil rather than raising on anything unexpected.
--- @param raw string
--- @return table|nil
local function decode_json(raw)
	if type(raw) ~= "string" or raw == "" then return nil end
	local ok_mod, json = pcall(require, "json")
	if not ok_mod or type(json) ~= "table" or type(json.decode) ~= "function" then
		Logger.warn(LOG, "No JSON decoder — the compositor query cannot be read.")
		return nil
	end
	local ok, value = pcall(json.decode, raw)
	if not ok or type(value) ~= "table" then return nil end
	return value
end

--- Reads the process name for a PID, or "" when it cannot be read.
--- @param pid string|number|nil
--- @return string
local function comm_of(pid)
	if not pid then return "" end
	local comm = Shell.exec_line("cat " .. Shell.quote("/proc/" .. tostring(pid) .. "/comm"))
	return comm or ""
end

--- Reads a process name from /proc in this process: the window list names
--- every window, and a spawn per window froze the menu that asked for it.
--- @param pid number
--- @return string The name, or "" when the process is gone.
local function read_proc_comm(pid)
	local handle = io.open("/proc/" .. tostring(pid) .. "/comm", "rb")
	if not handle then return "" end
	local comm = handle:read("*a") or ""
	handle:close()
	return (comm:gsub("%s+$", ""))
end
_read_proc_comm = read_proc_comm

-- Window titles are not identities: two applications can both show "Untitled".
-- Retain the window ID too, while avoiding repeated process lookups at each poll.
local _x11_cache = { id = nil, title = nil, appId = "", identity = nil, pid = nil }

--- Builds a native window identity without substituting application metadata.
--- @param server string Display-server namespace.
--- @param id string|number|nil Native window identifier.
--- @param pid string|number|nil Owning process, when the compositor exposes it.
--- @return string|nil
local function native_identity(server, id, pid)
	if (type(id) ~= "string" and type(id) ~= "number") or tostring(id) == "" then return nil end
	if id == 0 or id == "0" or id == "0x0" then return nil end
	local process = (type(pid) == "string" or type(pid) == "number") and tostring(pid) or ""
	return server .. ":" .. process .. ":" .. tostring(id)
end




-- =========================================
-- =========================================
-- ======= 2/ X11 ==========================
-- =========================================
-- =========================================

--- Queries the focused window through xdotool.
---
--- Read the title from the exact window whose identity is retained, including
--- title changes within one browser window and switches between identical titles.
--- @return table|nil WindowInfo, or nil when the query produced nothing.
local function focused_x11()
	local win_id = Shell.exec_line("xdotool getactivewindow 2>/dev/null")
	if not win_id then return nil end
	local title = Shell.exec_line("xdotool getwindowname " .. Shell.quote(win_id) .. " 2>/dev/null")
	if not title then return nil end

	local info = empty_info()
	info.windowTitle = title

	if win_id == _x11_cache.id and title == _x11_cache.title and _x11_cache.appId ~= "" then
		info.appId = _x11_cache.appId
		return info, _x11_cache.identity, _x11_cache.pid
	end

	-- The identity is the process name, deliberately, and not WM_CLASS. It is
	-- what this driver has always reported, what the keystroke metrics are
	-- already attributed to, and what the other two drivers report; WM_CLASS
	-- would be a nicer identity and a silent break of every stored attribution.
	local pid = Shell.exec_line("xdotool getwindowpid " .. Shell.quote(win_id) .. " 2>/dev/null")
	info.appId = comm_of(pid)

	_x11_cache.id = win_id
	_x11_cache.title = title
	_x11_cache.appId = info.appId
	_x11_cache.identity = native_identity("x11", win_id, pid)
	_x11_cache.pid = tonumber(pid)
	return info, _x11_cache.identity, _x11_cache.pid
end

--- Parses `wmctrl -lp`: one managed window per line, as its id, desktop,
--- owning process (0 when the client does not say), client machine and title.
--- @param text string
--- @return table Array of { id, pid, title }.
function M._parse_wmctrl_list(text)
	local windows = {}
	for line in tostring(text or ""):gmatch("[^\n]+") do
		local id, pid, title = line:match("^(0x%x+)%s+%-?%d+%s+(%d+)%s+%S+ ?(.-)\r?$")
		if id then
			windows[#windows + 1] = { id = id, pid = tonumber(pid), title = title }
		else
			Logger.warn(LOG, "Unexpected wmctrl -lp line ignored: '%s'.", line)
		end
	end
	return windows
end

--- Lists every managed window in one wmctrl query, each named by the process
--- name focused_x11() reports, read from /proc without a spawn per window:
--- the excluded-applications picker builds this list on the menu path.
--- @return table Array of WindowInfo.
local function all_x11()
	if not Shell.has_command("wmctrl", true) then
		if not _reported_no_window_list then
			_reported_no_window_list = true
			Logger.warn(LOG, "wmctrl is not installed — the X11 window list is empty, so the "
				.. "excluded-applications picker offers no running application.")
		end
		return {}
	end
	local ok, out, err = Shell.exec_checked("timeout 1 wmctrl -lp 2>/dev/null")
	if not ok then
		Logger.error(LOG, "getAll(): wmctrl -lp failed — %s.", tostring(err))
		return {}
	end
	local infos, names = {}, {}
	for _, window in ipairs(M._parse_wmctrl_list(out)) do
		local entry = empty_info()
		entry.windowTitle = window.title
		if window.pid and window.pid > 0 then
			if names[window.pid] == nil then names[window.pid] = _read_proc_comm(window.pid) end
			entry.appId = names[window.pid]
		end
		infos[#infos + 1] = entry
	end
	return infos
end




-- =========================================
-- =========================================
-- ======= 3/ Wayland compositors ==========
-- =========================================
-- =========================================

--- Walks a sway/wlroots tree and returns the focused node.
--- @param node table
--- @return table|nil
local function sway_focused_node(node)
	if type(node) ~= "table" then return nil end
	if node.focused == true then return node end
	for _, key in ipairs({ "nodes", "floating_nodes" }) do
		for _, child in ipairs(node[key] or {}) do
			local found = sway_focused_node(child)
			if found then return found end
		end
	end
	return nil
end

--- Queries sway (and any wlroots compositor speaking the sway IPC).
--- @return table|nil
local function focused_sway()
	local tree = decode_json(Shell.exec("swaymsg -t get_tree 2>/dev/null"))
	if not tree then return nil end
	local node = sway_focused_node(tree)
	if not node then return nil end

	local info = empty_info()
	info.windowTitle = tostring(node.name or "")
	-- app_id is the Wayland-native identity; window_properties.class is what an
	-- XWayland client reports instead, and mixing them up means every X11
	-- application under sway resolves to nothing.
	info.appId = tostring(node.app_id
		or (type(node.window_properties) == "table" and node.window_properties.class)
		or "")
	if info.appId == "" then info.appId = comm_of(node.pid) end
	return info, native_identity("sway", node.id, node.pid), tonumber(node.pid)
end

--- Queries Hyprland.
--- @return table|nil
local function focused_hyprland()
	local win = decode_json(Shell.exec("hyprctl activewindow -j 2>/dev/null"))
	if not win then return nil end
	local info = empty_info()
	info.windowTitle = tostring(win.title or "")
	info.appId = tostring(win.class or "")
	if info.appId == "" then info.appId = comm_of(win.pid) end
	return info, native_identity("hyprland", win.address, win.pid), tonumber(win.pid)
end

--- Queries niri.
--- @return table|nil
local function focused_niri()
	local win = decode_json(Shell.exec("niri msg --json focused-window 2>/dev/null"))
	if not win then return nil end
	local info = empty_info()
	info.windowTitle = tostring(win.title or "")
	info.appId = tostring(win.app_id or "")
	if info.appId == "" then info.appId = comm_of(win.pid) end
	return info, native_identity("niri", win.id, win.pid), tonumber(win.pid)
end

local WAYLAND_QUERIES = {
	sway     = { binary = "swaymsg", query = focused_sway },
	hyprland = { binary = "hyprctl", query = focused_hyprland },
	niri     = { binary = "niri",    query = focused_niri },
}

--- Tries every Wayland backend this session might speak.
--- @return table|nil
local function focused_wayland()
	for _, name in ipairs(WAYLAND_BACKENDS) do
		local backend = WAYLAND_QUERIES[name]
		if Shell.has_command(backend.binary) then
			local info, identity, pid = backend.query()
			if info then return info, identity, pid end
		end
	end

	if not _reported_unsupported then
		_reported_unsupported = true
		-- Said once, and said plainly: this is a property of the compositor, not a
		-- bug to file. GNOME removed Shell.Eval in 41 and KDE exposes no
		-- equivalent, so there is nothing to fall back to and per-application
		-- rules cannot work here.
		Logger.warn(LOG,
			"No focused-window query on this compositor (%s) — per-application rules "
				.. "are inactive for this session.",
			DisplayServer.desktop() ~= "" and DisplayServer.desktop() or "unknown")
	end
	return nil
end




-- =========================================
-- =========================================
-- ======= 4/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Queries current metadata and exact native window identity together.
--- @return table|nil info
--- @return string|nil identity
local function query_focused()
	if DisplayServer.is_wayland() then
		-- XWayland is deliberately not tried as a fallback here. It answers for
		-- X11 clients only, so a session would silently report identities for
		-- some windows and nothing for others — worse than a uniform "unknown",
		-- because a rule that works on half a desktop looks like a flaky rule.
		return focused_wayland()
	end
	if DisplayServer.is_x11() then return focused_x11() end
	return nil
end

--- Returns the identity of the currently focused window.
--- Every field is "" when the session cannot answer; the table is never nil.
--- @return table WindowInfo: { appId, windowTitle, bundleId, executablePath }
function M.getFocused()
	local ok, info = pcall(query_focused)

	if not ok then
		Logger.error(LOG, "getFocused(): unexpected error — %s", tostring(info))
		return empty_info()
	end
	return info or empty_info()
end

--- Captures current metadata and compositor identity from one focus observation.
--- Periodic polling never acquires an accessible destination as a fallback.
--- @return table info Original four-field WindowInfo shape.
--- @return string|nil identity Native server/process/window identity.
function M.focused_snapshot()
	local info, identity = M.focused_process_snapshot()
	return info, identity
end

--- Captures compositor metadata and its native owning process in one query.
--- Privacy joins may compare the PID to an independently scoped native frame.
--- The ordinary public snapshot and metadata table retain their original shape.
--- @return table info Original four-field WindowInfo shape.
--- @return string|nil identity Native server/process/window identity.
--- @return number|nil pid Exact compositor process, absent when unavailable.
function M.focused_process_snapshot()
	local ok, info, identity, pid = pcall(query_focused)
	if not ok then
		Logger.error(LOG, "focused_process_snapshot(): native focus query failed.")
		return empty_info(), nil, nil
	end
	if type(pid) ~= "number" or pid <= 0 or pid % 1 ~= 0 then pid = nil end
	return info or empty_info(), identity, pid
end

--- Captures application/title policy without treating an unknown app as ordinary.
--- On compositors without window queries, a bounded native helper resolves the
--- active frame's process and title, tied to the caller's exact field receipt.
--- @param field table Exact fresh { bus, path, role } from the resident watcher.
--- @return table|nil context Fresh application/title and native window owner.
function M.focused_privacy_context(field)
	if type(field) ~= "table" then return nil end
	local snapshot, conclusive = require("adapters.atspi_focus").get_context_snapshot()
	if conclusive ~= true then return nil end
	return M._privacy_context_from_snapshot(field, snapshot)
end

--- Resolves native metadata inside the owned context helper, without re-forking AT-SPI.
--- @param field table Exact requested native field receipt.
--- @param snapshot table Fresh native active-frame snapshot from this helper.
--- @return table|nil context Exact application/title and native window owner.
function M._privacy_context_from_snapshot(field, snapshot)
	if type(field) ~= "table" or type(snapshot) ~= "table" or snapshot.native_bus_name ~= field.bus or snapshot.native_object_path ~= field.path
		or snapshot.role ~= field.role then return nil end
	local info, native, pid = M.focused_process_snapshot()
	if pid == snapshot.process_id and type(info.appId) == "string" and info.appId ~= ""
		and info.windowTitle == snapshot.window_title and type(native) == "string" and native ~= "" then
		return { app_id = info.appId, title = info.windowTitle, native_identity = native }
	end
	-- A compositor can lag behind accessibility focus. Its class/title may be
	-- used only for the same native process and frame; disagreement retains the
	-- helper's exact active owner, never the outgoing application's policy.
	return { app_id = snapshot.app_id, title = snapshot.window_title,
		native_identity = "atspi:" .. snapshot.window_bus_name .. ":" .. snapshot.window_object_path }
end

--- Starts one owned context capture without blocking the daemon's native event loop.
--- @param field table Exact requested native field receipt.
--- @param options table Owner and current-generation authorization callback.
--- @param callback function Receives context or nil only after physical retirement.
--- @return table|nil operation Owned process cleanup obligation.
function M.start_privacy_context(field, options, callback)
	return require("adapters.atspi_focus").start_context_capture(field, options, callback)
end

--- Captures the exact active text control for asynchronous AI input and output.
--- A native window ID cannot distinguish controls within the same window.
--- Each call uses one fresh bounded accessibility probe; cached or unavailable
--- evidence, password controls and inactive scopes never authorize text.
--- @return string|nil Unique native accessibility bus/object identity.
function M.focused_text_identity()
	local captured, destination = pcall(function()
		return require("adapters.user_hotstring_destination").capture_current()
	end)
	if not captured or not destination then return nil end
	return "atspi:" .. destination.bus .. ":" .. destination.path
end

--- Returns the current native window identity for asynchronous output targeting.
--- Application names and titles cannot distinguish two windows of the same app.
--- This driver-only API matches macOS; unsupported compositors return nil.
--- @return string|nil Native server/process/window identity.
function M.focused_identity()
	local ok, _, identity = pcall(query_focused)
	if not ok then
		Logger.error(LOG, "focused_identity(): native focus query failed.")
		return nil
	end
	if identity == nil and DisplayServer.is_wayland() then
		-- GNOME and KDE expose no compositor window ID. Their accessible control
		-- still has an exact native destination; labels never substitute for it.
		local captured, destination = pcall(function()
			return require("adapters.user_hotstring_destination").capture_current()
		end)
		if captured and destination then identity = "atspi:" .. destination.bus .. ":" .. destination.path end
	end
	return identity
end

--- Returns an array of WindowInfo tables for all currently visible windows.
--- @return table Array of WindowInfo objects (may be empty).
function M.getAll()
	local ok, infos = pcall(function()
		if DisplayServer.is_x11() then return all_x11() end
		-- No compositor in the list above exposes a stable enumeration of every
		-- window with its identity, and inventing a partial one would make an
		-- empty result indistinguishable from an incomplete one.
		return {}
	end)

	if not ok then
		Logger.error(LOG, "getAll(): unexpected error — %s", tostring(infos))
		return {}
	end
	return infos or {}
end

--- Test seam: clears the once-only unsupported-compositor warning and the X11
--- identity cache, so consecutive cases cannot inherit each other's answers.
function M._reset_state()
	_reported_unsupported = false
	_reported_no_window_list = false
	_read_proc_comm = read_proc_comm
	_x11_cache.id = nil
	_x11_cache.title = nil
	_x11_cache.appId = ""
	_x11_cache.identity = nil
	_x11_cache.pid = nil
end

--- Test seam: replaces the /proc process-name reader until the next reset.
--- @param reader function pid -> string
function M._set_proc_comm_reader_for_test(reader)
	_read_proc_comm = reader
end

return M
