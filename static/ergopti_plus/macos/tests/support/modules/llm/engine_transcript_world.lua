--- tests/support/modules/llm/engine_transcript_world.lua

--- ==============================================================================
--- MODULE: macOS Engine Transcript World
--- DESCRIPTION:
--- Builds the real macOS prediction engine (real gesture action registry,
--- streaming handler, LLM core dispatcher, remote backend, shared parser and
--- profile registry) on recording fakes of its three ports and exposes it to
--- the shared transcript runner (_shared/lua/test/llm_engine_transcript.lua):
--- the TimerScheduler is the adapter the engine arms its debounce on, the
--- HttpClient is the remote backend's inference client, the TooltipRenderer is
--- the prediction tooltip behind adapters.prediction_tooltip_port. What each port is
--- asked is recorded in the corpus vocabulary.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")
local PromptBuilder = require("llm.prompt_builder")
local InfoBar = require("llm.request_plan.info_bar")

local M = {}

local ENTRY_ID = "e2e-cerebras"
local MODEL = "qwen-3.8-27b"
local EM_DASH_JOIN = " \226\128\148 "

--- Returns one named closure upvalue, or nil when the closure does not own it.
local function get_upvalue(fn, target)
	for index = 1, 256 do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == target then return value, index end
	end
	return nil, nil
end

local function completion_body(content)
	return json.encode({
		id = "chatcmpl-transcript", object = "chat.completion",
		choices = { { index = 0, message = { role = "assistant", content = content }, finish_reason = "stop" } },
		usage = { prompt_tokens = 100, completion_tokens = 12, total_tokens = 112 },
	})
end

