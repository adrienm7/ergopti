--- tests/unit/modules/llm/test_screen_answer_end_to_end.lua

--- ==============================================================================
--- MODULE: Answers to What Is on the Screen End to End (llm-vision)
--- DESCRIPTION:
--- Runs the llm_screen_region and llm_screen_full actions without a model or a
--- screen: the real gesture action registry, screen-answer flow, prediction
--- engine refusals and tooltip surface, LLM core dispatcher, remote backend
--- (an OpenAI entry for the vision request, Cerebras as the AI menu's text
--- backend) and local backend. Only the boundaries are faked: the screenshot
--- (captures are recorded and completed by the test), the HTTP transports
--- (requests are captured and answered with canned bodies), the pointer's
--- screen, the tooltip canvas, and the key emitter of the acceptance step (the
--- real keymap bridge and expander drive the synthetic input collector).
---
--- ROOT CAUSE ENCODED:
--- No action could read what is on the screen. The feature only works when
--- every layer agrees: nothing is captured before the refusals, the vision
--- request carries the captured image in the provider's dialect with its key,
--- the answers run on the AI menu's backend with the vision.json prompts, the
--- tooltip offers them in order, and accepting one types it at the caret
--- without erasing anything.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")
local Vision = require("llm.vision")
local ApplyFixture = require("tests.support.apply_prediction_fixture")

local TEXT_ENTRY_ID = "vision-cerebras"
local TEXT_MODEL = "qwen-3.8-27b"
local VISION_ENTRY_ID = "vision-openai"
local VISION_KEY = "openai-secret"
local IMAGE = "iVBORw0KGgoAAAANSUhEUg=="
local SCREEN = "Salut, on se voit demain à 14h ?"
local ANSWERS = {
	"Oui, à demain 14h !",
	"Hi, shall we meet tomorrow at 2 pm?",
	"Marc propose un rendez-vous demain à 14 h.",
}

--- @param path string Shared-relative JSON path.
--- @return table decoded
local function read_json(path)
	local fh = assert(io.open(helpers.shared(path), "r"), "cannot open " .. path)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), path .. " is not valid JSON")
end

local CONFIG = read_json("modules/llm/vision.json")

--- Returns one named closure upvalue, or nil when the closure does not own it.
--- @param fn function Closure to inspect.
--- @param target string Upvalue name.
--- @return any value
local function get_upvalue(fn, target)
	for index = 1, 256 do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == target then return value end
	end
	return nil
end

--- Compares two decoded JSON values structurally.
--- @return boolean equal
--- @return string|nil where
local function deep_equal(a, b, where)
	where = where or "$"
	if type(a) ~= type(b) then return false, where .. ": " .. type(a) .. " vs " .. type(b) end
	if type(a) ~= "table" then
		return a == b, a == b and nil or (where .. ": " .. tostring(a) .. " vs " .. tostring(b))
	end
	for key, value in pairs(a) do
		local ok, why = deep_equal(value, b[key], where .. "." .. tostring(key))
		if not ok then return false, why end
	end
	for key in pairs(b) do
		if a[key] == nil then return false, where .. "." .. tostring(key) .. " is missing" end
	end
	return true
end

--- Encodes an OpenAI-dialect chat completion carrying one answer.
--- @param content string The model's answer.
--- @return string body
local function completion_body(content)
	return json.encode({
		id = "chatcmpl-vision",
		object = "chat.completion",
		choices = { { index = 0, message = { role = "assistant", content = content }, finish_reason = "stop" } },
		usage = { prompt_tokens = 100, completion_tokens = 12, total_tokens = 112 },
	})
end

