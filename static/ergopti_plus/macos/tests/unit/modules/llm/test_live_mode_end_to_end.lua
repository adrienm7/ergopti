--- tests/unit/modules/llm/test_live_mode_end_to_end.lua

--- ==============================================================================
--- MODULE: Live Mode End to End (llm-live-mode)
--- DESCRIPTION:
--- Runs live mode without a model: the real gesture action registry, prediction
--- engine, streaming handler, LLM core dispatcher, remote backend (Cerebras,
--- OpenAI dialect), shared parser and profile registry. Only the boundaries are
--- faked: the HTTP transport (requests are captured and answered with canned
--- bodies), the tooltip canvas, the native timers (fired by hand) and the clock.
--- A keystroke is what the keymap bridge does for one: the typed buffer is
--- published, then the engine's timer is stopped and armed again.
---
--- ROOT CAUSE ENCODED:
--- Live mode is a redirection of the automatic typing trigger, not a second
--- pipeline. Each rule below fails when one layer forgets it: the debounce and
--- the prompt must be live.json's and the binding's while on and the menu's
--- again once off; nothing the menu owns may change; a superseded request must
--- never paint; a hotstring tooltip, an explicit action and an acceptance must
--- each keep the single AI tooltip theirs.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")
local Rewrite = require("llm.rewrite")
local ApplyFixture = require("tests.support.apply_prediction_fixture")

local ENTRY_ID = "e2e-cerebras"
local MODEL = "qwen-3.8-27b"
local MENU_DEBOUNCE_SEC = 5
local MENU_MIN_WORDS = 9

--- Reads live.json the way a reviewer would, to compare the engine against it.
--- @return table { debounce_sec, min_words }
local function live_config()
	local fh = assert(io.open(helpers.shared("modules/llm/live.json"), "r"))
	local decoded = json.decode(fh:read("*a"))
	fh:close()
	return { debounce_sec = decoded.debounce_ms / 1000, min_words = decoded.min_words }
end
local LIVE = live_config()

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
--- @return table world
local function build_world()
	local world = {
		posts = {}, notices = {}, renders = 0, hotstring_visible = false, paused = false, clock = 1000,
	}

	for name in pairs(package.loaded) do
		if type(name) == "string" and (name:find("^modules%.") or name:find("^adapters%.")
			or name:find("^infra%.") or name:find("^ui%.")) then
			package.loaded[name] = nil
		end
	end
	helpers.load_with_stubs("modules.gestures")
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
	-- The native clock only feeds the backend's request floor: each request is
	-- made far enough from the previous one, as a human types
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
	package.loaded["modules.shortcuts.script_control"] = {
		is_paused = function() return world.paused end,
	}
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
		is_hotstring_visible = function() return world.hotstring_visible end,
		get_current_index = function() return 1 end,
		make_diff_styled = function() return true end,
		reset_llm_timer = function() return true end,
		mark_chain_complete = function() return true end,
		tint = function() return {} end,
		hide = function() return true end,
		hide_forced_silent = function() return true end,
	}

	local core = require("modules.llm")
	world.core = core
	local CoreState = get_upvalue(core.get_active_profile, "CoreState")
	assert(type(CoreState) == "table", "the LLM core state must be reachable")
	world.core_state = CoreState
	CoreState.backend = "api"
	CoreState.active_profile_id = "advanced"
	local api = core.api_remote
	api.set_entries({ { id = ENTRY_ID, provider = "cerebras", token = "e2e-token", model = MODEL } })
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
	world.set_active_profile_calls = 0
	local set_active_profile = core.set_active_profile
	core.set_active_profile = function(...)
		world.set_active_profile_calls = world.set_active_profile_calls + 1
		return set_active_profile(...)
	end

	local engine = require("modules.llm.prediction_engine")
	world.engine = engine
	-- The native timers are those of the stub the scheduler captured when it loaded
	local scheduler_hs = get_upvalue(require("adapters.timer_scheduler").after, "hs")
	assert(type(scheduler_hs) == "table" and type(scheduler_hs.timer.__timers) == "table",
		"the timer scheduler's native stub must be reachable")
	world.timers = scheduler_hs.timer.__timers
	world.state = {
		buffer = "",
		llm_buffer = "",
		mappings = {},
		DELAYS = { llm_prediction = 1 },
		ignored_window_titles = {},
		ignored_window_patterns = {},
		suppress_rescan_keep_buffer = function() return true end,
	}
	engine.init(world.state)
	engine.set_llm_enabled(true)
	engine.set_llm_num_predictions(1)
	engine.set_llm_sequential_mode(false)
	engine.set_llm_debounce(MENU_DEBOUNCE_SEC)
	engine.set_llm_min_words(MENU_MIN_WORDS)
	package.loaded["modules.keymap"] = {
		request_prompt_prediction = engine.request_prompt_prediction,
		request_manual_prediction = engine.request_manual_prediction,
		toggle_live_prompt = engine.toggle_live_prompt,
	}
	return world
