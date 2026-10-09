--- tests/unit/modules/llm/test_selection_translation_end_to_end.lua

--- ==============================================================================
--- MODULE: Translation of the Selection End to End (llm_translate_selection)
--- DESCRIPTION:
--- Runs the llm_translate_selection action without a model: the real gesture
--- action registry and parameter validator, translation module, prediction
--- engine refusals and tooltip surface, LLM core dispatcher, remote backend
--- (Cerebras, OpenAI dialect) and clipboard text pipeline. Only the boundaries
--- are faked: the HTTP transport (requests are captured and answered with
--- canned bodies), the pasteboard and the synthetic key emitter (a small
--- document model: Cmd+C copies the selection, Cmd+V replaces it, the
--- reselection batch selects the pasted text), the native timers (fired in
--- order), the focused window and the tooltip canvas. The acceptance runs the
--- candidate's own acceptance as the keymap bridge does (the bridge's routing
--- is pinned by test_apply_prediction_own_acceptance.lua).
---
--- ROOT CAUSE ENCODED:
--- No action translated the selection. It only works when every layer agrees:
--- nothing is read before the refusals, the request carries the translate.json
--- prompt naming the target language natively and the selection as TEXT, the
--- tooltip offers exactly one candidate, and accepting it replaces the
--- selection, which stays selected, while Escape leaves the text untouched.
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
	function synthetic.seal() return true end
	function synthetic.cancel() return true end
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
	scenario(build_world(selection, ui_locale))
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

