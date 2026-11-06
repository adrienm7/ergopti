--- tests/unit/modules/llm/prediction/test_prompt_prediction.lua

--- ==============================================================================
--- MODULE: Prediction With A Chosen Prompt (Linux)
--- DESCRIPTION:
--- The llm_prompt_prediction action and its llm_predict_<profile> presets run a
--- prediction now with the prompt a binding names, and the "rewrite" prompt
--- rewrites the sentence being typed instead of continuing it.
---
--- Every scenario runs the real engine, the real profile registry, the real
--- prompt builder, the real parser and the real remote client (Cerebras, OpenAI
--- dialect); only the boundaries are scripted: the HTTP transport, the API key
--- store, the preferences file, the clock, the tooltip and the injector.
---
--- ROOT CAUSE ENCODED:
--- A prediction could only use the AI menu's profile: running another prompt
--- meant switching the menu first. A rewrite needs its tail to be the whole
--- current sentence (not the last five words), a budget that grows with it and
--- a context never cut inside it, or the parser cannot erase what it replaces.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = require("tests.fakes")
local Json = require("json")
local PreferencesFixture = require("tests.support.llm_preferences_fixture")
local Rewrite = require("llm.rewrite")
local PromptBuilder = require("llm.prompt_builder")

local ENTRY = { id = "cerebras-1", provider = "cerebras", label = "Cerebras", token = "k", model = "", base_url = "" }
local REWRITE_CORPUS = helpers.driver_root() .. "/../_shared/tests/corpus/llm/rewrite_vectors.json"

-- Modules loaded afresh for each scenario, so they bind the scripted boundaries
local RELOADED = {
	"modules.llm.prediction_engine", "modules.llm.settings", "modules.llm.profile_settings",
	"modules.llm.display_settings", "modules.llm.trigger_settings", "modules.llm.navigation_settings",
	"modules.llm.api_remote",
}
-- The boundaries a scenario scripts
local FAKED = {
	"adapters.secure_field_detector", "adapters.http_client", "modules.llm.api_entries",
	"modules.llm.profiles", "modules.llm.api_ollama",
}

-- The preferences every scenario starts from: the menu runs "basic" with
-- three predictions, chosen by hand, through the remote API
local BASE_PREFERENCES = {
	["llm.models.selected"] = "api",
	["llm.profiles.active"] = "basic",
	["llm.profiles.num_predictions"] = 3,
	["llm.profiles.auto_profile_for_model"] = false,
}





-- ==========================
-- ==========================
-- ======= 1/ Harness =======
-- ==========================
-- ==========================

