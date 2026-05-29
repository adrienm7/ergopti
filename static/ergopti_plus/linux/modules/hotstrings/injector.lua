--- static/ergopti_plus/linux/modules/hotstrings/injector.lua

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

--- Runs a shell command, discarding stdout and stderr.
--- Returns true on exit code 0, false otherwise.
--- @param cmd string Shell command string.
--- @return boolean
local function shell_run(cmd)
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

--- Sleeps for the given number of milliseconds using the POSIX sleep command.
--- @param ms integer Milliseconds to sleep.
local function sleep_ms(ms)
	if ms <= 0 then return end
	-- /bin/sleep accepts fractional seconds on Linux (GNU coreutils).
	local sec = ms / 1000
	pcall(os.execute, string.format("sleep %.3f", sec))
end


-- =========================================
-- =========================================
-- ======= 4/ Public API ===================
-- =========================================
-- =========================================

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
