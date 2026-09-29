--- modules/gestures/workspace_switcher.lua

--- ==============================================================================
--- MODULE: Workspace Switcher (Linux)
--- DESCRIPTION:
--- Runs desktop_prev / desktop_next, which stop at the first and the last
--- workspace, and desktop_prev_wrap / desktop_next_wrap, which go on to the
--- other end, on whatever interface the session lets another process drive.
---
--- WHY ONE BACKEND PER DESKTOP:
--- No protocol lets a process read and pick a workspace on every Linux desktop:
---   - X11: every EWMH window manager answers wmctrl (`-d` lists the desktops
---     with the current one marked `*`, `-s` switches to one by number). KDE
---     Plasma on X11 answers it too.
---   - KDE Plasma on Wayland answers KWin's D-Bus interface: the current
---     desktop and its setter on /KWin, the desktop count on
---     /VirtualDesktopManager.
---   - sway answers swaymsg and Hyprland answers hyprctl. Their workspaces are
---     created on demand, so the row is the workspaces that exist on the
---     focused output, in the compositor's own order.
---   - GNOME on Wayland exposes nothing: its workspaces follow its own shortcut
---     only. The plain actions press that shortcut (Ctrl+Alt+Left or Right),
---     which stops at the edges as the plain actions do. The wrapping ones
---     cannot know where the edge is, so the picker greys them through the
---     "session:workspaces" requirement, and a binding made elsewhere logs why
---     it moved one workspace without wrapping.
---
--- FEATURES & RATIONALE:
--- 1. One rule: where a step lands comes from _shared/lua/desktop_navigation,
---    the rule the macOS and Windows drivers use, pinned by a shared corpus.
--- 2. A query that fails is reported, never read as "workspace 0": the action
---    then presses the desktop's own shortcut, which is the plain step. A
---    switch refused after a good read walks to the target with that shortcut.
--- 3. Every tool call is bounded by `timeout`: the daemon waits for it while
---    it holds the keyboard, so a hung display server must cost a second, not
---    the keyboard.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Shell = require("adapters.shell_runner")
local DisplayServer = require("infra.display_server")
local DesktopNavigation = require("desktop_navigation")
local json = require("json")

local LOG = "modules.gestures.workspace_switcher"

-- Seconds each tool call may take (see FEATURES 3).
local TOOL_TIMEOUT_S = 1

-- The combination the desktops bind to the previous and the next workspace,
-- pressed when no interface can switch. Under Wayland it is the only way
-- another process can on a desktop with no interface.
M.COMBO = {
	[DesktopNavigation.PREVIOUS] = "ctrl+alt+Left",
	[DesktopNavigation.NEXT] = "ctrl+alt+Right",
}

-- KWin's D-Bus client is packaged under several names: Qt 6 builds of Plasma
-- ship qdbus6 (Arch, KDE neon) or qdbus-qt6 (Fedora), Qt 5 ones qdbus or
-- qdbus-qt5. The first one on the PATH is used.
local QDBUS_BINARIES = { "qdbus6", "qdbus-qt6", "qdbus", "qdbus-qt5" }




-- =========================================
-- =========================================
-- ======= 1/ Reading tool output ==========
-- =========================================
-- =========================================

--- Runs one bounded query and returns its output, raising when it fails.
--- @param cmd string The tool invocation, without the timeout prefix.
--- @return string output
local function query(cmd)
	local ok, output, err = Shell.exec_checked("timeout " .. TOOL_TIMEOUT_S .. " " .. cmd .. " 2>/dev/null")
	if not ok then error(cmd .. " failed: " .. tostring(err), 0) end
	return output
end

--- Runs one bounded switch command.
--- @param cmd string The tool invocation, without the timeout prefix.
--- @return boolean switched
local function run(cmd)
	return Shell.run("timeout " .. TOOL_TIMEOUT_S .. " " .. cmd .. " >/dev/null 2>&1")
end

--- Decodes a JSON answer, raising on anything that is not the expected shape.
--- @param text string
--- @param what string What the answer describes, for the error.
--- @return table
local function decode(text, what)
	local ok, value = pcall(json.decode, text)
	if not ok or type(value) ~= "table" then
		error(what .. " is not JSON: " .. tostring(ok and text or value), 0)
	end
	return value
end

