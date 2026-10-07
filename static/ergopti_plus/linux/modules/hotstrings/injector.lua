--- modules/hotstrings/injector.lua

--- ==============================================================================
--- MODULE: Hotstring Injector (Linux)
--- DESCRIPTION:
--- OS-facing module responsible for replaying hotstring expansions into the
--- currently focused application on Linux. Given a backspace count and a
--- replacement string, it erases the typed trigger then delivers the
--- replacement — as keystrokes resolved against the session's own XKB layout,
--- or through the clipboard for the rare character no key can produce.
---
--- FEATURES & RATIONALE:
--- 1. Ordered injection: first emits N Backspace keystrokes to erase the trigger
---    and visible terminator, then delivers the replacement and replays a
---    non-consumed terminator after it.
--- 2. One output channel. Everything goes through the driver's own uinput
---    device, the same one the keyboard hook re-emits through, so an injection
---    obeys the same grab and the same ordering as the keystrokes around it.
---    ydotool is gone: it assumes a US layout, needs a daemon, and forks per
---    event, which is what made the grab unaffordable in the first place.
--- 3. Defensive pcall: an injection failure never propagates to the engine or
---    crashes the daemon.
--- 4. Delay between phases: a small inter-phase delay lets the target application
---    process the backspaces before the replacement text arrives, preventing
---    character interleaving in fast editors.
--- ==============================================================================

local M = {}


-- =========================================
-- =========================================
-- ======= 1/ Logger Shim ==================
-- =========================================
-- =========================================

local Logger = require("logger.shim")
local EvdevCodes = require("infra.evdev_codes")
local KeyboardLayout = require("adapters.keyboard_layout")
local XkbCapture = require("adapters.xkb_capture")
local Clipboard = require("adapters.clipboard")
local OutputTransaction = require("modules.hotstrings.output_transaction")

local LOG = "modules.hotstrings.injector"

-- Optional libuv binding — used for a CPU-yielding sleep (uv_sleep) on the
-- inter-phase delay, so injection neither forks /bin/sleep nor busy-waits.
local ok_luv, luv = pcall(require, "luv")
if not ok_luv then luv = nil end


-- =========================================
-- =========================================
-- ======= 2/ Constants ====================
-- =========================================
-- =========================================

-- Milliseconds to pause between the backspace phase and the type phase.
-- Allows slow applications to process the deletes before new characters arrive.
local INTER_PHASE_DELAY_MS = 20

-- evdev EV_KEY event values (linux/input-event-codes.h): a key report carries
-- 0 on release, 1 on press and 2 for a kernel-generated autorepeat.
local EVDEV_VALUE_UP     = 0
local EVDEV_VALUE_DOWN   = 1

-- The keys a synthetic modifier maps to. Named by the level vocabulary the
-- keymap uses ("shift", "altgr") rather than by keycode, so the layout table and
-- the injector cannot disagree about which level means which key.
local MODIFIER_CODES = EvdevCodes.LEVEL_MODIFIER_CODE


-- =========================================
-- =========================================
-- ======= 3/ Internal Helpers =============
-- =========================================
-- =========================================

--- The driver's uinput channel, once opened. It is the ONLY output path: nil
--- means the daemon cannot put a key back, cannot erase a trigger and cannot
--- type a replacement, which is why the daemon refuses to grab without it.
local _uinput = nil

--- Exact layout-level modifier keycodes the user is physically holding.
--- @return table Ordered evdev keycodes.
local function held_text_modifier_codes()
	local ok, hook = pcall(require, "adapters.keyboard_hook")
	if not ok or type(hook.held_text_modifier_codes) ~= "function" then return {} end
	local ok_call, held = pcall(hook.held_text_modifier_codes)
	return (ok_call and type(held) == "table") and held or {}
end

--- Shortcut modifiers (Ctrl, Alt, Super) the user is holding.
--- @return table Ordered evdev keycodes.
local function held_shortcut_modifier_codes()
	local ok, hook = pcall(require, "adapters.keyboard_hook")
	if not ok or type(hook.held_shortcut_modifier_codes) ~= "function" then return {} end
	local ok_call, held = pcall(hook.held_shortcut_modifier_codes)
	return (ok_call and type(held) == "table") and held or {}
end