--- Splits the info bar text the engine hands the tooltip into its pieces.
local function split_info(text)
	local parts, from = {}, 1
	while true do
		local at = text:find(EM_DASH_JOIN, from, true)
		if not at then parts[#parts + 1] = text:sub(from); return parts end
		parts[#parts + 1] = text:sub(from, at - 1)
		from = at + #EM_DASH_JOIN
	end
end

--- Runs body against a fresh engine on recording ports.
--- @param config table { debounce_ms, count, profile, user_prompt?, watch_timers_ms }
--- @param body function Receives the world.
function M.with_world(config, body)
	local watched = {}
	for _, ms in ipairs(config.watch_timers_ms) do watched[ms] = true end
	local log, posts = {}, {}
	local world = { model_label = MODEL, clock = 1000, paused = false }

	for name in pairs(package.loaded) do
		if type(name) == "string" and (name:find("^modules%.") or name:find("^adapters%.")
			or name:find("^infra%.") or name:find("^ui%.")) then
			package.loaded[name] = nil
		end
	end
	helpers.load_with_stubs("modules.gestures")
	local actions = require("modules.gestures.actions")
	actions.init({ action_params = {} })
	local front_app = {
		title = function() return "E2EApp" end, name = function() return "E2EApp" end,
		bundleID = function() return "test.e2e" end, path = function() return "/Applications/E2E.app" end,
		pid = function() return 7 end,
	}
	helpers.load_with_stubs("infra.logger", {
		application = { frontmostApplication = function() return front_app end },
	})
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	_G.hs.timer.secondsSinceEpoch = function() return world.clock end

	for _, name in ipairs({
		"modules.llm", "modules.llm.profiles", "modules.llm.api_remote", "modules.llm.api_ollama",
		"modules.llm.api_mlx", "modules.llm.parser", "modules.llm.prompt_builder",
		"modules.llm.streaming_handler", "modules.llm.warmup_controller", "modules.llm.app_filter",
		"modules.llm.api_common", "modules.llm.prediction_engine", "modules.llm.progressive_reveal",
	}) do
		package.loaded[name] = nil
	end
	package.loaded["modules.keymap.utils"] = { is_ignored_window = function() return false end }
	package.loaded["modules.shortcuts.script_control"] = { is_paused = function() return world.paused end }
	package.loaded["modules.keystats"] = {
		get_live_stats = function() return { wpm_physical = 0 } end,
		log_llm = function() end, log_llm_failed = function() end,
		log_llm_suggested = function() end, log_llm_dismissed = function() end,
	}
	-- The TooltipRenderer port: only a render that is not a loading placeholder is recorded.
	package.loaded["ui.tooltip"] = {
		set_navigate_callback = function() end, set_enter_validates = function() end,
		set_llm_timeout = function() end, set_chain_start = function() return true end,
		show_loading = function() return true end,
		show = function() return true end,
		show_predictions = function(predictions, _, _, info_bar, _, _, _, _, loading_text)
			if loading_text == nil then
				local call = { port = "tooltip", call = "show", candidates = #predictions,
					info = type(info_bar) == "string" and split_info(info_bar) or nil }
				-- The success callback paints the final state again after the partial paint
				-- that already held it; the screen does not change, so it is one call here.
				local previous = log[#log]
				if not (previous and previous.port == "tooltip" and previous.candidates == call.candidates
					and table.concat(previous.info or {}, "|") == table.concat(call.info or {}, "|")) then
					log[#log + 1] = call
				end
			end
			return true
		end,
		is_hotstring_visible = function() return false end,
		get_current_index = function() return 1 end,
		make_diff_styled = function() return true end,
		reset_llm_timer = function() return true end,
		mark_chain_complete = function() return true end,
		tint = function() return {} end,
		hide = function() return true end,
		hide_forced_silent = function() return true end,
	}

	-- The harness' i18n stub echoes keys: the labels the info bar shows are the real ones.
	local i18n = package.loaded["infra.i18n"]
	local Locale = require("infra.locale")
	local saved_get = i18n.get
	i18n.get = function(key) return Locale.get(key) or key end

	local core = require("modules.llm")
	local core_state = get_upvalue(core.get_active_profile, "CoreState")
	assert(type(core_state) == "table", "the LLM core state must be reachable")
	core_state.backend = "api"
	core_state.active_profile_id = config.profile
	if config.user_prompt then
		core_state.user_profiles = { {
			id = config.user_prompt.id, label = config.user_prompt.label,
			system_single = config.user_prompt.system_single,
		} }
	end
	local api = core.api_remote
	api.set_entries({ { id = ENTRY_ID, provider = "cerebras", token = "e2e-token", model = MODEL } })
	api.set_active_entry_id(ENTRY_ID)
	local _, ready_index = get_upvalue(api.is_ready, "_is_ready")
	assert(ready_index, "the remote readiness flag must be reachable")
	debug.setupvalue(api.is_ready, ready_index, true)
	-- The HttpClient port: the remote backend's inference client.
	local inference = get_upvalue(api.cancel_streaming, "_infer_client")
	assert(type(inference) == "table", "the remote HTTP owner must be reachable")
	inference.post = function(_, _, request_body, callback)
		local decoded = json.decode(request_body)
		posts[#posts + 1] = { callback = callback }
		log[#log + 1] = { port = "http", call = "post", max_tokens = decoded.max_tokens }
		return true
	end

	local engine = require("modules.llm.prediction_engine")
	-- The TimerScheduler port: the adapter the engine arms its debounce on.
	local scheduler = require("adapters.timer_scheduler")
	local real_after = scheduler.after
	scheduler.after = function(delay_sec, fn)
		local delay_ms = math.floor(delay_sec * 1000 + 0.5)
		if watched[delay_ms] then log[#log + 1] = { port = "timer", call = "after", delay_ms = delay_ms } end
		return real_after(delay_sec, fn)
	end
	local scheduler_hs = get_upvalue(real_after, "hs")
	assert(type(scheduler_hs) == "table" and type(scheduler_hs.timer.__timers) == "table",
		"the timer scheduler's native stub must be reachable")
	local timers = scheduler_hs.timer.__timers

	local state = {
		buffer = "", llm_buffer = "", mappings = {}, DELAYS = { llm_prediction = 1 },
		ignored_window_titles = {}, ignored_window_patterns = {},
		suppress_rescan_keep_buffer = function() return true end,
	}
	engine.init(state)
	engine.set_llm_enabled(true)
	engine.set_llm_num_predictions(config.count)
	engine.set_llm_sequential_mode(false)
	engine.set_llm_debounce(config.debounce_ms / 1000)
	engine.set_llm_min_words(0)
	package.loaded["modules.keymap"] = {
		request_prompt_prediction = engine.request_prompt_prediction,
		request_manual_prediction = engine.request_manual_prediction,
		toggle_live_prompt = engine.toggle_live_prompt,
	}

	function world.keystroke(text)
		world.clock = world.clock + 10
		state.buffer = text
		state.llm_buffer = text
		helpers.assert_eq(engine.stop_timer(), true, "the keystroke cancels the pending request")
		helpers.assert_eq(engine.start_timer(), true, "the keystroke arms the typing trigger")
	end
	--- Time passing: the running watched timers that fall due fire, shortest first.
	function world.elapse(ms)
		local due = {}
		for _, timer in ipairs(timers) do
			local delay_ms = math.floor((tonumber(timer.delay) or -1) * 1000 + 0.5)
			if timer.running and watched[delay_ms] and delay_ms <= ms then
				due[#due + 1] = { timer = timer, delay_ms = delay_ms }
			end
		end
		table.sort(due, function(a, b) return a.delay_ms < b.delay_ms end)
		for _, entry in ipairs(due) do entry.timer:fire() end
	end
	function world.answer(index, text)
		local post = assert(posts[index], "no request " .. index .. " was sent")
		local before = #timers
		post.callback({ ok = true, status = 200, body = completion_body(text), headers = {} })
		-- A batch is revealed prediction by prediction on zero-delay timers the answer arms:
		-- only those run, never an older timer of the engine's own.
		for _ = 1, 16 do
			local fired = false
			for index = before + 1, #timers do
				local timer = timers[index]
				if timer.running and (tonumber(timer.delay) or -1) == 0 then timer:fire(); fired = true end
			end
			if not fired then break end
		end
	end
	function world.toggle_live(value)
		helpers.assert_eq(actions.set_action_parameter("tap_3", "llm_live_prompt_toggle", value), true)
		return actions.execute_single("llm_live_prompt_toggle", "tap_3")
	end
	function world.delete_prompt(_) core_state.user_profiles = {} end
	function world.base_tokens(text)
		local _, max_words = engine.get_llm_runtime_setting("llm_max_words")
		return PromptBuilder.build_params(text, { max_words = max_words }).max_tokens
	end
	function world.profile_label(id)
		return InfoBar.short_profile_label(Locale.get("llm.profile." .. id .. ".label"))
	end
	function world.calls() return log end

	local ok, err = pcall(body, world)
	i18n.get = saved_get
	engine.stop_live_prompt("scenario end", true)
	if not ok then error(err, 0) end
end

return M
