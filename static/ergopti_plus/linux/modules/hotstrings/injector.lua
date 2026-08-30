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
local Clipboard = require("adapters.clipboard")

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
local MODIFIER_CODES = {
	shift = EvdevCodes.KEY_LEFTSHIFT,
	altgr = EvdevCodes.KEY_RIGHTALT,
}


-- =========================================
-- =========================================
-- ======= 3/ Internal Helpers =============
-- =========================================
-- =========================================

--- The driver's uinput channel, once opened. It is the ONLY output path: nil
--- means the daemon cannot put a key back, cannot erase a trigger and cannot
--- type a replacement, which is why the daemon refuses to grab without it.
local _uinput = nil

--- The layout-level modifiers the user is physically holding, from the hook that
--- tracks them. Required lazily so this module still loads in a harness that has
--- no hook, where the answer is simply "none".
--- @return table Array of "shift" / "altgr".
local function held_text_modifiers()
	local ok, hook = pcall(require, "adapters.keyboard_hook")
	if not ok or type(hook.held_text_modifiers) ~= "function" then return {} end
	local ok_call, held = pcall(hook.held_text_modifiers)
	return (ok_call and type(held) == "table") and held or {}
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
--- @param count integer Number of Backspace strokes to send.
local function send_backspaces(count)
	if count < 1 then return end

	if _uinput and _uinput.is_open() then
		for _ = 1, count do
			_uinput.emit(EvdevCodes.KEY_BACKSPACE, EVDEV_VALUE_DOWN)
			_uinput.emit(EvdevCodes.KEY_BACKSPACE, EVDEV_VALUE_UP)
		end
		return
	end

	-- No fallback, for the same reason emit_key has none: the daemon refuses to
	-- grab without this channel, so a closed one here means an injection that
	-- should never have been attempted.
	Logger.error(LOG, "send_backspaces(%d): no uinput channel — the trigger cannot be erased.", count)
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
--- @param text string
--- @return boolean True when the whole string was typed.
local function send_text_native(text)
	if not (_uinput and _uinput.is_open()) then return false end
	if not KeyboardLayout.is_ready() then return false end

	local plan, blocker = KeyboardLayout.plan(text)
	if not plan then
		Logger.debug(LOG, "Layout cannot type %s — falling back.", tostring(blocker))
		return false
	end

	for _, step in ipairs(plan) do
		for _, mod in ipairs(step.mods) do
			_uinput.emit(MODIFIER_CODES[mod], EVDEV_VALUE_DOWN)
		end
		_uinput.emit(step.keycode, EVDEV_VALUE_DOWN)
		_uinput.emit(step.keycode, EVDEV_VALUE_UP)
		-- Released in reverse, and always: a modifier left held after an
		-- interrupted injection turns every subsequent keystroke into a shortcut.
		for i = #step.mods, 1, -1 do
			_uinput.emit(MODIFIER_CODES[step.mods[i]], EVDEV_VALUE_UP)
		end
	end
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
--- @param text string
--- @param is_private boolean|nil True when `text` is PII and must not be logged.
local function send_text(text, is_private)
	if send_text_native(text) then return end

	if Clipboard.paste_text(text, _uinput, sleep_ms) then
		Logger.debug(LOG, "Replacement delivered by clipboard (untypable on this layout).")
		return
	end

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
end

--- Replays one non-consumed terminator after a replacement.
---
--- Enter and Tab are keystrokes, not text: sending them through the layout
--- planner has no answer and a clipboard paste would insert control characters
--- instead of activating the focused control. Printable terminators keep using
--- the normal layout-aware text path.
--- @param terminator string Exact carrier returned by the engine.
local function send_terminator(terminator)
	local keycode = nil
	if terminator == "\n" or terminator == "\r" then
		keycode = EvdevCodes.KEY_ENTER
	elseif terminator == "\t" then
		keycode = EvdevCodes.KEY_TAB
	end

	if keycode then
		_uinput.emit(keycode, EVDEV_VALUE_DOWN)
		_uinput.emit(keycode, EVDEV_VALUE_UP)
		return
	end
	send_text(terminator, false)
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
	_uinput = mod
	Logger.success(LOG, "Non-forking uinput channel open.")
	return true
end

