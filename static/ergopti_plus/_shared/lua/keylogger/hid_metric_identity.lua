--- _shared/lua/keylogger/hid_metric_identity.lua

--- Pure metrics identities for consumer keys without a platform virtual keycode.
--- These IDs are neither bindable keycodes nor keyboard positions. No capture is enabled.
local M = {}

-- Reserve the namespace above every uint32 platform keycode. Two uint16 HID
-- fields give a maximum of 8589934591, exactly representable by LuaJIT doubles,
-- Lua54 integers and JSON numbers; SQLite stores these as INTEGER values.
local BASE, PAGE_WIDTH, MAX_FIELD = 4294967296, 65536, 65535
local CONSUMER_PAGE = 0x0C

-- Apple IOHIDUsageTables.h at 777ccd9698845aadf711e32d843c8c9b777431d9:
-- DisplayBrightnessIncrement/Decrement, ScanNext/PreviousTrack, PlayOrPause.
-- Hammerspoon 1.1.1 at 1469832361b4c3687ec7d589c1b4efe4d3b742ee
-- libeventtap_event.m exposes these exact getSystemKey names.
-- This is deliberately a whitelist: Play-only, rewind and other usages are unknown.
local SYSTEM_NAMES = {
	[0x6F] = "BRIGHTNESS_UP",
	[0x70] = "BRIGHTNESS_DOWN",
	[0xB5] = "NEXT",
	[0xB6] = "PREVIOUS",
	[0xCD] = "PLAY",
}
local BY_SYSTEM_NAME = {}
for usage, name in pairs(SYSTEM_NAMES) do BY_SYSTEM_NAME[name] = usage end

local function field(value)
	return type(value) == "number" and value >= 0 and value <= MAX_FIELD and value % 1 == 0
end

--- Resolves only the approved consumer HID usages into the reserved metrics namespace.
--- @param page number HID usage page, never a native system-key type.
--- @param usage number HID usage within the page.
--- @return number|nil identity Stable metrics ID or nil for unsupported/invalid usages.
function M.resolve_hid(page, usage)
	if not field(page) or not field(usage) or page ~= CONSUMER_PAGE or SYSTEM_NAMES[usage] == nil then return nil end
	return BASE + page * PAGE_WIDTH + usage
end

--- Resolves a public Hammerspoon getSystemKey name to the same metrics identity.
--- @param name string Exact public name; native NX numeric types are not virtual keycodes.
--- @return number|nil identity Stable metrics ID or nil for unsupported names.
function M.resolve_system_name(name)
	if type(name) ~= "string" then return nil end
	local usage = BY_SYSTEM_NAME[name]
	return usage and M.resolve_hid(CONSUMER_PAGE, usage) or nil
end

--- Captures the existing platform resolver and preserves every known ID and reason.
--- @param resolve_virtual function Platform virtual-keycode resolver.
--- @return function resolve_metric Explicit metric resolver with a narrow HID fallback.
function M.with_virtual_keycodes(resolve_virtual)
	assert(type(resolve_virtual) == "function", "Missing virtual keycode resolver")
	return function(page, usage, keyboard_type)
		local keycode, reason = resolve_virtual(page, usage, keyboard_type)
		if keycode ~= nil then return keycode, reason end
		local metric = M.resolve_hid(page, usage)
		if metric ~= nil then return metric end
		return nil, reason
	end
end

return M
