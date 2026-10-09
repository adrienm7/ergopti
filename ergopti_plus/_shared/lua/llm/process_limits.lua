--- _shared/lua/llm/process_limits.lua

--- Canonical default policy shared by logical and physical process owners.
--- Explicit caller budgets/cadences remain authoritative after strict validation.
local M = {}

--- Returns detached defaults; callers cannot mutate another owner's policy.
--- The 25 ms worker default preserves the existing finite compatibility API.
--- Production AI composition passes its canonical llm timing explicitly.
--- Group observation remains referenced until real exit/ESRCH/close receipts.
function M.defaults()
	return { worker_retry_ms = 25, group_recheck_ms = 25, max_output_bytes = 65536 }
end

return M
