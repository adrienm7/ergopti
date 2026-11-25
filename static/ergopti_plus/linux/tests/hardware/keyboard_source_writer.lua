--- tests/hardware/keyboard_source_writer.lua

--- ==============================================================================
--- MODULE: Keyboard-Only Fixture Source Writer
--- DESCRIPTION:
--- Loads a private copy of the production uinput writer to stand in for a
--- physical keyboard in the real-kernel harnesses. The production keyboard
--- device advertises keys and SYN only (pointer output has its own device,
--- created on demand), so the copy is the writer byte for byte; it only
--- publishes the requested device name, as every harness did by swapping
--- infra.device_names around its load.
--- ==============================================================================

local M = {}

local Names = require("platform.input.device_names")

--- Returns the production writer source.
--- @param path string|nil Writer path, relative to the driver root by default.
--- @return string source
function M.keyboard_source(path)
	local file = assert(io.open(path or "platform/input/uinput_writer.lua", "rb"), "production writer unreadable")
	local text = assert(file:read("*a"))
	file:close()
	return text
end

--- Loads a keyboard-only writer copy that publishes the given device name.
--- @param name string Test-owned kernel device name.
--- @param path string|nil Writer path.
--- @return table writer A fresh writer module instance.
function M.load(name, path)
	assert(type(name) == "string" and name ~= "", "fixture source name required")
	local chunk = assert(load(M.keyboard_source(path), "@platform/input/uinput_writer.lua"))
	local old_name = Names.VIRTUAL_KEYBOARD
	Names.VIRTUAL_KEYBOARD = name
	local loaded, writer = pcall(chunk)
	Names.VIRTUAL_KEYBOARD = old_name
	assert(loaded, writer)
	return writer
end

return M
