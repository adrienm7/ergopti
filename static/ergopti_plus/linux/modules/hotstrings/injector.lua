--- modules/hotstrings/injector.lua

--- ==============================================================================
--- MODULE: Hotstring Injector (Linux)
--- DESCRIPTION:
--- OS-facing module responsible for replaying hotstring expansions into the
--- currently focused application on Linux. Given a backspace count and a
--- replacement string, it erases the typed trigger then inserts the replacement
--- text via ydotool (uinput), which works on both X11 and Wayland sessions.
---
--- FEATURES & RATIONALE:
--- 1. Two-phase injection: first emits N Backspace keystrokes to erase the
---    trigger (plus the terminator when consumed), then types the replacement.
--- 2. ydotool dependency: ydotool communicates with the ydotoold daemon via a
---    Unix socket, providing uinput-level injection that works on Wayland where
---    xdotool cannot send events to other windows.
--- 3. Defensive pcall: every os.execute call is wrapped so an injection failure
---    never propagates to the engine or crashes the daemon.
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

-- Kernel keycode for Backspace (KEY_BACKSPACE = 14 in input-event-codes.h).
-- ydotool key format: <keycode>:<value> where value 1=down, 0=up.
local YDOTOOL_BACKSPACE_DOWN = "14:1"
local YDOTOOL_BACKSPACE_UP   = "14:0"

-- Milliseconds to pause between the backspace phase and the type phase.
-- Allows slow applications to process the deletes before new characters arrive.
local INTER_PHASE_DELAY_MS = 20

-- ydotool --key-delay: milliseconds between synthesised key events.
-- 0 is fastest but can cause drops in some applications; 12 ms is reliable.
local YDOTOOL_KEY_DELAY_MS = 12

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

--- The non-forking uinput channel, when one has been opened. nil means emit_key
--- falls back to one `ydotool key` subprocess per event — correct, but far too
--- expensive to run under a keyboard grab.
local _uinput = nil

--- Test seam: when set, shell_run delegates to this function instead of os.execute.
--- The function receives the raw shell command string and must return a boolean.
--- Set via M._set_runner(fn); reset via M._reset_runner().
local _test_runner = nil

--- Runs a shell command, discarding stdout and stderr.
--- Returns true on exit code 0, false otherwise.
--- @param cmd string Shell command string.
--- @return boolean
local function shell_run(cmd)
	if _test_runner then
		return _test_runner(cmd)
	end
	local ok, result = pcall(function()
		return os.execute(cmd .. " 2>/dev/null")
	end)
	return ok and (result == true or result == 0)
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

	-- Build a space-separated list of down/up pairs for a single ydotool call.
	-- This is faster than count separate process spawns.
	local parts = {}
	for _ = 1, count do
		parts[#parts + 1] = YDOTOOL_BACKSPACE_DOWN
		parts[#parts + 1] = YDOTOOL_BACKSPACE_UP
	end
	local key_sequence = table.concat(parts, " ")
	local cmd = string.format("ydotool key %s", key_sequence)
	local success = shell_run(cmd)
	if not success then
		Logger.warn(LOG, "send_backspaces(%d): ydotool key returned non-zero.", count)
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

--- Injects a text string via ydotool type.
--- The replacement is passed as a single argument after -- to prevent any
--- leading hyphens in the text from being parsed as flags.
---
--- NOTE: --clearmodifiers used to be passed here. It is xdotool vocabulary, not
--- ydotool's, so ydotool rejected the whole invocation — and because the erase
--- phase runs FIRST, every successful match deleted the user's trigger and then
--- typed nothing. A silent data loss on the happy path, logged as one WARN.
--- @param text string The replacement text to type.
local function send_text_ydotool(text)
	-- Escape single quotes for safe shell embedding.
	local safe = text:gsub("'", "'\\''")
	local cmd  = string.format(
		"ydotool type --key-delay=%d -- '%s'",
		YDOTOOL_KEY_DELAY_MS,
		safe
	)
	local success = shell_run(cmd)
	if not success then
		Logger.warn(LOG, "send_text(): ydotool type returned non-zero for text '%s'.", text)
	end
end

--- Types a replacement, preferring the layout-aware path.
--- @param text string
local function send_text(text)
	if send_text_native(text) then return end
	send_text_ydotool(text)
end

--- Sleeps for the given number of milliseconds without forking or spinning.
--- Prefers luv.sleep (libuv uv_sleep, a nanosleep that yields the core) so the
--- single-threaded input path pays no /bin/sleep fork per injection. Falls back
--- to a forked sleep only when luv is unavailable — that still yields the CPU.
--- Never busy-waits on the standard CPU clock: on Linux it reports process CPU
--- time, so spinning on it would burn a full core for the delay, not yield.
--- @param ms integer Milliseconds to sleep.
local function sleep_ms(ms)
	if ms <= 0 then return end
	if luv and type(luv.sleep) == "function" then
		luv.sleep(ms)
		return
	end
	-- Fallback path (luv absent): fork /bin/sleep, which yields the CPU. Fractional
	-- seconds are GNU coreutils syntax.
	pcall(os.execute, string.format("sleep %.3f", ms / 1000))
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

--- Replaces the low-level shell runner with a custom function (test seam).
--- The function receives the raw shell command and must return a boolean.
--- @param fn function|nil Custom runner; nil to use the default.
function M._set_runner(fn)
	_test_runner = fn
end

--- Restores the default (os.execute) shell runner.
function M._reset_runner()
	_test_runner = nil
end

--- Re-emits a single raw evdev key event through the ydotool uinput channel.
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
--- when FFI or /dev/uinput is unavailable, and emit_key() then keeps using
--- ydotool — correct, just one fork per event, which is only affordable while
--- the daemon is NOT grabbing.
--- @return boolean True when the non-forking channel is live.
function M.open_fast_channel()
	local ok_mod, mod = pcall(require, "adapters.uinput_writer")
	if not ok_mod or type(mod) ~= "table" then
		Logger.debug(LOG, "uinput_writer unavailable — keeping the ydotool channel.")
		return false
	end
	if not mod.is_available() then
		Logger.info(LOG, "No uinput channel on this system — keeping the ydotool channel "
			.. "(one subprocess per event, so the daemon must not take a grab).")
		return false
	end
	if not mod.open() then
		Logger.warn(LOG, "uinput channel could not be opened — keeping the ydotool channel.")
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
function M.inject(backspace_count, replacement_text)
	if type(backspace_count) ~= "number" or type(replacement_text) ~= "string" then
		Logger.error(
			LOG,
			"inject(): invalid arguments — bc=%s text=%s.",
			tostring(backspace_count),
			tostring(replacement_text)
		)
		return
	end

	Logger.trace(LOG, "inject(): bc=%d text='%s'…", backspace_count, replacement_text)

	local ok, err = pcall(function()
		-- Phase 1: erase the trigger (and terminator if consumed).
		if backspace_count > 0 then
			send_backspaces(backspace_count)
			-- Brief pause to let the target process the deletions.
			sleep_ms(INTER_PHASE_DELAY_MS)
		end

		-- Phase 2: type the replacement.
		send_text(replacement_text)
	end)

	if not ok then
		Logger.error(LOG, "inject(): unexpected error — %s.", tostring(err))
		return
	end

	Logger.done(LOG, "inject(): done (bc=%d).", backspace_count)
end

return M