helpers.describe("translation of the selection end to end (llm_translate_selection)", function()
	helpers.it("translates into the interface language, offers one candidate and replaces the selection", function()
		with_world(SELECTION, "fr", function(world)
			helpers.assert_eq(trigger(world, "ui"), true)
			helpers.assert_eq(#world.notices, 0, "a ready request shows no refusal: " .. tostring(world.notices[1]))
			helpers.assert_eq(world.clipboard, USER_CLIPBOARD, "reading the selection gives the clipboard back")
			helpers.assert_eq(#world.document, 0, "reading the selection changes nothing")
			helpers.assert_eq(world.loadings, 1, "the loading row shows while the model translates")
			helpers.assert_eq(#world.posts, 1, "one request")
			assert_request(world.posts[1], "Français")

			answer(world.posts[1], "TRANSLATION: " .. TRANSLATION)
			local render = world.renders[#world.renders]
			helpers.assert_eq(#render.texts, 1, "one candidate")
			helpers.assert_eq(render.texts[1], TRANSLATION)
			helpers.assert_nil(render.loading, "no loading row is left")
			helpers.assert_eq(#world.document, 0, "nothing is typed before the user accepts")

			helpers.assert_eq(accept(world, 1), true, "the replacement starts")
			helpers.assert_eq(world.document[1], TRANSLATION, "the selection is replaced by the translation")
			helpers.assert_eq(#world.document, 1)
			helpers.assert_eq(world.selection, TRANSLATION, "and the translation is selected")
			helpers.assert_eq(world.clipboard, USER_CLIPBOARD, "the user's clipboard is restored")
		end)
	end)

	helpers.it("names a fixed target language natively, whatever the interface", function()
		with_world(SELECTION, "fr", function(world)
			trigger(world, "ja")
			assert_request(world.posts[1], "日本語")
		end)
	end)

	helpers.it("follows the interface language when it changes", function()
		with_world(SELECTION, "de", function(world)
			trigger(world, "ui")
			assert_request(world.posts[1], NAMES.locales.de.name)
		end)
	end)

	helpers.it("leaves the text untouched when the candidate is dismissed", function()
		with_world(SELECTION, "fr", function(world)
			trigger(world, "ui")
			answer(world.posts[1], "TRANSLATION: " .. TRANSLATION)
			local before = #world.keys
			world.engine.reset()
			settle(world)
			helpers.assert_eq(#world.engine.get_predictions(), 0, "no candidate is left")
			helpers.assert_eq(#world.keys, before, "no key reaches the document")
			helpers.assert_eq(#world.document, 0)
			helpers.assert_eq(world.selection, SELECTION)
		end)
	end)

	helpers.it("tells the user to select a text first, and sends nothing", function()
		with_world("", "fr", function(world)
			trigger(world, "ui")
			helpers.assert_eq(#world.posts, 0, "no request")
			helpers.assert_eq(world.loadings, 0, "no tooltip")
			helpers.assert_eq(world.notices[1], world.i18n.get("llm.translate.no_selection"))
			helpers.assert_eq(world.clipboard, USER_CLIPBOARD, "the clipboard is restored")
		end)
	end)

	helpers.it("refuses like a manual prediction when the AI is off, before reading the selection", function()
		with_world(SELECTION, "fr", function(world)
			world.engine.set_llm_enabled(false)
			trigger(world, "ui")
			helpers.assert_eq(#world.posts, 0, "no request")
			helpers.assert_eq(#world.keys, 0, "the selection is not even copied")
			helpers.assert_eq(world.notices[1], world.i18n.get("llm.manual_prediction.disabled"))
		end)
	end)

	helpers.it("tells the user when the answer holds no translation, or none came back", function()
		with_world(SELECTION, "fr", function(world)
			trigger(world, "ui")
			answer(world.posts[1], "Sure! See you tomorrow?")
			helpers.assert_eq(world.notices[1], world.i18n.get("llm.translate.failed"))
			helpers.assert_eq(#world.engine.get_predictions(), 0, "no candidate")
			helpers.assert_true(world.hides >= 1, "the loading row is closed")

			trigger(world, "ui")
			world.posts[2].callback({ ok = false, status = 500, body = "{}", headers = {} })
			helpers.assert_eq(world.notices[2], world.i18n.get("llm.translate.failed"))
			helpers.assert_eq(#world.document, 0)
		end)
	end)

	helpers.it("ignores the answer of a superseded translation", function()
		with_world(SELECTION, "fr", function(world)
			trigger(world, "ui")
			trigger(world, "ja")
			helpers.assert_eq(#world.posts, 2)
			answer(world.posts[1], "TRANSLATION: " .. TRANSLATION)
			helpers.assert_eq(#world.renders, 0, "the stale answer shows nothing")
			helpers.assert_eq(#world.notices, 0)
			answer(world.posts[2], "TRANSLATION: 明日会いましょう？")
			helpers.assert_eq(world.renders[#world.renders].texts[1], "明日会いましょう？", "only the current one")
		end)
	end)

	helpers.it("types nothing when the selection changed before the acceptance", function()
		with_world(SELECTION, "fr", function(world)
			trigger(world, "ui")
			answer(world.posts[1], "TRANSLATION: " .. TRANSLATION)
			world.selection = "une autre phrase"
			accept(world, 1)
			helpers.assert_eq(#world.document, 0, "the other selection is not replaced")
			helpers.assert_eq(world.selection, "une autre phrase")
			helpers.assert_eq(world.clipboard, USER_CLIPBOARD)
		end)
	end)

	helpers.it("types nothing when the focus moved before the acceptance", function()
		with_world(SELECTION, "fr", function(world)
			trigger(world, "ui")
			answer(world.posts[1], "TRANSLATION: " .. TRANSLATION)
			world.focus = "8:202"
			local before = #world.keys
			helpers.assert_eq(accept(world, 1), false, "the acceptance is refused")
			helpers.assert_eq(#world.keys, before, "no key reaches the other window")
			helpers.assert_eq(#world.document, 0)
		end)
	end)

	helpers.it("refuses a binding whose language contains an action separator", function()
		with_world(SELECTION, "fr", function(world)
			helpers.assert_eq(world.actions.set_action_parameter("tap_3", "llm_translate_selection", "English|2"), false,
				"the validator refuses it")
			world.actions.execute_single("llm_translate_selection", "tap_3")
			settle(world)
			helpers.assert_eq(#world.keys + #world.posts, 0, "nothing is read or sent")
		end)
	end)
end)

helpers.it("translates a free language name through the existing selection owner", function()
	with_world(SELECTION, "fr", function(world)
		helpers.assert_eq(world.actions.set_action_parameter("tap_3", "llm_translate_selection", "Esperanto"), true)
		world.actions.execute_single("llm_translate_selection", "tap_3")
		settle(world)
		helpers.assert_eq(#world.posts, 1)
		assert_request(world.posts[1], "Esperanto")
	end)
end)
