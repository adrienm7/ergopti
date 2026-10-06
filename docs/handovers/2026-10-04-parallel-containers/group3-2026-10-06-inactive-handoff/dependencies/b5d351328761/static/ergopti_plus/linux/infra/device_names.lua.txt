--- infra/device_names.lua

--- ==============================================================================
--- MODULE: Input Device Names (Linux)
--- DESCRIPTION:
--- The one place that names the input devices this daemon has to recognise:
--- the uinput writer stamps its own device's name into struct uinput_setup,
--- and the device finder must never read that device (or any other injector's)
--- back as a keyboard.
---
--- FEATURES & RATIONALE:
--- 1. The sysfs prefix is the primary signal, not the names. Every uinput-backed
---    device is registered under /devices/virtual/, whatever its owner chose to
---    call it, so the prefix catches injectors this list has never heard of. The
---    name patterns are the fallback for a kernel that reports no sysfs line.
--- 2. Reading our own device back would expand every injected character again,
---    which looks like a hotstring engine bug and reproduces only on hardware.
--- ==============================================================================

local M = {}




-- =============================================
-- =============================================
-- ======= 1/ Device names =====================
-- =============================================
-- =============================================

--- The uinput device this driver creates to re-emit and inject keystrokes.
--- Stamped into struct uinput_setup by adapters/uinput_writer.lua.
M.VIRTUAL_KEYBOARD = "Ergopti Virtual Keyboard"




-- =================================================
-- =================================================
-- ======= 2/ Synthetic-device recognition =========
-- =================================================
-- =================================================

--- Sysfs path prefix every uinput-backed device is registered under. This is the
--- kernel's own classification and needs no maintenance as new injectors appear.
M.VIRTUAL_SYSFS_PREFIX = "/devices/virtual/"

--- Lowercased substrings that mark a device as software-synthesised when the
--- kernel reports no sysfs line to classify it by. Deliberately short: this list
--- only has to catch the devices we or our neighbours create, because anything
--- else is caught by the sysfs prefix above.
M.SYNTHETIC_NAME_PATTERNS = {
	"ergopti",
	"ydotool",
	"virtual",
}

--- True when a device name matches one of the synthetic patterns.
--- @param name string Device name as reported by the kernel.
--- @return boolean
function M.is_synthetic_name(name)
	if type(name) ~= "string" then return false end
	local lower = name:lower()
	for _, pattern in ipairs(M.SYNTHETIC_NAME_PATTERNS) do
		if lower:find(pattern, 1, true) then return true end
	end
	return false
end

--- True when a sysfs path identifies a virtual (uinput-backed) device.
--- @param sysfs string|nil Value of the `S: Sysfs=` line, or nil when absent.
--- @return boolean
function M.is_virtual_sysfs(sysfs)
	if type(sysfs) ~= "string" then return false end
	return sysfs:sub(1, #M.VIRTUAL_SYSFS_PREFIX) == M.VIRTUAL_SYSFS_PREFIX
end

return M
