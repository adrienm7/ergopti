--- modules/llm/screen_answer.lua

--- ==============================================================================
--- MODULE: Answers to What Is on the Screen
--- DESCRIPTION:
--- Runs the llm_screen_region, llm_screen_full and llm_screen_error actions: a
--- screenshot (a region the user draws, or the whole screen the pointer is on)
--- is transcribed by a vision model, then the AI menu's text backend drafts the
--- answers of an answer set of vision.json (a reply, a translation and an
--- explanation; or the cause of an error, then its fix), offered as the
--- prediction tooltip's candidates. Accepting one types it at the caret;
--- nothing is typed without the user's acceptance.
---
--- FEATURES & RATIONALE:
--- 1. Refusals first: a paused script, the AI switched off, a text backend that
---    is not ready or a vision backend without a model refuse before anything
---    is captured, with the notices of llm_generate_prediction.
--- 2. The screenshot goes to a private temporary PNG, never the clipboard, and
---    the file is removed once the capture operation ends, whatever happened
---    (screenshot_save.capture_image). Neither the image nor the transcribed
---    screen is ever logged.
--- 3. The vision request goes to the binding's backend: "local" is the local
---    Ollama server whatever the AI menu uses for text; any other id is a
---    provider of api_providers.json with its stored API key.
--- 4. The answers run one after the other on the AI menu's backend, which
---    serves one request at a time; each is shown as soon as it arrives, in
---    the order of vision.json. The answer set is a parameter of the flow:
---    one capture and transcription path serves every screen action.
--- 5. One screen reading at a time: a new trigger supersedes the previous one,
---    whose late results are dropped by generation.
---
--- The pure logic (binding parameter, request bodies, answer reading) is shared:
--- _shared/lua/llm/vision.lua, configured by _shared/modules/llm/vision.json.
--- ==============================================================================

local M = {}

local Vision       = require("llm.vision")
local Logger       = require("infra.logger")
local i18n         = require("infra.i18n")
local Paths        = require("infra.paths")
local FileSystem   = require("adapters.file_system")
local JsonCodec    = require("adapters.json_codec")
local MouseControl = require("adapters.mouse_control")

local LOG = "llm.screen_answer"

-- The two capture modes, one per action
M.MODE_REGION = "region"
M.MODE_FULL   = "full"

-- The answer sets of vision.json, one per kind of screen action
M.ANSWERS_SCREEN = "answers"
M.ANSWERS_ERROR  = "error_answers"
local ANSWER_SETS = { M.ANSWERS_SCREEN, M.ANSWERS_ERROR }

-- screencapture flags of the region the user draws
local REGION_FLAGS = { "-i" }

-- The decoded vision.json, read on first use
local _config = nil

-- Generation of the current screen reading; a callback of an older one is stale
local _generation = 0




-- =====================================
-- =====================================
-- ======= 1/ Configuration ============
-- =====================================
-- =====================================

--- Raises unless a vision.json field has the expected type.
--- @param config table The decoded file.
--- @param key string Field name.
--- @param kind string Expected Lua type.
local function require_field(config, key, kind)
	if type(config[key]) ~= kind then
		error("screen_answer: vision.json field '" .. key .. "' must be a " .. kind)
	end
end

--- Returns the decoded _shared/modules/llm/vision.json, read once. A missing or
--- malformed file is a broken install and raises.
--- @return table config
function M.config()
	if _config then return _config end
	local path = Paths.shared_llm_path("vision.json")
	local raw = path and FileSystem.read(path) or nil
	if type(raw) ~= "string" then error("screen_answer: _shared/modules/llm/vision.json is unreadable") end
	local config, decode_error = JsonCodec.decode(raw)
	if type(config) ~= "table" then
		error("screen_answer: vision.json is not valid JSON: " .. tostring(decode_error))
	end
	for _, key in ipairs({ "screen_tag", "answer_tag", "image_mime", "read_prompt" }) do
		require_field(config, key, "string")
	end
	for _, key in ipairs({ "max_image_edge", "read_max_tokens", "answer_max_tokens" }) do
		require_field(config, key, "number")
	end
	require_field(config, "default_models", "table")
	for _, set in ipairs(ANSWER_SETS) do
		require_field(config, set, "table")
		if #config[set] == 0 then error("screen_answer: vision.json lists no answer in '" .. set .. "'") end
		for index, answer in ipairs(config[set]) do
			if type(answer) ~= "table" or type(answer.id) ~= "string" or type(answer.prompt) ~= "string" then
				error("screen_answer: vision.json " .. set .. " entry " .. index .. " needs an id and a prompt")
			end
		end
	end
	_config = config
	return _config
