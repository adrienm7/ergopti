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


-- =========================================
-- =========================================
-- ======= 3/ Internal Helpers =============
-- =========================================
-- =========================================

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

--- Emits count Backspace keystrokes via ydotool key.
--- @param count integer Number of Backspace strokes to send.
local function send_backspaces(count)
	if count < 1 then return end
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

--- Injects a text string via ydotool type.
--- The replacement is passed as a single argument after -- to prevent any
--- leading hyphens in the text from being parsed as flags.
--- @param text string The replacement text to type.
local function send_text(text)
	-- Escape single quotes for safe shell embedding.
	local safe = text:gsub("'", "'\\''")
	local cmd  = string.format(
		"ydotool type --key-delay=%d --clearmodifiers -- '%s'",
		YDOTOOL_KEY_DELAY_MS,
		safe
	)
	local success = shell_run(cmd)
	if not success then
		Logger.warn(LOG, "send_text(): ydotool type returned non-zero for text '%s'.", text)
	end
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
