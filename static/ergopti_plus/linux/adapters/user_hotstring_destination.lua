--- adapters/user_hotstring_destination.lua

--- ==============================================================================
--- MODULE: Programmable Hotstring Destination (Linux)
--- DESCRIPTION:
--- Retains exact native accessibility ownership from the bounded focus helper.
--- Window labels cannot substitute for a unique bus name and object path.
--- ==============================================================================
local M = {}
local AtspiFocus = require("adapters.atspi_focus")

--- Validates native D-Bus identity and active-window coverage from the helper.
--- @param snapshot table|nil Bounded native helper response.
--- @return boolean owned
local function owned(snapshot)
	return type(snapshot) == "table" and snapshot.active_scope == true
		and type(snapshot.native_bus_name) == "string" and snapshot.native_bus_name:match("^:%d+%.%d+$") ~= nil
		and type(snapshot.native_object_path) == "string" and snapshot.native_object_path:sub(1, 1) == "/"
		and snapshot.role ~= 40
end

--- Captures only the receipt already admitted by the daemon's privacy probe.
--- @return table|nil destination
function M.capture()
	local snapshot = AtspiFocus.cached_snapshot()
	if not owned(snapshot) then return nil end
	return { bus = snapshot.native_bus_name, path = snapshot.native_object_path }
end

--- Rechecks actual focused native identity through the existing bounded helper.
--- @param receipt table Exact destination previously captured.
--- @return boolean current
function M.current(receipt)
	local snapshot, conclusive = AtspiFocus.get_snapshot()
	return conclusive == true and owned(snapshot) and type(receipt) == "table"
		and receipt.bus == snapshot.native_bus_name and receipt.path == snapshot.native_object_path
end

return M
