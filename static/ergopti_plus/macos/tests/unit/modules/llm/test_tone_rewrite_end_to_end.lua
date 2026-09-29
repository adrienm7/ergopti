--- tests/unit/modules/llm/test_tone_rewrite_end_to_end.lua

--- ==============================================================================
--- MODULE: Tone Rewrite of the Selection End to End (llm-tone)
--- DESCRIPTION:
--- Runs the llm_tone_* actions without a model: the real gesture action
--- registry, tone module, prediction engine refusals, LLM core dispatcher,
--- remote backend (Cerebras, OpenAI dialect), profile registry and clipboard
--- text pipeline. Only the boundaries are faked: the HTTP transport (requests
--- are captured and answered with canned bodies), the pasteboard and the
--- synthetic key emitter (a small document model: Cmd+C copies the selection,
--- Cmd+V replaces it, the reselection batch selects the pasted text), the
--- native timers (fired in order), the focused window and the tooltip.
---
--- ROOT CAUSE ENCODED:
--- A tone step only works when every layer agrees: the selection is read
--- without touching the document, the request carries the ladder prompt and
--- the ORIGINAL text as TAIL, the answer replaces the selection and is selected
--- again over exactly its characters, and an answer meant for another window,
--- selection or step is never typed.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")
local Rewrite = require("llm.rewrite")

