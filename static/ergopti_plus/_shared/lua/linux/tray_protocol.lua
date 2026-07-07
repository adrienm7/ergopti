--- _shared/lua/linux/tray_protocol.lua
---
--- Pure, driver-agnostic serialization helpers for the D-Bus StatusNotifierItem
--- (SNI) protocol and notify-send desktop notifications. All functions produce
--- strings suitable for io.popen / os.execute — zero native dependencies.
---
--- This file was Item 24 of the Linux port (Palier 4).

local M = {}

-- ============================================================================
-- 1. D-Bus XML menu serialization
-- ============================================================================

--- Escapes XML special characters in a string.
--- @param s string
--- @return string
local function xml_escape(s)
	if type(s) ~= "string" then return "" end
	return s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&apos;")
end

--- Builds a single D-Bus menu item node XML.
--- @param item table { title (string), enabled (boolean|nil), checked (boolean|nil), separator (boolean|nil), items (table|nil) }
--- @param id number Unique item ID for the D-Bus property.
--- @return string XML node string.
function M.build_menu_item_xml(item, id)
	if type(item) ~= "table" then return "" end
	if item.separator then
		return string.format(
			'<menu id="%d"><property name="type" type="s" value="separator"/></menu>',
			id or 0
		)
	end
	local title   = xml_escape(item.title or "")
	local enabled = item.enabled ~= false  -- default true
	local checked = item.checked == true
	local parts   = {}

	parts[#parts + 1] = string.format('<menu id="%d">', id or 0)
	parts[#parts + 1] = string.format('<property name="type" type="s" value="%s"/>',
		checked and "checkmark" or "standard")
	parts[#parts + 1] = string.format('<property name="label" type="s" value="%s"/>', title)
	parts[#parts + 1] = string.format('<property name="enabled" type="b" value="%s"/>',
		enabled and "true" or "false")
	if checked then
		local state_str = "true"  -- checked state
		parts[#parts + 1] = string.format('<property name="toggle-state" type="i" value="%d"/>', 1)
		parts[#parts + 1] = string.format('<property name="toggle-type" type="s" value="%s"/>', "checkmark")
	end

	-- Sub-items (recursive)
	if type(item.items) == "table" and #item.items > 0 then
		parts[#parts + 1] = '<property name="children-display" type="s" value="submenu"/>'
		for i, sub in ipairs(item.items) do
			parts[#parts + 1] = M.build_menu_item_xml(sub, id * 1000 + i)
		end
	end
	parts[#parts + 1] = '</menu>'
	return table.concat(parts, "\n")
end

--- Builds the complete D-Bus menu layout XML from an array of items.
--- Wraps individual menu nodes in the com.canonical.dbusmenu root.
--- @param items table Array of { title, enabled?, checked?, separator?, items? } entries.
--- @return string Complete D-Bus menu XML.
function M.build_dbus_menu_xml(items)
	if type(items) ~= "table" then return "" end
	local parts = { '<?xml version="1.0" encoding="UTF-8"?>' }
	parts[#parts + 1] = '<node name="/MenuBar">'
	parts[#parts + 1] = '<interface name="com.canonical.dbusmenu">'
	for i, item in ipairs(items) do
		parts[#parts + 1] = M.build_menu_item_xml(item, i)
	end
	parts[#parts + 1] = '</interface>'
	parts[#parts + 1] = '</node>'
	return table.concat(parts, "\n")
end

-- ============================================================================
-- 2. notify-send command builder
-- ============================================================================

--- Kind-to-urgency mapping for notify-send.
M.KIND_URGENCY = {
	info  = "normal",
	warn  = "normal",
	error = "critical",
}

--- Builds a notify-send shell command string.
--- The caller is responsible for executing it via os.execute / io.popen.
--- @param title string Notification title.
--- @param body  string Notification body text.
--- @param kind  string "info" | "warn" | "error" (default "info").
--- @return string Shell command ready for os.execute.
function M.build_notify_send_cmd(title, body, kind)
	title = title or ""
	body  = body  or ""
	kind  = kind  or "info"
	local urgency = M.KIND_URGENCY[kind] or "normal"

	-- Escape single quotes for shell safety
	local safe_title = title:gsub("'", "'\\''")
	local safe_body  = body:gsub("'", "'\\''")

	return string.format(
		"notify-send --urgency=%s '%s' '%s' 2>/dev/null",
		urgency, safe_title, safe_body
	)
end

-- ============================================================================
-- 3. Tooltip rendering command builder (zenity / yad stub)
-- ============================================================================

--- Builds a zenity --info command as a tooltip placeholder.
--- Used as a fallback until a native cairo/GTK overlay is wired.
--- @param text   string Tooltip body text.
--- @param timeout_ms number Auto-dismiss timeout in milliseconds.
--- @return string Shell command ready for os.execute.
function M.build_zenity_tooltip_cmd(text, timeout_ms)
	text = text or ""
	timeout_ms = tonumber(timeout_ms) or 2000
	local safe = text:gsub("'", "'\\''"):sub(1, 500)
	return string.format(
		"zenity --info --title='ergopti' --text='%s' --timeout=%d 2>/dev/null",
		safe, math.floor(timeout_ms / 1000)
	)
end

-- ============================================================================
-- 4. SNI icon path resolver
-- ============================================================================

--- Resolves the path to the tray icon file.
--- Tries the distributed PNG in the assets directory, falling back to a
--- system icon.
--- @param driver_root string Absolute path to the linux driver root.
--- @return string Absolute path to an existing icon file, or empty string.
function M.resolve_tray_icon(driver_root)
	driver_root = driver_root or "."
	-- Try the bundled icon first
	local candidates = {
		driver_root .. "/../_shared/assets/ergopti_tray.png",
		driver_root .. "/../_shared/assets/ergopti_tray.svg",
		driver_root .. "/assets/tray_icon.png",
	}

	-- Normalize separators for the current OS
	local sep = package.config:sub(1, 1)
	for _, p in ipairs(candidates) do
		if sep == "\\" then p = p:gsub("/", "\\") end
		local fh = io.open(p, "r")
		if fh then
			fh:close()
			return p
		end
	end
	return ""
end

-- ============================================================================
-- 5. SNI property serialization
-- ============================================================================

--- Builds the gdbus command to set an SNI property.
--- @param bus_name  string D-Bus bus name (e.g. "org.kde.StatusNotifierItem-1-1").
--- @param object_path string D-Bus object path (e.g. "/StatusNotifierItem").
--- @param property  string Property name.
--- @param signature string D-Bus type signature (e.g. "s", "b", "(ii)").
--- @param value     string Property value as a string.
--- @return string gdbus command ready for os.execute.
function M.build_gdbus_set_cmd(bus_name, object_path, property, signature, value)
	return string.format(
		'gdbus call --session --dest %s --object-path %s --method org.freedesktop.DBus.Properties.Set %s %s "<%s %s>"',
		bus_name, object_path,
		"org.kde.StatusNotifierItem",
		property,
		signature, value
	)
end

--- Builds a D-Bus method call command for creating a new StatusNotifierItem.
--- @param service_name string Unique service name on the session bus.
--- @param object_path string Object path for the item (e.g. "/StatusNotifierItem").
--- @return string gdbus command.
function M.build_sni_register_cmd(service_name, object_path)
	return string.format(
		'gdbus call --session --dest org.kde.StatusNotifierWatcher --object-path /StatusNotifierWatcher --method org.kde.StatusNotifierWatcher.RegisterStatusNotifierItem %s',
		service_name
	)
end

return M
