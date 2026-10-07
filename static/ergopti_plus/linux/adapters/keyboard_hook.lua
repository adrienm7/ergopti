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
local RuntimeGuard = require("infra.runtime_guard")
-- The new logical lease trusts the normal package loader's cold construction,
-- before any backend/setup callback. A preloaded facade keeps ordinary input
-- compatibility but supplies no evidence that these authority exports are original.
local original_reader_load = package.loaded["adapters.evdev_reader"] == nil
local EvdevReader = require("adapters.evdev_reader")
local INPUT_READER_PORT_NAMES = { "capture_event", "event_view", "event_current", "source_current",
	"capture_source_owner", "source_owner_current", "retire_source", "open", "close", "grab", "ungrab", "use_ffi_backend", "_set_backend", "_reset_backend" }
local _input_reader_ports = {}
for _, name in ipairs(INPUT_READER_PORT_NAMES) do
	_input_reader_ports[name] = rawget(EvdevReader, name)
end
local EvdevCodes = require("infra.evdev_codes")
local Monotonic = require("infra.monotonic")
local InputEvent = require("infra.input_event")
local XkbCapture = require("adapters.xkb_capture")
local ModifierBroker = require("adapters.modifier_broker")
local installed_output_broker = ModifierBroker.for_channel
local INPUT_OUTPUT_PORT_NAMES = { "capture_output", "capture_output_observer", "output_view", "acquire_transaction", "transaction_view", "transaction_current",
	"transaction_emit", "dispatch_transaction", "commit_transaction", "retire_transaction", "close_owned" }
local InputIssuer = require("platform.remap.key_combination_engine")
local original_input_hook_ports = {}
local INPUT_HOOK_PORT_NAMES = { "capture_input_owner", "input_owner_current", "arm_one_shot", "set_remapper", "stop", "emergency_stop", "key_text" }
local INPUT_PORT_NAMES = { "capture_input_owner", "input_owner_current", "capture_input_guard", "arm_one_shot", "input_owner_state", "clear_input_arm" }
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
local _on_desync    = nil   -- function() invalidates text derived before SYN_DROPPED

-- Cached foreground window context (updated via refreshContext).
local _context  = { appId = "", windowTitle = "" }

-- Running flag — set after the device is successfully opened.
local _running  = false

-- One captured publisher and one in-flight source transaction belong to a start.
local _capture_session, _capture_options, _capture_republisher = nil, nil, nil
local _source_reconciliation = nil

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
--- Seeds the capture state's CapsLock from the keyboard's LED.
---
--- A fresh XKB state starts unlocked, and the capture state learns CapsLock only
--- from key presses. Started (or re-acquired after a hotplug) while CapsLock was
--- already on, the daemon therefore believed it off: typed triggers were read in
--- the wrong case, and the injector — which releases a locked CapsLock around a
--- replacement — typed it inverted. The LED is read at acquisition, before the
--- grab can make it stale (the kernel drops the compositor's LED writes to a
--- grabbed device), and matches what the desktop last set.
--- @param path string|nil The keyboard source just acquired.
--- @return boolean True when the state now matches the LED.
local function _seed_caps_lock(path)
	if not path then return false end
	local leds, led_err = EvdevReader.active_leds(keyboard_slot(path), LED_CAPSL)
	if not leds then
		Logger.warn(LOG, "CapsLock state of %s unreadable — assuming off (%s).", path, tostring(led_err))
		return false
	end
	if leds[LED_CAPSL] == true then
		_capture(EvdevCodes.KEY_CAPSLOCK, InputEvent.VALUE_DOWN)
		_capture(EvdevCodes.KEY_CAPSLOCK, InputEvent.VALUE_UP)
		Logger.debug(LOG, "CapsLock is on at acquisition — capture state locked to match.")
	end
	return true
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
	return { source = source, generation = receipt.generation, ready = receipt.ready, physical = _physical_sources[source] == true }
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
	if not ctx or ctx.used or ctx.arming or getmetatable(lease) ~= nil or next(lease) ~= nil
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
		return true
	end
	_forwarded_down[key] = prior
	M.emergency_stop(string.format("raw ownership settlement failed (code=%d value=%d): %s",
		ev.code, ev.value, receipt.disposition))
	return false
