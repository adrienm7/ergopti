--- tests/support/keyboard_geometry_ports.lua

--- ==============================================================================
--- MODULE: Recording Keyboard Geometry Ports
--- DESCRIPTION:
--- Synthetic model identifiers name declared native classifier outcomes. They
--- are not a table of real Apple models or evidence of native classification.
--- ==============================================================================

local M = {}

function M.new(properties)
	local forms = { [40] = "ansi", [7001] = "ansi", [7002] = "iso", [7003] = "jis" }
	local port = {}
	function port.native_code(primary, iso, model)
		if primary == iso then return primary end
		if forms[model] == "ansi" then return primary end
		if forms[model] == "iso" then return iso end
		return nil
	end
	function port.physical_code(entry, model)
		return port.native_code(entry.hs, type(entry.macos_iso) == "table" and entry.macos_iso.hs or entry.hs, model)
	end
	function port.event_type(event)
		local okay, model = pcall(event.getProperty, event, properties.keyboardEventKeyboardType)
		if okay and type(model) == "number" and model >= 0 and model <= 32767 and model % 1 == 0 then return model end
		return nil
	end
	return port
end

return M