end

--- Returns every running native timer armed with this delay.
--- @param world table
--- @param delay number Seconds.
--- @return table timers
local function running_timers(world, delay)
	local found = {}
	for _, timer in ipairs(world.timers) do
		if timer.running and math.abs((tonumber(timer.delay) or -1) - delay) < 1e-9 then
			found[#found + 1] = timer
		end
	end
	return found
end

--- Types a buffer the way the keymap bridge reports a keystroke.
--- @param world table
--- @param text string The whole typed buffer after the keystroke.
local function keystroke(world, text)
	world.clock = world.clock + 10
	world.state.buffer = text
	world.state.llm_buffer = text
	helpers.assert_eq(world.engine.stop_timer(), true, "the keystroke cancels the pending request")
	helpers.assert_eq(world.engine.start_timer(), true, "the keystroke arms the typing trigger")
end

--- Fires the single running debounce timer armed with this delay.
--- @param world table
--- @param delay number Seconds the timer must have been armed with.
--- @param message string Assertion context.
local function fire_debounce(world, delay, message)
	local timers = running_timers(world, delay)
	helpers.assert_eq(#timers, 1, message .. ": one debounce timer armed with " .. delay .. "s")
	timers[1]:fire()
end

--- Answers one captured request as the provider would.
--- @param post table A captured request.
--- @param content string The model's answer.
local function answer(post, content)
	post.callback({ ok = true, status = 200, body = completion_body(content), headers = {} })
end

--- Tells whether a notice starts with a locale key or its translation.
--- @param notice string|nil The shown notice.
--- @param key string The locale key.
--- @return boolean
local function notice_is(notice, key)
	if type(notice) ~= "string" then return false end
	local i18n = require("infra.i18n")
	local text = i18n.get(key):gsub("{1}.*$", "")
	return notice:find(text, 1, true) == 1
end

--- Asserts that nothing the AI menu owns changed.
--- @param world table
local function assert_menu_untouched(world)
	helpers.assert_eq(world.set_active_profile_calls, 0, "the menu's profile is never switched")
	helpers.assert_eq(world.core.get_active_profile().id, "advanced", "the menu's profile is still advanced")
	for key, expected in pairs({
		llm_num_predictions = 1, llm_debounce = MENU_DEBOUNCE_SEC, llm_min_words = MENU_MIN_WORDS,
	}) do
		local found, value = world.engine.get_llm_runtime_setting(key)
		helpers.assert_true(found, key)
		helpers.assert_eq(value, expected, "the menu's " .. key .. " is unchanged")
	end
end

--- Accepts a prediction through the real keymap bridge and expander.
--- @param prediction table The engine's prediction record.
--- @param buffer string The typed buffer.
--- @return table result
--- @return number backspaces
--- @return string typed
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

--- Turns live mode on through a real binding of the action.
--- @param world table
--- @param value string The binding's parameter.
--- @return boolean handled
local function toggle(world, value)
	helpers.assert_eq(world.actions.set_action_parameter("tap_3", "llm_live_prompt_toggle", value), true)
	return world.actions.execute_single("llm_live_prompt_toggle", "tap_3")
end

helpers.describe("live mode end to end (llm-live-mode)", function()
	local TYPED = "on se voit demain"

	helpers.it("translates the sentence at every keystroke, then accepts it", function()
		local world = build_world()
		helpers.assert_true(MENU_MIN_WORDS > select(2, TYPED:gsub("%S+", "")),
			"positive control: the typed sentence is below the menu's minimum word count")
		helpers.assert_true(LIVE.debounce_sec < MENU_DEBOUNCE_SEC, "positive control: the two debounces differ")

		-- The harness's i18n stub echoes keys: point it at the real locale core so
		-- the notice shows its {1} filled with the prompt's menu label
		local i18n = package.loaded["infra.i18n"]
		local Locale = require("infra.locale")
		local saved_get, saved_format = i18n.get, i18n.format
		i18n.get = function(key) return Locale.get(key) or key end
		i18n.format = function(key, ...)
			local text = i18n.get(key)
			for index, value in ipairs({ ... }) do
				text = text:gsub("{" .. index .. "}", (tostring(value):gsub("%%", "%%%%")))
			end
			return text
		end
		local toggled_ok, toggled = pcall(toggle, world, "translate_en")
		i18n.get, i18n.format = saved_get, saved_format
		helpers.assert_true(toggled_ok, tostring(toggled))
		helpers.assert_eq(toggled, true)
		helpers.assert_eq(world.engine.get_live_prompt().profile_id, "translate_en")
		local menu_label = require("ui.menu.menu_llm.profile_label").format(
			world.core.find_profile("translate_en").label, 1)
		helpers.assert_eq(world.notices[#world.notices],
			(Locale.get("llm.live.on"):gsub("{1}", (menu_label:gsub("%%", "%%%%")))),
			"the live-on notice names the prompt's menu label")
		helpers.assert_eq(#world.posts, 0, "turning live mode on asks for nothing yet")

		keystroke(world, "on se")
		fire_debounce(world, LIVE.debounce_sec, "the live debounce, not the menu's")
		helpers.assert_eq(#running_timers(world, MENU_DEBOUNCE_SEC), 0, "the menu's debounce is not armed")
		helpers.assert_eq(#world.posts, 1, "the first keystrokes are already translated")
		local system = world.posts[1].body.messages[1].content
		helpers.assert_true(system:find("Translate TAIL into English", 1, true) ~= nil,
			"the system prompt is translate_en's")
		helpers.assert_eq(world.posts[1].body.messages[2].content, 'PREFIX: "on se"\nTAIL: "on se"')

		-- A new keystroke supersedes the request in flight: its late answer never paints
		keystroke(world, TYPED)
		fire_debounce(world, LIVE.debounce_sec, "the second keystroke")
		helpers.assert_eq(#world.posts, 2)
		local request = world.posts[2]
		helpers.assert_eq(request.body.messages[2].content, 'PREFIX: "' .. TYPED .. '"\nTAIL: "' .. TYPED .. '"',
			"the tail is the current sentence")
		helpers.assert_eq(request.body.max_tokens, Rewrite.max_tokens(TYPED), "the rewrite budget")
		answer(world.posts[1], "REWRITE: We")
		helpers.assert_eq(#world.engine.get_predictions(), 0, "the superseded answer is ignored")
		helpers.assert_eq(world.engine.is_visible(), false, "Tab has nothing to accept yet")

		answer(request, "REWRITE: See you tomorrow")
		local shown = world.engine.get_predictions()
		helpers.assert_eq(#shown, 1, "the translation is offered")
		helpers.assert_eq(shown[1].rewrite, true)
		helpers.assert_eq(shown[1].to_type, "See you tomorrow")
		helpers.assert_eq(shown[1].deletes, #TYPED, "it replaces the whole sentence")
		helpers.assert_eq(world.engine.is_visible(), true, "Tab accepts while the live tooltip is visible")
		assert_menu_untouched(world)

		local result, backspaces, typed = accept(shown[1], TYPED)
		helpers.assert_eq(result.applied, true)
		helpers.assert_eq(backspaces, #TYPED, "exactly the sentence is erased")
		helpers.assert_eq(typed, "See you tomorrow")
		helpers.assert_eq(result.state.buffer, "See you tomorrow", "the buffer holds the translation")
	end)

	helpers.it("turns off on a second press of any live binding, and the menu's trigger comes back", function()
		local world = build_world()
		helpers.assert_eq(toggle(world, "translate_ja|3"), true)
		helpers.assert_eq(world.engine.get_live_prompt().num_predictions, 3, "the binding's own count")
		-- Another binding, with a prompt that does not even exist, still turns it off
		helpers.assert_eq(toggle(world, "no_such_prompt"), true)
		helpers.assert_eq(world.engine.get_live_prompt(), nil, "live mode is off")
		helpers.assert_true(notice_is(world.notices[#world.notices], "llm.live.off"),
			"the live-off notice: " .. tostring(world.notices[#world.notices]))

		keystroke(world, "Je vous envoie ce mail pour vous dire")
		helpers.assert_eq(#running_timers(world, LIVE.debounce_sec), 0, "the live debounce is gone")
		fire_debounce(world, MENU_DEBOUNCE_SEC, "the menu's debounce")
		helpers.assert_eq(#world.posts, 1)
		helpers.assert_true(world.posts[1].body.messages[1].content:find("TAIL_CORRECTED", 1, true) ~= nil,
			"the menu's advanced prompt continues the text again")
		-- The answer to a timer-triggered request arrives after the timer callback
		-- returned: it used to be discarded, so no typing prediction ever showed
		answer(world.posts[1], "TAIL_CORRECTED: pour vous dire\nNEXT_WORDS: que tout va bien.")
		helpers.assert_eq(#world.engine.get_predictions(), 1,
			"the answer to the typing trigger is offered after its timer callback returned")
		assert_menu_untouched(world)
	end)

	helpers.it("refuses an unknown prompt and an AI that cannot answer, and stays off", function()
		local world = build_world()
		toggle(world, "deleted_prompt")
		helpers.assert_eq(world.engine.get_live_prompt(), nil)
		helpers.assert_true(notice_is(world.notices[#world.notices], "llm.prompt_prediction.unknown_prompt"),
			"the unknown-prompt notice: " .. tostring(world.notices[#world.notices]))

		world.paused = true
		toggle(world, "translate_en")
		helpers.assert_eq(world.engine.get_live_prompt(), nil)
		helpers.assert_true(notice_is(world.notices[#world.notices], "llm.manual_prediction.paused"),
			"the paused notice: " .. tostring(world.notices[#world.notices]))
		world.paused = false

		world.engine.set_llm_enabled(false)
		toggle(world, "translate_en")
		helpers.assert_true(notice_is(world.notices[#world.notices], "llm.manual_prediction.disabled"),
			"the AI-off notice: " .. tostring(world.notices[#world.notices]))
		helpers.assert_eq(world.engine.get_live_prompt(), nil)
		assert_menu_untouched(world)
	end)

	helpers.it("turns off silently when the AI is switched off", function()
		local world = build_world()
		helpers.assert_eq(toggle(world, "translate_en"), true)
		local notices = #world.notices
		world.engine.set_llm_enabled(false)
		helpers.assert_eq(world.engine.get_live_prompt(), nil, "the AI off ends live mode")
		helpers.assert_eq(#world.notices, notices, "without a notice")
		world.engine.set_llm_enabled(true)
		helpers.assert_eq(world.engine.get_live_prompt(), nil, "and the AI back on does not resume it")
	end)

	helpers.it("waits for a hotstring tooltip to go before drawing the live one", function()
		local world = build_world()
		helpers.assert_eq(toggle(world, "translate_en"), true)
		world.hotstring_visible = true
		keystroke(world, "on se voit")
		fire_debounce(world, LIVE.debounce_sec, "the live debounce")
		helpers.assert_eq(#world.posts, 0, "no live request while the hotstring tooltip is shown")
		world.hotstring_visible = false
		fire_debounce(world, LIVE.debounce_sec, "the wait re-arms the live debounce")
		helpers.assert_eq(#world.posts, 1, "the live request follows once the hotstring tooltip is gone")
		helpers.assert_eq(world.posts[1].body.messages[2].content, 'PREFIX: "on se voit"\nTAIL: "on se voit"')
	end)

	helpers.it("dismisses the live tooltip on an expansion and translates the expanded text", function()
		local world = build_world()
		helpers.assert_eq(toggle(world, "translate_en"), true)
		keystroke(world, "on se voit dm")
		fire_debounce(world, LIVE.debounce_sec, "before the expansion")
		answer(world.posts[1], "REWRITE: See you dm")
		helpers.assert_eq(world.engine.is_visible(), true)
		-- The expander hides the tooltip, then its completion refreshes the preview:
		-- the bridge resets the predictions and reports the expanded buffer
		helpers.assert_eq(world.engine.reset(), true)
		helpers.assert_eq(world.engine.is_visible(), false, "Tab no longer accepts the old translation")
		keystroke(world, "on se voit demain")
		fire_debounce(world, LIVE.debounce_sec, "after the expansion")
		helpers.assert_eq(#world.posts, 2, "the live request is issued again")
		helpers.assert_eq(world.posts[2].body.messages[2].content,
			'PREFIX: "on se voit demain"\nTAIL: "on se voit demain"', "on the text after the expansion")
	end)

	helpers.it("lets an explicit action take over, then resumes on the next keystroke", function()
		local world = build_world()
		helpers.assert_eq(toggle(world, "translate_en"), true)
		world.state.buffer = "Je vous envoie ce mail pour vous dire"
		world.state.llm_buffer = world.state.buffer
		helpers.assert_eq(world.actions.execute_single("llm_generate_prediction", "tap_3"), true)
		helpers.assert_eq(#world.posts, 1)
		helpers.assert_true(world.posts[1].body.messages[1].content:find("TAIL_CORRECTED", 1, true) ~= nil,
			"the explicit action runs the menu's prompt")
		keystroke(world, "Je vous envoie ce mail pour vous dire que")
		fire_debounce(world, LIVE.debounce_sec, "the next keystroke")
		helpers.assert_eq(#world.posts, 2)
		helpers.assert_true(world.posts[2].body.messages[1].content:find("Translate TAIL into English", 1, true) ~= nil,
			"live mode resumes")
		helpers.assert_eq(world.engine.get_live_prompt().profile_id, "translate_en")
	end)

	helpers.it("does not ask for the accepted sentence again until the user types", function()
		local world = build_world()
		--- Accepts, then delivers the chain signal and fires the dispatch it arms.
		local function accept_and_chain()
			helpers.assert_eq(world.engine.consume(1) ~= nil, true, "the offered prediction is accepted")
			helpers.assert_eq(world.engine.arm_chain(), true)
			local before = #world.timers
			helpers.assert_eq(world.engine.handle_chain_signal(world.engine.KEYCODE_LLM_CHAIN), true)
			local dispatched = 0
			for index = before + 1, #world.timers do
				local timer = world.timers[index]
				if timer.running and timer.delay == 0 then
					timer:fire()
					dispatched = dispatched + 1
				end
			end
			helpers.assert_eq(dispatched, 1, "the chain signal arms one dispatch")
		end

		helpers.assert_eq(toggle(world, "translate_en"), true)
		keystroke(world, TYPED)
		fire_debounce(world, LIVE.debounce_sec, "the keystroke")
		answer(world.posts[1], "REWRITE: See you tomorrow")
		accept_and_chain()
		helpers.assert_eq(#world.posts, 1, "the chained request is not sent in live mode")

		-- Positive control: out of live mode the same chain asks for a continuation
		world.engine.stop_live_prompt("test", true)
		world.state.buffer = "See you tomorrow"
		world.state.llm_buffer = world.state.buffer
		world.engine.request_manual_prediction()
		helpers.assert_eq(#world.posts, 2)
		answer(world.posts[2], "TAIL_CORRECTED: tomorrow\nNEXT_WORDS: at noon.")
		accept_and_chain()
		helpers.assert_eq(#world.posts, 3, "the chain dispatches outside live mode")
	end)

	helpers.it("drives the same live state from the AI menu's live-mode submenu", function()
		local world = build_world()
		world.core_state.user_profiles = {
			{ id = "custom_7", label = "My translator", system_single = "Translate TAIL. REWRITE: <text>" },
			{ id = "custom_8", label = "My continuation", system_single = "Continue TAIL." },
		}
		-- The keymap bridge's two live-mode entry points, over the real engine
		local keymap = {
			get_live_prompt = world.engine.get_live_prompt,
			set_live_prompt = function(value)
				if value == nil then
					world.engine.stop_live_prompt("menu", false)
					return world.engine.get_live_prompt() == nil
				end
				return world.engine.start_live_prompt(value)
			end,
		}
		package.loaded["ui.menu.menu_llm.live_mode_panel"] = nil
		local Panel = require("ui.menu.menu_llm.live_mode_panel")
		local redraws = 0
		local function build()
			return Panel.build({
				llm_mod = world.core, keymap = keymap, count = 1, is_disabled = false,
				update_menu = function() redraws = redraws + 1 end,
			})
		end

		local expected = {}
		for _, profile in ipairs(world.core.BUILTIN_PROFILES) do
			if Rewrite.is_rewrite_profile(profile) then expected[#expected + 1] = profile.id end
		end
		expected[#expected + 1] = "custom_7"
		local builtin_ids = table.concat(expected, ",")
		helpers.assert_true(builtin_ids:find("translate_en,translate_ja", 1, true) ~= nil,
			"the translations are offered: " .. builtin_ids)
		helpers.assert_true(builtin_ids:find("advanced", 1, true) == nil, "a continuation prompt is not")

		local rows = build()
		helpers.assert_eq(#rows, 2 + #expected, "Off, a separator, then every rewrite prompt")
		helpers.assert_eq(rows[1].checked, true, "Off is checked while live mode is off")
		helpers.assert_eq(rows[2].title, "-")
		local prompts = Panel.live_prompts(world.core, 1)
		for index, id in ipairs(expected) do
			helpers.assert_eq(prompts[index].id, id, "prompt " .. index)
			helpers.assert_eq(rows[2 + index].title, prompts[index].label, id .. " is labelled like the prompt list")
		end

		local ja_row = rows[2 + #expected - 1]
		helpers.assert_eq(prompts[#expected - 1].id, "translate_ja")
		helpers.assert_eq(ja_row.fn(), true)
		helpers.assert_eq(world.engine.get_live_prompt().profile_id, "translate_ja", "the menu turns live mode on")
		helpers.assert_eq(world.engine.get_live_prompt().num_predictions, nil, "with the menu's count")
		helpers.assert_eq(redraws, 1)
		rows = build()
		helpers.assert_eq(rows[1].checked, false)
		helpers.assert_eq(rows[2 + #expected - 1].checked, true, "the current prompt is checked")

		-- The action and the menu share one state: a toggle turns the menu's choice off
		helpers.assert_eq(toggle(world, "translate_en"), true)
		helpers.assert_eq(world.engine.get_live_prompt(), nil)
		helpers.assert_eq(build()[1].checked, true)

		helpers.assert_eq(build()[2 + #expected].fn(), true)
		helpers.assert_eq(world.engine.get_live_prompt().profile_id, "custom_7", "a custom rewrite prompt")
		helpers.assert_eq(build()[1].fn(), true)
		helpers.assert_eq(world.engine.get_live_prompt(), nil, "Off turns live mode off")
		helpers.assert_true(notice_is(world.notices[#world.notices], "llm.live.off"))
		assert_menu_untouched(world)
	end)
end)


helpers.describe("declared live Off choice", function()
	local function corpus()
		local file = assert(io.open(helpers.shared("tests/corpus/menus/llm_live_off.json"), "r"))
		local value = json.decode(file:read("*a")); file:close(); return value
	end

	helpers.it("retains the actual bridge and refuses a retained row after admission changes", function()
		local world = build_world()
		local Panel = require("ui.menu.menu_llm.live_mode_panel")
		local calls, redraws = 0, 0
		local keymap = { get_live_prompt = world.engine.get_live_prompt,
			set_live_prompt = function(value)
				calls = calls + 1
				if value == nil then world.engine.stop_live_prompt("menu", false); return world.engine.get_live_prompt() == nil end
				return world.engine.start_live_prompt(value)
			end }
		local ctx = { llm_mod = world.core, keymap = keymap, count = 1, is_disabled = false,
			update_menu = function() redraws = redraws + 1 end }
		helpers.assert_true(world.engine.start_live_prompt("translate_en"))
		local before = world.engine.get_live_prompt()
		local row = Panel.build(ctx)[1]
		helpers.assert_eq(row.checked, false)
		ctx.is_disabled = true
		local result = row.fn()
		helpers.assert_eq(result, false, "the retained declaration rechecks current admission")
		helpers.assert_eq(calls, 0, "refusal happens before entering the bridge")
		helpers.assert_eq(redraws, 0)
		helpers.assert_eq(world.engine.get_live_prompt(), before)
		ctx.is_disabled = false
		helpers.assert_eq(row.fn(), true)
		helpers.assert_eq(calls, 1)
		helpers.assert_eq(redraws, 1)
		helpers.assert_nil(world.engine.get_live_prompt())
		helpers.assert_eq(Panel.build(ctx)[1].checked, true)
		assert_menu_untouched(world)
	end)

	helpers.it("uses all actual locale labels and preserves refused bridge state", function()
		local world = build_world()
		local Panel = require("ui.menu.menu_llm.live_mode_panel")
		local i18n = require("infra.i18n")
		local saved_get = i18n.get
		local spec = corpus()
		local calls, redraws, result = 0, 0, false
		local before = { profile_id = "translate_en" }
		local ctx = { llm_mod = world.core, count = 1,
			keymap = { get_live_prompt = function() return before end,
				set_live_prompt = function(value) calls = calls + 1; return result end },
			update_menu = function() redraws = redraws + 1 end }
		local ok, err = xpcall(function()
			for _, code in ipairs(spec.locales) do
				local file = assert(io.open(helpers.shared("data/locales/" .. code .. ".json"), "r"))
				local catalog = json.decode(file:read("*a")); file:close()
				i18n.get = function(key) return catalog[key] or key end
				local row = Panel.build(ctx)[1]
				helpers.assert_eq(row.title, catalog[spec.label_key], code)
				helpers.assert_eq(row.checked, false)
				local observed = row.fn()
				helpers.assert_eq(observed, false)
				helpers.assert_eq(ctx.keymap.get_live_prompt(), before)
			end
			for _, refusal in ipairs(spec.refusals) do
				ctx.keymap.set_live_prompt = function()
					calls = calls + 1
					if refusal == "throw" then error("owned live refusal") end
					if refusal == "number" then return 2 end
					if refusal == "nil" then return nil end
					return false
				end
				local invoked, receipt = pcall(Panel.build(ctx)[1].fn)
				if refusal == "throw" then helpers.assert_eq(invoked, false)
				else helpers.assert_eq(invoked, true); helpers.assert_eq(receipt, false) end
				helpers.assert_eq(ctx.keymap.get_live_prompt(), before)
			end
		end, debug.traceback)
		i18n.get = saved_get
		helpers.assert_true(ok, err)
		helpers.assert_eq(calls, 25)
		helpers.assert_eq(redraws, 24, "existing Mac redraw-on-refusal ABI is retained")
	end)
end)


--- Uses the existing genuine live pipeline fixture with a real scoped translator/renderer.
local function control_boundary_corpus()
	local file = assert(io.open(helpers.shared("tests/corpus/menus/llm_control_boundaries.json"), "rb"))
	local bytes = assert(file:read("*a")); assert(file:close())
	return assert(json.decode(bytes))
end

local function with_live_boundary_owner(scenario)
	local previous, previous_hs = {}, rawget(_G, "hs")
	for name, value in pairs(package.loaded) do previous[name] = value end
	local world, native, owner, receipt, acquired
	local ok, detail = xpcall(function()
		world = build_world()
		for _, name in ipairs({ "infra.i18n", "infra.locale", "locale.core", "infra.manifest_menu",
			"ui.menu.menu_llm.live_mode_panel", "ui.menu.menu_llm.profile_label" }) do package.loaded[name] = nil end
		native = require("infra.i18n")
		local backend = require("infra.locale")
		native.set_locale_injector(function(code) backend.set_locale(code) end)
		native.init()
		owner = { pending = function() return false end }
		acquired = native.scope_acquire(owner); helpers.assert_eq(acquired, true)
		receipt = assert(native.scope_capture(owner)); helpers.assert_eq(native.scope_apply(owner, receipt, "en"), true)
		local menu = require("infra.manifest_menu"); assert(menu.get_root())
		scenario(world, require("ui.menu.menu_llm.live_mode_panel"), menu, native)
	end, debug.traceback)
	local restored, released, forgotten = true, true, true
	if receipt then restored = native.scope_restore(owner, receipt) == true end
	if acquired then released = native.scope_release(owner) == true end
	if receipt then forgotten = native.scope_forget(owner, receipt) == true end
	local cleaned, cleanup_detail = pcall(function()
		if world then world.engine.stop_live_prompt("boundary fixture cleanup", true) end
		local scheduler = package.loaded["adapters.timer_scheduler"]
		if scheduler and not rawequal(scheduler, previous["adapters.timer_scheduler"]) then
			helpers.assert_eq(scheduler.cancelAll(), true); helpers.assert_eq(scheduler.activeCount(), 0)
		end
		local bridge = package.loaded["modules.keylogger.kc_bridge"]
		if bridge and not rawequal(bridge, previous["modules.keylogger.kc_bridge"]) then bridge.stop() end
	end)
	for name in pairs(package.loaded) do if previous[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(previous) do package.loaded[name] = value end
	_G.hs = previous_hs
	for name, value in pairs(previous) do helpers.assert_true(rawequal(package.loaded[name], value), name) end
	helpers.assert_true(rawequal(rawget(_G, "hs"), previous_hs))
	helpers.assert_eq(restored, true); helpers.assert_eq(released, true); helpers.assert_eq(forgotten, true)
	helpers.assert_eq(cleaned, true, tostring(cleanup_detail))
	if not ok then error(detail, 0) end
end

helpers.describe("llm-control-boundaries: actual live prompt owner", function()
	helpers.it("consumes the shared boundary without changing Off/prompt admission or callbacks (llm-control-boundaries)", function()
		with_live_boundary_owner(function(world, panel, menu)
			local expected = control_boundary_corpus()
			local boundary = expected.boundaries.live
			local root, original = menu.get_root(), menu.get_array(boundary.section)
			local calls, redraws = 0, 0
			local context = { llm_mod = world.core, count = 1, is_disabled = false,
				keymap = { get_live_prompt = world.engine.get_live_prompt,
					set_live_prompt = function(id)
						calls = calls + 1
						if id == nil then world.engine.stop_live_prompt("menu", false); return world.engine.get_live_prompt() == nil end
						return world.engine.start_live_prompt(id)
					end }, update_menu = function() redraws = redraws + 1 end }
			local function build() return panel.build(context) end
			local rows, prompts = build(), panel.live_prompts(world.core, 1)
			helpers.assert_true(#prompts > 0, "genuine builtin rewrite prompts must be reached")
			helpers.assert_eq(#rows, #prompts + 2)
			helpers.assert_eq(rows[1].title, expected.live_off_english)
			helpers.assert_eq(rows[1].checked, true); helpers.assert_type(rows[1].fn, "function")
			helpers.assert_eq(rows[2].title, "-")
			for index, prompt in ipairs(prompts) do
				helpers.assert_eq(rows[index + 2].title, prompt.label); helpers.assert_type(rows[index + 2].fn, "function")
			end
			local ok, detail = xpcall(function()
				root[boundary.section] = { { type = "label", id = "hand_live_boundary", i18n = expected.marker_key,
					platforms = { "hs" }, unavailable = "hide" } }
				rows = build()
				helpers.assert_eq(rows[2].title, expected.marker_english)
				helpers.assert_eq(rows[2].disabled, true); helpers.assert_nil(rows[2].fn)
				helpers.assert_eq(rows[3].title, prompts[1].label)
				helpers.assert_eq(rows[3].fn(), true)
				helpers.assert_eq(world.engine.get_live_prompt().profile_id, prompts[1].id)
				helpers.assert_eq(calls, 1); helpers.assert_eq(redraws, 1)
				local retained = rows[1]
				context.is_disabled = true
				helpers.assert_eq(retained.fn(), false)
				helpers.assert_eq(calls, 1); helpers.assert_eq(redraws, 1)
				rows = build(); helpers.assert_eq(rows[1].disabled, true); helpers.assert_nil(rows[3].fn)
				context.is_disabled = false
				helpers.assert_eq(build()[1].fn(), true); helpers.assert_nil(world.engine.get_live_prompt())
				helpers.assert_eq(calls, 2); helpers.assert_eq(redraws, 2)
				root[boundary.section] = nil
				helpers.assert_eq(build(), {}, "no native fallback after a real declaration withdrawal")
				root[boundary.section] = { { type = "command", id = "hand_unbound_live_boundary", i18n = expected.marker_key } }
				helpers.assert_eq(build(), {})
				helpers.assert_eq(calls, 2); helpers.assert_eq(redraws, 2)
				context.keymap = nil
				rows = build(); helpers.assert_eq(#rows, 1); helpers.assert_eq(rows[1].disabled, true)
				helpers.assert_eq(rows[1].title, expected.live_off_english)
			end, debug.traceback)
			root[boundary.section] = original
			if not ok then error(detail, 0) end
			context.keymap = { get_live_prompt = world.engine.get_live_prompt,
				set_live_prompt = function() error("construction cannot enter the native bridge") end }
			rows = build(); helpers.assert_eq(rows[2].title, "-")
			helpers.assert_eq(rows[1].checked, true); helpers.assert_eq(calls, 2); helpers.assert_eq(redraws, 2)
			assert_menu_untouched(world)
		end)
	end)

	helpers.it("projects all three presentation roles and each genuine cross-platform absence (llm-control-boundaries)", function()
		with_live_boundary_owner(function(_, _, _, native)
			local expected = control_boundary_corpus()
			for _, platform in ipairs({ "ahk", "hs", "linux" }) do
				local renderer = assert(require("menu.renderer").new({ platform = platform,
					manifest_path = function() return helpers.shared("modules/menu/menu_manifest.json") end,
					json_decode = require("adapters.json_codec").decode, i18n = native, logger = require("infra.logger") }))
				for _, boundary in pairs(expected.boundaries) do
					helpers.assert_eq(renderer.template_rows(boundary.section, {}, {}, {}), boundary.projections[platform])
				end
			end
		end)
	end)

	helpers.it("restores the genuine predecessor cohort after a raised scenario (llm-control-boundaries)", function()
		local prior, previous_hs = {}, rawget(_G, "hs")
		for name, value in pairs(package.loaded) do prior[name] = value end
		local ok, detail = pcall(function()
			with_live_boundary_owner(function() error("live boundary inverse sentinel") end)
		end)
		helpers.assert_eq(ok, false); helpers.assert_contains(detail, "live boundary inverse sentinel")
		for name, value in pairs(prior) do helpers.assert_true(rawequal(rawget(package.loaded, name), value), name) end
		for name in pairs(package.loaded) do helpers.assert_true(prior[name] ~= nil, name) end
		helpers.assert_true(rawequal(rawget(_G, "hs"), previous_hs))
	end)
end)
