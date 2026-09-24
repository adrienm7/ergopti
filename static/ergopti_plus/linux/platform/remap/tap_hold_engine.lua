--- platform/remap/tap_hold_engine.lua

--- ==============================================================================
--- MODULE: Tap-Hold Engine (Linux)
--- DESCRIPTION:
--- Turns the physical key stream of the grabbed keyboard into what the user
--- configured: a key that is one thing when tapped and another when held
--- (Shift tapped = copy, CapsLock tapped = Enter and held = Ctrl, left Alt held
--- = the navigation layer), and the one-shot Shift.
---
--- FEATURES & RATIONALE:
--- 1. The same semantics as the Windows driver, which also does this in its own
---    process. The hold is taken at key-down, so a held modifier works for a
---    chord or a click at once. A release is a tap only when it comes within the
---    key's threshold, no sooner than the minimum tap duration, and with no
---    other key, click or wheel in between.
--- 2. Pure: events in, events out. The keyboard hook dispatches what comes out
---    exactly as if the user had pressed it, so the hotstring buffer, the
---    modifier state and the virtual keyboard see one consistent stream.
--- 3. Everything this engine presses, it can name and release: release_all()
---    returns the key-ups for every held modifier, layer key and one-shot, and
---    the hook calls it on stop, pause, resynchronisation and dialogs.
--- 4. It replaces kanata, which was optional, needed a newer glibc than Debian
---    12 and Ubuntu 22.04 ship, was never started by the daemon, and broke its
---    whole configuration on the first free-text action.
--- ==============================================================================

local M = {}

local UP, DOWN, REPEAT = 0, 1, 2

-- evdev codes of the keys a tap-hold can be configured on (the Windows set).
M.KEY_CODES = {
	escape = 1, tab = 15, caps_lock = 58, left_shift = 42, left_ctrl = 29,
	win = 125, left_alt = 56, space = 57, alt_gr = 100, right_ctrl = 97,
	right_shift = 54, enter = 28, backspace = 14, delete = 111,
}

-- The keys in the order the tray lists them (the Windows order).
M.KEY_ORDER = {
	"escape", "tab", "caps_lock", "left_shift", "left_ctrl", "win", "left_alt",
	"space", "alt_gr", "right_ctrl", "right_shift", "enter", "backspace", "delete",
}

-- evdev codes of the holdable modifiers.
M.MODIFIER_CODES = { ctrl = 29, shift = 42, alt = 56, alt_gr = 100, win = 125 }

local KEY_LEFTSHIFT = 42
-- Every modifier key, left and right.
local MODIFIER_KEYS = { [29] = true, [42] = true, [54] = true, [56] = true, [97] = true, [100] = true, [125] = true, [126] = true }
local KEY_LEFTCTRL, KEY_LEFTALT, KEY_LEFTMETA = 29, 56, 125
-- The keys that are themselves under a held modifier (Ctrl+Tab, Shift+Tab,
-- Ctrl+Backspace), as the Windows hotkeys without a wildcard are. CapsLock
-- and the modifier keys stay tap-holds, so LShift and CapsLock held together
-- are Ctrl+Shift.
local NATIVE_UNDER_MODIFIER = { [1] = true, [14] = true, [15] = true, [28] = true, [57] = true, [111] = true }
local KEY_HOME, KEY_END, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT = 102, 107, 103, 108, 105, 106
local KEY_ENTER, KEY_BACKSPACE, KEY_ESC = 28, 14, 1
local KEY_F2, KEY_F12 = 60, 88

-- Tap actions that are a single key. They are dispatched through the hook
-- like the key itself, so an Enter tapped on CapsLock ends a hotstring as a
-- real Enter does.
M.KEY_TAPS = { enter = 28, tab = 15, backspace = 14, escape = 1, delete = 111, space = 57, caps_lock = 58 }

--- A chord of the navigation layer.
local function chord(mods, key) return { mods = mods, keys = { key } } end
local C, S, A, W = KEY_LEFTCTRL, KEY_LEFTSHIFT, KEY_LEFTALT, KEY_LEFTMETA