--- Non-modifier keys the hook forwarded as pressed and not yet released.
--- @return table evdev keycodes.
local function held_forwarded_keys()
	local ok, hook = pcall(require, "adapters.keyboard_hook")
	if not ok or type(hook.held_forwarded_keys) ~= "function" then return {} end
	local ok_call, held = pcall(hook.held_forwarded_keys)
	return (ok_call and type(held) == "table") and held or {}
end

local function must_emit(tx, code, value, phase)
	if not tx.emit(code, value, phase) then
		error(tx.error() or (phase .. " failed"), 0)
	end
end

--- The FFI nanosleep binding, or false when this runtime has no FFI. Probed once.
local _nanosleep = nil

--- Binds nanosleep(2) through FFI.
---
--- The reason this exists rather than only the luv path: luv is not installed in
--- CI and is optional on a user's machine, so the fallback below is what actually
--- ran everywhere — and it forks /bin/sleep on the injection path, once per
--- expansion. LuaJIT is a hard requirement of this driver, so FFI is not.
--- @return function|nil sleep(seconds)
local function nanosleep()
	if _nanosleep ~= nil then return _nanosleep or nil end
	_nanosleep = false

	local ok_ffi, ffi = pcall(require, "ffi")
	if not ok_ffi or type(ffi) ~= "table" then return nil end
	local ok_cdef, cdef_err = pcall(ffi.cdef, [[
		struct timespec { long tv_sec; long tv_nsec; };
		int nanosleep(const struct timespec *req, struct timespec *rem);
	]])
	if not ok_cdef and not tostring(cdef_err):find("redefin", 1, true) then return nil end

	local req = ffi.new("struct timespec[1]")
	_nanosleep = function(seconds)
		req[0].tv_sec = math.floor(seconds)
		req[0].tv_nsec = math.floor((seconds % 1) * 1e9)
		ffi.C.nanosleep(req, nil)
	end
	return _nanosleep
end

--- Sleeps for the given number of milliseconds without forking or spinning.
---
--- Never busy-waits on the standard CPU clock: on Linux it reports process CPU
--- time, so spinning on it would burn a full core for the delay rather than
--- yield it.
--- @param ms integer Milliseconds to sleep.
local function sleep_ms(ms)
	if ms <= 0 then return end
	local nap = nanosleep()
	if nap then
		nap(ms / 1000)
		return
	end
	if luv and type(luv.sleep) == "function" then
		luv.sleep(ms)
		return
	end
	-- Last resort, and the only spawn left anywhere on this path: a runtime with
	-- neither FFI nor luv, which is the developer's plain Lua and not the daemon.
	-- Fractional seconds are GNU coreutils syntax.
	pcall(os.execute, string.format("sleep %.3f", ms / 1000))
end

--- Test seam: forces the nanosleep probe to a known state.
--- @param value function|false|nil
function M._set_nanosleep_for_test(value)
	_nanosleep = value
end

--- Emits count Backspace keystrokes.
---
--- Through the uinput channel when one is open, which is the normal case under a
--- grab: the erase phase then costs no subprocess at all, on the one path where
--- latency is visible to the user as a flicker between the trigger disappearing
--- and the replacement arriving.
--- @param tx table Output transaction.
--- @param count integer Number of Backspace strokes to send.
local require_publication

local function send_backspaces(tx, count)
	if count < 1 then return end
	for _ = 1, count do
		must_emit(tx, EvdevCodes.KEY_BACKSPACE, EVDEV_VALUE_DOWN, "backspace down")
		must_emit(tx, EvdevCodes.KEY_BACKSPACE, EVDEV_VALUE_UP, "backspace up")
	end
end

