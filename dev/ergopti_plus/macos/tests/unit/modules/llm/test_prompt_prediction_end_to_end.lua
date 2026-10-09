--- tests/unit/modules/llm/test_prompt_prediction_end_to_end.lua

--- ==============================================================================
--- MODULE: Prompt Prediction End to End (llm-prompt-prediction)
--- DESCRIPTION:
--- Runs the whole rewrite feature without a model: the real gesture action
--- registry, prediction engine, streaming handler, LLM core dispatcher, remote
--- backend (Cerebras, OpenAI dialect), shared parser and profile registry. Only
--- the boundaries are faked: the HTTP transport (requests are captured and
--- answered with canned bodies), the tooltip canvas, and the key emitter of the
--- acceptance step (the real keymap bridge and expander drive the synthetic
--- input collector, whose events are inspected).
---
--- ROOT CAUSE ENCODED:
--- The rewrite prompt and the per-prompt actions only work when every layer
--- agrees: the tail sent to the model must be the current sentence, the budget
--- must fit a rewritten sentence, the parser must see that same tail, the noise
--- gate must keep a capitalized answer, and acceptance must erase exactly the
--- sentence. Each layer's unit test can pass while their composition does not.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")
local Rewrite = require("llm.rewrite")
local SharedPromptBuilder = require("llm.prompt_builder")
local ApplyFixture = require("tests.support.apply_prediction_fixture")

local ENTRY_ID = "e2e-cerebras"
local MODEL = "qwen-3.8-27b"

--- Returns one named closure upvalue, or nil when the closure does not own it.
--- @param fn function Closure to inspect.
--- @param target string Upvalue name.
--- @return any value
--- @return number|nil index
local function get_upvalue(fn, target)
	for index = 1, 256 do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == target then return value, index end
	end
	return nil, nil
end

--- Encodes an OpenAI-dialect chat completion carrying one answer.
--- @param content string The model's answer.
--- @return string body
local function completion_body(content)
	return json.encode({
		id = "chatcmpl-e2e",
		object = "chat.completion",
		choices = { { index = 0, message = { role = "assistant", content = content }, finish_reason = "stop" } },
		usage = { prompt_tokens = 100, completion_tokens = 12, total_tokens = 112 },
	})
end

