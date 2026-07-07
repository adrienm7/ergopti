--- adapters/tray_menu.lua

--- ==============================================================================
--- MODULE: TrayMenu Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the TrayMenu port contract defined in
--- static/ergopti_plus/_shared/core/ports/TrayMenu.spec.js. Wraps a yad
--- --notification subprocess (a GTK+ systray icon with a right-click menu)
--- to expose a platform-agnostic interface (setIcon, setMenu, setTooltip,
--- destroy) for desktop-environment tray icons.
---
--- FEATURES & RATIONALE:
--- 1. yad backend: yad --notification creates a StatusNotifierItem / XEmbed
---    tray icon that works on KDE, GNOME (X11), XFCE, and most compositors.
---    Wayland support depends on XWayland; pure Wayland may need
---    libappindicator fallback in a future version.
--- 2. Menu serialization: setMenu items are serialized into yad's proprietary
---    menu format (title!bash -c 'command') and piped to the existing yad
---    process via a FIFO or relaunch.
--- 3. Lazy creation: the tray process is spawned on the first setIcon or
---    setMenu call, not at module load time.
--- 4. Robust teardown: destroy() kills the yad subprocess and cleans up.
---    If yad is not installed, all methods are silent no-ops.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "adapters.tray_menu"


-- =========================================
-- =========================================
-- ======= 1/ Internal State ===============
-- =========================================
-- =========================================

-- PID of the yad subprocess (nil when not running).
local _pid       = nil

-- Pipe handle for the yad subprocess (so we can send menu updates).
local _pipe      = nil

-- Cached menu items for relaunch on update.
local _items     = {}

-- Cached icon path.
local _image     = nil

-- Cached tooltip text.
local _tooltip   = nil

-- Whether yad is available on this system (checked once).
local _yad_available = nil


-- =========================================
-- =========================================
-- ======= 2/ Helpers ======================
-- =========================================
-- =========================================

--- Checks once whether yad is installed.
local function _check_yad()
	if _yad_available ~= nil then return _yad_available end
	local ok = os.execute("which yad >/dev/null 2>&1")
	_yad_available = (ok == true or ok == 0)
	if not _yad_available then
		Logger.warn(LOG, "yad is not installed — tray menu unavailable.")
		Logger.warn(LOG, "  Install: sudo apt-get install yad")
	end
	return _yad_available
end