end

local function _call_callback(label, callback, ...)
	local args = { n = select("#", ...), ... }
	local unpack_args = table.unpack or unpack
	return RuntimeGuard.call(label, function() return callback(unpack_args(args, 1, args.n)) end, function()
		M.emergency_stop(label .. " failed")
	end)
end

local function _resynchronise(source)
	local pressed = {}
	for key, current in pairs(_physical_down) do
		if current.source ~= source then pressed[key] = current end
	end

	local slot = keyboard_slot(source)
	local held_receipt = EvdevReader.capture_pressed_keys and EvdevReader.capture_pressed_keys(slot, KEY_MAX) or nil
	local held_view = held_receipt and EvdevReader.pressed_keys_view(held_receipt) or nil
	local source_keys, key_err
	if held_view then
		source_keys = {}
		for _, code in ipairs(held_view.down) do source_keys[code] = true end
	else source_keys, key_err = EvdevReader.pressed_keys(slot, KEY_MAX) end
	local leds, led_err = EvdevReader.active_leds(slot, LED_CAPSL)
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
		if current.code ~= EvdevCodes.KEY_CAPSLOCK and (not role or not captured[current.code]) then
			captured[current.code] = true
			local _, _, capture_err = _capture(current.code, InputEvent.VALUE_DOWN)
			if capture_err then return false, tostring(capture_err) end
		end
		_track_modifier(current.source, current.code, InputEvent.VALUE_DOWN, role)
		_pressed_at[key] = Monotonic.now_ms()
		if consumed[key] then _consumed_down[key] = true end
	end
	if leds[LED_CAPSL] == true then
		local _, _, down_err = _capture(EvdevCodes.KEY_CAPSLOCK, InputEvent.VALUE_DOWN)
		local _, _, up_err = _capture(EvdevCodes.KEY_CAPSLOCK, InputEvent.VALUE_UP)
		if down_err or up_err then return false, tostring(down_err or up_err) end
	end

	if held_receipt and not EvdevReader.pressed_keys_current(held_receipt) then return false, "held source query revoked" end
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
				if requested ~= "one_shot_shift" or action ~= tap then return false end
				local lease = original_input_hook_ports.capture_input_owner()
				if not lease or original_input_hook_ports.input_owner_current(lease) ~= true then return false end
				return original_input_hook_ports.arm_one_shot(lease) == true
					and original_input_hook_ports.input_owner_current(lease) == true
			end, _combination_source(source))
		else frame.run(callback, _combination_source(source)) end
		_live_input_context = prior
	end
end

