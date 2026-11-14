--- core/fs/adapters/file_manager_folder.lua

--- ==============================================================================
--- MODULE: Active File Manager Folder (Linux)
--- DESCRIPTION:
--- Reads the folder the active file manager window shows, for
--- open_terminal_here and new_text_file_here, and reveals a file in that same
--- window. Only a file manager that publishes the folder of each of its windows
--- over D-Bus can be read: Nautilus (GNOME Files) on an X11 session.
---
--- FEATURES & RATIONALE:
--- 1. The window is the active X11 window (xdotool), and its owner is what the
---    window itself publishes: GTK sets `_GTK_APPLICATION_ID`,
---    `_GTK_UNIQUE_BUS_NAME` and `_GTK_WINDOW_OBJECT_PATH` on every
---    GtkApplicationWindow. Nautilus keys its FileManager1
---    `OpenWindowsWithLocations` property by that same object path, and the
---    property is read from the window's own unique bus name, never from the
---    well-known `org.freedesktop.FileManager1` name another file manager
---    (Thunar, Dolphin) may own.
--- 2. The property lists every tab of the window in tab order and does not
---    say which tab is active (Nautilus 46: its `go-to-tab` action state stays
---    0 whatever tab is shown). A window whose tabs show different folders is
---    refused as ambiguous; one whose tabs all show one folder is that folder.
--- 3. Window titles, a process's working directory and a location bar copied
---    through the clipboard are not ownership evidence and are never read.
--- 4. The window and its folder are read twice, and both reads must agree: a
---    focus change or a navigation during the query is refused, not guessed.
--- 5. Only a local `file://` folder is admitted; `trash:///`, `starred:///`,
---    `sftp://` and the other GVfs locations are refused, never replaced by
---    the home folder.
--- 6. Thunar's D-Bus interfaces only act on folders the caller supplies, and
---    Dolphin's MainWindow only answers whether a URL is open in some tab:
---    neither says which folder the active window shows, so both are named in
---    the refusal instead of being guessed (UNSUPPORTED).
--- ==============================================================================

local M = {}

local FileSelection = require("core.fs.engine.file_selection")
local Logger = require("core.logger.engine.shim")
local TextUtils = require("core.text.engine.utils_core")

local LOG = "core.fs.adapters.file_manager_folder"

--- The shell runner, resolved per call: modules/shortcuts/open_selection
--- loads this adapter for its file manager names, possibly while a caller has
--- the runner replaced.
--- @return table
local function shell() return require("core.process.adapters.shell_runner") end

--- @param value string
--- @return string
local function quote(value) return shell().quote(value) end





-- ==================================
-- ==================================
-- ======= 1/ Constants =============
-- ==================================
-- ==================================

--- The GTK application ids whose windows publish their folder, by the name
--- the logs use.
M.SUPPORTED = { ["org.gnome.Nautilus"] = "Nautilus" }

--- The focused application identities (X11 WM_CLASS or process names, Wayland
--- app ids) of the known file managers, by the name a refusal shows. A
--- reverse-DNS id also matches by its last component (org.gnome.Nautilus).
M.FILE_MANAGERS = {
	["nautilus"] = "Nautilus", ["nemo"] = "Nemo", ["caja"] = "Caja", ["thunar"] = "Thunar",
	["dolphin"] = "Dolphin", ["konqueror"] = "Konqueror", ["pcmanfm"] = "PCManFM",
	["pcmanfm-qt"] = "PCManFM-Qt", ["spacefm"] = "SpaceFM", ["krusader"] = "Krusader",
	["doublecmd"] = "Double Commander", ["peony"] = "Peony", ["io.elementary.files"] = "Files",
	["pantheon-files"] = "Files",
}

--- The binaries of the file managers in SUPPORTED, for the picker's probe.
M.SUPPORTED_BINARIES = { "nautilus" }

--- Seconds one D-Bus query may take before it is refused.
M.DBUS_TIMEOUT_S = 2