end




-- =====================================
-- =====================================
-- ======= 2/ Internal Helpers =========
-- =====================================
-- =====================================

--- Shows a notice explaining why a screen reading did nothing.
--- @param key string Locale key of the notice.
local function show_notice(key)
	local ok_tooltip, tooltip = pcall(require, "ui.tooltip")
	local ok_show, shown = false, nil
	if ok_tooltip and type(tooltip) == "table" and type(tooltip.show) == "function" then
		ok_show, shown = pcall(tooltip.show, i18n.get(key), true, true)
	end
	if not ok_show or shown ~= true then
		Logger.warn(LOG, "Screen reading notice '%s' was not shown: %s.", key, tostring(shown))
	end
end

--- Loads a module the screen reading calls at dispatch time.
--- @param name string Module name.
--- @param method string Function the module must expose.
--- @return table|nil module The module, or nil after logging why it is unavailable.
local function dependency(name, method)
	local ok, module = pcall(require, name)
	if not ok or type(module) ~= "table" or type(module[method]) ~= "function" then
		Logger.error(LOG, "Screen reading impossible: '%s.%s' is unavailable (%s).", name, method, tostring(module))
		return nil
	end
	return module
end

--- Tells whether a callback still belongs to the current screen reading.
--- @param generation number The screen reading the callback belongs to.
--- @param stage string What the callback delivers, for the log.
--- @return boolean current
local function is_current(generation, stage)
	if generation == _generation then return true end
	Logger.info(LOG, "Screen reading %s dropped: a newer screen reading superseded it.", stage)
	return false
end