--- Builds the real pipeline around the faked boundaries.
--- @return table world
local function build_world()
	local world = {
		captures = {}, vision_posts = {}, local_posts = {}, text_posts = {},
		notices = {}, loadings = 0, renders = {}, hides = 0,
	}
	for name in pairs(package.loaded) do
		if type(name) == "string" and (name:find("^modules%.") or name:find("^adapters%.")
			or name:find("^infra%.") or name:find("^ui%.")) then
			package.loaded[name] = nil
		end
	end
	local _gestures = helpers.load_with_stubs("modules.gestures")
	world.actions = require("modules.gestures.actions")
	world.actions.init({ action_params = {} })
	local front_app = {
		title = function() return "VisionApp" end,
		name = function() return "VisionApp" end,
		bundleID = function() return "test.vision" end,
		path = function() return "/Applications/Vision.app" end,
		pid = function() return 7 end,
	}
	helpers.load_with_stubs("infra.logger", {
		application = { frontmostApplication = function() return front_app end },
	})
	package.loaded["infra.logger"] = helpers.make_logger_stub()

	for _, name in ipairs({
		"modules.llm", "modules.llm.profiles", "modules.llm.api_remote", "modules.llm.api_ollama",
		"modules.llm.api_mlx", "modules.llm.parser", "modules.llm.prompt_builder",
		"modules.llm.streaming_handler", "modules.llm.warmup_controller", "modules.llm.app_filter",
		"modules.llm.api_common", "modules.llm.prediction_engine", "modules.llm.progressive_reveal",
		"modules.llm.screen_answer",
	}) do
		package.loaded[name] = nil
	end
	package.loaded["modules.keymap.utils"] = { is_ignored_window = function() return false end }
	package.loaded["modules.shortcuts.script_control"] = nil
	package.loaded["modules.keylogger"] = {
		get_live_stats = function() return { wpm_physical = 0 } end,
		log_llm = function() end,
		log_llm_failed = function() end,
		log_llm_suggested = function() end,
		log_llm_dismissed = function() end,
	}
	package.loaded["ui.tooltip"] = {
		set_navigate_callback = function() end,
		set_enter_validates = function() end,
		set_llm_timeout = function() end,
		set_chain_start = function() return true end,
		show_loading = function()
			world.loadings = world.loadings + 1
			return true
		end,
		show = function(content)
			world.notices[#world.notices + 1] = content
			return true
		end,
		show_predictions = function(predictions, _, _, _, _, _, _, _, loading_text, slots)
			local texts = {}
			for index, prediction in ipairs(predictions) do texts[index] = prediction.to_type end
			world.renders[#world.renders + 1] = { texts = texts, loading = loading_text, slots = slots }
			return true
		end,
		get_current_index = function() return 1 end,
		make_diff_styled = function() return true end,
		reset_llm_timer = function() return true end,
		mark_chain_complete = function() return true end,
		tint = function() return {} end,
		hide = function()
			world.hides = world.hides + 1
			return true
		end,
		hide_forced_silent = function()
			world.hides = world.hides + 1
			return true
		end,
	}
	-- The screenshot boundary: the test completes each capture itself
	package.loaded["modules.shortcuts.actions.screenshot_save"] = {
		capture_image = function(flags, parent, max_edge, on_image)
			world.captures[#world.captures + 1] = {
				flags = flags, parent = parent, max_edge = max_edge, on_image = on_image,
			}
			return true
		end,
	}
	package.loaded["adapters.mouse_control"] = {
		screen_frame_under_cursor = function() return { x = 1512, y = 0, w = 1920, h = 1080.5 } end,
	}

	local core = require("modules.llm")
	world.core = core
	local CoreState = get_upvalue(core.get_active_profile, "CoreState")
	assert(type(CoreState) == "table", "the LLM core state must be reachable")
	CoreState.backend = "api"
	CoreState.active_profile_id = "advanced"
	local api = core.api_remote
	api.set_entries({
		{ id = TEXT_ENTRY_ID, provider = "cerebras", token = "cerebras-token", model = TEXT_MODEL },
		{ id = VISION_ENTRY_ID, provider = "openai", token = VISION_KEY, model = "gpt-4o" },
	})
	api.set_active_entry_id(TEXT_ENTRY_ID)
	local ready_index
	for index = 1, 256 do
		local name = debug.getupvalue(api.is_ready, index)
		if not name then break end
		if name == "_is_ready" then ready_index = index end
	end
	assert(ready_index, "the remote readiness flag must be reachable")
	debug.setupvalue(api.is_ready, ready_index, true)

	local function capture_into(list)
		return function(url, headers, body, callback)
			list[#list + 1] = { url = url, headers = headers, body = json.decode(body), callback = callback }
			return true
		end
	end
	local inference = get_upvalue(api.cancel_streaming, "_infer_client")
	assert(type(inference) == "table", "the remote prediction owner must be reachable")
	inference.post = capture_into(world.text_posts)
	local vision = get_upvalue(api.request_vision, "_vision_client")
	assert(type(vision) == "table", "the remote vision owner must be reachable")
	vision.post = capture_into(world.vision_posts)
	local ollama = require("modules.llm.api_ollama")
	local local_vision = get_upvalue(ollama.request_vision, "_vision_client")
	assert(type(local_vision) == "table", "the local vision owner must be reachable")
	local_vision.post = capture_into(world.local_posts)

	local engine = require("modules.llm.prediction_engine")
	world.engine = engine
	engine.init({
		buffer = "",
		llm_buffer = "",
		mappings = {},
		DELAYS = { llm_prediction = 1 },
		ignored_window_titles = {},
		ignored_window_patterns = {},
		suppress_rescan_keep_buffer = function() end,
	})
	engine.set_llm_enabled(true)
	world.flow = require("modules.llm.screen_answer")
	package.loaded["modules.keymap"] = {
		request_screen_answers = function(value, mode, parent) return world.flow.run(value, mode, parent) end,
	}
	world.language = require("modules.llm.profiles").prompt_language()
	return world
end

--- Runs a screen-reading action as the gesture registry dispatches it.
--- @param world table
--- @param action string The action id.
--- @param value string The binding's vision parameter.
--- @return boolean started
local function trigger(world, action, value)
	helpers.assert_eq(world.actions.set_action_parameter("tap_3", action, value), true, "a valid binding")
	return world.actions.execute_single(action, "tap_3")
end

--- Answers one captured request as the provider would.
--- @param post table A captured request.
--- @param content string The model's answer.
local function answer(post, content)
	post.callback({ ok = true, status = 200, body = completion_body(content), headers = {} })
end

--- Asserts that text request `index` drafts answer `index` of vision.json.
--- @param world table
--- @param index number
local function assert_answer_request(world, index)
	local post = world.text_posts[index]
	helpers.assert_true(post ~= nil, "answer request " .. index .. " is on the wire")
	helpers.assert_true(post.url:find("https://api.cerebras.ai/v1/chat/completions", 1, true) == 1,
		"the AI menu's backend answers: " .. tostring(post.url))
	helpers.assert_eq(post.body.model, TEXT_MODEL)
	helpers.assert_eq(post.body.messages[1].content,
		Vision.fill_language(CONFIG.answers[index].prompt, world.language),
		"the prompt of answer '" .. CONFIG.answers[index].id .. "'")
	helpers.assert_eq(post.body.messages[2].content, "SCREEN:\n" .. SCREEN, "the transcribed screen, as is")
	helpers.assert_eq(post.body.max_tokens, CONFIG.answer_max_tokens)
	helpers.assert_true(post.body.stream ~= true, "no streaming")
end

--- Accepts a prediction through the real keymap bridge and expander.
--- @param prediction table The engine's prediction record.
--- @param buffer string The typed buffer.
--- @return table result, number backspaces, string typed
local function accept(prediction, buffer)
	local copy = {}
	for key, value in pairs(prediction) do copy[key] = value end
	local result = ApplyFixture.run({ prediction = copy, buffer = buffer, real_overlap = true })
	local backspaces, typed = 0, {}
	for _, event in ipairs(result.events or {}) do
		if event.isDown == true then
			if event.key == "delete" then
				backspaces = backspaces + 1
			elseif type(event.unicode) == "string" then
				typed[#typed + 1] = event.unicode
			end
		end
	end
	return result, backspaces, table.concat(typed)
end

--- Runs a region reading up to the transcribed screen.
--- @param world table
--- @return table capture The recorded capture.
local function read_screen(world)
	helpers.assert_eq(trigger(world, "llm_screen_region", "openai|gpt-4.1-mini"), true)
	local capture = world.captures[#world.captures]
	capture.on_image("image", IMAGE)
	answer(world.vision_posts[#world.vision_posts], "SCREEN: " .. SCREEN)
	return capture
end

helpers.describe("screen answers end to end (llm-vision)", function()
	helpers.it("reads a region with OpenAI, drafts three answers in order and types the first", function()
		local world = build_world()
		helpers.assert_eq(trigger(world, "llm_screen_region", "openai|gpt-4.1-mini"), true)
		helpers.assert_eq(#world.notices, 0, "a ready request shows no refusal: " .. tostring(world.notices[1]))
		helpers.assert_eq(#world.captures, 1, "one screenshot")
		local capture = world.captures[1]
		helpers.assert_true(deep_equal(capture.flags, { "-i" }), "the user draws the region")
		helpers.assert_eq(capture.max_edge, CONFIG.max_image_edge, "the downscale bound of vision.json")
		helpers.assert_eq(#world.vision_posts + #world.text_posts, 0, "nothing is sent before the image")

		capture.on_image("image", IMAGE)
		helpers.assert_eq(world.loadings, 1, "the loading row shows while the model reads")
		helpers.assert_eq(#world.vision_posts, 1, "one vision request")
		local vision = world.vision_posts[1]
		helpers.assert_eq(vision.url, "https://api.openai.com/v1/chat/completions")
		helpers.assert_eq(vision.headers.Authorization, "Bearer " .. VISION_KEY, "the provider's stored key")
		local expected = Vision.build_request("openai", {
			model = "gpt-4.1-mini", system = CONFIG.read_prompt, text = Vision.READ_USER_TEXT,
			image = IMAGE, mime = CONFIG.image_mime, max_tokens = CONFIG.read_max_tokens,
		})
		local same, where = deep_equal(vision.body, json.decode(json.encode(expected)))
		helpers.assert_true(same, "the body is build_request's, with the captured image: " .. tostring(where))
		helpers.assert_eq(#world.text_posts, 0, "no answer before the screen is read")

		answer(vision, "SCREEN: " .. SCREEN)
		for index, text in ipairs(ANSWERS) do
			helpers.assert_eq(#world.text_posts, index, "the answers run one after the other")
			assert_answer_request(world, index)
			answer(world.text_posts[index], "ANSWER: " .. text)
			local render = world.renders[#world.renders]
			helpers.assert_eq(#render.texts, index, "each answer shows as it arrives")
			for shown = 1, index do helpers.assert_eq(render.texts[shown], ANSWERS[shown], "answer order") end
			if index < #ANSWERS then
				helpers.assert_true(render.loading ~= nil, "a loading row stands for the rest")
				helpers.assert_eq(render.slots, #ANSWERS)
			else
				helpers.assert_nil(render.loading, "the last answer ends the loading")
			end
		end
		helpers.assert_eq(#world.text_posts, #ANSWERS, "one request per answer")
		helpers.assert_eq(#world.notices, 0)
		helpers.assert_true(world.engine.is_visible(), "the answers await the user")

		local shown = world.engine.get_predictions()
		helpers.assert_eq(#shown, #ANSWERS)
		for index, text in ipairs(ANSWERS) do helpers.assert_eq(shown[index].to_type, text) end
		helpers.assert_eq(shown[1].deletes, 0, "an answer erases nothing")
		local buffer = "Réponse : "
		local result, backspaces, typed = accept(shown[1], buffer)
		helpers.assert_eq(result.applied, true, "the answer is accepted")
		helpers.assert_eq(backspaces, 0, "nothing is erased")
		helpers.assert_eq(typed, ANSWERS[1], "the first answer is typed at the caret")
		helpers.assert_eq(result.state.buffer, buffer .. ANSWERS[1])
	end)

	helpers.it("types a multi-line answer verbatim, even when the buffer ends like it starts", function()
		local text = "Oui merci,\nà demain."
		local world = build_world()
		read_screen(world)
		answer(world.text_posts[1], "ANSWER: " .. text)
		local shown = world.engine.get_predictions()
		helpers.assert_eq(shown[1].to_type, text, "the lines are kept")
		local result, backspaces, typed = accept(shown[1], "Oui")
		helpers.assert_eq(result.applied, true)
		helpers.assert_eq(backspaces, 0, "no overlap trims or erases the typed text")
		helpers.assert_true(typed == text or result.clipboard_writes[1] == text,
			"the whole answer is typed or pasted: " .. tostring(typed))
		helpers.assert_eq(result.state.buffer, "Oui" .. text)
	end)

	helpers.it("reads the whole screen under the pointer with no selection", function()
		local world = build_world()
		helpers.assert_eq(trigger(world, "llm_screen_full", "openai|gpt-4.1-mini"), true)
		helpers.assert_true(deep_equal(world.captures[1].flags, { "-R", "1512,0,1920,1080" }),
			"the pointer's screen, by its frame")
	end)

	helpers.it("sends a local reading to Ollama's /api/chat with the image", function()
		local world = build_world()
		helpers.assert_eq(trigger(world, "llm_screen_region", "local"), true)
		world.captures[1].on_image("image", IMAGE)
		helpers.assert_eq(#world.vision_posts, 0, "no API provider is involved")
		helpers.assert_eq(#world.local_posts, 1)
		local post = world.local_posts[1]
		helpers.assert_true(post.url:match("^http://127%.0%.0%.1:%d+/api/chat$") ~= nil, post.url)
		helpers.assert_eq(post.body.model, CONFIG.default_models["local"], "the default local vision model")
		helpers.assert_true(deep_equal(post.body.messages[2].images, { IMAGE }), "the image rides in images")
		post.callback({ ok = true, status = 200, body = json.encode({ message = { content = "SCREEN: " .. SCREEN } }) })
		helpers.assert_eq(#world.text_posts, 1, "the answers still run on the AI menu's backend")
		assert_answer_request(world, 1)
	end)

	helpers.it("does nothing when the region selection is cancelled", function()
		local world = build_world()
		trigger(world, "llm_screen_region", "openai|gpt-4.1-mini")
		world.captures[1].on_image("cancelled")
		helpers.assert_eq(#world.vision_posts + #world.text_posts, 0, "no request")
		helpers.assert_eq(#world.notices, 0, "no notice")
		helpers.assert_eq(world.loadings, 0, "no tooltip")
	end)

	helpers.it("refuses a backend without a default model before any capture", function()
		local world = build_world()
		trigger(world, "llm_screen_region", "cerebras")
		helpers.assert_eq(#world.captures, 0, "no screenshot")
		helpers.assert_eq(world.notices[1], require("infra.i18n").get("llm.vision.no_model"))
	end)

	helpers.it("refuses like a manual prediction when the AI is off, before any capture", function()
		local world = build_world()
		world.engine.set_llm_enabled(false)
		trigger(world, "llm_screen_full", "openai")
		helpers.assert_eq(#world.captures, 0, "no screenshot")
		helpers.assert_eq(world.notices[1], require("infra.i18n").get("llm.manual_prediction.disabled"))
	end)

	helpers.it("refuses a provider without a stored key before any capture", function()
		local world = build_world()
		trigger(world, "llm_screen_region", "anthropic")
		helpers.assert_eq(#world.captures, 0, "no screenshot")
		helpers.assert_eq(world.notices[1], require("infra.i18n").get("llm.vision.read_failed"))
	end)

	helpers.it("tells the user when the screenshot fails", function()
		local world = build_world()
		trigger(world, "llm_screen_region", "openai|gpt-4.1-mini")
		world.captures[1].on_image("failed", "screencapture exited with code 1")
		helpers.assert_eq(#world.vision_posts, 0)
		helpers.assert_eq(world.notices[1], require("infra.i18n").get("llm.vision.capture_failed"))
	end)

	helpers.it("tells the user when the vision model fails or reads nothing", function()
		local world = build_world()
		trigger(world, "llm_screen_region", "openai|gpt-4.1-mini")
		world.captures[1].on_image("image", IMAGE)
		world.vision_posts[1].callback({ ok = false, status = 500, body = "{}", headers = {} })
		helpers.assert_eq(#world.text_posts, 0, "no answer without a screen")
		helpers.assert_eq(world.notices[1], require("infra.i18n").get("llm.vision.read_failed"))
		helpers.assert_true(world.hides >= 1, "the loading row is closed")

		trigger(world, "llm_screen_region", "openai|gpt-4.1-mini")
		world.captures[2].on_image("image", IMAGE)
		answer(world.vision_posts[2], "I cannot see anything.")
		helpers.assert_eq(#world.text_posts, 0)
		helpers.assert_eq(world.notices[2], require("infra.i18n").get("llm.vision.read_failed"))
	end)

	helpers.it("skips an answer without its tag and fails only when all three do", function()
		local world = build_world()
		read_screen(world)
		answer(world.text_posts[1], "Sure! Here is a reply.")
		helpers.assert_eq(#world.renders, 0, "a skipped answer shows nothing")
		answer(world.text_posts[2], "ANSWER: " .. ANSWERS[2])
		answer(world.text_posts[3], "nothing")
		local shown = world.engine.get_predictions()
		helpers.assert_eq(#shown, 1, "only the answer that came back")
		helpers.assert_eq(shown[1].to_type, ANSWERS[2])
		helpers.assert_nil(world.renders[#world.renders].loading, "the loading row ends with the last answer")
		helpers.assert_eq(#world.notices, 0)

		local failed = build_world()
		read_screen(failed)
		for index = 1, #ANSWERS do answer(failed.text_posts[index], "no tag") end
		helpers.assert_eq(failed.notices[1], require("infra.i18n").get("llm.vision.read_failed"))
		helpers.assert_eq(#failed.engine.get_predictions(), 0)
	end)

	helpers.it("drops the results of a superseded screen reading", function()
		local world = build_world()
		trigger(world, "llm_screen_region", "openai|gpt-4.1-mini")
		trigger(world, "llm_screen_region", "openai|gpt-4.1-mini")
		world.captures[1].on_image("image", IMAGE)
		helpers.assert_eq(#world.vision_posts, 0, "the stale capture sends nothing")
		world.captures[2].on_image("image", IMAGE)
		helpers.assert_eq(#world.vision_posts, 1)

		trigger(world, "llm_screen_region", "openai|gpt-4.1-mini")
		answer(world.vision_posts[1], "SCREEN: " .. SCREEN)
		helpers.assert_eq(#world.text_posts, 0, "a stale transcription drafts nothing")
		helpers.assert_eq(#world.notices, 0)
	end)

	helpers.it("stops drafting once the user dismissed the answers", function()
		local world = build_world()
		read_screen(world)
		answer(world.text_posts[1], "ANSWER: " .. ANSWERS[1])
		helpers.assert_eq(#world.text_posts, 2)
		world.engine.reset()
		answer(world.text_posts[2], "ANSWER: " .. ANSWERS[2])
		helpers.assert_eq(#world.text_posts, 2, "nothing more is asked")
		helpers.assert_eq(#world.engine.get_predictions(), 0, "nothing reappears")
	end)
end)
