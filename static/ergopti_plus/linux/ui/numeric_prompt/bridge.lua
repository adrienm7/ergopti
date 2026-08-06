--- ui/numeric_prompt/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Numeric Prompt
--- DESCRIPTION:
--- Asks the user for one number within a declared range, and hands it to
--- whoever opened the window.
--- Bridge name: "numeric_prompt_bridge"
---
--- WHY THIS EXISTS:
--- macOS sets its numeric LLM settings through a free-text dialog; the Linux
--- tray has no text input at all, so its menu offers presets. That was the last
--- LLM gap between the two drivers, and closing it by taking the dialog away
--- from macOS would have REMOVED a capability — convergence downwards. This
--- adds the capability to Linux instead, so both drivers have presets for the
--- common values and free entry for anything else.
---
--- FEATURES & RATIONALE:
--- 1. The window knows nothing about what it is asking for. The caller supplies
---    a title, a range and a callback; a second setting needs no second window.
--- 2. One request at a time, and opening a second replaces the first. Two
---    prompts sharing one bridge would deliver the second answer to the first
---    caller, which is worse than refusing to open.
--- 3. The bounds are checked HERE as well as in the page. The page is the
---    convenience; this is the guarantee, because a bridge is reachable by
---    anything that can post to it.
--- ==============================================================================

local M = {}
M.bridge_name = "numeric_prompt_bridge"

local Logger = require("logger.shim")
local LOG = "bridge.numeric_prompt"

-- The request currently on screen: { title, hint, value, min, max, on_save }.
local _pending = nil




-- =========================================
-- =========================================
-- ======= 1/ Asking =======================
-- =========================================
-- =========================================

--- Opens the window for one value.
---
--- @param request table { title, hint?, value, min, max, on_save = function(number) }
--- @param webview table The webview manager, so this module opens nothing itself.
--- @return boolean Whether the window was opened.
function M.ask(request, webview)
	if type(request) ~= "table" or type(request.on_save) ~= "function" then
		Logger.error(LOG, "ask(): a request with an on_save callback is required.")
		return false
	end
	if type(request.min) ~= "number" or type(request.max) ~= "number" then
		Logger.error(LOG, "ask(): a range is required — an unbounded numeric field "
			.. "accepts anything and the caller then has to reject it after the fact.")
		return false
	end
	if not webview or type(webview.show) ~= "function" then
		Logger.error(LOG, "ask(): no webview manager — the prompt cannot be shown.")
		return false
	end

	-- Replacing rather than queueing: two prompts sharing one bridge would
	-- deliver the second answer to the first caller.
	if _pending then
		Logger.info(LOG, "A prompt was already open — it is replaced.")
	end
	_pending = request
	return webview.show("numeric_prompt") and true or false
end

--- Whether a prompt is waiting for an answer.
--- @return boolean
function M.is_pending()
	return _pending ~= nil
end




-- =========================================
-- =========================================
-- ======= 2/ Answering ====================
-- =========================================
-- =========================================

--- Handles an incoming JS message.
--- @param payload any String or table from host_bridge.js.
--- @param _state table Daemon state, unused: this window carries its own request.
--- @return any|nil Response to send back to JS.
function M.on_message(payload, _state)
	local action = type(payload) == "table" and payload.action or payload

	if action == "ready" then
		if not _pending then
			Logger.warn(LOG, "The prompt reported ready with nothing to ask — window left empty.")
			return nil
		end
		return {
			title = _pending.title or "",
			hint = _pending.hint or "",
			value = _pending.value,
			min = _pending.min,
			max = _pending.max,
		}
	end

	if action == "cancel" then
		_pending = nil
		Logger.debug(LOG, "Prompt cancelled.")
		return { closed = true }
	end

	if action == "save" and type(payload) == "table" then
		local request = _pending
		if not request then
			Logger.warn(LOG, "A value arrived with no prompt waiting for it — ignored.")
			return { saved = false }
		end
		local value = tonumber(payload.value)
		-- Checked here as well as in the page. The page is the convenience; this
		-- is the guarantee, because a bridge is reachable by anything that can
		-- post to it and the caller's setter should never see a value its own
		-- range forbids.
		if not value or value < request.min or value > request.max then
			Logger.error(LOG, "Prompt returned %s, outside %s..%s — refused.",
				tostring(payload.value), tostring(request.min), tostring(request.max))
			return { saved = false }
		end

		_pending = nil
		local ok, err = pcall(request.on_save, value)
		if not ok then
			Logger.error(LOG, "The prompt's callback raised: %s.", tostring(err))
			return { saved = false }
		end
		return { saved = true }
	end

	Logger.warn(LOG, "Unknown bridge action received: %s.", tostring(action))
	return nil
end

--- Test seam: forgets any pending request.
function M._reset()
	_pending = nil
end

return M
