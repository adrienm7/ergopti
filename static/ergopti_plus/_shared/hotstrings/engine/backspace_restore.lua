--- _shared/hotstrings/engine/backspace_restore.lua

--- ==============================================================================
--- MODULE: Backspace Restore Rule (shared)
--- DESCRIPTION:
--- Decides what a Backspace pressed right after an expansion gives back, and
--- until when it still does. The macOS expander and the Linux daemon call it;
--- the AutoHotkey port replays the same vectors
--- (_shared/tests/corpus/hotstrings/backspace_restore_vectors.json).
---
--- FEATURES & RATIONALE:
--- 1. The magic key is an action, not text: a trigger it ended (« td★ ») comes
---    back without it (« td »), and the repeat key's lone ★ gives nothing back.
--- 2. A terminator typed after the output (Space, punctuation, Enter) is part
---    of what the user typed: « adn » and Space come back as « adn » and Space,
---    not as the output followed by Space. A consumed terminator was never
---    typed and does not come back.
--- 3. The undo lasts hotstrings.backspace_restore_window_ms after the
---    expansion, inclusive; past it the Backspace deletes the last character.
---    Any other key ends it earlier: each driver drops its record on that key.
--- ==============================================================================

local M = {}




-- ===============================
-- ===============================
-- ======= 1/ The rule ===========
-- ===============================
-- ===============================

--- The text a restore types back.
--- @param trigger string What the user typed for the expansion, as on screen.
--- @param magic_key string|nil The magic key in effect.
--- @param replayed string|nil The terminator typed back after the output.
--- @return string text The trigger without a final magic key, then the terminator.
function M.restored_text(trigger, magic_key, replayed)
	if type(trigger) ~= "string" then
		error("backspace_restore.restored_text: the trigger must be a string", 2)
	end
	if replayed ~= nil and type(replayed) ~= "string" then
		error("backspace_restore.restored_text: the replayed terminator must be a string", 2)
	end
	local text = trigger
	if type(magic_key) == "string" and magic_key ~= "" and #text >= #magic_key
		and text:sub(-#magic_key) == magic_key then
		text = text:sub(1, #text - #magic_key)
	end
	return text .. (replayed or "")
end

--- Whether a window value is admissible: a whole positive number of milliseconds.
--- @param window_ms any
--- @return boolean
function M.valid_window_ms(window_ms)
	return type(window_ms) == "number" and window_ms >= 1 and window_ms == math.floor(window_ms)
		and window_ms < math.huge
end

--- Whether a Backspace at now_ms still undoes an expansion committed at committed_ms.
--- @param committed_ms number Monotonic time of the expansion's commit.
--- @param now_ms number Monotonic time of the Backspace.
--- @param window_ms number hotstrings.backspace_restore_window_ms.
--- @return boolean
function M.within_window(committed_ms, now_ms, window_ms)
	if not M.valid_window_ms(window_ms) then
		error("backspace_restore.within_window: the window must be a whole positive number of milliseconds", 2)
	end
	if type(committed_ms) ~= "number" or type(now_ms) ~= "number" then
		error("backspace_restore.within_window: the times must be numbers", 2)
	end
	local elapsed = now_ms - committed_ms
	return elapsed >= 0 and elapsed <= window_ms
end

return M
