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
local TableUtil = require("table_util")

local Logger = require("logger.shim")
local RuntimeGuard = require("infra.runtime_guard")
-- The new logical lease trusts the normal package loader's cold construction,
-- before any backend/setup callback. A preloaded facade keeps ordinary input
-- compatibility but supplies no evidence that these authority exports are original.
local original_reader_load = package.loaded["adapters.evdev_reader"] == nil
local EvdevReader = require("adapters.evdev_reader")
local INPUT_READER_PORT_NAMES = { "capture_event", "event_view", "event_current", "source_current", "reconcile_sources",
	"capture_source_owner", "source_owner_current", "retire_source", "open", "close", "grab", "ungrab", "event_capabilities", "use_ffi_backend", "_set_backend", "_reset_backend" }
local _input_reader_ports = {}
for _, name in ipairs(INPUT_READER_PORT_NAMES) do
	_input_reader_ports[name] = rawget(EvdevReader, name)
end
local EvdevCodes = require("infra.evdev_codes")
local Monotonic = require("infra.monotonic")
local Perf = require("infra.perf_counters")
local InputEvent = require("infra.input_event")
local XkbCapture = require("adapters.xkb_capture")
local ModifierBroker = require("adapters.modifier_broker")
local installed_output_broker = ModifierBroker.for_channel
local INPUT_OUTPUT_PORT_NAMES = { "capture_output", "capture_output_observer", "output_view", "acquire_transaction", "transaction_view", "transaction_current",
	"transaction_emit", "dispatch_transaction", "commit_transaction", "retire_transaction", "close_owned" }
local InputIssuer = require("platform.remap.key_combination_engine")
local HookModuleSource = require("module_source_identity")
local HookModuleDirectory = require("module_source_directory")
local hook_directory = HookModuleDirectory.capture()
local hook_source_label = debug.getinfo(1, "S").source
local original_input_hook_ports = {}
local INPUT_HOOK_PORT_NAMES = { "capture_input_owner", "input_owner_current", "arm_one_shot", "set_remapper", "stop", "emergency_stop", "key_text", "capture_buffered_input", "buffered_input_current", "buffered_input_view", "retire_buffered_input", "refresh_capture" }
local INPUT_PORT_NAMES = { "capture_input_owner", "input_owner_current", "capture_input_guard", "arm_one_shot", "input_owner_state", "clear_input_arm", "buffered_request_current" }
local _input_ports = {}
for _, name in ipairs(INPUT_PORT_NAMES) do _input_ports[name] = rawget(InputIssuer, name) end

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
local _on_key       = nil   -- function(key_name_string, { mods = held_modifiers() } | shortcut detail)
local _on_physical  = nil   -- function(evdev_scancode, key_name, char_or_nil, evdev_value)
local _on_hold      = nil   -- function(evdev_scancode, held_ms)
local _on_hold_admission = nil -- function() -> opaque token or nil
local _hold_admission_session = nil
local _on_desync    = nil   -- function() invalidates text derived before SYN_DROPPED

-- Cached foreground window context (updated via refreshContext).
local _context  = { appId = "", windowTitle = "" }

-- Running flag — set after the device is successfully opened.
local _running  = false

-- One captured publisher and one in-flight source transaction belong to a start.
local _capture_session, _capture_options, _capture_republisher = nil, nil, nil
local _source_reconciliation = nil
local _source_recovery = { inverse = rawget(XkbCapture, "inverse_table"), inverse_current = rawget(XkbCapture, "inverse_current") }
local _number_row = { retired = {}, suppressed = {}, mode = "native" }

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
local _on_consume = nil
local _consumed_down = {}
local _sync_dropped = {}
local _forwarded_down = {}
local _physical_down = {}
local _broker = nil
local _output_owners = {}
local _remapper_generation = 0
local _synthetic_source_of = {}
local _buffer_dispatch
local _event_receipts = setmetatable({}, { __mode = "k" })
local _wire_source_of = setmetatable({}, { __mode = "k" })
local _release_forwarded_sources

-- The tap-hold engine (platform/remap/tap_hold_engine), set by the daemon. It rewrites
-- the grabbed stream before anything else reads it, and _on_tap runs the tap
-- actions it hands back that are not a plain key.
local _physical_sources = {}
local _origin_generation, _origin_signature = 0, nil
local _origin_ready = false
local _remapper = nil
local _remapper_input_owner = nil
local _input_output_owner = nil
local _input_source_owners = nil
local _input_source_observers, _input_pointer_observers = nil, nil
local _leased_reader_cleanup = nil
local _buffered_reader_cleanup, _buffered_record = nil, nil
local _leased_remapper_cleanup = nil
local _input_pointer_owners = nil
local _live_input_context, _armed_input = nil, nil
local _retired_input_context = nil
local _input_leases = setmetatable({}, { __mode = "k" })
local _on_tap = nil
local _release_remapped
local _tick_remapper
-- Physical keys whose press the engine took, and those it took whose engine
-- is gone (swapped, removed or reset while they were held): the release of an
-- orphan is swallowed whole, never sent as an up nothing went down for.
local _remap_owned = {}
local _remap_orphans = {}
-- The source each key the engine handles went down on, by code: a hold the
-- engine presses later for that key (M:tick) goes out on the same keyboard as
-- the release that lifts it.
local _remap_source_of = {}
-- The last key or pointer event's time on the clock the events carry, and the
-- daemon's monotonic time when it was read: the pump tells the engine what
-- time it is on the events' clock from these, with nothing to read in between.
local _clock_event_ms = nil
local _clock_read_ms = nil
-- Test seam: the time the engine reads while _test_drive replays a stream
-- whose events carry `at_ms` and no kernel timestamp. nil in production.
local _test_clock_ms = nil

-- Only EV_KEY is forwarded. The uinput channel appends its own SYN_REPORT after
-- each key, so forwarding the source stream's EV_SYN would double it; EV_MSC is
-- duplicate scancode metadata the desktop derives from the key report itself;
-- EV_LED and EV_REP are output and configuration, not input.
local EVDEV_TYPE_KEY = InputEvent.EV_KEY
local EVDEV_TYPE_SYN = InputEvent.EV_SYN
local SYN_REPORT = 0
local SYN_DROPPED = 3
local KEY_MAX = 0x2FF
local LED_CAPSL = 1
local _locks = { last_led = 2, codes = { [0] = EvdevCodes.KEY_NUMLOCK,
	[LED_CAPSL] = EvdevCodes.KEY_CAPSLOCK, [2] = EvdevCodes.KEY_SCROLLLOCK }, keys = {} }
for _, code in pairs(_locks.codes) do _locks.keys[code] = true end
-- The CapsLock a CapsWord session holds (M.lock_caps_for_word):
-- { emit, on_lost, owned }, `owned` when the session locked it itself. Kept in
-- _locks, not a local of its own: this chunk is near LuaJIT's local budget.
_locks.word = nil
_locks.describe_failure = require("error_description").describe

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
local _hold_owners = {}
local _legacy_hold_owner = {}

local function hold_owner()
	if not rawequal(_hold_admission_session, _capture_session) then return nil, nil end
	if _on_hold_admission == nil then return _legacy_hold_owner, nil end
	local callback = _on_hold_admission
	local ok, token = pcall(callback)
	if ok and rawequal(callback, _on_hold_admission)
		and type(token) == "table" and getmetatable(token) == nil then
		return token, callback
	end
	return nil, nil
end

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
-- Called with ("press", code) for every press of an observed pointer and with
-- ("motion", axis) for every EV_REL report (a movement or a wheel turn), if
-- the caller asked for it: CapsWord ends on the pointer kinds it names.
local _on_pointer_event = nil

-- Set while XKB cannot tell the keys' roles or capture them, so that is
-- logged once and not at every key event; the next press XKB answers in full
-- clears it.
local _xkb_failure_reported = false

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

local function _reset_capture_state()
	if _test_capture_event then return true end
	return XkbCapture.reset_state()
end
--- Restores the lock actions of a fresh capture state from observed LEDs.
--- Held lock keys must not also be replayed: that would toggle their state twice.
--- @param leds table Native LED states, indexed by Linux LED code.
--- @return boolean acknowledged All requested capture transitions succeeded.
--- @return string|nil reason
function _locks.seed_leds(leds)
	for led = 0, _locks.last_led do
		if leds[led] == true then
			local code = _locks.codes[led]
			local _, _, down_err = _capture(code, InputEvent.VALUE_DOWN)
			if down_err then return false, tostring(down_err) end
			local _, _, up_err = _capture(code, InputEvent.VALUE_UP)
			if up_err then return false, tostring(up_err) end
		end
	end
	-- A CapsLock a CapsWord session locked is the desktop's state even when the
	-- LED never showed it: under the grab the kernel drops the compositor's LED
	-- writes to the grabbed keyboard, so a reseed would read it unlocked.
	local word = _locks.word
	if word and word.owned and not XkbCapture.caps_locked() then
		local ok, reason = _locks.capture_tap()
		if not ok then return false, reason end
	end
	return true
end

--- Seeds a newly reset capture state from the acquired keyboard's lock LEDs.
--- The desktop may update LEDs even while EVIOCGRAB excludes other readers.
--- EVIOCGLED observes the source; it does not prove a desktop-wide lock state
--- when that source has no LED capability or the desktop has not updated it.
--- @param path string|nil The keyboard source just acquired.
--- @return boolean acknowledged
--- @return string|nil reason
function _locks.seed(path)
	if not path then return false, "keyboard source is unavailable" end
	local leds, led_err = EvdevReader.active_leds(keyboard_slot(path), _locks.last_led)
	if not leds then
		Logger.warn(LOG, "Lock state of %s unreadable (%s).", path, tostring(led_err))
		return false, led_err
	end
	return _locks.seed_leds(leds)
end

--- Feeds the capture state one CapsLock press and release, as the desktop
--- receives the key a CapsWord session emits.
--- @return boolean acknowledged
--- @return string|nil reason
function _locks.capture_tap()
	for _, value in ipairs({ InputEvent.VALUE_DOWN, InputEvent.VALUE_UP }) do
		local _, _, err = _capture(EvdevCodes.KEY_CAPSLOCK, value)
		if err then return false, "the capture state refused CapsLock: " .. tostring(err) end
	end
	return true
end

--- Toggles CapsLock in the capture state, then on the desktop through `emit`.
--- The capture goes first: a keymap whose CapsLock key locks nothing
--- (caps:escape, ctrl:nocaps, caps:shiftlock) is refused before the desktop
--- receives that key, and its press and release are undone in the capture.
--- @param emit function() -> boolean, table|nil Presses and releases KEY_CAPSLOCK.
--- @param locked boolean The Caps Lock state wanted.
--- @return boolean ok
--- @return string|nil reason
--- @return boolean|nil unchanged True only when no native output was attempted.
function _locks.toggle_word(emit, locked)
	local captured, capture_err = _locks.capture_tap()
	if not captured then return false, capture_err, true end
	if XkbCapture.caps_locked() ~= locked then
		local undone, undo_err = _locks.capture_tap()
		if not undone then return false, undo_err, true end
		return false, "the keymap's CapsLock key does not toggle Caps Lock", true
	end
	local called, emitted, outcome = pcall(emit)
	if called and emitted == true then return true end
	local undone, undo_err = _locks.capture_tap()
	if not undone then return false, undo_err, false end
	local unchanged = called and type(outcome) == "table" and getmetatable(outcome) == nil
		and (rawget(outcome, "kind") == "refused" or rawget(outcome, "kind") == "unavailable")
	return false, "the CapsLock key could not be emitted: " .. _locks.describe_failure(emitted), unchanged == true
end

--- Ends the session's hold on CapsLock.
--- @param unlock boolean Whether to unlock a CapsLock the session locked.
--- @param reason string|nil When the hook ends it, why: the session is told.
--- @return boolean ok False when the unlock could not be emitted (logged).
function _locks.end_word(unlock, reason)
	local word = _locks.word
	if not word then return true end
	-- The emitter may re-enter stop while native output retires. Neither that
	-- call nor a successor session can acknowledge the unlock still in flight.
	if word.releasing then return false end
	word.releasing = true
	local ok, err = true, nil
	if unlock and word.owned then
		if word.retryable == false then
			ok, err = false, "the previous CapsLock emission has no acknowledged outcome"
		elseif not XkbCapture.caps_locked() then
			ok, err = false, "the capture no longer represents the owned CapsLock"
		else
			ok, err, word.retryable = _locks.toggle_word(word.emit, false)
		end
	end
	word.releasing = false
	-- A partial or unclassified native emission may already have toggled the
	-- desktop. Retain that debt without another toggle; retry only a typed
	-- pre-output refusal, through the exact original emitter.
	if ok then _locks.word = nil end
	if not ok then Logger.error(LOG, "CapsWord could not unlock CapsLock: %s.", tostring(err)) end
	if reason and not word.loss_reported then
		word.loss_reported = true
		local told, tell_err = pcall(word.on_lost, reason)
		if not told then Logger.error(LOG, "CapsWord lock-loss callback failed: %s.", _locks.describe_failure(tell_err)) end
	end
	return ok
end



-- =========================================
-- =========================================
-- ======= 3/ Event Dispatch ===============
-- =========================================
-- =========================================

--- Logs an XKB failure once, however many keys it hits: a keymap XKB cannot
--- read fails every key event, and a line for each filled the log. The next
--- press XKB answers in full clears it (_xkb_answered).
--- @param fmt string Logger format.
local function _xkb_failed(fmt, ...)
	if _xkb_failure_reported then return end
	_xkb_failure_reported = true
	Logger.error(LOG, fmt, ...)
end

--- Clears a reported XKB failure once a key is answered in full, and says so.
local function _xkb_answered()
	if not _xkb_failure_reported then return end
	_xkb_failure_reported = false
	Logger.info(LOG, "XKB answers again: the keys' roles and text come from the layout.")
end

--- Forgets a dead key the capture state holds for a key press a consumer kept
--- from the application: the application's own Compose never saw it, so the
--- next key must read here as it types there, not composed with it.
local function _cancel_capture_compose()
	if _test_capture_event then return true end
	local ok, err = XkbCapture.cancel_compose()
	if not ok then
		_xkb_failed("XKB Compose could not be cancelled after a consumed key (%s) — the next key may read composed.",
			tostring(err))
	end
	return ok == true
end

--- The role a physical key has in the ACTIVE layout, asked of XKB before its
--- press is committed, for every key. The key alone does not say: Right Alt is
--- AltGr (ISO_Level3_Shift, which types text) on a French or Ergopti layout
--- and plain Alt_R (a shortcut) on a US one, and XKB options move modifiers to
--- other keys (ctrl:nocaps makes CapsLock a Ctrl, lv3:menu_switch makes Menu
--- an AltGr). Only a capture double (tests) is not a layout: there the key's
--- usual role stands, and so it does, logged once, when XKB cannot answer.
--- @param code integer evdev keycode.
--- @return string|nil "shift", "altgr", "ctrl", "alt", "meta", or nil when the
---   key is not a modifier in this layout.
--- @return boolean True when XKB could not answer and the usual role stands.
local function _modifier_role(code)
	if _test_capture_event then return EvdevCodes.MODIFIER_OF[code], false end
	local role, role_err = XkbCapture.modifier_role(code)
	if role_err then
		_xkb_failed("XKB cannot tell the role of key %d (%s) — each key keeps its usual role until it can.",
			code, tostring(role_err))
		return EvdevCodes.MODIFIER_OF[code], true
	end
	return role, false
end

