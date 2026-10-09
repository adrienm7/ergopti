--- modules/gestures/combo_emitter.lua

--- ==============================================================================
--- MODULE: Gesture Combos, Emitted Through uinput
--- DESCRIPTION:
--- Turns an X11-keysym combo string — `ctrl+Right`, `super+Up`, `alt+F4` — into
--- evdev keycodes and presses them on the device the daemon already owns.
---
--- WHY THIS REPLACES `xdotool key`:
--- Every gesture action ran through `os.execute("xdotool key …")`, which is X11
--- only. Under Wayland xdotool talks to nothing: the command succeeds, the
--- shell exits zero, and the gesture does nothing — the worst shape of failure,
--- because there is no error to find. uinput sits BELOW the display server, so
--- the same keystroke reaches X11, every Wayland compositor and a bare TTY
--- alike; it is the same reason the hotstring injector was moved off ydotool.
---
--- WHY A BOUNDED TABLE AND NOT ALL OF X11:
--- The combos are not arbitrary user input. They come from
--- `_shared/modules/actions/actions.toml` through the generated table, and from
--- the modifier chords of `_shared/modules/actions/modifier_chords.json` (Ctrl+A,
--- Super+1, Alt+.), which name the letters, the digits, Space, Return, the
--- period and the comma, and from the media keys the volume, brightness and
--- track actions fall back to. Mapping those is bounded and checkable; mapping "all of
--- X11" would be a hundred entries written blind, most of them never used, and
--- no way to tell a wrong one from an unused one.
--- `tests/unit/modules/test_combo_emitter.lua` asserts that EVERY combo the
--- generated catalogue contains resolves, and
--- `tests/unit/modules/test_action_handlers_declared.lua` presses every declared
--- modifier chord, so the bound is enforced rather than assumed: add an action
--- or a chord key with a new name and the suite says so.
---
--- WHAT IT STILL CANNOT DO:
--- A keystroke is all uinput can express. "Switch to workspace 3" or "focus that
--- window" are not keystrokes, and no external process can perform them under
--- Wayland at all — there is no protocol for it. Those actions can only be a
--- combination the compositor already binds, and Hyprland, sway, i3, niri and
--- river ship none by default. That is a property of Wayland, not of this file.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local EvdevCodes = require("infra.evdev_codes")

local LOG = "gestures.combo_emitter"

-- The issuer owns its source factory before later calls can replace cache
-- entries or observation exports. Such a replacement cannot mint authority.
local trusted_writer_ok, trusted_writer = pcall(require, "adapters.uinput_writer")
local trusted_broker_ok, trusted_broker = pcall(require, "adapters.modifier_broker")
local trusted_for_channel = trusted_broker_ok and type(trusted_broker) == "table"
	and rawget(trusted_broker, "for_channel") or nil
local trusted_writer_ports = {}
if trusted_writer_ok and type(trusted_writer) == "table" then
	for name, port in pairs(trusted_writer) do
		if type(port) == "function" then trusted_writer_ports[name] = port end
	end
end

-- Only this issuer can authorize another producer. A status string, copied
-- table or stale channel observation is not a pre-acquisition receipt.
local unavailable_witnesses = setmetatable({}, { __mode = "k" })

local function outcome(kind)
	return { kind = kind }
end

local function witness_current(receipt)
	if getmetatable(receipt.writer) ~= nil or getmetatable(receipt.broker) ~= nil
		or not rawequal(package.loaded["adapters.uinput_writer"], receipt.writer)
		or not rawequal(package.loaded["adapters.modifier_broker"], receipt.broker)
		or not rawequal(rawget(receipt.broker, "for_channel"), receipt.for_channel) then return false end
	for name, port in pairs(receipt.ports) do
		if not rawequal(rawget(receipt.writer, name), port) then return false end
	end
	for name, port in pairs(receipt.writer) do
		if type(port) == "function" and not rawequal(receipt.ports[name], port) then return false end
	end
	return receipt.for_channel(receipt.writer) == nil
end

local function unavailable_outcome(writer, broker, ports, label)
	if not trusted_writer_ok or not rawequal(writer, trusted_writer) then return nil end
	if not trusted_broker_ok or not rawequal(broker, trusted_broker)
		or not rawequal(rawget(broker, "for_channel"), trusted_for_channel) then return nil end
	for name, port in pairs(trusted_writer_ports) do
		if not rawequal(ports[name], port) then return nil end
	end
	for name, port in pairs(ports) do
		if not rawequal(trusted_writer_ports[name], port) then return nil end
	end
	local observe = ports.unavailable_for_output
	if type(observe) ~= "function" or type(broker.for_channel) ~= "function" then return nil end
	local receipt = { writer = writer, broker = broker, for_channel = broker.for_channel, ports = ports }
	if not witness_current(receipt) then return nil end
	local ok, unavailable, generation = pcall(observe)
	if not ok or unavailable ~= true or type(generation) ~= "number"
		or generation < 0 or generation >= math.huge or generation ~= math.floor(generation)
		or not witness_current(receipt) then return nil end
	local result = outcome("unavailable")
	receipt.generation = generation
	receipt.label = label
	unavailable_witnesses[result] = receipt
	return result
