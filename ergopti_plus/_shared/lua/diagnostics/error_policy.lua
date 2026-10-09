--- _shared/lua/diagnostics/error_policy.lua

--- ==============================================================================
--- MODULE: Error Window Policy (Shared Lua)
--- DESCRIPTION:
--- Decides, for the macOS and Linux drivers, whether a logged ERROR opens the
--- error window (_shared/ui/error_dialog/), joins the one already open, or is
--- only logged. The thresholds are data: _shared/modules/diagnostics/
--- error_policy.json. The AHK port (windows/infra/error_policy.ahk) replays the
--- same vectors (_shared/tests/corpus/diagnostics/error_policy_vectors.json).
---
--- FEATURES & RATIONALE:
--- 1. An error's signature is its module and the message template the code
---    passed to the logger, before its arguments are filled in: a path, a count
---    or a time that changes from one occurrence to the next cannot make one
---    fault look like many.
--- 2. A signature opens the window at most once per session; a window that
---    reopens on every recurrence of the same fault trains the user to close it
---    unread.
--- 3. A budget of max_dialogs windows per window_sec seconds bounds a storm of
---    distinct faults. An error over the budget is not recorded, so it can still
---    open the window when it recurs once the budget allows.
--- 4. An error logged while the window is open, or about to open, joins it
---    and spends no budget: the host counts it in the open window.
--- 5. Pure: the host owns the clock, the window and the setting, and passes
---    them in with each event.
--- ==============================================================================

local M = {}

-- Every answer decide() can give, in the order its checks run
M.VERDICTS = { "disabled", "duplicate", "folded", "rate_limited", "show" }





-- =============================
-- =============================
-- ======= 1/ The Policy =======
-- =============================
-- =============================

--- True when a value is a whole number of at least `min`.
--- @param value any
--- @param min number
--- @return boolean
local function is_count(value, min)
	return type(value) == "number" and value == math.floor(value) and value >= min
end

--- Checks a decoded error_policy.json and returns it.
--- @param policy table
--- @return table The same table.
--- @throws When a field is missing or out of range.
function M.validate(policy)
	if type(policy) ~= "table" then error("error_policy: the policy must be a table", 2) end
	if type(policy.signature_separator) ~= "string" or policy.signature_separator == "" then
		error("error_policy: signature_separator must be a non-empty string", 2)
	end
	if not is_count(policy.max_dialogs, 1) then
		error("error_policy: max_dialogs must be a whole number of at least 1", 2)
	end
	if type(policy.window_sec) ~= "number" or policy.window_sec <= 0 then
		error("error_policy: window_sec must be a positive number", 2)
	end
	if not is_count(policy.present_delay_ms, 0) then
		error("error_policy: present_delay_ms must be a whole number of at least 0", 2)
	end
	return policy
end

--- A fresh session: no signature seen, no window opened.
--- @return table
function M.new_state()
	return { seen = {}, shown = {} }
end

--- An error's signature: its module, the separator, then its template.
--- @param policy table { signature_separator }
--- @param module_name any
--- @param template any The message template, before its arguments.
--- @return string
function M.signature(policy, module_name, template)
	return tostring(module_name) .. policy.signature_separator .. tostring(template)
end





-- ==============================
-- ==============================
-- ======= 2/ The Verdict =======
-- ==============================
-- ==============================

--- Drops the windows that no longer count against the budget.
--- @param shown table Opening times, oldest first.
--- @param now number
--- @param window_sec number
local function prune(shown, now, window_sec)
	while shown[1] ~= nil and now - shown[1] >= window_sec do table.remove(shown, 1) end
end

--- Decides what one logged error does, and records it in the session.
--- @param state table From new_state().
--- @param policy table A validated policy.
--- @param event table { module, template, at (seconds), enabled, open }
--- @return string verdict One of M.VERDICTS.
--- @return string signature
function M.decide(state, policy, event)
	local signature = M.signature(policy, event.module, event.template)
	if event.enabled ~= true then return "disabled", signature end
	if state.seen[signature] then return "duplicate", signature end
	if event.open == true then
		state.seen[signature] = true
		return "folded", signature
	end
	prune(state.shown, event.at, policy.window_sec)
	if #state.shown >= policy.max_dialogs then return "rate_limited", signature end
	state.seen[signature] = true
	state.shown[#state.shown + 1] = event.at
	return "show", signature
end

return M