--- Serializes menu items into yad's --menu format.
--- Format: "Title!bash -c 'cmd'!Title2!bash -c 'cmd2'"
--- @param items table Array of { title, fn, checked?, disabled? }
--- @return string
local function _serialize_menu(items)
	if type(items) ~= "table" or #items == 0 then
		return "ergopti!bash -c 'echo ergopti'"
	end

	local parts = {}
	for _, item in ipairs(items) do
		if type(item) == "table" and type(item.title) == "string" then
			-- Build a shell command to invoke the Lua callback.
			-- We write the callback index to a temp file and signal the daemon.
			-- For now, we pass a simple bash no-op as placeholder.
			parts[#parts + 1] = item.title:gsub("!", "!!")
			if type(item.fn) == "function" then
				-- Store the function reference in a registry so we can call it later.
				_registry[#_registry + 1] = item.fn
				local idx = #_registry
				parts[#parts + 1] = string.format(
					"bash -c 'echo \"MENU:%d\" > %s'",
					idx,
					(_signal_file or "/dev/null")
				)
			else
				parts[#parts + 1] = "bash -c 'true'"
			end
		end
	end
	return table.concat(parts, "!")
end

-- Registry of callback functions, indexed by menu position.
local _registry = {}

-- Signal file path for menu callbacks.
local _signal_file = nil


--- Builds the full yad command line from current state.
--- @return string
local function _build_yad_cmd()
	local parts = {
		"yad",
		"--notification",
		"--no-middle",
	}

	if _image then
		parts[#parts + 1] = "--image=" .. _image
	else
		parts[#parts + 1] = "--image=ergopti"
	end

	if _tooltip then
		local safe_tip = _tooltip:gsub("'", "'\\''")
		parts[#parts + 1] = "--text=" .. safe_tip
	end

	-- Menu items.
	local menu_str = _serialize_menu(_items)
	parts[#parts + 1] = "--menu=" .. menu_str

	return table.concat(parts, " ")
end

--- Kills the yad subprocess.
local function _kill_yad()
	if _pipe then
		pcall(function() _pipe:close() end)
		_pipe = nil
	end
	if _pid then
		-- Send SIGTERM to the yad process group.
		os.execute(string.format("kill %d 2>/dev/null", _pid))
		_pid = nil
	end
end

--- Spawns or respawns the yad subprocess.
local function _spawn_yad()
	if not _check_yad() then return false end

	-- Kill any existing process first.
	_kill_yad()

	-- Create the signal file in a temp directory.
	if not _signal_file then
		_signal_file = os.tmpname and os.tmpname() or "/tmp/ergopti_tray_" .. tostring(os.time())
		-- os.tmpname() creates a file — we remove it and use it as a path stem
		os.remove(_signal_file)
		_signal_file = _signal_file .. ".signal"
	end

	local cmd = _build_yad_cmd()
	Logger.debug(LOG, "Spawning yad: %s", cmd)

	-- Launch yad in the background and capture its PID.
	-- The trailing & runs yad asynchronously; $! gives its PID.
	local launch = string.format("%s & echo $!", cmd)
	local pipe = io.popen(launch, "r")
	if not pipe then
		Logger.error(LOG, "_spawn_yad(): io.popen failed.")
		return false
	end

	local pid_str = pipe:read("*l")
	pipe:close()
	_pid = tonumber(pid_str)
	if not _pid then
		Logger.error(LOG, "_spawn_yad(): could not read PID.")
		return false
	end

	Logger.success(LOG, "yad tray icon spawned (pid=%d).", _pid)
	return true
end


-- =========================================
-- =========================================
-- ======= 3/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Sets the tray icon.
--- @param opts table { image?, title? }
---              image  string  Path to a PNG/SVG file used as the tray icon.
---              title  string  Text label shown beside the icon.
function M.setIcon(opts)
	local options = type(opts) == "table" and opts or {}
	if type(options.image) == "string" then
		_image = options.image
	end
	if type(options.title) == "string" then
		_tooltip = options.title
	end
	-- (Re)launch yad with the new icon.
	_spawn_yad()
end

--- Replaces the drop-down menu items.
--- @param items table Array of { title, fn, checked?, disabled? } entries.
function M.setMenu(items)
	if type(items) ~= "table" then return end
	_items = items
	_registry = {}  -- Clear old callbacks
	-- Relaunch yad with the new menu (restarting is simpler than updating in-place).
	_spawn_yad()
end

--- Sets the tooltip shown on hover.
--- @param text string Tooltip text.
function M.setTooltip(text)
	_tooltip = tostring(text or "")
	-- Relaunch to apply tooltip change.
	if _pid then _spawn_yad() end
end

--- Removes and destroys the tray icon. Safe to call multiple times.
function M.destroy()
	_kill_yad()
	-- Clean up the signal file on disk.
	if _signal_file then
		os.remove(_signal_file)
	end
	_signal_file = nil
	Logger.debug(LOG, "destroy(): tray icon released.")
end

--- Pumps the signal file for menu callbacks. Should be called from the event loop.
--- Reads the signal file, invokes the registered callback, and truncates the file.
function M.pump()
	if not _signal_file then return end
	local fh = io.open(_signal_file, "r")
	if not fh then return end
	local content = fh:read("*a")
	fh:close()

	if not content or content == "" then return end

	-- Parse MENU:N lines.
	for idx_str in content:gmatch("MENU:(%d+)") do
		local idx = tonumber(idx_str)
		if idx and _registry[idx] and type(_registry[idx]) == "function" then
			pcall(_registry[idx])
		end
	end

	-- Clear the signal file.
	local fh2 = io.open(_signal_file, "w")
	if fh2 then fh2:close() end
end

return M