--- Parses `wmctrl -d`: one line per desktop, its number first and `*` on the
--- current one ("0  * DG: 1920x1080  VP: 0,0 ...").
--- @param text string
--- @return table state { ids = {desktop numbers...}, index = 0-based current }
function M.parse_wmctrl(text)
	local ids, index = {}, nil
	for line in tostring(text):gmatch("[^\n]+") do
		local id, mark = line:match("^%s*(%d+)%s+([%*%-])")
		if not id then error("unexpected wmctrl -d line: " .. line, 0) end
		ids[#ids + 1] = id
		if mark == "*" then
			if index then error("wmctrl -d marks two current desktops", 0) end
			index = #ids - 1
		end
	end
	if #ids == 0 then error("wmctrl -d listed no desktop", 0) end
	if not index then error("wmctrl -d marks no current desktop", 0) end
	return { ids = ids, index = index }
end

--- Builds the KWin state from its current desktop (1-based) and its count.
--- @param current_text string
--- @param count_text string
--- @return table state { ids = {1..count}, index = 0-based current }
function M.parse_kwin(current_text, count_text)
	local current = tonumber(tostring(current_text):match("^%s*(%d+)%s*$"))
	local count = tonumber(tostring(count_text):match("^%s*(%d+)%s*$"))
	if not current or not count then
		error("KWin answered '" .. tostring(current_text) .. "' / '" .. tostring(count_text) .. "'", 0)
	end
	if count < 1 or current < 1 or current > count then
		error("KWin's current desktop " .. current .. " is outside its " .. count .. " desktop(s)", 0)
	end
	local ids = {}
	for n = 1, count do ids[n] = n end
	return { ids = ids, index = current - 1 }
end

--- Builds the sway state: the workspaces of the focused workspace's output,
--- in the order get_workspaces lists them.
--- @param workspaces table Decoded `swaymsg -t get_workspaces`.
--- @return table state { ids = {names...}, index = 0-based current }
function M.parse_sway(workspaces)
	local focused = nil
	for _, workspace in ipairs(workspaces) do
		if workspace.focused == true then focused = workspace end
	end
	if not focused then error("sway reports no focused workspace", 0) end
	local ids, index = {}, nil
	for _, workspace in ipairs(workspaces) do
		if workspace.output == focused.output then
			if type(workspace.name) ~= "string" or workspace.name == "" then
				error("sway reports a workspace without a name", 0)
			end
			ids[#ids + 1] = workspace.name
			if workspace == focused then index = #ids - 1 end
		end
	end
	return { ids = ids, index = index }
end

--- Builds the Hyprland state: the regular workspaces of the active
--- workspace's monitor, by id (special workspaces have negative ids).
--- @param active table Decoded `hyprctl -j activeworkspace`.
--- @param workspaces table Decoded `hyprctl -j workspaces`.
--- @return table state { ids = {ids...}, index = 0-based current }
function M.parse_hyprland(active, workspaces)
	if type(active.id) ~= "number" or type(active.monitor) ~= "string" then
		error("Hyprland reports no active workspace", 0)
	end
	local ids = {}
	for _, workspace in ipairs(workspaces) do
		if workspace.monitor == active.monitor and type(workspace.id) == "number" and workspace.id > 0 then
			ids[#ids + 1] = workspace.id
		end
	end
	table.sort(ids)
	local index = nil
	for position, id in ipairs(ids) do
		if id == active.id then index = position - 1 end
	end
	if not index then error("Hyprland's active workspace " .. active.id .. " is not a listed one", 0) end
	return { ids = ids, index = index }
end

--- Quotes a sway workspace name for sway's own command parser.
--- @param name string
--- @return string
local function sway_quoted(name)
	local escaped = name:gsub("\\", "\\\\")
	escaped = escaped:gsub('"', '\\"')
	return '"' .. escaped .. '"'
end




-- =========================================
-- =========================================
-- ======= 2/ Backends =====================
-- =========================================
-- =========================================

local BACKENDS = {
	wmctrl = {
		name = "wmctrl",
		read = function() return M.parse_wmctrl(query("wmctrl -d")) end,
		switch = function(_, id) return run("wmctrl -s " .. Shell.quote(id)) end,
	},
	kwin = {
		name = "KWin",
		read = function(backend)
			local qdbus = backend.binary
			return M.parse_kwin(
				query(qdbus .. " org.kde.KWin /KWin org.kde.KWin.currentDesktop"),
				query(qdbus .. " org.kde.KWin /VirtualDesktopManager org.kde.KWin.VirtualDesktopManager.count"))
		end,
		switch = function(backend, id)
			return run(backend.binary .. " org.kde.KWin /KWin org.kde.KWin.setCurrentDesktop " .. Shell.quote(id))
		end,
	},
	sway = {
		name = "sway",
		read = function()
			return M.parse_sway(decode(query("swaymsg -t get_workspaces -r"), "swaymsg -t get_workspaces"))
		end,
		switch = function(_, id)
			return run("swaymsg -- " .. Shell.quote("workspace " .. sway_quoted(id)))
		end,
	},
	hyprland = {
		name = "Hyprland",
		read = function()
			return M.parse_hyprland(
				decode(query("hyprctl -j activeworkspace"), "hyprctl activeworkspace"),
				decode(query("hyprctl -j workspaces"), "hyprctl workspaces"))
		end,
		switch = function(_, id) return run("hyprctl dispatch workspace " .. Shell.quote(tostring(id))) end,
	},
}

--- Reads an environment variable, treating empty as absent.
--- @param name string
--- @return string|nil
local function env(name)
	local value = os.getenv(name)
	if type(value) ~= "string" or value == "" then return nil end
	return value
end

--- The backend this session answers.
--- @return table|nil backend { name, read, switch, binary? } or nil.
--- @return string|nil reason When nil: "tool:<binary>" for a missing tool,
---   "unsupported" for a session with no workspace interface, "unknown" when
---   the session could not be identified.
function M.detect()
	local kind = DisplayServer.kind()
	if kind == DisplayServer.X11 then
		if Shell.has_command("wmctrl") then return BACKENDS.wmctrl, nil end
		return nil, "tool:wmctrl"
	end
	if kind ~= DisplayServer.WAYLAND then return nil, "unknown" end
	if env("HYPRLAND_INSTANCE_SIGNATURE") or DisplayServer.desktop_is("hyprland") then
		if Shell.has_command("hyprctl") then return BACKENDS.hyprland, nil end
		return nil, "tool:hyprctl"
	end
	if env("SWAYSOCK") or DisplayServer.desktop_is("sway") then
		if Shell.has_command("swaymsg") then return BACKENDS.sway, nil end
		return nil, "tool:swaymsg"
	end
	if DisplayServer.desktop_is("kde") then
		for _, binary in ipairs(QDBUS_BINARIES) do
			if Shell.has_command(binary) then
				return setmetatable({ binary = binary }, { __index = BACKENDS.kwin }), nil
			end
		end
		return nil, "tool:qdbus"
	end
	return nil, "unsupported"
end




-- =========================================
-- =========================================
-- ======= 3/ Switching ====================
-- =========================================
-- =========================================

--- Moves one workspace in a direction.
--- @param direction string DesktopNavigation.PREVIOUS or .NEXT.
--- @param wrap boolean True to go on to the other end from an edge.
--- @param press_combo function Presses one xdotool-style combination.
--- @return string outcome "switched", "stayed" or "pressed".
function M.switch(direction, wrap, press_combo)
	if M.COMBO[direction] == nil then
		error("workspace_switcher: unknown direction '" .. tostring(direction) .. "'", 2)
	end
	if type(wrap) ~= "boolean" or type(press_combo) ~= "function" then
		error("workspace_switcher: switch needs a boolean wrap and a combo presser", 2)
	end
	local backend, reason = M.detect()
	if backend then
		local ok, result = pcall(function()
			local state = backend:read()
			local target = DesktopNavigation.target(state.index, #state.ids, direction, wrap)
			return { state = state, target = target }
		end)
		if ok then
			local state, target = result.state, result.target
			if target == state.index then
				Logger.debug(LOG, "Workspace %d of %d is an edge — the %s step stays.",
					state.index + 1, #state.ids, wrap and "wrapping" or "plain")
				return "stayed"
			end
			if backend:switch(state.ids[target + 1]) then
				Logger.debug(LOG, "%s switched from workspace %d to %d of %d.",
					backend.name, state.index + 1, target + 1, #state.ids)
				return "switched"
			end
			-- The position is known, so walk to the target as the macOS and
			-- Windows drivers do: a wrap from an edge is several steps the
			-- other way, and one press in the requested direction would run
			-- into the edge.
			local steps = target - state.index
			local combo = M.COMBO[steps > 0 and DesktopNavigation.NEXT or DesktopNavigation.PREVIOUS]
			Logger.warn(LOG, "%s refused to switch to workspace %d — pressing %s %d time(s) instead.",
				backend.name, target + 1, combo, math.abs(steps))
			for _ = 1, math.abs(steps) do press_combo(combo) end
			return "pressed"
		else
			Logger.warn(LOG, "%s could not list the workspaces (%s) — pressing %s instead.",
				backend.name, tostring(result), M.COMBO[direction])
		end
	elseif wrap then
		Logger.warn(LOG, "This session cannot list its workspaces (%s) — moving one workspace "
			.. "without wrapping.", tostring(reason))
	end
	press_combo(M.COMBO[direction])
	return "pressed"
end

return M
