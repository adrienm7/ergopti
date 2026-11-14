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
---   - every compositor with wlr-foreign-toplevel-management (labwc, Wayfire,
---     river and the other wlroots ones) answers through `lswt -j`, whose
---     listing marks the activated toplevel.
---   - GNOME removed Shell.Eval in 41 and admits its Introspect interface to
---     allow-listed senders only, and KDE answers only a loaded KWin script:
---     the Ergopti Shell extension and KWin script (linux/desktop_focus/) push
---     every focus change to a session-bus name the daemon owns
---     (adapters/compositor_focus), read here from memory, without a fork.
---   - COSMIC's own toplevel protocol needs a native Wayland client, and
---     ext-foreign-toplevel-list carries no activation state; Weston exposes
---     nothing. Those stay unknown.
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

local Logger = require("core.logger.engine.shim")
local Shell = require("core.process.adapters.shell_runner")
local DisplayServer = require("infra.display_server")
local X11Focus = require("adapters.x11_focus")

local LOG = "adapters.window_info"

-- Compositors that answer a focused-window query, and how to ask. Order is
-- deliberate: the probe tries each in turn, so a session running more than one
-- IPC socket resolves the same way every time rather than by chance.
local WAYLAND_BACKENDS = { "sway", "hyprland", "niri", "wlr_toplevel" }

-- Set once when no query interface exists, so the log states the limitation
-- rather than repeating it on every keystroke's context refresh.
local _reported_unsupported = false

-- Set once when wmctrl is missing, for the same reason.
local _reported_no_window_list = false

-- The /proc process-name reader getAll() uses; a test seam replaces it.
local _read_proc_comm = nil

-- The GNOME Shell or KWin focus source, when this session started one
-- (start_compositor_focus); it then owns the Wayland answer.
local _compositor_focus = nil




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

--- Compositor text fields may be JSON null; never turn its sentinel into an
--- application identity or window title.
local function text_field(value)
	return type(value) == "string" and value or ""
end

--- Decodes JSON, returning nil rather than raising on anything unexpected.
--- @param raw string
--- @return table|nil
local function decode_json(raw)
	if type(raw) ~= "string" or raw == "" then return nil end
	local ok_mod, json = pcall(require, "core.text.engine.json")
	if not ok_mod or type(json) ~= "table" or type(json.decode) ~= "function" then
		Logger.warn(LOG, "No JSON decoder — the compositor query cannot be read.")
		return nil
	end
	local ok, value = pcall(json.decode, raw)
	if not ok or type(value) ~= "table" then return nil end
	return value
end

--- Removes only the record delimiter appended by procfs to a kernel task name.
--- @param record string Raw /proc/<pid>/comm bytes.
--- @return string name Exact native task-name payload.
local function process_name_record(record)
	return (record:gsub("\n$", ""))
end

--- Reads the process name for a PID, or "" when it cannot be read.
--- @param pid string|number|nil
--- @return string
local function comm_of(pid)
	if type(pid) ~= "string" and type(pid) ~= "number" then return "" end
	local literal = tostring(pid)
	local number = tonumber(literal)
	if not literal:match("^%d+$") or not number or number <= 0 or number > 2147483647 then return "" end
	local comm = Shell.exec("cat " .. Shell.quote("/proc/" .. literal .. "/comm"))
	return process_name_record(comm)
end

--- Reads a process name from /proc in this process: the window list names
--- every window, and a spawn per window froze the menu that asked for it.
--- @param pid number
--- @return string The name, or "" when the process is gone.
local function read_proc_comm(pid)
	local handle = io.open("/proc/" .. tostring(pid) .. "/comm", "rb")
	if not handle then return "" end
	local read_ok, comm = pcall(handle.read, handle, "*a")
	local close_ok, closed = pcall(handle.close, handle)
	if not read_ok or type(comm) ~= "string" or not close_ok or closed ~= true then return "" end
	return process_name_record(comm)
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
	local win_id, title, native_pid
	local native_reason
	if X11Focus.has_transport() then
		win_id, title, native_pid, native_reason = X11Focus.query()
		if native_reason == nil then
			-- The server answered, in this process: no window, or an untitled
			-- one, is no answer, exactly as an empty xdotool line was.
			if not win_id or not title then return nil end
		else
			-- Transport trouble (server unreachable): ask the tools this once,
			-- so a flaky connection degrades to the old route, not to silence.
			Logger.debug(LOG, "Native X11 focus query unavailable (%s) — using xdotool.", native_reason)
		end
	end
	if native_reason ~= nil or not X11Focus.has_transport() then
		win_id = Shell.exec_line("xdotool getactivewindow 2>/dev/null")
		if not win_id then return nil end
		title = Shell.exec_line("xdotool getwindowname " .. Shell.quote(win_id) .. " 2>/dev/null")
		if not title then return nil end
		native_pid = Shell.exec_line("xdotool getwindowpid " .. Shell.quote(win_id) .. " 2>/dev/null")
	end

	local info = empty_info()
	info.windowTitle = title

	-- The X server can reuse a window ID and title for a different process.
	-- A native query already carries its PID, so it must still match the owner
	-- behind the cached attribution (including when the property disappears).
	local same_native_owner = tonumber(native_pid) == _x11_cache.pid
	if win_id == _x11_cache.id and title == _x11_cache.title and same_native_owner and _x11_cache.appId ~= "" then
		info.appId = _x11_cache.appId
		return info, _x11_cache.identity, _x11_cache.pid
	end

	-- One identity under X11 and Wayland (ADD-3, decided by the maintainer on
	-- 2026-11-11): the WM_CLASS class, the name sway and the desktop
	-- compositors report, so an exclusion list built under one session type
	-- matches under the other. /proc/<pid>/comm is only the fallback for a
	-- window without WM_CLASS (or without the native transport): the kernel
	-- cuts it to 15 bytes (TASK_COMM_LEN 16 with its NUL), so
	-- gnome-terminal-server reads « gnome-terminal- ». Saved lists were
	-- converted once by core/lifecycle/engine/app_identity_migration.lua.
	local pid = native_pid
	local class = native_reason == nil and X11Focus.has_transport() and X11Focus.window_class(win_id) or nil
	info.appId = (type(class) == "string" and class ~= "") and class or comm_of(pid)

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