local function _dispatch_event(ev, source)
	-- Intercept mode grabbed the device, so nothing reaches the application
	-- except through here: put the raw event back BEFORE doing anything else.
	-- Order is the whole point — an injection triggered by this event must run
	-- against an application that already shows the character. In observe mode
	-- the physical event was never consumed, and re-emitting would type it twice.
	if ev.type == EVDEV_TYPE_SYN then
		if ev.code == SYN_DROPPED then
			if not _sync_dropped[source] then
				_sync_dropped[source] = true
				if _on_desync and not _call_callback(
					"input-desync callback", _on_desync) then return end
			end
		elseif ev.code == SYN_REPORT and _sync_dropped[source] then
			_sync_dropped[source] = nil
			local synced, sync_err = _resynchronise(source)
			if not synced then M.emergency_stop("evdev resynchronisation failed: " .. tostring(sync_err)) end
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
			out, tap, binding, frame = _remapper:process(ev.code, ev.value, at_ms, receipt)
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
				local accepted = _deliver_owned_rows(exact, out, source)
				if frame.ack(accepted) ~= true then
					if _armed_input then M.emergency_stop("owned input delivery acknowledgement refused") end
					return
				end
				if frame.replay then
					_remap_owned[owned_key] = nil
					_dispatch_event(ev, source)
					return
				end
				_run_owned_tap_frame(frame, tap, binding, exact, original_generation, origin, origin_view, source, at_ms)
				local restored, restore_frame = frame.restore(_combination_source(source))
				if restore_frame then
					local restored_ack = _deliver_owned_rows(exact, restored, source)
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
				_dispatch_event({ type = EVDEV_TYPE_KEY, code = remapped.code, value = remapped.value,
					remapped = true, original_owner = remapped.physical == true,
					holder = remapped.holder or (exact.output_holder and exact:output_holder(remapped)), handoff = remapped.handoff },
					remapped.physical and (_remap_source_of[remapped.code] or source) or source)
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
	if capture_transition then char, identity, capture_err = _capture(ev.code, ev.value) end

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
			if not _call_callback("key-hold callback", _on_hold, ev.code, held_ms) then
				-- A release owns the application's key state: it must go back
				-- even when the metrics consumer just died, or the key sticks
				-- down over there while nothing is held here.
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
			-- A missing verdict is not a suppression: the event still belongs
			-- to the application.
			_forward_raw(ev, source)
			return
		elseif consume == true or repeat_callback ~= nil then
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

	if not _forward_raw(ev, source) then return end

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
			_call_callback("control-key callback", _on_key, control, { mods = M.held_modifiers() })
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
			_call_callback("shortcut callback", _on_key,
				"shortcut", { key = identity or char, mods = M.held_modifiers() })
		end
		return
	end

	if char and _on_char then
		_call_callback("character callback", _on_char, char, ev.code)
	end
end




--- Releases every key the tap-hold engine holds (a hold modifier, a layer
--- chord, a one-shot Shift) through the normal path, so the virtual keyboard
--- and the modifier state both see the key-ups.
_dispatch_owned_rows = function(rows, source, exact)
	if #rows == 0 then return true end
	if not _running or not _intercept or type(_emit_raw) ~= "function" then return false end
	local generation, output, armed = _remapper_generation, _broker, _armed_input
	for _, row in ipairs(rows) do
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
		if receipt.count ~= 1 or receipt.accepted ~= true then return false end
		if armed and (_remapper ~= exact or _remapper_generation ~= generation or _broker ~= output
			or not _input_guard_current(armed)) then _withdraw_input_arm(armed); return false end
	end
	return true
end

