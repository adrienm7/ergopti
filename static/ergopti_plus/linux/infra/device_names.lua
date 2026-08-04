--- infra/device_names.lua

--- ==============================================================================
--- MODULE: Input Device Names (Linux)
--- DESCRIPTION:
--- The one place that names the input devices this daemon and the remap daemon
--- have to agree about. Three unrelated pieces of code depend on the same few
--- strings: the uinput writer stamps one of them into struct uinput_setup, the
--- remap daemon's config excludes two of them by exact name, and the device
--- finder both excludes and prefers by name.
---
--- WHY THIS EXISTS:
--- kanata's `linux-dev-names-exclude` is an EXACT string match. A name that
--- drifts by one character does not fail loudly — it silently stops excluding,
--- and from that moment the remap daemon re-maps our own injected text while our
--- daemon reads its own output back in. Both failure modes are invisible in a
--- log, reproduce only on real hardware, and look like a hotstring engine bug.
--- That is precisely the class of defect a single source of truth exists to make
--- impossible, so the strings live here and nowhere else.
---
--- FEATURES & RATIONALE:
--- 1. Exact names for the remap daemon, patterns for our own finder. kanata
---    compares names byte for byte; our finder classifies devices it has never
---    seen, so it needs the looser test. Keeping both here makes the difference
---    a stated design decision rather than two call sites that happen to differ.
--- 2. The sysfs prefix is the primary signal, not the names. Every uinput-backed
---    device is registered under /devices/virtual/, whatever its owner chose to
---    call it, so the prefix catches injectors this list has never heard of. The
---    name patterns are the fallback for a kernel that reports no sysfs line.
--- 3. The remap output is named, not excluded. Its device carries POST-remap
---    keycodes — the same codes the application receives — so reading it is the
---    only way the engine sees what the user actually typed. It is a virtual
---    device, so the generic exclusion would drop it: the finder has to ask for
---    it by name before applying any rule.
--- ==============================================================================

local M = {}




-- =============================================
-- =============================================
-- ======= 1/ Device names =====================
-- =============================================
-- =============================================

--- The uinput device this driver creates to re-emit and inject keystrokes.
--- Stamped into struct uinput_setup by adapters/uinput_writer.lua and excluded
--- by the generated remap config, so the remap daemon never grabs our output.
M.VIRTUAL_KEYBOARD = "Ergopti Virtual Keyboard"

--- kanata's output device, named by its `linux-output-device-name` default.
--- kanata excludes this one itself with a hardcoded name test, which is why the
--- value is not ours to choose: it is theirs, and we only have to match it.
M.REMAP_OUTPUT = "kanata"

--- The uinput device ydotoold creates. This driver does not use ydotool, but it
--- is the most widespread third-party injector on Linux desktops, and a user
--- running one alongside would otherwise have every character it types re-mapped
--- by the remap daemon. Excluding it costs nothing and removes a whole class of
--- "text comes out scrambled in one app" report we would otherwise have to
--- diagnose from the outside.
M.THIRD_PARTY_INJECTOR = "ydotoold virtual device"

--- Exact names handed to the remap daemon's `linux-dev-names-exclude`.
--- Order is the order they appear in the generated config, so a diff of that
--- file stays stable across regenerations.
M.REMAP_EXCLUDE = {
	M.THIRD_PARTY_INJECTOR,
	M.VIRTUAL_KEYBOARD,
}




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
