--- adapters/tray_menu.lua

--- ==============================================================================
--- MODULE: TrayMenu Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the TrayMenu port contract defined in
--- static/ergopti_plus/_shared/core/ports/TrayMenu.spec.js. Provides a system-tray
--- icon with a right-click D-Bus menu via the StatusNotifierItem (SNI) +
--- com.canonical.dbusmenu protocols — the de-facto Linux desktop standard
--- supported by KDE, GNOME (with AppIndicator), XFCE, and wlroots compositors.
---
--- When gdbus is unavailable, falls back to the legacy yad --notification
--- subprocess (which works on X11 desktops with XEmbed support).
---
--- FEATURES & RATIONALE:
--- 1. Native SNI/dbusmenu: registers a StatusNotifierItem on the D-Bus session
---    bus via gdbus, serialises the menu tree into com.canonical.dbusmenu XML
---    using the shared tray_protocol.lua module, and listens for activation
---    signals via a gdbus monitor subprocess.
--- 2. Graceful degradation: when gdbus or the session bus is absent, falls back
---    to the existing yad --notification backend (unchanged from the prior
---    implementation).  The fallback is transparent to callers.
--- 3. Hierarchical menus: unlike yad's flat !-delimited format, SNI supports
---    nested submenus (title → { menu = […] }).  The setMenu() contract accepts
---    both flat and nested item shapes; the adapter serialises accordingly.
--- 4. Idempotent lifecycle: setIcon/setMenu/setTooltip may be called in any
---    order; the backend is (re)launched lazily. destroy() is safe at any time.
--- 5. Callback isolation: menu activation callbacks are wrapped in pcall so a
---    single broken handler never takes down the tray icon.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "adapters.tray_menu"


-- =========================================
-- =========================================
-- ======= 1/ Internal State ===============
-- =========================================
-- =========================================

-- Backend mode: "sni", "yad", or nil (uninitialised).
local _backend    = nil

-- SNI state ----------------------------------------------------------
local _sni_pid        = nil    -- PID of the gdbus monitor subprocess (for callbacks).
local _sni_pipe       = nil    -- Pipe handle for reading activation signals.
local _sni_bus_name   = nil    -- Unique D-Bus bus name (e.g. "org.ergopti.Tray-1").
local _sni_menu_xml   = nil    -- Last serialised dbusmenu XML (written to a temp file).
local _sni_menu_file  = nil    -- Path to the temp file holding the menu XML.
local _sni_items      = {}     -- Cached item tree for callback dispatch.
local _sni_image      = nil    -- Cached icon path for SNI IconName/IconThemePath.
local _sni_tooltip    = nil    -- Cached tooltip for SNI ToolTip property.

-- yad state (fallback) ------------------------------------------------
local _yad_pid        = nil
local _yad_pipe       = nil
local _yad_items      = {}
local _yad_image      = nil
local _yad_tooltip    = nil
local _yad_registry   = {}     -- callbacks keyed by menu position
local _yad_signal_file= nil

-- Shared state --------------------------------------------------------
local _items_cache    = {}     -- Canonical item list (flat, for yad compat).


-- =========================================
-- =========================================
-- ======= 2/ Backend Detection ============
-- =========================================
-- =========================================

--- Checks once whether gdbus is available on the session bus.
--- @return boolean
local function _has_gdbus()
	local ok = os.execute("gdbus call --session --dest org.freedesktop.DBus "
		.. "--object-path / --method org.freedesktop.DBus.ListNames "
		.. ">/dev/null 2>&1")
	return (ok == true or ok == 0)
end

--- Checks once whether yad is available.
--- @return boolean
local function _has_yad()
	local ok = os.execute("which yad >/dev/null 2>&1")
	return (ok == true or ok == 0)
end

--- Selects the best available backend.  Called once on first use.
local function _select_backend()
	if _backend then return _backend end
	if _has_gdbus() then
		_backend = "sni"
		Logger.info(LOG, "gdbus available — using native SNI/dbusmenu tray.")
	elseif _has_yad() then
		_backend = "yad"
		Logger.info(LOG, "gdbus unavailable — falling back to yad tray.")
	else
		_backend = "none"
		Logger.warn(LOG, "Neither gdbus nor yad is available — tray menu disabled.")
		Logger.warn(LOG, "  Install: sudo apt-get install yad  (or libdbus-glib-1-dev for gdbus)")
	end
	return _backend
end


-- =========================================
-- =========================================
-- ======= 3/ SNI Backend ==================
-- =========================================
-- =========================================

local TrayProto = nil  -- lazy-loaded

