--- hotstrings/engine/commit_followup.lua

--- ==============================================================================
--- MODULE: Hotstring Commit Follow-up (Linux)
--- DESCRIPTION:
--- Decides what the engine keeps once an expansion's output has committed: the
--- expanded text for chaining, only the AI context for a final result, nothing
--- for key tokens, and nothing for an action entry, whose action then runs out
--- of the key callback (hotstrings/engine/action_runner.lua).
---
--- FEATURES & RATIONALE:
--- 1. Its own owner: the daemon's main() sits at LuaJIT's 60-upvalue budget,
---    and the action wiring inlined there pushed it to 61, so the entry point
---    no longer compiled. main() requires this one owner as a local for the
---    whole follow-up, whatever the follow-up learns to do next.
--- ==============================================================================

local ActionRunner = require("hotstrings.engine.action_runner")

local M = {}




-- ===================================
-- ===================================
-- ======= 1/ Follow-up ==============
-- ===================================
-- ===================================

--- Applies the follow-up of a committed match result to the engine.
--- @param engine table The hotstring engine (reset, apply_expansion).
--- @param result table The committed match result.
--- @param deps table|nil { run_action } (tests).
--- @return boolean True when the context changed, so no undo may restore the trigger.
function M.apply(engine, result, deps)
	if type(engine) ~= "table" or type(result) ~= "table" then
		error("commit_followup.apply needs the engine and the committed result", 2)
	end
	if result.action then
		-- The edit has landed and the action runs next. It changes the context,
		-- so nothing chains and no undo restores a trigger it may have acted on.
		engine:reset(false)
		local run_action = deps and deps.run_action or ActionRunner.run
		run_action(result)
		return true
	end
	if result.has_key_tokens then
		-- The caret is somewhere the engine never saw: neither the word buffer
		-- nor the AI context can describe the text behind it.
		engine:reset(false)
	elseif result.final_result then
		-- The field holds the replacement whether or not the matcher may chain
		-- off it: the AI context mirrors it, then only the word buffer is dropped.
		engine:apply_expansion(result)
		engine:reset(nil, nil, "keep")
	else
		engine:apply_expansion(result)
	end
	return false
end

return M
