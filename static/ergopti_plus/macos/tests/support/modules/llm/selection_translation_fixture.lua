--- tests/support/modules/llm/selection_translation_fixture.lua

--- ==============================================================================
--- MODULE: Selection Translation Pipeline Fixture
--- DESCRIPTION:
--- Runs the real translation, prediction, backend and clipboard text pipeline.
--- HTTP, native focus, pasteboard, timers and synthetic key delivery form the
--- modeled boundaries; document writes remain independently observable.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local shared_lua = helpers.shared("lua/")
package.path = shared_lua .. "?.lua;" .. shared_lua .. "?/init.lua;" .. package.path

local Translate = require("llm.translate")

local ENTRY_ID = "translate-cerebras"
local MODEL = "qwen-3.8-27b"
local USER_CLIPBOARD = "USER_CLIPBOARD"
local SELECTION = "On se voit demain ?"
local TRANSLATION = "See you tomorrow?"

--- @param path string Shared-relative JSON path.
--- @return table decoded
local function read_json(path)
	local fh = assert(io.open(helpers.shared(path), "r"), "cannot open " .. path)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), path .. " is not valid JSON")
end

local CONFIG = read_json("modules/llm/translate.json")
local NAMES = read_json("data/locale_names.json")

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
		id = "chatcmpl-translate",
		object = "chat.completion",
		choices = { { index = 0, message = { role = "assistant", content = content }, finish_reason = "stop" } },
		usage = { prompt_tokens = 100, completion_tokens = 12, total_tokens = 112 },
	})
end