--- Updates the held-modifier flags from a key transition. A release and a
--- repeat keep the role the press was given, so the counts always balance.
--- @param source string Source identity.
--- @param code integer evdev keycode.
--- @param value integer evdev value: 0 release, 1 press, 2 repeat.
--- @param role string|nil For a press: the key's role from _modifier_role().
--- @return boolean True when the key is a held modifier and nothing else applies.
local function _track_modifier(source, code, value, role)
	local key = source_key(source, code)
	local held_role = _modifier_down[key]
	if value == InputEvent.VALUE_DOWN then
		if held_role then return true end
		if not role then return false end
		_modifier_down[key] = role
		_modifier_count[role] = _modifier_count[role] + 1
		_modifier_order[#_modifier_order + 1] = { key = key, code = code }
	elseif value == InputEvent.VALUE_UP then
		if not held_role then return false end
		_modifier_down[key] = nil
		_modifier_count[held_role] = math.max(0, _modifier_count[held_role] - 1)
		for index = #_modifier_order, 1, -1 do
			if _modifier_order[index].key == key then
				table.remove(_modifier_order, index)
				break
			end
		end
	else
		return held_role ~= nil
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
	_consumed_down = {}
	_pressed_at = {}
	_hold_owners = {}
end

--- True while a modifier that starts a SHORTCUT is held.
--- Deliberately excludes shift and AltGr, which select a layout level and
--- produce text.
--- @return boolean
local function _shortcut_modifier_held()
	return _ctrl_held or _alt_held or _meta_held
end

local _owned_row_receipt = nil
local _dispatch_owned_rows
local _deliver_owned_rows
local function _combination_source(source)
	local receipt = M.physical_source_receipt()
	local slot = keyboard_slot(source)
	local owner = _input_source_owners and _input_source_owners[slot]
	local observer = owner and _input_source_observers[slot]
	local current = owner and _input_reader_ports.source_owner_current(owner, observer,
		_input_reader_ports.capture_source_owner, _input_reader_ports.source_owner_current, _input_reader_ports.retire_source)
	-- A source publication may mint another lease for the SAME native opening.
	-- Keep its original opaque identity while both that lease and the published
	-- cohort remain current; a closed/reopened descriptor fails the old join.
	local cache = _source_recovery.remap_sources
	if not cache or cache.session ~= _capture_session then
		cache = { session = _capture_session, sources = _input_source_owners, owners = {} }
		_source_recovery.remap_sources = cache
	elseif cache.sources ~= _input_source_owners then
		local retained = {}
		for _, path in ipairs(_devices) do retained[path] = cache.owners[path] end
		cache.sources, cache.owners = _input_source_owners, retained
	end
	local original = cache.owners[source]
	if current == true then
		local original_current = original and (rawequal(original.owner, owner) or
			_input_reader_ports.source_owner_current(original.owner, original.observer,
				_input_reader_ports.capture_source_owner, _input_reader_ports.source_owner_current,
				_input_reader_ports.retire_source) == true)
		if not original_current then
			original = { owner = owner, observer = observer }
			cache.owners[source] = original
		end
	end
	return { source = source, generation = receipt.generation, ready = receipt.ready,
		physical = _physical_sources[source] == true,
		source_owner = original and original.owner or owner, source_current = current }
end

local function _input_exports_current()
	if package.loaded["adapters.evdev_reader"] ~= EvdevReader
		or package.loaded["platform.remap.key_combination_engine"] ~= InputIssuer then return false end
	for _, name in ipairs(INPUT_PORT_NAMES) do
		local port = _input_ports[name]; if type(port) ~= "function" or rawget(InputIssuer, name) ~= port then return false end
	end
	for _, name in ipairs(INPUT_READER_PORT_NAMES) do
		local port = _input_reader_ports[name]; if type(port) ~= "function" or rawget(EvdevReader, name) ~= port then return false end
	end
	return true
end

local function _input_runtime_current(ctx, active)
	if _source_reconciliation or not original_reader_load or not ctx or type(ctx.broker) ~= "table" or package.loaded["adapters.keyboard_hook"] ~= M
		or not _running or not _intercept or _remapper ~= ctx.engine
		or _remapper_generation ~= ctx.generation or _remapper_input_owner ~= ctx.issuer
		or _broker ~= ctx.broker or _emit_raw ~= ctx.emitter or _on_tap ~= ctx.callback
		or _input_source_owners ~= ctx.sources or type(ctx.sources) ~= "table"
		or _input_source_observers ~= ctx.source_observers or type(ctx.source_observers) ~= "table"
		or _input_pointer_owners ~= ctx.pointer_sources or type(ctx.pointer_sources) ~= "table"
		or _input_pointer_observers ~= ctx.pointer_observers or type(ctx.pointer_observers) ~= "table"
		or _origin_ready ~= true or _origin_generation ~= ctx.origin_generation
		or _physical_sources[ctx.source] ~= true or _sync_dropped[ctx.source]
		or active and _live_input_context ~= ctx or not _input_exports_current()
		or ctx.lease and (getmetatable(ctx.lease) ~= nil or next(ctx.lease) ~= nil) then return false end
	if rawget(ctx.broker, "view") ~= ctx.output_view or rawget(ctx.broker, "has_debt") ~= ctx.output_debt
		or rawget(ctx.broker, "output_current") ~= ctx.output_current
		or rawget(ctx.broker, "output_retired") ~= ctx.output_retired
		or rawget(ctx.broker, "retire") ~= ctx.output_retire then return false end
	for _, name in ipairs(INPUT_HOOK_PORT_NAMES) do
		local port = ctx.hook_ports[name]
		if type(port) ~= "function" or port ~= original_input_hook_ports[name]
			or rawget(M, name) ~= port then return false end
	end
	if type(ctx.finder) ~= "table" or type(ctx.classify_source) ~= "function"
		or package.loaded["modules.hotstrings.device_finder"] ~= ctx.finder
		or rawget(ctx.finder, "physical_sources") ~= ctx.classify_source then return false end
	local output = ctx.output_issuer
	if not output or output ~= _input_output_owner or output.broker ~= ctx.broker
		or package.loaded["adapters.uinput_writer"] ~= output.writer
		or package.loaded["adapters.modifier_broker"] ~= ModifierBroker
		or rawget(ModifierBroker, "for_channel") ~= installed_output_broker
		or installed_output_broker(output.writer) ~= ctx.broker then return false end
	local exact_broker, binding = installed_output_broker(output.writer)
	if exact_broker ~= ctx.broker or binding ~= output.binding or type(binding) ~= "function"
		or binding(ctx.broker) ~= true then return false end
	for _, name in ipairs(INPUT_OUTPUT_PORT_NAMES) do
		local port = output.ports[name]
		if type(port) ~= "function" or rawget(output.writer, name) ~= port then return false end
	end
	for slot, lease in pairs(ctx.sources) do
		local observer = ctx.source_observers[slot]
		if type(observer) ~= "function" or observer(lease, _input_reader_ports.capture_source_owner,
			_input_reader_ports.source_owner_current, _input_reader_ports.retire_source) ~= true
			or _input_reader_ports.source_owner_current(lease) ~= true then return false end
	end
	for slot, lease in pairs(ctx.pointer_sources) do
		local observer = ctx.pointer_observers[slot]
		if type(observer) ~= "function" or observer(lease, _input_reader_ports.capture_source_owner,
			_input_reader_ports.source_owner_current, _input_reader_ports.retire_source) ~= true then return false end
	end
	return _input_ports.input_owner_current(ctx.issuer) == true
		and _input_reader_ports.source_current(ctx.origin, ctx.sources[keyboard_slot(ctx.source)],
			ctx.source_observers[keyboard_slot(ctx.source)], _input_reader_ports.capture_source_owner,
			_input_reader_ports.source_owner_current, _input_reader_ports.retire_source) == true and _input_exports_current()
end

-- Pending first presses are issued only inside actual original dispatch. A
-- decoded table, positive caller closure or detached key-state bitmap cannot
-- mint this opaque source/output capability.
do
	local receipts = setmetatable({}, {__mode="k"})
	_buffered_record=function(token) return receipts[token] end
	local function current(record, held)
		if not record or _input_runtime_current(record,false) ~= true then return false end
		-- Original observers above may run callbacks; private issuer currency is
		-- checked last. Held state follows processed events, never future ioctl bits.
		return _running and _intercept and _remapper == record.engine and _remapper_generation == record.generation
			and _broker == record.broker and _emit_raw == record.emitter and _on_tap == record.callback
			and _input_source_owners == record.sources and _input_source_observers == record.source_observers
			and _origin_ready and _origin_generation == record.origin_generation and not _source_reconciliation
			and _physical_sources[record.source] == true and not _sync_dropped[record.source]
			and (held ~= true or _physical_down[record.stamp] == record.down)
	end
	function M.capture_buffered_input(engine, code, at_ms)
		local dispatch = _buffer_dispatch
		if not dispatch or dispatch.engine ~= engine or engine ~= _remapper or dispatch.event.code ~= code
			or dispatch.event.value ~= InputEvent.VALUE_DOWN or dispatch.at_ms ~= at_ms or dispatch.event.remapped
			or dispatch.acquired or dispatch.acquiring or _input_ports.buffered_request_current(engine,code,at_ms) ~= true then return nil end
		local origin, source = dispatch.origin, dispatch.source
		local view = origin and _input_exports_current() and _input_reader_ports.event_view(origin)
		local stamp = source_key(source,code)
		local down = _physical_down[stamp]
		if not view or view.origin ~= "native-evdev" or view.source ~= source or view.code ~= code or view.value ~= 1
			or not down or down.origin ~= origin or not _remapper_input_owner then return nil end
		local hook_ports = {}; for _,name in ipairs(INPUT_HOOK_PORT_NAMES) do hook_ports[name] = rawget(M,name) end
		local finder = package.loaded["modules.hotstrings.device_finder"]
		local record = {engine=engine,generation=_remapper_generation,issuer=_remapper_input_owner,origin=origin,
			engine_release_all=rawget(engine,"release_all"),engine_ack_retirement=rawget(engine,"ack_retirement"),
			view=view,source=source,stamp=stamp,down=down,at_ms=at_ms,hook_ports=hook_ports,
			finder=finder,classify_source=type(finder)=="table" and rawget(finder,"physical_sources") or nil,
			origin_generation=_origin_generation,sources=_input_source_owners,source_observers=_input_source_observers,
			pointer_sources=_input_pointer_owners,pointer_observers=_input_pointer_observers,
			broker=_broker,output_issuer=_input_output_owner,emitter=_emit_raw,callback=_on_tap,
			output_view=_broker and rawget(_broker,"view"),output_debt=_broker and rawget(_broker,"has_debt"),
			output_current=_broker and rawget(_broker,"output_current"),output_retire=_broker and rawget(_broker,"retire"),output_retired=_input_output_owner and _input_output_owner.terminal}
		dispatch.acquiring=true
		local called,admitted=pcall(current,record,true)
		dispatch.acquiring=nil
		if not called or admitted~=true then return nil end
		if _buffer_dispatch~=dispatch or dispatch.acquired or _input_ports.buffered_request_current(engine,code,at_ms) ~= true then return nil end
		local token = {}; receipts[token]=record; dispatch.acquired=true
		-- Stop/hotplug cleanup retains this captured cohort, never a later owner
		-- that happens to reuse a slot or numeric descriptor.
		_buffered_reader_cleanup={}
		for slot,lease in pairs(record.sources) do _buffered_reader_cleanup[slot]=lease end
		for slot,lease in pairs(record.pointer_sources) do _buffered_reader_cleanup[slot]=lease end
		return token
	end
	--- Retires only this issuer's original unforwarded physical lifetime. No IO,
	--- source acquisition or output right is granted by this cleanup observation.
	function M.retire_buffered_input(token,engine)
		local record=receipts[token]
		if not record or record.engine~=engine then return false end
		if _physical_down[record.stamp]==record.down then _remap_orphans[record.stamp]=true end
		return true
	end
	function M.buffered_input_current(token, held) return current(receipts[token],held) end
	function M.buffered_input_view(token)
		local record=receipts[token]
		if not current(record,false) then return nil end
		local view={}; for key,value in pairs(record.view) do view[key]=value end
		return {source=record.source,at_ms=record.at_ms,origin=record.origin,origin_view=view,
			generation=record.generation,physical_generation=record.origin_generation,code=record.view.code}
	end
end

local function _input_guard_current(ctx)
	if not _input_runtime_current(ctx, false) or type(ctx.guard) ~= "function"
		or type(ctx.output_current) ~= "function" then return false end
	local checked, configured = pcall(ctx.guard)
	if not checked or configured ~= true or not _input_runtime_current(ctx, false) then return false end
	local seen, view = pcall(ctx.output_view)
	local debt_ok, debt = pcall(ctx.output_debt)
	local output_ok, output = pcall(ctx.output_current)
	-- The terminal join observes captured RAM issuers after all callback-shaped
	-- configuration/output observations; it performs no further native query.
	return seen and type(view) == "table" and view.busy == false and view.debt == false
		and debt_ok and debt == false and output_ok and output == true
		and _input_runtime_current(ctx, false)
end

-- Captured cleanup observes only its original engine and native output issuer.
-- Input-source currency is deliberately absent: that source caused withdrawal.
local function _input_cleanup_current(ctx)
	if package.loaded["adapters.keyboard_hook"] ~= M or _remapper ~= ctx.engine
		or _remapper_generation ~= ctx.generation or _broker ~= ctx.broker
		or _input_output_owner ~= ctx.output_issuer or not _input_exports_current()
		or rawget(ctx.engine, "release_all") ~= ctx.engine_release_all
		or rawget(ctx.engine, "ack_retirement") ~= ctx.engine_ack_retirement
		or rawget(ctx.engine, "output_holder") ~= ctx.engine_output_holder then return false end
	for name, port in pairs(ctx.engine_ports) do
		if rawget(ctx.engine, name) ~= port then return false end
	end
	for name, port in pairs(ctx.hook_ports) do
		if rawget(M, name) ~= port or port ~= original_input_hook_ports[name] then return false end
	end
	local output = ctx.output_issuer
	if not output or package.loaded["adapters.uinput_writer"] ~= output.writer
		or package.loaded["adapters.modifier_broker"] ~= ModifierBroker
		or rawget(ModifierBroker, "for_channel") ~= installed_output_broker then return false end
	local broker, binding = installed_output_broker(output.writer)
	if broker ~= ctx.broker or binding ~= output.binding or type(binding) ~= "function"
		or binding(ctx.broker) ~= true then return false end
	for name, port in pairs(output.ports) do
		if rawget(output.writer, name) ~= port then return false end
	end
	return true
end

-- The cancelled suffix comes from this controller's original delivery iterator.
-- A missing holder by itself never proves that a DOWN was not issued.
local function _capture_input_retirement(ctx)
	local called, rows = pcall(ctx.engine_release_all, ctx.engine)
	if not called or type(rows) ~= "table" then return nil end
	local record = { rows = rows, owners = {}, snapshots = {} }
	local batch = ctx.delivery_batch
	for index, row in ipairs(rows) do
		local holder = row.holder or ctx.engine_output_holder(ctx.engine, row)
		if row.value ~= InputEvent.VALUE_UP or type(holder) ~= "string" then return nil end
		local holder_key = ctx.generation .. ":" .. holder .. ":" .. row.code
		local original_source = _synthetic_source_of[holder_key]
		local output_source = "remapper:" .. ctx.generation .. ":" .. holder .. ":" .. tostring(original_source or ctx.source)
		local key = source_key(output_source, row.code)
		local owner, forwarded = _output_owners[key], _forwarded_down[key]
		local never_issued = false
		if not owner and not forwarded and original_source == nil and batch
			and batch.engine == ctx.engine and batch.generation == ctx.generation
			and batch.source == ctx.source and batch.unwound == true then
			for tail = batch.next_index, #batch.rows do
				local witness = batch.snapshots[tail]
				local pending = batch.rows[tail]
				if pending ~= witness.row or pending.code ~= witness.code or pending.value ~= witness.value
					or (pending.holder or ctx.engine_output_holder(ctx.engine, pending)) ~= witness.holder then return nil end
				if pending.value == InputEvent.VALUE_DOWN and pending.code == row.code
					and (pending.holder or ctx.engine_output_holder(ctx.engine, pending)) == holder then
					never_issued = true; break
				end
			end
		end
		if not never_issued and (type(owner) ~= "table" or not forwarded
			or forwarded.code ~= row.code or forwarded.owner_source ~= output_source) then return nil end
		record.owners[index] = owner or false
		record.snapshots[index] = { row = row, code = row.code, value = row.value, holder = holder,
			key = key, never_issued = never_issued }
	end
	return record
end

local function _settle_current_input(ctx)
	local record = ctx.retirement_record
	if not record or not _input_cleanup_current(ctx) then return false end
	local observed, current = pcall(ctx.output_current)
	if not observed or current ~= true or not _input_cleanup_current(ctx) then return false end
	-- The original view is a pure RAM roster after the native issuer join.
	local seen, view = pcall(ctx.output_view)
	if not seen or type(view) ~= "table" or view.busy ~= false or view.debt ~= false
		or type(view.owners) ~= "table" then return false end
	for index, snapshot in ipairs(record.snapshots) do
		local row, owner = record.rows[index], record.owners[index]
		if row ~= snapshot.row or row.code ~= snapshot.code or row.value ~= snapshot.value
			or (row.holder or ctx.engine_output_holder(ctx.engine, row)) ~= snapshot.holder then return false end
		if owner and view.owners[owner] ~= nil then return false end
		if snapshot.never_issued and (_output_owners[snapshot.key] ~= nil
			or _forwarded_down[snapshot.key] ~= nil) then return false end
	end
	if #record.rows ~= #record.snapshots or not _input_cleanup_current(ctx) then return false end
	local released, exact = pcall(ctx.engine_release_all, ctx.engine)
	if not released or exact ~= record.rows or not _input_cleanup_current(ctx) then return false end
	local acknowledged, settled = pcall(ctx.engine_ack_retirement, ctx.engine, true, exact)
	return acknowledged and settled == true
end

-- Acknowledged destruction of the original output lifetime settles only this
-- exact producer's pending retirement. Unknown native close never grants an ACK.
local function _settle_retired_input(ctx)
	if type(ctx.output_retired) ~= "function" or type(ctx.engine_release_all) ~= "function"
		or type(ctx.engine_ack_retirement) ~= "function" then return false end
	local observed, terminal = pcall(ctx.output_retired)
	if not observed or terminal ~= true then return _settle_current_input(ctx) end
	local released, rows = pcall(ctx.engine_release_all, ctx.engine)
	if not released or type(rows) ~= "table" then return false end
	local acknowledged, settled = pcall(ctx.engine_ack_retirement, ctx.engine, true, rows)
	return acknowledged and settled == true
end

local function _withdraw_input_arm(ctx)
	if _armed_input == ctx then _armed_input = nil end
	local state = _input_ports.input_owner_state(ctx.issuer)
	if state ~= "consumed" and not ctx.consumed then _input_ports.clear_input_arm(ctx.issuer); return true end
	-- Consumed presses already own output. The current owner uses its existing
	-- inverse/retirement path; a replaced owner may retire only its captured channel.
	if _remapper == ctx.engine and _remapper_generation == ctx.generation and _broker == ctx.broker then
		ctx.retirement_record = _capture_input_retirement(ctx)
		_retired_input_context = ctx
		local prior, prior_remapper = _leased_reader_cleanup, _leased_remapper_cleanup
		_leased_remapper_cleanup = { engine = ctx.engine, release_all = ctx.engine_release_all }
		_leased_reader_cleanup = {}
		for slot, lease in pairs(ctx.sources) do _leased_reader_cleanup[slot] = lease end
		for slot, lease in pairs(ctx.pointer_sources or {}) do _leased_reader_cleanup[slot] = lease end
		local stopped = pcall(ctx.emergency_stop, "input-owner logical delivery was withdrawn")
		_leased_reader_cleanup, _leased_remapper_cleanup = prior, prior_remapper
		if not stopped then ctx.output_retire() end
	else ctx.output_retire() end
	if _settle_retired_input(ctx) and _retired_input_context == ctx then _retired_input_context = nil end
	return false
end

--- Captures only an actual acknowledged logical pair frame in its callback.
--- @return table|nil lease Opaque installed source/input owner, never output rights.
function M.capture_input_owner()
	local ctx = _live_input_context
	if not ctx or ctx.action ~= "one_shot_shift" or not _input_runtime_current(ctx, true) then return nil end
	if ctx.lease then return ctx.lease end
	local captured, guard = pcall(_input_ports.capture_input_guard, ctx.issuer, ctx.frame, ctx.action)
	if not captured or type(guard) ~= "function" or not _input_runtime_current(ctx, true) then return nil end
	ctx.guard = guard
	local lease = {}; ctx.lease = lease; _input_leases[lease] = ctx
	return lease
end

--- Observes last-sealed input/source currency; it grants no additional mutation.
--- @param lease table Original issued lease, never a detached copy.
--- @return boolean current
function M.input_owner_current(lease)
	local ctx = _input_leases[lease]
	if not ctx or getmetatable(lease) ~= nil or next(lease) ~= nil then return false end
	return _input_runtime_current(ctx, not ctx.used) and (not ctx.used or _armed_input == ctx)
		and _input_guard_current(ctx)
end

--- Publishes one logical arm on the exact installed issuer, without output reservation.
--- @param lease table Original source/frame lease.
--- @return boolean published
function M.arm_one_shot(lease)
	local ctx = _input_leases[lease]
	if not ctx or ctx.action ~= "one_shot_shift" or ctx.used or ctx.arming or getmetatable(lease) ~= nil or next(lease) ~= nil
		or not _input_runtime_current(ctx, true) or _armed_input ~= nil then return false end
	local function current() return _input_runtime_current(ctx, not ctx.used) and _input_guard_current(ctx) end
	ctx.arming = true
	local called, published = pcall(_input_ports.arm_one_shot, ctx.issuer, ctx.at_ms, current)
	ctx.arming = false
	if not called or published ~= true then return false end
	if not _input_runtime_current(ctx, true) then _input_ports.clear_input_arm(ctx.issuer); return false end
	ctx.used, _armed_input = true, ctx
	return true
end

local function _forward_raw(ev, source)
	if not _intercept or not _emit_raw or ev.type ~= EVDEV_TYPE_KEY then return true end
	-- The events written back to the desktop under the grab: what the user's
	-- keystrokes became after the tap-hold engine and the layout.
	Perf.count("input.forwarded_events")
	local key = source_key(source, ev.code)
	local prior = _forwarded_down[key]
	local owner = _output_owners[key]
	if not owner then owner = {}; _output_owners[key] = owner end
	if ev.handoff then
		local receipt = _broker.handoff(ev.code, ev.handoff, _emit_raw)
		if _owned_row_receipt and _owned_row_receipt.code == ev.code and _owned_row_receipt.value == ev.value then
			_owned_row_receipt.count = _owned_row_receipt.count + 1
			_owned_row_receipt.accepted = receipt.ok
			_owned_row_receipt.native_writes = receipt.native_writes
			_owned_row_receipt.disposition = receipt.disposition
		end
		return receipt.ok
	end
	-- Staging before the callback lets a same-owner stop/remapper withdrawal
	-- queue its exact inverse instead of publishing a later stranded down.
	if ev.value == InputEvent.VALUE_DOWN then
		_forwarded_down[key] = { code = ev.code, source = ev.original_source or _wire_source_of[ev] or source, owner_source = source }
	elseif ev.value == InputEvent.VALUE_UP then _forwarded_down[key] = nil end
	local receipt = _broker.edge(owner, ev.code, ev.value, _emit_raw)
	if _owned_row_receipt and _owned_row_receipt.code == ev.code and _owned_row_receipt.value == ev.value then
		_owned_row_receipt.count = _owned_row_receipt.count + 1
		_owned_row_receipt.accepted = receipt.ok
		_owned_row_receipt.native_writes = receipt.native_writes
		_owned_row_receipt.disposition = receipt.disposition
	end
	if receipt.ok then
		if ev.value == InputEvent.VALUE_UP then _output_owners[key] = nil end
		return true, receipt
	end
	_forwarded_down[key] = prior
	M.emergency_stop(string.format("raw ownership settlement failed (code=%d value=%d): %s",
		ev.code, ev.value, receipt.disposition))
	return false
end

--- Whether this pass-through transition changes the aggregate desktop key.
--- A coalesced dead-key press must not feed Compose when the desktop sees none.
--- @param ev table Post-remap key event.
--- @param source string Stable output source.
--- @return boolean
local function _capture_wire_transition(ev, source)
	if not _intercept or not _broker or _consumed_down[source_key(source, ev.code)] then return true end
	local view = _broker.view()
	local down = false
	for _, code in ipairs(view.down) do if code == ev.code then down = true; break end end
	if ev.value == InputEvent.VALUE_DOWN then return not down end
	local owner = _output_owners[source_key(source, ev.code)]
	local row = owner and view.owners[owner]
	if not row then return false end
	if ev.value == InputEvent.VALUE_REPEAT then return row.state == "held" and down end
	if row.state ~= "held" and row.state ~= "spent" then return false end
	-- Injection can spend output ownership before the physical release arrives.
	-- XKB already saw its down; the last original owner must still retire it.
	for other, current in pairs(view.owners) do
		if other ~= owner and current.code == ev.code
			and (current.state == "held" or current.state == "spent") then return false end
	end
	return true
end

local function _call_callback(label, callback, ...)
	local args = { n = select("#", ...), ... }
	local unpack_args = table.unpack or unpack
	return RuntimeGuard.call(label, function() return callback(unpack_args(args, 1, args.n)) end, function()
		M.emergency_stop(label .. " failed")
	end)
end

local function _resynchronise(source, snapshot, cohort)
	local pressed = {}
	if cohort then
		for _, peer in ipairs(cohort) do
			if peer.source ~= source then
				for code in pairs(peer.keys) do
					pressed[source_key(peer.source, code)] = { source = peer.source, code = code, held_origin = peer.held }
				end
			end
		end
	else
		for key, current in pairs(_physical_down) do
			if current.source ~= source then pressed[key] = current end
		end
	end

	local slot = keyboard_slot(source)
	local held_receipt = snapshot and snapshot.held
		or EvdevReader.capture_pressed_keys and EvdevReader.capture_pressed_keys(slot, KEY_MAX) or nil
	local held_view = not snapshot and held_receipt and EvdevReader.pressed_keys_view(held_receipt) or nil
	local source_keys, key_err
	if snapshot then source_keys = snapshot.keys
	elseif held_view then
		source_keys = {}
		for _, code in ipairs(held_view.down) do source_keys[code] = true end
	else source_keys, key_err = EvdevReader.pressed_keys(slot, KEY_MAX) end
	local leds, led_err
	if snapshot then leds = snapshot.leds
	else leds, led_err = EvdevReader.active_leds(slot, _locks.last_led) end
	if not source_keys or not leds then
		return false, string.format("state query failed for %s: %s; %s", source,
			tostring(key_err), tostring(led_err))
	end
	for code in pairs(source_keys) do
		pressed[source_key(source, code)] = { source = source, code = code, held_origin = held_receipt }
	end

	-- The engine's keys are released and its physically held keys consumed:
	-- replaying a held CapsLock as itself would toggle the lock, where the user
	-- was holding it for Ctrl.
	if _remapper then
		if _release_remapped() == false then return false, "combination key retirement refused" end
		if _remapper.activate and _remapper:activate() ~= true then return false, "combination activation refused" end
		for key, current in pairs(pressed) do
			if _remapper:handles(current.code) then
				_remap_orphans[key] = true
				pressed[key] = nil
			end
		end
		_remap_owned = {}
	end
	local consumed = _consumed_down
	local reset_ok, reset_err = _reset_capture_state()
	if not reset_ok then return false, tostring(reset_err) end
	_reset_modifier_state()
	local ordered = {}
	for key, current in pairs(pressed) do
		ordered[#ordered + 1] = { key = key, source = current.source, code = current.code }
	end
	table.sort(ordered, function(left, right)
		local left_modifier = _modifier_role(left.code) ~= nil
		local right_modifier = _modifier_role(right.code) ~= nil
		if left_modifier ~= right_modifier then return left_modifier end
		if left.code ~= right.code then return left.code < right.code end
		return left.key < right.key
	end)
	local captured = {}
	for _, current in ipairs(ordered) do
		local key = current.key
		local role = _modifier_role(current.code)
		-- Already-consumed presses remain physical cleanup debt, but the output
		-- no longer holds them. Replaying their modifiers here would invent text.
		if not consumed[key] then
			if not _locks.keys[current.code] and (not role or not captured[current.code]) then
				captured[current.code] = true
				local _, _, capture_err = _capture(current.code, InputEvent.VALUE_DOWN)
				if capture_err then return false, tostring(capture_err) end
			end
			_track_modifier(current.source, current.code, InputEvent.VALUE_DOWN, role)
			-- Reconciliation saw an already-held key, not a fresh admitted DOWN.
			_pressed_at[key] = _on_hold_admission == nil and Monotonic.now_ms() or nil
			_hold_owners[key] = _on_hold_admission == nil
				and { token = _legacy_hold_owner, callback = nil } or nil
		end
		if consumed[key] then _consumed_down[key] = true end
	end
	local seeded, seed_err = _locks.seed_leds(leds)
	if not seeded then return false, seed_err end

	if snapshot then
		if snapshot.current() ~= true then return false, "pending source query revoked" end
	elseif held_receipt and not EvdevReader.pressed_keys_current(held_receipt) then return false, "held source query revoked" end
	if _intercept then
		for key, forwarded in pairs(_forwarded_down) do
			if not pressed[key] then
				local emitted = _forward_raw({ type = EVDEV_TYPE_KEY, code = forwarded.code, value = InputEvent.VALUE_UP,
					original_source = forwarded.source }, forwarded.owner_source or forwarded.source)
				if not emitted then
					return false, "could not release a key lost during queue overflow"
				end
			end
		end
		for key, current in pairs(pressed) do
			if not _forwarded_down[key] and not consumed[key] then
				local emitted = _forward_raw({ type = EVDEV_TYPE_KEY, code = current.code, value = InputEvent.VALUE_DOWN }, current.source)
				if not emitted then
					return false, "could not restore a key held during queue overflow"
				end
			end
		end
	end

	_physical_down = pressed
	_forwarded_down = {}
	if _intercept then
		for key, current in pairs(pressed) do
			if not consumed[key] then
				_forwarded_down[key] = { code = current.code, source = current.source, owner_source = current.source }
			end
		end
	end
	return true
end

--- Handles one decoded event: re-emits it when we own the stream, then turns it
--- into the domain callbacks.
--- @param ev table { type = integer, code = integer, value = integer }.
--- @param source string|nil Stable source identity.
--- When a key event happened, in milliseconds, for telling a tap from a hold.
--- The kernel's stamp, not the time the daemon reads the event: a daemon busy
--- for a moment reads a 100 ms tap's release late, and timed on reading it
--- measured a hold (a Shift tap that never copied). Every evdev device stamps
--- on the same clock, so stamps compare across keyboards; only an event the
--- kernel did not stamp (a replayed test stream) is timed on reading it.
--- @param ev table A decoded event.
--- @return number
local function _event_time_ms(ev)
	local at_ms
	if type(ev.timestamp_us) == "number" and ev.timestamp_us > 0 then
		at_ms = ev.timestamp_us / 1000
	else
		at_ms = _test_clock_ms or Monotonic.now_ms()
	end
	_clock_event_ms, _clock_read_ms = at_ms, Monotonic.now_ms()
	return at_ms
end

--- The time now on the clock the events carry, from the last one read: the
--- kernel's stamps are not the daemon's monotonic clock. Never ahead of the
--- real time, or a hold would go down before a key typed within its
--- threshold: two readings of the daemon's clock can overstate the time
--- between them by its resolution (a whole second without luv), so that is
--- taken off. An event read late leaves it behind by as long as that event
--- waited, and a hold then goes down late, never early; an earlier estimate is
--- not kept over it because the kernel stamps on the wall clock
--- (CLOCK_REALTIME), which can step back, and a clock kept ahead of a step
--- back would press every later hold at once.
--- @return number|nil nil before any event.
local function _event_clock_now_ms()
	if not _clock_event_ms then return nil end
	local since_read = Monotonic.now_ms() - _clock_read_ms - Monotonic.resolution_ms()
	return _clock_event_ms + math.max(0, since_read)
end

--- Accepts only the explicit native repeat receipt; boolean consumers stay once-only.
--- @param receipt any Consumer result.
--- @return function|nil callback Exact callback owned by this physical press.
local function consumed_repeat_callback(receipt)
	if type(receipt) ~= "table" or getmetatable(receipt) ~= nil or receipt.consume ~= true
		or type(receipt.repeat_callback) ~= "function" then return nil end
	for key in pairs(receipt) do
		if key ~= "consume" and key ~= "repeat_callback" then return nil end
	end
	return receipt.repeat_callback
end

--- Detaches the native event identity and its already-published origin epoch.
--- @param ev table Decoded evdev event.
--- @param source string Owned device path.
--- @param identity string|nil Native layout identity.
--- @param char string|nil Native layout character.
--- @return table detail Consumer event.
local function consumption_detail(ev, source, identity, char)
	return { key = identity or char, char = char, code = ev.code,
		physical = ev.remapped ~= true and _physical_sources[source] == true,
		origin_generation = _origin_ready and _origin_generation or nil,
		value = ev.value, mods = M.held_modifiers(), shift_side = M.held_shift_side(),
	}
end

--- Internal Hook consumer of the actual receiving-row producer.
--- The original Hook supplies event_current/owner_current/shift_codes closures,
--- real installed broker/emitter, and commits native Compose only after delivery.
--- Constructor/lifecycle insertion into Hook is still being composed privately.

local function build_row_owners(rows, broker, emitter, owner_current, event_current, shift_codes, commit_action, release_action)
	local ports = { edge = broker.edge, handoff = broker.handoff, view = broker.view,
		current = broker.output_current, retired = broker.output_retired, debt = broker.has_debt }
	local owners, closing, busy = {}, {}, false
	local function binding_current()
		return broker.edge == ports.edge and broker.handoff == ports.handoff and broker.view == ports.view
			and broker.output_current == ports.current and broker.output_retired == ports.retired
			and broker.has_debt == ports.debt and ports.debt() == false
	end
	local function admitted(event)
		return owner_current() == true and binding_current() and event_current(event) == true
	end
	local function admitted_shift(record, event)
		-- Rejoin retained Shift sources after the event/inventory observers.
		return admitted(event) and type(record.shift_current) == "function" and record.shift_current() == true
	end
	local function receipt(value)
		return type(value) == "table" and value.ok == true and type(value.native_writes) == "number"
			and value.native_writes % 1 == 0 and value.native_writes >= 0 and value.native_writes <= 1
	end
	local function cleanup(record)
		-- Retain custody before any observer, including a throwing/debt path.
		closing[record] = true
		-- Cleanup may outlive source admission; it targets only original owners.
		if not binding_current() then
			if ports.retired() == true then closing[record] = nil; return true end
			return false
		end
		local settled = true
		local before = ports.view()
		if type(before) ~= "table" or type(before.owners) ~= "table" then return false end
		if record.row_attempted and before.owners[record.owner] ~= nil then
			local ack = ports.edge(record.owner, record.code, 0, emitter)
			if not receipt(ack) then settled = false
			elseif ack.native_writes == 1 then record.release_emitted = true end
		end
		if record.shift_attempted and before.owners[record.shift_owner] ~= nil then
			local ack = ports.edge(record.shift_owner, 42, 0, emitter)
			if not receipt(ack) then settled = false end
		end
		for index = #record.lifted, 1, -1 do
			local lifted = record.lifted[index]
			if lifted.state == "suspended" then
				-- A retired input cannot authorize a new restored Shift down.
				-- Keep the exact suspended broker owner and cleanup record.
				if type(record.shift_current) ~= "function" or record.shift_current() ~= true then settled = false
				else
					lifted.state = "restoring"
					local ack = ports.handoff(lifted.code, "restored", emitter)
					if receipt(ack) then lifted.state = "restored" else settled = false end
				end
			elseif lifted.state ~= "restored" then settled = false end
		end
		local view = ports.view()
		if type(view) ~= "table" or view.busy ~= false or view.debt ~= false or type(view.owners) ~= "table"
			or view.owners[record.owner] ~= nil or view.owners[record.shift_owner] ~= nil then settled = false end
		if settled and record.release_emitted and not record.release_committed then
			record.release_committed = true
			local called, acknowledged = pcall(release_action, record.code)
			if not called or acknowledged ~= true then settled = false end
		end
		if settled or ports.retired() == true then closing[record] = nil; return true end
		return false
	end
	local function event(key, ev, mode, position, physical_shift, prepared)
		if busy then return false, "row-owner-busy" end
		local value, record = ev.value, owners[key]
		if value == 0 then
			if not record then return false, "ordinary" end
			if event_current(ev) ~= true then return false, "row-release-origin-refused" end
			owners[key] = nil
			busy = true
			local called, closed = pcall(cleanup, record)
			rows.retire(record.plan)
			if called and closed == true and record.release_emitted and not record.release_committed then
				record.release_committed = true
				local released, ack = pcall(release_action, record.code)
				closed = released and ack == true
			end
			busy = false
			return called and closed == true, "retirement"
		end
		if not admitted(ev) then
			if record then
				owners[key] = nil; record.closed = true
				pcall(cleanup, record); rows.retire(record.plan)
			end
			return false, "row-owner-unavailable"
		end
		if value ~= 1 and value ~= 2 then return false, "row-value-refused" end
		if value == 2 and not record then return false, "ordinary" end
		if record and record.closed then return false, "row-owner-retired" end
		if record and value == 1 then
			if prepared then rows.retire(prepared) end
			return true, { status = "duplicate-owner", native_writes = 0 }
		end
		busy = true
		local called, accepted, outcome = pcall(function()
			if record and value == 2 then
				local next_plan = prepared
				local next_action = next_plan and rows.desired(next_plan)
				if not next_action or next_action.code ~= record.code or not admitted(ev) then
					if next_plan then rows.retire(next_plan) end
					return false, "row-repeat-source-refused"
				end
				rows.retire(record.plan)
				record.plan = next_plan
			end
			if not record then
				local plan = prepared
				if not plan or not admitted(ev) then return false, "ordinary" end
				local desired = rows.desired(plan)
				if not desired or desired.code ~= ev.code then rows.retire(plan); return false, "row-plan-refused" end
				record = { plan = plan, owner = {}, shift_owner = {}, code = desired.code, lifted = {}, key = key, mode = mode, position = position }
				owners[key] = record -- Reserve before any output callback can stop Hook.
			end
			local desired = rows.desired(record.plan)
			if not desired or not admitted(ev) then return false, "row-source-refused" end
			local held, shift_current = shift_codes()
			record.shift_current = shift_current
			if type(held) ~= "table" or type(shift_current) ~= "function" or shift_current() ~= true
				or (physical_shift and #held == 0) or (not physical_shift and #held ~= 0) then
				return false, "row-physical-shift-unqualified"
			end
			if not desired.shift then
				for _, code in ipairs(held) do
					if not admitted_shift(record, ev) then return false, "row-source-refused" end
					local lifted = { code = code, state = "suspending" }
					record.lifted[#record.lifted + 1] = lifted
					if not receipt(ports.handoff(code, "suspended", emitter)) then return false, "row-prefix-unknown" end
					lifted.state = "suspended"
				end
			elseif #held == 0 then
				if not admitted_shift(record, ev) then return false, "row-source-refused" end
				record.shift_attempted = true
				if not receipt(ports.edge(record.shift_owner, 42, 1, emitter)) then return false, "row-prefix-unknown" end
			end
			local action = rows.observe(record.plan, desired.shift)
			if not action or not admitted_shift(record, ev) then return false, "row-receiving-source-refused" end
			record.row_attempted = true
			local ack = ports.edge(record.owner, record.code, value, emitter)
			if not receipt(ack) then return false, "row-prefix-unknown" end
			-- The KEY/SYN acknowledgement is transport evidence, not desktop text.
			local emitted = ack.native_writes == 1
			if record.shift_attempted then
				if not admitted_shift(record, ev) then return false, "row-restore-source-refused" end
				if not receipt(ports.edge(record.shift_owner, 42, 0, emitter)) then return false, "row-restore-unknown" end
				record.shift_attempted = nil
			end
			for index = #record.lifted, 1, -1 do
				local lifted = record.lifted[index]
				if not admitted_shift(record, ev) then return false, "row-restore-source-refused" end
				lifted.state = "restoring"
				if not receipt(ports.handoff(lifted.code, "restored", emitter)) then return false, "row-restore-unknown" end
				lifted.state = "restored"
			end
			record.lifted = {}
			if not admitted_shift(record, ev) or ports.current() ~= true then return false, "row-post-delivery-revoked" end
			local committed, text, identity = commit_action(record.plan, action, ev.code, value, emitted)
			if committed ~= true then return false, "row-compose-refused" end
			if not admitted_shift(record, ev) or ports.current() ~= true then return false, "row-post-commit-revoked" end
			return true, { status = emitted and "native-wire-acknowledged" or "ownership-only",
				native_writes = ack.native_writes, text = text, identity = identity }
		end)
		if not called or accepted ~= true then
			if record then
				record.closed = true
				owners[key] = nil
				pcall(cleanup, record)
				rows.retire(record.plan)
			end
		end
		busy = false
		return called and accepted == true, called and outcome or "row-delivery-unresolved"
	end
	local function retire_all()
		local settled = true
		for key, record in pairs(owners) do
			owners[key] = nil
			record.closed = true
			local called, closed = pcall(cleanup, record)
			rows.retire(record.plan)
			if not called or closed ~= true then settled = false end
		end
		for record in pairs(closing) do
			local called, closed = pcall(cleanup, record)
			if called and closed == true then closing[record] = nil else settled = false end
		end
		return settled
	end
	return { event = event, retire = retire_all,
		has = function(key) return owners[key] ~= nil end,
		keys = function() local keys = {}; for key in pairs(owners) do keys[#keys + 1] = key end; return keys end }
end


--- Connected opt-in backend. Public policy/menu capability remains unchanged.
--- No boolean/string native profile grants output: only the original issuer,
--- same Probe connection, live map and native row selector can create a plan.
function _number_row.binding(record)
	if not record or _capture_session ~= record.session or _capture_options ~= record.options
		or _broker ~= record.broker or _emit_raw ~= record.emitter or _input_output_owner ~= record.output
		or _input_source_owners ~= record.sources or _input_source_observers ~= record.observers
		or _origin_generation ~= record.origin or _source_reconciliation or not _input_exports_current()
		or not _running or not _intercept or _capture_options.numberRowMode ~= record.mode
		or package.loaded["adapters.xkb_capture"] ~= XkbCapture then return false end
	local output = record.output
	if not output or package.loaded["adapters.uinput_writer"] ~= output.writer
		or ModifierBroker.for_channel ~= installed_output_broker then return false end
	local broker, observer = installed_output_broker(output.writer)
	if broker ~= record.broker or observer ~= output.binding or observer(record.broker) ~= true then return false end
	for _, name in ipairs(INPUT_OUTPUT_PORT_NAMES) do if output.writer[name] ~= output.ports[name] then return false end end
	return output.writer.capture_kernel_source == record.kernel_capture
		and output.writer.kernel_source_ports == record.kernel_ports
		and XkbCapture.capture_receiving_rows == record.capture_rows and XkbCapture.receiving_row_ports == record.row_ports
		and package.loaded["modules.hotstrings.device_finder"] == record.finder
		and rawget(record.finder, "physical_sources") == record.source_inventory
end
function _number_row.input_allowed(record, source)
	if not _number_row.binding(record) or record.rows.input_allowed(source) ~= true then return false end
	-- The original kernel inventory is used ONLY for exclusion/known canonical
	-- naming. Its physical boolean is deliberately unread: a genuine virtual
	-- Reader stream is eligible without becoming physical/Caps/OneShot evidence.
	local rows = record.source_inventory({ source })
	local row = type(rows) == "table" and getmetatable(rows) == nil and #rows == 1 and rawget(rows, 1) or nil
	return type(row) == "table" and getmetatable(row) == nil and row.path == source
		and type(row.name) == "string" and row.name ~= "" and row.name ~= record.writer_name
		and type(row.sysfs) == "string" and row.sysfs ~= "" and _number_row.binding(record)
		and record.rows.input_allowed(source) == true
end
function _number_row.event_current(record, ev, source)
	if not _input_exports_current() or ev.remapped or ev.handoff
		or _sync_dropped[source] or (ev.value ~= InputEvent.VALUE_UP and not _number_row.input_allowed(record, source)) then return false end
	local origin, slot = _event_receipts[ev], keyboard_slot(source)
	local view = origin and _input_reader_ports.event_view(origin)
	return type(view) == "table" and view.source == source and view.slot == slot and origin ~= nil and _input_reader_ports.event_current(origin, ev, slot) == true
		and _input_reader_ports.source_current(origin, record.sources[slot], record.observers[slot],
			_input_reader_ports.capture_source_owner, _input_reader_ports.source_owner_current, _input_reader_ports.retire_source) == true
		and (ev.value == InputEvent.VALUE_UP or _number_row.binding(record))
		and _input_reader_ports.event_current(origin, ev, slot) == true and _input_exports_current()
end
function _number_row.shift_codes(record)
	local seen, codes, retained = {}, {}, {}
	local function shift_current()
		-- Original Reader observations are RAM-only. No inventory or native
		-- callback follows these joins before the caller's output decision.
		if not _input_exports_current() then return false end
		for _, held in ipairs(retained) do
			if _physical_down[held.stamp] ~= held.down or held.down.origin ~= held.origin
				or held.down.source ~= held.source or held.down.code ~= held.code
				or _modifier_down[held.key] ~= "shift" or _sync_dropped[held.source]
				or record.sources[held.slot] ~= held.lease or record.observers[held.slot] ~= held.observer
				or _input_reader_ports.source_current(held.origin, held.lease, held.observer,
					_input_reader_ports.capture_source_owner, _input_reader_ports.source_owner_current,
					_input_reader_ports.retire_source) ~= true then return false end
		end
		return true
	end
	for _, entry in ipairs(_modifier_order) do
		if _modifier_down[entry.key] == "shift" then
			local stamp = entry.key
			local down = _physical_down[stamp]
			if not down then
				local forwarded = _forwarded_down[entry.key]
				if forwarded then stamp = source_key(forwarded.source, entry.code); down = _physical_down[stamp] end
			end
			if not down or not down.origin or _sync_dropped[down.source]
				or _number_row.input_allowed(record, down.source) ~= true then return nil end
			local slot = keyboard_slot(down.source)
			local held = { stamp = stamp, key = entry.key, down = down, source = down.source, code = entry.code,
				origin = down.origin, slot = slot, lease = record.sources[slot], observer = record.observers[slot] }
			retained[#retained + 1] = held
			if not shift_current() then return nil end
			if not seen[entry.code] then seen[entry.code] = true; codes[#codes + 1] = entry.code end
		end
	end
	if not _number_row.binding(record) or not shift_current() then return nil end
	return codes, shift_current
end
function _number_row.retire()
	local record = _number_row.active
	_number_row.active = nil -- Revoke admission before original cleanup callbacks.
	if record then
		for _, key in ipairs(record.owners.keys()) do _number_row.suppressed[key] = true end
		_number_row.retired[record] = true
	end
	local closed = true
	for owned in pairs(_number_row.retired) do
		-- Output settlement is independent of the now-revoked source/map.
		local called, ack = pcall(owned.owners.retire)
		if called and ack == true then
			local target_called, target_closed = pcall(owned.rows.close)
			if target_called and target_closed == true then _number_row.retired[owned] = nil else closed = false end
		else closed = false end
	end
	return closed
end
function _number_row.construct()
	if _number_row.mode == "native" or _number_row.active or next(_number_row.retired) ~= nil
		or not _input_output_owner or not _running or not _intercept or not original_reader_load
		or not _input_exports_current() or _source_reconciliation then return false end
	local output, options = _input_output_owner, _capture_options
	local writer = output.writer
	local finder = require("modules.hotstrings.device_finder")
	local source_inventory = rawget(finder, "physical_sources")
	if type(source_inventory) ~= "function" then return false end
	local writer_name = require("infra.device_names").VIRTUAL_KEYBOARD
	if type(writer_name) ~= "string" or writer_name == "" then return false end
	local kernel_capture, kernel_ports, capture_rows, row_ports = writer.capture_kernel_source, writer.kernel_source_ports,
		XkbCapture.capture_receiving_rows, XkbCapture.receiving_row_ports
	if type(kernel_capture) ~= "function" or type(kernel_ports) ~= "function" or type(capture_rows) ~= "function" or type(row_ports) ~= "function" then return false end
	local record = { session = _capture_session, options = options, mode = _number_row.mode,
		broker = _broker, emitter = _emit_raw, output = output, sources = _input_source_owners,
		observers = _input_source_observers, origin = _origin_generation,
		kernel_capture = kernel_capture, kernel_ports = kernel_ports, capture_rows = capture_rows, row_ports = row_ports,
		finder = finder, source_inventory = source_inventory, writer_name = writer_name }
	if not _number_row.binding(record) then return false end
	local called, kernel = pcall(kernel_capture)
	if not called or not kernel then return false end
	local captured, token = pcall(capture_rows, kernel)
	local rows = captured and token and row_ports(token) or nil
	if not rows or not _number_row.binding(record) then
		local ports = kernel_ports(kernel)
		if ports and ports.close() ~= true then
			_number_row.retired[record] = true
			record.owners = { keys = function() return {} end, retire = function() return true end }
			record.rows = { close = ports.close }
		end
		return false
	end
	record.rows = rows
	-- event() stores the exact source/event only for this synchronous delivery.
	record.owners = build_row_owners(rows, record.broker, record.emitter,
		function() return _number_row.active == record and _number_row.binding(record) end,
		function(ev) return record.event == ev and _number_row.event_current(record, ev, record.source) end,
		function() return _number_row.shift_codes(record) end, rows.commit, function(code)
			if rows.capture_current() ~= true then return true end -- Session retired: do not call a stale native pointer.
			return rows.release(code)
		end)
	_number_row.active = record
	return true
end
function _number_row.drive()
	local record = _number_row.active
	if not record then return end
	local called, admitted = pcall(record.rows.drive)
	if not called or admitted == false or not _number_row.binding(record) then
		if _number_row.retire() then _number_row.construct() end -- Explicit native/source epoch replacement.
	end
end
function _number_row.preview(ev, source)
	local key = source_key(source, ev.code)
	if _number_row.suppressed[key] then
		if ev.value == InputEvent.VALUE_UP then _number_row.suppressed[key] = nil end
		return { suppressed = true }
	end
	local record = _number_row.active
	if not record or ev.remapped or ev.handoff then return nil end
	if record.owners.has(key) and ev.value ~= InputEvent.VALUE_UP
		and not _number_row.event_current(record, ev, source) then
		_number_row.retire(); return { suppressed = true }
	end
	if record.owners.has(key) and ev.value == InputEvent.VALUE_UP then return { record = record, key = key, release = true } end
	if ev.code < 2 or ev.code > 11 or ev.value == InputEvent.VALUE_UP
		or (ev.value == InputEvent.VALUE_REPEAT and not record.owners.has(key)) or _consumed_down[key]
		or _shortcut_modifier_held() or _altgr_held or not _number_row.event_current(record, ev, source) then return nil end
	local plan = record.rows.prepare({ 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 }, record.mode, ev.code - 1, _shift_held)
	if not plan then return nil end
	local preview = record.rows.preview(plan)
	if not preview or not _number_row.event_current(record, ev, source) then record.rows.retire(plan); return nil end
	return { record = record, key = key, plan = plan, text = preview.text, identity = preview.identity }
end
function _number_row.abandon(plan, ev, consumed)
	if plan and plan.plan then
		if consumed then return plan.record.rows.suppress(plan.plan, ev.code) end
		return plan.record.rows.retire(plan.plan)
	end
end
function _number_row.deliver(plan, ev, source)
	if plan.suppressed then return true, nil, nil end
	local record = plan.record
	record.event, record.source = ev, source
	local called, accepted, outcome = pcall(record.owners.event, plan.key, ev, record.mode, ev.code - 1, _shift_held, plan.plan)
	record.event, record.source = nil, nil
	if not called or accepted ~= true then
		_number_row.abandon(plan, ev, false)
		M.emergency_stop("native number-row source/output retirement refused")
		return false
	end
	if type(outcome) == "table" then return true, outcome.text, outcome.identity end
	return true, nil, nil
end

--- Whether a chord came from the tap-hold engine rather than the hand: the key
--- itself is one the engine produced (a navigation-layer chord), or a held
--- Ctrl, Alt or Super is (a tap-hold hold). Such a modifier is tracked under its
--- "remapper:" source, a physical one under its device. The daemon gives this
--- chord to hotstrings.tap_hold_resets_word instead of shortcut_resets_word.
--- @param ev table The dispatched event.
--- @return boolean|nil True for a tap-hold chord, nil otherwise.
local function _tap_hold_chord(ev)
	if ev.remapped and not ev.original_owner then return true end
	for _, entry in ipairs(_modifier_order) do
		local role = _modifier_down[entry.key]
		if (role == "ctrl" or role == "alt" or role == "meta") and entry.key:sub(1, 9) == "remapper:" then
			return true
		end
	end
	return nil
end

--- Dispatches the original post-remapper path without widening the LuaJIT closure.
--- The event/source and all native capture, modifier, callback and IO guards stay live.
local function _dispatch_post_remap(ev, source)
	local original_source = source
	if ev.remapped and not ev.original_owner then
		local holder_key = _remapper_generation .. ":" .. (ev.holder or "transient") .. ":" .. ev.code
		if ev.value == InputEvent.VALUE_DOWN and not _synthetic_source_of[holder_key] then
			_synthetic_source_of[holder_key] = source
		end
		original_source = _synthetic_source_of[holder_key] or source
		source = "remapper:" .. _remapper_generation .. ":" .. (ev.holder or "transient") .. ":" .. tostring(original_source)
		if ev.value == InputEvent.VALUE_UP then _synthetic_source_of[holder_key] = nil end
	end
	_wire_source_of[ev] = original_source
	-- Observe the role before every XKB transition, including custody handoffs.
	local pressed = ev.value ~= InputEvent.VALUE_UP
	local role, role_failed = nil, false
	if ev.value == InputEvent.VALUE_DOWN then role, role_failed = _modifier_role(ev.code) end
	if ev.handoff then
		local _, _, capture_err = _capture(ev.code, ev.value)
		if capture_err then M.emergency_stop("XKB handoff capture refused: " .. tostring(capture_err)); return end
		_forward_raw(ev, source)
		return
	end
	local modifier_key = source_key(source, ev.code)
	local held_role = _modifier_down[modifier_key]
	local aggregate_before = false
	for _, entry in ipairs(_modifier_order) do
		if entry.code == ev.code then aggregate_before = true; break end
	end
	local is_modifier = _track_modifier(source, ev.code, ev.value, role)
	local aggregate_after = false
	for _, entry in ipairs(_modifier_order) do
		if entry.code == ev.code then aggregate_after = true; break end
	end
	local capture_transition = not is_modifier
		or (ev.value == InputEvent.VALUE_DOWN and not aggregate_before and aggregate_after)
		or (ev.value == InputEvent.VALUE_UP and aggregate_before and not aggregate_after)
		or (ev.value == InputEvent.VALUE_REPEAT and held_role ~= nil)
	local char, identity, capture_err
	local row_plan = not is_modifier and _number_row.preview(ev, source) or nil
	if not is_modifier and not row_plan and not _capture_wire_transition(ev, source) then capture_transition = false end
	if row_plan then char, identity = row_plan.text, row_plan.identity
	elseif capture_transition then char, identity, capture_err = _capture(ev.code, ev.value) end

	if capture_err then
		_xkb_failed("XKB capture failed (code=%d value=%d) — %s.", ev.code, ev.value, tostring(capture_err))
	elseif ev.value == InputEvent.VALUE_DOWN and not role_failed then
		-- A press asks XKB both questions: answered, XKB is back.
		_xkb_answered()
	end

	-- Publish physical identity before any interpretation branch can return.
	-- Down and up are both exposed so consumers can choose their metric; repeat is
	-- not a new physical transition. This includes modifiers and CapsLock.
	if _on_physical and ev.value ~= InputEvent.VALUE_REPEAT and ev.code > 0 then
		if not _call_callback("physical-key callback", _on_physical,
			ev.code, EvdevCodes.key_name(ev.code), char, ev.value) then
			-- The callback already triggered the emergency stop; the grabbed
			-- event must still reach the application before giving up on it.
			_number_row.abandon(row_plan, ev, false)
			_forward_raw(ev, source)
			return
		end
	end

	-- XKB has already consumed the transition above. Modifiers still produce no
	-- domain event; returning here prevents a test double or a malformed keymap
	-- from inventing a typed character for a physical modifier.
	if is_modifier then
		_forward_raw(ev, source)
		return
	end
	if ev.code == EvdevCodes.KEY_CAPSLOCK then
		-- The desktop's CapsLock is the user's again: a CapsWord session riding
		-- on it ends, and must not toggle it back.
		if ev.value == InputEvent.VALUE_DOWN and _locks.word then _locks.end_word(false, "CapsLock pressed") end
		_forward_raw(ev, source)
		return
	end

	-- How long the key was held, measured here because this is the only place a
	-- release is seen at all.
	--
	-- The line below used to say releases carry no meaning past modifier
	-- tracking, and for the text path that is true. It is not true for the
	-- metrics: on a keyboard whose whole design is tap-hold, how long a key was
	-- held is the difference between the two things it can mean, and
	-- agg_app_day_kc_hold was empty because nothing measured it.
	if ev.value == InputEvent.VALUE_DOWN and ev.code > 0 then
		local key = source_key(source, ev.code)
		local token, callback = hold_owner()
		_pressed_at[key] = token and Monotonic.now_ms() or nil
		_hold_owners[key] = token and { token = token, callback = callback } or nil
	elseif ev.value == InputEvent.VALUE_UP and ev.code > 0 then
		local pressed_key = source_key(source, ev.code)
		local down_at, owner = _pressed_at[pressed_key], _hold_owners[pressed_key]
		_pressed_at[pressed_key], _hold_owners[pressed_key] = nil, nil
		local token, callback = hold_owner()
		if down_at and owner and rawequal(owner.token, token)
			and rawequal(owner.callback, callback) and _on_hold then
			-- Clamped, because a release can arrive after a suspend, a lost
			-- descriptor or a lid close, and one such reading would dominate every
			-- average it entered for the rest of the day.
			local held_ms = math.min(math.max(0, Monotonic.now_ms() - down_at), MAX_PLAUSIBLE_HOLD_MS)
			if not _call_callback("key-hold callback", _on_hold, ev.code, held_ms) then
				-- A release owns the application's key state: it must go back
				-- even when the metrics consumer just died, or the key sticks
				-- down over there while nothing is held here.
				_number_row.abandon(row_plan, ev, false)
				_forward_raw(ev, source)
				return
			end
		end
	end

	local consumed_key = source_key(source, ev.code)
	if _consumed_down[consumed_key] then
		if ev.value == InputEvent.VALUE_UP then
			_consumed_down[consumed_key] = nil
		else
			-- XKB read each auto-repeat of the consumed press too, a dead key's
			-- included, and the application saw none of them.
			local compose_cancelled = _cancel_capture_compose()
			local repeat_callback = _consumed_down[consumed_key]
			if ev.value == InputEvent.VALUE_REPEAT and type(repeat_callback) == "function" then
				local called, acknowledged = false, false
				if compose_cancelled then
					called, acknowledged = _call_callback("consumed-key repeat callback",
						repeat_callback, consumption_detail(ev, source, identity, char))
				end
				if not called or acknowledged ~= true then
					-- A refusal retires this press; later repeats cannot revive it,
					-- and its suppressed down still owns the eventual release.
					_consumed_down[consumed_key] = true
				end
			end
		end
		return
	end

	-- A consumer can suppress a complete key press only while this adapter owns
	-- the source stream. XKB and modifier state are current before the decision;
	-- raw pass-through and semantic callbacks happen only if it declines.
	if _intercept and not is_modifier and ev.value == InputEvent.VALUE_DOWN and _on_consume then
		local ok_consume, consume = _call_callback("key-consumption callback", _on_consume,
			consumption_detail(ev, source, identity, char))
		local repeat_callback = consumed_repeat_callback(consume)
		if not ok_consume then
			_number_row.abandon(row_plan, ev, false)
			-- A missing verdict is not a suppression: the event still belongs
			-- to the application.
			_forward_raw(ev, source)
			return
		elseif consume == true or repeat_callback ~= nil then
			if _number_row.abandon(row_plan, ev, true) == false then
				M.emergency_stop("native number-row consumed transition refused"); return
			end
			_consumed_down[consumed_key] = repeat_callback or true
			-- A dead key consumed here (a tap key or the physical magic key on
			-- a French ^ or a US-international ') would otherwise stay pending.
			if not _cancel_capture_compose() then
				-- Its first output is already consumed; a refused retirement
				-- cannot leave optional repeats alive for this held press.
				_consumed_down[consumed_key] = true
			end
			return
		end
	end

	if row_plan then
		local delivered, row_text, row_identity = _number_row.deliver(row_plan, ev, source)
		if not delivered then return end
		char, identity = row_text, row_identity
	else
		local delivered, receipt = _forward_raw(ev, source)
		if not delivered then return end
		-- Ownership can settle without typing: duplicate downs, shared presses
		-- and repeats of a key spent by an injection have no semantic text.
		if receipt and receipt.native_writes == 0 then return end
	end

	-- Releases carry no meaning past modifier tracking and the hold above.
	if not pressed then return end

	local control = EvdevCodes.CONTROL_NAME_OF[ev.code]
	if control then
		local text_char = TEXT_CONTROL_CHAR[control]
		if text_char and not _shortcut_modifier_held() then
			-- Enter and Tab are both control keys and enabled hotstring
			-- terminators. Bare presses belong to the matcher; modified presses
			-- remain controls so Alt+Tab and Ctrl+Enter never become text.
			if _on_char then _call_callback("text-control callback", _on_char, text_char, ev.code) end
		elseif _on_key then
			-- The modifiers travel with the key. Ctrl+Backspace deletes a word and
			-- Alt+Backspace undoes in some applications: reported as a bare
			-- "backspace", the daemon undid the last expansion over a word already
			-- gone, or dropped one character of a buffer that had lost a word.
			-- `tap_hold` says a held Ctrl, Alt or Super (or the key) came from a
			-- tap-hold, which decides the option that owns the word reset.
			_call_callback("control-key callback", _on_key, control,
				{ mods = M.held_modifiers(), tap_hold = _tap_hold_chord(ev) })
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
		-- `keystats.record_shortcut` had no caller at all, and the configurable
		-- slots had nothing to match against.
		--
		-- A second argument rather than a different event name: every existing
		-- caller takes one parameter and ignores this, so the contract widens
		-- without any of them changing.
		if _on_key then
			_call_callback("shortcut callback", _on_key,
				"shortcut", { key = identity or char, mods = M.held_modifiers(), tap_hold = _tap_hold_chord(ev) })
		end
		return
	end

	if char and _on_char then
		_call_callback("character callback", _on_char, char, ev.code)
	end
end

--- Runs the acknowledged owned frame with its exact original input context.
--- Kept separate so the dispatcher stays within LuaJIT's 60-upvalue budget.
--- @param frame table Acknowledged native frame.
--- @param tap string|nil Action selected by the frame.
--- @param binding string|nil Exact selected binding.
--- @param exact table Original issuing engine.
--- @param original_generation integer Original remapper generation.
--- @param origin table|nil Exact Reader event receipt.
--- @param origin_view table|nil Detached original event facts.
--- @param source string Original device path.
--- @param at_ms number Original event time.
local function _run_owned_tap_frame(frame, tap, binding, exact, original_generation, origin, origin_view, source, at_ms)
	if tap and _on_tap then
		local callback = _on_tap
		local prior = _live_input_context
		_live_input_context = nil
		if tap == "one_shot_shift" and origin_view and origin_view.source == source
			and origin_view.origin == "native-evdev" and _remapper_input_owner then
			local hook_ports = {}; for _, name in ipairs(INPUT_HOOK_PORT_NAMES) do hook_ports[name] = rawget(M, name) end
			local engine_ports = {}
			for _, name in ipairs({ "process", "tick", "activity", "activate", "configure", "set_tap_holds_enabled",
				"begin_delivery", "end_delivery", "release_all", "ack_retirement", "take_custody", "output_holder" }) do
				engine_ports[name] = rawget(exact, name)
			end
			local finder = package.loaded["modules.hotstrings.device_finder"]
			_live_input_context = { engine = exact, generation = original_generation,
				hook_ports = hook_ports, engine_ports = engine_ports, finder = finder, classify_source = type(finder) == "table" and rawget(finder, "physical_sources") or nil,
				issuer = _remapper_input_owner, origin = origin, source = source,
				origin_generation = _origin_generation, frame = frame, action = tap, binding = binding,
				broker = _broker, output_retire = rawget(_broker, "retire"), emergency_stop = rawget(M, "emergency_stop"),
				engine_release_all = rawget(exact, "release_all"), engine_ack_retirement = rawget(exact, "ack_retirement"),
				engine_output_holder = rawget(exact, "output_holder"),
				sources = _input_source_owners, source_observers = _input_source_observers, pointer_sources = _input_pointer_owners,
				pointer_observers = _input_pointer_observers, output_issuer = _input_output_owner, emitter = _emit_raw, callback = _on_tap, at_ms = at_ms,
				output_view = rawget(_broker, "view"), output_debt = rawget(_broker, "has_debt"),
				output_current = rawget(_broker, "output_current"), output_retired = _input_output_owner and _input_output_owner.terminal }
		end
		if tap == "one_shot_shift" then
			-- The action callback returns semantic intent only. Retain construction
			-- originals: a late Manager snapshot of public ports is not an issuer.
			frame.run(function(action, selected)
				local requested = callback(action, selected)
				if requested ~= tap or action ~= tap then return false end
				local lease = original_input_hook_ports.capture_input_owner()
				if not lease or original_input_hook_ports.input_owner_current(lease) ~= true then return false end
				return original_input_hook_ports.arm_one_shot(lease) == true
					and original_input_hook_ports.input_owner_current(lease) == true
			end, _combination_source(source))
		else frame.run(callback, _combination_source(source)) end
		_live_input_context = prior
	end
end

-- Position capture observes the original stream. It never suppresses a key,
-- lends a logical-action lease, reserves output or changes the existing mapper.
local position_capture = { busy = false, tokens = setmetatable({}, { __mode = "k" }) }
position_capture.reader = {}
for _, name in ipairs({ "capture_pressed_keys", "pressed_keys_view", "pressed_keys_current" }) do
	position_capture.reader[name] = rawget(EvdevReader, name)
end
position_capture.source = rawget(XkbCapture, "source_generation")
position_capture.source_file = HookModuleSource.sibling(hook_source_label,
	"adapters/keyboard_hook.lua", "adapters/xkb_capture.lua", hook_directory)

local function position_runtime(record)
	if not original_reader_load or not _running or not _intercept or _source_reconciliation
		or not rawequal(_capture_session, record.session) or not rawequal(_capture_options, record.options)
		or not rawequal(_input_source_owners, record.sources) or not rawequal(_input_source_observers, record.observers)
		or type(record.sources) ~= "table" or type(record.observers) ~= "table"
		or _origin_generation ~= record.origin or _origin_ready ~= true
		or not rawequal(package.loaded["adapters.keyboard_hook"], M)
		or not rawequal(package.loaded["adapters.evdev_reader"], EvdevReader)
		or not rawequal(package.loaded["platform.remap.key_combination_engine"], InputIssuer)
		or not _input_exports_current()
		or not rawequal(package.loaded["adapters.xkb_capture"], XkbCapture)
		or rawget(XkbCapture, "source_generation") ~= position_capture.source
		or not rawequal(package.loaded["modules.hotstrings.device_finder"], record.finder)
		or type(record.finder) ~= "table" or type(record.classify) ~= "function"
		or rawget(record.finder, "physical_sources") ~= record.classify then return false end
	for name, port in pairs(position_capture.exports) do
		if rawget(M, name) ~= port then return false end
	end
	for _, name in ipairs({ "capture_pressed_keys", "pressed_keys_view", "pressed_keys_current" }) do
		local port = position_capture.reader[name]
		if type(port) ~= "function" or rawget(EvdevReader, name) ~= port then return false end
	end
	for _, path in ipairs(_devices) do
		local slot = keyboard_slot(path)
		if _physical_sources[path] ~= true or _sync_dropped[path]
			or _input_reader_ports.source_owner_current(record.sources[slot], record.observers[slot],
				_input_reader_ports.capture_source_owner, _input_reader_ports.source_owner_current,
				_input_reader_ports.retire_source) ~= true then return false end
	end
	return #_devices > 0
end

local function position_page(record)
	if not rawequal(position_capture.pending, record) or not position_runtime(record) then return false end
	local called, accepted = pcall(record.current)
	return called and accepted == true and rawequal(position_capture.pending, record) and position_runtime(record)
end

--- Reports existing native observation prerequisites without opening a resource.
--- @return boolean available Source/session readiness, never physical delivery.
function M.position_capture_available()
	if position_capture.busy or position_capture.pending or type(position_capture.source) ~= "function" then return false end
	local info = debug.getinfo(position_capture.source, "S")
	if not info or not HookModuleSource.same(info.source, position_capture.source_file, hook_directory) then return false end
	local finder = package.loaded["modules.hotstrings.device_finder"]
	if type(finder) ~= "table" then return false end
	return position_runtime({ session = _capture_session, options = _capture_options,
		sources = _input_source_owners, observers = _input_source_observers, origin = _origin_generation,
		finder = finder, classify = rawget(finder, "physical_sources") })
end

--- Enrolls one exact page's observation-only physical position request.
--- @param current function Captured page epoch and canonical inventory guard.
--- @param receive function Receives detached original evdev code/modifiers.
--- @return table|nil token Exact cancellation identity; never input or output rights.
function M.capture_position(current, receive)
	if position_capture.busy or position_capture.pending or type(current) ~= "function"
		or type(receive) ~= "function" or position_capture.exports.position_capture_available() ~= true then return nil end
	local info = debug.getinfo(position_capture.source, "S")
	if not info or not HookModuleSource.same(info.source, position_capture.source_file, hook_directory) then return nil end
	local finder = package.loaded["modules.hotstrings.device_finder"]
	if type(finder) ~= "table" or type(rawget(finder, "physical_sources")) ~= "function" then return nil end
	local token = {}
	local record = { current = current, receive = receive, token = token, session = _capture_session,
		options = _capture_options, sources = _input_source_owners, observers = _input_source_observers,
		origin = _origin_generation, finder = finder, classify = rawget(finder, "physical_sources") }
	position_capture.tokens[token] = record
	position_capture.busy, position_capture.pending = true, record
	local accepted = position_page(record)
	position_capture.busy = false
	if not accepted then
		if rawequal(position_capture.pending, record) then position_capture.pending = nil end
		position_capture.tokens[token] = nil
		return nil
	end
	return token
end

local function finish_position(record)
	local token = record.token
	if token == nil then return end
	position_capture.tokens[token] = true
	-- LuaJIT may retain a traced record after the call. Completed records carry
	-- no page closure, token cycle or source owner even in that case.
	record.token, record.current, record.receive = nil, nil, nil
	record.session, record.options, record.sources, record.observers, record.finder, record.classify = nil, nil, nil, nil, nil, nil
end

--- Cancels only the original observation; forwarding and key ownership continue.
--- @param token table Exact enrollment token, never a browser field.
--- @return boolean retired
function M.cancel_position(token)
	local record = position_capture.tokens[token]
	if not record or getmetatable(token) ~= nil or next(token) ~= nil then return false end
	if rawequal(position_capture.pending, record) then position_capture.pending = nil end
	if record ~= true then finish_position(record) end
	return true
end

position_capture.exports = { capture_position = M.capture_position, cancel_position = M.cancel_position,
	position_capture_available = M.position_capture_available }

local function _observe_position_capture(ev, source)
	local record = position_capture.pending
	if not record or position_capture.busy or ev.remapped or ev.type ~= EVDEV_TYPE_KEY
		or ev.value ~= InputEvent.VALUE_DOWN or EvdevCodes.MODIFIER_OF[ev.code] then return end
	position_capture.busy = true
	local function observe()
		if not position_page(record) then return false end
		local origin = _event_receipts[ev]
		local view = origin and _input_reader_ports.event_view(origin)
		local slot = keyboard_slot(source)
		if not view or view.origin ~= "native-evdev" or view.source ~= source or view.slot ~= slot
			or view.code ~= ev.code or view.value ~= ev.value or _physical_sources[source] ~= true then return false end
		local held, modifiers, found = {}, {}, false
		local roles = { [EvdevCodes.KEY_LEFTCTRL] = "ctrl", [EvdevCodes.KEY_RIGHTCTRL] = "ctrl",
			[EvdevCodes.KEY_LEFTALT] = "alt", [EvdevCodes.KEY_LEFTSHIFT] = "shift",
			[EvdevCodes.KEY_RIGHTSHIFT] = "shift", [EvdevCodes.KEY_LEFTMETA] = "super",
			[EvdevCodes.KEY_RIGHTMETA] = "super" }
		local function exact()
			if not position_runtime(record) or not rawequal(position_capture.pending, record)
				or _input_reader_ports.event_current(origin) ~= true
				or _input_reader_ports.source_current(origin, record.sources[slot], record.observers[slot],
					_input_reader_ports.capture_source_owner, _input_reader_ports.source_owner_current,
					_input_reader_ports.retire_source) ~= true then return false end
			for _, receipt in ipairs(held) do
				if position_capture.reader.pressed_keys_current(receipt) ~= true then return false end
			end
			return true
		end
		for _, path in ipairs(_devices) do
			local receipt = position_capture.reader.capture_pressed_keys(keyboard_slot(path))
			local bits = receipt and position_capture.reader.pressed_keys_view(receipt)
			if not bits or bits.source ~= path or bits.origin ~= "native-evdev" then return false end
			held[#held + 1] = receipt
			if not exact() then return false end
			for _, code in ipairs(bits.down) do
				-- Physical RightAlt is not silently reinterpreted as plain Alt;
				-- AltGr's fake Ctrl and effective layout role require another owner.
				if code == EvdevCodes.KEY_RIGHTALT then return false end
				if roles[code] then modifiers[roles[code]] = true end
				if path == source and code == ev.code then found = true end
			end
		end
		if not found or not exact() then return false end
		local called, generation, _, source_current = pcall(position_capture.source)
		if not called or type(generation) ~= "number" or generation < 0 or generation % 1 ~= 0
			or type(source_current) ~= "function" or not exact() then return false end
		local function sealed()
			if not exact() then return false end
			local seen, current = pcall(source_current)
			return seen and current == true and exact()
		end
		if not sealed() or not position_page(record) or not sealed() then return false end
		local delivered, accepted = pcall(record.receive, { native_code = ev.code, mods = modifiers })
		return delivered and accepted == true and sealed() and position_page(record) and sealed()
	end
	local called, accepted = pcall(observe)
	position_capture.busy = false
	-- A refused attempted primary press never remains armed for a different key.
	if rawequal(position_capture.pending, record) then position_capture.pending = nil end
	finish_position(record)
	return called and accepted == true
end

local function _dispatch_event(ev, source)
	_observe_position_capture(ev, source)
	-- Intercept mode grabbed the device, so nothing reaches the application
	-- except through here: put the raw event back BEFORE doing anything else.
	-- Order is the whole point — an injection triggered by this event must run
	-- against an application that already shows the character. In observe mode
	-- the physical event was never consumed, and re-emitting would type it twice.
	if ev.type == EVDEV_TYPE_SYN then
		if ev.code == SYN_DROPPED then
			if _number_row.retire() ~= true then M.emergency_stop("native number-row source desynchronised"); return end
			if not _sync_dropped[source] then
				_sync_dropped[source] = true
				if _on_desync and not _call_callback(
					"input-desync callback", _on_desync) then return end
			end
		elseif ev.code == SYN_REPORT and _sync_dropped[source] then
			local synced, sync_err = _source_recovery.run({ source })
			if not synced then M.emergency_stop("evdev resynchronisation failed: " .. tostring(sync_err))
			else _sync_dropped[source] = nil; _number_row.construct() end
		end
		return
	end
	if _sync_dropped[source] or ev.type ~= EVDEV_TYPE_KEY then return end

	-- Tap-holds first: what the engine hands back is dispatched as if the user
	-- had pressed it, so the modifier state, the hotstring buffer and the
	-- virtual keyboard all see one consistent stream.
	local owned_key = source_key(source, ev.code)
	if not ev.remapped then
		if ev.value == InputEvent.VALUE_DOWN and not _physical_down[owned_key] then
			_physical_down[owned_key] = { source = source, code = ev.code, origin = _event_receipts[ev] }
		elseif ev.value == InputEvent.VALUE_UP then _physical_down[owned_key] = nil end
	end
	if _remap_orphans[owned_key] and not ev.remapped then
		if ev.value == InputEvent.VALUE_UP then _remap_orphans[owned_key] = nil end
		return
	end
	if _remapper and _intercept and not ev.remapped then
		if _armed_input then
			local armed = _armed_input
			if _input_ports.input_owner_state(armed.issuer) == nil and not armed.consumed then _armed_input = nil
			elseif source ~= armed.source or not _input_guard_current(armed) then
				_withdraw_input_arm(armed)
				if not _running then return end
			end
		end
		local at_ms = _event_time_ms(ev)
		-- A hold due before this event goes down before it.
		_tick_remapper(at_ms)
		if not _running then return end
		-- A callback of that hold may have taken the engine out: the event is
		-- then the hand's, as with no engine.
		local out, tap, binding, frame = nil, nil, nil, nil
		local original_engine, original_generation, original_output = _remapper, _remapper_generation, _broker
		local origin = _event_receipts[ev]
		local origin_view = origin and _input_exports_current() and _input_reader_ports.event_view(origin) or nil
		local custody = {}
		if _remapper then
			local receipt = _remapper.has_combinations and _combination_source(source) or nil
			local previous_buffer = _buffer_dispatch
			_buffer_dispatch = {engine=_remapper,event=ev,source=source,origin=origin,at_ms=at_ms}
			local process_started = Perf.clock()
			local called,rows,requested,selected,owned_frame = pcall(_remapper.process,_remapper,ev.code,ev.value,at_ms,receipt)
			Perf.span("taphold.process", process_started)
			Perf.count("taphold.processed")
			_buffer_dispatch = previous_buffer
			if not called then error(rows,0) end
			out,tap,binding,frame=rows,requested,selected,owned_frame
			if _remapper.take_custody then custody = _remapper:take_custody() end
		end
		local consuming = _armed_input
		if consuming and _input_ports.input_owner_state(consuming.issuer) == "consumed" then consuming.consumed = true end
		if _armed_input and (_remapper ~= original_engine or _remapper_generation ~= original_generation
			or _broker ~= original_output or not _input_guard_current(_armed_input)) then
			_withdraw_input_arm(_armed_input)
			return
		end
		if ev.value == InputEvent.VALUE_UP then
			_remap_owned[owned_key] = nil
			_remap_source_of[ev.code] = nil
		elseif ev.value == InputEvent.VALUE_DOWN then
			local passed = false
			for _, row in ipairs(custody) do if row.physical then passed = true end end
			if out and not passed then _remap_owned[owned_key] = true end
			_remap_source_of[ev.code] = source
		end
		for _, row in ipairs(custody) do
			_dispatch_event({ type = EVDEV_TYPE_KEY, code = row.code, value = row.value,
				remapped = true, original_owner = row.physical == true, holder = row.holder }, source)
		end
		if out then
			if frame and frame.owned then
				local exact = _remapper
				local buffered = frame.buffered and original_input_hook_ports.buffered_input_view(frame.buffered) or nil
				if frame.buffered and not buffered then M.emergency_stop("buffered input source refused"); return end
				local delivery_source = buffered and buffered.source or source
				local accepted = _deliver_owned_rows(exact, out, delivery_source, frame)
				if frame.ack(accepted) ~= true then
					if frame.buffered and (_broker.has_debt() or _broker.output_retired()==true) then _retired_input_context=_buffered_record(frame.buffered) end
					if _armed_input then M.emergency_stop("owned input delivery acknowledgement refused") end
					return
				end
				for _,token in ipairs(frame.orphans or {}) do
					if original_input_hook_ports.retire_buffered_input(token,exact) ~= true then return end
				end
				if buffered then
					if frame.admit(_combination_source(delivery_source)) ~= true then
						M.emergency_stop("buffered input terminal source refused"); return
					end
					_run_owned_tap_frame(frame,tap,binding,exact,original_generation,buffered.origin,buffered.origin_view,delivery_source,buffered.at_ms)
				end
				if frame.replay then
					_remap_owned[owned_key] = nil
					_dispatch_event(ev, source)
					return
				end
				if not buffered then _run_owned_tap_frame(frame, tap, binding, exact, original_generation, origin, origin_view, source, at_ms) end
				local restored, restore_frame = frame.restore(_combination_source(delivery_source))
				if restore_frame then
					local restored_ack = _deliver_owned_rows(exact, restored, delivery_source)
					restore_frame.ack(restored_ack)
				end
				return
			end
			local exact = _remapper
			local delivery = exact and exact.begin_delivery and exact:begin_delivery(out) or nil
			if exact and exact.begin_delivery and not delivery then return end
			local input_batch = _armed_input and { engine = exact, generation = original_generation,
				source = source, rows = out, snapshots = {}, next_index = 1, unwound = false } or nil
			if input_batch then
				for index, row in ipairs(out) do input_batch.snapshots[index] = { row = row, code = row.code,
					value = row.value, holder = row.holder or exact:output_holder(row) } end
				_armed_input.delivery_batch = input_batch
			end
			for index, remapped in ipairs(out) do
				if _armed_input and (_remapper ~= exact or _remapper_generation ~= original_generation
					or _broker ~= original_output or remapped.value ~= InputEvent.VALUE_UP and not _input_guard_current(_armed_input)) then
					if delivery then
						local unwound = exact:end_delivery(delivery)
						if input_batch then input_batch.unwound = unwound == true end
					end
					_withdraw_input_arm(_armed_input); return
				end
				local emitted_event = { type = EVDEV_TYPE_KEY, code = remapped.code, value = remapped.value,
					remapped = true, original_owner = remapped.physical == true,
					holder = remapped.holder or (exact.output_holder and exact:output_holder(remapped)), handoff = remapped.handoff }
				local emitted_source = remapped.physical and (_remap_source_of[remapped.code] or source) or source
				_dispatch_event(emitted_event, emitted_source)
				if input_batch then input_batch.next_index = index + 1 end
				if _armed_input and not _input_guard_current(_armed_input) then
					if delivery then
						local unwound = exact:end_delivery(delivery)
						if input_batch then input_batch.unwound = unwound == true end
					end
					_withdraw_input_arm(_armed_input); return
				end
				if not _running then
					if delivery then exact:end_delivery(delivery) end
					return
				end
			end
			if delivery and exact:end_delivery(delivery) ~= true then return end
			if consuming and _armed_input == consuming and _input_ports.input_owner_state(consuming.issuer) == nil then
				_armed_input = nil
			end
			if tap and _on_tap then _call_callback("tap action callback", _on_tap, tap, binding) end
			return
		end
	end

	return _dispatch_post_remap(ev, source)
end




--- Releases every key the tap-hold engine holds (a hold modifier, a layer
--- chord, a one-shot Shift) through the normal path, so the virtual keyboard
--- and the modifier state both see the key-ups.
_dispatch_owned_rows = function(rows, source, exact, frame)
	if #rows == 0 then return true end
	if not _running or not _intercept or type(_emit_raw) ~= "function" then return false end
	local generation, output, armed = _remapper_generation, _broker, _armed_input
	local function buffered_current()
		if not frame or not frame.buffered then return true end
		if original_input_hook_ports.buffered_input_current(frame.buffered,false) ~= true or frame.delivery_current() ~= true then return false end
		return _remapper == exact and _remapper_generation == generation and _broker == output
	end
	for _, row in ipairs(rows) do
		if not buffered_current() then return false end
		if armed and (_remapper ~= exact or _remapper_generation ~= generation or _broker ~= output
			or row.value ~= InputEvent.VALUE_UP and not _input_guard_current(armed)) then
			_withdraw_input_arm(armed); return false
		end
		local prior = _owned_row_receipt
		local receipt = { code = row.code, value = row.value, count = 0, accepted = false }
		_owned_row_receipt = receipt
		local dispatched = pcall(_dispatch_event, { type = EVDEV_TYPE_KEY, code = row.code, value = row.value, remapped = true,
			holder = row.holder or (exact.output_holder and exact:output_holder(row)), handoff = row.handoff, original_owner = row.physical == true }, source)
		_owned_row_receipt = prior
		if not dispatched then return false end
		if receipt.count ~= 1 or receipt.accepted ~= true or not buffered_current() then return false end
		if armed and (_remapper ~= exact or _remapper_generation ~= generation or _broker ~= output
			or not _input_guard_current(armed)) then _withdraw_input_arm(armed); return false end
	end
	return true
end

_deliver_owned_rows = function(exact, rows, source, frame)
	local token = exact:begin_delivery(rows)
	if not token then return false end
	local accepted = _dispatch_owned_rows(rows, source, exact, frame)
	if exact:end_delivery(token) ~= true then return false end
	return accepted
end

-- A batch retains its producer and native output owner through callbacks.
-- Withdrawal ends delivery; remaining acknowledged owners clean up through
-- the existing exact broker, never through a successor remapper generation.
local function _remapper_batch_current(exact, generation, output)
	if _remapper == exact and _remapper_generation == generation and _broker == output then return true end
	if _broker == output then
		M.emergency_stop("remapper issuer changed during output delivery")
	elseif output then
		output.retire()
	end
	return false
end

_release_remapped = function()
	if _retired_input_context then
		if not _settle_retired_input(_retired_input_context) then return false end
		_retired_input_context = nil
	end
	if not _remapper then return true end
	local exact, generation, output, running = _remapper, _remapper_generation, _broker, _running
	if exact.has_combinations then
		local rows = exact:release_all()
		if exact.take_custody then
			for _, row in ipairs(exact:take_custody()) do rows[#rows + 1] = row end
		end
		local accepted = _deliver_owned_rows(exact, rows, _device)
		return exact:ack_retirement(accepted, rows) == true
	end
	local releases = exact:release_all()
	if exact.take_custody then
		for _, row in ipairs(exact:take_custody()) do releases[#releases + 1] = row end
	end
	for _, released in ipairs(releases) do
		if not _remapper_batch_current(exact, generation, output) then return false end
		local source = _device
		for _, entry in pairs(_forwarded_down) do
			if entry.code == released.code then source = entry.source; break end
		end
		_dispatch_event({ type = EVDEV_TYPE_KEY, code = released.code, value = released.value,
			remapped = true, holder = released.holder or (exact.output_holder and exact:output_holder(released)), handoff = released.handoff }, source)
		if not _remapper_batch_current(exact, generation, output) or (running and not _running) then return false end
	end
	return true
end

--- Tells the engine the time is `now_ms` on the events' clock and dispatches
--- the holds that came due (RCtrl's one-shot Shift past its threshold), each
--- on the keyboard its key went down on.
--- @param now_ms number
_tick_remapper = function(now_ms)
	if not (_remapper and _intercept) then return end
	Perf.count("taphold.ticks")
	local exact, generation, output = _remapper, _remapper_generation, _broker
	local due_rows = exact:tick(now_ms)
	if exact.take_custody then
		for _, row in ipairs(exact:take_custody()) do due_rows[#due_rows + 1] = row end
	end
	for _, due in ipairs(due_rows) do
		if not _remapper_batch_current(exact, generation, output) then return false end
		if due.owned_rows then
			local buffered = due.frame.buffered and original_input_hook_ports.buffered_input_view(due.frame.buffered) or nil
			if due.frame.buffered and not buffered then M.emergency_stop("buffered deadline source refused"); return false end
			local source = buffered and buffered.source or _device
			if due.frame.ack(_deliver_owned_rows(exact,due.owned_rows,source,due.frame)) ~= true then
				if due.frame.buffered and (_broker.has_debt() or _broker.output_retired()==true) then _retired_input_context=_buffered_record(due.frame.buffered) end
				return false
			end
			for _,token in ipairs(due.frame.orphans or {}) do
				if original_input_hook_ports.retire_buffered_input(token,exact) ~= true then return false end
			end
			if buffered then
				if due.frame.admit(_combination_source(source)) ~= true then M.emergency_stop("buffered deadline terminal source refused"); return false end
				_run_owned_tap_frame(due.frame,due.tap,due.binding,exact,generation,buffered.origin,buffered.origin_view,source,buffered.at_ms)
			end
		elseif due.tap ~= nil then
			-- The action of a key replayed under a hold that just came due.
			if _on_tap then _call_callback("tap action callback", _on_tap, due.tap, due.binding) end
		else
			_dispatch_event({ type = EVDEV_TYPE_KEY, code = due.code, value = due.value, remapped = true, holder = due.holder or (exact.output_holder and exact:output_holder(due)), handoff = due.handoff, original_owner = due.physical == true },
				_remap_source_of[due.owner] or _device)
		end
		if not _remapper_batch_current(exact, generation, output) or not _running then return false end
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
	if ev.type == EVDEV_TYPE_KEY and ev.code >= InputEvent.POINTER_BUTTON_FIRST then
		-- A click while a tap-hold key is down makes it a chord (Shift+click),
		-- and so does the release of one, as on Windows (hook_dispatcher's
		-- _OnLUp ... _OnX2Up): a click begun before the tap ends inside it.
		-- A finger landing on a touchpad (BTN_TOUCH, BTN_TOOL_*) is neither.
		if _remapper and InputEvent.is_pointer_button(ev.code) and ev.value ~= InputEvent.VALUE_REPEAT then
			_remapper:activity()
			local at_ms=_event_clock_now_ms(); if at_ms then _tick_remapper(at_ms) end
		end
		-- The daemon hears of every press, the touch included: with tap-to-click
		-- the kernel reports a touch and no BTN_LEFT, and that touch moves the
		-- caret all the same, so the password-field verdict and the typing
		-- buffer must be dropped as on a click.
		if ev.value == InputEvent.VALUE_DOWN then
			_call_callback("pointer callback", _on_click, ev.code)
		end
	elseif ev.type == InputEvent.EV_REL and InputEvent.REL_WHEEL_AXES[ev.code] and _remapper then
		-- So does a wheel turn: Ctrl+wheel must not paste on release. Only the
		-- wheel, as on Windows and macOS: every EV_REL used to count, so a hand
		-- that merely moved the mouse while tapping CapsLock typed no Enter.
		_remapper:activity()
		local at_ms=_event_clock_now_ms(); if at_ms then _tick_remapper(at_ms) end
	end
	if _on_pointer_event then
		-- The value and the frame's SYN_REPORT let the metrics measure a movement.
		if ev.type == InputEvent.EV_REL then
			_call_callback("pointer event callback", _on_pointer_event, "motion", ev.code, ev.value)
		elseif ev.type == EVDEV_TYPE_KEY and ev.value == InputEvent.VALUE_DOWN then
			_call_callback("pointer event callback", _on_pointer_event, "press", ev.code, ev.value)
		elseif ev.type == InputEvent.EV_SYN and ev.code == InputEvent.SYN_REPORT then
			_call_callback("pointer event callback", _on_pointer_event, "frame", ev.code, ev.value)
		end
	end
end

local function _read_source(source)
	local event, status, reason = EvdevReader.read_event(source.slot)
	if event and EvdevReader.capture_event then
		_event_receipts[event] = EvdevReader.capture_event(event, source.slot)
	end
	if status ~= "fatal" then return event end
	Logger.error(LOG, "Fatal evdev read on %s — %s; scheduling re-acquisition.",
		source.path, tostring(reason))
	_pending_events[source.slot] = nil
	if source.keyboard then
		if _source_recovery.retire_remaps({ source.path }) ~= true then
			M.emergency_stop("could not retire the failed source remapper")
			return nil
		end
		local released, release_err = _release_forwarded_sources({ source.path })
		if not released then
			M.emergency_stop("could not release keys from failed source: " .. tostring(release_err))
			return nil
		end
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

--- Reads the next event of every source that has none pending.
--- @param sources table The pump's sources.
local function _read_empty_sources(sources)
	for _, source in ipairs(sources) do
		if not _pending_events[source.slot] then
			_pending_events[source.slot] = _read_source(source)
		end
	end
end

--- The source whose pending event comes first, nil when none has one.
--- @param sources table The pump's sources.
--- @return table|nil source
local function _earliest_pending(sources)
	local selected = nil
	for _, source in ipairs(sources) do
		local event = _pending_events[source.slot]
		if event and (not selected or _event_precedes(
			event, source, _pending_events[selected.slot], selected))
		then
			selected = source
		end
	end
	return selected
end

--- Drains ready events in global kernel-timestamp order and returns.
---
--- Called from the daemon's idle callback. Nothing here blocks: the descriptor is
--- O_NONBLOCK and the merge is globally bounded, so the tray, periodic tick and
--- file watchers advance even under an autorepeat backlog.
function M.pump()
	if not _running then return end
	if _source_reconciliation then return end
	Perf.count("input.pump_calls")
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
		_number_row.retire()
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

	_number_row.drive() -- Same original pump/queue; no additional reader/timer.
	_read_empty_sources(sources)
	local drained = false
	for _ = 1, EvdevReader.MAX_EVENTS_PER_DRAIN do
		local selected = _earliest_pending(sources)
		if not selected then
			-- A source is read again only once its event is dispatched: one
			-- empty at the start of the drain is read once more before the
			-- queues count as empty.
			_read_empty_sources(sources)
			selected = _earliest_pending(sources)
			if not selected then
				drained = true
				break
			end
		end
		local selected_event = _pending_events[selected.slot]
		_pending_events[selected.slot] = nil
		Perf.count("input.events")
		if selected.keyboard then
			local dispatch_started = Perf.clock()
			Perf.count("input.key_events")
			_dispatch_event(selected_event, selected.path)
			Perf.span("input.dispatch", dispatch_started)
		else
			Perf.count("input.pointer_events")
			-- The pointer is not grabbed: its events reached the desktop when
			-- they happened, and only keep the events' clock fresh here.
			if _remapper and _intercept then _event_time_ms(selected_event) end
			_dispatch_pointer(selected_event)
		end
		_pending_events[selected.slot] = _read_source(selected)
	end

	-- Time passes with no event: a hold that came due since the last one goes
	-- down now. Only once every event read is dispatched, each after the holds
	-- due at its own stamp: before them, a key stamped within the threshold
	-- and read after it came out under the hold.
	if drained and _running then
		local now_ms = _event_clock_now_ms()
		if now_ms then _tick_remapper(now_ms) end
	end
end

--- Sleeps the idle loop until an input source has data, at most `timeout_ms`.
---
--- The daemon's event loop calls it between pumps, so an idle daemon wakes on
--- input or on the timeout instead of spinning, and a key is pumped the moment
--- it arrives. An event already read and not yet dispatched (a drain that hit
--- its bound) must not sleep behind the wait, so it answers at once.
--- @param timeout_ms integer Longest wait.
--- @return boolean|nil ready True when a source can be read now, false after a
---   quiet wait, nil when no wait is possible (hook stopped or reacquiring,
---   no open source): the loop then yields a fixed millisecond.
function M.idle_wait(timeout_ms)
	if not _running or _reacquiring or _source_reconciliation then return nil end
	if next(_pending_events) ~= nil then return true end
	return EvdevReader.wait_any_readable(timeout_ms)
end

--- The text a key would type now, in the live layout and with the modifiers
--- held now, without pressing it; nil for a key that types none. A key under
--- Ctrl, Alt or Super is a shortcut, not text, whatever its level would type.
--- The tap-hold engine's one-shot Shift asks it, as the Windows InputHook
--- collects only keys that type text.
--- @param code integer evdev keycode.
--- @return string|nil text, string|nil error Why the layout could not answer.
function M.key_text(code)
	if _shortcut_modifier_held() then return nil end
	local text, err
	if _test_capture_event then
		-- Under a capture double (tests) the double is the layout: it answers
		-- as it would for the press.
		text, _, err = _test_capture_event(code, InputEvent.VALUE_DOWN)
	else
		text, err = XkbCapture.peek_text(code)
	end
	if err then return nil, err end
	local first = type(text) == "string" and text:byte(1) or nil
	if not first or first < 32 or first == 127 then return nil end
	return text
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
	local held, seen = {}, {}
	for _, entry in ipairs(_modifier_order) do
		local role = _modifier_down[entry.key]
		if role == "shift" or role == "altgr" then
			if not seen[entry.code] then held[#held + 1] = entry.code; seen[entry.code] = true end
		end
	end
	return held
end

--- The side of the one Shift held, for a chord that tells the two apart: the
--- prediction tooltip's Shift+Tab steps back with the left Shift and forward
--- with the right one. Nil when no Shift, both, or a key only remapped to Shift
--- is held, since none of those names a side.
--- @return string|nil "left" or "right".
function M.held_shift_side()
	local left, right, other = false, false, false
	for _, entry in ipairs(_modifier_order) do
		if _modifier_down[entry.key] == "shift" then
			if entry.code == EvdevCodes.KEY_LEFTSHIFT then
				left = true
			elseif entry.code == EvdevCodes.KEY_RIGHTSHIFT then
				right = true
			else
				other = true
			end
		end
	end
	if other or left == right then return nil end
	return left and "left" or "right"
end

--- Shortcut modifiers (Ctrl, Alt, Super) the user is holding, in press order.
---
--- Text never needs them, and typed while one is held each character becomes a
--- shortcut: accepting a prediction with Alt+1 typed it as Alt+q, Alt+u, …
--- @return table Ordered evdev keycodes.
function M.held_shortcut_modifier_codes()
	local held, seen = {}, {}
	for _, entry in ipairs(_modifier_order) do
		local role = _modifier_down[entry.key]
		if role == "ctrl" or role == "alt" or role == "meta" then
			if not seen[entry.code] then held[#held + 1] = entry.code; seen[entry.code] = true end
		end
	end
	return held
end

--- Non-modifier keys this daemon has forwarded as pressed and not yet released.
---
--- An expansion fires on the terminator's key-DOWN, which has already been
--- forwarded, so during the injection that key is still pressed on the virtual
--- keyboard. The kernel drops a key-down for a key that is already down: the
--- replayed terminator (the space after "adn ") vanished, and every end-char
--- expansion glued the next word onto the replacement. Measured through a real
--- kernel by tests/hardware/run_daemon_live.lua.
--- @return table Sorted evdev keycodes.
function M.held_forwarded_keys()
	local codes, seen = {}, {}
	for _, entry in pairs(_forwarded_down) do
		if not _modifier_down[source_key(entry.source, entry.code)] and not seen[entry.code] then
			seen[entry.code] = true
			codes[#codes + 1] = entry.code
		end
	end
	table.sort(codes)
	return codes
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

--- Whether CapsLock is locked, from the LED of the first open keyboard: the
--- daemon forwards CapsLock and keeps no lock state of its own.
--- @return boolean|nil locked Nil when no keyboard is open or the query failed.
--- @return string|nil error Why the state is unknown.
function M.caps_lock_on()
	for _, path in ipairs(_devices) do
		local slot = keyboard_slot(path)
		if EvdevReader.is_open(slot) then
			local leds, err = EvdevReader.active_leds(slot, LED_CAPSL)
			if not leds then return nil, tostring(err) end
			return leds[LED_CAPSL] == true
		end
	end
	return nil, "no keyboard is open"
end

--- Locks CapsLock for a CapsWord session, as Windows and macOS light it for
--- theirs: the letters then reach the application as the layout's CapsLock
--- level types them (capitals; Ergopti keeps its digits and punctuation).
--- A CapsLock the user already locked is ridden, never toggled, and stays on
--- after the session. The hold ends with release_caps_word_lock(), or with
--- `on_lost(reason)` when the hook ends it: a CapsLock pressed, the hook
--- stopped, the keyboard handed to a dialog.
--- @param emit function() -> boolean, table|nil Presses and releases KEY_CAPSLOCK
---   on the daemon's device; retains ComboEmitter's typed pre-output refusal.
--- @param on_lost function(reason) Told once when the hook ends the hold.
--- @return boolean ok
--- @return string|nil reason Why the lock was refused.
function M.lock_caps_for_word(emit, on_lost)
	if type(emit) ~= "function" or type(on_lost) ~= "function" then
		error("lock_caps_for_word needs an emitter and a loss callback", 2)
	end
	if _locks.word then return false, "a CapsWord session already holds CapsLock" end
	if not _running then return false, "the keyboard is not captured" end
	if XkbCapture.caps_locked() then
		_locks.word = { emit = emit, on_lost = on_lost, owned = false }
		return true
	end
	-- Reserve ownership before calling output: a failed native press may have
	-- toggled the desktop even when its release could not be acknowledged.
	local word = { emit = emit, on_lost = on_lost, owned = true, releasing = true }
	_locks.word = word
	local ok, reason, unchanged = _locks.toggle_word(emit, true)
	word.releasing = false
	if not ok then
		if unchanged then _locks.word = nil else word.retryable = false end
		return false, reason
	end
	return true
end

--- Ends a CapsWord session's hold on CapsLock, unlocking it when the session
--- locked it. A no-op when the hook already ended the hold.
--- @return boolean ok False when the unlock could not be emitted (logged).
function M.release_caps_word_lock()
	return _locks.end_word(true, nil)
end

--- Whether a CapsWord session owns a lock or unsettled CapsLock output.
--- @return boolean
function M.caps_word_lock_held()
	return _locks.word ~= nil
end

--- Rechecks the existing capture owner's kernel origin without a new watcher.
--- @return table receipt Physical-source generation and admission.
function M.physical_source_receipt()
	local ok, Finder = pcall(require, "modules.hotstrings.device_finder")
	local sources = ok and type(Finder.physical_sources) == "function" and Finder.physical_sources(_devices) or {}
	local ready = _running and _intercept and #_devices > 0 and #sources == #_devices
	local signature, physical = { tostring(ready) }, {}
	for _, source in ipairs(sources) do
		physical[source.path] = source.physical == true
		ready = ready and source.physical == true
		for _, value in ipairs({ source.path, source.sysfs, source.name, tostring(source.physical) }) do
			signature[#signature + 1] = #value .. ":" .. value
		end
	end
	local encoded = table.concat(signature, ";")
	if _origin_signature ~= encoded then _origin_signature, _origin_generation = encoded, _origin_generation + 1 end
	_physical_sources = physical
	_origin_ready = ready == true
	return { generation = _origin_generation, ready = ready == true }
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

local function _close_paths(paths, slot_for, tx)
	for _, path in ipairs(paths) do
		local slot = slot_for(path)
		if tx and tx.authority then
			local lease = tx.close_owners[slot]
			if lease then _input_reader_ports.retire_source(lease) end
		elseif _leased_reader_cleanup then
			local lease = _leased_reader_cleanup[slot]
			if lease then _input_reader_ports.retire_source(lease) end
		elseif _buffered_reader_cleanup then
			local lease=_buffered_reader_cleanup[slot]
			if lease then _input_reader_ports.retire_source(lease) end
		else EvdevReader.close(slot) end
		_pending_events[slot] = nil
	end
end

--- Releases virtual keys whose last physical owner is leaving the source set.
--- Multiple keyboards can hold the same evdev code at once, but uinput exposes
--- only one state bit for that code. A departing source therefore emits key-up
--- only when no retained source still owns the same forwarded code.
--- @param paths table Keyboard source paths being retired.
--- @return boolean released
--- @return string|nil detail
_release_forwarded_sources = function(paths)
	if _number_row.retire() ~= true then return false, "native number-row cleanup pending" end
	local retiring = {}
	for _, path in ipairs(paths) do retiring[path] = true end
	local entries = {}
	for key, entry in pairs(_forwarded_down) do
		if retiring[entry.source] then entries[#entries + 1] = { key = key, entry = entry } end
	end
	table.sort(entries, function(left, right) return left.key < right.key end)
	for _, row in ipairs(entries) do
		local entry = row.entry
		if not _forward_raw({ type = EVDEV_TYPE_KEY, code = entry.code, value = InputEvent.VALUE_UP,
			original_source = entry.source }, entry.owner_source or entry.source) then return false, "owned source retirement refused" end
		local role = _modifier_down[row.key]
		_track_modifier(entry.owner_source or entry.source, entry.code, InputEvent.VALUE_UP)
		local retained = false
		for _, current in ipairs(_modifier_order) do if current.code == entry.code then retained = true end end
		if role and not retained then _capture(entry.code, InputEvent.VALUE_UP) end
	end
	-- Reconciliation may already have dropped an orphan's physical record.
	-- Its encoded source still owns that old suppressed press, not a later
	-- descriptor that happens to reuse the same path.
	for key in pairs(_remap_orphans) do
		if retiring[key:match("^(.*):%d+$")] then _remap_orphans[key] = nil end
	end
	for key, entry in pairs(_physical_down) do
		if retiring[entry.source] then
			_physical_down[key], _consumed_down[key], _pressed_at[key] = nil, nil, nil
			_hold_owners[key] = nil
		end
	end
	return true
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

--- Retains only source leases issued by the construction-captured Reader.
--- @param tx table Original source transaction.
--- @param path string Intended device path.
--- @param slot_for function Keyboard or pointer namespace.
--- @param keyboard boolean Whether input admission requires the native grab.
--- @return boolean accepted
local function _capture_source_member(tx, path, slot_for, keyboard)
	if not tx.authority then tx.native_complete = false; return not tx.managed end
	local exports_current = _input_exports_current()
	local slot = slot_for(path)
	local lease, observer = _input_reader_ports.capture_source_owner(slot)
	-- This retained getter is the genuine constructor, even after a public
	-- export changes. Its opaque originals remain safe cleanup targets only.
	if lease then
		tx.cleanup[#tx.cleanup + 1] = lease
		tx.close_owners[slot], tx.close_observers[slot] = lease, observer
	end
	if not exports_current then tx.native_complete = false; return not tx.managed end
	local input, cleanup = _input_reader_ports.source_owner_current(lease, observer,
		_input_reader_ports.capture_source_owner, _input_reader_ports.source_owner_current, _input_reader_ports.retire_source)
	if cleanup ~= true or not _input_exports_current() then
		tx.native_complete = false
		return not tx.managed
	end
	local is_keyboard = slot_for == keyboard_slot
	local owners, observers = is_keyboard and tx.sources or tx.pointers, is_keyboard and tx.source_observers or tx.pointer_observers
	owners[slot], observers[slot] = lease, observer
	if keyboard and _intercept and input ~= true then tx.native_complete = false; return not tx.managed end
	return true
end

--- Captures the exact session and output owner before any watchdog callback.
--- @return table tx
local function _begin_source_transaction()
	local tx = { session = _capture_session, options = _capture_options, publisher = _capture_republisher,
		managed = _capture_republisher ~= nil, authority = original_reader_load,
		engine = _remapper, generation = _remapper_generation, issuer = _remapper_input_owner,
		broker = _broker, emitter = _emit_raw, callback = _on_tap, output = _input_output_owner,
		sources = {}, source_observers = {}, pointers = {}, pointer_observers = {}, cleanup = {},
		close_owners = {}, close_observers = {}, native_complete = true,
		emergency = original_input_hook_ports.emergency_stop }
	if tx.engine then tx.release = rawget(tx.engine, "release_all"); tx.ack = rawget(tx.engine, "ack_retirement") end
	if tx.broker then
		tx.output_ports = {}
		for _, name in ipairs({ "view", "has_debt", "output_current", "output_retired", "retire" }) do
			tx.output_ports[name] = rawget(tx.broker, name)
		end
	end
	_source_reconciliation = tx
	local function remember(paths, slot_for, owners, observers, keyboard)
		for _, path in ipairs(paths) do
			local slot = slot_for(path)
			local lease, observer = owners and owners[slot], observers and observers[slot]
			if tx.authority and lease then
				tx.cleanup[#tx.cleanup + 1] = lease
				tx.close_owners[slot], tx.close_observers[slot] = lease, observer
				local input, cleanup = _input_reader_ports.source_owner_current(lease, observer,
					_input_reader_ports.capture_source_owner, _input_reader_ports.source_owner_current, _input_reader_ports.retire_source)
				if cleanup == true then
					local staged, staged_observers = keyboard and tx.sources or tx.pointers,
						keyboard and tx.source_observers or tx.pointer_observers
					staged[slot], staged_observers[slot] = lease, observer
					if keyboard and _intercept and input ~= true then tx.native_complete = false end
				else tx.native_complete = false end
			else tx.native_complete = false end
		end
	end
	remember(_devices, keyboard_slot, _input_source_owners, _input_source_observers, true)
	remember(_pointer_devices, pointer_slot, _input_pointer_owners, _input_pointer_observers, false)
	tx.original_sources, tx.original_source_observers = tx.sources, tx.source_observers
	tx.original_pointers, tx.original_pointer_observers = tx.pointers, tx.pointer_observers
	return tx
end

--- Joins retained identities only; callback-bearing output observation stays separate.
--- @param tx table Original source transaction.
--- @return boolean current
local function _source_transaction_current(tx)
	if _source_reconciliation ~= tx or _capture_session ~= tx.session or _capture_options ~= tx.options
		or _capture_republisher ~= tx.publisher or not tx.options
		or rawget(tx.options, "onCaptureReacquired") ~= tx.publisher
		or package.loaded["adapters.keyboard_hook"] ~= M or _remapper ~= tx.engine
		or _remapper_generation ~= tx.generation or _remapper_input_owner ~= tx.issuer
		or _broker ~= tx.broker or _emit_raw ~= tx.emitter or _on_tap ~= tx.callback
		or tx.managed and (not tx.authority or not _input_exports_current()) then return false end
	for _, name in ipairs(INPUT_HOOK_PORT_NAMES) do
		if rawget(M, name) ~= original_input_hook_ports[name] then return false end
	end
	if tx.output then
		if _input_output_owner ~= tx.output or package.loaded["adapters.uinput_writer"] ~= tx.output.writer
			or package.loaded["adapters.modifier_broker"] ~= ModifierBroker
			or rawget(ModifierBroker, "for_channel") ~= installed_output_broker then return false end
		local exact, binding = installed_output_broker(tx.output.writer)
		if exact ~= tx.broker or binding ~= tx.output.binding or binding(tx.broker) ~= true then return false end
		for _, name in ipairs(INPUT_OUTPUT_PORT_NAMES) do
			if rawget(tx.output.writer, name) ~= tx.output.ports[name] then return false end
		end
	end
	for name, port in pairs(tx.output_ports or {}) do
		if rawget(tx.broker, name) ~= port then return false end
	end
	return true
end

--- Retires the shared engine only when a departing source owns consumed input.
--- A retained physical press stays swallowed until UP rather than becoming a tap
--- or replaying its remapped DOWN after the engine's state was retired.
--- @param paths table Departing keyboard paths.
--- @return boolean retired
function _source_recovery.retire_remaps(paths)
	if not _remapper then return true end
	local departing, needed = {}, false
	for _, path in ipairs(paths) do departing[path] = true end
	for key in pairs(_remap_owned) do
		local physical = _physical_down[key]
		if physical and departing[physical.source] then needed = true; break end
	end
	if not needed then return true end
	local exact, generation, output, session, issuer = _remapper, _remapper_generation, _broker, _capture_session, _remapper_input_owner
	local tx, owned = _source_reconciliation, _remap_owned
	local function current()
		return _remapper == exact and _remapper_generation == generation and _broker == output
			and _capture_session == session and _remapper_input_owner == issuer
			and (not tx or _source_transaction_current(tx))
	end
	if not current() or _release_remapped() ~= true or not current() then return false end
	if exact.activate and exact:activate() ~= true then return false end
	if not current() then return false end
	local replacement = _input_ports.capture_input_owner(exact)
	if exact.has_combinations and (not replacement or not _input_ports.input_owner_current(replacement)) then return false end
	if not current() then return false end
	for key in pairs(owned) do
		local physical = _physical_down[key]
		if physical and not departing[physical.source] then _remap_orphans[key] = true end
	end
	_remap_owned, _remap_source_of = {}, {}
	_remapper_input_owner = replacement
	if tx then tx.issuer = replacement end
	return true
end

--- Refuses a previously captured native slot that a callback has replaced.
--- @param tx table Original transaction.
--- @param slot string Already-open slot.
--- @return boolean owned
local function _source_existing_current(tx, slot)
	if not tx.authority then return not tx.managed end
	local lease, observer = tx.close_owners[slot], tx.close_observers[slot]
	if not lease then tx.native_complete = false; return not tx.managed end
	local _, cleanup = _input_reader_ports.source_owner_current(lease, observer,
		_input_reader_ports.capture_source_owner, _input_reader_ports.source_owner_current, _input_reader_ports.retire_source)
	if cleanup ~= true then
		tx.native_complete = false
		-- Explicit unmanaged raw input keeps compatibility after an authority-port
		-- substitution, but cannot adopt a genuine foreign native lifetime.
		return not tx.managed and not _input_exports_current()
	end
	return _source_transaction_current(tx)
end

--- Rejoins original lifetimes before the first intentional source mutation.
--- @param tx table Original transaction.
--- @return boolean current
local function _source_original_cohort_current(tx)
	if not _source_transaction_current(tx) then return false end
	for _, pair in ipairs({ { tx.original_sources, tx.original_source_observers },
		{ tx.original_pointers, tx.original_pointer_observers } }) do
		for slot, lease in pairs(pair[1]) do
			local _, cleanup = _input_reader_ports.source_owner_current(lease, pair[2][slot],
				_input_reader_ports.capture_source_owner, _input_reader_ports.source_owner_current, _input_reader_ports.retire_source)
			if cleanup ~= true then return false end
		end
	end
	return _source_transaction_current(tx)
end

--- Observes existing source lifetimes without inventing an event or an input lease.
--- @param tx table Original source transaction.
--- @return boolean current
local function _source_cohort_current(tx)
	if not _source_transaction_current(tx) then return false end
	if not tx.native_complete then return not tx.managed end
	for _, pair in ipairs({ { tx.sources, tx.source_observers, true }, { tx.pointers, tx.pointer_observers, false } }) do
		for slot, lease in pairs(pair[1]) do
			local input, cleanup = _input_reader_ports.source_owner_current(lease, pair[2][slot],
				_input_reader_ports.capture_source_owner, _input_reader_ports.source_owner_current, _input_reader_ports.retire_source)
			if cleanup ~= true or pair[3] and _intercept and input ~= true then return false end
		end
	end
	return _source_transaction_current(tx)
end

--- Retires only captured originals; reopened descriptors and channels stay untouched.
--- @param tx table Original source transaction.
--- @param reason string Closed admission reason.
--- @return boolean settled
local function _retire_source_transaction(tx, reason)
	local settled = true
	if tx.authority then
		for _, lease in ipairs(tx.cleanup) do
			local called, acknowledged = pcall(_input_reader_ports.retire_source, lease)
			settled = called and acknowledged == true and settled
		end
		if tx.output and tx.output_ports and type(tx.output_ports.retire) == "function" then
			local called, acknowledged = pcall(tx.output_ports.retire)
			settled = called and acknowledged == true and settled
			if type(tx.output_ports.output_retired) == "function" and type(tx.release) == "function" then
				local observed, terminal = pcall(tx.output_ports.output_retired)
				if observed and terminal == true then
					local released, rows = pcall(tx.release, tx.engine)
					if released and type(rows) == "table" and type(tx.ack) == "function" then
						local called_ack, acknowledged_ack = pcall(tx.ack, tx.engine, true, rows)
						settled = called_ack and acknowledged_ack == true and settled
					end
				end
			end
		end
		if _capture_session == tx.session then
			_running, _reacquiring, _capture_session = false, false, nil
			_devices, _pointer_devices, _device = {}, {}, nil
			_armed_input, _live_input_context = nil, nil
			_origin_ready = false
		end
	elseif _source_transaction_current(tx) and type(tx.emergency) == "function" then
		-- Existing unmanaged recorder backends have no native source lease. They
		-- keep their original raw-input cleanup contract, never logical admission.
		pcall(tx.emergency, reason)
	end
	return settled
end

--- Publishes whole replacement maps only after every native and caller callback.
--- @param tx table Original source transaction.
--- @return boolean accepted
local function _publish_source_transaction(tx)
	if not _source_cohort_current(tx) then return false end
	if tx.managed and _intercept then
		if not tx.output or type(tx.output_ports.output_current) ~= "function" then return false end
		local called, current = pcall(tx.output_ports.output_current)
		if not called or current ~= true or not _source_cohort_current(tx) then return false end
	end
	if tx.changed == false then return true end
	if tx.native_complete and tx.authority then
		_input_source_owners, _input_source_observers = tx.sources, tx.source_observers
		_input_pointer_owners, _input_pointer_observers = tx.pointers, tx.pointer_observers
		-- Successful original Hook publication replaces its exact cleanup cohort.
		-- A foreign slot replacement without this transaction remains unowned.
		if _buffered_reader_cleanup then
			local cleanup={}
			for slot,lease in pairs(tx.sources) do cleanup[slot]=lease end
			for slot,lease in pairs(tx.pointers) do cleanup[slot]=lease end
			_buffered_reader_cleanup=cleanup
		end
	else
		_input_source_owners, _input_source_observers, _input_pointer_owners, _input_pointer_observers = nil, nil, nil, nil
	end
	return true
end


--- Opens and, when asked, grabs every desired keyboard as one transaction.
--- Existing desired sources remain live while new ones are staged. A failed new
--- source is rolled back, so hotplug cannot silently publish a partial set.
--- @param paths table Device paths.
--- @param force_path string|nil A same-path reconnect whose stale fd must close.
--- @return boolean True when the complete desired set is live.
local function _acquire(paths, force_path, tx)
	local retained = {}
	for _, path in ipairs(_devices) do retained[path] = true end
	local opened = {}
	for _, path in ipairs(paths) do
		local slot = keyboard_slot(path)
		if path == force_path then
			if _source_recovery.retire_remaps({ path }) ~= true then return false, "reconnected source remapper retirement refused" end
			local released, release_err = _release_forwarded_sources({ path })
			if not released then return false, release_err end
			_close_paths({ path }, keyboard_slot, tx)
		end
		local already_open = EvdevReader.is_open(slot)
		if already_open and tx and not _source_existing_current(tx, slot) then return false, "original open source was replaced" end
		if not already_open then
			if not EvdevReader.open(path, slot) then
				_close_paths(opened, keyboard_slot, tx)
				return false
			end
			opened[#opened + 1] = path
			if tx and not _capture_source_member(tx, path, keyboard_slot, false) then
				return false, "original source cleanup authority refused"
			end
			if _intercept then
				-- Discovery is a pathname snapshot. Only the opened fd identifies
				-- the complete stream this grab would take from the desktop.
				local query = _input_reader_ports.event_capabilities
				local finder = package.loaded["modules.hotstrings.device_finder"]
				local policy = type(finder) == "table" and rawget(finder, "is_interceptable_event_mask")
				local called, mask = false, nil
				if type(query) == "function" and rawget(EvdevReader, "event_capabilities") == query then
					called, mask = pcall(query, slot)
				end
				local checked, allowed = false, false
				if called and mask ~= nil and type(policy) == "function" then checked, allowed = pcall(policy, mask) end
				if not checked or allowed ~= true or rawget(EvdevReader, "event_capabilities") ~= query
					or package.loaded["modules.hotstrings.device_finder"] ~= finder
					or rawget(finder, "is_interceptable_event_mask") ~= policy
					or tx and not _source_transaction_current(tx) then
					_close_paths(opened, keyboard_slot, tx)
					return false, "opened device cannot be intercepted by the keyboard output"
				end
			end
			if _intercept and not EvdevReader.grab(slot) then
				_close_paths(opened, keyboard_slot, tx)
				return false
			end
		end
		if tx and not _capture_source_member(tx, path, keyboard_slot, true) then
			return false, "original grabbed source authority refused"
		end
		retained[path] = nil
	end
	local retired = TableUtil.sorted_keys(retained)
	if _source_recovery.retire_remaps(retired) ~= true then return false, "departed source remapper retirement refused" end
	local released, release_err = _release_forwarded_sources(retired)
	if not released then
		_close_paths(opened, keyboard_slot, tx)
		return false, release_err
	end
	_close_paths(retired, keyboard_slot, tx)
	_devices = {}
	for index, path in ipairs(paths) do _devices[index] = path end
	_device = _devices[1]
	M.physical_source_receipt()
	return true
end

--- Reconciles the non-grabbed pointer observers independently of keyboards.
--- @param paths table Device paths.
local function _acquire_pointers(paths, tx)
	local retained = {}
	for _, path in ipairs(_pointer_devices) do retained[path] = true end
	local opened = {}
	for _, path in ipairs(paths) do
		local slot = pointer_slot(path)
		local already_open = EvdevReader.is_open(slot)
		if already_open and tx and not _source_existing_current(tx, slot) then return false, "original open source was replaced" end
		if not already_open then
			if not EvdevReader.open(path, slot) then
				_close_paths(opened, pointer_slot, tx)
				Logger.warn(LOG, "Could not observe every pointer — keeping the previous set.")
				if tx then
					tx.native_complete = false
					if tx.managed then return false end
				end
				return
			end
			opened[#opened + 1] = path
		end
		if tx and not _capture_source_member(tx, path, pointer_slot, false) then
			return false
		end
		retained[path] = nil
	end
	for path in pairs(retained) do _close_paths({ path }, pointer_slot, tx) end
	_pointer_devices = {}
	for index, path in ipairs(paths) do _pointer_devices[index] = path end
	return true
end

--- Reconciles native state under one unpublished cohort, without dropping the grab.
--- Recorder-only callers retain their raw-input path but acquire no native rights.
--- @param paths table Sources whose state must be restored.
--- @param consume_held boolean|nil Whether a modal already delivered their held keys.
--- @param existing table|nil Original cohort captured before a modal released it.
--- @return boolean restored
--- @return string|nil reason
function _source_recovery.run(paths, consume_held, existing)
	if not existing and (not original_reader_load or not _input_source_owners or not _capture_session or not _intercept) then
		for _, path in ipairs(paths) do
			if consume_held then
				local held = EvdevReader.pressed_keys(keyboard_slot(path), KEY_MAX)
				for code in pairs(held or {}) do _consumed_down[source_key(path, code)] = true end
			end
			local restored, reason = _resynchronise(path)
			if not restored then return false, reason end
		end
		return true
	end
	if _source_reconciliation and _source_reconciliation ~= existing then return false, "source reconciliation is already pending" end
	local tx, selected = existing or _begin_source_transaction(), {}
	for _, path in ipairs(paths) do selected[path] = true end
	tx.changed, tx.native_complete = true, true
	tx.sources, tx.source_observers, tx.pointers, tx.pointer_observers = {}, {}, {}, {}
	local called, accepted = pcall(function()
		if not _source_transaction_current(tx) then return false end
		local slots, originals = {}, {}
		for _, path in ipairs(_devices) do
			local slot = keyboard_slot(path)
			slots[#slots + 1] = slot
			if not tx.close_owners[slot] then return false end
			originals[#originals + 1] = tx.close_owners[slot]
		end
		for _, path in ipairs(_pointer_devices) do
			if not _capture_source_member(tx, path, pointer_slot, false) then return false end
		end
		return _input_reader_ports.reconcile_sources(slots, function(snapshots)
			if not _source_transaction_current(tx) then return false end
			if #snapshots ~= #slots then return false end
			local selected_snapshot
			for index, snapshot in ipairs(snapshots) do
				if snapshot.slot ~= slots[index] or snapshot.source ~= _devices[index]
					or not snapshot.lease or type(snapshot.observer) ~= "function" then return false end
				tx.sources[snapshot.slot], tx.source_observers[snapshot.slot] = snapshot.lease, snapshot.observer
			end
			for _, snapshot in ipairs(snapshots) do
				if selected[snapshot.source] then
					selected_snapshot = selected_snapshot or snapshot
					if consume_held then
						for code in pairs(snapshot.keys) do _consumed_down[source_key(snapshot.source, code)] = true end
					end
				end
			end
			if not selected_snapshot or not _resynchronise(selected_snapshot.source, selected_snapshot, snapshots)
				or not _source_transaction_current(tx) then return false end
			-- activate() retired the remapper's old private issuer epoch too.
			if tx.engine then
				local issuer = _input_ports.capture_input_owner(tx.engine)
				if not issuer or not _input_ports.input_owner_current(issuer) or not _source_transaction_current(tx) then return false end
				_remapper_input_owner, tx.issuer = issuer, issuer
			end
			if tx.publisher then
				local published, acknowledged = pcall(tx.publisher)
				if not published or acknowledged ~= true or not _source_transaction_current(tx) then return false end
			end
			return _source_transaction_current(tx)
		end, originals) == true and _publish_source_transaction(tx)
	end)
	if not called or accepted ~= true then _retire_source_transaction(tx, "native state reconciliation refused") end
	if _source_reconciliation == tx then _source_reconciliation = nil end
	if called and accepted == true then return true end
	return false, "native state reconciliation refused"
end

--- Brackets a selected-map refresh while preserving only acknowledged output modifiers.
--- Ordinary holds, consumed-key debt and the remapper keep their existing owners.
--- @param layout string Physical family requested by the menu.
--- @param refresh function Original selected-map operation, including its label update.
--- @param selected function Checks the original map selection before and after publication.
--- @return boolean applied
function M.refresh_capture(layout, refresh, selected)
	if _source_reconciliation or not _running or type(refresh) ~= "function" or type(selected) ~= "function"
		or type(layout) ~= "string" or type(_source_recovery.inverse) ~= "function"
		or type(_source_recovery.inverse_current) ~= "function" then return false end
	local tx, previous_layout, rows, ordered = _begin_source_transaction(), _layout, {}, {}
	local inverse, inverse_current = _source_recovery.inverse, _source_recovery.inverse_current
	local old_capture
	local function current()
		return _source_cohort_current(tx) and package.loaded["adapters.xkb_capture"] == XkbCapture
			and rawget(XkbCapture, "inverse_table") == inverse and rawget(XkbCapture, "inverse_current") == inverse_current
			and (not tx.engine or _input_ports.input_owner_current(tx.issuer) == true)
	end
	local called, accepted = pcall(function()
		-- Freeze the output roster before an inverse provider or menu callback runs.
		for key, row in pairs(_forwarded_down) do
			rows[key] = { original = row, source = row.owner_source or row.source, code = row.code, owner = _output_owners[key] }
		end
		local seen = {}
		for _, row in ipairs(_modifier_order) do if rows[row.key] then ordered[#ordered + 1] = row.key; seen[row.key] = true end end
		local remaining = {}; for key in pairs(rows) do if not seen[key] then remaining[#remaining + 1] = key end end
		table.sort(remaining); for _, key in ipairs(remaining) do ordered[#ordered + 1] = key end
		local original_view = tx.broker and tx.broker.view()
		if not original_view or original_view.busy or original_view.debt or not current() then return false end
		local _, _, captured = inverse(false); old_capture = captured
		if not old_capture or not current() or inverse_current(old_capture) ~= true or selected() ~= true or not current() then return false end
		if _armed_input then
			local arm = _armed_input
			if arm.consumed or _input_ports.input_owner_state(arm.issuer) == "consumed" then
				if _withdraw_input_arm(arm) ~= true then return false end
			else
				if _input_ports.clear_input_arm(arm.issuer) ~= true then return false end
				if _armed_input == arm then _armed_input = nil end
			end
		end
		if not current() or refresh() ~= true or not current() or _layout ~= layout
			or selected() ~= true or not current() or inverse_current(old_capture) == true then return false end
		local _, _, fresh = inverse(false)
		if not fresh or not current() or inverse_current(fresh) ~= true then return false end
		local view = tx.broker and tx.broker.view()
		if not view or view.busy or view.debt or type(view.owners) ~= "table" or not current() then return false end
		for owner, output in pairs(original_view.owners) do
			local after = view.owners[owner]
			if not after or after.code ~= output.code or after.state ~= output.state then return false end
		end
		for owner in pairs(view.owners) do if not original_view.owners[owner] then return false end end
		for key, row in pairs(rows) do
			if _forwarded_down[key] ~= row.original or row.original.code ~= row.code
				or (row.original.owner_source or row.original.source) ~= row.source or _output_owners[key] ~= row.owner then return false end
		end
		local consumed, pressed_at, hold_owners = _consumed_down, _pressed_at, _hold_owners
		_reset_modifier_state()
		_consumed_down, _pressed_at, _hold_owners = consumed, pressed_at, hold_owners
		local captured_codes = {}
		for _, key in ipairs(ordered) do
			local row, output = rows[key], view.owners[rows[key].owner]
			if output and output.state == "held" and not consumed[key] then
				local role, failed = _modifier_role(row.code)
				if failed then return false end
				if role then
					if not captured_codes[row.code] then
						local _, _, err = _capture(row.code, InputEvent.VALUE_DOWN)
						if err then return false end
						captured_codes[row.code] = true
					end
					_track_modifier(row.source, row.code, InputEvent.VALUE_DOWN, role)
				end
			end
		end
		if not _locks.seed(_devices[1]) or not current() or inverse_current(fresh) ~= true then return false end
		if tx.publisher and (tx.publisher() ~= true or not current()) then return false end
		if selected() ~= true or not current() or inverse_current(fresh) ~= true then return false end
		tx.changed = true
		return _publish_source_transaction(tx)
	end)
	if not called or accepted ~= true then
		if old_capture and current() and inverse_current(old_capture) == true then _layout = previous_layout
		else _retire_source_transaction(tx, "selected-map refresh refused") end
	end
	if _source_reconciliation == tx then _source_reconciliation = nil end
	return called and accepted == true
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
	if _source_reconciliation then return end
	if not _running and not _reacquiring then return end

	_ticks_since_check = _ticks_since_check + 1
	if _ticks_since_check < DEVICE_CHECK_TICKS then return end
	_ticks_since_check = 0
	local tx = _begin_source_transaction()
	tx.changed = false
	local called, accepted = pcall(function()
	
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
				tx.waiting = true; return true
			end
			-- Readable is not the same as "can produce key events", and the kernel
			-- reuses eventN numbers across hotplug: the exact path may now name a
			-- mouse or another non-keyboard node. start() refuses those, so the
			-- watchdog must not adopt one behind its back and grab it as a keyboard.
			local ok_finder, Finder = pcall(require, "modules.hotstrings.device_finder")
			local validate = ok_finder and Finder.is_key_device
			if ok_finder and _intercept then validate = Finder.is_interceptable_key_device end
			if type(validate) ~= "function" then
				Logger.error(LOG, "Pinned input capability validation is unavailable — refusing capture.")
				return false
			end
			local is_key, key_why = validate(_pinned_device)
			if not is_key then
				_pinned_missing = true
				if not _reported_missing then
					Logger.warn(LOG, "Pinned input device %s cannot be captured in the current mode (%s) — waiting for that exact path.",
						_pinned_device, tostring(key_why))
					_reported_missing = true
				end
				tx.waiting = true; return true
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
			if not same_paths(pointers, _pointer_devices) or not _all_pointers_open(pointers) then
				if _armed_input and _withdraw_input_arm(_armed_input) ~= true then return false end
				if not _source_original_cohort_current(tx) then return false end
				tx.changed = true
				tx.sources, tx.source_observers, tx.pointers, tx.pointer_observers, tx.native_complete = {}, {}, {}, {}, true
				for _, path in ipairs(_devices) do
					if not _capture_source_member(tx, path, keyboard_slot, true) then return false end
				end
				if _acquire_pointers(pointers, tx) == false then return false end
			end
			tx.waiting = true; return true
		end
		_reported_missing = false
	
		local keyboards_changed = not same_paths(keyboards, _devices)
			or not _all_keyboards_open(keyboards) or _pinned_missing
		local pointers_changed = not same_paths(pointers, _pointer_devices)
			or not _all_pointers_open(pointers)
		-- Refresh origin admission through this existing watchdog, including an
		-- unchanged path whose kernel descriptor became synthetic or unknown.
		M.physical_source_receipt()
		if not keyboards_changed and not pointers_changed then return true end
		if _armed_input and _withdraw_input_arm(_armed_input) ~= true then return false end
		if not _source_original_cohort_current(tx) then return false end
		tx.changed = true
		if not keyboards_changed then
			tx.sources, tx.source_observers, tx.pointers, tx.pointer_observers, tx.native_complete = {}, {}, {}, {}, true
			for _, path in ipairs(_devices) do
				if not _capture_source_member(tx, path, keyboard_slot, true) then return false end
			end
			if _acquire_pointers(pointers, tx) == false then return false end
			return true
		end
		local force_path = _pinned_missing and _pinned_device or nil
		_pinned_missing = false
	
		Logger.start(LOG, "Keyboard source set changed (%d → %d) — re-acquiring…",
			#_devices, #keyboards)
		tx.sources, tx.source_observers, tx.pointers, tx.pointer_observers, tx.native_complete = {}, {}, {}, {}, true
		local acquired, acquire_err = _acquire(keyboards, force_path, tx)
		if acquired then
			-- A failed new open must leave the retained XKB state intact. Once
			-- acquisition succeeds, preserve only modifiers whose exact forwarded
			-- owner survived; a removed keyboard has already retired its owners.
			local modifiers = {}
			for _, entry in ipairs(_modifier_order) do
				local forwarded = _forwarded_down[entry.key]
				if forwarded then
					modifiers[#modifiers + 1] = { source = forwarded.owner_source or forwarded.source,
						code = entry.code, role = _modifier_down[entry.key] }
				end
			end
			local reset_ok, reset_err = XkbCapture.reset_state()
			if not reset_ok then
				Logger.error(LOG, "Cannot reset XKB state after keyboard acquisition: %s.", tostring(reset_err))
				return false
			end
			local seeded, seed_err = _locks.seed(_devices[1])
			if tx.managed and not seeded then
				Logger.error(LOG, "Cannot restore lock state after keyboard acquisition: %s.", tostring(seed_err))
				return false
			end
			-- A source/capture change retires every old repeat callback, but the
			-- application still never saw its consumed down. Keep that debt only
			-- on committed source/key owners until an actual release arrives.
			local sources, suppressed, physical, snapshots = {}, {}, {}, {}
			for _, path in ipairs(_devices) do sources[path] = true end
			for key, down in pairs(_physical_down) do
				-- A retained remap hold still needs its original physical source
				-- for later unplug retirement, even when no consumer swallowed it.
				if _remap_owned[key] and sources[down.source] then physical[key] = down end
				if _consumed_down[key] and sources[down.source] then
					local snapshot = snapshots[down.source]
					if snapshot == nil then
						local keys, query_err = EvdevReader.pressed_keys(keyboard_slot(down.source), KEY_MAX)
						snapshot = { keys = keys }
						snapshots[down.source] = snapshot
						if keys == nil then
							Logger.warn(LOG, "Suppressed-key state unavailable on recovered source %s — "
								.. "retaining consumed presses until release (%s).", down.source, tostring(query_err))
						end
					end
					-- The kernel can prove a release whose event was lost while the
					-- descriptor was closed. An unavailable query proves no release.
					if snapshot.keys == nil or snapshot.keys[down.code] == true then
						suppressed[key], physical[key] = true, down
					end
				end
			end
			_reset_modifier_state()
			local captured = {}
			for _, modifier in ipairs(modifiers) do
				if not captured[modifier.code] then
					local _, _, capture_err = _capture(modifier.code, InputEvent.VALUE_DOWN)
					if capture_err then return false end
					captured[modifier.code] = true
				end
				_track_modifier(modifier.source, modifier.code, InputEvent.VALUE_DOWN, modifier.role)
			end
			_consumed_down, _physical_down = suppressed, physical
			_sync_dropped = {}
			if _acquire_pointers(pointers, tx) == false then return false end
			if not _source_cohort_current(tx) then return false end
			if tx.publisher then
				local called, published = pcall(tx.publisher)
				if not called or published ~= true or not _source_cohort_current(tx) then return false end
			end
			_running = true
			_reacquiring = false
			-- A cold reacquisition published before it was running. A warm one
			-- already published ready through _acquire and needs no second scan.
			if not _origin_ready then M.physical_source_receipt() end
			Logger.success(LOG, "Re-acquired %d keyboard source(s) (intercept=%s).",
				#keyboards, tostring(_intercept))
		else
			-- Deliberately not a silent retry loop: the next tick tries again, and
			-- saying so each time is how a permission problem on a newly created node
			-- becomes visible instead of looking like a dead daemon.
			Logger.error(LOG, "Could not acquire the complete keyboard source set — will retry (%s).",
				tostring(acquire_err or "open or grab refused"))
			if acquire_err then
				return false
			end
			if tx.managed then return false end
			_running = _all_keyboards_open(_devices)
			_reacquiring = not _running
			tx.changed = false; tx.waiting = true
		end
		return true
	end)
	local current = called and accepted == true and (tx.waiting and not tx.changed
		and _source_transaction_current(tx) or _publish_source_transaction(tx))
	if not current then _retire_source_transaction(tx, "source reconciliation refused") end
	if _source_reconciliation == tx then _source_reconciliation = nil end
	if called and accepted == true then _number_row.construct() end
	return current
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
--- @param opts table|nil { intercept?, layout?, onChar?, onKey?, onPhysical?, onHold?, onHoldAdmission?, onConsume?, onDesync?, onEmitRaw?, device?, pinned? }
---              onHold function     Receives an admitted physical scancode and held milliseconds.
---              onHoldAdmission function Returns the current opaque plain-table policy token or nil.
---                                  Absence preserves legacy callers; refusal affects metrics only.
---              intercept boolean   Grab the device. Default false.
---              layout    string    Physical family for metrics: "qwerty" or
---                                  "azerty". Text always follows live XKB.
---              onChar    function  Called with (char_string, evdev_scancode) for printable keys.
---              onKey     function  Called with (key_name, { mods }) for control keys,
---                                  mods being held_modifiers() at the press,
---                                  and with ("shortcut", { key, mods }) for a chord.
---              onPhysical function  Called with (evdev_scancode, key_name, char_or_nil,
---                                  evdev_value) for every physical down/up transition.
---              onConsume function Called before pass-through with a key detail;
---                                  true suppresses its down/repeat/up in intercept mode.
---              onDesync function Called synchronously when evdev reports queue loss.
---              onEmitRaw function  Called with (evdev_scancode, evdev_value) to put a
---                                  consumed event back on the wire. MANDATORY when
---                                  intercept is true, ignored otherwise.
---              onClick   function  Called with (button_code) when a pointer button is
---                                  pressed. Supplying it opens a second, NEVER
---                                  grabbed, read-only descriptor on the pointer.
---              device    string    Override /dev/input/eventN path.
---              pinned    boolean   Reacquire only device; never auto-switch it.
---              onCaptureReacquired function Original selected-map publisher after
---                                  keyboard replacement and CapsLock seeding. A
---                                  refusal stops managed input before it resumes.
function M.start(opts)
	if _source_reconciliation then return false end
	if _running then
		Logger.debug(LOG, "start() called while already running — no-op.")
		return
	end

	-- Capture transport may passively forward genuine event receipts. Its start
	-- identity is sealed before callbacks; all private issuer/cleanup ports above
	-- retain their cold-construction originals and authenticate every returned receipt.
	_input_reader_ports.capture_event = rawget(EvdevReader, "capture_event")
	local options = type(opts) == "table" and opts or {}
	local admission = options.onHoldAdmission
	if admission ~= nil and type(admission) ~= "function" then return false end
	if _number_row.retire() ~= true then return false end
	_number_row.suppressed = {}
	local row_mode = require("layout.number_row_policy").mode(rawget(options, "numberRowMode") or "native")
	if not row_mode then return false end
	_number_row.mode = row_mode
	_capture_session, _capture_options = {}, options
	local capture_session = _capture_session
	_capture_republisher = rawget(options, "onCaptureReacquired")
	if _capture_republisher ~= nil and type(_capture_republisher) ~= "function" then
		Logger.error(LOG, "start(): current capture publisher is invalid — refusing input.")
		return false
	end
	if _capture_republisher and (not original_reader_load or not _input_exports_current()) then
		Logger.error(LOG, "start(): original Reader authority is unavailable — refusing managed capture.")
		return false
	end
	_pinned_device = options.pinned == true and type(options.device) == "string"
		and options.device ~= "" and options.device or nil
	_pinned_missing = false
	_reacquiring = false
	if type(options.onChar) == "function" then _on_char = options.onChar end
	if type(options.onKey)  == "function" then _on_key  = options.onKey  end
	if type(options.onPhysical) == "function" then _on_physical = options.onPhysical end
	if type(options.onHold) == "function" then _on_hold = options.onHold end
	if type(options.onClick) == "function" then _on_click = options.onClick end
	if type(options.onPointerEvent) == "function" then _on_pointer_event = options.onPointerEvent end
	_on_consume = type(options.onConsume) == "function" and options.onConsume or nil
	_on_desync = type(options.onDesync) == "function" and options.onDesync or nil
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
	_sync_dropped = {}
	_forwarded_down = {}
	_physical_down = {}

	local writer = require("adapters.uinput_writer")
	_broker = options.outputBroker or ModifierBroker.for_channel(writer) or ModifierBroker.attach(writer)
	if not _broker and options.requireOutputBroker then
		Logger.error(LOG, "The exact shared output broker is unavailable — refusing the keyboard device.")
		return
	end
	if not _broker then _broker = ModifierBroker.controlled() end
	_input_output_owner = nil
	if rawget(ModifierBroker, "for_channel") == installed_output_broker then
		local installed, binding = installed_output_broker(writer)
		if installed == _broker and type(binding) == "function" and binding(_broker) == true then
			local ports = {}; for _, name in ipairs(INPUT_OUTPUT_PORT_NAMES) do ports[name] = rawget(writer, name) end
			_input_output_owner = { writer = writer, broker = _broker, ports = ports, binding = binding,
				terminal = rawget(_broker, "output_retired") }
		end
	end

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
	local validate = ok_finder and Finder.is_key_device
	if ok_finder and _intercept then validate = Finder.is_interceptable_key_device end
	if type(validate) ~= "function" then
		Logger.error(LOG, "start(): device_finder unavailable — cannot verify the keyboard source set.")
		return
	end
	for _, target in ipairs(targets) do
		local is_key, key_why = validate(target)
		if not is_key then
			Logger.error(LOG, "start(): %s cannot be captured in the current mode — %s.", target, tostring(key_why))
			return
		end
	end

	-- Refresh the foreground context before starting.
	_read_context()

	if _capture_session ~= capture_session then return false end
	local tx = _begin_source_transaction()
	tx.sources, tx.source_observers, tx.pointers, tx.pointer_observers, tx.native_complete = {}, {}, {}, {}, true
	local called, accepted = pcall(function()
		if not _source_transaction_current(tx) or not _acquire(targets, nil, tx) then
			Logger.error(LOG, "start(): failed to open or grab the complete keyboard source set.")
			return false
		end
		local seeded, seed_err = _locks.seed(_devices[1])
		if tx.managed and not seeded then
			Logger.error(LOG, "Cannot seed keyboard lock state: %s.", tostring(seed_err))
			return false
		end
	
		-- The pointer is opened last and its failure is not fatal: a machine with no
		-- pointer, or one whose node this user cannot read, still expands hotstrings.
		-- It simply cannot notice a click, which is the behaviour this driver had for
		-- its whole life until now.
		-- Managed capture must also retain its complete original cleanup cohort.
		if _on_click and _acquire_pointers(pointers, tx) == false then return false end
	
		_ticks_since_check = 0
		_reported_missing = false
		_running = true
		-- Acquisition proved the device before it was running. Publish admission
		-- at the completed lifecycle boundary so the first press can own repeats.
		M.physical_source_receipt()
		Logger.success(LOG, "Keyboard hook started (keyboards=%d pointers=%d layout=%s intercept=%s).",
			#_devices, #_pointer_devices, _layout, tostring(_intercept))
		return _publish_source_transaction(tx)
	end)
	if not called or accepted ~= true then _retire_source_transaction(tx, "startup source publication refused") end
	if _source_reconciliation == tx then _source_reconciliation = nil end
	if called and accepted == true then
		_number_row.construct()
		if not _running or not rawequal(_capture_session, capture_session) then return false end
		_on_hold_admission = admission
		_hold_admission_session = capture_session
	end
	return called and accepted == true
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
	if _number_row.retire() ~= true then M.emergency_stop("native number-row stop cleanup pending"); return false end
	-- First, while the daemon's device can still carry the unlock.
	_locks.end_word(true, "keyboard hook stopped")
	_capture_session = nil
	if not _running and not _reacquiring then return end
	if _release_remapped() == false then
		M.emergency_stop("combination key retirement refused during stop")
		return false
	end
	local released, release_err = _release_forwarded_sources(_devices)
	if not released then
		M.emergency_stop("could not release virtual keys during stop: " .. tostring(release_err))
		return
	end
	_close_paths(_pointer_devices, pointer_slot)
	_close_paths(_devices, keyboard_slot)
	_buffered_reader_cleanup=nil
	_pointer_devices = {}
	_devices = {}
	_device  = nil
	_pinned_device = nil
	_pinned_missing = false
	_reacquiring = false
	_running = false
	_consumed_down = {}
	_remap_owned = {}
	_remap_orphans = {}
	_remap_source_of = {}
	_clock_event_ms, _clock_read_ms = nil, nil
	_sync_dropped = {}
	_forwarded_down = {}
	_physical_down = {}
	_armed_input, _live_input_context = nil, nil
	Logger.info(LOG, "Keyboard hook stopped.")
end

--- Immediately releases every grabbed descriptor after an output-path failure.
---
--- The current event may already be lost, but keeping EVIOCGRAB after the only
--- pass-through channel failed would swallow every subsequent keystroke. Closing
--- the descriptor is the kernel-guaranteed emergency ungrab.
--- @param reason string|nil
function M.emergency_stop(reason)
	_number_row.retire() -- Unknown original row/output debt stays retained.
	_capture_session = nil
	local message = tostring(reason or "keyboard output path failed")
	Logger.error(LOG, "Emergency keyboard stop — %s.", message)
	-- Best effort as below: a CapsLock left locked types every later letter in
	-- capitals, and Ergopti's CapsLock key taps Enter instead of unlocking it.
	pcall(_locks.end_word, true, "emergency keyboard stop")
	-- Best effort, before the descriptors close: a Ctrl the virtual keyboard
	-- still holds would stay down in every application once nothing forwards
	-- its release. The output path may be what failed, so nothing here throws.
	if _remapper then
		local original = _leased_remapper_cleanup
		if original and original.engine == _remapper then
			pcall(original.release_all, original.engine)
		else pcall(function() _remapper:release_all() end) end
	end
	if _broker and _broker.has_debt() then
		_broker.retire()
	elseif _broker and type(_emit_raw) == "function" then
		for key, entry in pairs(_forwarded_down) do
			local owner = _output_owners[key]
			if owner then
				local receipt = _broker.edge(owner, entry.code, InputEvent.VALUE_UP, _emit_raw)
				if not receipt.ok then _broker.retire(); break end
			end
		end
	end
	_close_paths(_pointer_devices, pointer_slot)
	_close_paths(_devices, keyboard_slot)
	_buffered_reader_cleanup=nil
	_pointer_devices = {}
	_devices = {}
	_device = nil
	_pinned_device = nil
	_pinned_missing = false
	_reacquiring = false
	_running = false
	_consumed_down = {}
	_remap_owned = {}
	_remap_orphans = {}
	_remap_source_of = {}
	_clock_event_ms, _clock_read_ms = nil, nil
	_sync_dropped = {}
	_forwarded_down = {}
	_physical_down = {}
	_armed_input, _live_input_context = nil, nil
end

--- Runs a blocking modal (a zenity dialog) with the keyboard handed back to
--- the desktop, then takes it again.
---
--- The daemon forwards every grabbed key from its event loop, and a dialog run
--- from a menu callback blocks that loop until it closes. Under the grab the
--- dialog therefore never received a key: it could only be dismissed with the
--- mouse, and no value (an API key, a delay) could be typed into it.
--- Keys typed into the dialog are discarded on return, and keys still held
--- then (the Enter that closed it) are treated as consumed, so neither reaches
--- the hotstring buffer nor the application a second time.
--- @param fn function The modal; its results are returned.
--- @param opts table|nil { observer(stage, receipt) } brackets acknowledged native restoration.
--- @return any
function M.while_released(fn, opts)
	local observer = type(opts) == "table" and opts.observer or nil
	local function observe(stage, receipt)
		if type(observer) ~= "function" then return true end
		return _call_callback("modal restoration observer", observer, stage, receipt)
	end
	if _source_reconciliation then
		observe("refused", { ok = false, reason = "reconciliation_pending" })
		return nil, "source reconciliation is already pending"
	end
	if not _running then
		if _remapper and _remapper.has_combinations then
			if _release_remapped() ~= true or _remapper:activate() ~= true then
				observe("refused", { ok = false, reason = "release_failed" })
				return nil, "combination key retirement refused"
			end
		end
		return fn()
	end
	local paths = {}
	for index, path in ipairs(_devices) do paths[index] = path end
	if _release_remapped() == false then
		observe("refused", { ok = false, reason = "release_failed" })
		return nil, "combination key retirement refused"
	end
	-- Ungrabbed, the keyboard reaches the desktop unseen: a CapsLock pressed
	-- in the dialog could not be told apart from the session's, so it ends.
	if _locks.end_word(true, "keyboard handed to a dialog") ~= true then
		observe("refused", { ok = false, reason = "caps_word_retirement_refused" })
		return nil, "CapsWord lock retirement refused"
	end
	local modal_tx = _intercept and original_reader_load and _input_source_owners and _capture_session
		and _begin_source_transaction() or nil
	local function stop_modal(reason)
		if modal_tx then
			_retire_source_transaction(modal_tx, reason)
			if _source_reconciliation == modal_tx then _source_reconciliation = nil end
		else M.emergency_stop(reason) end
	end
	if _intercept then
		local release_call, released, release_err = pcall(_release_forwarded_sources, paths)
		if not release_call or not released then
			stop_modal("could not release virtual keys before a dialog: " .. tostring(release_err or "release refused"))
			observe("refused", { ok = false, reason = "release_failed" })
			return nil, "virtual key retirement refused"
		end
		for _, path in ipairs(paths) do
			local called, acknowledged = pcall(EvdevReader.ungrab, keyboard_slot(path))
			if not called or acknowledged ~= true then
				stop_modal("could not release the keyboard before a dialog: " .. path)
				observe("refused", { ok = false, reason = "ungrab_failed" })
				return nil, "keyboard release refused"
			end
		end
	end
	Logger.debug(LOG, "Keyboard released to the desktop for a dialog.")

	local results = { n = 0 }
	local function keep(...) results = { n = select("#", ...), ... } end
	-- An error may itself be false or nil; only pcall's status owns success.
	local ok, err = pcall(function() keep(fn()) end)

	-- Restoration can acquire one source before a later native operation raises.
	-- Keep the entire cohort under one cleanup boundary so no grab escapes it.
	local restored_call, restored, restore_reason = pcall(function()
		-- Refuse every foreign opening before draining or grabbing ANY successor.
		-- Native ungrab revokes input generations, but not this per-open RAM join.
		if modal_tx then
			for _, path in ipairs(paths) do
				local slot = keyboard_slot(path)
				local _, _, same_open = _input_reader_ports.source_owner_current(modal_tx.close_owners[slot],
					modal_tx.close_observers[slot], _input_reader_ports.capture_source_owner,
					_input_reader_ports.source_owner_current, _input_reader_ports.retire_source)
				if same_open ~= true then return false, "original_open_replaced" end
			end
		end
		for _, path in ipairs(paths) do
			local slot = keyboard_slot(path)
			repeat local drained = EvdevReader.drain(function() end, slot) until not drained or drained == 0
			_pending_events[slot] = nil
			if _intercept and EvdevReader.grab(slot) ~= true then return false, "regrab_failed" end
		end
		-- Observe mode receives the same queued evdev input while the blocking
		-- dialog owns the desktop. Discard it and resynchronise without grabbing
		-- or creating the native transaction reserved for intercepted sources.
		if not _source_recovery.run(paths, true, modal_tx) then return false, "resynchronisation_failed" end
		return true
	end)
	if not restored_call or restored ~= true then
		restore_reason = restored_call and restore_reason or "restoration_failed"
		stop_modal("could not restore keyboard capture after a dialog: " .. tostring(restore_reason))
		observe("refused", { ok = false, reason = restore_reason })
		if not ok then error(err, 0) end
		return (table.unpack or unpack)(results, 1, results.n)
	end
	if not observe("before", { ok = true }) then
		observe("refused", { ok = false, reason = "observer_failed" })
		if not ok then error(err, 0) end
		return (table.unpack or unpack)(results, 1, results.n)
	end
	local desynced = not _on_desync or _call_callback("input-desync callback", _on_desync)
	observe("after", { ok = desynced and _running and ok })
	if desynced and _running and ok then _number_row.construct() end
	Logger.debug(LOG, "Keyboard taken back after a dialog.")
	if not ok then error(err, 0) end
	return (table.unpack or unpack)(results, 1, results.n)
end

--- Installs (or removes, with nil) the tap-hold engine. Whatever the previous
--- engine held is released first.
--- @param engine table|nil platform/remap/tap_hold_engine instance
--- @param on_tap function|nil Runs a tap action and its canonical source binding.
function M.set_remapper(engine, on_tap)
	if _number_row.retire() ~= true then return false end
	if _release_remapped() == false then return false end
	for key in pairs(_remap_owned) do _remap_orphans[key] = true end
	_remap_owned = {}
	_remap_source_of = {}
	if engine and engine.activate and engine:activate() ~= true then return false end
	_remapper_generation = _remapper_generation + 1
	_remapper = engine
	_remapper_input_owner = engine and type(_input_ports.capture_input_owner) == "function"
		and _input_ports.capture_input_owner(engine) or nil
	_armed_input, _live_input_context = nil, nil
	_on_tap = type(on_tap) == "function" and on_tap or nil
	_number_row.construct()
	return true
end

--- Releases every key the tap-hold engine holds (pause, feature switch).
function M.release_remapped()
	if _number_row.retire() ~= true then return false end
	return _release_remapped()
end

--- Returns true if the keyboard hook is currently active.
--- @return boolean
function M.isRunning()
	return _running
end

--- Returns true while a previously live source set is waiting to be acquired
--- again. This is distinct from startup failure: the daemon keeps its periodic
--- watchdog alive only for a capture session that proved it was operational.
--- @return boolean
function M.isRecovering()
	return _reacquiring
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
--- @param events table Array of { type, code, value, at_ms?, timestamp_us? } tables, in arrival order.
--- @param callbacks table { onChar?, onKey?, onPhysical?, onHold?, onConsume?, onDesync?, onEmitRaw?, captureEvent?,
---   liveXkb?, keyState?, ledState? }.
-- Exposed so the watchdog test can advance exactly as many ticks as the check
-- needs, instead of hardcoding a number that silently stops matching.
M.DEVICE_CHECK_TICKS = DEVICE_CHECK_TICKS

--- @param intercept boolean Whether to run the pass-through branch.
--- @return integer Number of events drained.
--- Test seam: runs lock LED seeding against an already-open source.
--- @param path string
--- @return boolean
function M._seed_caps_lock_for_test(path)
	return _locks.seed(path)
end

function M._test_drive(events, callbacks, intercept)
	local size = InputEvent.native_size()
	local queue, times = {}, {}
	for i, ev in ipairs(events or {}) do
		queue[i] = InputEvent.encode(ev.type, ev.code, ev.value, size, ev.timestamp_us)
		times[i] = ev.at_ms
	end
	local at = 0
	local cb = callbacks or {}
	_broker = ModifierBroker.controlled()
	_output_owners = {}

	EvdevReader._set_backend({
		open  = function() return 1 end,
		ioctl = function() return true end,
		read  = function()
			at = at + 1
			return queue[at]
		end,
		poll  = function() return queue[at + 1] ~= nil end,
		close = function() end,
		read_bits = function(_, request, count)
			local provider = request % 0x100 == EvdevReader.EVIOCGLED_NR
				and cb.ledState or cb.keyState
			if type(provider) == "function" then return provider(count) end
			return string.rep("\0", count)
		end,
	})

	_on_char     = cb.onChar
	_on_key      = cb.onKey
	_on_physical = cb.onPhysical
	_on_hold     = cb.onHold
	_on_hold_admission = cb.onHoldAdmission
	_hold_admission_session = _capture_session
	_on_consume  = cb.onConsume
	_on_desync   = cb.onDesync
	_emit_raw    = cb.onEmitRaw
	_intercept   = intercept and true or false
	-- liveXkb drives the production path through adapters/xkb_capture, whose
	-- backend and keymap the test has installed; otherwise a capture double.
	if cb.liveXkb == true then
		_test_capture_event = nil
	else
		_test_capture_event = type(cb.captureEvent) == "function"
			and cb.captureEvent or _legacy_capture_for_test
	end
	_reset_modifier_state()
	_sync_dropped = {}
	_forwarded_down = {}
	_physical_down = {}

	local test_path = "/dev/input/test"
	_devices = { test_path }
	_physical_sources = { [test_path] = cb.physicalSource ~= false }
	_device = test_path
	local slot = keyboard_slot(test_path)
	EvdevReader.open(test_path, slot)
	_running = true
	-- Drained to the end: one drain is bounded, and a long stream cut at the
	-- bound reads as keys the daemon never released.
	local drained, status = 0, "bounded"
	while status == "bounded" do
		local count
		count, status = EvdevReader.drain(function(ev)
			_test_clock_ms = times[at]
			_dispatch_event(ev, test_path)
		end, slot)
		drained = drained + count
	end
	_test_clock_ms = nil
	_clock_event_ms, _clock_read_ms = nil, nil
	_remap_source_of = {}
	_running = false
	_devices = {}
	_physical_sources = {}
	_device = nil
	_test_capture_event = nil
	_sync_dropped = {}
	_forwarded_down = {}
	_physical_down = {}
	EvdevReader._reset_backend()
	return drained
end

-- Original cleanup and input exports are minted once, before caller callbacks.
for _, name in ipairs(INPUT_HOOK_PORT_NAMES) do original_input_hook_ports[name] = rawget(M, name) end

return M