_deliver_owned_rows = function(exact, rows, source)
	local token = exact:begin_delivery(rows)
	if not token then return false end
	local accepted = _dispatch_owned_rows(rows, source, exact)
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
	local exact, generation, output = _remapper, _remapper_generation, _broker
	local due_rows = exact:tick(now_ms)
	if exact.take_custody then
		for _, row in ipairs(exact:take_custody()) do due_rows[#due_rows + 1] = row end
	end
	for _, due in ipairs(due_rows) do
		if not _remapper_batch_current(exact, generation, output) then return false end
		if due.owned_rows then
			due.frame.ack(_deliver_owned_rows(exact, due.owned_rows, _device))
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
		if selected.keyboard then
			_dispatch_event(selected_event, selected.path)
		else
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
	for key, entry in pairs(_physical_down) do
		if retiring[entry.source] then
			_physical_down[key], _consumed_down[key], _pressed_at[key] = nil, nil, nil
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
	local retired = {}
	for path in pairs(retained) do retired[#retired + 1] = path end
	table.sort(retired)
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
			if ok_finder and type(Finder.is_key_device) == "function" then
				local is_key, key_why = Finder.is_key_device(_pinned_device)
				if not is_key then
					_pinned_missing = true
					if not _reported_missing then
						Logger.warn(LOG, "Pinned input device %s no longer produces key events (%s) — waiting for that exact path.",
							_pinned_device, tostring(key_why))
						_reported_missing = true
					end
					tx.waiting = true; return true
				end
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
		local reset_ok, reset_err = XkbCapture.reset_state()
		if not reset_ok then
			Logger.error(LOG, "Cannot reset XKB state for the new source set — keeping the previous set: %s.",
				tostring(reset_err))
			return not tx.managed
		end
		tx.sources, tx.source_observers, tx.pointers, tx.pointer_observers, tx.native_complete = {}, {}, {}, {}, true
		local acquired, acquire_err = _acquire(keyboards, force_path, tx)
		if acquired then
			_seed_caps_lock(_devices[1])
			-- A source/capture change retires every old repeat callback, but the
			-- application still never saw its consumed down. Keep that debt only
			-- on committed source/key owners until an actual release arrives.
			local sources, suppressed, physical, snapshots = {}, {}, {}, {}
			for _, path in ipairs(_devices) do sources[path] = true end
			for key, down in pairs(_physical_down) do
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
--- @param opts table|nil { intercept?, layout?, onChar?, onKey?, onPhysical?, onConsume?, onDesync?, onEmitRaw?, device?, pinned? }
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

	if _capture_session ~= capture_session then return false end
	local tx = _begin_source_transaction()
	tx.sources, tx.source_observers, tx.pointers, tx.pointer_observers, tx.native_complete = {}, {}, {}, {}, true
	local called, accepted = pcall(function()
		if not _source_transaction_current(tx) or not _acquire(targets, nil, tx) then
			Logger.error(LOG, "start(): failed to open or grab the complete keyboard source set.")
			return false
		end
		_seed_caps_lock(_devices[1])
	
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
	_capture_session = nil
	local message = tostring(reason or "keyboard output path failed")
	Logger.error(LOG, "Emergency keyboard stop — %s.", message)
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
	if not _running or not _intercept then
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
	local released, release_err = _release_forwarded_sources(paths)
	if not released then
		M.emergency_stop("could not release virtual keys before a dialog: " .. tostring(release_err))
		observe("refused", { ok = false, reason = "release_failed" })
		return fn()
	end
	for _, path in ipairs(paths) do EvdevReader.ungrab(keyboard_slot(path)) end
	Logger.debug(LOG, "Keyboard released to the desktop for a dialog.")

	local results = { n = 0 }
	local function keep(...) results = { n = select("#", ...), ... } end
	local ok, err = pcall(function() keep(fn()) end)
	if ok then err = nil end

	for _, path in ipairs(paths) do
		local slot = keyboard_slot(path)
		repeat local drained = EvdevReader.drain(function() end, slot) until not drained or drained == 0
		_pending_events[slot] = nil
		if not EvdevReader.grab(slot) then
			M.emergency_stop("could not take the keyboard back after a dialog: " .. path)
			observe("refused", { ok = false, reason = "regrab_failed" })
			return (table.unpack or unpack)(results, 1, results.n)
		end
		local held = EvdevReader.pressed_keys(slot, KEY_MAX)
		for code in pairs(held or {}) do _consumed_down[source_key(path, code)] = true end
		local synced, sync_err = _resynchronise(path)
		if not synced then
			M.emergency_stop("could not resynchronise after a dialog: " .. tostring(sync_err))
			observe("refused", { ok = false, reason = "resynchronisation_failed" })
			return (table.unpack or unpack)(results, 1, results.n)
		end
	end
	if not observe("before", { ok = true }) then
		observe("refused", { ok = false, reason = "observer_failed" })
		return (table.unpack or unpack)(results, 1, results.n)
	end
	local desynced = not _on_desync or _call_callback("input-desync callback", _on_desync)
	observe("after", { ok = desynced and _running and err == nil })
	Logger.debug(LOG, "Keyboard taken back after a dialog.")
	if err then error(err, 0) end
	return (table.unpack or unpack)(results, 1, results.n)
end

--- Installs (or removes, with nil) the tap-hold engine. Whatever the previous
--- engine held is released first.
--- @param engine table|nil platform/remap/tap_hold_engine instance
--- @param on_tap function|nil Runs a tap action and its canonical source binding.
function M.set_remapper(engine, on_tap)
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
	return true
end

--- Releases every key the tap-hold engine holds (pause, feature switch).
function M.release_remapped()
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
--- Test seam: runs the CapsLock seeding against an already-open source.
--- @param path string
--- @return boolean
function M._seed_caps_lock_for_test(path)
	return _seed_caps_lock(path)
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
