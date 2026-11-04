--- tests/hardware/keyboard_source_writer.lua

--- ==============================================================================
--- MODULE: Keyboard-Only Fixture Source Writer
--- DESCRIPTION:
--- Loads a private copy of the production uinput writer to stand in for a
--- physical keyboard in the real-kernel harnesses. Since the navigation layer
--- forwards a mouse wheel, the production virtual device also advertises
--- relative axes; a source that does is refused by the hook's grab policy
--- (device_finder.is_interceptable_event_mask), as a keyboard with a pointing
--- stick is. A fixture source is therefore created without that registration:
--- keys and SYN only, the capabilities of a plain keyboard.
---
--- FEATURES & RATIONALE:
--- 1. The copy is the production writer byte for byte except the one removed
---    registration, which must match exactly once: a writer refactor fails this
---    loader loudly instead of silently grabbing a pointer-capable source.
--- 2. The copy publishes the requested device name, as every harness did by
---    swapping infra.device_names around its load.
--- ==============================================================================

local M = {}

local Names = require("infra.device_names")

--- The relative-axis registration a keyboard source must not carry.
M.RELATIVE_REGISTRATION = "\t\tif not admit(UI_SET_EVBIT, EV_REL) then return false end\n"
	.. "\t\tfor _, axis in ipairs(RELATIVE_AXES) do\n"
	.. "\t\t\tif not admit(UI_SET_RELBIT, axis) then return false end\n"
	.. "\t\tend\n"

--- Returns the production writer source with its relative axes removed.
--- @param path string|nil Writer path, relative to the driver root by default.
--- @return string source
function M.keyboard_source(path)
	local file = assert(io.open(path or "adapters/uinput_writer.lua", "rb"), "production writer unreadable")
	local text = assert(file:read("*a"))
	file:close()
	local start, finish = text:find(M.RELATIVE_REGISTRATION, 1, true)
	assert(start, "the writer's relative-axis registration moved: update the keyboard fixture")
	assert(not text:find(M.RELATIVE_REGISTRATION, finish + 1, true), "the relative-axis registration is not unique")
	return text:sub(1, start - 1) .. text:sub(finish + 1)
end

--- Loads a keyboard-only writer copy that publishes the given device name.
--- @param name string Test-owned kernel device name.
--- @param path string|nil Writer path.
--- @return table writer A fresh writer module instance.
function M.load(name, path)
	assert(type(name) == "string" and name ~= "", "fixture source name required")
	local chunk = assert(load(M.keyboard_source(path), "@adapters/uinput_writer.lua"))
	local old_name = Names.VIRTUAL_KEYBOARD
	Names.VIRTUAL_KEYBOARD = name
	local loaded, writer = pcall(chunk)
	Names.VIRTUAL_KEYBOARD = old_name
	assert(loaded, writer)
	return writer
end

return M
