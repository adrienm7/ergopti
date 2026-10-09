--- modules/keylogger/physical_key_identity.lua

--- ==============================================================================
--- MODULE: Physical Key Identity
--- DESCRIPTION:
--- Turns a raw HID (usage page, usage) from the physical-key stream into the
--- macOS virtual keycode the metrics store for that key, or says explicitly why
--- the press cannot be attributed.
---
--- FEATURES & RATIONALE:
--- 1. One identity for both sources: the Quartz event tap has always credited
---    macOS virtual keycodes, so the stream credits the keycode macOS reports for
---    the same physical key. History and the heatmap keep one key identity
---    across the switch.
--- 2. Registry-owned: every keyboard and consumer key resolves through
---    _generated/hid_key_identity.lua, generated from the shared physical-key
---    registry and its HID companion hid_usages.json, which also lists the
---    further usages keyboards send for a known key (Non-US # is Backslash) and
---    the keys no layer can bind (F13 to F20, keypad =, the JIS keys); this
---    module holds no usage table of its own.
--- 3. ISO swap: the registry places a usage by the USB HID usage tables, and
---    macOS reports the key left of 1 (usage 0x35) and the key left of Z (0x64)
---    with swapped keycodes on an ISO keyboard (macos_iso in the registry). Only
---    a key whose keycode differs by form needs the device's keyboard type; every
---    other key resolves without it. A keyboard type the registry has no form for
---    (JIS) leaves only those two positions unattributed; the JIS keys resolve.
--- 4. fn/globe is counted: Apple keyboards report it as usage 0x0003 on a vendor
---    page, the top case page (0x00FF) or the Apple keyboard page (0xFF01). It
---    resolves to the fn keycode Quartz reports in flagsChanged (keycodes.FUNCTION).
--- 5. Nothing is guessed: any other usage returns nil and a reason, which the
---    delivery tallies as uncounted coverage instead of retiring the capture or
---    crediting a wrong key. The media keys the registry lacks (play/pause, track
---    skips, brightness) have no macOS virtual keycode and stay uncounted until
---    they are given an identity.
--- ==============================================================================

local M = {}

local Keycodes = require("keycodes")
local Wire     = require("modules.keylogger.physical_wire")
local Table    = require("_generated.hid_key_identity")





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

--- The fn/globe usage on both Apple vendor pages.
M.USAGE_APPLE_FUNCTION = 0x0003

--- The usage is not a key Ergopti has an identity for.
M.REASON_UNMAPPED = "unmapped_usage"

--- The key's keycode depends on a keyboard type the registry has no form for.
M.REASON_KEYBOARD_TYPE = "unsupported_keyboard_type"

-- Registry forms, read from the generated table so a new registry form becomes
-- resolvable without editing this module.
local FORMS = {}
for _, form in ipairs(Table.forms) do FORMS[form] = true end

-- Apple vendor pages whose usage 0x0003 is fn/globe.
local APPLE_FUNCTION_PAGES = {
	[Wire.PAGE_APPLE_VENDOR_TOP_CASE] = true,
	[Wire.PAGE_APPLE_VENDOR_KEYBOARD] = true,
}





-- =============================
-- =============================
-- ======= 2/ Public API =======
-- =============================
-- =============================

--- Resolves one physical key to its macOS virtual keycode.
--- @param page number HID usage page.
--- @param usage number HID usage within that page.
--- @param keyboard_type string The device's keyboard type ("ansi", "iso", "jis") or "none".
--- @return number|nil keycode The macOS virtual keycode, nil when unattributed.
--- @return string|nil reason REASON_UNMAPPED or REASON_KEYBOARD_TYPE when nil.
function M.resolve(page, usage, keyboard_type)
	if APPLE_FUNCTION_PAGES[page] and usage == M.USAGE_APPLE_FUNCTION then
		return Keycodes.FUNCTION
	end
	local usages = Table.pages[page]
	local record = usages and usages[usage]
	if not record then return nil, M.REASON_UNMAPPED end
	if record.kc then return record.kc end
	if not FORMS[keyboard_type] then return nil, M.REASON_KEYBOARD_TYPE end
	return record[keyboard_type]
end

return M