local ENTRY_ID = "tone-cerebras"
local MODEL = "qwen-3.8-27b"
local USER_CLIPBOARD = "USER_CLIPBOARD"

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
		id = "chatcmpl-tone",
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
	function synthetic.emit_key_strokes() error("the tone actions never type key by key") end
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
--- @return table world
local function build_world(selection)
	local world = {
		posts = {}, notices = {}, keys = {}, document = {},
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

	-- The pasteboard of the document model, on the hs stub every module shares
	local hs_stub = _G.hs
	-- The application the exclusion filter reads
	local front_app = {
		title = function() return "ToneApp" end,
		name = function() return "ToneApp" end,
		bundleID = function() return "test.tone" end,
		path = function() return "/Applications/Tone.app" end,
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
		"modules.llm.tone_rewrite", "modules.shortcuts.actions.text",
	}) do
		package.loaded[name] = nil
	end
	package.loaded["adapters.synthetic_input"] = make_synthetic(world)
	package.loaded["adapters.window_info"] = {
		focused_identity = function() return world.focus end,
		getFocused = function()
			return { appId = "ToneApp", windowTitle = "Draft", bundleId = "test.tone", executablePath = "" }
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
		show_loading = function() error("a tone step shows no loading tooltip") end,
		show = function(content)
			world.notices[#world.notices + 1] = content
			return true
		end,
		show_predictions = function() error("a tone step shows no prediction tooltip") end,
		mark_chain_complete = function() return true end,
		hide = function() return true end,
		hide_forced_silent = function() return true end,
	}

	local core = require("modules.llm")
	world.core = core
	local CoreState = get_upvalue(core.get_active_profile, "CoreState")
	assert(type(CoreState) == "table", "the LLM core state must be reachable")
	CoreState.backend = "api"
	CoreState.active_profile_id = "advanced"
	local api = core.api_remote
	api.set_entries({ { id = ENTRY_ID, provider = "cerebras", token = "tone-token", model = MODEL } })
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
	engine.set_llm_num_predictions(3)
	world.tone = require("modules.llm.tone_rewrite")
	-- Only the timers of the actions run: the backend's own stay untouched
	world.timer_baseline = #hs_stub.timer.__timers
	package.loaded["modules.keymap"] = {
		request_tone_step = function(direction, cycle, parent)
			return world.tone.step(direction, cycle, parent)
		end,
	}
	return world
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

--- Runs a tone action as the gesture registry dispatches it, then lets the
--- selection copy complete.
--- @param world table
--- @param action string The action id.
--- @return boolean started
local function swipe(world, action)
	local started = world.actions.execute_single(action, "tap_3")
	settle(world)
	return started
end

--- Answers one captured request as the provider would, then lets the
--- replacement complete.
--- @param world table
--- @param post table A captured request.
--- @param content string The model's answer.
local function answer(world, post, content)
	post.callback({ ok = true, status = 200, body = completion_body(content), headers = {} })
	settle(world)
end

--- Returns the system prompt a ladder profile resolves to.
--- @param world table
--- @param profile_id string
--- @return string
local function prompt_of(world, profile_id)
	local profile = world.core.find_profile(profile_id)
	assert(type(profile) == "table", "the built-in profile " .. profile_id .. " must exist")
	return require("modules.llm.profiles").resolve_system_prompt(profile, 1)
end

--- Asserts a request rewrites `source` with `profile_id`.
--- @param world table
--- @param post table
--- @param profile_id string
--- @param source string
local function assert_request(world, post, profile_id, source)
	helpers.assert_true(post.url:find("https://api.cerebras.ai/v1/chat/completions", 1, true) == 1,
		"the Cerebras chat endpoint: " .. tostring(post.url))
	helpers.assert_eq(post.body.model, MODEL)
	helpers.assert_eq(post.body.messages[1].content, prompt_of(world, profile_id),
		"the system prompt is the " .. profile_id .. " prompt")
	helpers.assert_eq(post.body.messages[2].content,
		'PREFIX: "' .. source .. '"\nTAIL: "' .. source .. '"', "the text to rewrite is PREFIX and TAIL")
	helpers.assert_eq(post.body.max_tokens, Rewrite.max_tokens(source), "the rewrite budget")
	helpers.assert_true(post.body.stream ~= true, "no streaming")
end

--- Returns the key strokes recorded since `from`, as "mods+key" strings.
--- @param world table
--- @param from number Index of the first stroke.
--- @return table strokes
local function strokes_since(world, from)
	local out = {}
	for index = from, #world.keys do
		local stroke = world.keys[index]
		out[#out + 1] = (stroke.mods ~= "" and (stroke.mods .. "+") or "") .. stroke.key
	end
	return out
end

--- Asserts the replacement key sequence: copy, paste, then the reselection of
--- `steps` characters (Left × steps, then Shift+Right × steps).
--- @param strokes table
--- @param steps number
local function assert_replacement(strokes, steps)
	helpers.assert_eq(#strokes, 2 + 2 * steps, "copy, paste and the reselection: " .. table.concat(strokes, " "))
	helpers.assert_eq(strokes[1], "cmd+c", "the selection is checked first")
	helpers.assert_eq(strokes[2], "cmd+v", "then replaced")
	for index = 1, steps do
		helpers.assert_eq(strokes[2 + index], "left", "caret back over the inserted text")
		helpers.assert_eq(strokes[2 + steps + index], "shift+right", "then selected forward")
	end
end

helpers.describe("tone rewrite of the selection end to end (llm-tone)", function()
	helpers.it("climbs the ladder from the original, stops at the top and wraps with _cycle", function()
		local world = build_world("merci pour ton aide")

		helpers.assert_eq(swipe(world, "llm_tone_more_formal"), true)
		helpers.assert_eq(#world.notices, 0, "a ready request shows no refusal: " .. tostring(world.notices[1]))
		helpers.assert_eq(#world.posts, 1, "one request")
		helpers.assert_eq(world.clipboard, USER_CLIPBOARD, "reading the selection gives the clipboard back")
		helpers.assert_eq(#world.document, 0, "reading the selection changes nothing")
		assert_request(world, world.posts[1], "tone_formal", "merci pour ton aide")

		local before = #world.keys + 1
		answer(world, world.posts[1], "REWRITE: Merci pour votre aide.")
		assert_replacement(strokes_since(world, before), #"Merci pour votre aide.")
		helpers.assert_eq(world.document[1], "Merci pour votre aide.", "the selection is replaced by the rewrite")
		helpers.assert_eq(world.selection, "Merci pour votre aide.", "and the rewrite is selected")
		helpers.assert_eq(world.clipboard, USER_CLIPBOARD, "the user's clipboard is restored")
		local memory = world.tone.get_memory()
		helpers.assert_eq(memory.source, "merci pour ton aide")
		helpers.assert_eq(memory.output, "Merci pour votre aide.")
		helpers.assert_eq(memory.level, 3)

		helpers.assert_eq(swipe(world, "llm_tone_more_formal"), true)
		helpers.assert_eq(#world.posts, 2)
		assert_request(world, world.posts[2], "tone_very_formal", "merci pour ton aide")
		answer(world, world.posts[2], "REWRITE: Je vous remercie infiniment pour votre aide.")
		helpers.assert_eq(world.selection, "Je vous remercie infiniment pour votre aide.")

		helpers.assert_eq(swipe(world, "llm_tone_more_formal"), true)
		helpers.assert_eq(#world.posts, 2, "the top of the ladder sends nothing")
		helpers.assert_eq(#world.notices, 1)
		helpers.assert_eq(world.notices[1], require("infra.i18n").get("llm.tone.most_formal"))
		helpers.assert_eq(world.clipboard, USER_CLIPBOARD)

		helpers.assert_eq(swipe(world, "llm_tone_more_formal_cycle"), true)
		helpers.assert_eq(#world.posts, 3, "_cycle wraps around")
		assert_request(world, world.posts[3], "tone_familiar", "merci pour ton aide")
	end)

	helpers.it("goes down the ladder and stops at the most familiar register", function()
		local world = build_world("Merci pour votre aide.")
		swipe(world, "llm_tone_more_familiar")
		assert_request(world, world.posts[1], "tone_familiar", "Merci pour votre aide.")
		answer(world, world.posts[1], "REWRITE: Merci pour ton aide !")
		swipe(world, "llm_tone_more_familiar")
		helpers.assert_eq(#world.posts, 1)
		helpers.assert_eq(world.notices[1], require("infra.i18n").get("llm.tone.most_familiar"))
		swipe(world, "llm_tone_more_familiar_cycle")
		assert_request(world, world.posts[2], "tone_very_formal", "Merci pour votre aide.")
	end)

	-- One arrow press moves over one composed character: counting codepoints
	-- moved the caret one step too far for 👍🏽 and left a character outside
	helpers.it("reselects an emoji with a skin tone as one character", function()
		local world = build_world("merci")
		swipe(world, "llm_tone_more_familiar")
		local before = #world.keys + 1
		answer(world, world.posts[1], "REWRITE: Merci 👍🏽 !")
		assert_replacement(strokes_since(world, before), #"Merci " + 1 + #" !")
	end)

	helpers.it("does nothing when nothing is selected", function()
		local world = build_world("")
		swipe(world, "llm_tone_more_formal")
		helpers.assert_eq(#world.posts, 0, "no request")
		helpers.assert_eq(#world.notices, 0, "no notice")
		helpers.assert_eq(#world.document, 0)
		helpers.assert_eq(world.clipboard, USER_CLIPBOARD, "the clipboard is restored")
	end)

	helpers.it("refuses like a manual prediction when the AI is off", function()
		local world = build_world("merci pour ton aide")
		world.engine.set_llm_enabled(false)
		swipe(world, "llm_tone_more_formal")
		helpers.assert_eq(#world.posts, 0, "no request")
		helpers.assert_eq(#world.notices, 1)
		helpers.assert_eq(world.notices[1], require("infra.i18n").get("llm.manual_prediction.disabled"))
	end)

	helpers.it("types nothing when the focus moved before the answer", function()
		local world = build_world("merci pour ton aide")
		swipe(world, "llm_tone_more_formal")
		world.focus = "8:202"
		local before = #world.keys
		answer(world, world.posts[1], "REWRITE: Merci pour votre aide.")
		helpers.assert_eq(#world.keys, before, "no key reaches the other window")
		helpers.assert_eq(#world.document, 0)
		helpers.assert_eq(world.tone.get_memory(), nil)
	end)

	helpers.it("types nothing when the selection changed before the answer", function()
		local world = build_world("merci pour ton aide")
		swipe(world, "llm_tone_more_formal")
		world.selection = "une autre phrase"
		answer(world, world.posts[1], "REWRITE: Merci pour votre aide.")
		helpers.assert_eq(#world.document, 0, "the other selection is not replaced")
		helpers.assert_eq(world.selection, "une autre phrase")
		helpers.assert_eq(world.clipboard, USER_CLIPBOARD)
		helpers.assert_eq(world.tone.get_memory(), nil)
	end)

	helpers.it("ignores the answer of a superseded step", function()
		local world = build_world("merci pour ton aide")
		swipe(world, "llm_tone_more_formal")
		swipe(world, "llm_tone_more_familiar")
		helpers.assert_eq(#world.posts, 2)
		assert_request(world, world.posts[2], "tone_familiar", "merci pour ton aide")
		local before = #world.keys
		answer(world, world.posts[1], "REWRITE: Merci pour votre aide.")
		helpers.assert_eq(#world.keys, before, "the stale answer types nothing")
		answer(world, world.posts[2], "REWRITE: Merci pour ton aide !")
		helpers.assert_eq(world.document[1], "Merci pour ton aide !", "only the current answer is typed")
		helpers.assert_eq(#world.document, 1)
	end)

	helpers.it("types nothing when the answer holds no rewrite", function()
		local world = build_world("merci pour ton aide")
		swipe(world, "llm_tone_more_formal")
		answer(world, world.posts[1], "Sorry, I cannot help with that.")
		helpers.assert_eq(#world.document, 0)
	end)
end)