--- Drafts the answers one after the other on the AI menu's backend and shows
--- each as it arrives.
--- @param generation number The screen reading.
--- @param engine table The prediction engine.
--- @param session number The tooltip surface.
--- @param config table vision.json.
--- @param answer_set table The answers to draft, in tooltip order.
--- @param screen string The transcribed screen.
local function draft_answers(generation, engine, session, config, answer_set, screen)
	local answers = {}
	local waiting_shown = false
	local user_text = Vision.answer_user_text(screen)
	local Profiles = require("modules.llm.profiles")
	local language = Profiles.prompt_language()
	local total = #answer_set

	--- Shows the answers so far; false when the user closed the surface.
	--- @param remaining number Answers still to come.
	--- @return boolean shown
	local function publish(remaining)
		waiting_shown = remaining > 0
		if engine.show_answers(session, answers, #answers + remaining) then return true end
		Logger.info(LOG, "Screen reading stopped: its answers were dismissed or replaced.")
		return false
	end

	local step
	--- Ends the screen reading once every answer was asked for.
	local function finish()
		if #answers == 0 then
			Logger.warn(LOG, "Screen reading failed: no answer could be drafted.")
			engine.close_answer_surface(session)
			show_notice("llm.vision.read_failed")
			return
		end
		if waiting_shown and not publish(0) then return end
		Logger.info(LOG, "Screen reading offers %d answer(s).", #answers)
	end

	--- Asks for one answer, then the next.
	--- @param index number Position in answer_set.
	step = function(index)
		if not is_current(generation, "answer") then return end
		if index > total then
			finish()
			return
		end
		local answer = answer_set[index]
		local settled = false
		--- Moves on once this answer settled, exactly once.
		--- @param text string|nil The answer, nil when skipped.
		local function settle(text)
			if settled or not is_current(generation, "answer") then return end
			settled = true
			if text then
				answers[#answers + 1] = text
				if not publish(total - index) then return end
			end
			step(index + 1)
		end
		local sent = engine.request_chat_answer("Screen reading answer",
			Vision.fill_language(answer.prompt, language), user_text,
			config.answer_max_tokens,
			function(raw)
				local text = Vision.extract(raw, config.answer_tag)
				if not text then
					Logger.warn(LOG, "Screen answer '%s' skipped: it holds no %s block.", answer.id, config.answer_tag)
				end
				settle(text)
			end,
			function(detail)
				Logger.warn(LOG, "Screen answer '%s' skipped: the model gave no answer (%s).",
					answer.id, tostring(detail))
				settle(nil)
			end)
		if not sent then
			Logger.warn(LOG, "Screen answer '%s' skipped: the request could not be sent.", answer.id)
			settle(nil)
		end
	end
	step(1)
end

--- Sends the vision request once the screenshot is captured.
--- @param generation number The screen reading.
--- @param backend table { kind = "local"|"remote", provider, format }.
--- @param model string The vision model.
--- @param config table vision.json.
--- @param answer_set table The answers to draft, in tooltip order.
--- @param outcome string "image", "cancelled" or "failed".
--- @param data string|nil The base64 PNG, or the failure detail.
local function on_capture(generation, backend, model, config, answer_set, outcome, data)
	if not is_current(generation, "capture") then return end
	if outcome == "cancelled" then
		Logger.info(LOG, "Screen reading cancelled: no region was selected.")
		return
	end
	if outcome ~= "image" then
		Logger.error(LOG, "Screen reading failed: the screenshot could not be taken (%s).", tostring(data))
		show_notice("llm.vision.capture_failed")
		return
	end
	local engine = dependency("modules.llm.prediction_engine", "open_answer_surface")
	if not engine then return end
	local session = engine.open_answer_surface("Screen reading")
	if not session then
		Logger.warn(LOG, "Screen reading stopped: the prediction tooltip could not be opened.")
		return
	end
	local body = Vision.build_request(backend.format, {
		model = model,
		system = config.read_prompt,
		text = Vision.READ_USER_TEXT,
		image = data,
		mime = config.image_mime,
		max_tokens = config.read_max_tokens,
	})

	--- Ends a screen reading whose vision request failed.
	--- @param reason string Why, for the log.
	local function fail(reason)
		Logger.warn(LOG, "Screen reading failed: %s.", reason)
		engine.close_answer_surface(session)
		show_notice("llm.vision.read_failed")
	end
	local function on_text(text)
		if not is_current(generation, "transcription") then return end
		local screen = Vision.extract(text, config.screen_tag)
		if not screen then
			fail(string.format("the vision answer holds no %s block (%d char(s))", config.screen_tag, #text))
			return
		end
		Logger.info(LOG, "Screen read (%d char(s)); drafting %d answer(s).", #screen, #answer_set)
		draft_answers(generation, engine, session, config, answer_set, screen)
	end
	local function on_fail(reason, detail)
		if not is_current(generation, "transcription") then return end
		local Offer = require("modules.llm.local_model_offer")
		if Offer.is_missing(reason, detail) then
			-- Named, with its Download button, instead of the vague failure
			Logger.warn(LOG, "Screen reading failed: the local server does not hold model %s.", detail.model)
			engine.close_answer_surface(session)
			Offer.offer(detail.model)
			return
		end
		fail("the vision model gave no answer (" .. tostring(reason) .. ")")
	end
	if backend.kind == "local" then
		local Ollama = dependency("modules.llm.api_ollama", "request_vision")
		if not Ollama then return fail("the local backend is unavailable") end
		Ollama.request_vision(body, on_text, on_fail)
	else
		local Remote = dependency("modules.llm.api_remote", "request_vision")
		if not Remote then return fail("the remote backend is unavailable") end
		Remote.request_vision(backend.provider, model, body, on_text, on_fail)
	end
end

--- Resolves where the vision request goes, before anything is captured.
--- @param backend_id string The binding's backend.
--- @return table|nil backend { kind, provider, format }, nil after logging why.
local function resolve_backend(backend_id)
	if backend_id == Vision.LOCAL_BACKEND then return { kind = "local", format = "ollama" } end
	local Remote = dependency("modules.llm.api_remote", "vision_provider_status")
	if not Remote then return nil end
	local ready, reason = Remote.vision_provider_status(backend_id)
	if not ready then
		Logger.warn(LOG, "Screen reading refused: provider '%s' cannot take a vision request (%s).",
			backend_id, tostring(reason))
		return nil
	end
	return { kind = "remote", provider = backend_id, format = Remote.provider_format(backend_id) }
end

--- The screencapture flags of a capture mode.
--- @param mode string M.MODE_REGION or M.MODE_FULL.
--- @return table|nil flags Nil when the pointer's screen cannot be read.
local function capture_flags(mode)
	if mode == M.MODE_REGION then return REGION_FLAGS end
	local frame = MouseControl.screen_frame_under_cursor()
	if not frame then return nil end
	return { "-R", string.format("%d,%d,%d,%d", math.floor(frame.x), math.floor(frame.y),
		math.floor(frame.w), math.floor(frame.h)) }
end




-- =====================================
-- =====================================
-- ======= 3/ Public API ===============
-- =====================================
-- =====================================

--- Reads the screen and offers the answers of an answer set in the prediction
--- tooltip.
--- @param value string The binding's parameter: "<backend>" or "<backend>|<model>".
--- @param mode string M.MODE_REGION or M.MODE_FULL.
--- @param parent string|nil Stable action parent of the screenshot actions.
--- @param answers string M.ANSWERS_SCREEN or M.ANSWERS_ERROR.
--- @return boolean started True when the screenshot is being taken.
function M.run(value, mode, parent, answers)
	if mode ~= M.MODE_REGION and mode ~= M.MODE_FULL then
		error("screen_answer.run: mode must be MODE_REGION or MODE_FULL")
	end
	if answers ~= M.ANSWERS_SCREEN and answers ~= M.ANSWERS_ERROR then
		error("screen_answer.run: answers must be ANSWERS_SCREEN or ANSWERS_ERROR")
	end
	local engine = dependency("modules.llm.prediction_engine", "admit_answer_request")
	if not engine or not engine.admit_answer_request("Screen reading") then return false end
	local parsed, parse_error = Vision.parse(value)
	if not parsed then
		Logger.warn(LOG, "Screen reading refused: invalid vision parameter '%s' (%s).",
			tostring(value), tostring(parse_error))
		return false
	end
	local config = M.config()
	local answer_set = config[answers]
	local model = Vision.resolve_model(parsed, config)
	if not model then
		Logger.info(LOG, "Screen reading refused: backend '%s' has no default vision model.", parsed.backend)
		show_notice("llm.vision.no_model")
		return false
	end
	local backend = resolve_backend(parsed.backend)
	if not backend then
		show_notice("llm.vision.read_failed")
		return false
	end
	local flags = capture_flags(mode)
	if not flags then
		Logger.error(LOG, "Screen reading refused: the screen under the pointer cannot be read.")
		show_notice("llm.vision.capture_failed")
		return false
	end
	local Capture = dependency("modules.shortcuts.actions.screenshot_save", "capture_image")
	if not Capture then return false end
	_generation = _generation + 1
	local generation = _generation
	local accepted = Capture.capture_image(flags, parent, config.max_image_edge, function(outcome, data)
		on_capture(generation, backend, model, config, answer_set, outcome, data)
	end)
	if not accepted then
		Logger.warn(LOG, "Screen reading stopped: the screenshot could not start.")
		show_notice("llm.vision.capture_failed")
		return false
	end
	Logger.info(LOG, "Screen reading %d started (%s, %s, backend '%s', model %s).",
		generation, mode, answers, parsed.backend, model)
	return true
end

--- Drops every screen reading in flight, for tests and a fresh start.
function M.reset()
	_generation = _generation + 1
	Logger.debug(LOG, "Screen reading generation advanced to %d.", _generation)
end

return M