--- Runs body against the real engine with scripted boundaries.
--- @param opts table { buffer, stored? } stored overrides BASE_PREFERENCES.
--- @param body function Receives the scenario's world.
local function scenario(opts, body)
	local stored = {}
	for key, value in pairs(BASE_PREFERENCES) do stored[key] = value end
	for key, value in pairs(opts.stored or {}) do stored[key] = value end
	PreferencesFixture.with(function(preferences)
		local previous = {}
		for _, name in ipairs(RELOADED) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
		for _, name in ipairs(FAKED) do previous[name] = package.loaded[name] end
		local world = { posts = {}, ollama = {}, notices = {}, injected = {}, shown = {},
			preferences = preferences, buffer = opts.buffer }
		package.loaded["adapters.secure_field_detector"] = {
			isSecureField = function() return false end,
			isSecureApp = function() return false end,
			isUrlBar = function() return false end,
		}
		package.loaded["adapters.http_client"] = {
			post = function(url, _, request_body, callback)
				world.posts[#world.posts + 1] = { url = url, body = Json.decode(request_body), callback = callback }
				return true
			end,
			cancel = function() return true end,
		}
		package.loaded["modules.llm.api_entries"] = { active = function() return ENTRY end }
		package.loaded["modules.llm.profiles"] = {
			init = function() end,
			is_enabled = function() return opts.disabled ~= true end,
			get_current_model = function() return "ollama-model" end,
			get_base_url = function() return "http://127.0.0.1:11434" end,
		}
		package.loaded["modules.llm.api_ollama"] = {
			chat = function(_, _, messages, request_opts, _, on_done)
				world.ollama[#world.ollama + 1] = { messages = messages, opts = request_opts, on_done = on_done }
			end,
			cancel = function() return true end,
		}
		local scheduler = Fakes.timer_scheduler()
		local engine = require("modules.llm.prediction_engine")
		engine.init({ focus_id = function() return "owned-prediction-window" end,
			scheduler = scheduler,
			clock_ms = function() return scheduler.now * 1000 end,
			engine = {
				reset = function() world.buffer = "" end,
			},
			context = { text = function() return world.buffer end, replaced = function() end },
			notify = function(text) world.notices[#world.notices + 1] = text; return true end,
			overlay = {
				show = function(candidates, meta)
					world.shown[#world.shown + 1] = { count = #candidates, profile = meta.profile }
					world.showing = #candidates > 0
					return true
				end,
				hide = function() world.showing = false; return true end,
				is_showing = function() return world.showing == true end,
			},
			apply_prediction = function(candidate)
				world.injected[#world.injected + 1] = { deletes = candidate.deletes, to_type = candidate.to_type }
				return true
			end,
		})
		world.engine = engine
		world.handlers = engine.action_handlers()

		--- The remote server answers request `index` with `text`.
		function world.respond(index, text)
			local post = assert(world.posts[index], "no request " .. index .. " was sent")
			post.callback({ ok = true, status = 200,
				body = Json.encode({ choices = { { message = { role = "assistant", content = text } } } }) })
		end

		--- Lets the pacing timer run until request `index` is sent, or long past it.
		function world.wait_for(index)
			for _ = 1, 20 do
				if world.posts[index] then return end
				scheduler.test.advance(0.5)
			end
		end

		--- Answers every request with `text`, letting the pacing timer send the next.
		function world.answer_all(text, expected)
			for index = 1, expected do
				world.wait_for(index)
				world.respond(index, text)
			end
			world.wait_for(expected + 1)
		end

		--- Answers request `index` with `texts[index]`, letting the pacing timer send the next.
		function world.answer_each(texts)
			for index, text in ipairs(texts) do
				world.wait_for(index)
				world.respond(index, text)
			end
			world.wait_for(#texts + 1)
		end

		--- Presses the validation chord of suggestion `index`.
		function world.press(index)
			local mods = {}
			for _, modifier in ipairs(require("modules.llm.navigation_settings").get()) do
				mods[modifier == "cmd" and "meta" or modifier] = true
			end
			return engine.handle_shortcut({ key = tostring(index), mods = mods })
		end

		local ok, err = pcall(body, world)
		engine.dismiss()
		for _, name in ipairs(RELOADED) do package.loaded[name] = previous[name] end
		for _, name in ipairs(FAKED) do package.loaded[name] = previous[name] end
		if not ok then error(err, 0) end
	end, { initial = stored })
end

--- The user turn a request carried.
--- @param post table
--- @return string
local function user_turn(post)
	local messages = post.body.messages
	return messages[#messages].content
end

--- The system turn a request carried ("" when none).
--- @param post table
--- @return string
local function system_turn(post)
	local first = post.body.messages[1]
	return first.role == "system" and first.content or ""
end

--- A built-in's name as the tooltip shows it: its menu label without the description.
--- @param id string
--- @return string
local function menu_name(id)
	return (require("infra.i18n").get("llm.profile." .. id .. ".label"):gsub("%s+\226\128\148.*$", ""))
end

--- Asserts the menu's profile and count were left exactly as they were.
--- @param world table
local function assert_menu_untouched(world)
	helpers.assert_eq(world.preferences.values["llm.profiles.active"], "basic",
		"the stored menu profile is unchanged")
	helpers.assert_eq(world.preferences.values["llm.profiles.num_predictions"], 3,
		"the stored menu count is unchanged")
	helpers.assert_eq(require("modules.llm.profile_settings").get("active"), "basic",
		"the live menu profile is unchanged")
end





-- ==============================================
-- ==============================================
-- ======= 2/ End to end, through the API =======
-- ==============================================
-- ==============================================

helpers.describe("prompt prediction: a rewrite from the key press to the injected text", function()

	helpers.it("llm_predict_rewrite rewrites the current sentence with the menu's count", function()
		scenario({ buffer = "Bonjour Marc. ok pr jd 14h" }, function(world)
			helpers.assert_eq(world.handlers.llm_predict_rewrite("keyboard__meta_r", nil), true,
				"the preset starts a request")
			helpers.assert_eq(#world.posts, 1, "the first variant is sent at once")
			local post = world.posts[1]
			helpers.assert_true(post.url:find("/chat/completions", 1, true) ~= nil, "OpenAI dialect: " .. post.url)
			helpers.assert_true(system_turn(post):find("^You are a text rewriting engine") ~= nil
				and system_turn(post):find("REWRITE:", 1, true) ~= nil,
				"the rewrite prompt is the system turn: " .. system_turn(post))
			helpers.assert_eq(user_turn(post), 'PREFIX: "Bonjour Marc. ok pr jd 14h"\nTAIL: "ok pr jd 14h"',
				"the tail is the current sentence, not the last words")
			helpers.assert_eq(post.body.max_tokens, Rewrite.max_tokens("ok pr jd 14h"), "the rewrite budget")

			world.answer_all("REWRITE: Ok pour jeudi 14 h.", 6)
			helpers.assert_eq(#world.posts, 6,
				"identical rewrites refill the menu's three up to the shared retry budget (3 x 2)")
			local suggestions = world.engine.get_suggestions()
			helpers.assert_eq(#suggestions, 1, "identical rewrites are offered once")
			helpers.assert_eq(suggestions[1].to_type, "Ok pour jeudi 14 h.")
			helpers.assert_eq(world.shown[#world.shown].profile, menu_name("rewrite"),
				"the tooltip names the prompt that ran, not the menu's")

			helpers.assert_true(world.press(1), "the validation chord accepts the rewrite")
			helpers.assert_eq(#world.injected, 1, "one injection")
			helpers.assert_eq(world.injected[1].deletes, #"ok pr jd 14h", "the whole sentence is erased")
			helpers.assert_eq(world.injected[1].to_type, "Ok pour jeudi 14 h.", "and retyped rewritten")
			assert_menu_untouched(world)
		end)
	end)

	helpers.it("llm_prompt_prediction 'rewrite|2' sends two requests and offers both rewrites", function()
		scenario({ buffer = "Bonjour Marc. ok pr jd 14h" }, function(world)
			helpers.assert_eq(world.handlers.llm_prompt_prediction("tap_3", "rewrite|2"), true)
			world.respond(1, "REWRITE: Ok pour jeudi 14 h.")
			world.wait_for(2)
			world.respond(2, "REWRITE: OK pour jeudi à 14 h.")
			world.wait_for(3)
			helpers.assert_eq(#world.posts, 2, "the binding's own count, not the menu's three")
			for _, post in ipairs(world.posts) do
				helpers.assert_eq(user_turn(post), 'PREFIX: "Bonjour Marc. ok pr jd 14h"\nTAIL: "ok pr jd 14h"')
				helpers.assert_eq(post.body.max_tokens, Rewrite.max_tokens("ok pr jd 14h"))
			end
			local suggestions = world.engine.get_suggestions()
			helpers.assert_eq(#suggestions, 2, "both rewrites are on offer")
			helpers.assert_true(world.press(2), "the second one is chosen")
			helpers.assert_eq(world.injected[1].deletes, #"ok pr jd 14h")
			helpers.assert_eq(world.injected[1].to_type, "OK pour jeudi à 14 h.")
			assert_menu_untouched(world)
		end)
	end)

	helpers.it("preserves explicit manual generation when trigger exclusions are invalid", function()
		scenario({ buffer = "Bonjour", stored = { ["llm.trigger.disabled_apps"] = { "firefox", "Firefox" } } }, function(world)
			helpers.assert_true(world.handlers.llm_generate_prediction("keyboard__meta_space", nil))
			helpers.assert_eq(#world.posts, 1, "an invalid automatic-only list does not change manual policy")
		end)
	end)

	helpers.it("a normal prediction is unchanged: the menu's prompt, count, tail and budget", function()
		scenario({ buffer = "Bonjour Marc, je voulais te dire" }, function(world)
			helpers.assert_eq(world.handlers.llm_generate_prediction("keyboard__meta_space", nil), true)
			local post = world.posts[1]
			helpers.assert_true(system_turn(post):find("REWRITE:", 1, true) == nil, "not the rewrite prompt")
			helpers.assert_eq(user_turn(post), "Bonjour Marc, je voulais te dire", "basic sends the text alone")
			local Settings = require("modules.llm.settings")
			local expected = PromptBuilder.build_params("Bonjour Marc, je voulais te dire",
				{ max_words = Settings.get("max_words") }).max_tokens
			helpers.assert_eq(post.body.max_tokens, expected, "the continuation budget")
			world.answer_each({ "que tout est prêt.", "que tout est prêt demain.", "que tout est enfin prêt." })
			helpers.assert_eq(#world.posts, 3, "the menu's three predictions")
			local suggestions = world.engine.get_suggestions()
			helpers.assert_true(#suggestions >= 1, "a continuation is offered")
			helpers.assert_true(world.press(1))
			helpers.assert_eq(world.injected[1].deletes, 0, "a continuation erases nothing")
			helpers.assert_true(world.injected[1].to_type:find("tout est prêt", 1, true) ~= nil,
				"and types the words: " .. world.injected[1].to_type)
			helpers.assert_eq(world.shown[#world.shown].profile, menu_name("basic"),
				"the tooltip names the menu's prompt")
		end)
	end)
end)





-- ============================================
-- ============================================
-- ======= 3/ Which prompt, which count =======
-- ============================================
-- ============================================

helpers.describe("prompt prediction: the binding's prompt and count, for this request only", function()

	helpers.it("every built-in has a preset that runs it with the menu's count", function()
		for _, id in ipairs({ "raw", "basic", "advanced", "batch_advanced", "rewrite",
			"tone_familiar", "tone_neutral", "tone_formal", "tone_very_formal", "translate_en", "translate_ja" }) do
			scenario({ buffer = "Bonjour Marc. ok pr jd 14h" }, function(world)
				local handler = world.handlers["llm_predict_" .. id]
				helpers.assert_eq(type(handler), "function", "llm_predict_" .. id .. " has a handler")
				helpers.assert_eq(handler("tap_3", nil), true)
				local expected = require("modules.llm.profile_settings").resolve_id(id)
				local system = system_turn(world.posts[1])
				if id == "raw" then
					helpers.assert_eq(system, "", "raw sends no system turn")
				else
					helpers.assert_eq(system:sub(1, 40), expected.system_single:sub(1, 40),
						"llm_predict_" .. id .. " sends its own prompt")
				end
				assert_menu_untouched(world)
			end)
		end
	end)

	helpers.it("a batch prompt asks for the binding's count in one request", function()
		scenario({ buffer = "Je vous envoie ce mail pour" }, function(world)
			helpers.assert_eq(world.handlers.llm_prompt_prediction("tap_3", "batch_advanced|2"), true)
			world.answer_all("TAIL_CORRECTED: pour\nNEXT_WORDS: vous dire\n===\nTAIL_CORRECTED: pour\nNEXT_WORDS: te dire", 1)
			helpers.assert_eq(#world.posts, 1, "a batch is one request")
			helpers.assert_true(system_turn(world.posts[1]):find("exactly 2 different", 1, true) ~= nil,
				"the batch template asks for the binding's two: " .. system_turn(world.posts[1]))
			-- The shared token budget: every variant of a batch adds its numbering room
			-- (macOS and Windows already did; Linux used to give the bare product).
			local base = PromptBuilder.build_params("Je vous envoie ce mail pour",
				{ max_words = require("modules.llm.settings").get("max_words") }).max_tokens
			helpers.assert_eq(world.posts[1].body.max_tokens, 2 * (base + 5), "a batch of two budget")
			assert_menu_untouched(world)
		end)
	end)

	helpers.it("outranks the automatic profile for the model", function()
		scenario({ buffer = "Bonjour Marc. ok pr jd 14h",
			stored = { ["llm.profiles.auto_profile_for_model"] = true } }, function(world)
			helpers.assert_eq(world.handlers.llm_prompt_prediction("tap_3", "rewrite|1"), true)
			helpers.assert_true(system_turn(world.posts[1]):find("REWRITE:", 1, true) ~= nil,
				"the binding's prompt, whatever the model would pick")
			helpers.assert_eq(world.preferences.values["llm.profiles.auto_profile_for_model"], true,
				"the automatic choice stays on")
		end)
	end)

	helpers.it("runs a custom prompt by its id", function()
		scenario({ buffer = "Bonjour Marc", stored = {
			["llm.user_profiles"] = require("llm.profile_registry_codec").encode({
				{ id = "user_formal", label = "Formal", system_single = "Continue formally.", batch = false },
			}),
		} }, function(world)
			helpers.assert_eq(world.handlers.llm_prompt_prediction("tap_3", "user_formal"), true)
			helpers.assert_eq(system_turn(world.posts[1]), "Continue formally.")
			world.answer_each({ " et toute l'équipe.", " et toute la famille.", " et tous les collègues." })
			helpers.assert_eq(#world.posts, 3, "no count of its own: the menu's")
			helpers.assert_eq(world.shown[#world.shown].profile, "Formal", "the tooltip shows its label")
		end)
	end)

	helpers.it("refuses a prompt that no longer exists, and says so", function()
		scenario({ buffer = "Bonjour Marc" }, function(world)
			helpers.assert_eq(world.handlers.llm_prompt_prediction("tap_3", "user_deleted|2"), false)
			helpers.assert_eq(#world.posts, 0, "nothing is sent, not even with another prompt")
			helpers.assert_eq(#world.notices, 1, "the user is told")
			helpers.assert_eq(world.notices[1], require("infra.i18n").get("llm.prompt_prediction.unknown_prompt"))
			assert_menu_untouched(world)
		end)
	end)

	helpers.it("refuses like the manual prediction while the AI is off", function()
		scenario({ buffer = "Bonjour Marc", disabled = true }, function(world)
			helpers.assert_eq(world.handlers.llm_predict_rewrite("tap_3", nil), false)
			helpers.assert_eq(world.notices[1], require("infra.i18n").get("llm.manual_prediction.disabled"))
			helpers.assert_eq(#world.posts, 0)
		end)
	end)

	helpers.it("refuses an invalid parameter without sending anything", function()
		scenario({ buffer = "Bonjour Marc" }, function(world)
			helpers.assert_eq(world.handlers.llm_prompt_prediction("tap_3", "rewrite|11"), false)
			helpers.assert_eq(#world.posts, 0)
		end)
	end)
end)





-- ======================================
-- ======================================
-- ======= 4/ The rewrite request =======
-- ======================================
-- ======================================

helpers.describe("prompt prediction: what a rewrite sends", function()

	helpers.it("refuses a blank sentence like an empty buffer", function()
		scenario({ buffer = "\n  " }, function(world)
			helpers.assert_eq(world.handlers.llm_prompt_prediction("tap_3", "rewrite"), false)
			helpers.assert_eq(#world.posts, 0, "there is nothing to rewrite")
			helpers.assert_eq(world.notices[1], require("infra.i18n").get("llm.manual_prediction.empty_context"))
		end)
	end)

	helpers.it("widens a capped context to hold the whole sentence", function()
		scenario({ buffer = "" }, function(world)
			local Settings = require("modules.llm.settings")
			helpers.assert_true(Settings.set("context_length", 100))
			local sentence = string.rep("jd ok pr ", 20) .. "fin"
			world.buffer = "Intro. " .. sentence
			helpers.assert_eq(world.handlers.llm_prompt_prediction("tap_3", "rewrite|1"), true)
			helpers.assert_eq(user_turn(world.posts[1]),
				'PREFIX: "' .. sentence .. '"\nTAIL: "' .. sentence .. '"',
				"the sentence is sent whole even past the 100-character cap")
			helpers.assert_eq(world.posts[1].body.max_tokens, Rewrite.max_tokens(sentence))
			helpers.assert_true(Rewrite.max_tokens(sentence) > 200, "a long sentence gets a long budget")
		end)
	end)

	helpers.it("keeps its budget when the continuation budget is overridden", function()
		scenario({ buffer = "Bonjour Marc. ok pr jd 14h" }, function(world)
			world.engine.set_max_tokens(8)
			helpers.assert_eq(world.handlers.llm_predict_rewrite("tap_3", nil), true)
			helpers.assert_eq(world.posts[1].body.max_tokens, Rewrite.max_tokens("ok pr jd 14h"))
		end)
	end)

	helpers.it("applies to the menu's rewrite profile and to a typing trigger", function()
		scenario({ buffer = "", stored = { ["llm.profiles.active"] = "rewrite",
			["llm.models.selected"] = "ollama" } }, function(world)
			world.engine.predict("Bonjour Marc. ok pr jd 14h", nil)
			helpers.assert_eq(#world.ollama, 1, "Ollama is asked")
			local request = world.ollama[1]
			helpers.assert_eq(request.messages[#request.messages].content,
				'PREFIX: "Bonjour Marc. ok pr jd 14h"\nTAIL: "ok pr jd 14h"')
			helpers.assert_eq(request.opts.max_tokens, Rewrite.max_tokens("ok pr jd 14h"))
			helpers.assert_eq(request.opts.line_mode, true, "one line: REWRITE: <sentence>")
			request.on_done("REWRITE: Ok pour jeudi 14 h.", nil)
			local suggestions = world.engine.get_suggestions()
			helpers.assert_eq(#suggestions, 1)
			helpers.assert_eq(suggestions[1].deletes, #"ok pr jd 14h")
			helpers.assert_eq(suggestions[1].to_type, "Ok pour jeudi 14 h.")
		end)
	end)

	helpers.it("erases the trigger typed after the sentence too", function()
		scenario({ buffer = "", stored = { ["llm.profiles.active"] = "rewrite",
			["llm.models.selected"] = "ollama" } }, function(world)
			world.engine.predict("Bonjour Marc. ok pr jd 14h//", { input_chars = 2 })
			local request = world.ollama[1]
			helpers.assert_eq(request.messages[#request.messages].content,
				'PREFIX: "Bonjour Marc. ok pr jd 14h"\nTAIL: "ok pr jd 14h"', "the trigger is not rewritten")
			request.on_done("REWRITE: Ok pour jeudi 14 h.", nil)
			helpers.assert_eq(world.engine.get_suggestions()[1].deletes, #"ok pr jd 14h" + 2)
		end)
	end)

	helpers.it("replays the shared sentence vectors through the engine", function()
		local fh = assert(io.open(REWRITE_CORPUS, "r"), "cannot open " .. REWRITE_CORPUS)
		local corpus = Json.decode(fh:read("*a"))
		fh:close()
		helpers.assert_true(#corpus.sentence_vectors >= 10, "the corpus holds its vectors")
		for _, vector in ipairs(corpus.sentence_vectors) do
			scenario({ buffer = vector.buffer }, function(world)
				local started = world.handlers.llm_prompt_prediction("tap_3", "rewrite|1")
				if vector.span == "" then
					helpers.assert_eq(started, false, vector.id .. ": nothing to rewrite")
					return
				end
				helpers.assert_eq(started, true, vector.id .. ": the request starts")
				local turn = user_turn(world.posts[1])
				helpers.assert_eq(turn:sub(-(#vector.span + 1)), vector.span .. '"',
					vector.id .. ": TAIL is the span; sent " .. turn)
			end)
		end
	end)
end)

helpers.it("runs a free-language contextual rewrite without changing the menu profile", function()
	scenario({ buffer = "Bonjour Marc. On se voit demain ?" }, function(world)
		helpers.assert_eq(world.handlers.llm_prompt_prediction("tap_3", "translate|1|Esperanto"), true)
		helpers.assert_eq(#world.posts, 1)
		helpers.assert_true(system_turn(world.posts[1]):find("Translate TAIL into Esperanto", 1, true) ~= nil)
		helpers.assert_true(system_turn(world.posts[1]):find("REWRITE:", 1, true) ~= nil)
		helpers.assert_eq(user_turn(world.posts[1]), 'PREFIX: "Bonjour Marc. On se voit demain ?"\nTAIL: "On se voit demain ?"')
		assert_menu_untouched(world)
	end)
end)





-- ===========================================
-- ===========================================
-- ======= 4/ Shared sequential retries =======
-- ===========================================
-- ===========================================

-- The retry policy of _shared/modules/llm/inference.json, which macOS and
-- Windows already apply: max_multiplier attempts per requested prediction,
-- and a failed or empty attempt followed by one with more room and warmth.
local INFERENCE = helpers.driver_root() .. "/../_shared/modules/llm/inference.json"

--- The shared retry policy, read from its single source.
--- @return table
local function retry_policy()
	local fh = assert(io.open(INFERENCE, "r"), "cannot open " .. INFERENCE)
	local root = Json.decode(fh:read("*a"))
	fh:close()
	return root.retry
end

helpers.describe("prompt prediction: sequential variants follow the shared retry policy", function()
	helpers.it("refills the requested count after duplicate answers", function()
		scenario({ buffer = "Bonjour Marc, je voulais te dire" }, function(world)
			helpers.assert_eq(world.handlers.llm_generate_prediction("keyboard__meta_space", nil), true)
			world.answer_each({ "que tout est prêt.", "que tout est prêt.",
				"que tout est prêt demain.", "que tout est enfin prêt." })
			helpers.assert_eq(#world.posts, 4, "one more attempt replaces the duplicate")
			helpers.assert_eq(#world.engine.get_suggestions(), 3, "the three requested predictions")
		end)
	end)

	helpers.it("retries a failed request with the policy's extra tokens and temperature", function()
		scenario({ buffer = "Bonjour Marc, je voulais te dire" }, function(world)
			local policy = retry_policy()
			helpers.assert_eq(world.handlers.llm_generate_prediction("keyboard__meta_space", nil), true)
			local first = world.posts[1].body
			world.posts[1].callback({ ok = false, status = 500, body = "{}" })
			world.wait_for(2)
			local retried = assert(world.posts[2], "the failed variant is retried").body
			helpers.assert_eq(retried.max_tokens, first.max_tokens + policy.retry_extra_tokens)
			helpers.assert_true(math.abs(retried.temperature - (first.temperature + policy.retry_temperature_step)) < 1e-9,
				"the retry is warmer by the policy's step")
			for index, text in ipairs({ "que tout est prêt.", "que tout est prêt demain.", "que tout est enfin prêt." }) do
				world.wait_for(index + 1)
				world.respond(index + 1, text)
			end
			helpers.assert_eq(#world.engine.get_suggestions(), 3, "the failure did not end the request")
		end)
	end)

	helpers.it("stops at max_multiplier attempts per requested prediction", function()
		scenario({ buffer = "Bonjour Marc, je voulais te dire" }, function(world)
			local budget = 3 * retry_policy().max_multiplier
			helpers.assert_eq(world.handlers.llm_generate_prediction("keyboard__meta_space", nil), true)
			for index = 1, budget + 1 do
				world.wait_for(index)
				if world.posts[index] then world.posts[index].callback({ ok = false, status = 500, body = "{}" }) end
			end
			world.wait_for(budget + 1)
			helpers.assert_eq(#world.posts, budget, "no attempt beyond the shared budget")
			helpers.assert_eq(#world.engine.get_suggestions(), 0)
		end)
	end)
end)
