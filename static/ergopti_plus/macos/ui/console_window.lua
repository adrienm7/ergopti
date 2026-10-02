--- ui/console_window.lua

--- ==============================================================================
--- MODULE: Native Debug Console Window
--- DESCRIPTION:
--- Opens the owned console in front, then gives small windows the shared minimum
--- geometry after AppKit has created the window. Existing large windows stay put.
--- ==============================================================================

local M = {}
local hs = hs
local Logger = require("infra.logger")
local Paths = require("infra.paths")
local DeferredWork = require("infra.deferred_work")
local JsonCodec = require("adapters.json_codec")
local LOG = "console_window"

--- Resolves the native console ratios from the shared geometry owner.
--- @return table ratios Validated width and height ratios.
local function read_ratios()
	local path = assert(Paths.shared("ui/apps.manifest.json"), "shared UI manifest path is unavailable")
	local file = assert(io.open(path, "rb"))
	local text = file:read("*a")
	file:close()
	local data, decode_err = JsonCodec.decode(text)
	assert(decode_err == nil, "native console geometry JSON is invalid")
	local ratios = type(data) == "table" and type(data.native_windows) == "table" and data.native_windows.console
	assert(type(ratios) == "table", "native console geometry is missing")
	for _, name in ipairs({ "width_ratio", "height_ratio" }) do
		local value = ratios[name]
		assert(type(value) == "number" and value > 0 and value <= 1, "invalid console " .. name)
	end
	return ratios
end

--- Places the console after its native window becomes available.
--- @param ratios table Validated shared ratios.
local function place(ratios)
	local window = assert(hs.console.hswindow(), "console window is unavailable")
	local screen = assert(hs.screen.mainScreen(), "main screen is unavailable")
	local bounds, current = screen:frame(), window:frame()
	local width = math.max(current.w, math.floor(bounds.w * ratios.width_ratio + 0.5))
	local height = math.max(current.h, math.floor(bounds.h * ratios.height_ratio + 0.5))
	if width == current.w and height == current.h then return end
	assert(window:setFrame({
		x = bounds.x + (bounds.w - width) / 2,
		y = bounds.y + (bounds.h - height) / 2,
		w = width, h = height,
	}, 0), "console placement was refused")
end

--- Opens the debug console and schedules placement outside the originating action.
--- @return boolean scheduled Whether opening and deferred placement were accepted.
function M.open()
	local opened, detail = pcall(hs.openConsole, true)
	if not opened then
		Logger.error(LOG, "Cannot open console: %s.", tostring(detail))
		return false
	end
	local scheduled = DeferredWork.after(0, function()
		local placed, err = pcall(function() place(read_ratios()) end)
		if not placed then Logger.error(LOG, "Cannot place console: %s.", tostring(err)) end
	end, "console_window.layout")
	if not scheduled then Logger.error(LOG, "Console placement could not be scheduled.") end
	return scheduled
end

return M