--- Closes the non-forking channel, if one is open.
function M.close_fast_channel()
	if not _uinput then return end
	_uinput.close()
	_uinput = nil
	Logger.done(LOG, "Non-forking uinput channel closed.")
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
function M.inject(backspace_count, replacement_text, is_private, replay_terminator)
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
		return
	end

	if is_private then
		Logger.trace(LOG, "inject(): bc=%d, private text (content withheld)…", backspace_count)
	else
		Logger.trace(LOG, "inject(): bc=%d text='%s'…", backspace_count, replacement_text)
	end

	local ok, err = pcall(function()
		-- Neutralise whatever the user is physically holding. Under a grab the
		-- application has already seen the press we re-emitted, so it believes
		-- Shift is down: an injected "e" would arrive as "E", and under AltGr as
		-- "€". Waiting for the user to let go is not an option — the release event
		-- is in the kernel buffer this injection is currently not reading.
		local held = held_text_modifiers()
		for _, mod in ipairs(held) do
			_uinput.emit(MODIFIER_CODES[mod], EVDEV_VALUE_UP)
		end

		-- Phase 1: erase the trigger (and terminator if consumed).
		if backspace_count > 0 then
			send_backspaces(backspace_count)
			-- Brief pause to let the target process the deletions.
			sleep_ms(INTER_PHASE_DELAY_MS)
		end

		-- Phase 2: type the replacement.
		send_text(replacement_text, is_private)
		if replay_terminator and replay_terminator ~= "" then
			send_terminator(replay_terminator)
		end

		-- Put them back, so a user who was still holding Shift when the expansion
		-- fired keeps holding it afterwards. Restored in reverse for symmetry with
		-- how every other modifier pair in this file is emitted.
		for i = #held, 1, -1 do
			_uinput.emit(MODIFIER_CODES[held[i]], EVDEV_VALUE_DOWN)
		end
	end)

	if not ok then
		Logger.error(LOG, "inject(): unexpected error — %s.", tostring(err))
		return
	end

	Logger.done(LOG, "inject(): done (bc=%d).", backspace_count)
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
		return
	end
	if #values == 0 then
		Logger.error(LOG, "inject_fields(): no values — the trigger would be erased for nothing.")
		return
	end

	-- One value is the ordinary case and needs no Tab at all; routing it through
	-- inject() keeps a single implementation of the modifier neutralisation, the
	-- two-phase timing and the clipboard fallback.
	if #values == 1 then
		M.inject(backspace_count, values[1], is_private)
		return
	end

	if is_private then
		Logger.trace(LOG, "inject_fields(): bc=%d, %d private field(s) (content withheld)…",
			backspace_count, #values)
	else
		Logger.trace(LOG, "inject_fields(): bc=%d, %d field(s)…", backspace_count, #values)
	end

	local ok, err = pcall(function()
		-- Same reason as inject(): under a grab the application already believes
		-- the physically-held modifiers are down, so an injected "e" arrives as "E".
		local held = held_text_modifiers()
		for _, mod in ipairs(held) do
			_uinput.emit(MODIFIER_CODES[mod], EVDEV_VALUE_UP)
		end

		if backspace_count > 0 then
			send_backspaces(backspace_count)
			sleep_ms(INTER_PHASE_DELAY_MS)
		end

		for index, value in ipairs(values) do
			send_text(value, is_private)
			if index < #values then
				_uinput.emit(EvdevCodes.KEY_TAB, EVDEV_VALUE_DOWN)
				_uinput.emit(EvdevCodes.KEY_TAB, EVDEV_VALUE_UP)
				-- The focus change a Tab causes is asynchronous in most toolkits;
				-- typing into the old field because the new one has not been given
				-- focus yet is the failure this delay buys off. Same constant the
				-- backspace phase uses, for the same reason.
				sleep_ms(INTER_PHASE_DELAY_MS)
			end
		end

		for i = #held, 1, -1 do
			_uinput.emit(MODIFIER_CODES[held[i]], EVDEV_VALUE_DOWN)
		end
	end)

	if not ok then
		Logger.error(LOG, "inject_fields(): unexpected error — %s.", tostring(err))
		return
	end

	Logger.done(LOG, "inject_fields(): done (bc=%d, %d field(s)).", backspace_count, #values)
end

return M