--- The X11 window properties read from the active window.
local WINDOW_PROPERTIES = "_GTK_APPLICATION_ID _GTK_UNIQUE_BUS_NAME _GTK_WINDOW_OBJECT_PATH WM_CLASS"

--- The tools the read runs; missing ones make it refuse.
M.TOOLS = { "xdotool", "xprop", "gdbus" }





-- ==================================
-- ==================================
-- ======= 2/ Parsers ===============
-- ==================================
-- ==================================

--- The file manager a focused application identity names.
--- @param app any X11 WM_CLASS, process name or Wayland app id.
--- @return string|nil name The display name, nil when no known file manager.
function M.file_manager_name(app)
	if type(app) ~= "string" or app == "" then return nil end
	local id = app:lower()
	return M.FILE_MANAGERS[id] or M.FILE_MANAGERS[id:match("([^.]+)$")]
end

--- Parses `xprop -notype` output of WINDOW_PROPERTIES.
--- @param text string
--- @return table properties Name -> value; WM_CLASS holds its class (second string).
function M.parse_window_properties(text)
	local properties = {}
	for line in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do
		local name, value = line:match('^([%w_]+) = "([^"]*)"$')
		if name then
			properties[name] = value
		else
			local instance, class = line:match('^WM_CLASS = "([^"]*)", "([^"]*)"$')
			if instance then properties.WM_CLASS = class ~= "" and class or instance end
		end
	end
	return properties
end

local SIMPLE_ESCAPES = { ["\\"] = "\\", ["'"] = "'", ['"'] = '"', n = "\n", t = "\t", r = "\r" }