end

--- Consumes one exact positively observed pre-acquisition unavailable receipt.
--- Native refusal, attempted delivery or unsettled debt never creates one.
--- @param result table Opaque second result returned by press().
--- @param label string Exact original combo; another effect cannot borrow the receipt.
--- @return boolean allowed
function M.can_fallback(result, label)
	local receipt = unavailable_witnesses[result]
	if not receipt then return false end
	unavailable_witnesses[result] = nil
	if type(result) ~= "table" or getmetatable(result) ~= nil or rawget(result, "kind") ~= "unavailable"
		or type(label) ~= "string" or label ~= receipt.label or not witness_current(receipt) then return false end
	for name in pairs(result) do if name ~= "kind" then return false end end
	local ok, unavailable, generation = pcall(receipt.ports.unavailable_for_output)
	return ok and unavailable == true and generation == receipt.generation and witness_current(receipt)
end

-- The evdev value for a press and a release.
local PRESS = 1
local RELEASE = 0

-- X11 keysym name → evdev keycode, from include/uapi/linux/input-event-codes.h.
--
-- Only the names the shared action catalogue actually uses. Modifier names are
-- the lower-case ones xdotool accepts; the rest are X11 keysyms as the catalogue
-- spells them, which is why "Return" and not "Enter".
local KEYSYM_TO_CODE = {
	-- Modifiers. Left-hand variants, because a combo says which modifier it
	-- wants and not which side; the left one is the one every layout has.
	ctrl      = 29,  -- KEY_LEFTCTRL
	shift     = 42,  -- KEY_LEFTSHIFT
	alt       = 56,  -- KEY_LEFTALT
	super     = 125, -- KEY_LEFTMETA

	-- Navigation.
	Left      = 105, -- KEY_LEFT
	Right     = 106, -- KEY_RIGHT
	Up        = 103, -- KEY_UP
	Down      = 108, -- KEY_DOWN
	Home      = 102, -- KEY_HOME
	End       = 107, -- KEY_END
	Prior     = 104, -- KEY_PAGEUP
	Next      = 109, -- KEY_PAGEDOWN

	-- Editing and control.
	Return    = 28,  -- KEY_ENTER
	Escape    = 1,   -- KEY_ESC
	Tab       = 15,  -- KEY_TAB
	Caps_Lock = 58,  -- KEY_CAPSLOCK
	BackSpace = 14,  -- KEY_BACKSPACE
	Delete    = 111, -- KEY_DELETE
	space     = 57,  -- KEY_SPACE

	-- Function keys.
	F4        = 62,  -- KEY_F4
	F11       = 87,  -- KEY_F11

	-- Every letter and digit, the period and the comma: the catalogue's own
	-- combos (ctrl+c, ctrl+v, ctrl+t, ctrl+w, ctrl+x) and every modifier chord.
	-- US positions: parse() moves each character to where the live layout has it.
	a = 30, b = 48, c = 46, d = 32, e = 18, f = 33, g = 34, h = 35, i = 23,  -- KEY_A..KEY_I
	j = 36, k = 37, l = 38, m = 50, n = 49, o = 24, p = 25, q = 16, r = 19,  -- KEY_J..KEY_R
	s = 31, t = 20, u = 22, v = 47, w = 17, x = 45, y = 21, z = 44,          -- KEY_S..KEY_Z
	["1"] = 2, ["2"] = 3, ["3"] = 4, ["4"] = 5, ["5"] = 6,                     -- KEY_1..KEY_5
	["6"] = 7, ["7"] = 8, ["8"] = 9, ["9"] = 10, ["0"] = 11,                   -- KEY_6..KEY_0
	period    = 52,  -- KEY_DOT
	comma     = 51,  -- KEY_COMMA

	-- The media keys the volume, brightness and track actions press when their
	-- tool (pactl, brightnessctl, playerctl) cannot do it.
	XF86AudioMute         = 113, -- KEY_MUTE
	XF86AudioLowerVolume  = 114, -- KEY_VOLUMEDOWN
	XF86AudioRaiseVolume  = 115, -- KEY_VOLUMEUP
	XF86AudioNext         = 163, -- KEY_NEXTSONG
	XF86AudioPlay         = 164, -- KEY_PLAYPAUSE
	XF86AudioPrev         = 165, -- KEY_PREVIOUSSONG
	XF86MonBrightnessDown = 224, -- KEY_BRIGHTNESSDOWN
	XF86MonBrightnessUp   = 225, -- KEY_BRIGHTNESSUP
	-- The key every Linux desktop binds to its own screenshot tool, which is
	-- what the screen_capture action opens.
	Print     = 99,  -- KEY_SYSRQ

}