--- Types a string as keystrokes, under the layout the session actually has.
---
--- This is the path that makes accented replacements work at all. uinput sends
--- keycodes and the compositor applies the user's XKB layout on top, so the
--- keycode for "é" is a property of THEIR layout, not of ours. ydotool assumes
--- US and produces gibberish on AZERTY, BÉPO, Dvorak and German — and this
--- driver's replacements are overwhelmingly accented French.
---
--- All-or-nothing by design. A plan that covered only the first few characters
--- would type half a replacement after the trigger had already been erased,
--- which is worse than not typing it: the user loses text they had.
--- @param tx table Output transaction.
--- @param text string
--- @return boolean True when the whole string was typed.
local function send_text_native(tx, text)
	if not (_uinput and _uinput.is_open()) then return false end
	if not KeyboardLayout.is_ready() then return false end

	local plan, blocker = KeyboardLayout.plan(text)
	if not plan then
		Logger.debug(LOG, "Layout cannot type %s — falling back.", tostring(blocker))
		return false
	end

	-- The plan is the chord for each character with CapsLock OFF. Typed under a
	-- locked CapsLock every letter inverts ("Bonjour" arrives as "bONJOUR"), and
	-- on Ergopti, whose type maps Lock to its own level, other keys change too.
	-- So the lock is released for the replacement and restored after it —
	-- restored even when an emit fails, or the user is left with CapsLock off.
	local caps = XkbCapture.caps_locked()
	if caps then
		must_emit(tx, EvdevCodes.KEY_CAPSLOCK, EVDEV_VALUE_DOWN, "capslock release down")
		must_emit(tx, EvdevCodes.KEY_CAPSLOCK, EVDEV_VALUE_UP, "capslock release up")
	end
	local ok_typed, typed_err = pcall(function()
		require_publication(tx.publication, false)
		for _, step in ipairs(plan) do
			for _, mod in ipairs(step.mods) do
				must_emit(tx, MODIFIER_CODES[mod], EVDEV_VALUE_DOWN, "layout modifier down")
			end
			must_emit(tx, step.keycode, EVDEV_VALUE_DOWN, "replacement key down")
			must_emit(tx, step.keycode, EVDEV_VALUE_UP, "replacement key up")
			-- Released in reverse, and always: a modifier left held after an
			-- interrupted injection turns every subsequent keystroke into a shortcut.
			for i = #step.mods, 1, -1 do
				must_emit(tx, MODIFIER_CODES[step.mods[i]], EVDEV_VALUE_UP, "layout modifier up")
			end
		end
	end)
	if caps then
		must_emit(tx, EvdevCodes.KEY_CAPSLOCK, EVDEV_VALUE_DOWN, "capslock restore down")
		must_emit(tx, EvdevCodes.KEY_CAPSLOCK, EVDEV_VALUE_UP, "capslock restore up")
	end
	if not ok_typed then error(typed_err, 0) end
	return true
end

--- Delivers a replacement.
---
--- Keystrokes first, clipboard second, and nothing third. ydotool used to be the
--- third and was never a fallback for the case that reaches one: it assumes a US
--- layout, so a character the layout cannot type is exactly the character
--- ydotool gets wrong. It also cannot run under the grab, because `ydotool type`
--- needs a daemon this driver no longer talks to.
---
--- The clipboard is deliberately the rare path now. Before the layout was
--- resolved it would have carried every accented replacement; it now carries
--- only what no key on the user's keyboard can produce. That is a better thing
--- to be rare, because pasting is visible, races clipboard managers, and
--- destroys what the user had copied unless it is put back.
--- @param tx table Output transaction.
--- @param text string
--- @param is_private boolean|nil True when `text` is PII and must not be logged.
--- @return boolean True when the whole payload was delivered.
local function send_text(tx, text, is_private)
	if send_text_native(tx, text) then return true end

	local pause = sleep_ms
	if tx.publication then
		pause = function(ms)
			require_publication(tx.publication, false)
			sleep_ms(ms)
			require_publication(tx.publication, false)
		end
	end
	require_publication(tx.publication, false)
	if Clipboard.paste_text(text, tx.channel(), pause) then
		Logger.debug(LOG, "Replacement delivered by clipboard (untypable on this layout).")
		return true
	end
	if tx.is_failed() then error(tx.error() or "clipboard paste chord failed", 0) end

	-- Reached only when the layout cannot type it AND there is no clipboard tool.
	-- Said loudly: the trigger has already been erased, so the user has lost text
	-- and deserves to know why rather than to wonder. For a private payload the
	-- loudness has to survive without the content, since this log is kept for 14
	-- days and the driver's default level prints it.
	if is_private then
		Logger.error(LOG,
			"Cannot deliver a private replacement — not typable on this layout and no clipboard route.")
	else
		Logger.error(LOG, "Cannot deliver '%s' — not typable on this layout and no clipboard route.", text)
	end
	tx.fail("replacement could not be delivered", "replacement")
	return false
end