--- Reads one GVariant text string literal starting at `index`.
--- @return string|nil value
--- @return number|nil next The index after the closing quote.
local function read_string(text, index)
	local quote_char = text:sub(index, index)
	if quote_char ~= "'" and quote_char ~= '"' then return nil end
	local out = {}
	index = index + 1
	while index <= #text do
		local char = text:sub(index, index)
		if char == quote_char then return table.concat(out), index + 1 end
		if char == "\\" then
			-- A file URI is ASCII (GLib percent-escapes every other byte): an
			-- escape outside the simple ones is refused, not decoded.
			local escaped = SIMPLE_ESCAPES[text:sub(index + 1, index + 1)]
			if not escaped then return nil end
			out[#out + 1] = escaped
			index = index + 2
		else
			out[#out + 1] = char
			index = index + 1
		end
	end
	return nil
end

--- Parses the `gdbus call` answer to a Get of OpenWindowsWithLocations: the
--- GVariant text `(<{'/path': ['uri', …], …}>,)`.
--- @param text string
--- @return table|nil windows Object path -> list of URIs in tab order.
function M.parse_windows_with_locations(text)
	if type(text) ~= "string" then return nil end
	local body = text:match("^%s*%(<(.*)>,%)%s*$")
	if not body then return nil end
	body = body:gsub("^@a{sas} ", "")
	local index = 1
	local function skip() index = body:find("[^%s]", index) or (#body + 1) end
	local function expect(char)
		skip()
		if body:sub(index, index) ~= char then return false end
		index = index + 1
		return true
	end
	if not expect("{") then return nil end
	local windows = {}
	skip()
	if body:sub(index, index) == "}" then
		index = index + 1
		skip()
		return index > #body and windows or nil
	end
	while true do
		skip()
		local path, after = read_string(body, index)
		if not path then return nil end
		index = after
		if not expect(":") then return nil end
		skip()
		if body:sub(index, index + 3) == "@as " then index = index + 4 end
		if not expect("[") then return nil end
		local uris = {}
		skip()
		if body:sub(index, index) == "]" then
			index = index + 1
		else
			while true do
				skip()
				local uri, next_index = read_string(body, index)
				if not uri then return nil end
				uris[#uris + 1] = uri
				index = next_index
				skip()
				local separator = body:sub(index, index)
				index = index + 1
				if separator == "]" then break end
				if separator ~= "," then return nil end
			end
		end
		if windows[path] then return nil end
		windows[path] = uris
		skip()
		local separator = body:sub(index, index)
		index = index + 1
		if separator == "}" then break end
		if separator ~= "," then return nil end
	end
	skip()
	if index <= #body then return nil end
	return windows
end

--- The one folder a window's tab list shows.
--- @param uris table The window's locations in tab order.
--- @return string|nil path Local folder path.
--- @return string|nil reason "no_folder", "ambiguous_tabs" or "not_local".
function M.single_folder(uris)
	if type(uris) ~= "table" or #uris == 0 then return nil, "no_folder" end
	for index = 2, #uris do
		if uris[index] ~= uris[1] then return nil, "ambiguous_tabs" end
	end
	local paths = FileSelection.parse_uri_list(uris[1])
	if not paths or #paths ~= 1 then return nil, "not_local" end
	return paths[1], nil
end

--- Encodes an absolute local path as a file URI: each segment keeps only the
--- RFC 3986 unreserved characters, so the URI never needs escaping in GVariant
--- text (an apostrophe is encoded with the rest).
--- @param path string
--- @return string
function M.file_uri(path)
	local segments = {}
	for segment in (path .. "/"):gmatch("([^/]*)/") do segments[#segments + 1] = TextUtils.percent_encode(segment) end
	return "file://" .. table.concat(segments, "/")
end





-- ==================================
-- ==================================
-- ======= 3/ Native Reads ==========
-- ==================================
-- ==================================

local DEFAULT_DEPS = {
	exec = function(command)
		local ok, output = shell().exec_checked(command)
		return ok and output or nil
	end,
	has_command = function(binary) return shell().has_command(binary, true) end,
	is_directory = function(path)
		local ok_uv, uv = pcall(require, "luv")
		if not ok_uv or type(uv) ~= "table" then return false end
		local called, attributes = pcall(uv.fs_stat, path)
		return called and type(attributes) == "table" and attributes.type == "directory"
	end,
	is_x11 = function()
		local Display = require("core.ui.engine.display_server")
		return Display.kind() == Display.X11
	end,
}
local deps = DEFAULT_DEPS

--- The active window and the properties it publishes.
--- @return table|nil window { xid, properties }
local function read_window()
	local xid = deps.exec("xdotool getactivewindow 2>/dev/null")
	xid = xid and xid:match("^(%d+)%s*$")
	if not xid then return nil end
	local text = deps.exec("xprop -notype -id " .. xid .. " " .. WINDOW_PROPERTIES .. " 2>/dev/null")
	if not text then return nil end
	return { xid = xid, properties = M.parse_window_properties(text) }
end

--- The folder lists one Nautilus process publishes, by window object path.
--- @param bus string The process's unique bus name.
--- @return table|nil windows
local function read_locations(bus)
	local output = deps.exec("gdbus call --session --timeout " .. M.DBUS_TIMEOUT_S
		.. " --dest " .. quote(bus) .. " --object-path /org/freedesktop/FileManager1"
		.. " --method org.freedesktop.DBus.Properties.Get org.freedesktop.FileManager1"
		.. " OpenWindowsWithLocations 2>/dev/null")
	if not output then return nil end
	return M.parse_windows_with_locations(output)
end

--- One read of the active window's folder.
--- @return table|nil snapshot { xid, bus, window_path, uris }
--- @return string|nil reason
--- @return string|nil detail The file manager's name for "unsupported_file_manager".
local function snapshot()
	local window = read_window()
	if not window then return nil, "no_window" end
	local properties = window.properties
	local app = properties._GTK_APPLICATION_ID
	if not (app and M.SUPPORTED[app]) then
		local name = M.file_manager_name(app) or M.file_manager_name(properties.WM_CLASS)
		if name then return nil, "unsupported_file_manager", name end
		return nil, "not_file_manager"
	end
	local bus, window_path = properties._GTK_UNIQUE_BUS_NAME, properties._GTK_WINDOW_OBJECT_PATH
	if not (bus and bus:match("^:%d+%.%d+$") and window_path and window_path:match("^/[%w_/]+$")) then
		return nil, "query_failed"
	end
	local windows = read_locations(bus)
	if not windows then return nil, "query_failed" end
	local uris = windows[window_path]
	if not uris then return nil, "query_failed" end
	return { xid = window.xid, bus = bus, window_path = window_path, uris = uris, app = app }
end

--- Whether two snapshots name the same window showing the same tabs.
local function same_snapshot(first, second)
	if first.xid ~= second.xid or first.bus ~= second.bus or first.window_path ~= second.window_path then
		return false
	end
	if #first.uris ~= #second.uris then return false end
	for index, uri in ipairs(first.uris) do
		if second.uris[index] ~= uri then return false end
	end
	return true
end





-- ==================================
-- ==================================
-- ======= 4/ Public API ============
-- ==================================
-- ==================================

--- Whether a file manager whose folder can be read is installed.
--- @return boolean
function M.supported_installed()
	for _, binary in ipairs(M.SUPPORTED_BINARIES) do
		if deps.has_command(binary) then return true end
	end
	return false
end

--- Whether this session can read a file manager's folder at all: an X11
--- session with the tools and a supported file manager installed.
--- @return boolean available
--- @return string|nil missing "session:x11", "tool:<binary>" or "file_manager".
function M.available()
	if not deps.is_x11() then return false, "session:x11" end
	for _, tool in ipairs(M.TOOLS) do
		if not deps.has_command(tool) then return false, "tool:" .. tool end
	end
	if M.supported_installed() then return true, nil end
	return false, "file_manager"
end

--- Reads the local folder the active file manager window shows.
--- @return table|nil folder { path, bus, window_path, xid, app }
--- @return string|nil reason "no_window", "not_file_manager",
---   "unsupported_file_manager", "query_failed", "focus_changed",
---   "no_folder", "ambiguous_tabs", "not_local" or "not_directory".
--- @return string|nil detail The file manager's name for "unsupported_file_manager".
function M.read_active_folder()
	local first, reason, detail = snapshot()
	if not first then return nil, reason, detail end
	local second, again = snapshot()
	if not second then
		Logger.debug(LOG, "The second read of the active window failed (%s).", tostring(again))
		return nil, "focus_changed"
	end
	if not same_snapshot(first, second) then return nil, "focus_changed" end
	local path, why = M.single_folder(first.uris)
	if not path then return nil, why end
	if not deps.is_directory(path) then return nil, "not_directory" end
	Logger.debug(LOG, "The active %s window shows a local folder.", M.SUPPORTED[first.app])
	return { path = path, bus = first.bus, window_path = first.window_path, xid = first.xid, app = first.app }
end

--- Whether the window a folder was read from is still the active one,
--- showing that folder alone.
--- @param folder table The result of read_active_folder.
--- @return boolean
function M.still_active(folder)
	local current = snapshot()
	if not current or current.xid ~= folder.xid or current.bus ~= folder.bus
		or current.window_path ~= folder.window_path then
		return false
	end
	local path = M.single_folder(current.uris)
	return path == folder.path
end

--- The command that asks the file manager the folder came from to select a
--- file, in the window that already shows its folder.
--- @param folder table The result of read_active_folder.
--- @param path string Absolute path of the file to reveal.
--- @return string command
function M.reveal_command(folder, path)
	return "gdbus call --session --timeout " .. M.DBUS_TIMEOUT_S .. " --dest " .. quote(folder.bus)
		.. " --object-path /org/freedesktop/FileManager1 --method org.freedesktop.FileManager1.ShowItems "
		.. quote("['" .. M.file_uri(path) .. "']") .. " ''"
end

--- Replaces the native ports for a test.
--- @param overrides table|nil Any of exec, has_command, is_directory, is_x11.
function M._set_deps(overrides)
	deps = {}
	for name, port in pairs(DEFAULT_DEPS) do deps[name] = port end
	for name, port in pairs(overrides or {}) do deps[name] = port end
end

--- Restores the native ports.
function M._reset_deps()
	deps = DEFAULT_DEPS
end

return M