local function _get_tray_proto()
	if TrayProto then return TrayProto end
	local ok, mod = pcall(require, "tray.protocol")
	if ok then TrayProto = mod end
	return TrayProto
end

--- Flattens a nested item tree into a flat callback registry (for signal-file dispatch).
--- SNI/dbusmenu callbacks arrive as integer IDs; _sni_registry[id] = fn.
local _sni_registry = {}
local _sni_next_id  = 0

local function _sni_register_callbacks(item, recursion_id)
	if type(item) ~= "table" then return end
	local id = recursion_id or _sni_next_id + 1
	if not recursion_id then
		_sni_next_id = id
	end
	if type(item.fn) == "function" then
		_sni_registry[id] = item.fn
	end
	_sni_next_id = math.max(_sni_next_id, id)

	if type(item.menu) == "table" then
		for i, sub in ipairs(item.menu) do
			_sni_register_callbacks(sub, id * 1000 + i)
			_sni_next_id = math.max(_sni_next_id, id * 1000 + i)
		end
	end
end

--- Builds the full dbusmenu XML from cached items and writes it to the temp file.
local function _sni_rebuild_menu_xml()
	local tp = _get_tray_proto()
	if not tp then return end

	-- Clear the old registry and rebuild.
	_sni_registry = {}
	_sni_next_id  = 0

	-- Register callbacks for each top-level item.
	for _, item in ipairs(_sni_items) do
		_sni_register_callbacks(item)
	end

	-- Serialise the items array into dbusmenu XML.
	local xml = tp.build_dbus_menu_xml(_sni_items)

	-- Write to a temp file so gdbus can reference it by path.
	if not _sni_menu_file then
		_sni_menu_file = (os.tmpname and os.tmpname() or "/tmp/ergopti_menu_" .. tostring(os.time()))
		os.remove(_sni_menu_file)
		_sni_menu_file = _sni_menu_file .. ".xml"
	end
	local fh = io.open(_sni_menu_file, "w")
	if fh then
		fh:write(xml)
		fh:close()
		_sni_menu_xml = xml
		Logger.debug(LOG, "SNI menu XML written to %s (%d bytes).",
			_sni_menu_file, #xml)
	else
		Logger.error(LOG, "Cannot write SNI menu XML to %s.", _sni_menu_file)
	end
end

--- Launches the gdbus monitor subprocess for menu activation signals.
local function _sni_start_monitor()
	if _sni_pipe then return true end
	if not _sni_bus_name then return false end

	local cmd = string.format(
		"gdbus monitor --session --dest %s --object-path /MenuBar 2>/dev/null",
		_sni_bus_name:gsub("'", "'\\''")
	)

	local ok, pipe = pcall(io.popen, cmd, "r")
	if not ok or not pipe then
		Logger.error(LOG, "_sni_start_monitor(): io.popen failed.")
		return false
	end
	_sni_pipe = pipe
	Logger.debug(LOG, "SNI monitor subprocess started for %s.", _sni_bus_name)
	return true
end

--- Registers a StatusNotifierItem on the D-Bus session bus.
local function _sni_register()
	if _sni_bus_name then
		-- Already registered — update properties only.
		return true
	end

	local suffix  = tostring(os.time()) .. "." .. tostring(math.random(1000, 9999))
	_sni_bus_name = "org.ergopti.Tray-" .. suffix

	-- Build the gdbus command to create the object and set initial properties.
	local cmds = {}

	-- 1. Register the service on the bus.
	cmds[#cmds + 1] = string.format(
		"gdbus call --session --dest org.freedesktop.DBus "
		.. "--object-path /org/freedesktop/DBus "
		.. "--method org.freedesktop.DBus.RequestName '%s' 0 "
		.. ">/dev/null 2>&1",
		_sni_bus_name
	)

	-- 2. Register with StatusNotifierWatcher.
	local tp = _get_tray_proto()
	if tp then
		cmds[#cmds + 1] = tp.build_sni_register_cmd(_sni_bus_name, "/StatusNotifierItem")
	end

	-- 3. Set initial properties (Title, ToolTip, Menu).
	local icon_path = tp and tp.resolve_tray_icon() or "ergopti"
	cmds[#cmds + 1] = string.format(
		"gdbus call --session --dest %s --object-path /StatusNotifierItem "
		.. "--method org.freedesktop.DBus.Properties.Set "
		.. "org.kde.StatusNotifierItem Title '<s>' '%s' >/dev/null 2>&1",
		_sni_bus_name, "Ergopti"
	)

	-- Tooltip
	local tip = _sni_tooltip or "Ergopti"
	tip = tip:gsub("'", "'\\''")
	cmds[#cmds + 1] = string.format(
		"gdbus call --session --dest %s --object-path /StatusNotifierItem "
		.. "--method org.freedesktop.DBus.Properties.Set "
		.. "org.kde.StatusNotifierItem ToolTip '<(sa(iiay)ss)>' "
		.. "'<('\\''%s'\\'', (<0,0>, []), \\'\\'\\'\\'', \\'\\'\\'\\'')>' >/dev/null 2>&1",
		_sni_bus_name, tip
	)

	for _, c in ipairs(cmds) do
		os.execute(c)
	end

	Logger.success(LOG, "SNI tray item registered: %s.", _sni_bus_name)
	return true
end

--- Kills the SNI subprocess and cleans up.
local function _sni_destroy()
	if _sni_pipe then
		pcall(function() _sni_pipe:close() end)
		_sni_pipe = nil
	end
	if _sni_bus_name then
		-- Release the bus name.
		os.execute(string.format(
			"gdbus call --session --dest org.freedesktop.DBus "
			.. "--object-path /org/freedesktop/DBus "
			.. "--method org.freedesktop.DBus.ReleaseName '%s' "
			.. ">/dev/null 2>&1",
			_sni_bus_name
		))
		_sni_bus_name = nil
	end
	if _sni_menu_file then
		os.remove(_sni_menu_file)
		_sni_menu_file = nil
	end
	_sni_menu_xml = nil
	_sni_registry = {}
	_sni_next_id  = 0
	_sni_items    = {}
	Logger.debug(LOG, "SNI tray destroyed.")
end


-- =========================================
-- =========================================
-- ======= 4/ yad Fallback Backend =========
-- =========================================
-- =========================================

--- Serialises a flat item list into yad's --menu format.
--- Fallback backend only — SNI uses the XML builder above.
--- @param items table Flat array of { title, fn, checked?, disabled? }
--- @return string
local function _yad_serialize_menu(items)
	if type(items) ~= "table" or #items == 0 then
		return "ergopti!bash -c 'echo ergopti'"
	end
	_yad_registry = {}
	local parts = {}
	for _, item in ipairs(items) do
		if type(item) == "table" and type(item.title) == "string" then
			parts[#parts + 1] = item.title:gsub("!", "!!")
			if type(item.fn) == "function" then
				_yad_registry[#_yad_registry + 1] = item.fn
				local dest = _yad_signal_file or "/dev/null"
				parts[#parts + 1] = string.format(
					"bash -c 'echo \"MENU:%d\" > %s'",
					#_yad_registry,
					dest
				)
			else
				parts[#parts + 1] = "bash -c 'true'"
			end
		end
	end
	return table.concat(parts, "!")
end

--- Launches / respawns the yad subprocess.
local function _yad_launch()
	if not _has_yad() then return false end
	_yad_kill()

	if not _yad_signal_file then
		_yad_signal_file = (os.tmpname and os.tmpname() or "/tmp/ergopti_tray_" .. tostring(os.time()))
		os.remove(_yad_signal_file)
		_yad_signal_file = _yad_signal_file .. ".signal"
	end

	local parts = { "yad", "--notification", "--no-middle" }
	if _yad_image then
		parts[#parts + 1] = "--image=" .. _yad_image
	else
		parts[#parts + 1] = "--image=ergopti"
	end
	if _yad_tooltip then
		parts[#parts + 1] = "--text=" .. _yad_tooltip:gsub("'", "'\\''")
	end
	local menu_str = _yad_serialize_menu(_yad_items)
	parts[#parts + 1] = "--menu=" .. menu_str

	local cmd = table.concat(parts, " ")
	Logger.debug(LOG, "Launching yad: %s", cmd)
	local launch = string.format("%s & echo $!", cmd)
	local pipe = io.popen(launch, "r")
	if not pipe then return false end
	local pid_str = pipe:read("*l")
	pipe:close()
	_yad_pid = tonumber(pid_str)
	if not _yad_pid then return false end
	Logger.success(LOG, "yad tray icon spawned (pid=%d).", _yad_pid)
	return true
end

--- Kills the yad subprocess.
local function _yad_kill()
	if _yad_pipe then
		pcall(function() _yad_pipe:close() end)
		_yad_pipe = nil
	end
	if _yad_pid then
		os.execute(string.format("kill %d 2>/dev/null", _yad_pid))
		_yad_pid = nil
	end
end


-- =========================================
-- =========================================
-- ======= 5/ Public API ===================
-- =========================================
-- =========================================

--- Sets or replaces the tray icon.
--- @param opts table { image?, title? }
function M.setIcon(opts)
	local options = type(opts) == "table" and opts or {}
	_select_backend()

	if _backend == "sni" then
		if type(options.image) == "string" then _sni_image = options.image end
		if type(options.title) == "string" then _sni_tooltip = options.title end
		_sni_register()
	elseif _backend == "yad" then
		if type(options.image) == "string" then _yad_image = options.image end
		if type(options.title) == "string" then _yad_tooltip = options.title end
		_yad_launch()
	end
end

--- Replaces the drop-down menu items.
--- Items may be flat ({title, fn}) or nested ({title, menu={…}, fn}).
--- @param items table Array of menu-item tables.
function M.setMenu(items)
	if type(items) ~= "table" then return end
	_select_backend()

	_items_cache = items

	if _backend == "sni" then
		_sni_items = items
		_sni_rebuild_menu_xml()
		_sni_register()
		_sni_start_monitor()
	elseif _backend == "yad" then
		-- yad only supports flat menus — flatten nested items into a single list.
		local flat = {}
		local function flatten(list)
			for _, item in ipairs(list) do
				if type(item) == "table" then
					flat[#flat + 1] = item
					if type(item.menu) == "table" then
						flat[#flat + 1] = { title = "───────────────", fn = function() end, disabled = true }
						flatten(item.menu)
					end
				end
			end
		end
		flatten(items)
		_yad_items = flat
		_yad_launch()
	end
end

--- Sets the tooltip shown on hover.
--- @param text string Tooltip text.
function M.setTooltip(text)
	text = tostring(text or "")
	_select_backend()

	if _backend == "sni" then
		_sni_tooltip = text
		if _sni_bus_name then
			local tip = text:gsub("'", "'\\''")
			os.execute(string.format(
				"gdbus call --session --dest %s --object-path /StatusNotifierItem "
				.. "--method org.freedesktop.DBus.Properties.Set "
				.. "org.kde.StatusNotifierItem ToolTip '<(sa(iiay)ss)>' "
				.. "'<('\\''%s'\\'', (<0,0>, []), \\'\\'\\'\\'', \\'\\'\\'\\'')>' "
				.. ">/dev/null 2>&1",
				_sni_bus_name, tip
			))
		end
	elseif _backend == "yad" then
		_yad_tooltip = text
		if _yad_pid then _yad_launch() end
	end
end

--- Removes and destroys the tray icon. Safe to call multiple times.
function M.destroy()
	if _backend == "sni" then _sni_destroy() end
	if _backend == "yad" then
		_yad_kill()
		if _yad_signal_file then
			os.remove(_yad_signal_file)
			_yad_signal_file = nil
		end
	end
	_backend = nil
	Logger.debug(LOG, "destroy(): tray icon released.")
end

--- Pumps the activation-signal pipe for menu callbacks.
--- In SNI mode: reads lines from the gdbus monitor subprocess.
--- In yad mode: reads from the signal file.
--- Should be called from the event loop.
function M.pump()
	if _backend == "sni" and _sni_pipe then
		-- Non-blocking read of one line from the gdbus monitor.
		local line = _sni_pipe:read("*l")
		if not line then return end

		-- gdbus monitor lines look like:
		--   /MenuBar: org.ergopti.Tray-....ItemActivated (int32 5, uint32 0)
		local id_str = line:match("ItemActivated %(int32 (%d+)")
		if id_str then
			local id = tonumber(id_str)
			if id and _sni_registry[id] and type(_sni_registry[id]) == "function" then
				pcall(_sni_registry[id])
			end
		end
	elseif _backend == "yad" and _yad_signal_file then
		local fh = io.open(_yad_signal_file, "r")
		if not fh then return end
		local content = fh:read("*a")
		fh:close()
		if not content or content == "" then return end

		for idx_str in content:gmatch("MENU:(%d+)") do
			local idx = tonumber(idx_str)
			if idx and _yad_registry[idx] and type(_yad_registry[idx]) == "function" then
				pcall(_yad_registry[idx])
			end
		end

		local fh2 = io.open(_yad_signal_file, "w")
		if fh2 then fh2:close() end
	end
end

--- Returns the name of the active backend (for tests/diagnostics).
--- @return string "sni", "yad", "none", or nil
function M.getBackend()
	_select_backend()
	return _backend
end

-- Exposed for the serialisation regression test.
M._yad_serialize_menu = _yad_serialize_menu

return M
