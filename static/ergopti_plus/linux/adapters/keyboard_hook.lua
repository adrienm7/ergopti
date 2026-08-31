--- adapters/keyboard_hook.lua

--- ==============================================================================
--- MODULE: KeyboardHook Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the KeyboardHook port contract defined in
--- static/ergopti_plus/_shared/core/ports/KeyboardHook.spec.js. Turns the kernel
--- event streams from the owned /dev/input/eventN devices into the domain-level
--- on_char / on_key / on_physical callbacks.
---
--- HOW IT READS, AND WHY IT CHANGED:
--- It reads the device. It used to run `evtest --grab` (or `libinput
--- debug-events`) under io.popen and parse the PROSE those tools print. That cost
--- four things at once: a blocking pipe read, so the tray and every timer
--- advanced only when a key arrived; a hard dependency on a binary the user had
--- to install; a lossy parse, when re-emission under a grab has to be exact; and
--- no control over EVIOCGRAB, which belonged to the child process. Reading the
--- descriptor through adapters/evdev_reader.lua removes all four.
---
--- FEATURES & RATIONALE:
--- 1. Two modes, one code path. "intercept" takes EVIOCGRAB, so nothing reaches
---    the desktop except what this adapter re-emits through the caller's channel;
---    "observe" opens the same descriptor and skips one ioctl. There is no second
---    implementation to drift, which is what the previous pair of parsers was.
--- 2. Re-emit first, dispatch second. Under a grab the application must already
---    show the trigger when the injector erases it. Anything typed during the
---    injection is still in the kernel buffer and is read afterwards, so it lands
---    after the replacement instead of interleaving with it — the structural fix
---    for the "abcd" → "acd" corruption, which no amount of internal queueing
---    could provide while the OS still delivered keys directly.
--- 3. Autorepeat produces characters. Under a grab the application sees exactly
---    what is re-emitted, repeats included, so a buffer that ignored value 2
---    would believe the user typed "a" while the screen said "aaaa" — and then
---    erase the wrong number of characters. Repeats do NOT count as physical
---    presses: the keystroke metrics measure keys pressed, not keys held.
--- 4. Identity by code, characters by live XKB state. Modifiers and named
---    control keys come from infra/evdev_codes.lua; printable text comes from
---    adapters/xkb_capture.lua, using the server's complete keymap and every
---    down/up transition. Static QWERTY/AZERTY tables cannot represent locks,
---    groups, AltGr, Compose or compositor customisations.
--- 5. Nothing blocks. pump() drains what is ready and returns; the descriptor is
---    O_NONBLOCK, so an idle daemon costs one failed read per loop rather than a
---    stalled event loop.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local EvdevReader = require("adapters.evdev_reader")
local EvdevCodes = require("infra.evdev_codes")
local Monotonic = require("infra.monotonic")
local InputEvent = require("infra.input_event")
local XkbCapture = require("adapters.xkb_capture")

local LOG = "adapters.keyboard_hook"

local TEXT_CONTROL_CHAR = {
	enter = "\n",
	tab = "\t",
}




-- =========================================
-- =========================================
-- ======= 1/ Internal State ===============
-- =========================================
-- =========================================

-- Callbacks set by the caller via M.start().
local _on_char      = nil   -- function(char_string, evdev_scancode)
local _on_key       = nil   -- function(key_name_string)
local _on_physical  = nil   -- function(evdev_scancode, key_name, char_or_nil)
local _on_hold      = nil   -- function(evdev_scancode, held_ms)

-- Cached foreground window context (updated via refreshContext).
local _context  = { appId = "", windowTitle = "" }

-- Running flag — set after the device is successfully opened.
local _running  = false

-- Every owned keyboard and observed pointer path. The first keyboard remains in
-- _device for the public log/status contract, but it is never the whole state.
local _devices = {}
local _pointer_devices = {}
local _device = nil

-- One unread event per source for the timestamp merge. Heads survive a bounded
-- pump so an older backlog entry can never be overtaken on the next iteration.
local _pending_events = {}

-- A CLI-selected device is an ownership policy, not merely the first path to
-- open. The watchdog may re-open this exact node after a disconnect, but it must
-- never replace it with the auto-detected preference.
local _pinned_device = nil
local _pinned_missing = false

-- True after a watchdog acquisition failure, so later checks keep retrying even
-- though there is temporarily no open descriptor.
local _reacquiring = false

-- Layout name resolved at start() time ("qwerty" or "azerty").
local _layout   = "qwerty"

-- Intercept mode flag.
local _intercept = false

-- Raw re-emit channel used in intercept mode — function(evdev_code, evdev_value).
-- Injected per capture session through start({ onEmitRaw = … }) rather than
-- required here, because the caller owns the output stream (the injector's
-- uinput channel in production, a recorder in the harness). Rebound on every
-- start() so a session can never inherit a previous session's emitter.
local _emit_raw = nil

-- Only EV_KEY is forwarded. The uinput channel appends its own SYN_REPORT after
-- each key, so forwarding the source stream's EV_SYN would double it; EV_MSC is
-- duplicate scancode metadata the desktop derives from the key report itself;
-- EV_LED and EV_REP are output and configuration, not input.
local EVDEV_TYPE_KEY = InputEvent.EV_KEY