--- Builds the synthetic key emitter over the world's document model.
--- @param world table The world whose selection and clipboard it drives.
--- @return table synthetic An adapters.synthetic_input double.
local function make_synthetic(world)
	local synthetic = {}
	local function record(mods, key)
		world.keys[#world.keys + 1] = { mods = table.concat(mods or {}, "+"), key = key }
	end
	function synthetic.emit_key_stroke(mods, key)
		record(mods, key)
		local chord = table.concat(mods or {}, "+")
		if chord == "cmd" and key == "c" and world.selection ~= "" then
			world.clipboard = world.selection
		elseif chord == "cmd" and key == "v" then
			world.pasted = world.clipboard
			world.document[#world.document + 1] = world.clipboard
			world.selection = ""
		end
		return true
	end
	function synthetic.emit_key_strokes() error("the translation never types key by key") end
	function synthetic.begin(owner, effect) return { owner = owner, effect = effect } end
	function synthetic.begin_batch(tx) return { tx = tx } end
	function synthetic.keyStroke(_, mods, key)
		record(mods, key)
		return true
	end
	function synthetic.dispatch()
		-- The reselection batch selects the text Cmd+V inserted
		world.selection = world.pasted
		return true
	end
	function synthetic.on_complete(tx, callback) tx.callback = callback end
	function synthetic.on_dispatched(tx, callback) tx.dispatched = callback end
	function synthetic.seal(tx)
		if tx.dispatched then tx.dispatched(tx, nil, "dispatched") end
		if tx.callback then tx.callback(tx, "complete") end
		return true
	end
	function synthetic.cancel(tx)
		if tx.callback then tx.callback(tx, "cancelled") end
		return true
	end
	return synthetic
end

--- Builds the real pipeline around the faked boundaries.
--- @param selection string What the user has selected.
--- @param ui_locale string|nil The interface locale, "fr" when omitted.
--- @return table world
local function build_world(selection, ui_locale)
	local world = {
		posts = {}, notices = {}, keys = {}, document = {}, renders = {}, loadings = 0, hides = 0,
		selection = selection, clipboard = USER_CLIPBOARD, pasted = nil, focus = "7:101",
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
	package.loaded["infra.logger"] = helpers.make_logger_stub()

	local hs_stub = _G.hs
	world.clock_ns = 0
	hs_stub.timer.absoluteTime = function() return world.clock_ns end
	local native_timer_new = hs_stub.timer.new
	hs_stub.timer.new = function(delay, callback)
		return native_timer_new(delay, function()
			world.clock_ns = world.clock_ns + math.ceil(delay * 1e9)
			callback()
		end)
	end
	local front_app = {
		title = function() return "TranslateApp" end,
		name = function() return "TranslateApp" end,
		bundleID = function() return "test.translate" end,
		path = function() return "/Applications/Translate.app" end,
		pid = function() return 7 end,
	}
	hs_stub.application = hs_stub.application or {}
	hs_stub.application.frontmostApplication = function() return front_app end
	hs_stub.pasteboard = {
		readAllData = function()
			if world.clipboard == nil then return {} end
			return { ["public.utf8-plain-text"] = world.clipboard }
		end,
		writeAllData = function(data)
			world.clipboard = data["public.utf8-plain-text"]
			return true
		end,
		getContents = function() return world.clipboard end,
		setContents = function(value)
			world.clipboard = value
			return true
		end,
		clearContents = function()
			world.clipboard = nil
			return true
		end,
	}

	for _, name in ipairs({
		"modules.llm", "modules.llm.profiles", "modules.llm.api_remote", "modules.llm.api_ollama",
		"modules.llm.api_mlx", "modules.llm.parser", "modules.llm.prompt_builder",
		"modules.llm.streaming_handler", "modules.llm.warmup_controller", "modules.llm.app_filter",
		"modules.llm.api_common", "modules.llm.prediction_engine", "modules.llm.progressive_reveal",
		"modules.llm.selection_translation", "modules.shortcuts.actions.text",
	}) do
		package.loaded[name] = nil
	end
	package.loaded["adapters.synthetic_input"] = make_synthetic(world)
	package.loaded["adapters.window_info"] = {
		focused_identity = function() return world.focus end,
		getFocused = function()
			return { appId = "TranslateApp", windowTitle = "Draft", bundleId = "test.translate", executablePath = "" }
		end,
		getAll = function() return {} end,
	}
	require("tests.support.modules.llm.selection_translation_destination").attach(world)
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

	-- The i18n stub of load_with_stubs, fresh for every world: its locale is
	-- the interface language "ui" follows
	local i18n = require("infra.i18n")
	i18n.get_locale = function() return ui_locale or "fr" end
	world.i18n = i18n

	local core = require("modules.llm")
	world.core = core
	local CoreState = get_upvalue(core.get_active_profile, "CoreState")
	assert(type(CoreState) == "table", "the LLM core state must be reachable")
	CoreState.backend = "api"
	CoreState.active_profile_id = "advanced"
	local api = core.api_remote
	api.set_entries({ { id = ENTRY_ID, provider = "cerebras", token = "translate-token", model = MODEL } })
	api.set_active_entry_id(ENTRY_ID)
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

	local engine = require("modules.llm.prediction_engine")
	world.engine = engine
	local engine_state = {
		buffer = "",
		llm_buffer = "",
		mappings = {},
		DELAYS = { llm_prediction = 1 },
		ignored_window_titles = {},
		ignored_window_patterns = {},
		suppress_rescan_keep_buffer = function() end,
	}
	engine.init(engine_state)
	world.engine_state = engine_state
	engine.set_llm_enabled(true)
	world.flow = require("modules.llm.selection_translation")
	-- Only the timers of the actions run: the backend's own stay untouched
	world.timer_baseline = #hs_stub.timer.__timers
	package.loaded["modules.keymap"] = {
		request_selection_translation = function(value, parent) return world.flow.run(value, parent) end,
	}
	return world
end

--- Runs a scenario on a fresh world.
--- @param selection string What the user has selected.
--- @param ui_locale string|nil The interface locale.
--- @param scenario function Receives the world.
local function with_world(selection, ui_locale, scenario)
	return require("tests.support.modules.llm.selection_translation_scope").run(function()
		return scenario(build_world(selection, ui_locale))
	end)
end

--- Fires, in order, every pending timer of the text pipeline (never its 2 s
--- ownership failsafe), until none is left.
--- @param world table
local function settle(world)
	local timers = _G.hs.timer.__timers
	local progressed = true
	while progressed do
		progressed = false
		for index = world.timer_baseline + 1, #timers do
			local timer = timers[index]
			if timer.running and timer.fired == 0 and (tonumber(timer.delay) or 0) < 1.5 then
				timer:fire()
				progressed = true
				break
			end
		end
	end
end

--- Runs the translation as the gesture registry dispatches it, then lets the
--- selection copy complete.
--- @param world table
--- @param value string The binding's language parameter.
--- @return boolean started
local function trigger(world, value)
	helpers.assert_eq(world.actions.set_action_parameter("tap_3", "llm_translate_selection", value), true,
		"a valid binding")
	local started = world.actions.execute_single("llm_translate_selection", "tap_3")
	settle(world)
	return started
end

--- Answers one captured request as the provider would.
--- @param post table A captured request.
--- @param content string The model's answer.
local function answer(post, content)
	post.callback({ ok = true, status = 200, body = completion_body(content), headers = {} })
end

--- Accepts candidate `index` as the keymap bridge does: the engine consumes it,
--- then its own acceptance runs, and the replacement completes.
--- @param world table
--- @param index number
--- @return boolean applied
local function accept(world, index)
	local prediction = world.engine.consume(index)
	helpers.assert_true(prediction ~= nil, "a candidate to accept")
	helpers.assert_eq(type(prediction.on_accept), "function", "the candidate applies itself")
	local applied = prediction.on_accept(prediction.to_type)
	settle(world)
	return applied
end

--- Asserts that the request translates SELECTION into `language`.
--- @param post table
--- @param language string The native name of the target language.
local function assert_request(post, language)
	helpers.assert_true(post.url:find("https://api.cerebras.ai/v1/chat/completions", 1, true) == 1,
		"the AI menu's backend answers: " .. tostring(post.url))
	helpers.assert_eq(post.body.model, MODEL)
	helpers.assert_eq(post.body.messages[1].content, Translate.system_prompt(CONFIG, language),
		"the translate.json prompt into " .. language)
	helpers.assert_eq(post.body.messages[2].content, Translate.user_text(CONFIG, SELECTION), "the selection as TEXT")
	helpers.assert_eq(#post.body.messages, 2, "one plain chat turn, no PREFIX/TAIL")
	helpers.assert_eq(post.body.max_tokens, CONFIG.max_tokens)
	helpers.assert_true(post.body.stream ~= true, "no streaming")
end

return {
	build_world = build_world, with_world = with_world, settle = settle,
	trigger = trigger, answer = answer, accept = accept, assert_request = assert_request,
	SELECTION = SELECTION, TRANSLATION = TRANSLATION, USER_CLIPBOARD = USER_CLIPBOARD,
	NAMES = NAMES,
}
