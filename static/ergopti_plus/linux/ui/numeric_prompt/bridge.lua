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

--- Retains cleanup permission for the same native page, including cleanup debt.
--- @param pending table|nil Exact request.
--- @return boolean
local function retained(pending)
	if not pending or _pending ~= pending or pending.opening or not pending.native_epoch then return false end
	local manager = pending.webview
	if manager.current_epoch ~= pending.current_epoch then return false end
	local called, epoch = pcall(pending.current_epoch, APP_NAME)
	return called and epoch == pending.native_epoch and _pending == pending
		and manager.current_epoch == pending.current_epoch
end

--- Admits a setter only while its exact page is ready without native debt.
--- @param pending table|nil Exact request.
--- @return boolean
local function current(pending)
	if not retained(pending) or pending.webview.page_current ~= pending.page_current then return false end
	local called, live = pcall(pending.page_current, APP_NAME, pending.native_epoch)
	return called and live == true and _pending == pending
		and pending.webview.page_current == pending.page_current
		and pending.webview.current_epoch == pending.current_epoch
end

local function push_request(pending)
	local manager = pending and pending.webview or nil
	if not manager or not current(pending) then return false end
	local ok_json, encoded = pcall(Json.encode, public_request(pending))
	if not ok_json or type(encoded) ~= "string" or not current(pending) then return false end
	local ok_push, pushed = pcall(manager.eval_js, APP_NAME,
		"if(window.receive_prompt) window.receive_prompt(" .. encoded .. ")")
	return ok_push and pushed == true and current(pending)
end

local function hide_prompt(pending)
	if not retained(pending) then return false end
	local manager = pending.webview
	local ok, accepted = pcall(manager.hide, APP_NAME, pending.native_epoch)
	if not ok or accepted ~= true or _pending ~= pending then return false end
	local visible_ok, visible = pcall(manager.is_visible, APP_NAME)
	return visible_ok and visible == false and _pending == pending
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
		or type(webview.hide) ~= "function" or type(webview.is_visible) ~= "function"
		or type(webview.current_epoch) ~= "function" or type(webview.page_current) ~= "function" then
		Logger.error(LOG, "ask(): no webview manager — the prompt cannot be shown.")
		return false
	end

	-- Replacing rather than queueing: two prompts sharing one bridge would
	-- deliver the second answer to the first caller.
	local previous = _pending
	_next_request_epoch = _next_request_epoch + 1
	local pending = {
		title = request.title or "",
		hint = request.hint or "",
		value = request.value,
		min = request.min,
		max = request.max,
		on_save = request.on_save,
		webview = webview,
		request_epoch = _next_request_epoch,
		completed = false,
		opening = true,
		page_current = webview.page_current,
		current_epoch = webview.current_epoch,
	}
	_pending = pending
	if previous then Logger.info(LOG, "A prompt was already open — it is replaced.") end
	if _pending ~= pending then return false end
	local shown_ok, shown = pcall(webview.show, APP_NAME)
	if _pending ~= pending then return false end
	pending.opening = false
	if not shown_ok or shown ~= true then
		_pending = previous
		Logger.error(LOG, "ask(): the numeric prompt window could not be shown.")
		return false
	end
	local epoch_ok, epoch = pcall(pending.current_epoch, APP_NAME)
	if _pending ~= pending then return false end
	if epoch_ok and type(epoch) == "number" then pending.native_epoch = epoch end
	-- A newly-created page will ask again with ready. A retained hidden page does
	-- not reload, so it needs this immediate push to replace its previous request.
	if not push_request(pending) then
		if _pending ~= pending then return false end
		local closed = hide_prompt(pending)
		if _pending ~= pending then return false end
		if closed then
			_pending = previous
			if not current(previous) and _pending == previous then _pending = nil end
		end
		Logger.error(LOG, "ask(): the numeric prompt request could not reach its page.")
		return false
	end
	return true
end

--- Whether a prompt is waiting for an answer.
--- @return boolean
function M.is_pending()
	return retained(_pending)
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
		local pending = _pending
		if not current(pending) then
			Logger.warn(LOG, "The prompt reported ready with nothing to ask.")
			return nil
		end
		local pushed = push_request(pending)
		if not current(pending) then return nil end
		return { pushed = pushed, request = public_request(pending) }
	end

	if action == "cancel" then
		local pending = _pending
		if not retained(pending) or type(payload) ~= "table"
			or payload.request_epoch ~= pending.request_epoch or pending.saving then
			return { closed = false, stale = true }
		end
		local closed = hide_prompt(pending)
		if _pending ~= pending then return { closed = false, stale = true } end
		if not closed then return { closed = false } end
		_pending = nil
		Logger.debug(LOG, "Prompt cancelled.")
		return { closed = true }
	end

	if action == "save" and type(payload) == "table" then
		local request = _pending
		if not retained(request) or payload.request_epoch ~= request.request_epoch then
			Logger.warn(LOG, "A value arrived with no prompt waiting for it — ignored.")
			return { saved = false, stale = true }
		end
		if request.saving then return { saved = false, busy = true } end
		if request.completed then
			local closed = hide_prompt(request)
			if _pending ~= request then return { saved = false, closed = false, stale = true } end
			if closed then _pending = nil end
			return { saved = true, closed = closed }
		end
		if not current(request) then return { saved = false, stale = true } end
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

		request.saving = true
		local ok, accepted = pcall(request.on_save, value)
		request.saving = false
		if not current(request) then return { saved = false, closed = false, stale = true } end
		if not ok or accepted == false then
			Logger.error(LOG, "The prompt's callback failed: %s.", tostring(accepted))
			if not current(request) then return { saved = false, stale = true } end
			return { saved = false }
		end
		request.completed = true
		local closed = hide_prompt(request)
		if _pending ~= request then return { saved = false, closed = false, stale = true } end
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