-- The navigation layer, by physical (QWERTY) position, as on Windows
-- (windows/platform/remap/nav_layer.ahk): selection and word moves on the
-- letter rows, lines moved and duplicated on the bottom-left, windows moved to
-- another screen on the right. A key not listed stays itself.
M.NAV_LAYER = {
	-- Top row: q w e r t | y u i o p [
	[16] = chord({ C, S }, KEY_HOME), [17] = chord({ C }, KEY_HOME), [18] = chord({ C }, KEY_END),
	[19] = chord({ C, S }, KEY_END), [20] = chord({}, KEY_F2),
	[21] = chord({ S }, KEY_HOME), [22] = chord({ C, S }, KEY_LEFT), [23] = chord({ S }, KEY_LEFT),
	[24] = chord({ S }, KEY_RIGHT), [25] = chord({ C, S }, KEY_RIGHT), [26] = chord({ S }, KEY_END),
	-- Middle row: caps a s d f g | h j k l ; '
	[58] = chord({}, KEY_BACKSPACE),
	[30] = chord({ C, S }, KEY_UP), [31] = chord({}, KEY_UP), [32] = chord({}, KEY_DOWN),
	[33] = chord({ C, S }, KEY_DOWN), [34] = chord({}, KEY_F12),
	[35] = chord({ W, S }, KEY_LEFT), [36] = chord({ C }, KEY_LEFT), [37] = chord({}, KEY_LEFT),
	[38] = chord({}, KEY_RIGHT), [39] = chord({ C }, KEY_RIGHT), [40] = chord({ W, S }, KEY_RIGHT),
	-- Bottom row: < z x c v | n m , . /
	[86] = chord({ A, S }, KEY_UP), [44] = chord({ A }, KEY_UP), [45] = chord({ A }, KEY_DOWN),
	[46] = chord({ A, S }, KEY_DOWN), [47] = { mods = {}, keys = { KEY_END, KEY_ENTER } },
	[49] = chord({ W }, KEY_UP), [50] = chord({}, KEY_HOME), [51] = chord({ W }, KEY_LEFT),
	[52] = chord({ W }, KEY_RIGHT), [53] = chord({}, KEY_END),
	-- AltGr: Escape.
	[100] = chord({}, KEY_ESC),
}




-- =========================================
-- =========================================
-- ======= 1/ Construction =================
-- =========================================
-- =========================================

--- Creates an engine for one configuration.
--- @param opts table {
---   keys = { [key_id] = { tap_action, hold_modifier, hold_layer, time_activation_seconds, enabled } },
---   tap_min_ms = number, one_shot_timeout_ms = number,
--- }
--- @return table engine
function M.new(opts)
	local options = type(opts) == "table" and opts or {}
	local self = {
		by_code = {},
		tap_min_ms = assert(tonumber(options.tap_min_ms), "tap_min_ms is required"),
		one_shot_timeout_ms = assert(tonumber(options.one_shot_timeout_ms), "one_shot_timeout_ms is required"),
		held = {},          -- code -> { down_at, cancelled, emitted = {codes}, layer = bool }
		layer_depth = 0,     -- how many layer keys are down
		layer_keys = {},     -- code -> chord emitted for a key pressed on the layer
		one_shot_until = nil,
		one_shot_keys = {},  -- keys a one-shot Shift is wrapping (several can overlap)
		native_keys = {},    -- configured keys pressed under a modifier: themselves until released
		key_refs = {},       -- code -> how many of this engine's holders keep it down
		passed_down = {},    -- keys that went through untouched and are down (the hand's)
		modifiers_down = {}, -- modifier keys that went through untouched, and are down
	}
	for key_id, config in pairs(type(options.keys) == "table" and options.keys or {}) do
		local code = M.KEY_CODES[key_id]
		if code and type(config) == "table" and config.enabled ~= false then
			local mods = {}
			if type(config.hold_modifier) == "string" and config.hold_modifier ~= "" then
				for part in config.hold_modifier:gmatch("[^+%s]+") do
					if M.MODIFIER_CODES[part] then mods[#mods + 1] = M.MODIFIER_CODES[part] end
				end
			end
			local layer = type(config.hold_layer) == "string" and config.hold_layer ~= "" and config.hold_layer or nil
			local tap = type(config.tap_action) == "string" and config.tap_action or ""
			-- A native tap and no hold is the key itself: left alone, so it keeps
			-- its autorepeat and its press is not delayed to its release.
			if tap == "" and #mods == 0 and not layer then goto continue end
			self.by_code[code] = {
				id = key_id,
				tap = tap,
				mods = layer and {} or mods,
				layer = layer,
				threshold_ms = math.floor((tonumber(config.time_activation_seconds) or 0) * 1000 + 0.5),
			}
		end
		::continue::
	end
	return setmetatable(self, { __index = M })
end

--- Whether a key is handled by this engine.
--- @param code integer
--- @return boolean
function M:handles(code)
	return self.by_code[code] ~= nil
end




-- =========================================
-- =========================================
-- ======= 2/ Events ======================
-- =========================================
-- =========================================

--- Marks every held tap-hold key but one as used in a chord.
local function cancel_taps(self, except)
	for code, state in pairs(self.held) do
		if code ~= except then state.cancelled = true end
	end
end

--- Presses a key for one more of this engine's holders. Only the first sends
--- it down, and not even that one when the hand already holds it: two holds of
--- one modifier (CapsLock and left Ctrl, both Ctrl), two layer keys that are
--- both Left, a physical Backspace and the layer's are each one key to the
--- kernel, and the first release must not lift it under the others.
local function press(self, out, code)
	local refs = (self.key_refs[code] or 0) + 1
	self.key_refs[code] = refs
	if refs == 1 and not self.passed_down[code] then out[#out + 1] = { code = code, value = DOWN } end
end

--- Releases a key for one of this engine's holders; only the last sends it
--- up, and only when the hand does not still hold it.
local function release(self, out, code)
	local refs = (self.key_refs[code] or 0) - 1
	if refs > 0 then
		self.key_refs[code] = refs
		return
	end
	self.key_refs[code] = nil
	if not self.passed_down[code] then out[#out + 1] = { code = code, value = UP } end
end

--- Appends the events of a chord going down or up.
local function chord_events(self, out, spec, value)
	if value == DOWN then
		for _, mod in ipairs(spec.mods) do press(self, out, mod) end
		for index, key in ipairs(spec.keys) do
			press(self, out, key)
			-- A sequence (End then Enter) releases each key before the next.
			if index < #spec.keys then release(self, out, key) end
		end
	else
		release(self, out, spec.keys[#spec.keys])
		for index = #spec.mods, 1, -1 do release(self, out, spec.mods[index]) end
	end
end

--- Whether a modifier is down: one passed through, or one a hold emitted.
local function modifier_held(self)
	if next(self.modifiers_down) then return true end
	for _, state in pairs(self.held) do
		if #state.emitted > 0 then return true end
	end
	return false
end

--- Passes an event through, keeping track of what the hand holds. A key this
--- engine already holds (CapsLock's Ctrl, then a physical Ctrl) is not pressed
--- again, and is lifted by whichever of the two lets go last.
--- @return table|nil nil to pass the event unchanged, {} to swallow it
local function pass(self, code, value)
	if value == REPEAT then return nil end
	if MODIFIER_KEYS[code] then self.modifiers_down[code] = value == DOWN or nil end
	self.passed_down[code] = value == DOWN or nil
	if self.key_refs[code] then return {} end
	return nil
end

--- A key typed by a tap. Already held through (Enter held while CapsLock types
--- Enter), it is lifted and pressed again: a keystroke all the same, and the
--- kernel's one bit for it ends as the user's hand has it.
local function tap_key(self, out, code)
	if self.key_refs[code] or self.passed_down[code] then
		out[#out + 1] = { code = code, value = UP }
		out[#out + 1] = { code = code, value = DOWN }
	else
		out[#out + 1] = { code = code, value = DOWN }
		out[#out + 1] = { code = code, value = UP }
	end
end

--- Presses a layer chord for `code` and remembers it until the key comes up.
local function press_layer_key(self, code, spec)
	local out = {}
	self.layer_keys[code] = spec
	chord_events(self, out, spec, DOWN)
	return out
end

--- Processes one physical key event.
--- @param code integer evdev code
--- @param value integer 0 up, 1 down, 2 repeat
--- @param now_ms number
--- @return table|nil events to dispatch instead (nil = pass the event through unchanged)
--- @return string|nil tap action to run after them
function M:process(code, value, now_ms)
	local config = self.by_code[code]
	local out = {}

	-- A key pressed on the layer keeps its chord until it is released, even if
	-- the layer key comes up first.
	local on_layer = self.layer_keys[code]
	if on_layer then
		if value == REPEAT then
			out[#out + 1] = { code = on_layer.keys[#on_layer.keys], value = REPEAT }
		elseif value == UP then
			self.layer_keys[code] = nil
			chord_events(self, out, on_layer, UP)
		end
		return out
	end

	-- Tab, Enter and their kind pressed while a modifier was down are the key
	-- itself (Ctrl+Tab, Shift+Tab), as on Windows, until released.
	if self.native_keys[code] then
		if value == UP then self.native_keys[code] = nil end
		return pass(self, code, value)
	end

	if config then
		if value == REPEAT then return out end
		if value == DOWN then
			if self.held[code] then return out end
			-- On the layer, a configured key is a layer key like any other.
			local spec = self.layer_depth > 0 and not config.layer and M.NAV_LAYER[code]
			if spec then
				cancel_taps(self, nil)
				return press_layer_key(self, code, spec)
			end
			if NATIVE_UNDER_MODIFIER[code] and modifier_held(self) then
				cancel_taps(self, nil)
				self.native_keys[code] = true
				return pass(self, code, value)
			end
			cancel_taps(self, code)
			local state = { down_at = now_ms, cancelled = false, emitted = {} }
			self.held[code] = state
			if config.layer then
				state.layer = true
				self.layer_depth = self.layer_depth + 1
			end
			for _, mod in ipairs(config.mods) do
				press(self, out, mod)
				state.emitted[#state.emitted + 1] = mod
			end
			return out
		end
		-- Release.
		local state = self.held[code]
		-- A release without its press here went down before this engine was
		-- installed: the hook decides, from what it forwarded, what it means.
		if not state then return nil end
		self.held[code] = nil
		for index = #state.emitted, 1, -1 do release(self, out, state.emitted[index]) end
		if state.layer then self.layer_depth = math.max(0, self.layer_depth - 1) end
		local elapsed = now_ms - state.down_at
		local is_tap = not state.cancelled and elapsed <= config.threshold_ms and elapsed >= self.tap_min_ms
		if not is_tap or config.tap == "none" then return out, nil end
		if config.tap == "" then
			-- The native key, as if nothing were configured on a tap.
			out[#out + 1] = { code = code, value = DOWN }
			out[#out + 1] = { code = code, value = UP }
			return out, nil
		end
		if config.tap == "one_shot_shift" then
			self.one_shot_until = now_ms + self.one_shot_timeout_ms
			return out, nil
		end
		local key_tap = M.KEY_TAPS[config.tap]
		if key_tap then
			tap_key(self, out, key_tap)
			return out, nil
		end
		return out, config.tap
	end

	-- Any other key: a chord for every held tap-hold key.
	if value == DOWN then cancel_taps(self, nil) end

	if self.layer_depth > 0 and value == DOWN then
		local spec = M.NAV_LAYER[code]
		if spec then return press_layer_key(self, code, spec) end
	end

	-- The one-shot Shift wraps the next key.
	if self.one_shot_keys[code] and value == UP then
		self.one_shot_keys[code] = nil
		release(self, out, code)
		release(self, out, KEY_LEFTSHIFT)
		return out
	end
	-- A modifier pressed meanwhile (Ctrl for Ctrl+Shift+T) leaves it armed.
	if self.one_shot_until and value == DOWN and not MODIFIER_KEYS[code] then
		local armed = now_ms <= self.one_shot_until
		self.one_shot_until = nil
		if armed and not self.one_shot_keys[code] then
			self.one_shot_keys[code] = true
			press(self, out, KEY_LEFTSHIFT)
			press(self, out, code)
			return out
		end
	end
	return pass(self, code, value)
end

--- A click or a wheel turn: it makes every held tap-hold key a chord.
function M:activity()
	cancel_taps(self, nil)
end

--- Releases everything this engine holds down and forgets its state.
--- @return table events Key-ups, in the reverse of the order they went down.
function M:release_all()
	local out = {}
	-- Every key this engine holds down, once, whoever of it holds it.
	-- Keys the hand still holds stay down: they are the kernel's to release.
	for code in pairs(self.key_refs) do
		if not self.passed_down[code] then out[#out + 1] = { code = code, value = UP } end
	end
	self.held, self.layer_keys, self.layer_depth = {}, {}, 0
	self.one_shot_until, self.one_shot_keys, self.key_refs = nil, {}, {}
	self.native_keys, self.modifiers_down, self.passed_down = {}, {}, {}
	return out
end

return M
