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
---    other key pressed, repeated or released, no click and no wheel in
---    between (Windows' A_PriorKey and activity tracker). A key with a tap and
---    no hold does what its Windows tap-only hotkey does: most fire at
---    key-down and at each repeat, LShift, LCtrl, RShift and AltGr stay
---    themselves, all four tapping on a quick release (NO_HOLD_BY_KEY).
--- 2. Pure: events in, events out, and the time in through M:tick for a hold
---    that waits for its threshold. The keyboard hook dispatches what comes out
---    exactly as if the user had pressed it, so the hotstring buffer, the
---    modifier state and the virtual keyboard see one consistent stream.
--- 3. Everything this engine presses, it can name and release: release_all()
---    returns the key-ups for every held modifier, layer key and one-shot, and
---    the hook calls it on stop, pause, resynchronisation and dialogs.
--- 4. It replaces kanata, which was optional, needed a newer glibc than Debian
---    12 and Ubuntu 22.04 ship, was never started by the daemon, and broke its
---    whole configuration on the first free-text action.
--- 5. A typing key is decided by the order of the releases. Space, Enter, Tab,
---    Backspace, Delete and Escape that keep their own key on a tap and gain a
---    hold (the shared `roll_keys`) are struck in the flow of text, where the
---    next key goes down before they come up: with the hold taken at key-down,
---    « word, Space, a » typed « wordA » and no space. Such a key stays
---    undecided and the keys struck meanwhile wait: it is a tap when it comes
---    up first or when a second key is struck (typing rolling on), and a hold
---    when the key struck under it comes up first or its threshold passes.
---    The waiting keys are then replayed in order, after the tap or under the
---    hold. Its tap needs no minimum duration and is not cancelled by the
---    release of an earlier key: both are what fast typing looks like.
--- 6. A key whose hold is a modifier taken at key-down, pressed alone, still
---    taps up to lone_tap_max_ms (tap_holds.lone_modifier_tap_max_ms, shared
---    rule in tap_hold.lone_tap); 0 keeps the strict threshold.
--- ==============================================================================

local EvdevCodes = require("infra.evdev_codes")
local OneShotShift = require("tap_hold.engine.one_shot_shift_core")
local LoneTap = require("tap_hold.engine.lone_tap")
local OneShotTimeout = require("tap_hold.engine.one_shot_timeout")
local InputEvent = require("infra.input_event")

local M = {}
-- Only the installed wrapper supplies the hook-backed port. Pure engine users
-- have no native authority and can leave it unset.
local roll_origin_ports = setmetatable({}, { __mode = "k" })
local roll_replay_origins = setmetatable({}, { __mode = "k" })
local roll_origins = setmetatable({}, { __mode = "k" })
local roll_journaling = setmetatable({}, { __mode = "k" })

--- Installs the original source-capture port only while the engine is idle.
function M:set_roll_origin_capture(capture, current)
	if type(capture) ~= "function" or type(current) ~= "function" or self.undecided
		or next(self.held) or next(self.key_refs) or next(self.layer_keys) or next(self.instant_down)
		or next(self.native_keys) or next(self.passed_down) or next(self.physical_down) or next(self.one_shot_keys)
		or next(self.one_shot_swallowed) or self.one_shot_until ~= nil
		or roll_origins[self] and next(roll_origins[self]) then return false end
	roll_origin_ports[self] = { capture = capture, current = current }
	return true
end

--- Marks an origin delivered only after its exact journal step is acknowledged.
function M:commit_roll_origin(token)
	local pending = roll_origins[self]
	if not pending or not pending[token] then return false end
	pending[token] = nil
	return true, next(pending) == nil
end

--- Returns the original uncommitted origins for the wrapper's retirement.
function M:take_roll_origins()
	local pending, result = roll_origins[self], {}
	if pending then
		for token in pairs(pending) do result[#result + 1] = token end
	end
	roll_origins[self] = nil
	return result
end

local function capture_roll_origin(self, code, at_ms, receipt)
	local replay = roll_replay_origins[self]
	if replay and replay.code == code and replay.at_ms == at_ms then return replay end
	local source = type(receipt) == "table" and { source = receipt.source, generation = receipt.generation,
		source_owner = receipt.source_owner } or nil
	local ports = roll_origin_ports[self]
	if not ports then return { code = code, at_ms = at_ms, receipt = source } end
	local ok, token = pcall(ports.capture, code, at_ms)
	if not ok or type(token) ~= "table" then return nil end
	local pending = roll_origins[self] or {}
	roll_origins[self] = pending
	pending[token] = true
	return { code = code, at_ms = at_ms, token = token, receipt = source }
end

local function roll_origin_current(self, origin)
	local ports = roll_origin_ports[self]
	if not ports then return true end
	if not origin or not origin.token then return false end
	local ok, current = pcall(ports.current, origin.token)
	return ok and current == true
end

local UP, DOWN, REPEAT = 0, 1, 2

-- evdev codes of the keys a tap-hold can be configured on (the Windows set).
-- Their order in the tray and their hand are the shared key catalogue's
-- ([tap_hold.catalog] in _shared/tap_hold/data/defaults.toml, its `linux` column),
-- which the manager holds to exactly these keys.
M.KEY_CODES = {
	escape = 1, tab = 15, caps_lock = 58, left_shift = 42, left_ctrl = 29,
	win = 125, left_alt = 56, space = 57, alt_gr = 100, right_ctrl = 97,
	right_shift = 54, enter = 28, backspace = 14, delete = 111,
}

-- evdev codes of the holdable modifiers.
M.MODIFIER_CODES = { ctrl = 29, shift = 42, alt = 56, alt_gr = 100, win = 125 }

-- The keys whose plain "ctrl" / "shift" hold is their own side (the right
-- Ctrl holds RCtrl, the right Shift holds RShift), as on Windows.
local OWN_SIDE_MODIFIER_CODES = { right_ctrl = { ctrl = 97 }, right_shift = { shift = 54 } }

local KEY_LEFTSHIFT = 42
-- Every usual modifier key, left and right.
local MODIFIER_KEYS = EvdevCodes.MODIFIER_OF
local KEY_LEFTCTRL, KEY_LEFTALT = 29, 56
-- The keys that are themselves under a held modifier (Ctrl+Tab, Shift+Tab,
-- Ctrl+Backspace), as the Windows hotkeys without a wildcard are. CapsLock
-- and the modifier keys stay tap-holds, so LShift and CapsLock held together
-- are Ctrl+Shift.
local NATIVE_UNDER_MODIFIER = { [1] = true, [14] = true, [15] = true, [28] = true, [57] = true, [111] = true }

-- What a key with a tap and no hold does while it is down, as its Windows
-- tap-only hotkey does (windows/platform/remap/<key>.ahk). Most fire the tap
-- at key-down and at each repeat (see fire_instant). These keys, and these
-- taps, wait for a quick release instead and hold meanwhile what the Windows
-- hotkey holds:
--   - LShift, LCtrl, RShift and AltGr stay the modifier they are, a ~ hotkey
--     that taps on a quick release (lshift_lctrl.ahk, rshift.ahk, altgr.ahk),
--     and so does RCtrl with a Tab tap (rctrl.ahk 7.2); `own` holds the key
--     itself, and a lone Right Alt, a plain Alt on some layouts, is masked
--     before its release (mask_lone_release);
--   - an alt_tab_monitor tap holds Alt for the switcher (tab.ahk 8.1,
--     lalt.ahk 4.3), from key-down as every hold is; LAlt's Tab with no hold
--     layer is no such rule: lalt.ahk 4.2 needs a hold layer, so it is the
--     generic tap-only block 4.9, a Tab at key-down and at each repeat;
--   - RCtrl's one-shot Shift holds Shift for a long press only once its
--     threshold has passed, as rctrl.ahk 7.3 presses it when its KeyWait
--     times out: a key typed sooner is typed unshifted (`hold_past_threshold`,
--     pressed by M:tick);
--   - LAlt's one-shot Shift is armed at key-down and holds Shift until the
--     key comes up (lalt.ahk 4.1): `tap_at_down`. Its hotkey has no *
--     wildcard, so under a held modifier LAlt stays Alt (`native_under_
--     modifier`), and it does nothing at all while RCtrl, CapsLock, LShift or
--     LCtrl is physically down (`skip_while_down`);
--   - the alt_tab_monitor taps and RCtrl's Tab tap wait for their release with
--     the key's own threshold (KS_WaitReleased(.., TapHoldDuration) in
--     tab.ahk 8.1, lalt.ahk 4.3, rctrl.ahk 7.2), never the lone tap window
--     the other held modifiers get (`strict_tap`).
local NO_HOLD_BY_KEY = {
	left_shift = { own = true }, left_ctrl = { own = true }, right_shift = { own = true },
	alt_gr = { own = true },
}
local NO_HOLD_BY_TAP = {
	tab = { alt_tab_monitor = { mods = { KEY_LEFTALT }, strict_tap = true } },
	left_alt = {
		alt_tab_monitor = { mods = { KEY_LEFTALT }, strict_tap = true },
		one_shot_shift = {
			mods = { KEY_LEFTSHIFT }, tap_at_down = true, native_under_modifier = true,
			skip_while_down = { EvdevCodes.KEY_RIGHTCTRL, EvdevCodes.KEY_CAPSLOCK, KEY_LEFTSHIFT, KEY_LEFTCTRL },
		},
	},
	right_ctrl = { tab = { own = true, strict_tap = true }, one_shot_shift = { mods = { KEY_LEFTSHIFT }, hold_past_threshold = true } },
}
-- The keys that must be up when a key goes down for its tap to fire, by key.
-- LCtrl taps only with CapsLock and LAlt up (lshift_lctrl.ahk 3.1, in its
-- tap-only and its hold variants), so CapsLock+LCtrl or LAlt+LCtrl let go
-- quickly runs no tap. Physical keys, whatever the layout makes of them.
local TAP_NEEDS_UP = { left_ctrl = { EvdevCodes.KEY_CAPSLOCK, KEY_LEFTALT } }
-- LAlt tapping Backspace with the layer on hold taps only with CapsLock up at
-- its release (lalt.ahk 4.5), against a Backspace on a quick LAlt+CapsLock.
local LAYER_BACKSPACE_TAP_NEEDS_UP_AT_RELEASE = { left_alt = { EvdevCodes.KEY_CAPSLOCK } }
local KEY_BACKSPACE, KEY_DELETE, KEY_RIGHT, KEY_TAB = 14, 111, 106, 15

-- Tap actions that are a single key. They are dispatched through the hook
-- like the key itself, so an Enter tapped on CapsLock ends a hotstring as a
-- real Enter does, and an armed one-shot Shift treats them as that key.
M.KEY_TAPS = { enter = 28, tab = 15, backspace = 14, escape = 1, delete = 111, space = 57, caps_lock = 58 }

-- The keys the layer swallows while another key holds it, by key, with the tap
-- and the hold that make them so: LAlt tapping Backspace with the layer on hold
-- (nav_layer.ahk, "Fix when LAlt triggers the layer"). Passed through, it was
-- an Alt under every chord of the layer (J gave Ctrl+Alt+Left).
local SWALLOWED_ON_LAYER = { left_alt = { tap = "backspace", layer = "nav" } }




-- =========================================
-- =========================================
-- ======= 1/ Construction =================
-- =========================================
-- =========================================

--- Creates an engine for one configuration.
--- @param opts table {
---   keys = { [key_id] = { tap_action, hold_modifier, hold_layer, time_activation_seconds, enabled } },
---   tap_min_ms = number, one_shot_timeout_ms = number,
---   lone_tap_max_ms = number, how long a modifier key pressed alone still taps,
---     0 for the strict tap-hold (tap_hold.lone_tap),
---   roll_keys = { key_id }|nil, the typing keys decided by the order of the
---     releases when they keep their own key on a tap and have a hold,
---   nav_layer = table|nil, explicitly compiled navigation chords; absent is native,
---   key_text = function(code) -> string|nil, the text a key would type now in
---     the live layout, nil for none;
---   plan_text = function(text) -> steps|nil, the keystrokes { keycode, mods }
---     the live layout types `text` with, nil when it cannot;
---   one_shot_result = function(char) -> string|nil, what the one-shot Shift
---     types for `char` instead of its capital (Space gives "-");
---   the three are required when a key taps the one-shot Shift,
---   tap_blocked = function(action) -> boolean, whether a catalogue tap is
---     unarmed right now (the AI actions while the AI is off): the key then
---     does what it does with no tap action, asked at each press and release
---     so that switching back on needs no reload; absent, none is,
---   held_modifiers = function() -> table, the modifiers down now, by role
---     ({ ctrl = true }), as the live layout names them (the keyboard hook's:
---     ctrl:nocaps makes CapsLock a Ctrl); without it, a caller with no layout
---     (the tests), the usual modifier keys the engine saw and its own holds,
---   held_text_modifier_codes = function() -> { code }, the keys down now that
---     select a level (Shift, AltGr), as the live layout names them (the
---     hook's); without it, Shift and Right Alt when the hand or a hold has
---     them down,
---   held_shortcut_modifier_codes = function() -> { code }, the same for Ctrl,
---     Alt and Super; without it, the usual Ctrl, Alt and Super keys the hand
---     or a hold has down,
---   caps_locked = function() -> boolean, whether Caps Lock is locked now (the
---     XKB state); plan_text plans with it off, so typed text releases it
---     around its keystrokes; without it, a caller with no layout, never,
--- }
--- @return table engine
function M.new(opts)
	local options = type(opts) == "table" and opts or {}
	if options.nav_layer ~= nil and type(options.nav_layer) ~= "table" then
		error("nav_layer must be a table of compiled navigation bindings", 2)
	end
	local self = {
		by_code = {},
		nav_layer = options.nav_layer or {},
		tap_min_ms = assert(tonumber(options.tap_min_ms), "tap_min_ms is required"),
		lone_tap_max_ms = LoneTap.validate(options.lone_tap_max_ms),
		one_shot_timeout_ms = OneShotTimeout.validate(options.one_shot_timeout_ms),
		tap_blocked = options.tap_blocked,
		key_text = options.key_text,
		plan_text = options.plan_text,
		one_shot_result = options.one_shot_result,
		held_modifiers = options.held_modifiers,
		held_text_modifier_codes = options.held_text_modifier_codes,
		held_shortcut_modifier_codes = options.held_shortcut_modifier_codes,
		caps_locked = options.caps_locked,
		held = {},          -- code -> { down_at, cancelled, emitted = {codes}, layer = bool }
		layer_depth = 0,     -- how many layer keys are down
		layer_keys = {},     -- code -> chord emitted for a key pressed on the layer
		-- How many times the next repeatable layer action sends its last chord:
		-- a repeat_count key sets it, any layer send and leaving the layer reset
		-- it to 1 (Windows' NumberOfRepetitions, nav_layer_helpers.ahk).
		repeat_count = 1,
		one_shot_until = nil,
		-- code -> "shift" while a one-shot Shift wraps it, "spent" once a later
		-- key took the Shift back, "rolled" for a key pressed then (several can overlap)
		one_shot_keys = {},
		one_shot_swallowed = {}, -- keys a one-shot Shift replaced by its result, until released
		native_keys = {},    -- configured keys pressed under a modifier: themselves until released
		instant_down = {},   -- keys with a tap and no hold, down since their tap fired
		key_refs = {},       -- code -> how many of this engine's holders keep it down
		key_order = {},      -- first-acquired keys, for reverse-order retirement
		passed_down = {},    -- keys that went through untouched and are down (the hand's)
		modifiers_down = {}, -- modifier keys that went through untouched, and are down
		physical_down = {},  -- every physical key down now, whatever this engine made of it
		undecided = nil,     -- code of the roll key down and not yet a tap or a hold
	}
	local roll_keys = {}
	for _, key_id in ipairs(type(options.roll_keys) == "table" and options.roll_keys or {}) do
		roll_keys[key_id] = true
	end
	for key_id, config in pairs(type(options.keys) == "table" and options.keys or {}) do
		local code = M.KEY_CODES[key_id]
		if code and type(config) == "table" and config.enabled ~= false then
			local mods = {}
			local left_forced = {}
			if type(config.hold_left_modifiers) == "string" then
				for part in config.hold_left_modifiers:gmatch("[^+]+") do left_forced[part] = true end
			end
			if type(config.hold_modifier) == "string" and config.hold_modifier ~= "" then
				-- The loader hands over canonical ids only: anything else here is a
				-- bug upstream, never a hold to drop without a word.
				for part in config.hold_modifier:gmatch("[^+]+") do
					local modifier_code = M.MODIFIER_CODES[part]
					-- The right Ctrl and right Shift keys hold their own side, as on
					-- Windows (_TapHoldOwnSideModifier), unless the file spelled the
					-- modifier with a left alias (lctrl, lshift).
					local own_side = OWN_SIDE_MODIFIER_CODES[key_id]
					if own_side and own_side[part] and not left_forced[part] then
						modifier_code = own_side[part]
					end
					if not modifier_code then
						error(string.format("tap-hold key '%s': '%s' is not a canonical hold modifier",
							tostring(key_id), config.hold_modifier), 2)
					end
					mods[#mods + 1] = modifier_code
				end
			end
			local layer = type(config.hold_layer) == "string" and config.hold_layer ~= "" and config.hold_layer or nil
			local tap = type(config.tap_action) == "string" and config.tap_action or ""
			local swallowed = SWALLOWED_ON_LAYER[key_id]
			local swallowed_on_layer = swallowed ~= nil and tap == swallowed.tap and layer == swallowed.layer
			if tap == "one_shot_shift" then
				for _, name in ipairs({ "key_text", "plan_text", "one_shot_result" }) do
					if type(options[name]) ~= "function" then
						error("a one-shot Shift needs " .. name .. ": what a key types is the layout's to say", 2)
					end
				end
			end
			-- A native tap and no hold is the key itself: left alone, so it keeps
			-- its autorepeat and its press is not delayed to its release.
			local no_hold = #mods == 0 and not layer
			if tap == "" and no_hold then goto continue end
			-- A tap and no hold follows the key's Windows hotkey (NO_HOLD_BY_KEY).
			local rule = no_hold and ((NO_HOLD_BY_TAP[key_id] or {})[tap] or NO_HOLD_BY_KEY[key_id]) or nil
			if rule then
				mods = rule.own and { code } or rule.mods or {}
				layer = rule.layer
			end
			self.by_code[code] = {
				id = key_id,
				tap = tap,
				mods = layer and {} or mods,
				layer = layer,
				swallowed_on_layer = swallowed_on_layer,
				-- The file's own hold modifier, whatever a layer or a rule makes of mods.
				holds_modifier = type(config.hold_modifier) == "string" and config.hold_modifier ~= "",
				-- A tap and no hold with no rule: nothing to wait for (see fire_instant).
				instant = no_hold and not rule,
				tap_at_down = rule and rule.tap_at_down or false,
				native_under_modifier = rule and rule.native_under_modifier or false,
				hold_past_threshold = rule and rule.hold_past_threshold or false,
				-- A typing key that is itself on a tap and has a hold (see 5.).
				roll = roll_keys[key_id] == true and not no_hold
					and (tap == "" or M.KEY_TAPS[tap] == code),
				skip_while_down = rule and rule.skip_while_down or nil,
				tap_needs_up = TAP_NEEDS_UP[key_id],
				tap_needs_up_at_release = (tap == "backspace" and layer)
					and LAYER_BACKSPACE_TAP_NEEDS_UP_AT_RELEASE[key_id] or nil,
				threshold_ms = math.floor((tonumber(config.time_activation_seconds) or 0) * 1000 + 0.5),
			}
			-- A modifier hold taken at key-down, on a key outside the typing keys:
			-- pressed alone, its tap may last up to lone_tap_max_ms (see 6.).
			local entry = self.by_code[code]
			-- A one-shot Shift is no such tap: armed by a long press, it would shift
			-- the next letter of a Shift the user held and let go unused.
			-- Every typing key is left out, as on macOS and Windows, whatever its tap.
			entry.lone_modifier = #entry.mods > 0 and not entry.layer and not roll_keys[key_id]
				and not entry.hold_past_threshold and not entry.tap_at_down and not entry.instant
				and not (rule and rule.strict_tap) and tap ~= "one_shot_shift"
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

--- Marks every held tap-hold key but one as used in a chord. An undecided
--- roll key is not used by the keys around it, which are typing: only a
--- click or the wheel (`pointer`) makes its press something else than a tap.
local function cancel_taps(self, except, pointer)
	for code, state in pairs(self.held) do
		if code ~= except and (pointer or not state.undecided) then state.cancelled = true end
	end
end

--- Presses a key for one more of this engine's holders. Only the first sends
--- it down, and not even that one when the hand already holds it: two holds of
--- one modifier (CapsLock and left Ctrl, both Ctrl), two layer keys that are
--- both Left, a physical Backspace and the layer's are each one key to the
--- kernel, and the first release must not lift it under the others.
local output_holders = setmetatable({}, { __mode = "k" })
local source_holds = setmetatable({}, { __mode = "k" })
local layer_sources = setmetatable({}, { __mode = "k" })
local instant_sources = setmetatable({}, { __mode = "k" })
local native_sources = setmetatable({}, { __mode = "k" })
local pass_observations = setmetatable({}, { __mode = "k" })
local source_physical = setmetatable({}, { __mode = "k" })

--- Retains producer custody separately from the stable public event shape.
local function hold_row(self, out, code, value)
	local row = { code = code, value = value }
	output_holders[row] = { engine = self, code = code, value = value }
	out[#out + 1] = row
end

--- Reads only this engine's exact, unchanged output row.
--- @param row table Original emitted row, never a caller copy.
--- @return string|nil holder Private producer domain or no hold receipt.
function M:output_holder(row)
	local owned = output_holders[row]
	if owned and owned.engine == self and row.code == owned.code and row.value == owned.value then return "hold" end
	return nil
end

local function custody(self, code, value, physical, out)
	local row = { code = code, value = value, physical = physical == true, holder = "hold" }
	if roll_journaling[self] then
		if out then out[#out + 1] = row end
		return row
	end
	self.output_custody = self.output_custody or {}
	self.output_custody[#self.output_custody + 1] = row
end

--- Returns explicit suppressed ownership edges; never invents a native ACK.
--- @return table rows Original/producer transitions suppressed from the wire.
function M:take_custody()
	local rows = self.output_custody or {}
	self.output_custody = {}
	return rows
end

local function press(self, out, code)
	local refs = (self.key_refs[code] or 0) + 1
	self.key_refs[code] = refs
	if refs == 1 then
		self.key_order[#self.key_order + 1] = code
		if self.passed_down[code] then custody(self, code, DOWN, false, out)
		else hold_row(self, out, code, DOWN) end
	end
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
	for index = #self.key_order, 1, -1 do
		if self.key_order[index] == code then table.remove(self.key_order, index); break end
	end
	if self.passed_down[code] then custody(self, code, UP, false, out)
	else hold_row(self, out, code, UP) end
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
		if #spec.keys > 0 then release(self, out, spec.keys[#spec.keys]) end
		for index = #spec.mods, 1, -1 do release(self, out, spec.mods[index]) end
	end
end

--- Whether a modifier is down. The live layout names the modifiers, so the
--- hook is asked when there is one; otherwise, a usual modifier key passed
--- through or one a hold emitted.
local function modifier_held(self)
	if self.held_modifiers then return next(self.held_modifiers()) ~= nil end
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
	local observation = pass_observations[self]
	if observation and observation.code == code and observation.value == value then observation.forwarded = true end
	if value == REPEAT then return nil end
	if MODIFIER_KEYS[code] then self.modifiers_down[code] = value == DOWN or nil end
	self.passed_down[code] = value == DOWN or nil
	if self.key_refs[code] then local row = custody(self, code, value, true); return row and { row } or {} end
	return nil
end

-- Modifiers whose lone release opens something: the menu bar of an
-- application with access keys (Alt, and AltGr on a layout where Right Alt is
-- plain Alt) or the desktop's launcher (Super).
local MENU_MODIFIERS = { [56] = true, [100] = true, [125] = true, [126] = true }

--- Masks a lone hold before its modifiers are released. A hold that saw no
--- other key would otherwise be a lone Alt or Super tap, and the tap output
--- that follows would land in the menu bar or the launcher. The masking tap is
--- the injector's own (KEY_F24, bound to nothing), and is only needed when one
--- of those modifiers really goes up now.
local function mask_lone_release(self, out, state)
	if state.cancelled then return end
	for _, mod in ipairs(state.emitted) do
		if MENU_MODIFIERS[mod] and (self.key_refs[mod] or 0) == 1 and not self.passed_down[mod] then
			out[#out + 1] = { code = EvdevCodes.KEY_F24, value = DOWN }
			out[#out + 1] = { code = EvdevCodes.KEY_F24, value = UP }
			return
		end
	end
end

--- A key typed by a tap. Already held through (Enter held while CapsLock types
--- Enter), it is lifted and pressed again: a keystroke all the same, and the
--- kernel's one bit for it ends as the user's hand has it.
local function tap_key(self, out, code)
	if self.key_refs[code] or self.passed_down[code] then
		out[#out + 1] = { code = code, value = UP, handoff = "suspended" }
		out[#out + 1] = { code = code, value = DOWN, handoff = "restored" }
	else
		out[#out + 1] = { code = code, value = DOWN }
		out[#out + 1] = { code = code, value = UP }
	end
end

--- Decides what an armed one-shot Shift does with a key going down, and spends
--- it when the key uses it up, as the Windows InputHook decides
--- (platform/remap/one_shot_shift.ahk). A key that types no text in the live
--- layout leaves it armed: a modifier, CapsLock, an arrow, Print, a volume key,
--- NumLock, a keypad key with NumLock off, any key under Ctrl, Alt or Super.
--- Backspace, Enter, Delete, Tab and Escape spend it and pass as they are. A
--- character spends it and becomes what Windows types for it: the shared
--- result when it has one (Space gives "-", "." gives " :"), otherwise its
--- title case, which leaves "1" and "," as they are where Shift made them "!"
--- and "?" (and a keypad 1 KP_End).
--- @param code integer The key going down, pressed by hand or typed by a tap.
--- @param now_ms number
--- @return string|nil verdict nil: the key passes as it is; "shift": wrap it
---   in Shift, which types its capital; "text": type `text` instead of it.
--- @return string|nil text
local input_arms = setmetatable({}, { __mode = "k" })

--- Publishes the existing logical deadline without acquiring output authority.
local function arm_one_shot(self, now_ms, guard)
	if type(now_ms) ~= "number" or now_ms ~= now_ms or math.abs(now_ms) == math.huge
		or type(self.key_text) ~= "function" or type(self.plan_text) ~= "function"
		or type(self.one_shot_result) ~= "function" then return false end
	if input_arms[self] and input_arms[self].state == "consumed" then return false end
	if guard then
		local ok, current = pcall(guard)
		if not ok or current ~= true then return false end
	end
	-- 0 is no time limit: the arm waits until a key spends or clears it.
	self.one_shot_until = OneShotTimeout.deadline(now_ms, self.one_shot_timeout_ms)
	input_arms[self] = guard and { current = guard, state = "armed" } or nil
	return true
end

--- Arms only the input owner's retained guard; standalone state creates no lease.
--- @param now_ms number Original event clock.
--- @param guard function Captured installed input-owner currency.
--- @return boolean published
function M:arm_one_shot(now_ms, guard)
	if type(guard) ~= "function" then return false end
	return arm_one_shot(self, now_ms, guard)
end

--- Observes private logical ownership without calling an external provider.
--- @return string|nil state
function M:input_arm_state()
	local arm = input_arms[self]
	return arm and arm.state or nil
end

--- Clears only an unspent logical arm; consumed output requires release_all ACK.
--- @return boolean cleared
function M:clear_input_arm()
	local arm = input_arms[self]
	if arm and arm.state == "consumed" then return false end
	if arm then self.one_shot_until, input_arms[self] = nil, nil end
	return true
end

local function input_arm_current(self, arm)
	if not arm then return true end
	local ok, current = pcall(arm.current)
	return ok and current == true and input_arms[self] == arm
end

--- Takes the one-shot Shift back from every key it still wraps. The Shift is
--- that press's own, kept for its repeats only: a key struck before it is
--- released is typed as it is, as on Windows, where the one-shot capture ends
--- at the first character. Keeping it down capitalised a fast roll (« abc »
--- gave « ABc »).
--- @return boolean spent Whether a Shift went up.
local function spend_one_shot_shift(self, out)
	local spent = false
	for wrapped, state in pairs(self.one_shot_keys) do
		if state == "shift" then
			self.one_shot_keys[wrapped] = "spent"
			release(self, out, KEY_LEFTSHIFT)
			spent = true
		end
	end
	return spent
end

--- Whether Caps Lock is locked now, as the live XKB state says.
--- @return boolean
local function caps_locked(self)
	return self.caps_locked ~= nil and self.caps_locked() == true
end

--- Toggles the Caps Lock state with one keystroke of its own.
local function toggle_caps_lock(out)
	out[#out + 1] = { code = EvdevCodes.KEY_CAPSLOCK, value = DOWN }
	out[#out + 1] = { code = EvdevCodes.KEY_CAPSLOCK, value = UP }
end

local function take_one_shot(self, code, now_ms)
	if not self.one_shot_until then return nil end
	local arm = input_arms[self]
	if not input_arm_current(self, arm) then self:clear_input_arm(); return nil end
	if MODIFIER_KEYS[code] or code == EvdevCodes.KEY_CAPSLOCK then return nil end
	local control = EvdevCodes.CONTROL_NAME_OF[code]
	if OneShotShift.spends_unshifted(control) then
		self.one_shot_until = nil
		input_arms[self] = nil
		return nil
	end
	local text = self.key_text(code)
	if not input_arm_current(self, arm) then self:clear_input_arm(); return nil end
	if type(text) ~= "string" or text == "" then return nil end
	local armed = now_ms <= self.one_shot_until
	self.one_shot_until = nil
	if not armed then input_arms[self] = nil; return nil end
	-- The capital on the same key's Shift level is that key under Shift: a real
	-- keystroke that repeats. Anywhere else ("É" on AZERTY), it is typed. The
	-- plan assumes Caps Lock off: locked, that Shift gives the lowercase (OSL-001),
	-- so the capital is typed with the lock released, as Windows types it.
	local locked = caps_locked(self)
	local verdict, result = OneShotShift.resolve(text, self.one_shot_result, function(title)
		if locked then return false end
		local steps = self.plan_text(title)
		local step = steps and #steps == 1 and steps[1]
		return step and step.keycode == code and #step.mods == 1 and step.mods[1] == "shift"
	end)
	if not input_arm_current(self, arm) then self:clear_input_arm(); return nil end
	if arm then
		if verdict then arm.state, arm.code = "consumed", code else input_arms[self] = nil end
	end
	return verdict, result
end

-- The level keys the engine counts as held when no live layout names them.
local USUAL_LEVEL_KEYS = { EvdevCodes.KEY_LEFTSHIFT, EvdevCodes.KEY_RIGHTSHIFT, EvdevCodes.KEY_RIGHTALT }

--- The keys down now that select a level: the live layout's (the hook's),
--- or Shift and Right Alt when the hand or a hold has them down.
--- @return table codes, each once
local function held_level_keys(self)
	local codes, seen = {}, {}
	local held = self.held_text_modifier_codes and self.held_text_modifier_codes() or nil
	if not held then
		held = {}
		for _, code in ipairs(USUAL_LEVEL_KEYS) do
			if self.passed_down[code] or self.key_refs[code] then held[#held + 1] = code end
		end
	end
	for _, code in ipairs(held) do
		if not seen[code] then
			seen[code] = true
			codes[#codes + 1] = code
		end
	end
	return codes
end

--- Types `text` as the keystrokes the live layout has for it, each held on
--- its level, so the hotstrings and the application see it typed. A text the
--- layout cannot type ("€" on a US layout) is handed back for the injector.
--- The steps choose their own level: a Shift or an AltGr still down, the
--- hand's or a hold's, would put each on another one (AZERTY's " :" typed as
--- " /" under Shift), so those are lifted around the text and pressed back
--- after it, as Windows' SendEvent {Text} lifts them.
--- @return table|nil tap { type_text = text } when the layout cannot type it.
local function type_text(self, out, text)
	local arm = input_arms[self]
	local steps = self.plan_text(text)
	if not input_arm_current(self, arm) then return nil end
	if not steps then return not arm and { type_text = text } or nil end
	local lifted = held_level_keys(self)
	if not input_arm_current(self, arm) then return nil end
	for _, code in ipairs(lifted) do out[#out + 1] = { code = code, value = UP, handoff = "suspended" } end
	-- The steps are planned with Caps Lock off; locked, every letter would
	-- invert, so the lock is released around them as the injector does.
	local locked = caps_locked(self)
	if locked then toggle_caps_lock(out) end
	for _, step in ipairs(steps) do
		local mods = {}
		for _, name in ipairs(step.mods or {}) do
			mods[#mods + 1] = assert(EvdevCodes.LEVEL_MODIFIER_CODE[name], "no key for the level modifier " .. tostring(name))
		end
		-- Every level key is up here, whoever held it: each step presses its own.
		for _, mod in ipairs(mods) do out[#out + 1] = { code = mod, value = DOWN } end
		tap_key(self, out, step.keycode)
		for index = #mods, 1, -1 do out[#out + 1] = { code = mods[index], value = UP } end
	end
	if locked then toggle_caps_lock(out) end
	for index = #lifted, 1, -1 do out[#out + 1] = { code = lifted[index], value = DOWN, handoff = "restored" } end
	return nil
end

--- Types the key a tap stands for, exactly as the same key pressed by hand
--- would reach an armed one-shot Shift. A tap bypassing it typed its Enter
--- unshifted and left the Shift for the next letter.
--- @return table|nil tap Text for the injector, as type_text returns it.
local function type_tap(self, out, code, now_ms)
	local verdict, text = take_one_shot(self, code, now_ms)
	if verdict == "text" then return type_text(self, out, text) end
	if verdict == "shift" then press(self, out, KEY_LEFTSHIFT) end
	tap_key(self, out, code)
	if verdict == "shift" then release(self, out, KEY_LEFTSHIFT) end
	return nil
end

-- The usual shortcut modifier keys, counted when no live layout names them.
local USUAL_SHORTCUT_KEYS = {
	KEY_LEFTCTRL, EvdevCodes.KEY_RIGHTCTRL, KEY_LEFTALT, EvdevCodes.KEY_LEFTMETA, EvdevCodes.KEY_RIGHTMETA,
}

--- Every modifier key down now: the level keys (held_level_keys) and the
--- shortcut ones, as the live layout names them (the hook's), or the usual
--- keys the hand or a hold has down. The hook answers before `out` reaches
--- it: a key `out` already lifts (the tapped key's own hold) is up.
--- @param out table The events this call dispatches so far.
--- @return table codes, each once
local function held_modifier_codes(self, out)
	local codes = held_level_keys(self)
	local shortcut = self.held_shortcut_modifier_codes and self.held_shortcut_modifier_codes() or nil
	if not shortcut then
		shortcut = {}
		for _, code in ipairs(USUAL_SHORTCUT_KEYS) do
			if self.passed_down[code] or self.key_refs[code] then shortcut[#shortcut + 1] = code end
		end
	end
	for _, code in ipairs(shortcut) do codes[#codes + 1] = code end
	local last = {}
	for _, ev in ipairs(out) do last[ev.code] = ev.value end
	local held, seen = {}, {}
	for _, code in ipairs(codes) do
		if last[code] ~= UP and not seen[code] then
			seen[code] = true
			held[#held + 1] = code
		end
	end
	return held
end

--- Types keystrokes with only their own modifiers, as Windows' TextPressKey
--- sends them: every modifier down now is lifted around them and pressed back
--- after, except a Ctrl when every keystroke is a Ctrl chord anyway.
--- @param chords table { { ctrl = boolean, shift = boolean|nil, key = code } }, typed in order.
local function type_chords(self, out, chords)
	local all_ctrl = true
	for _, chord in ipairs(chords) do all_ctrl = all_ctrl and chord.ctrl end
	local kept_ctrl, lifted = false, {}
	for _, code in ipairs(held_modifier_codes(self, out)) do
		if all_ctrl and MODIFIER_KEYS[code] == "ctrl" then
			kept_ctrl = true
		else
			lifted[#lifted + 1] = code
		end
	end
	for _, code in ipairs(lifted) do out[#out + 1] = { code = code, value = UP, handoff = "suspended" } end
	for _, chord in ipairs(chords) do
		local press_ctrl = chord.ctrl and not kept_ctrl
		if press_ctrl then out[#out + 1] = { code = KEY_LEFTCTRL, value = DOWN } end
		if chord.shift then out[#out + 1] = { code = KEY_LEFTSHIFT, value = DOWN } end
		tap_key(self, out, chord.key)
		if chord.shift then out[#out + 1] = { code = KEY_LEFTSHIFT, value = UP } end
		if press_ctrl then out[#out + 1] = { code = KEY_LEFTCTRL, value = UP } end
	end
	for index = #lifted, 1, -1 do out[#out + 1] = { code = lifted[index], value = DOWN, handoff = "restored" } end
end

--- Whether RCtrl, configured to tap the one-shot Shift, is physically down.
--- @return boolean
local function rctrl_one_shot_down(self)
	local rctrl_config = self.by_code[EvdevCodes.KEY_RIGHTCTRL]
	return self.physical_down[EvdevCodes.KEY_RIGHTCTRL] == true
		and rctrl_config ~= nil and rctrl_config.tap == "one_shot_shift"
end

--- What LAlt's Tab tap types under RCtrl tapping the one-shot Shift: Shift+Tab,
--- as lalt.ahk's `SC11D & SC038` combo sends it.
--- @return table|nil chords As type_chords takes them; nil for the plain key.
local function lalt_tab_chords(self)
	if rctrl_one_shot_down(self) then return { { ctrl = false, shift = true, key = KEY_TAB } } end
	return nil
end

--- What LAlt's Backspace tap types instead of a plain Backspace under the keys
--- physically down now, as Windows' BackSpaceLogic decides (lalt.ahk 4.10).
--- @return table|nil chords As type_chords takes them; nil for the plain key.
local function lalt_backspace_chords(self)
	local down = self.physical_down
	local lctrl, rctrl = down[KEY_LEFTCTRL], down[EvdevCodes.KEY_RIGHTCTRL]
	local shift = down[KEY_LEFTSHIFT] or down[EvdevCodes.KEY_RIGHTSHIFT]
	local rctrl_config = self.by_code[EvdevCodes.KEY_RIGHTCTRL]
	-- RCtrl tapping the one-shot Shift is a Shift, never a Ctrl, to this logic.
	local rctrl_one_shot = rctrl_config ~= nil and rctrl_config.tap == "one_shot_shift"
	local rctrl_ctrl = rctrl and not rctrl_one_shot
	if (lctrl or rctrl_ctrl) and shift then return { { ctrl = true, key = KEY_DELETE } } end
	-- Right then Backspace: a Delete that LAlt, still Alt to some, cannot turn
	-- into Ctrl+Alt+Delete.
	if rctrl and rctrl_one_shot then
		return { { ctrl = lctrl or false, key = KEY_RIGHT }, { ctrl = lctrl or false, key = KEY_BACKSPACE } }
	end
	if shift then return { { ctrl = false, key = KEY_DELETE } } end
	if lctrl or rctrl_ctrl then return { { ctrl = true, key = KEY_BACKSPACE } } end
	return nil
end

--- What RCtrl's Backspace tap types instead of a plain Backspace under the
--- keys physically down now, as rctrl.ahk decides (7.1 and _RCtrlBackspaceTap):
--- Delete under the left Shift, Right then Backspace under LAlt tapping the
--- one-shot Shift, whose Delete would be Ctrl+Alt+Delete.
--- @return table|nil chords As type_chords takes them; nil for the plain key.
local function rctrl_backspace_chords(self)
	local down = self.physical_down
	if down[KEY_LEFTSHIFT] then return { { ctrl = false, key = KEY_DELETE } } end
	local lalt_config = self.by_code[KEY_LEFTALT]
	if down[KEY_LEFTALT] and lalt_config ~= nil and lalt_config.tap == "one_shot_shift" then
		return { { ctrl = false, key = KEY_RIGHT }, { ctrl = false, key = KEY_BACKSPACE } }
	end
	return nil
end

-- The keys whose Backspace or Tab tap Windows types through a logic of its
-- own, by the key the tap types, then by key id.
local KEY_TAP_CHORDS = {
	[KEY_BACKSPACE] = { left_alt = lalt_backspace_chords, right_ctrl = rctrl_backspace_chords },
	[KEY_TAB] = { left_alt = lalt_tab_chords },
}

--- Types the key a tap stands for (type_tap), or what the key's Windows
--- Backspace logic types in its place under the keys held now. That logic's
--- keystrokes all end in a Delete, a Backspace or a Tab, which spend an armed
--- one-shot Shift, as its OneShotShiftFix does.
--- @return table|nil tap Text for the injector, as type_tap returns it.
local function type_key_tap(self, out, config, typed, now_ms)
	local logic = KEY_TAP_CHORDS[typed] and KEY_TAP_CHORDS[typed][config.id]
	local chords = logic and logic(self)
	if not chords then return type_tap(self, out, typed, now_ms) end
	self.one_shot_until = nil
	type_chords(self, out, chords)
	return nil
end

--- The tap a key runs now: its configured one, or no tap action (the key's
--- own) when that is a catalogue action unarmed right now. Key taps, the
--- one-shot Shift and "none" are the engine's own and are never unarmed.
--- @return string tap
local function effective_tap(self, config)
	local tap = config.tap
	if tap == "" or tap == "none" or tap == "one_shot_shift" or M.KEY_TAPS[tap] then return tap end
	if self.tap_blocked and self.tap_blocked(tap) == true then return "" end
	return tap
end

--- Fires the tap of a key that has no hold, at its key-down and at each of its
--- repeats, as the Windows hotkey of such a key does (escape.ahk "Fire
--- immediately on key-down"): there is no hold to tell it from, so waiting for
--- the release only delayed it and lost the auto-repeat. Also LAlt's one-shot
--- Shift at key-down (NO_HOLD_BY_TAP).
--- @return table out, string|table|nil tap As M:process returns them.
local function fire_instant(self, out, config, now_ms)
	local tap = effective_tap(self, config)
	if tap == "none" then return out, nil end
	if tap == "one_shot_shift" then
		arm_one_shot(self, now_ms)
		return out, nil
	end
	-- An unarmed action leaves the key's own press.
	local typed = tap == "" and M.KEY_CODES[config.id] or M.KEY_TAPS[tap]
	if typed then return out, type_key_tap(self, out, config, typed, now_ms) end
	return out, tap, "tap_hold__" .. config.id
end

--- Runs one event through the engine and appends what comes out, the event
--- itself when the engine passes it unchanged.
--- @return string|table|nil tap As M:process returns it.
local function replay(self, out, code, value, now_ms, origin)
	local receipt = origin and origin.receipt
	if type(receipt) == "table" and type(receipt.source) == "string" then
		receipt = { source = receipt.source, generation = receipt.generation, source_owner = receipt.source_owner,
			source_current = true, physical_down = self.physical_down }
	end
	local previous, previous_journaling, previous_pass = roll_replay_origins[self], roll_journaling[self], pass_observations[self]
	roll_replay_origins[self], pass_observations[self] = origin, nil
	if roll_origin_ports[self] then roll_journaling[self] = true end
	local ok, events, tap, binding, journal = pcall(self.process, self, code, value, now_ms, receipt)
	roll_replay_origins[self], roll_journaling[self], pass_observations[self] = previous, previous_journaling, previous_pass
	if not ok then error(events, 0) end
	local rows = {}
	if events == nil then
		rows[1] = { code = code, value = value, physical = true }
	else
		for _, event in ipairs(events) do rows[#rows + 1] = event end
	end
	for _, event in ipairs(rows) do out[#out + 1] = event end
	return tap, binding, rows, journal
end

--- Decides an undecided roll key and replays the keys struck meanwhile, in
--- order: after its tap, or under its hold.
--- @param code integer The roll key.
--- @param decision string "tap" or "hold".
--- @param released boolean|nil True when the key itself came up.
--- @return table out, string|table|nil tap As M:process returns them.
local function resolve_roll_body(self, code, decision, now_ms, released)
	local config, state = self.by_code[code], self.held[code]
	local out, tap, binding = {}, nil, nil
	local queue = state.queue
	if not roll_origin_current(self, state.origin) then return {}, nil, nil, { refused = true } end
	for _, queued in ipairs(queue) do
		if not roll_origin_current(self, queued) then return {}, nil, nil, { refused = true } end
	end
	state.undecided, state.queue = nil, nil
	self.undecided = nil
	if released then self.held[code] = nil end
	if decision == "hold" then
		for _, mod in ipairs(config.mods) do
			press(self, out, mod)
			state.emitted[#state.emitted + 1] = mod
		end
		if config.layer then
			state.layer = true
			self.layer_depth = self.layer_depth + 1
		end
		-- A key struck under the hold made it a chord: no tap at the release.
		if #queue > 0 then state.cancelled = true end
	else
		state.tapped = true
		-- A click or the wheel during the press made it something else than typing.
		if not state.cancelled then
			local roll_tap = effective_tap(self, config)
			tap = type_key_tap(self, out, config, roll_tap == "" and code or M.KEY_TAPS[roll_tap], now_ms)
		end
	end
	local journal = { { rows = out, tap = tap, binding = binding, origin = state.origin and state.origin.token } }
	-- Keep the first segment detached: replay appends to the legacy output too.
	journal[1].rows = {}; for _, event in ipairs(out) do journal[1].rows[#journal[1].rows + 1] = event end
	for _, queued in ipairs(queue) do
		local queued_tap, queued_binding, rows, nested = replay(self, out, queued.code, DOWN, queued.at_ms, queued)
		if nested and nested.refused then return out, tap, binding, nested end
		if nested then for _, segment in ipairs(nested) do journal[#journal + 1] = segment end
		else journal[#journal + 1] = { rows = rows, tap = queued_tap, binding = queued_binding, origin = queued.token } end
		if tap == nil then tap, binding = queued_tap, queued_binding end
	end
	return out, tap, binding, roll_origin_ports[self] and journal or nil
end


-- Custody transitions generated while resolving belong to the same ordered,
-- acknowledged segment as the rest of that original input's output.
local function resolve_roll(self, code, decision, now_ms, released)
	local previous = roll_journaling[self]
	if roll_origin_ports[self] then roll_journaling[self] = true end
	local ok, rows, tap, binding, journal = pcall(resolve_roll_body, self, code, decision, now_ms, released)
	roll_journaling[self] = previous
	if not ok then error(rows, 0) end
	return rows, tap, binding, journal
end

--- Another key's event while a roll key is undecided.
--- @return boolean handled False for an event of a key that was down before
---   the roll key: its repeats and its release are its own.
--- @return table|nil out, string|table|nil tap As M:process returns them.
local function roll_other_key(self, pending, code, value, now_ms, receipt)
	local state = self.held[pending]
	if value == DOWN then
		local origin = capture_roll_origin(self, code, now_ms, receipt)
		if not origin then return true, {}, nil, nil, { refused = true } end
		state.queue[#state.queue + 1] = origin
		-- A second key struck before either came up: typing rolling on.
		if #state.queue >= 2 then return true, resolve_roll(self, pending, "tap", now_ms) end
		return true, {}
	end
	local waiting = false
	local queued_origin
	for _, queued in ipairs(state.queue) do if queued.code == code then waiting, queued_origin = true, queued end end
	if not waiting then return false end
	if value == REPEAT then return true, {} end
	-- Struck and let go while the roll key is still down: its hold.
	local out, tap, binding, journal = resolve_roll(self, pending, "hold", now_ms)
	if journal and journal.refused then return true, out, tap, binding, journal end
	local released_tap, released_binding, rows, nested = replay(self, out, code, UP, now_ms, queued_origin)
	if journal then
		if nested then for _, segment in ipairs(nested) do journal[#journal + 1] = segment end
		else journal[#journal + 1] = { rows = rows, tap = released_tap, binding = released_binding, origin = queued_origin.token } end
	end
	if tap == nil then tap, binding = released_tap, released_binding end
	return true, out, tap, binding, journal
end

-- The chord a repeat_count key holds until its release: nothing.
local NO_CHORD = { mods = {}, keys = {} }

--- Appends a layer binding's events: a repeat_count row sets the count and
--- sends nothing; a counted sequence sends its last chord that many times, as
--- Windows sends "{Up N}". Every send but `none` resets the count to 1.
--- @return table final The chord left down, released with the source key.
local function layer_binding_events(self, out, spec)
	if spec.repeat_count then
		self.repeat_count = spec.repeat_count
		return NO_CHORD
	end
	local chords, first = spec.chords or { spec }, #out
	local final = assert(chords[#chords], "a navigation binding needs a final chord")
	for index = 1, #chords - 1 do
		chord_events(self, out, chords[index], DOWN)
		chord_events(self, out, chords[index], UP)
	end
	for _ = 2, spec.counted and self.repeat_count or 1 do
		chord_events(self, out, final, DOWN)
		chord_events(self, out, final, UP)
	end
	chord_events(self, out, final, DOWN)
	if #out > first then self.repeat_count = 1 end
	return final
end

--- Leaving the layer forgets a count no action used, as Windows' ActivateLayer
--- starts every hold at 1.
local function reset_repeat_off_layer(self)
	if self.layer_depth <= 0 then self.repeat_count = 1 end
end

--- Presses a layer chord for `code` and remembers it until the key comes up.
local function press_layer_key(self, code, spec)
	local out = {}
	self.layer_keys[code] = layer_binding_events(self, out, spec)
	return out
end

--- Swallows a key's press, its repeats and its release: held with nothing to
--- hold and no tap.
--- @return table out No events.
local function swallow_until_release(self, code, now_ms)
	self.held[code] = { down_at = now_ms, cancelled = true, emitted = {}, tapped = true }
	return {}
end

--- Processes one physical key event.
--- @param code integer evdev code
--- @param value integer 0 up, 1 down, 2 repeat
--- @param now_ms number
--- @return table|nil events to dispatch instead (nil = pass the event through unchanged)
--- @return string|table|nil tap What to run after them: a catalogue action, or
---   { type_text } for text the layout cannot type
--- @return string|nil binding Exact tap_hold__ source of a catalogue action.
local function process(self, code, value, now_ms, scoped, receipt, skip_layer, skip_native)
	local config = self.by_code[code]
	local out = {}
	if not scoped and value == DOWN then
		self.physical_down[code] = true
	elseif not scoped and value == UP then
		self.physical_down[code] = nil
	end

	-- A roll key not yet decided: the keys struck meanwhile wait for it.
	if self.undecided and code ~= self.undecided then
		local handled, events, tap, binding, journal = roll_other_key(self, self.undecided, code, value, now_ms, receipt)
		if handled then return events, tap, binding, journal end
	end

	-- A release is activity too, as on Windows (hook_dispatcher's _OnKeyUp): a
	-- key held before a tap-hold key and let go during it was used with it. So
	-- is an auto-repeat: a Windows tap fires only when the key itself was the
	-- last key pressed (A_PriorKey counts repeats, and the InputHook tracker
	-- sees each repeated key-down), and a key held on another keyboard keeps
	-- repeating through the tap. A key's own events are not activity for it.
	if value == UP or value == REPEAT then cancel_taps(self, code) end

	-- A key pressed on the layer keeps its chord until it is released, even if
	-- the layer key comes up first.
	local on_layer = not skip_layer and self.layer_keys[code]
	if on_layer then
		if value == REPEAT then
			if #on_layer.keys > 0 then
				hold_row(self, out, on_layer.keys[#on_layer.keys], REPEAT)
			end
		elseif value == UP then
			self.layer_keys[code] = nil
			chord_events(self, out, on_layer, UP)
		end
		return out
	end

	-- Tab, Enter and their kind pressed while a modifier was down are the key
	-- itself (Ctrl+Tab, Shift+Tab), as on Windows, until released.
	if not skip_native and self.native_keys[code] then
		if value == UP then self.native_keys[code] = nil end
		return pass(self, code, value)
	end

	if config then
		if self.instant_down[code] then
			if value == UP then self.instant_down[code] = nil end
			if value == REPEAT then return fire_instant(self, out, config, now_ms) end
			return out
		end
		if value == REPEAT then return out end
		if value == DOWN then
			if self.held[code] then return out end
			-- Another key holds the layer (this one is not down), and no tap-hold
			-- is on there, as every Windows tap-hold hotkey needs the layer off:
			-- a key the layer maps is the layer's key, its own hold the layer
			-- included (CapsLock is its Backspace); LAlt tapping Backspace is
			-- swallowed (SWALLOWED_ON_LAYER); any other key is itself, with its
			-- auto-repeat (Space types a space, LShift is a Shift that copies
			-- nothing, RCtrl a Ctrl, Tab a Tab).
			-- The swallower comes first: nav_layer.ahk's static *SC038 is created
			-- before the layer's bindings and AHK fires the earliest variant.
			if self.layer_depth > 0 then
				cancel_taps(self, nil)
				if config.swallowed_on_layer then return swallow_until_release(self, code, now_ms) end
				local spec = self.nav_layer[code]
				if spec then return press_layer_key(self, code, spec) end
				self.native_keys[code] = true
				return pass(self, code, value)
			end
			-- LAlt tapping Tab with no hold modifier, struck under RCtrl tapping
			-- the one-shot Shift, is lalt.ahk's `SC11D & SC038` combo, whatever
			-- its hold layer: Shift+Tab at key-down and at each repeat.
			if config.id == "left_alt" and config.tap == "tab" and not config.holds_modifier
				and rctrl_one_shot_down(self) then
				cancel_taps(self, nil)
				self.instant_down[code] = true
				return fire_instant(self, out, config, now_ms)
			end
			local native_under_modifier = NATIVE_UNDER_MODIFIER[code] or config.native_under_modifier
			if native_under_modifier and modifier_held(self) then
				cancel_taps(self, nil)
				self.native_keys[code] = true
				return pass(self, code, value)
			end
			for _, blocker in ipairs(config.skip_while_down or {}) do
				if self.physical_down[blocker] then
					cancel_taps(self, code)
					return swallow_until_release(self, code, now_ms)
				end
			end
			-- A tap-hold key struck under a wrapped key takes its Shift back too.
			spend_one_shot_shift(self, out)
			if config.instant then
				cancel_taps(self, nil)
				self.instant_down[code] = true
				return fire_instant(self, out, config, now_ms)
			end
			cancel_taps(self, code)
			-- A roll key takes nothing yet: the next events decide (resolve_roll).
			if config.roll then
				local origin = capture_roll_origin(self, code, now_ms, receipt)
				if not origin then self.native_keys[code] = true; return pass(self, code, value) end
				self.held[code] = { down_at = now_ms, cancelled = false, emitted = {}, undecided = true, queue = {}, origin = origin }
				self.undecided = code
				return out
			end
			local state = { down_at = now_ms, cancelled = false, emitted = {} }
			for _, needed_up in ipairs(config.tap_needs_up or {}) do
				if self.physical_down[needed_up] then state.tap_blocked = true end
			end
			self.held[code] = state
			if config.layer then
				state.layer = true
				self.layer_depth = self.layer_depth + 1
			end
			-- A hold taken only past the threshold is pressed by M:tick.
			if config.hold_past_threshold then
				state.hold_pending = true
				return out
			end
			for _, mod in ipairs(config.mods) do
				press(self, out, mod)
				state.emitted[#state.emitted + 1] = mod
			end
			if config.tap_at_down then
				state.tapped = true
				return fire_instant(self, out, config, now_ms)
			end
			return out
		end
		-- Release.
		local state = self.held[code]
		-- A release without its press here went down before this engine was
		-- installed: the hook decides, from what it forwarded, what it means.
		if not state then return nil end
		-- A roll key that comes up first is a tap, then the key struck over it.
		if state.undecided then return resolve_roll(self, code, "tap", now_ms, true) end
		self.held[code] = nil
		mask_lone_release(self, out, state)
		for index = #state.emitted, 1, -1 do release(self, out, state.emitted[index]) end
		if state.layer then self.layer_depth = math.max(0, self.layer_depth - 1); reset_repeat_off_layer(self) end
		local elapsed = now_ms - state.down_at
		local is_tap = not state.cancelled and not state.tap_blocked
			and elapsed <= LoneTap.tap_max_ms(config.threshold_ms, config.lone_modifier, self.lone_tap_max_ms)
			and elapsed >= self.tap_min_ms
		for _, needed_up in ipairs(config.tap_needs_up_at_release or {}) do
			if self.physical_down[needed_up] then is_tap = false end
		end
		local tap = effective_tap(self, config)
		if state.tapped or not is_tap or tap == "none" then return out, nil end
		if tap == "one_shot_shift" then
			arm_one_shot(self, now_ms)
			return out, nil
		end
		-- The native key (as if nothing were configured on a tap) or a key tap.
		local typed = tap == "" and code or M.KEY_TAPS[tap]
		if typed then
			return out, type_key_tap(self, out, config, typed, now_ms)
		end
		return out, tap, "tap_hold__" .. config.id
	end

	-- A key the one-shot Shift replaced by its result: its repeats and its
	-- release belong to the result, which is already typed.
	if self.one_shot_swallowed[code] then
		if value == UP then
			self.one_shot_swallowed[code] = nil
			if input_arms[self] and input_arms[self].code == code then input_arms[self] = nil end
		end
		return out
	end

	-- Any other key: a chord for every held tap-hold key.
	if value == DOWN then cancel_taps(self, nil) end

	if self.layer_depth > 0 and value == DOWN then
		local spec = self.nav_layer[code]
		if spec then return press_layer_key(self, code, spec) end
	end

	-- The one-shot Shift wraps the next key.
	local wrapped = self.one_shot_keys[code]
	if wrapped and value == UP then
		self.one_shot_keys[code] = nil
		release(self, out, code)
		if wrapped == "shift" then release(self, out, KEY_LEFTSHIFT) end
		if input_arms[self] and input_arms[self].code == code then input_arms[self] = nil end
		return out
	end
	-- The repeat belongs to the engine that pressed the key, whichever way the
	-- one-shot was armed: a physical tap sets only the deadline, no input arm,
	-- and its repeat used to fall through as a physical row the broker refuses.
	if wrapped and value == REPEAT then
		hold_row(self, out, code, REPEAT)
		return out
	end
	if value == DOWN and not wrapped then
		-- A key struck while a wrapped one is still down goes down after its
		-- Shift is up, and is this engine's to release, like the wrapped key.
		local rolled = not MODIFIER_KEYS[code] and spend_one_shot_shift(self, out)
		local verdict, text = take_one_shot(self, code, now_ms)
		if verdict == "shift" then
			self.one_shot_keys[code] = "shift"
			press(self, out, KEY_LEFTSHIFT)
			press(self, out, code)
			return out
		elseif verdict == "text" then
			self.one_shot_swallowed[code] = true
			return out, type_text(self, out, text)
		end
		if rolled then
			self.one_shot_keys[code] = "rolled"
			press(self, out, code)
			return out
		end
	end
	return pass(self, code, value)
end

--- Each native source owns its own standalone hold. A concurrent same-code
--- press adds a modifier reference but cannot inherit the first source's tap.
--- Its UP can retire only the state admitted by its own original DOWN.
function M:process(code, value, now_ms, receipt)
	local source = type(receipt) == "table" and rawget(receipt, "source") or nil
	local generation = source and rawget(receipt, "generation") or nil
	local native_owner = source and rawget(receipt, "source_owner") or nil
	local scoped = type(source) == "string" and source ~= "" and type(generation) == "number"
	if scoped and native_owner and rawget(receipt, "source_current") ~= true then return {} end
	if scoped then
		-- The hook observes even physical edges the pair policy did not pass to
		-- this engine. Direct users without that snapshot track each source here.
		local snapshot = rawget(receipt, "physical_down")
		if type(snapshot) == "table" then
			self.physical_down = {}
			for key, down in pairs(snapshot) do if down == true then self.physical_down[key] = true end end
		else
			local sources = source_physical[self] or {}; source_physical[self] = sources
			local down = sources[code] or {}; sources[code] = down
			if value == DOWN then down[source] = true elseif value == UP then down[source] = nil end
			self.physical_down[code] = next(down) ~= nil and true or nil
		end
	end
	-- Instant actions keep their own press and repeat lifetime per source.
	local instant_groups = instant_sources[self]
	local instant_group = scoped and instant_groups and instant_groups[code] or nil
	local instant_owner = instant_group and instant_group[source] or nil
	if instant_owner then
		if instant_owner.generation ~= generation or not rawequal(instant_owner.native_owner, native_owner) then return {} end
		if value == DOWN then return {} end
		if value == UP then
			cancel_taps(self, code)
			instant_group[source] = nil
			if next(instant_group) == nil then instant_groups[code] = nil; self.instant_down[code] = nil end
			return {}
		end
		if value == REPEAT then
			cancel_taps(self, code)
			if instant_owner.swallowed then return {} end
			return fire_instant(self, {}, self.by_code[code], now_ms)
		end
	end
	local layer_groups = layer_sources[self]
	local layer_group = scoped and layer_groups and layer_groups[code] or nil
	local existing_holds = scoped and source_holds[self] and source_holds[self][code] or nil
	local layer_owner = layer_group and layer_group[source] or nil
	local hold_owner = existing_holds and existing_holds[source] or nil
	local bypass_layer = hold_owner ~= nil

	-- Native pass-through selected under a layer/modifier is likewise owned
	-- per keyboard: one release cannot retire the surviving key's repeats.
	local native_groups = native_sources[self]
	local native_group = scoped and native_groups and native_groups[code] or nil
	local bypass_native = native_group ~= nil and native_group[source] == nil
	if native_group then
		local own = native_group[source]
		if own and (own.generation ~= generation or not rawequal(own.native_owner, native_owner)) then return {} end
		if own then
			if value == DOWN then return {} end
			if value == UP then
				cancel_taps(self, code)
				native_group[source] = nil
				local remaining = next(native_group) ~= nil
				if not remaining then native_groups[code] = nil; self.native_keys[code] = nil end
				local rows = pass(self, code, value)
				if remaining then
					self.passed_down[code] = true
					if MODIFIER_KEYS[code] then self.modifiers_down[code] = true end
				end
				return rows
			end
			if value == REPEAT then cancel_taps(self, code); return pass(self, code, value) end
		elseif value ~= DOWN and not layer_owner and not hold_owner then return {} end
	end
	-- A mapped chord is shared only by sources that pressed while its layer
	-- was active. A later source follows its own current configuration.
	if layer_group and not bypass_layer then
		local own = layer_owner
		if own and (own.generation ~= generation or not rawequal(own.native_owner, native_owner)) then return {} end
		if value == DOWN then
			if own then return {} end
			if self.layer_depth <= 0 then bypass_layer = true
			else layer_group[source] = { generation = generation, native_owner = native_owner }; return {} end
		elseif not own then return {}
		elseif value == UP then
			layer_group[source] = nil
			if next(layer_group) ~= nil then cancel_taps(self, code); return {} end
			layer_groups[code] = nil
			return process(self, code, value, now_ms, scoped, receipt)
		end
	end
	local groups = source_holds[self]
	if scoped and not groups then groups = {}; source_holds[self] = groups end
	local group = groups and groups[code]
	if scoped and group then
		local own = group[source]
		if own and (own.generation ~= generation or not rawequal(own.native_owner, native_owner)) then return {} end
		if value == DOWN then
			if own then return {} end
			-- A new physical source selects the active layer before sharing an
			-- older source's held tap-hold state.
			local config = self.by_code[code]
			-- A swallowed key never takes the layer's binding (see process).
			local layer_spec = self.layer_depth > 0 and not (config and config.swallowed_on_layer) and self.nav_layer[code]
			if layer_spec and not layer_group then
				cancel_taps(self, nil)
				local rows = press_layer_key(self, code, layer_spec)
				layer_groups = layer_groups or {}; layer_sources[self] = layer_groups
				layer_groups[code] = { [source] = { generation = generation, native_owner = native_owner } }
				return rows
			end
			if self.layer_depth > 0 and not layer_spec and config and config.swallowed_on_layer then
				cancel_taps(self, nil)
				instant_groups = instant_groups or {}; instant_sources[self] = instant_groups
				instant_group = instant_group or {}; instant_groups[code] = instant_group
				instant_group[source] = { generation = generation, native_owner = native_owner, swallowed = true }
				return {}
			end
			if self.layer_depth > 0 and not layer_spec and config and not config.swallowed_on_layer then
				cancel_taps(self, nil)
				self.native_keys[code] = true
				native_groups = native_groups or {}; native_sources[self] = native_groups
				native_group = native_group or {}; native_groups[code] = native_group
				native_group[source] = { generation = generation, native_owner = native_owner }
				return pass(self, code, value)
			end
			local original = self.held[code]
			if not original then return {} end
			if original.undecided then
				-- The second source is a concurrent physical hold, not another tap
				-- of the first source. Capture its own DOWN before deciding the roll.
				local origin = capture_roll_origin(self, code, now_ms, receipt)
				if not origin or source_holds[self] ~= groups or groups[code] ~= group
					or group[source] ~= nil or self.held[code] ~= original then
					return {}, nil, nil, { refused = true }
				end
				local out, tap, binding, journal = resolve_roll(self, code, "hold", now_ms)
				if journal and journal.refused then return out, tap, binding, journal end
				if source_holds[self] ~= groups or groups[code] ~= group
					or group[source] ~= nil or self.held[code] ~= original then
					return {}, nil, nil, { refused = true }
				end
				original.cancelled = true
				local state = { down_at = now_ms, cancelled = true, emitted = {},
					layer = original.layer, hold_pending = original.hold_pending }
				local extra = {}
				for _, mod in ipairs(original.emitted) do
					press(self, extra, mod); state.emitted[#state.emitted + 1] = mod
				end
				if state.layer then self.layer_depth = self.layer_depth + 1 end
				group[source] = { state = state, generation = generation, native_owner = native_owner }
				self.physical_down[code] = true
				for _, row in ipairs(extra) do out[#out + 1] = row end
				if journal then journal[#journal + 1] = { rows = extra, origin = origin.token } end
				return out, tap, binding, journal
			end
			local out, state = {}, { down_at = now_ms, cancelled = true, emitted = {},
				layer = original.layer, hold_pending = original.hold_pending }
			for _, other in pairs(group) do other.state.cancelled = true end
			for _, mod in ipairs(original.emitted) do
				press(self, out, mod); state.emitted[#state.emitted + 1] = mod
			end
			if state.layer then self.layer_depth = self.layer_depth + 1 end
			group[source] = { state = state, generation = generation, native_owner = native_owner }
			self.physical_down[code] = true
			return out
		elseif not own then return {}
		elseif value == UP then
			self.held[code], group[source] = own.state, nil
			local out, tap, binding, journal = process(self, code, value, now_ms, scoped, receipt, bypass_layer, bypass_native)
			if source_holds[self] ~= groups or groups[code] ~= group then return out, tap, binding, journal end
			local _, remaining = next(group)
			if remaining then self.held[code], self.physical_down[code] = remaining.state, true
			else groups[code] = nil end
			return out, tap, binding, journal
		end
	end
	-- Another source holding an instant key must not hide this new DOWN from
	-- normal layer and modifier precedence. Restore its aggregate flag afterward.
	local separate_instant = scoped and value == DOWN and instant_group ~= nil and instant_owner == nil
	if separate_instant then self.instant_down[code] = nil end
	local out, tap, binding, journal
	local observation
	if bypass_layer or bypass_native or (scoped and value == DOWN) then
		local previous = pass_observations[self]
		observation = { code = code, value = value, forwarded = false }
		pass_observations[self] = observation
		local ok
		ok, out, tap, binding, journal = pcall(process, self, code, value, now_ms, scoped, receipt, bypass_layer, bypass_native)
		pass_observations[self] = previous
		if not ok then error(out, 0) end
	else
		out, tap, binding, journal = process(self, code, value, now_ms, scoped, receipt)
	end
	local acquired_instant = scoped and value == DOWN and self.instant_down[code] == true
	if acquired_instant then
		instant_groups = instant_groups or {}; instant_sources[self] = instant_groups
		instant_group = instant_group or {}; instant_groups[code] = instant_group
		instant_group[source] = { generation = generation, native_owner = native_owner }
	end
	if separate_instant and not acquired_instant then self.instant_down[code] = true end
	if scoped and value == DOWN and ((not bypass_native and self.native_keys[code]) or (observation and observation.forwarded)) then
		native_groups = native_groups or {}; native_sources[self] = native_groups
		native_group = native_group or {}; native_groups[code] = native_group
		native_group[source] = { generation = generation, native_owner = native_owner }
	end
	if scoped and value == DOWN and self.layer_keys[code] and not layer_group and not bypass_layer then
		layer_groups = layer_sources[self] or {}; layer_sources[self] = layer_groups
		layer_groups[code] = { [source] = { generation = generation, native_owner = native_owner } }
	end
	if scoped and source_holds[self] == groups and value == DOWN and self.held[code] and not group then
		groups[code] = { [source] = { state = self.held[code], generation = generation, native_owner = native_owner } }
	end
	return out, tap, binding, journal
end

--- A click, its release or a wheel turn: it makes every held tap-hold key a
--- chord.
function M:activity()
	cancel_taps(self, nil, true)
end

--- Whether the engine needs the mouse: the held navigation layer binds a wheel
--- direction or a mouse button, or a bound button is still down. The keyboard
--- hook then owns the pointer, so a bound notch never also scrolls and a bound
--- click never also clicks.
--- @return boolean
function M:pointer_bound()
	for code in pairs(self.layer_keys) do
		if InputEvent.is_pointer_button(code) then return true end
	end
	if self.layer_depth <= 0 then return false end
	for _, codes in pairs(InputEvent.WHEEL_LAYER_CODES) do
		for _, code in pairs(codes) do
			if self.nav_layer[code] then return true end
		end
	end
	for code in pairs(self.nav_layer) do
		if InputEvent.is_pointer_button(code) then return true end
	end
	return false
end

--- One mouse button event of a mouse the hook took for the layer: a press the
--- held layer binds runs that binding and keeps its last chord down until the
--- button comes up, as a keyboard key on the layer does (Windows registers the
--- layer's mouse buttons as hotkeys). Anything else is nil and reaches the
--- desktop.
--- @param code integer evdev button code (BTN_LEFT ...).
--- @param value integer 0 up, 1 down, 2 repeat.
--- @return table|nil events Key events to dispatch instead of the button.
function M:button(code, value)
	local on_layer = self.layer_keys[code]
	if on_layer then
		local out = {}
		if value == UP then
			self.layer_keys[code] = nil
			chord_events(self, out, on_layer, UP)
		end
		return out
	end
	if value ~= DOWN or self.layer_depth <= 0 then return nil end
	local spec = self.nav_layer[code]
	if not spec then return nil end
	return press_layer_key(self, code, spec)
end

--- The held layer's binding of one wheel direction, or nil.
--- @param axis string "vertical" or "horizontal".
--- @param direction integer 1 or -1.
--- @return table|nil spec
function M:wheel_binding(axis, direction)
	if self.layer_depth <= 0 then return nil end
	local code = InputEvent.wheel_layer_code(axis, direction)
	return code and self.nav_layer[code] or nil
end

--- One wheel notch while the navigation layer is held: the binding of that
--- direction, pressed and released (volume up for each notch, as on Windows),
--- or nil when the layer leaves this direction alone and the notch scrolls.
--- @param axis string "vertical" or "horizontal".
--- @param direction integer 1 or -1, the sign evdev reports.
--- @return table|nil events Key events to dispatch instead of the notch.
function M:wheel(axis, direction)
	local spec = self:wheel_binding(axis, direction)
	if not spec then return nil end
	local out = {}
	chord_events(self, out, layer_binding_events(self, out, spec), UP)
	return out
end

--- Lets time pass: presses the hold of every key held past its threshold
--- whose hold waits for it (RCtrl's one-shot Shift, as rctrl.ahk 7.3 presses
--- it when its KeyWait times out). The keyboard hook calls it before each key
--- event, at that event's time, and from its pump once every event read is
--- dispatched, so the hold is down for a key typed after the threshold and
--- never for one typed sooner.
--- @param now_ms number On the clock the key events carry.
--- An undecided roll key past its threshold becomes its hold too, and the key
--- struck under it is replayed.
--- @return table events What to dispatch, each with `owner`, the code of the
---   key whose hold it is: key events, and { tap = … } for an action a
---   replayed key runs, with its own canonical `binding`.
function M:tick(now_ms)
	local out = {}
	local pending = self.undecided
	if pending and now_ms - self.held[pending].down_at > self.by_code[pending].threshold_ms then
		local events, tap, binding, journal = resolve_roll(self, pending, "hold", now_ms)
		if roll_origin_ports[self] and journal then return { { roll_journal = journal } } end
		for _, event in ipairs(events) do
			event.owner = pending
			out[#out + 1] = event
		end
		if tap ~= nil then out[#out + 1] = { tap = tap, binding = binding, owner = pending } end
	end
	for code, primary in pairs(self.held) do
		local group = source_holds[self] and source_holds[self][code]
		local states = group or { { state = primary } }
		for _, owner in pairs(states) do
			local state, config = owner.state, self.by_code[code]
			if state.hold_pending and now_ms - state.down_at > config.threshold_ms then
				state.hold_pending = nil
				local first = #out + 1
				for _, mod in ipairs(config.mods) do
					press(self, out, mod)
					state.emitted[#state.emitted + 1] = mod
				end
				for index = first, #out do out[index].owner = code end
			end
		end
	end
	return out
end

--- Releases everything this engine holds down and forgets its state.
--- @return table events Key-ups, in the reverse of the order they went down.
function M:release_all()
	native_sources[self] = nil
	instant_sources[self] = nil
	layer_sources[self] = nil
	source_holds[self] = nil
	source_physical[self] = nil
	local out = {}
	-- Every key this engine holds down, once, whoever of it holds it.
	-- Keys the hand still holds stay down: they are the kernel's to release.
	for index = #self.key_order, 1, -1 do
		local code = self.key_order[index]
		if self.passed_down[code] then custody(self, code, UP, false, out)
		else hold_row(self, out, code, UP) end
	end
	self.held, self.layer_keys, self.layer_depth, self.repeat_count = {}, {}, 0, 1
	self.undecided = nil
	self.one_shot_until, self.one_shot_keys, self.key_refs = nil, {}, {}
	self.key_order = {}
	input_arms[self] = nil
	self.one_shot_swallowed, self.instant_down = {}, {}
	self.native_keys, self.modifiers_down, self.passed_down = {}, {}, {}
	-- The hook swallows the rest of every key it took from this engine, so
	-- their releases never come back here.
	self.physical_down = {}
	return out
end


--- Pure first-press eligibility before acquiring any standalone hold. Navigation,
--- existing owners and native-under-modifier/instant precedence are unchanged.
function M:combination_first_available(code)
	if self.layer_depth > 0 or self.undecided or next(self.held) or self.held[code] or self.native_keys[code] or self.instant_down[code]
		or self.layer_keys[code] or self.one_shot_until then return false end
	local config = self.by_code[code]
	if config then
		if config.instant or config.tap_at_down or (NATIVE_UNDER_MODIFIER[code] or config.native_under_modifier) and modifier_held(self) then return false end
		for _, blocker in ipairs(config.skip_while_down or {}) do if self.physical_down[blocker] then return false end end
	end
	return true
end

--- Narrow composition ports for configured ordered pairs. These retain the
--- existing reference counts: lifting one owner's Ctrl cannot lift another's.
function M:combination_hold(spec)
	local out, state = {}, { emitted = {}, layer = false }
	for _, code in ipairs(spec.mods or {}) do press(self, out, code); state.emitted[#state.emitted + 1] = code end
	if spec.layer then self.layer_depth = self.layer_depth + 1; state.layer = true end
	return out, state
end
function M:combination_release(state)
	local out = {}
	for index = #state.emitted, 1, -1 do release(self, out, state.emitted[index]) end
	if state.layer then self.layer_depth = self.layer_depth - 1; reset_repeat_off_layer(self) end
	state.emitted, state.layer = {}, false
	return out
end
function M:combination_lift(code)
	local first = self.held[code]
	if not first or first.undecided then return {}, nil end
	first.cancelled = true
	local frame = { first = first, code = code, emitted = first.emitted, layer = first.layer }
	first.emitted, first.layer = {}, false
	local out = {}
	for index = #frame.emitted, 1, -1 do release(self, out, frame.emitted[index]) end
	if frame.layer then self.layer_depth = self.layer_depth - 1 end
	return out, frame
end
function M:combination_restore(frame)
	local out = {}
	if not frame or self.held[frame.code] ~= frame.first then return out end
	for _, code in ipairs(frame.emitted) do press(self, out, code) end
	if frame.layer then self.layer_depth = self.layer_depth + 1 end
	frame.first.emitted, frame.first.layer = frame.emitted, frame.layer
	return out
end
return M