-- Modifier tracking — updated by _dispatch_event() on each press/release.
-- Split by ROLE, not by key: shift and AltGr select a level of the layout and
-- therefore produce characters; ctrl, alt and meta start a shortcut and
-- therefore produce none. Treating AltGr as Alt is how a French keyboard loses
-- é, € and « — or how Alt+Tab ends up in the typing buffer.
local _shift_held = false
local _ctrl_held  = false
local _alt_held   = false
local _altgr_held = false
local _meta_held  = false

-- Physical modifier keys currently down, keyed by evdev code, and a count per
-- role. A single boolean cannot represent Left+Right Shift: releasing either
-- one used to clear Shift even while the other remained held.
local _modifier_down = {}
local _modifier_count = { shift = 0, ctrl = 0, alt = 0, altgr = 0, meta = 0 }
local _modifier_order = {}

-- When each key went down, by evdev code. Cleared on release, so a key still
-- held when a flush lands is simply not reported until it comes up.
local _pressed_at = {}

-- Beyond this, a "hold" is not a hold. A release can arrive after a suspend, a
-- lost descriptor or a lid close, and a single reading of several hours would
-- dominate every average it entered for the rest of the day. Ten seconds is far
-- longer than any deliberate hold and far shorter than any of those accidents.
local MAX_PLAUSIBLE_HOLD_MS = 10000

-- How many periodic ticks pass between device checks. The daemon ticks four
-- times a second and the check re-reads /proc/bus/input/devices, so every tick
-- would be four small file reads per second for an event that happens when a
-- keyboard is unplugged or the remap daemon restarts — twice a day at most.
local DEVICE_CHECK_TICKS = 8

-- Ticks since the last device check.
local _ticks_since_check = 0

-- Set once when no device at all can be found, so the log says it once rather
-- than every two seconds for as long as the keyboard stays unplugged.
local _reported_missing = false

-- Called when a pointer button is pressed, if the caller asked for it.
local _on_click = nil

-- evdev button codes start at BTN_MISC. Everything at or above it on a pointer
-- is a button; everything below is a keyboard key, and a pointer reports none.
local BTN_FIRST = 0x100

local function keyboard_slot(path)
	return "keyboard:" .. path
end

local function pointer_slot(path)
	return "pointer:" .. path
end

local function source_key(source, code)
	return tostring(source or "keyboard") .. ":" .. tostring(code)
end

local function same_paths(left, right)
	if #left ~= #right then return false end
	for index, path in ipairs(left) do
		if right[index] ~= path then return false end
	end
	return true
end




-- =========================================
-- =========================================
-- ======= 2/ XKB Capture Wiring ===========
-- =========================================
-- =========================================

-- Legacy resolver used ONLY by the pure-Lua hook harness. Production never
-- reaches it: the harness has no LuaJIT FFI or Linux keymap, while its older
-- event-routing tests still need deterministic printable characters.
local _input_reader = nil
local _test_capture_event = nil

local function _get_input_reader()
	if _input_reader then return _input_reader end
	local ok, mod = pcall(require, "modules.hotstrings.input_reader")
	if ok then
		_input_reader = mod
	else
		Logger.error(LOG, "Cannot load input_reader — keyboard hook will be inactive.")
	end
	return _input_reader
end

local function _legacy_capture_for_test(code, value)
	if value == InputEvent.VALUE_UP
		or EvdevCodes.MODIFIER_OF[code]
		or code == EvdevCodes.KEY_CAPSLOCK
	then
		return nil, nil, nil
	end
	local ir = _get_input_reader()
	if not ir or not ir.resolve_char then return nil, nil, "test input_reader unavailable" end
	local char = ir.resolve_char(code, _layout, _shift_held)
	return char, char, nil
end

--- Resolves and commits one event through the production XKB state or the
--- explicit pure-Lua test seam.
--- @param code integer evdev keycode.
--- @param value integer 0 release, 1 press, 2 repeat.
--- @return string|nil text, string|nil identity, string|nil error
local function _capture(code, value)
	if _test_capture_event then return _test_capture_event(code, value) end
	return XkbCapture.process(code, value)
end




-- =========================================
-- =========================================
-- ======= 3/ Event Dispatch ===============
-- =========================================
-- =========================================