-- The character each shortcut key types, looked up in the live layout: a
-- letter or a digit is its own keysym name, and the two marks are named as X
-- spells them, which is also what the xdotool fallback accepts.
local SHORTCUT_CHAR = { period = ".", comma = "," }

-- Which names are modifiers. A combo presses its modifiers first and releases
-- them last, so the order matters and cannot be read off the string alone.
local IS_MODIFIER = {
	ctrl = true, shift = true, alt = true, super = true,
}

M.KEYSYM_TO_CODE = KEYSYM_TO_CODE
M.IS_MODIFIER = IS_MODIFIER




-- =========================================
-- =========================================
-- ======= 1/ Reading a combo ==============
-- =========================================
-- =========================================

--- Splits a combo into the modifiers to hold and the keys to strike.
---
--- Pure, so the whole parse can be checked without a device — which is most of
--- what can go wrong here.
--- @param combo string e.g. "ctrl+shift+Tab"
--- @return table|nil { mods = {code…}, keys = {code…} }, string|nil unknown name
function M.parse(combo)
	if type(combo) ~= "string" or combo == "" then return nil, "empty combo" end

	local mods, keys, level_mods = {}, {}, {}
	local ok_layout, KeyboardLayout = pcall(require, "adapters.keyboard_layout")
	for part in combo:gmatch("[^+%s]+") do
		local code = KEYSYM_TO_CODE[part]
		-- A character is pressed where the live layout types it, not where US
		-- does: ctrl+w as KEY_W is Ctrl+Z (undo) on AZERTY, and ctrl+comma as
		-- KEY_COMMA is no comma on Ergopti. Every one-character name and the
		-- two marks are characters; the named keys (Return, Left, F4) are keys.
		local char = #part == 1 and part or SHORTCUT_CHAR[part]
		if code and char and ok_layout then
			local extra
			code, extra = KeyboardLayout.shortcut_keycode(char, code)
			for _, mod in ipairs(extra or {}) do level_mods[#level_mods + 1] = mod end
		end
		if not code then
			-- Named, not swallowed. An unmapped key name means the action
			-- catalogue grew and this table did not, and the symptom would
			-- otherwise be one gesture that quietly does nothing.
			return nil, part
		end
		if IS_MODIFIER[part] then
			mods[#mods + 1] = code
		else
			keys[#keys + 1] = code
		end
	end
	-- The level the layout types a character on (Shift for "." on AZERTY) is
	-- held with the chord's own modifiers, once.
	for _, mod in ipairs(level_mods) do
		local held = false
		for _, existing in ipairs(mods) do held = held or existing == mod end
		if not held then mods[#mods + 1] = mod end
	end

	if #keys == 0 then return nil, "combo has no non-modifier key" end
	return { mods = mods, keys = keys }, nil
end




-- =========================================
-- =========================================
-- ======= 2/ Pressing it ==================
-- =========================================
-- =========================================

--- Modifier keycodes already down on the daemon's device: the hand's, or a
--- tap-hold's hold (CapsLock held as Ctrl), both tracked by the keyboard hook.
--- @return table Set of evdev keycodes.
local function held_modifier_codes()
	local held = {}
	local ok, hook = pcall(require, "adapters.keyboard_hook")
	if not ok or type(hook) ~= "table" then return held end
	for _, accessor in ipairs({ "held_text_modifier_codes", "held_shortcut_modifier_codes" }) do
		if type(hook[accessor]) == "function" then
			local ok_call, codes = pcall(hook[accessor])
			if ok_call and type(codes) == "table" then
				for _, code in ipairs(codes) do held[code] = true end
			end
		end
	end
	return held
end

--- Presses a combo on the daemon's uinput device.
--- @param combo string
--- @return boolean True when every event was written.
--- @return table Typed outcome; only an issued unavailable receipt permits fallback.
function M.press(combo)
	local parsed, unknown = M.parse(combo)
	if not parsed then
		Logger.error(LOG, "Cannot emit '%s': %s.", tostring(combo), tostring(unknown))
		return false, outcome("refused")
	end
	return M.press_codes(parsed.mods, parsed.keys, combo)
end

--- Presses evdev codes on the daemon's uinput device: the modifiers held, the
--- keys struck, as one chord.
---
--- Modifiers down, keys down, keys up, modifiers up in reverse — the order a
--- physical hand produces, and the order every compositor expects. Releasing a
--- modifier before the key it modifies leaves the application seeing a bare
--- keystroke, which is the classic way a synthesised chord half-works. The
--- send_key and send_shortcut actions press codes the user chose rather than a
--- catalogue combo, which is why this takes codes and not keysym names.
--- A modifier already held by the hand or a tap-hold is neither pressed nor
--- released: releasing it would lift a key this emission does not own.
--- @param mods table Array of modifier evdev codes, pressed in order.
--- @param keys table Non-empty array of key evdev codes.
--- @param label string|nil What to call the chord in the log.
--- @return boolean True when every event was written.
--- @return table Typed outcome retaining unavailable/native-refusal distinction.
function M.press_codes(mods, keys, label)
	if type(mods) ~= "table" or type(keys) ~= "table" or #keys == 0 then
		Logger.error(LOG, "press_codes() needs a modifier list and at least one key.")
		return false, outcome("refused")
	end
	local name = label or (table.concat(mods, "+") .. "|" .. table.concat(keys, "+"))

	local ok_writer, Writer = pcall(require, "adapters.uinput_writer")
	if not ok_writer or type(Writer) ~= "table" or type(Writer.emit) ~= "function" then
		Logger.error(LOG, "No uinput writer — '%s' cannot be emitted.", name)
		return false, outcome("refused")
	end
	local writer_ports = {}
	for name, port in pairs(Writer) do if type(port) == "function" then writer_ports[name] = port end end
	local Broker = require("adapters.modifier_broker")
	if type(Writer.is_open) == "function" and not Writer.is_open() then
		-- Loud rather than opened here: the daemon owns that device's lifetime,
		-- and a module that opened it on demand would race the one that closes it.
		Logger.error(LOG, "The uinput device is not open — '%s' was not emitted.", name)
		return false, unavailable_outcome(Writer, Broker, writer_ports, name) or outcome("refused")
	end

	local broker = Broker.for_channel(Writer)
	local reservation = broker and broker.begin() or nil
	if broker and not reservation then return false, outcome("refused") end
	local held = {}
	local function emit(code, value)
		if value == PRESS and not reservation then held[#held + 1] = code end
		local ok, result = pcall(reservation and reservation.emit or Writer.emit, code, value)
		if not ok or result ~= true then return false end
		if value == PRESS and reservation then held[#held + 1] = code end
		if value == RELEASE then
			for i = #held, 1, -1 do
				if held[i] == code then table.remove(held, i); break end
			end
		end
		return true
	end
	local function settle()
		if not reservation or reservation.finish() then return true end
		local Hook = require("adapters.keyboard_hook")
		if type(Hook.emergency_stop) == "function" then Hook.emergency_stop("gesture output custody unresolved") end
		return false
	end
	local function cleanup()
		local clean = true
		for i = #held, 1, -1 do
			local ok, result = pcall(reservation and reservation.emit or Writer.emit, held[i], RELEASE)
			if not ok or result ~= true then clean = false end
		end
		if not settle() then clean = false end
		return clean
	end
	local function failed()
		return false, outcome(cleanup() and "native_failed" or "custody_unresolved")
	end
	if reservation then
		for _, code in ipairs(keys) do
			if reservation.borrow(code) then
				return false, outcome(settle() and "refused" or "custody_unresolved")
			end
		end
	end
	local already_down = held_modifier_codes()
	local owned_mods = {}
	for _, code in ipairs(mods) do
		local borrowed = reservation and reservation.borrow(code) or (not broker and already_down[code])
		if not borrowed then owned_mods[#owned_mods + 1] = code end
	end
	for _, code in ipairs(owned_mods) do
		if not emit(code, PRESS) then return failed() end
	end
	for _, code in ipairs(keys) do
		if not emit(code, PRESS) then return failed() end
	end
	for i = #keys, 1, -1 do
		if not emit(keys[i], RELEASE) then return failed() end
	end
	for i = #owned_mods, 1, -1 do
		if not emit(owned_mods[i], RELEASE) then return failed() end
	end

	if not settle() then return false, outcome("custody_unresolved") end
	Logger.debug(LOG, "Emitted '%s' (%d modifier(s), %d key(s)).", name, #owned_mods, #keys)
	return true, outcome("emitted")
end

return M
