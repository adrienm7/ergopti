--- _shared/lua/llm/test_prediction.lua

--- ==============================================================================
--- MODULE: Test Prediction
--- DESCRIPTION:
--- The AI menu's « Test a prediction » on macOS and Linux: one prediction on a
--- translated sample context with the active backend, showing the answer or why
--- it could not run. Windows has the same behaviour in
--- ui/menu/menu_llm/menu_settings.ahk (LLM_Menu_TestPrediction).
---
--- FEATURES & RATIONALE:
--- 1. Straight to the Backend: an engine answer is a tooltip the user could accept
---    into the focused document, so the driver's send port never goes through the
---    prediction engine's offer, and the typed context stays untouched.
--- 2. Only the Newest: a later test, a pause or the switch-off withdraws the one
---    in flight. The current port is handed to the backend as well.
--- 3. Nothing Logged but Sizes: an answer stays out of the log like every
---    prediction.
--- 4. Injected Ports: the driver supplies its refusal, backend and notice, so this
---    module owns the behaviour and none of the native effects.
--- ==============================================================================

local M = {}

--- The most characters of an answer the notice shows; Windows declares the same
--- (tools/test/test-test-prediction-single-source.cjs).
M.EXCERPT_CHARS = 200

--- The reason shown for a blank answer, as on Windows.
M.EMPTY_ANSWER_REASON = "the backend returned an empty answer"
--- The reason shown when a backend failed without saying why.
M.UNKNOWN_FAILURE_REASON = "the backend did not answer"

--- Cuts a text to a number of UTF-8 characters.
--- @param text string
--- @param limit number
--- @return string kept, boolean cut
local function excerpt(text, limit)
	local count, stop = 0, nil
	for start in text:gmatch("()[^\128-\191][\128-\191]*") do
		count = count + 1
		if count > limit then
			stop = start
			break
		end
	end
	if not stop then return text, false end
	return text:sub(1, stop - 1), true
end

--- Fills the {1} of a translated template with a plain value.
--- @param template string
--- @param value string
--- @return string
local function fill(template, value)
	local at, stop = template:find("{1}", 1, true)
	if not at then return template end
	return template:sub(1, at - 1) .. value .. template:sub(stop + 1)
end

--- The readable reason of a backend failure, whichever form the backend gives.
--- @param failure any A string, or a table with a reason or message.
--- @return string
local function reason_of(failure)
	if type(failure) == "table" then failure = failure.reason or failure.message end
	if type(failure) == "string" and failure ~= "" then return failure end
	return M.UNKNOWN_FAILURE_REASON
end

--- Builds one test owner, holding the generation of its newest test.
--- @param ports table {
---   text = function(key) -> string,
---   refusal = function() -> locale key or nil,
---   may_publish = function() -> boolean: not paused and the AI on,
---   send = function(sample, on_text, on_fail, current): raises when refused,
---   show = function(text),
---   info = function(fmt, ...), warn = function(fmt, ...) }
--- @return table owner { run = function() -> boolean }
function M.new(ports)
	assert(type(ports) == "table", "the test prediction needs its ports")
	for _, name in ipairs({ "text", "refusal", "may_publish", "send", "show", "info", "warn" }) do
		assert(type(ports[name]) == "function", "the test prediction needs a " .. name .. " port")
	end
	local generation = 0

	local function current(id)
		return id == generation and ports.may_publish() == true
	end

	local function on_fail(id, failure)
		if not current(id) then return end
		local reason = reason_of(failure)
		ports.warn("Test prediction #%d failed: %s.", id, reason)
		ports.show(fill(ports.text("llm.test_prediction.failed"), reason))
	end

	local function on_text(id, answer)
		if not current(id) then return end
		answer = type(answer) == "string" and require("text_utils").trim(answer) or ""
		if answer == "" then return on_fail(id, M.EMPTY_ANSWER_REASON) end
		ports.info("Test prediction #%d answered (%d byte(s)).", id, #answer)
		local kept, cut = excerpt(answer, M.EXCERPT_CHARS)
		ports.show(fill(ports.text("llm.test_prediction.result"), cut and (kept .. "…") or kept))
	end

	local owner = {}

	--- Runs one test.
	--- @return boolean sent True when the request left.
	function owner.run()
		local refusal = ports.refusal()
		if refusal then
			ports.info("Test prediction refused (%s).", refusal)
			ports.show(ports.text(refusal))
			return false
		end
		generation = generation + 1
		local id = generation
		ports.info("Test prediction #%d sent to the active backend.", id)
		ports.show(ports.text("llm.test_prediction.running"))
		local sent, err = pcall(ports.send, ports.text("llm.test_prediction.sample"),
			function(answer) on_text(id, answer) end,
			function(failure) on_fail(id, failure) end,
			function() return current(id) end)
		if not sent then
			on_fail(id, tostring(err))
			return false
		end
		return true
	end

	return owner
end

return M