--- Replays one non-consumed terminator after a replacement.
---
--- Enter and Tab are keystrokes, not text: sending them through the layout
--- planner has no answer and a clipboard paste would insert control characters
--- instead of activating the focused control. Printable terminators keep using
--- the normal layout-aware text path.
--- @param tx table Output transaction.
--- @param terminator string Exact carrier returned by the engine.
local function send_terminator(tx, terminator)
	local keycode = nil
	if terminator == "\n" or terminator == "\r" then
		keycode = EvdevCodes.KEY_ENTER
	elseif terminator == "\t" then
		keycode = EvdevCodes.KEY_TAB
	end

	if keycode then
		must_emit(tx, keycode, EVDEV_VALUE_DOWN, "terminator down")
		must_emit(tx, keycode, EVDEV_VALUE_UP, "terminator up")
		return
	end
	if not send_text(tx, terminator, false) then error(tx.error(), 0) end
end

local function stop_after_failure(result, label)
	Logger.error(LOG, "%s failed in %s — %s (cleanup_ok=%s).",
		label, tostring(result.failed_phase), tostring(result.error), tostring(result.cleanup_ok))
	local ok_hook, hook = pcall(require, "adapters.keyboard_hook")
	if ok_hook and type(hook.emergency_stop) == "function" then
		pcall(hook.emergency_stop, label .. ": " .. tostring(result.error))
	end
end

--- Requires retained programmable admission at an actual native output boundary.
--- @param publication table|nil Optional programmable publication owner.
--- @param cached boolean True for the RAM-only per-key fence.
require_publication = function(publication, cached)
	if publication == nil then return end
	local check = cached and publication.cached or publication.current
	local ok, current = pcall(check)
	if not ok or current ~= true then error("programmable publication is no longer current", 0) end
end

--- Runs one complete output transaction with unconditional cleanup.
--- @param label string Diagnostic operation name.
--- @param body function Called as body(transaction).
--- @return table Commit result.
local function run_transaction(label, body, publication)
	local native_tx = OutputTransaction.new(_uinput)
	local tx = native_tx
	if publication ~= nil then
		-- Cleanup remains on the original transaction wire, so a refused late
		-- publication never prevents owned key-ups or physical modifier restore.
		tx = setmetatable({ publication = publication,
			emit = function(code, value, phase)
				if value == EVDEV_VALUE_DOWN and phase ~= "capslock restore down" then
					require_publication(publication, true)
				end
				return native_tx.emit(code, value, phase)
			end,
		}, { __index = native_tx })
		tx.channel = function()
			local channel = native_tx.channel()
			return { is_open = channel.is_open,
				emit = function(code, value) return tx.emit(code, value, "clipboard paste chord") end }
		end
	end
	local ok, err = pcall(function()
		require_publication(publication, false)
		if not tx.neutralize(held_text_modifier_codes()) then error(tx.error(), 0) end
		-- Ctrl, Alt and Super are released for good: the chord that asked for
		-- this text (Alt+1 on a prediction) is spent, and text typed under them
		-- would be shortcuts. A masking tap comes first, so the release is not a
		-- lone Alt tap that would move the focus to the application's menu bar.
		local shortcut_modifiers = held_shortcut_modifier_codes()
		if #shortcut_modifiers > 0 then
			must_emit(tx, EvdevCodes.KEY_F24, EVDEV_VALUE_DOWN, "modifier mask")
			must_emit(tx, EvdevCodes.KEY_F24, EVDEV_VALUE_UP, "modifier mask")
			for _, code in ipairs(shortcut_modifiers) do
				must_emit(tx, code, EVDEV_VALUE_UP, "shortcut modifier release")
			end
		end
		-- Released, never restored: the key is the terminator the user already
		-- typed, and pressing it again would type it twice. Its physical release
		-- arrives later and is a harmless duplicate for the kernel.
		for _, code in ipairs(held_forwarded_keys()) do
			must_emit(tx, code, EVDEV_VALUE_UP, "held key release")
		end
		body(tx)
	end)
	if not ok and not tx.is_failed() then tx.fail(err, "unexpected exception") end
	local result = tx.finish()
	if not result.ok and not (publication ~= nil and result.cleanup_ok == true
		and result.error == "programmable publication is no longer current") then stop_after_failure(result, label) end
	return result
end



-- =========================================
-- =========================================
-- ======= 4/ Public API ===================
-- =========================================
-- =========================================

