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

local Json = require("json")
local Logger = require("logger.shim")
local LOG = "bridge.numeric_prompt"
local APP_NAME = "numeric_prompt"

-- The request currently on screen, including its native owner and request epoch.
local _pending = nil
local _next_request_epoch = 0

local function public_request(pending)
	return {
		title = pending.title,
		hint = pending.hint,
		value = pending.value,
		min = pending.min,
		max = pending.max,
		request_epoch = pending.request_epoch,
	}
end

local function push_request(pending)
	local manager = pending and pending.webview or nil
	if type(manager) ~= "table" or type(manager.eval_js) ~= "function" then return false end
	local ok_json, encoded = pcall(Json.encode, public_request(pending))
	if not ok_json or type(encoded) ~= "string" then return false end
	local ok_push, pushed = pcall(manager.eval_js, APP_NAME,
		"if(window.receive_prompt) window.receive_prompt(" .. encoded .. ")")
	return ok_push and pushed == true
end

local function hide_prompt(pending)
	local manager = pending and pending.webview or nil
	if type(manager) ~= "table" or type(manager.hide) ~= "function" then return false end
	local ok = pcall(manager.hide, APP_NAME)
	if not ok then return false end
	if type(manager.is_visible) == "function" then
		local visible_ok, visible = pcall(manager.is_visible, APP_NAME)
		return visible_ok and visible ~= true
	end
	return true
end




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
	if type(request.value) ~= "number" or type(request.min) ~= "number"
		or type(request.max) ~= "number" or request.min > request.max
		or request.value < request.min or request.value > request.max then
		Logger.error(LOG, "ask(): a range is required — an unbounded numeric field "
			.. "accepts anything and the caller then has to reject it after the fact.")
		return false
	end
	if not webview or type(webview.show) ~= "function" or type(webview.eval_js) ~= "function"
		or type(webview.hide) ~= "function" then
		Logger.error(LOG, "ask(): no webview manager — the prompt cannot be shown.")
		return false
	end

	-- Replacing rather than queueing: two prompts sharing one bridge would
	-- deliver the second answer to the first caller.
	if _pending then
		Logger.info(LOG, "A prompt was already open — it is replaced.")
	end
	local previous = _pending
	_next_request_epoch = _next_request_epoch + 1
	_pending = {
		title = request.title or "",
		hint = request.hint or "",
		value = request.value,
		min = request.min,
		max = request.max,
		on_save = request.on_save,
		webview = webview,
		request_epoch = _next_request_epoch,
		completed = false,
	}
	local shown_ok, shown = pcall(webview.show, APP_NAME)
	if not shown_ok or shown ~= true then
		_pending = previous
		Logger.error(LOG, "ask(): the numeric prompt window could not be shown.")
		return false
	end
	-- A newly-created page will ask again with ready. A retained hidden page does
	-- not reload, so it needs this immediate push to replace its previous request.
	if not push_request(_pending) then
		pcall(webview.hide, APP_NAME)
		_pending = previous
		Logger.error(LOG, "ask(): the numeric prompt request could not reach its page.")
		return false
	end
	return true
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
--- @param _state table Daemon state, unused: the pending request owns its window.
--- @return any|nil Response to send back to JS.
function M.on_message(payload, _state)
	local action = type(payload) == "table" and payload.action or payload

	if action == "ready" then
		if not _pending then
			Logger.warn(LOG, "The prompt reported ready with nothing to ask.")
			return nil
		end
		return {
			pushed = push_request(_pending),
			request = public_request(_pending),
		}
	end

	if action == "cancel" then
		if not _pending or type(payload) ~= "table"
			or payload.request_epoch ~= _pending.request_epoch then
			return { closed = false, stale = true }
		end
		if not hide_prompt(_pending) then return { closed = false } end
		_pending = nil
		Logger.debug(LOG, "Prompt cancelled.")
		return { closed = true }
	end

	if action == "save" and type(payload) == "table" then
		local request = _pending
		if not request or payload.request_epoch ~= request.request_epoch then
			Logger.warn(LOG, "A value arrived with no prompt waiting for it — ignored.")
			return { saved = false, stale = true }
		end
		if request.completed then
			local closed = hide_prompt(request)
			if closed then _pending = nil end
			return { saved = true, closed = closed }
		end
		local value = payload.value
		-- Checked here as well as in the page. The page is the convenience; this
		-- is the guarantee, because a bridge is reachable by anything that can
		-- post to it and the caller's setter should never see a value its own
		-- range forbids.
		if type(value) ~= "number" or value < request.min or value > request.max then
			Logger.error(LOG, "Prompt returned %s, outside %s..%s — refused.",
				tostring(payload.value), tostring(request.min), tostring(request.max))
			return { saved = false }
		end

		local ok, accepted = pcall(request.on_save, value)
		if not ok or accepted == false then
			Logger.error(LOG, "The prompt's callback failed: %s.", tostring(accepted))
			return { saved = false }
		end
		request.completed = true
		local closed = hide_prompt(request)
		if closed then _pending = nil end
		return { saved = true, closed = closed }
	end

	Logger.warn(LOG, "Unknown bridge action received: %s.", tostring(action))
	return nil
end

--- Test seam: forgets any pending request.
function M._reset()
	_pending = nil
	_next_request_epoch = _next_request_epoch + 1
end

return M