--- WindowInfo tables for a list of { title, pid, class } windows, naming each by
--- its WM_CLASS class, else its process (one /proc read per process).
--- @param windows table Array of { title, pid, class }.
--- @return table
local function infos_of_windows(windows)
	local infos, names = {}, {}
	for _, window in ipairs(windows) do
		local entry = empty_info()
		entry.windowTitle = window.title
		if type(window.class) == "string" and window.class ~= "" then
			entry.appId = window.class
		elseif window.pid and window.pid > 0 then
			if names[window.pid] == nil then names[window.pid] = _read_proc_comm(window.pid) end
			entry.appId = names[window.pid]
		end
		infos[#infos + 1] = entry
	end
	return infos
end

--- Lists every managed window from the X server (libxcb in this process, else one wmctrl query), each named by the
--- identity focused_x11() reports (WM_CLASS, else the process name read from /proc without a spawn per window):
--- the excluded-applications picker builds this list on the menu path.
--- @return table Array of WindowInfo.
local function all_x11()
	if X11Focus.has_transport() then
		-- In this process, like the focus query: no wmctrl fork, no wmctrl dependency.
		local clients, native_reason = X11Focus.clients()
		if clients then return infos_of_windows(clients) end
		Logger.debug(LOG, "Native X11 window list unavailable (%s) — using wmctrl.", tostring(native_reason))
	end
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
	return infos_of_windows(M._parse_wmctrl_list(out))
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

--- A client can emit valid JSON before failing; only acknowledged acquisition
--- may publish focus metadata. Shell owns the checked process diagnostics.
local function checked_json(command)
	local ok, output = Shell.exec_checked(command)
	if not ok then return nil end
	return decode_json(output)
end

--- Queries sway (and any wlroots compositor speaking the sway IPC).
--- @return table|nil
local function focused_sway()
	if not Shell.has_command("swaymsg") then return nil end
	local tree = checked_json("swaymsg -t get_tree 2>/dev/null")
	if not tree then return nil end
	local node = sway_focused_node(tree)
	if not node then return nil end

	local info = empty_info()
	info.windowTitle = text_field(node.name)
	-- app_id is the Wayland-native identity; window_properties.class is what an
	-- XWayland client reports instead, and mixing them up means every X11
	-- application under sway resolves to nothing.
	info.appId = text_field(node.app_id)
	if info.appId == "" and type(node.window_properties) == "table" then
		info.appId = text_field(node.window_properties.class)
	end
	if info.appId == "" then info.appId = comm_of(node.pid) end
	return info, native_identity("sway", node.id, node.pid), tonumber(node.pid)
end

--- Queries Hyprland.
--- @return table|nil
local function focused_hyprland()
	if not Shell.has_command("hyprctl") then return nil end
	local win = checked_json("hyprctl activewindow -j 2>/dev/null")
	if not win then return nil end
	local info = empty_info()
	info.windowTitle = text_field(win.title)
	info.appId = text_field(win.class)
	if info.appId == "" then info.appId = comm_of(win.pid) end
	return info, native_identity("hyprland", win.address, win.pid), tonumber(win.pid)
end

--- Queries niri.
--- @return table|nil
local function focused_niri()
	if not Shell.has_command("niri") then return nil end
	local win = checked_json("niri msg --json focused-window 2>/dev/null")
	if not win then return nil end
	local info = empty_info()
	info.windowTitle = text_field(win.title)
	info.appId = text_field(win.app_id)
	if info.appId == "" then info.appId = comm_of(win.pid) end
	return info, native_identity("niri", win.id, win.pid), tonumber(win.pid)
end

--- Queries a wlr-foreign-toplevel compositor through lswt (2.0 or later).
--- The protocol names no process, so the identity carries none. A listing
--- that cannot report activation (ext-foreign-toplevel-list alone), with no
--- or with two activated toplevels, names no focus: unknown, not a guess.
--- @return table|nil
local function focused_wlr_toplevel()
	if not Shell.has_command("lswt") then return nil end
	local listing = checked_json("lswt -j 2>/dev/null")
	if not listing or type(listing.toplevels) ~= "table" then return nil end
	local supported = type(listing["supported-data"]) == "table" and listing["supported-data"] or {}
	if supported.activated ~= true then return nil end
	local focused = nil
	for _, toplevel in ipairs(listing.toplevels) do
		if type(toplevel) == "table" and toplevel.activated == true then
			if focused then return nil end
			focused = toplevel
		end
	end
	if not focused then return nil end
	local info = empty_info()
	info.windowTitle = text_field(focused.title)
	info.appId = text_field(focused["app-id"])
	return info, native_identity("wlr-toplevel", focused.identifier, nil), nil
end

-- The identity prefix of each compositor focus family.
local COMPOSITOR_SERVERS = { gnome = "gnome", kde = "kwin", cosmic = "cosmic" }

--- Reads the focus GNOME Shell, KWin or cosmic-comp last pushed to the daemon.
--- @return table|nil info, string|nil identity, number|nil pid
local function focused_compositor()
	local window = _compositor_focus.snapshot()
	if not window then return nil end
	local info = empty_info()
	info.windowTitle = window.title
	-- The WM class is the desktop's own application identity, as app_id is
	-- under sway; a window without one is named by its process, read in this
	-- process (the poll runs four times a second).
	info.appId = window.class
	if info.appId == "" and window.pid then info.appId = _read_proc_comm(window.pid) end
	local server = assert(COMPOSITOR_SERVERS[_compositor_focus.family()], "compositor focus family without an identity prefix")
	return info, native_identity(server, window.id, window.pid), window.pid
end

-- Each query probes its own client binary first and answers nil without it.
local WAYLAND_QUERIES = {
	sway         = focused_sway,
	hyprland     = focused_hyprland,
	niri         = focused_niri,
	wlr_toplevel = focused_wlr_toplevel,
}

--- Tries every Wayland backend this session might speak.
--- @return table|nil
local function focused_wayland()
	-- A started desktop source is the answer for this session, unknown
	-- included: falling through would fork the other clients on every poll
	-- for compositors that are not running. It logs its own unavailability.
	if _compositor_focus and _compositor_focus.is_active() then return focused_compositor() end
	for _, name in ipairs(WAYLAND_BACKENDS) do
		local info, identity, pid = WAYLAND_QUERIES[name]()
		if info then return info, identity, pid end
	end

	if not _reported_unsupported then
		_reported_unsupported = true
		-- Said once, and said plainly: this is a property of the compositor, not a
		-- bug to file. COSMIC and Weston offer a client no focus query, so
		-- there is nothing to fall back to and per-application rules cannot
		-- work here.
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

--- Binds the in-process X11 focus query for this daemon (instead of forking
--- xdotool four times a second). Called once at startup; a runtime without
--- libxcb keeps the xdotool route and says so.
--- @return boolean bound
function M.use_native_x11()
	local bound, reason = X11Focus.use_xcb()
	if bound then
		Logger.info(LOG, "Focus queries on X11 use libxcb in this process (no xdotool forks).")
	else
		Logger.warn(LOG, "libxcb focus queries unavailable (%s) — X11 focus keeps using xdotool.", tostring(reason))
	end
	return bound
end

--- Starts the GNOME Shell, KWin or cosmic-comp focus source for this daemon,
--- once. Only a Wayland GNOME, KDE or COSMIC session has one; elsewhere
--- nothing starts.
--- @param options table|nil Extra compositor_focus.new options (test seams).
--- @return boolean started
function M.start_compositor_focus(options)
	assert(_compositor_focus == nil, "compositor focus source already started")
	if not DisplayServer.is_wayland() then return false end
	local CompositorFocus = require("adapters.compositor_focus")
	local family = CompositorFocus.desktop_family(DisplayServer.desktop())
	if not family then return false end
	local settings = { family = family }
	for key, value in pairs(options or {}) do settings[key] = value end
	_compositor_focus = CompositorFocus.new(settings)
	return _compositor_focus.start()
end

--- Stops the focus source started by start_compositor_focus().
--- @return boolean settled
function M.stop_compositor_focus()
	if not _compositor_focus then return true end
	local settled = _compositor_focus.stop()
	if settled then _compositor_focus = nil end
	return settled
end

--- The X server readings the metrics take beside the focus: the cursor
--- position (pointer distance in screen pixels), the EWMH current desktop and
--- the focused window's geometry, state and monitor (window topology).
--- Only a native X11 session answers them; under Wayland a client reads none.
--- @return table sources { pointer = function|nil, desktop = function|nil, topology = function|nil }
function M.metrics_sources()
	if not DisplayServer.is_x11() or not X11Focus.has_transport() then return {} end
	return { pointer = X11Focus.pointer_position, desktop = X11Focus.current_desktop,
		topology = X11Focus.active_topology }
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
		-- No compositor window ID here (COSMIC, or GNOME and KDE before their
		-- Ergopti integration reports). The accessible control
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
	_compositor_focus = nil
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