--- Input queue: characters queued during an in-flight injection so they are
--- replayed in order after the injection completes. Prevents physical keystrokes
--- from interleaving with synthetic backspace+replacement events.
local _input_queue = {}
local _injecting = false

--- Called by the daemon BEFORE inject() to signal that input should be queued.
--- Resets the queue so stale characters from a prior injection cycle cannot leak in.
function M._begin_injection()
	_input_queue = {}
	_injecting = true
end

--- Called by the daemon AFTER inject() completes. Returns any queued characters
--- and clears the queue, so the daemon can replay them through the engine in
--- arrival order.
--- @return table List of characters queued during the injection.
function M._end_injection()
	_injecting = false
	local drained = _input_queue
	_input_queue = {}
	return drained
end

--- Returns true while an injection is in flight.
--- @return boolean
function M._is_injecting()
	return _injecting
end

--- Queues a single character that arrived during an in-flight injection.
--- Safe to call when not injecting (no-op).
--- @param ch string|table Character, or { char, scancode } preserving input metadata.
function M._queue_char(ch)
	if _injecting then
		_input_queue[#_input_queue + 1] = ch
	end
end

--- Re-emits a single raw evdev key event through the uinput channel.
---
--- Only meaningful in the keyboard hook's intercept mode: EVIOCGRAB suppresses
--- delivery of the grabbed device to the desktop, which makes the daemon the
--- ONLY remaining path to the application. Every physical event it consumes must
--- therefore be put back, in arrival order, or the keyboard is dead.
---
--- There is ONE channel and no fallback. A subprocess per event was the previous
--- answer, and it is not an answer: under a grab that is a fork per physical
--- keystroke on the input path, which is the measured reason the daemon could
--- not grab in the first place. Batching is not an alternative either — the hook
--- re-emits an event and THEN dispatches it, so collapsing a batch would run an
--- injection triggered by event N before the re-emit of N, reintroducing exactly
--- the interleaving the grab exists to remove.
---
--- So when the channel is absent this refuses and says so, rather than degrading
--- into the cost that made the feature impossible. The daemon checks the channel
--- before it grabs, which is what keeps this branch from ever being reached with
--- a real keyboard behind it.
---
--- @param code  integer evdev keycode (input-event-codes.h KEY_*).
--- @param value integer 0 = release, 1 = press, 2 = autorepeat.
--- @return boolean True when the event reached the wire.
function M.emit_key(code, value)
	if type(code) ~= "number" or type(value) ~= "number" then
		Logger.error(LOG, "emit_key(): invalid arguments — code=%s value=%s.",
			tostring(code), tostring(value))
		return false
	end
	if not _uinput or not _uinput.is_open() then
		Logger.error(LOG, "emit_key(%s:%s): no uinput channel — the event cannot be put back.",
			tostring(code), tostring(value))
		return false
	end
	-- The autorepeat value is passed through unchanged: under a grab this is a
	-- pass-through, and a pass-through that rewrites what it passes is not one.
	return _uinput.emit(code, value)
end

--- Opens the non-forking uinput channel, if this system can provide one.
---
--- Called by the daemon before taking a grab. Returns false rather than raising
--- when FFI or /dev/uinput is unavailable; the daemon then exits with the reason
--- instead of grabbing a keyboard it has no way to give back.
--- @return boolean True when the non-forking channel is live.
function M.open_fast_channel()
	local ok_mod, mod = pcall(require, "adapters.uinput_writer")
	if not ok_mod or type(mod) ~= "table" then
		Logger.error(LOG, "uinput_writer unavailable — there is no way to emit keys.")
		return false
	end
	if not mod.is_available() then
		Logger.error(LOG, "No uinput channel on this system — /dev/uinput needs the "
			.. "uinput group and the module loaded (bash install.sh --setup-perms).")
		return false
	end
	if not mod.open() then
		Logger.error(LOG, "uinput channel could not be opened — check /dev/uinput permissions.")
		return false
	end
	local Broker = require("adapters.modifier_broker")
	if not Broker.attach(mod) then
		mod.close()
		Logger.error(LOG, "The acknowledged output channel could not be reserved.")
		return false
	end
	_uinput = mod
	Logger.success(LOG, "Non-forking uinput channel open.")
	return true
end

--- Returns the exact shared output owner installed before native input opens.
--- @return table|nil broker
function M.output_broker()
	return _uinput and require("adapters.modifier_broker").for_channel(_uinput) or nil
end

--- Closes the non-forking channel, if one is open.
function M.close_fast_channel()
	if not _uinput then return end
	local Broker = require("adapters.modifier_broker")
	if Broker.for_channel(_uinput) then
		local acknowledged = _uinput.close() == true
		if not acknowledged and (not _uinput.is_open()) and not _uinput.has_output_debt() then acknowledged = true end
		if not acknowledged then
			Logger.error(LOG, "Output channel retirement remains unacknowledged.")
			return false
		end
		Broker.detach(_uinput)
	else _uinput.close() end
	_uinput = nil
	Logger.done(LOG, "Non-forking uinput channel closed.")
	return true
end

--- Test seam: injects (or clears) the uinput channel without touching /dev.
--- @param mod table|nil A module exposing is_open() and emit(code, value).
function M._set_uinput(mod)
	_uinput = mod
end

--- Performs a hotstring injection: erases the trigger then types the replacement.
---
--- This is the primary entry point called by the daemon on each match.
---
--- @param backspace_count  integer  Number of Backspace keystrokes to emit.
--- @param replacement_text string   The replacement string to type.
--- @param is_private       boolean|nil True when the replacement is PII. It
---   changes nothing about what is TYPED — only about what is written to the
---   log, which the driver keeps for 14 days at a level that prints TRACE.
--- @param replay_terminator string|nil Exact non-consumed carrier to type last.
--- @param publication table|nil Retained full-phase and cached-key admission guards.
function M.inject(backspace_count, replacement_text, is_private, replay_terminator, publication)
	if type(backspace_count) ~= "number" or type(replacement_text) ~= "string"
			or (replay_terminator ~= nil and type(replay_terminator) ~= "string") then
		-- The TYPES, not the values. This branch is reached BECAUSE the arguments
		-- are not what was expected, so neither position can be trusted to hold a
		-- non-secret — a caller that swapped them puts the payload in the count.
		-- The types are also the whole diagnosis here: the fault is always "a
		-- string where a number goes", never a particular string.
		Logger.error(
			LOG,
			"inject(): invalid arguments — bc is %s, text is %s.",
			type(backspace_count),
			type(replacement_text)
		)
		return { ok = false, error = "invalid arguments", cleanup_ok = true }
	end

	if is_private then
		Logger.trace(LOG, "inject(): bc=%d, private text (content withheld)…", backspace_count)
	else
		Logger.trace(LOG, "inject(): bc=%d text='%s'…", backspace_count, replacement_text)
	end

	local result = run_transaction("inject()", function(tx)
		-- Phase 1: erase the trigger (and terminator if consumed).
		if backspace_count > 0 then
			send_backspaces(tx, backspace_count)
			-- Brief pause to let the target process the deletions.
			sleep_ms(INTER_PHASE_DELAY_MS)
		end

		require_publication(publication, false)
		-- Phase 2: type the replacement.
		if not send_text(tx, replacement_text, is_private) then error(tx.error(), 0) end
		if replay_terminator and replay_terminator ~= "" then
			require_publication(publication, false)
			send_terminator(tx, replay_terminator)
		end
	end, publication)

	if result.ok then Logger.done(LOG, "inject(): done (bc=%d).", backspace_count) end
	return result
end

--- Whether the session's layout types a text with key presses alone, the one
--- route that never touches the clipboard.
--- @param text string
--- @return boolean
function M.can_type_directly(text)
	return type(text) == "string" and text ~= "" and KeyboardLayout.is_ready()
		and KeyboardLayout.plan(text) ~= nil
end

--- Types a text in place of a key the keyboard hook consumed: key presses
--- only, never the clipboard. A key typing another character is a keystroke,
--- decided inside the hook and repeated at typing speed — a paste would spawn
--- the clipboard tools on each press, fill the clipboard history and wait on
--- them in the hook — and a character the layout cannot type is not typed at
--- all: nothing is sent and the caller lets the key through. Only a uinput
--- write that fails midway stops the grab, as for every injection, since a
--- keyboard the daemon holds and cannot write to must be given back.
--- @param text string
--- @return table result { ok, error, cleanup_ok }; error "untypable" when no
---   key press sequence exists, with nothing sent.
function M.type_directly(text)
	if not M.can_type_directly(text) then
		return { ok = false, error = "untypable", cleanup_ok = true }
	end
	if not (_uinput and _uinput.is_open()) then
		return { ok = false, error = "no uinput channel", cleanup_ok = true }
	end
	return run_transaction("type_directly()", function(tx)
		if not send_text_native(tx, text) then error(tx.error() or "the key presses were refused", 0) end
	end)
end

--- Types several values separated by a real Tab KEYSTROKE.
---
--- WHY NOT JUST inject() WITH "\t" IN THE TEXT: the text path resolves every
--- character against the session's XKB layout, and U+0009 is a control code no
--- layout maps — so the whole replacement would fail the plan and fall through
--- to the CLIPBOARD, which pastes a literal tab character. In a form that
--- inserts whitespace instead of moving to the next field, which is the one
--- thing a multi-field expansion exists to do. macOS reached the same
--- conclusion: its personal_info expansion fires `keyStroke tab` between parts
--- rather than embedding one.
---
--- The Tab goes BETWEEN values and never after the last, so the caret ends in
--- the field the user is looking at. Windows and macOS both settled there.
--- @param backspace_count integer Characters to erase before typing.
--- @param values table Array of strings, in the order they are typed.
--- @param is_private boolean|nil True when the values are PII and must not be logged.
function M.inject_fields(backspace_count, values, is_private)
	if type(backspace_count) ~= "number" or type(values) ~= "table" then
		Logger.error(LOG, "inject_fields(): invalid arguments — bc is %s, values is %s.",
			type(backspace_count), type(values))
		return { ok = false, error = "invalid arguments", cleanup_ok = true }
	end
	if #values == 0 then
		Logger.error(LOG, "inject_fields(): no values — the trigger would be erased for nothing.")
		return { ok = false, error = "no values", cleanup_ok = true }
	end

	-- One value is the ordinary case and needs no Tab at all; routing it through
	-- inject() keeps a single implementation of the modifier neutralisation, the
	-- two-phase timing and the clipboard fallback.
	if #values == 1 then
		return M.inject(backspace_count, values[1], is_private)
	end

	if is_private then
		Logger.trace(LOG, "inject_fields(): bc=%d, %d private field(s) (content withheld)…",
			backspace_count, #values)
	else
		Logger.trace(LOG, "inject_fields(): bc=%d, %d field(s)…", backspace_count, #values)
	end

	local result = run_transaction("inject_fields()", function(tx)
		if backspace_count > 0 then
			send_backspaces(tx, backspace_count)
			sleep_ms(INTER_PHASE_DELAY_MS)
		end

		for index, value in ipairs(values) do
			if not send_text(tx, value, is_private) then error(tx.error(), 0) end
			if index < #values then
				must_emit(tx, EvdevCodes.KEY_TAB, EVDEV_VALUE_DOWN, "field Tab down")
				must_emit(tx, EvdevCodes.KEY_TAB, EVDEV_VALUE_UP, "field Tab up")
				-- The focus change a Tab causes is asynchronous in most toolkits;
				-- typing into the old field because the new one has not been given
				-- focus yet is the failure this delay buys off. Same constant the
				-- backspace phase uses, for the same reason.
				sleep_ms(INTER_PHASE_DELAY_MS)
			end
		end
	end)

	if result.ok then
		Logger.done(LOG, "inject_fields(): done (bc=%d, %d field(s)).", backspace_count, #values)
	end
	return result
end

-- The Left arrow, from the control-key names (one source for the code): the
-- tone actions re-select the text they typed with Shift+Left.
local KEY_LEFT = nil
for code, name in pairs(EvdevCodes.CONTROL_NAME_OF) do
	if name == "left" then KEY_LEFT = code end
end
if not KEY_LEFT then error("infra.evdev_codes names no Left arrow") end

-- Code point ranges that extend the character before them instead of starting
-- a new one: combining marks, variation selectors, emoji skin tones and tag
-- characters. A caret steps over the whole cluster with one Left arrow.
local CLUSTER_EXTENDERS = {
	{ 0x0300, 0x036F }, { 0x1AB0, 0x1AFF }, { 0x1DC0, 0x1DFF }, { 0x20D0, 0x20FF },
	{ 0xFE00, 0xFE0F }, { 0xFE20, 0xFE2F }, { 0x1F3FB, 0x1F3FF }, { 0xE0020, 0xE007F },
	{ 0xE0100, 0xE01EF },
}
local ZERO_WIDTH_JOINER = 0x200D
local REGIONAL_INDICATOR_FIRST, REGIONAL_INDICATOR_LAST = 0x1F1E6, 0x1F1FF

--- Whether a code point extends the cluster before it.
--- @param code integer
--- @return boolean
local function extends_cluster(code)
	if code == ZERO_WIDTH_JOINER then return true end
	for _, range in ipairs(CLUSTER_EXTENDERS) do
		if code >= range[1] and code <= range[2] then return true end
	end
	return false
end

--- How many Left arrows move the caret back over `text`.
---
--- GTK, Qt, Chromium and Firefox move the caret by user-perceived character
--- (grapheme cluster), not by byte or UTF-16 unit: "é" is one step whether it
--- is one code point or "e" plus a combining accent, and an emoji with a skin
--- tone, a ZWJ family or a flag is one step too. Counting code points instead
--- would re-select one character too many per accent or emoji, taking text the
--- rewrite never typed. The clusters are those of the rules above, which cover
--- what a rewrite produces; "\r\n" is one step.
--- @param text string Valid UTF-8.
--- @return integer steps
function M.caret_steps(text)
	if type(text) ~= "string" then error("caret_steps expects a string, got " .. type(text)) end
	local steps, previous, regional_open, after_joiner = 0, nil, false, false
	for sequence in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		local byte, code = sequence:byte(1), 0
		if byte < 0x80 then code = byte
		elseif byte < 0xE0 then code = (byte - 0xC0) * 0x40 + (sequence:byte(2) - 0x80)
		elseif byte < 0xF0 then
			code = ((byte - 0xE0) * 0x40 + (sequence:byte(2) - 0x80)) * 0x40 + (sequence:byte(3) - 0x80)
		else
			code = (((byte - 0xF0) * 0x40 + (sequence:byte(2) - 0x80)) * 0x40
				+ (sequence:byte(3) - 0x80)) * 0x40 + (sequence:byte(4) - 0x80)
		end
		local regional = code >= REGIONAL_INDICATOR_FIRST and code <= REGIONAL_INDICATOR_LAST
		local joins = previous ~= nil and (extends_cluster(code) or after_joiner
			or (previous == 0x0D and code == 0x0A) or (regional and regional_open))
		if not joins then steps = steps + 1 end
		-- A flag is a PAIR of regional indicators: the third starts a new flag.
		regional_open = regional and not (joins and regional_open)
		after_joiner = code == ZERO_WIDTH_JOINER
		previous = code
	end
	return steps
end

--- Types a text over the focused selection, then selects exactly what it typed.
---
--- Shift+Left per caret step, in the same transaction and on the same channel
--- as the text, so a keystroke from elsewhere cannot land between them. The
--- tone actions keep their rewrite selected this way, so the next step applies
--- to it.
--- @param text string Non-empty text to type.
--- @param is_private boolean|nil True when `text` must not be logged.
--- @return table Commit result { ok, error?, cleanup_ok }.
function M.inject_selected(text, is_private)
	if type(text) ~= "string" or text == "" then
		Logger.error(LOG, "inject_selected(): text is %s, expected a non-empty string.", type(text))
		return { ok = false, error = "invalid arguments", cleanup_ok = true }
	end
	local steps = M.caret_steps(text)
	local result = run_transaction("inject_selected()", function(tx)
		if not send_text(tx, text, is_private) then error(tx.error(), 0) end
		-- The typed text must reach the application before it is selected back.
		sleep_ms(INTER_PHASE_DELAY_MS)
		must_emit(tx, EvdevCodes.KEY_LEFTSHIFT, EVDEV_VALUE_DOWN, "selection shift down")
		for _ = 1, steps do
			must_emit(tx, KEY_LEFT, EVDEV_VALUE_DOWN, "selection left down")
			must_emit(tx, KEY_LEFT, EVDEV_VALUE_UP, "selection left up")
		end
		must_emit(tx, EvdevCodes.KEY_LEFTSHIFT, EVDEV_VALUE_UP, "selection shift up")
	end)
	if result.ok then Logger.done(LOG, "inject_selected(): done (%d step(s) selected).", steps) end
	return result
end

return M
