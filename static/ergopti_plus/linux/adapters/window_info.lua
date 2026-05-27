--- static/ergopti_plus/linux/adapters/window_info.lua

--- ==============================================================================
--- MODULE: WindowInfo Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the WindowInfo port contract defined in
--- static/ergopti_plus/shared/ports/WindowInfo.spec.js. Wraps the X11/Wayland
--- window stack (via xdotool or xprop on X11, or ydotool/swaymsg on Wayland)
--- behind the two canonical methods (getFocused, getAll) so domain modules
--- can query the focused window without coupling to any display-server API.
---
--- FEATURES & RATIONALE:
--- 1. Fail-safe returns: getFocused() always returns a WindowInfo table, never
---    nil — all fields default to "" when the focused window cannot be queried
---    (Wayland sandbox, permission denied, no DISPLAY).
--- 2. X11 primary path: xdotool getactivewindow + getwindowname is the most
---    portable X11 approach; it works on all major compositors (Openbox, XFCE,
---    KDE on X11, GNOME on X11).
--- 3. Wayland fallback: swaymsg -t get_tree is queried when $WAYLAND_DISPLAY
---    is set and xdotool fails, providing basic support for Sway / wlroots.
--- 4. Defensive pcall: io.popen can raise; every OS call is wrapped.
--- ==============================================================================

local M = {}

local Logger = require("lib.logger")

local LOG = "adapters.window_info"


-- =========================================
-- =========================================
-- ======= 1/ Internal Helpers =============
-- =========================================
-- =========================================

--- Returns an empty WindowInfo table (all fields "").
local function empty_info()
	return { appId = "", windowTitle = "", bundleId = "", executablePath = "" }
end

--- Runs a shell command and returns its trimmed stdout, or nil on failure.
--- @param cmd string Shell command to execute.
--- @return string|nil Command output or nil.
local function shell_read(cmd)
	local ok, result = pcall(function()
		local pipe = io.popen(cmd .. " 2>/dev/null")
		if not pipe then return nil end
		local out = pipe:read("*l")
		pipe:close()
		return out and out:match("^%s*(.-)%s*$") or nil
	end)
	return ok and result or nil
end


-- =========================================
-- =========================================
-- ======= 2/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Returns the identity of the currently focused window.
--- @return table WindowInfo: { appId, windowTitle, bundleId, executablePath }
function M.getFocused()
	-- TODO(linux): implement full X11/Wayland path using xdotool or swaymsg
	local info = empty_info()

	local ok, err = pcall(function()
		-- X11 path: use xdotool to retrieve window ID and name.
		local win_id = shell_read("xdotool getactivewindow")
		if win_id then
			local title = shell_read("xdotool getwindowname " .. win_id)
			if title then info.windowTitle = title end

			-- Retrieve the owning process name via /proc/<pid>/comm.
			local pid = shell_read("xdotool getwindowpid " .. win_id)
			if pid then
				local comm = shell_read("cat /proc/" .. pid .. "/comm")
				if comm then info.appId = comm end
				local exe = shell_read("readlink -f /proc/" .. pid .. "/exe")
				if exe then info.executablePath = exe end
			end
		end
	end)

	if not ok then
		Logger.error(LOG, "getFocused(): unexpected error — %s", tostring(err))
		return empty_info()
	end
	return info
end

--- Returns an array of WindowInfo tables for all currently visible windows.
--- @return table Array of WindowInfo objects (may be empty).
function M.getAll()
	-- TODO(linux): implement using xdotool search --onlyvisible or swaymsg -t get_tree
	local infos = {}

	local ok, err = pcall(function()
		-- X11 path: list all visible window IDs and build WindowInfo for each.
		local pipe = io.popen("xdotool search --onlyvisible --name '' 2>/dev/null")
		if not pipe then return end
		for win_id in pipe:lines() do
			win_id = win_id:match("^%s*(.-)%s*$")
			if win_id and win_id ~= "" then
				local entry = empty_info()
				local title = shell_read("xdotool getwindowname " .. win_id)
				if title then entry.windowTitle = title end
				infos[#infos + 1] = entry
			end
		end
		pipe:close()
	end)

	if not ok then
		Logger.error(LOG, "getAll(): unexpected error — %s", tostring(err))
		return {}
	end
	return infos
end

return M
