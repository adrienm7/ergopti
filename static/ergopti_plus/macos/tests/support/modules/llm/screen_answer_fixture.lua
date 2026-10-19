--- tests/support/modules/llm/screen_answer_fixture.lua

--- ==============================================================================
--- MODULE: Screen Answer Pipeline Fixture
--- DESCRIPTION:
--- Retains the existing end-to-end world over real screen flow, Engine, local
--- model preflight and consent owners. Native capture, HTTP, dialog and tooltip
--- ports remain observable and independently completed by scenarios.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")
local TEXT_ENTRY_ID = "vision-cerebras"
local TEXT_MODEL = "qwen-3.8-27b"
local VISION_ENTRY_ID = "vision-openai"
local VISION_KEY = "openai-secret"

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

--- Answers the local server's pending model listing with these models.
--- @param world table
--- @param names table Installed model names.
local function list_local_models(world, names)
	local pending = world.local_gets[#world.local_gets]
	assert(pending, "a model listing was asked for")
	local models = {}
	for index, name in ipairs(names) do models[index] = { name = name, model = name } end
	pending.callback({ ok = true, status = 200, body = json.encode({ models = json.array(models) }), headers = {} })
end

--- Builds the real pipeline around the faked boundaries.
--- @return table world
local function build_world()
	local world = {
		captures = {}, vision_posts = {}, local_posts = {}, text_posts = {},
		notices = {}, loadings = 0, renders = {}, hides = 0,
		-- The local server's model listings, the missing-model dialogs and the
		-- downloads their button asked for
		local_gets = {}, alerts = {}, installs = {},
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
	package.loaded["infra.dialog_util"] = {
		block_alert = function(title, message, first, second)
			world.alerts[#world.alerts + 1] = { title = title, message = message, buttons = { first, second } }
			return first
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
	local_vision.get = function(url, headers, callback)
		world.local_gets[#world.local_gets + 1] = { url = url, headers = headers, callback = callback }
		return true
	end
	local offer = require("modules.llm.local_model_offer")
	offer.set_installer(function(model)
		world.installs[#world.installs + 1] = model
		return true
	end)

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
		request_screen_answers = function(value, mode, parent, answers)
			return world.flow.run(value, mode, parent, answers)
		end,
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

local M = { build_world = build_world, trigger = trigger, list_local_models = list_local_models }
return M