--- Builds the real pipeline around a captured HTTP transport.
--- @param buffer string What the user has typed.
--- @return table world { actions, core, engine, posts, shown, notices, profile_changes }
local function build_world(buffer)
	local world = { posts = {}, shown = nil, notices = {}, renders = 0 }

	-- Every driver module is loaded fresh: the acceptance fixture of a previous
	-- scenario leaves its own doubles (manifest reader, keymap, tooltip) cached
	for name in pairs(package.loaded) do
		if type(name) == "string" and (name:find("^modules%.") or name:find("^adapters%.")
			or name:find("^infra%.") or name:find("^ui%.")) then
			package.loaded[name] = nil
		end
	end
	-- The gesture registry first: loading it installs a fresh hs stub, which the
	-- engine and the core capture when they load next
	local _gestures = helpers.load_with_stubs("modules.gestures")
	world.actions = require("modules.gestures.actions")
	world.actions.init({ action_params = {} })

	local front_app = {
		title = function() return "E2EApp" end,
		name = function() return "E2EApp" end,
		bundleID = function() return "test.e2e" end,
		path = function() return "/Applications/E2E.app" end,
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
		show_loading = function() return true end,
		show = function(content)
			world.notices[#world.notices + 1] = content
			return true
		end,
		show_predictions = function(predictions)
			world.renders = world.renders + 1
			world.shown = predictions
			return true
		end,
		get_current_index = function() return 1 end,
		make_diff_styled = function() return true end,
		reset_llm_timer = function() return true end,
		mark_chain_complete = function() return true end,
		tint = function() return {} end,
		hide = function() return true end,
		hide_forced_silent = function() return true end,
	}

	-- The real core, dispatching to the real remote backend
	local core = require("modules.llm")
	world.core = core
	local CoreState = get_upvalue(core.get_active_profile, "CoreState")
	assert(type(CoreState) == "table", "the LLM core state must be reachable")
	CoreState.backend = "api"
	CoreState.active_profile_id = "advanced"
	local api = core.api_remote
	api.set_entries({ { id = ENTRY_ID, provider = "cerebras", token = "e2e-token", model = MODEL } })
	api.set_active_entry_id(ENTRY_ID)
	-- Readiness is the remote warmup's verdict, a network probe: grant it
	local _, ready_index = get_upvalue(api.is_ready, "_is_ready")
	assert(ready_index, "the remote readiness flag must be reachable")
	debug.setupvalue(api.is_ready, ready_index, true)
	local inference = get_upvalue(api.cancel_streaming, "_infer_client")
	assert(type(inference) == "table", "the remote HTTP owner must be reachable")
	inference.post = function(url, headers, body, callback)
		world.posts[#world.posts + 1] = {
			url = url, headers = headers, body = json.decode(body), callback = callback,
		}
		return true
	end
	world.set_active_profile_calls = 0
	local set_active_profile = core.set_active_profile
	core.set_active_profile = function(...)
		world.set_active_profile_calls = world.set_active_profile_calls + 1
		return set_active_profile(...)
	end

	local engine = require("modules.llm.prediction_engine")
	world.engine = engine
	engine.init({
		buffer = buffer,
		llm_buffer = buffer,
		mappings = {},
		DELAYS = { llm_prediction = 1 },
		ignored_window_titles = {},
		ignored_window_patterns = {},
		suppress_rescan_keep_buffer = function() end,
	})
	engine.set_llm_enabled(true)
	engine.set_llm_num_predictions(1)
	engine.set_llm_sequential_mode(false)
	-- The keymap bridge only gates on an in-flight synthetic action, covered by
	-- the bridge's own tests; here it hands the value straight to the engine
	package.loaded["modules.keymap"] = {
		request_prompt_prediction = engine.request_prompt_prediction,
		request_manual_prediction = engine.request_manual_prediction,
	}
	return world
end

--- Answers one captured request as the provider would.
--- @param post table A captured request.
--- @param content string The model's answer.
local function answer(post, content)
	post.callback({ ok = true, status = 200, body = completion_body(content), headers = {} })
end

--- Accepts a prediction through the real keymap bridge and expander.
--- @param prediction table The engine's prediction record.
--- @param buffer string The typed buffer.
--- @return table result The apply fixture's observations.
--- @return number backspaces Backspace presses emitted.
--- @return string typed The text the emitter typed or pasted.
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

helpers.describe("prompt prediction end to end (llm-prompt-prediction)", function()
	local BUFFER = "Bonjour Marc. ok pr jd 14h"
	local SPAN = "ok pr jd 14h"

	helpers.it("rewrites the current sentence from llm_prompt_prediction 'rewrite|2' and accepts it", function()
		local world = build_world(BUFFER)
		helpers.assert_eq(world.actions.set_action_parameter("tap_3", "llm_prompt_prediction", "rewrite|2"), true)
		helpers.assert_eq(world.actions.execute_single("llm_prompt_prediction", "tap_3"), true)
		helpers.assert_eq(#world.notices, 0, "a ready request shows no refusal")
		helpers.assert_eq(#world.posts, 1, "the first of the two requests is on the wire")

		local request = world.posts[1]
		helpers.assert_true(request.url:find("https://api.cerebras.ai/v1/chat/completions", 1, true) == 1,
			"the Cerebras chat endpoint: " .. tostring(request.url))
		helpers.assert_eq(request.body.model, MODEL)
		helpers.assert_eq(request.body.reasoning_effort, "none", "the provider's model extras still apply")
		local system = request.body.messages[1].content
		helpers.assert_true(system:find("text rewriting engine", 1, true) ~= nil
			and system:find("REWRITE:", 1, true) ~= nil, "the system prompt is the rewrite prompt")
		helpers.assert_eq(request.body.messages[2].content,
			'PREFIX: "' .. BUFFER .. '"\nTAIL: "' .. SPAN .. '"',
			"the user turn carries the context and the current sentence as TAIL")
		helpers.assert_eq(request.body.max_tokens, Rewrite.max_tokens(SPAN), "the rewrite budget")

		answer(request, "REWRITE: Ok pour jeudi 14 h.")
		helpers.assert_eq(#world.posts, 2, "the binding's count asks for a second rewrite")
		helpers.assert_eq(world.posts[2].body.messages[2].content, request.body.messages[2].content,
			"the second request rewrites the same sentence")
		answer(world.posts[2], "REWRITE: OK pour jeudi, 14 h.")

		helpers.assert_true(world.renders >= 1, "the predictions reach the tooltip")
		local shown = world.engine.get_predictions()
		helpers.assert_eq(#shown, 2, "both rewrites are offered")
		helpers.assert_eq(shown[1].rewrite, true)
		helpers.assert_eq(shown[1].deletes, #SPAN, "the first rewrite replaces the whole sentence")
		helpers.assert_eq(shown[1].to_type, "Ok pour jeudi 14 h.")
		helpers.assert_eq(world.set_active_profile_calls, 0, "the global profile is never switched")
		helpers.assert_eq(world.core.get_active_profile().id, "advanced", "and still is the advanced one")
		local found, count = world.engine.get_llm_runtime_setting("llm_num_predictions")
		helpers.assert_true(found)
		helpers.assert_eq(count, 1, "the AI menu's count is unchanged")

		local result, backspaces, typed = accept(shown[1], BUFFER)
		helpers.assert_eq(result.applied, true, "the rewrite is accepted")
		helpers.assert_eq(backspaces, #SPAN, "exactly the sentence is erased")
		helpers.assert_eq(typed, "Ok pour jeudi 14 h.", "then the rewrite is typed")
		helpers.assert_eq(result.state.buffer, "Bonjour Marc. Ok pour jeudi 14 h.",
			"the buffer holds the rewritten sentence")
	end)

	helpers.it("rewrites from the llm_predict_rewrite preset with the AI menu's count", function()
		local world = build_world(BUFFER)
		helpers.assert_eq(world.actions.execute_single("llm_predict_rewrite", "tap_3"), true)
		helpers.assert_eq(#world.posts, 1)
		helpers.assert_eq(world.posts[1].body.messages[2].content,
			'PREFIX: "' .. BUFFER .. '"\nTAIL: "' .. SPAN .. '"')
		answer(world.posts[1], "REWRITE: Ok pour jeudi 14 h.")
		helpers.assert_eq(#world.posts, 1, "the menu's count is one: a single request")
		local shown = world.engine.get_predictions()
		helpers.assert_eq(#shown, 1)
		helpers.assert_eq(world.set_active_profile_calls, 0)
		local result, backspaces, typed = accept(shown[1], BUFFER)
		helpers.assert_eq(backspaces, #SPAN)
		helpers.assert_eq(typed, "Ok pour jeudi 14 h.")
		helpers.assert_eq(result.state.buffer, "Bonjour Marc. Ok pour jeudi 14 h.")
	end)

	-- The acceptance overlap resolver matched the sentence's last word against
	-- the rewrite's first one and erased only "oui": "Bonjour. oui Oui, oui."
	helpers.it("erases the whole sentence even when it ends like the rewrite starts", function()
		local buffer = "Bonjour. oui oui"
		local world = build_world(buffer)
		helpers.assert_eq(world.actions.execute_single("llm_predict_rewrite", "tap_3"), true)
		answer(world.posts[1], "REWRITE: Oui, oui.")
		local shown = world.engine.get_predictions()
		helpers.assert_eq(#shown, 1)
		local result, backspaces, typed = accept(shown[1], buffer)
		helpers.assert_eq(backspaces, #"oui oui", "the rewrite names its own span")
		helpers.assert_eq(typed, "Oui, oui.")
		helpers.assert_eq(result.state.buffer, "Bonjour. Oui, oui.")
	end)

	helpers.it("still continues the text with the global advanced profile", function()
		local buffer = "Je vous envoit ce mail pour vous dir"
		local world = build_world(buffer)
		helpers.assert_eq(world.actions.execute_single("llm_generate_prediction", "tap_3"), true)
		helpers.assert_eq(#world.posts, 1)
		local request = world.posts[1]
		helpers.assert_true(request.body.messages[1].content:find("TAIL_CORRECTED", 1, true) ~= nil,
			"the global advanced prompt")
		helpers.assert_eq(request.body.messages[2].content,
			'PREFIX: "' .. buffer .. '"\nTAIL: "ce mail pour vous dir"',
			"the continuation tail stays the last five words")
		local _, max_words = world.engine.get_llm_runtime_setting("llm_max_words")
		helpers.assert_eq(request.body.max_tokens,
			SharedPromptBuilder.build_params(buffer, { max_words = max_words }).max_tokens,
			"the continuation budget, from the word cap")
		answer(request, "TAIL_CORRECTED: ce mail pour vous dire\nNEXT_WORDS: que tout est prêt.")
		local shown = world.engine.get_predictions()
		helpers.assert_eq(#shown, 1)
		helpers.assert_true(shown[1].rewrite ~= true)
		local result = accept(shown[1], buffer)
		helpers.assert_eq(result.applied, true)
		helpers.assert_eq(result.state.buffer, buffer .. "e que tout est prêt",
			"the tail is corrected in place and the next words appended")
	end)
end)

helpers.it("the configurable translation shortcut carries its own target into the actual context pipeline", function()
	local world = build_world("Bonjour Marc. On se voit demain ?")
	helpers.assert_eq(world.actions.set_action_parameter("tap_3", "llm_translate_context", "Esperanto"), true)
	helpers.assert_eq(world.actions.execute_single("llm_translate_context", "tap_3"), true)
	helpers.assert_eq(#world.posts, 1)
	helpers.assert_true(world.posts[1].body.messages[1].content:find("Translate TAIL into Esperanto", 1, true) ~= nil)
	helpers.assert_eq(world.posts[1].body.messages[2].content, 'PREFIX: "Bonjour Marc. On se voit demain ?"\nTAIL: "On se voit demain ?"')
	helpers.assert_eq(world.core.get_active_profile().id, "advanced")
end)
