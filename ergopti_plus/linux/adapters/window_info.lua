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

-- Last X11 answer, so the steady state costs one subprocess per poll instead of
-- three. The caller polls four times a second and the answer changes a few times
-- a minute; resolving the application identity every time would be twelve
-- subprocesses a second to learn nothing.
local _x11_cache = { title = nil, appId = "" }




-- =========================================
-- =========================================
-- ======= 2/ X11 ==========================
-- =========================================
-- =========================================

--- Queries the focused window through xdotool.
---
--- The title is the change signal, not the window id. A window id changes when
--- the user switches windows, and NOT when a browser switches to a private tab —
--- which is precisely the transition the password-suppression feature exists to
--- notice, and precisely the one the previous implementation could not see.
--- xdotool chains both commands in one invocation, so the cheap probe and the
--- signal are the same subprocess.
--- @return table|nil WindowInfo, or nil when the query produced nothing.
local function focused_x11()
	local title = Shell.exec_line("xdotool getactivewindow getwindowname 2>/dev/null")
	if not title then return nil end

	local info = empty_info()
	info.windowTitle = title

	if title == _x11_cache.title then
		info.appId = _x11_cache.appId
		return info
	end

	-- The identity is the process name, deliberately, and not WM_CLASS. It is
	-- what this driver has always reported, what the keystroke metrics are
	-- already attributed to, and what the other two drivers report; WM_CLASS
	-- would be a nicer identity and a silent break of every stored attribution.
	local win_id = Shell.exec_line("xdotool getactivewindow 2>/dev/null")
	local pid = win_id and Shell.exec_line(
		"xdotool getwindowpid " .. Shell.quote(win_id) .. " 2>/dev/null") or nil
	info.appId = comm_of(pid)

	_x11_cache.title = title
	_x11_cache.appId = info.appId
	return info
end

--- Lists every visible window through xdotool.
--- @return table Array of WindowInfo.
local function all_x11()
	local infos = {}
	local out = Shell.exec("xdotool search --onlyvisible --name '' 2>/dev/null")
	for win_id in out:gmatch("[^\r\n]+") do
		local id = win_id:match("^%s*(.-)%s*$")
		if id ~= "" then
			local entry = empty_info()
			local title = Shell.exec_line("xdotool getwindowname " .. Shell.quote(id) .. " 2>/dev/null")
			if title then entry.windowTitle = title end
			infos[#infos + 1] = entry
		end
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
	return info
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
	return info
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
	return info
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
			local info = backend.query()
			if info then return info end
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

--- Returns the identity of the currently focused window.
--- Every field is "" when the session cannot answer; the table is never nil.
--- @return table WindowInfo: { appId, windowTitle, bundleId, executablePath }
function M.getFocused()
	local ok, info = pcall(function()
		if DisplayServer.is_wayland() then
			-- XWayland is deliberately not tried as a fallback here. It answers for
			-- X11 clients only, so a session would silently report identities for
			-- some windows and nothing for others — worse than a uniform "unknown",
			-- because a rule that works on half a desktop looks like a flaky rule.
			return focused_wayland()
		end
		if DisplayServer.is_x11() then
			return focused_x11()
		end
		return nil
	end)

	if not ok then
		Logger.error(LOG, "getFocused(): unexpected error — %s", tostring(info))
		return empty_info()
	end
	return info or empty_info()
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
	_x11_cache.title = nil
	_x11_cache.appId = ""
end

return M