--- Updates the held-modifier flags from a key transition.
--- @param source string Source identity.
--- @param code integer evdev keycode.
--- @param value integer evdev value: 0 release, 1 press, 2 repeat.
--- @return boolean True when the code was a modifier and nothing else applies.
local function _track_modifier(source, code, value)
	local modifier = EvdevCodes.MODIFIER_OF[code]
	if not modifier then return false end
	local key = source_key(source, code)
	if value == InputEvent.VALUE_DOWN and not _modifier_down[key] then
		_modifier_down[key] = modifier
		_modifier_count[modifier] = _modifier_count[modifier] + 1
		_modifier_order[#_modifier_order + 1] = { key = key, code = code }
	elseif value == InputEvent.VALUE_UP and _modifier_down[key] then
		_modifier_down[key] = nil
		_modifier_count[modifier] = math.max(0, _modifier_count[modifier] - 1)
		for index = #_modifier_order, 1, -1 do
			if _modifier_order[index].key == key then
				table.remove(_modifier_order, index)
				break
			end
		end
	end
	_shift_held = _modifier_count.shift > 0
	_ctrl_held  = _modifier_count.ctrl > 0
	_alt_held   = _modifier_count.alt > 0
	_altgr_held = _modifier_count.altgr > 0
	_meta_held  = _modifier_count.meta > 0
	return true
end

local function _reset_modifier_state()
	_modifier_down = {}
	_modifier_count = { shift = 0, ctrl = 0, alt = 0, altgr = 0, meta = 0 }
	_modifier_order = {}
	_shift_held, _ctrl_held, _alt_held = false, false, false
	_altgr_held, _meta_held = false, false
end

--- True while a modifier that starts a SHORTCUT is held.
--- Deliberately excludes shift and AltGr, which select a layout level and
--- produce text.
--- @return boolean
local function _shortcut_modifier_held()
	return _ctrl_held or _alt_held or _meta_held
end

--- Handles one decoded event: re-emits it when we own the stream, then turns it
--- into the domain callbacks.
--- @param ev table { type = integer, code = integer, value = integer }.
--- @param source string|nil Stable source identity.
local function _dispatch_event(ev, source)
	-- Intercept mode grabbed the device, so nothing reaches the application
	-- except through here: put the raw event back BEFORE doing anything else.
	-- Order is the whole point — an injection triggered by this event must run
	-- against an application that already shows the character. In observe mode
	-- the physical event was never consumed, and re-emitting would type it twice.
	if _intercept and _emit_raw and ev.type == EVDEV_TYPE_KEY then
		local ok_emit, emitted = pcall(_emit_raw, ev.code, ev.value)
		if not ok_emit or emitted ~= true then
			local reason = ok_emit and "emitter returned false" or tostring(emitted)
			M.emergency_stop(string.format(
				"raw pass-through failed (code=%d value=%d): %s",
				ev.code, ev.value, reason))
			return
		end
	end

	if ev.type ~= EVDEV_TYPE_KEY then return end

	local pressed = ev.value ~= InputEvent.VALUE_UP
	-- Every key transition reaches XKB before any routing early-return. Modifier,
	-- CapsLock and group-switch releases carry no text, but dropping them here
	-- leaves the state machine permanently different from the desktop.
	local char, identity, capture_err = _capture(ev.code, ev.value)
	if capture_err then
		Logger.error(LOG, "XKB capture failed (code=%d value=%d) — %s.",
			ev.code, ev.value, tostring(capture_err))
	end

	-- XKB has already consumed the transition above. Modifiers still produce no
	-- domain event; returning here prevents a test double or a malformed keymap
	-- from inventing a typed character for a physical modifier.
	if _track_modifier(source, ev.code, ev.value) then return end

	-- CapsLock is neither a modifier this driver tracks nor a character.
	if ev.code == EvdevCodes.KEY_CAPSLOCK then return end

	-- How long the key was held, measured here because this is the only place a
	-- release is seen at all.
	--
	-- The line below used to say releases carry no meaning past modifier
	-- tracking, and for the text path that is true. It is not true for the
	-- metrics: on a keyboard whose whole design is tap-hold, how long a key was
	-- held is the difference between the two things it can mean, and
	-- agg_app_day_kc_hold was empty because nothing measured it.
	if ev.value == InputEvent.VALUE_DOWN and ev.code > 0 then
		_pressed_at[source_key(source, ev.code)] = Monotonic.now_ms()
	elseif ev.value == InputEvent.VALUE_UP and ev.code > 0 then
		local pressed_key = source_key(source, ev.code)
		local down_at = _pressed_at[pressed_key]
		_pressed_at[pressed_key] = nil
		if down_at and _on_hold then
			-- Clamped, because a release can arrive after a suspend, a lost
			-- descriptor or a lid close, and one such reading would dominate every
			-- average it entered for the rest of the day.
			local held_ms = math.min(math.max(0, Monotonic.now_ms() - down_at), MAX_PLAUSIBLE_HOLD_MS)
			pcall(_on_hold, ev.code, held_ms)
		end
	end

	-- Releases carry no meaning past modifier tracking and the hold above.
	if not pressed then return end

	-- The layout-independent physical identity, for the hardware heatmap. It must
	-- never be inferred back from the produced character: AZERTY, dead keys and
	-- shortcuts make that lossy. Autorepeat is excluded because the metric counts
	-- keys pressed, and a held key is one press.
	if _on_physical and ev.value == InputEvent.VALUE_DOWN and ev.code > 0 then
		pcall(_on_physical, ev.code, EvdevCodes.key_name(ev.code), char)
	end

	local control = EvdevCodes.CONTROL_NAME_OF[ev.code]
	if control then
		local text_char = TEXT_CONTROL_CHAR[control]
		if text_char and not _shortcut_modifier_held() then
			-- Enter and Tab are both control keys and enabled hotstring
			-- terminators. Bare presses belong to the matcher; modified presses
			-- remain controls so Alt+Tab and Ctrl+Enter never become text.
			if _on_char then pcall(_on_char, text_char, ev.code) end
		elseif _on_key then
			pcall(_on_key, control)
		end
		return
	end

	-- Ctrl+S is not the letter S. The layout still resolves a character for the
	-- key, so without this the buffer filled up with every shortcut the user
	-- pressed and expansions fired against text nobody typed. Reported as a
	-- control event so the caller drops the buffer: the caret has almost
	-- certainly moved, and what came before it no longer describes the line.
	if _shortcut_modifier_held() then
		-- The chord's IDENTITY travels with the event. Reporting only "shortcut"
		-- told the caller that the caret had probably moved and nothing else, so
		-- the daemon could neither record which shortcut fired nor act on one —
		-- `keylogger.record_shortcut` had no caller at all, and the configurable
		-- slots had nothing to match against.
		--
		-- A second argument rather than a different event name: every existing
		-- caller takes one parameter and ignores this, so the contract widens
		-- without any of them changing.
		if _on_key then
			pcall(_on_key, "shortcut", { key = identity or char, mods = M.held_modifiers() })
		end
		return
	end

	if char and _on_char then
		pcall(_on_char, char, ev.code)
	end
end




-- =========================================
-- =========================================
-- ======= 4/ Context Helpers ==============
-- =========================================
-- =========================================

local function _read_context()
	local ok, window_info = pcall(require, "adapters.window_info")
	if not ok then return end
	local ok2, info = pcall(window_info.getFocused)
	if ok2 and type(info) == "table" then
		_context.appId       = info.appId or ""
		_context.windowTitle = info.windowTitle or ""
	end
end




-- =========================================
-- =========================================
-- ======= 5/ Event Pump ===================
-- =========================================
-- =========================================

local function _dispatch_pointer(ev)
	if ev.type == EVDEV_TYPE_KEY
		and ev.code >= BTN_FIRST
		and ev.value == InputEvent.VALUE_DOWN
	then
		pcall(_on_click, ev.code)
	end
end

local function _read_source(source)
	local event, status, reason = EvdevReader.read_event(source.slot)
	if status ~= "fatal" then return event end
	Logger.error(LOG, "Fatal evdev read on %s — %s; scheduling re-acquisition.",
		source.path, tostring(reason))
	_pending_events[source.slot] = nil
	if source.keyboard then
		local any_open = false
		for _, path in ipairs(_devices) do
			if EvdevReader.is_open(keyboard_slot(path)) then
				any_open = true
				break
			end
		end
		_running = any_open
		_reacquiring = true
	end
	return nil
end

local function _event_precedes(left_event, left_source, right_event, right_source)
	local left_time = type(left_event.timestamp_us) == "number" and left_event.timestamp_us or 0
	local right_time = type(right_event.timestamp_us) == "number" and right_event.timestamp_us or 0
	if left_time ~= right_time then return left_time < right_time end
	if left_source.priority ~= right_source.priority then
		return left_source.priority < right_source.priority
	end
	return left_source.path < right_source.path
end

--- Drains ready events in global kernel-timestamp order and returns.
---
--- Called from the daemon's idle callback. Nothing here blocks: the descriptor is
--- O_NONBLOCK and the merge is globally bounded, so the tray, periodic tick and
--- file watchers advance even under an autorepeat backlog.
function M.pump()
	if not _running then return end
	local open_keyboards = 0
	local sources = {}
	for _, path in ipairs(_devices) do
		local slot = keyboard_slot(path)
		if EvdevReader.is_open(slot) then
			open_keyboards = open_keyboards + 1
			sources[#sources + 1] = { slot = slot, path = path, priority = 2, keyboard = true }
		end
	end
	if open_keyboards == 0 then
		Logger.warn(LOG, "Every keyboard source is closed — waiting for re-acquisition.")
		_running = false
		_reacquiring = true
		return
	end

	if _on_click then
		for _, path in ipairs(_pointer_devices) do
			local slot = pointer_slot(path)
			if EvdevReader.is_open(slot) then
				sources[#sources + 1] = { slot = slot, path = path, priority = 1, keyboard = false }
			end
		end
	end

	for _, source in ipairs(sources) do
		if not _pending_events[source.slot] then
			_pending_events[source.slot] = _read_source(source)
		end
	end
	for _ = 1, EvdevReader.MAX_EVENTS_PER_DRAIN do
		local selected = nil
		for _, source in ipairs(sources) do
			local event = _pending_events[source.slot]
			if event and (not selected or _event_precedes(
				event, source, _pending_events[selected.slot], selected))
			then
				selected = source
			end
		end
		if not selected then break end
		local selected_event = _pending_events[selected.slot]
		_pending_events[selected.slot] = nil
		if selected.keyboard then
			_dispatch_event(selected_event, selected.path)
		else
			_dispatch_pointer(selected_event)
		end
		_pending_events[selected.slot] = _read_source(selected)
	end
end

--- The layout-level modifiers the user is physically holding right now.
---
--- Injection asks before it starts, and neutralises what it finds. Under a grab
--- the application has already seen the press we re-emitted, so it believes the
--- modifier is down; an injected "e" would arrive as "E", or as "€" under AltGr.
--- Releasing them for the duration and pressing them back afterwards is
--- deterministic, where waiting for the user to let go is not: the release event
--- is sitting in the kernel buffer that the injection is currently blocking.
---
--- Shortcut modifiers are absent on purpose — an expansion cannot fire while one
--- is held, because the character never reaches the engine.
--- @return table Array of "shift" / "altgr", in press order.
function M.held_text_modifiers()
	local held = {}
	if _shift_held then held[#held + 1] = "shift" end
	if _altgr_held then held[#held + 1] = "altgr" end
	return held
end

--- Exact physical keycodes of held text-level modifiers, in press order.
---
--- Injection must release and restore what the application actually saw. A role
--- such as "shift" loses Left/Right identity and collapses two simultaneously
--- held Shift keys into one synthetic LeftShift.
--- @return table Array of exact evdev keycodes.
function M.held_text_modifier_codes()
	local held = {}
	for _, entry in ipairs(_modifier_order) do
		local role = _modifier_down[entry.key]
		if role == "shift" or role == "altgr" then held[#held + 1] = entry.code end
	end
	return held
end

--- Every modifier currently held, keyed by name.
---
--- Distinct from `held_text_modifiers`, which answers a different question and
--- answers it as an ARRAY: that one lists only the two modifiers that select a
--- layout LEVEL, because its caller is resolving a character. This one is for
--- matching a keyboard shortcut, where ctrl and meta are the whole point and a
--- caller wants to ask `held.ctrl` rather than scan a list.
---
--- The two shapes are easy to confuse — indexing the array one by name yields
--- nil for every modifier, which reads as "nothing is held" and is silent.
--- @return table { shift?, ctrl?, alt?, altgr?, meta? } — true when held.
function M.held_modifiers()
	return {
		shift = _shift_held or nil,
		ctrl  = _ctrl_held or nil,
		alt   = _alt_held or nil,
		altgr = _altgr_held or nil,
		meta  = _meta_held or nil,
	}
end

--- Resolves every device the daemon should be reading right now.
--- @return table keyboards, table pointers
local function _best_devices()
	local ok_df, df = pcall(require, "modules.hotstrings.device_finder")
	if not ok_df then return {}, {} end
	if type(df.find_devices) == "function" then
		local ok_find, keyboards, pointers = pcall(df.find_devices)
		if ok_find and type(keyboards) == "table" and type(pointers) == "table" then
			return keyboards, pointers
		end
	end
	local keyboard = type(df.find_keyboard) == "function" and df.find_keyboard() or nil
	local pointer = type(df.find_pointer) == "function" and df.find_pointer() or nil
	return keyboard and { keyboard } or {}, pointer and { pointer } or {}
end

local function _best_pointers()
	local ok_df, df = pcall(require, "modules.hotstrings.device_finder")
	if not ok_df then return {} end
	if type(df.find_pointers) == "function" then
		local ok_find, pointers = pcall(df.find_pointers)
		if ok_find and type(pointers) == "table" then return pointers end
	end
	local pointer = type(df.find_pointer) == "function" and df.find_pointer() or nil
	return pointer and { pointer } or {}
end

local function _close_paths(paths, slot_for)
	for _, path in ipairs(paths) do
		local slot = slot_for(path)
		EvdevReader.close(slot)
		_pending_events[slot] = nil
	end
end

local function _all_keyboards_open(paths)
	if #paths == 0 then return false end
	for _, path in ipairs(paths) do
		if not EvdevReader.is_open(keyboard_slot(path)) then return false end
	end
	return true
end

local function _all_pointers_open(paths)
	for _, path in ipairs(paths) do
		if not EvdevReader.is_open(pointer_slot(path)) then return false end
	end
	return true
end

--- Opens and, when asked, grabs every desired keyboard as one transaction.
--- Existing desired sources remain live while new ones are staged. A failed new
--- source is rolled back, so hotplug cannot silently publish a partial set.
--- @param paths table Device paths.
--- @param force_path string|nil A same-path reconnect whose stale fd must close.
--- @return boolean True when the complete desired set is live.
local function _acquire(paths, force_path)
	local retained = {}
	for _, path in ipairs(_devices) do retained[path] = true end
	local opened = {}
	for _, path in ipairs(paths) do
		local slot = keyboard_slot(path)
		if path == force_path then EvdevReader.close(slot) end
		if not EvdevReader.is_open(slot) then
			if not EvdevReader.open(path, slot) then
				_close_paths(opened, keyboard_slot)
				return false
			end
			opened[#opened + 1] = path
			if _intercept and not EvdevReader.grab(slot) then
				_close_paths(opened, keyboard_slot)
				return false
			end
		end
		retained[path] = nil
	end
	for path in pairs(retained) do EvdevReader.close(keyboard_slot(path)) end
	_devices = {}
	for index, path in ipairs(paths) do _devices[index] = path end
	_device = _devices[1]
	return true
end

--- Reconciles the non-grabbed pointer observers independently of keyboards.
--- @param paths table Device paths.
local function _acquire_pointers(paths)
	local retained = {}
	for _, path in ipairs(_pointer_devices) do retained[path] = true end
	local opened = {}
	for _, path in ipairs(paths) do
		local slot = pointer_slot(path)
		if not EvdevReader.is_open(slot) then
			if not EvdevReader.open(path, slot) then
				_close_paths(opened, pointer_slot)
				Logger.warn(LOG, "Could not observe every pointer — keeping the previous set.")
				return
			end
			opened[#opened + 1] = path
		end
		retained[path] = nil
	end
	for path in pairs(retained) do EvdevReader.close(pointer_slot(path)) end
	_pointer_devices = {}
	for index, path in ipairs(paths) do _pointer_devices[index] = path end
end

--- Re-checks which device should be read, and switches when it has changed.
---
--- Two events make this necessary, and neither announces itself on the
--- descriptor we already hold. A keyboard unplugged and plugged back in gets a
--- NEW /dev/input/eventN node, so the old descriptor stays open forever and
--- delivers nothing. And the remap daemon restarting destroys and recreates its
--- output device — which is the device this daemon prefers, because it carries
--- post-remap keycodes. Without this, a `systemctl --user restart` of the remap
--- daemon silently downgraded us to reading the physical keyboard, i.e. to
--- resolving characters the user never typed.
---
--- Called from the daemon's periodic callback, not the idle one: it re-reads
--- /proc/bus/input/devices, which has no business on the keystroke path.
function M.check_device()
	if not _running and not _reacquiring then return end

	_ticks_since_check = _ticks_since_check + 1
	if _ticks_since_check < DEVICE_CHECK_TICKS then return end
	_ticks_since_check = 0

	local keyboards, pointers = {}, {}
	if _pinned_device then
		pointers = _on_click and _best_pointers() or {}
		local available = EvdevReader.is_available(_pinned_device)
		if not available then
			_pinned_missing = true
			if not _reported_missing then
				Logger.warn(LOG, "Pinned input device %s is unavailable — waiting for that exact path.",
					_pinned_device)
				_reported_missing = true
			end
			return
		end
		keyboards = { _pinned_device }
	else
		keyboards, pointers = _best_devices()
		if not _on_click then pointers = {} end
	end
	if #keyboards == 0 then
		if not _reported_missing then
			Logger.warn(LOG, "No keyboard source found — keeping the current set until one appears.")
			_reported_missing = true
		end
		_acquire_pointers(pointers)
		return
	end
	_reported_missing = false

	local keyboards_changed = not same_paths(keyboards, _devices)
		or not _all_keyboards_open(keyboards) or _pinned_missing
	local pointers_changed = not same_paths(pointers, _pointer_devices)
		or not _all_pointers_open(pointers)
	if not keyboards_changed and not pointers_changed then return end
	if not keyboards_changed then
		_acquire_pointers(pointers)
		return
	end
	local force_path = _pinned_missing and _pinned_device or nil
	_pinned_missing = false

	Logger.start(LOG, "Keyboard source set changed (%d → %d) — re-acquiring…",
		#_devices, #keyboards)
	local reset_ok, reset_err = XkbCapture.reset_state()
	if not reset_ok then
		Logger.error(LOG, "Cannot reset XKB state for the new source set — keeping the previous set: %s.",
			tostring(reset_err))
		return
	end
	_reset_modifier_state()
	if _acquire(keyboards, force_path) then
		_acquire_pointers(pointers)
		_running = true
		_reacquiring = false
		Logger.success(LOG, "Re-acquired %d keyboard source(s) (intercept=%s).",
			#keyboards, tostring(_intercept))
	else
		-- Deliberately not a silent retry loop: the next tick tries again, and
		-- saying so each time is how a permission problem on a newly created node
		-- becomes visible instead of looking like a dead daemon.
		Logger.error(LOG, "Could not acquire the complete keyboard source set — will retry.")
		_running = _all_keyboards_open(_devices)
		_reacquiring = not _running
	end
end




-- =========================================
-- =========================================
-- ======= 6/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Decides whether a capture session may start, given the requested mode and the
--- raw re-emit channel.
---
--- EVIOCGRAB stops the desktop from ever seeing the device again. Without a
--- channel to put those events back, the user's keyboard simply stops working —
--- a far worse outcome than the interleaving bug interception is meant to cure.
--- Refuse instead.
---
--- Exported because start() itself cannot run under the headless harness (it
--- needs a real /dev/input node); this is the actual decision start() delegates
--- to, not a copy of it.
---
--- @param intercept boolean       Whether EVIOCGRAB was requested.
--- @param emit_raw  function|nil  The raw re-emit channel, if any.
--- @return boolean ok, string|nil refusal Reason when ok is false.
function M.can_capture(intercept, emit_raw)
	if intercept and type(emit_raw) ~= "function" then
		return false, "intercept mode requires an onEmitRaw pass-through channel"
	end
	return true
end

--- Starts the keyboard hook. Idempotent — safe to call while already running.
--- @param opts table|nil { intercept?, layout?, onChar?, onKey?, onPhysical?, onEmitRaw?, device?, pinned? }
---              intercept boolean   Grab the device. Default false.
---              layout    string    Physical family for metrics: "qwerty" or
---                                  "azerty". Text always follows live XKB.
---              onChar    function  Called with (char_string, evdev_scancode) for printable keys.
---              onKey     function  Called with (key_name) for control keys.
---              onPhysical function  Called with (evdev_scancode, key_name, char_or_nil) for every physical keydown.
---              onEmitRaw function  Called with (evdev_scancode, evdev_value) to put a
---                                  consumed event back on the wire. MANDATORY when
---                                  intercept is true, ignored otherwise.
---              onClick   function  Called with (button_code) when a pointer button is
---                                  pressed. Supplying it opens a second, NEVER
---                                  grabbed, read-only descriptor on the pointer.
---              device    string    Override /dev/input/eventN path.
---              pinned    boolean   Reacquire only device; never auto-switch it.
function M.start(opts)
	if _running then
		Logger.debug(LOG, "start() called while already running — no-op.")
		return
	end

	local options = type(opts) == "table" and opts or {}
	_pinned_device = options.pinned == true and type(options.device) == "string"
		and options.device ~= "" and options.device or nil
	_pinned_missing = false
	_reacquiring = false
	if type(options.onChar) == "function" then _on_char = options.onChar end
	if type(options.onKey)  == "function" then _on_key  = options.onKey  end
	if type(options.onPhysical) == "function" then _on_physical = options.onPhysical end
	if type(options.onHold) == "function" then _on_hold = options.onHold end
	if type(options.onClick) == "function" then _on_click = options.onClick end
	if type(options.layout) == "string"  then _layout   = options.layout end
	_intercept = options.intercept == true
	-- Bound unconditionally (not "kept if absent" like the domain callbacks):
	-- an emitter left over from an earlier session would satisfy the guard below
	-- while pointing at a channel this session never asked for.
	_emit_raw  = type(options.onEmitRaw) == "function" and options.onEmitRaw or nil

	local ok_capture, refusal = M.can_capture(_intercept, _emit_raw)
	if not ok_capture then
		Logger.error(LOG, "start(): %s — refusing to grab the device.", refusal)
		return
	end

	-- keyboard_layout.refresh() owns the server keymap dump and loads the same
	-- text for capture and injection before start(). Refuse before opening (and
	-- especially before grabbing) a device if that state is missing or cannot be
	-- recreated cleanly. A guessed QWERTY path is silent text corruption.
	if not XkbCapture.is_ready() then
		Logger.error(LOG, "start(): live XKB capture is not initialised — refusing the keyboard device.")
		return
	end
	local reset_ok, reset_err = XkbCapture.reset_state()
	if not reset_ok then
		Logger.error(LOG, "start(): live XKB state reset failed — %s.", tostring(reset_err))
		return
	end
	_reset_modifier_state()

	-- Resolve the complete source set. A CLI override intentionally remains one
	-- pinned keyboard, while auto-detection owns every physical keyboard unless a
	-- consolidated remap output exists.
	local targets, pointers = {}, {}
	if type(options.device) == "string" and options.device ~= "" then
		targets = { options.device }
		if _on_click then pointers = _best_pointers() end
	else
		targets, pointers = _best_devices()
		if not _on_click then pointers = {} end
		if #targets == 0 then
			Logger.error(LOG, "start(): no keyboard device found (set --device or check /proc/bus/input/devices).")
			return
		end
	end

	-- Fail loudly and specifically. "No hotstrings happen" used to be the symptom
	-- of a missing binary, a masked keycode and an unreadable node alike; the
	-- reason a user can act on is the group membership, so say that.
	for _, target in ipairs(targets) do
		local available, why = EvdevReader.is_available(target)
		if not available then
			Logger.error(LOG, "start(): cannot read %s — %s.", target, tostring(why))
			return
		end
	end

	-- Readable is not the same as "can produce key events", and until 2026-08-05
	-- only the first was checked. /dev/null is readable, so `--device /dev/null`
	-- opened it, reported the hook as running, and left the daemon in its read
	-- loop forever waiting for events that cannot arrive. The kernel's own EV
	-- bitmask is the authority, so ask it before committing to the device.
	-- Required through pcall like the other two uses in this file: the finder reads
	-- /proc, and a runtime without it must fail HERE with a reason rather than at
	-- the first keystroke that never comes.
	local ok_finder, Finder = pcall(require, "modules.hotstrings.device_finder")
	if not ok_finder or type(Finder.is_key_device) ~= "function" then
		Logger.error(LOG, "start(): device_finder unavailable — cannot verify the keyboard source set.")
		return
	end
	for _, target in ipairs(targets) do
		local is_key, key_why = Finder.is_key_device(target)
		if not is_key then
			Logger.error(LOG, "start(): %s cannot produce key events — %s.", target, tostring(key_why))
			return
		end
	end

	-- Refresh the foreground context before starting.
	_read_context()

	if not _acquire(targets) then
		Logger.error(LOG, "start(): failed to open or grab the complete keyboard source set.")
		_device = nil
		return
	end

	-- The pointer is opened last and its failure is not fatal: a machine with no
	-- pointer, or one whose node this user cannot read, still expands hotstrings.
	-- It simply cannot notice a click, which is the behaviour this driver had for
	-- its whole life until now.
	if _on_click then _acquire_pointers(pointers) end

	_ticks_since_check = 0
	_reported_missing = false
	_running = true
	Logger.success(LOG, "Keyboard hook started (keyboards=%d pointers=%d layout=%s intercept=%s).",
		#_devices, #_pointer_devices, _layout, tostring(_intercept))
end

--- Stops the keyboard hook. Safe to call when not running.
--- Which layout the hook is currently reading keycodes through.
---
--- The setter below had no getter, so nothing could report or verify what it
--- had applied — including the setter's own tests, which had to drive a key
--- through the resolver to find out.
--- @return string
function M.get_layout()
	return _layout
end

--- Changes the physical keyboard family used by metrics and the heatmap.
---
--- Text capture deliberately ignores this label and follows the active XKB
--- keymap. Keeping the setter is still required for finger maps and aggregate
--- layout metrics, whose qwerty/azerty choice describes the physical board.
--- @param layout string "qwerty" or "azerty".
--- @return boolean Whether the layout was accepted.
function M.set_layout(layout)
	if type(layout) ~= "string" or layout == "" then
		Logger.error(LOG, "set_layout(): a layout name is required — layout unchanged.")
		return false
	end
	local reader = require("modules.hotstrings.input_reader")
	local known = type(reader.get_layouts) == "function" and reader.get_layouts() or nil
	if known and not known[layout] then
		-- Named but unknown is worse than refused: `LAYOUTS[layout] or
		-- LAYOUTS["qwerty"]` silently falls back, so the daemon would report the
		-- change as applied and resolve every key through the other table.
		Logger.error(LOG, "set_layout(): '%s' is not a layout this driver knows — layout unchanged.", layout)
		return false
	end
	_layout = layout
	Logger.info(LOG, "Layout: %s.", layout)
	return true
end

function M.stop()
	if not _running and not _reacquiring then return end
	_close_paths(_pointer_devices, pointer_slot)
	_close_paths(_devices, keyboard_slot)
	_pointer_devices = {}
	_devices = {}
	_device  = nil
	_pinned_device = nil
	_pinned_missing = false
	_reacquiring = false
	_running = false
	Logger.info(LOG, "Keyboard hook stopped.")
end

--- Immediately releases every grabbed descriptor after an output-path failure.
---
--- The current event may already be lost, but keeping EVIOCGRAB after the only
--- pass-through channel failed would swallow every subsequent keystroke. Closing
--- the descriptor is the kernel-guaranteed emergency ungrab.
--- @param reason string|nil
function M.emergency_stop(reason)
	local message = tostring(reason or "keyboard output path failed")
	Logger.error(LOG, "Emergency keyboard stop — %s.", message)
	_close_paths(_pointer_devices, pointer_slot)
	_close_paths(_devices, keyboard_slot)
	_pointer_devices = {}
	_devices = {}
	_device = nil
	_pinned_device = nil
	_pinned_missing = false
	_reacquiring = false
	_running = false
end

--- Returns true if the keyboard hook is currently active.
--- @return boolean
function M.isRunning()
	return _running
end

--- Returns the active capture mode: "intercept" (EVIOCGRAB held, physical events
--- suppressed from the desktop) or "observe" (the same descriptor, not grabbed).
---
--- Callers use this to decide whether hotstring replacement can safely own the
--- output stream. Replacement is only race-free in "intercept" mode: in
--- "observe" mode physical keys typed during an injection still reach the
--- application and interleave with the synthetic backspace+replacement stream —
--- the "abcd" → "acd" corruption. Observe mode is the recovery path behind
--- --no-grab, not a supported way to run.
--- @return string "intercept" | "observe"
function M.get_mode()
	return _intercept and "intercept" or "observe"
end

--- Re-reads the foreground application identity and caches it.
function M.refreshContext()
	_read_context()
end

--- Returns the last-known foreground application identity.
--- @return table { appId: string, windowTitle: string }
function M.getContext()
	return { appId = _context.appId, windowTitle = _context.windowTitle }
end

--- Test seam: drives a list of decoded events through the REAL reader.
---
--- Deliberately not a private dispatch hook. The property worth pinning is that
--- the descriptor, the drain and the dispatch are joined — a seam that skipped
--- the reader would have kept passing through the entire period in which capture
--- produced nothing at all.
--- @param events table Array of { type, code, value } tables, in arrival order.
--- @param callbacks table { onChar?, onKey?, onPhysical?, onEmitRaw?, captureEvent? }.
-- Exposed so the watchdog test can advance exactly as many ticks as the check
-- needs, instead of hardcoding a number that silently stops matching.
M.DEVICE_CHECK_TICKS = DEVICE_CHECK_TICKS

--- @param intercept boolean Whether to run the pass-through branch.
--- @return integer Number of events drained.
function M._test_drive(events, callbacks, intercept)
	local size = InputEvent.native_size()
	local queue = {}
	for i, ev in ipairs(events or {}) do
		queue[i] = InputEvent.encode(ev.type, ev.code, ev.value, size)
	end
	local at = 0

	EvdevReader._set_backend({
		open  = function() return 1 end,
		ioctl = function() return true end,
		read  = function()
			at = at + 1
			return queue[at]
		end,
		poll  = function() return queue[at + 1] ~= nil end,
		close = function() end,
	})

	local cb = callbacks or {}
	_on_char     = cb.onChar
	_on_key      = cb.onKey
	_on_physical = cb.onPhysical
	_emit_raw    = cb.onEmitRaw
	_intercept   = intercept and true or false
	_test_capture_event = type(cb.captureEvent) == "function"
		and cb.captureEvent or _legacy_capture_for_test
	_reset_modifier_state()

	local test_path = "/dev/input/test"
	_devices = { test_path }
	_device = test_path
	local slot = keyboard_slot(test_path)
	EvdevReader.open(test_path, slot)
	_running = true
	local drained = EvdevReader.drain(function(ev) _dispatch_event(ev, test_path) end, slot)
	_running = false
	_devices = {}
	_device = nil
	_test_capture_event = nil
	EvdevReader._reset_backend()
	return drained
end

return M
