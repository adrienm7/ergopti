--- tests/unit/modules/llm/test_live_mode.lua

--- ==============================================================================
--- MODULE: Live Mode (Linux)
--- DESCRIPTION:
--- The retained llm_live_prompt_toggle action redirects
--- the automatic typing trigger to a chosen prompt: with translate_en the
--- tooltip shows the sentence being typed in English, and Tab replaces it.
---
--- Every scenario runs the real engine, the real profile registry, the real
--- prompt builder, the real parser and the real remote client (Cerebras, OpenAI
--- dialect); only the boundaries are scripted: the HTTP transport, the API key
--- store, the preferences file, the clock, the tooltip and the injector.
---
--- ROOT CAUSE ENCODED:
--- Translating while typing meant pressing a prompt action after every
--- sentence. Live mode must reuse the one AI tooltip (never a second
--- pipeline), yield to hotstrings, leave Tab alone unless its own tooltip is on
--- screen, and leave the menu's prediction exactly as it was once turned off.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = require("tests.fakes")
local Json = require("json")
local PreferencesFixture = require("tests.support.llm_preferences_fixture")
local EvdevCodes = require("infra.evdev_codes")

local ENTRY = { id = "cerebras-1", provider = "cerebras", label = "Cerebras", token = "k", model = "", base_url = "" }
local LIVE_JSON = helpers.driver_root() .. "/../_shared/modules/llm/live.json"
local SENTENCE = "on se voit demain"

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
	["llm.trigger.instant_on_word_end"] = false,
}





-- ==========================
-- ==========================
-- ======= 1/ Harness =======
-- ==========================
-- ==========================

--- Runs body against the real engine with scripted boundaries.
--- @param opts table { buffer?, stored?, disabled? } stored overrides BASE_PREFERENCES.
--- @param body function Receives the scenario's world.
local function scenario(opts, body)
	local stored = {}
	for key, value in pairs(BASE_PREFERENCES) do stored[key] = value end
	for key, value in pairs(opts.stored or {}) do stored[key] = value end
	PreferencesFixture.with(function(preferences)
		local previous = {}
		for _, name in ipairs(RELOADED) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
		for _, name in ipairs(FAKED) do previous[name] = package.loaded[name] end
		local world = { posts = {}, notices = {}, injected = {}, shown = {}, live_changes = 0,
			preferences = preferences, buffer = opts.buffer or "", paused = false, preview = false }
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
		require("tests.support.owned_http_fixture").attach(package.loaded["adapters.http_client"])
		package.loaded["modules.llm.api_entries"] = { active = function() return ENTRY end }
		local ai_on = opts.disabled ~= true
		package.loaded["modules.llm.profiles"] = {
			init = function() end,
			is_enabled = function() return ai_on end,
			enable = function() ai_on = true; return true end,
			disable = function() ai_on = false; return true end,
			get_current_model = function() return "ollama-model" end,
			get_base_url = function() return "http://127.0.0.1:11434" end,
		}
		package.loaded["modules.llm.api_ollama"] = {
			chat = function() error("the scenario runs through the API") end,
			cancel = function() return true end,
		}
		local scheduler = Fakes.timer_scheduler()
		local engine = require("modules.llm.prediction_engine")
		engine.init({
			scheduler = scheduler,
			clock_ms = function() return scheduler.now * 1000 end,
			engine = {
				current_buffer = function() return world.buffer end,
				reset = function() world.buffer = "" end,
			},
			is_paused = function() return world.paused end,
			notify = function(text) world.notices[#world.notices + 1] = text; return true end,
			on_live_change = function() world.live_changes = world.live_changes + 1 end,
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
		world.scheduler = scheduler
		world.handlers = engine.action_handlers()

		--- Types text one character at a time, as the daemon feeds the engine.
		function world.type(text)
			for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
				world.buffer = world.buffer .. ch
				engine.on_char(ch, world.buffer, { app_id = "editor", hotstring_preview_visible = world.preview })
			end
		end

		--- The remote server answers request `index` with `text`.
		function world.respond(index, text)
			local post = assert(world.posts[index], "no request " .. index .. " was sent")
			post.callback({ ok = true, status = 200,
				body = Json.encode({ choices = { { message = { role = "assistant", content = text } } } }) })
		end

		--- Lets the timers run until request `index` is sent, or long past it.
		function world.wait_for(index)
			for _ = 1, 20 do
				if world.posts[index] then return end
				scheduler.test.advance(0.5)
			end
		end

		--- Presses Tab, with the given modifiers held.
		function world.tab(mods)
			return engine.handle_shortcut({ key = "tab", code = EvdevCodes.KEY_TAB, mods = mods or {} })
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
		engine.stop_live("scenario end", false)
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

--- Whether a request ran a built-in's own prompt.
--- @param post table
--- @param id string
--- @return boolean
local function runs_prompt(post, id)
	local expected = require("modules.llm.profile_settings").resolve_id(id).system_single
	return system_turn(post):sub(1, 60) == expected:sub(1, 60)
end

--- The shipped live.json.
--- @return table
local function live_json()
	local fh = assert(io.open(LIVE_JSON, "r"), "cannot open " .. LIVE_JSON)
	local config = Json.decode(fh:read("*a"))
	fh:close()
	return config
end

--- Asserts the menu's profile, count and trigger were left exactly as they were.
--- @param world table
--- @param expected_profile string|nil Explicit manual selection, or the original profile.
local function assert_menu_untouched(world, expected_profile)
	expected_profile = expected_profile or "basic"
	helpers.assert_eq(world.preferences.values["llm.profiles.active"], expected_profile, "the stored menu profile")
	helpers.assert_eq(world.preferences.values["llm.profiles.num_predictions"], 3, "the stored menu count")
	helpers.assert_eq(world.preferences.values["llm.trigger.debounce_ms"], nil, "the menu's debounce")
	helpers.assert_eq(require("modules.llm.profile_settings").get("active"), expected_profile, "the live menu profile")
end

--- The notice live mode shows when it starts with a built-in.
--- @param id string
--- @param count integer
--- @return string
local function on_notice(id, count)
	local ProfileSettings = require("modules.llm.profile_settings")
	local label = ProfileSettings.menu_label(ProfileSettings.resolve_id(id), count)
	local template = require("infra.i18n").get("llm.live.on")
	local at = assert(template:find("{1}", 1, true), "llm.live.on names the prompt")
	return template:sub(1, at - 1) .. label .. template:sub(at + 3)
end

--- Turns live mode on with translate_en and one prediction, then types the sentence.
--- @param world table
local function type_translated(world)
	helpers.assert_eq(world.handlers.llm_live_prompt_toggle("tap_3", "translate_en|1"), true)
	world.type(SENTENCE)
	world.scheduler.test.advance(live_json().debounce_ms / 1000)
	helpers.assert_eq(#world.posts, 1, "one request after the live debounce")
	world.respond(1, "REWRITE: See you tomorrow")
end





-- ======================================
-- ======================================
-- ======= 2/ Typing in live mode =======
-- ======================================
-- ======================================

helpers.describe("live mode: the sentence translated as it is typed", function()

	helpers.it("ships a debounce shorter than the menu's and no word floor", function()
		local config = live_json()
		helpers.assert_eq(require("modules.llm.prediction_engine").parse_live_config(Json.encode(config)).debounce_ms,
			config.debounce_ms, "the engine reads the shipped file")
		helpers.assert_eq(require("infra.manifest_reader").default_for("llm.trigger.debounce_ms") > config.debounce_ms,
			true, "otherwise the tests below could not tell the two debounces apart")
		helpers.assert_eq(config.min_words, 0)
		helpers.assert_eq(require("modules.llm.prediction_engine").parse_live_config('{"debounce_ms": -1, "min_words": 0}'),
			nil, "a negative debounce is refused")
		helpers.assert_eq(require("modules.llm.prediction_engine").parse_live_config("{"), nil, "and broken JSON")
	end)

	helpers.it("turns on with the binding's prompt and says so, changing no menu setting", function()
		scenario({}, function(world)
			helpers.assert_eq(world.handlers.llm_live_prompt_toggle("tap_3", "translate_en|1"), true)
			helpers.assert_eq(world.engine.get_live().profile_id, "translate_en")
			helpers.assert_eq(world.engine.get_live().num_predictions, 1)
			helpers.assert_eq(world.notices[1], on_notice("translate_en", 1))
			helpers.assert_eq(world.live_changes, 1, "the tray is told")
			helpers.assert_eq(#world.posts, 0, "nothing is sent before the user types")
			assert_menu_untouched(world)
		end)
	end)

	helpers.it("sends the sentence to translate_en after the live debounce, not the menu's", function()
		scenario({}, function(world)
			helpers.assert_eq(world.handlers.llm_live_prompt_toggle("tap_3", "translate_en|1"), true)
			world.type(SENTENCE)
			local debounce = live_json().debounce_ms / 1000
			world.scheduler.test.advance(debounce * 0.9)
			helpers.assert_eq(#world.posts, 0, "a burst of keystrokes is one request")
			world.scheduler.test.advance(debounce * 0.2)
			helpers.assert_eq(#world.posts, 1, "sent after the live debounce")
			local post = world.posts[1]
			helpers.assert_true(runs_prompt(post, "translate_en"), "the live prompt: " .. system_turn(post))
			helpers.assert_eq(user_turn(post), 'PREFIX: "' .. SENTENCE .. '"\nTAIL: "' .. SENTENCE .. '"',
				"TAIL is the current sentence")

			world.respond(1, "REWRITE: See you tomorrow")
			local suggestions = world.engine.get_suggestions()
			helpers.assert_eq(#suggestions, 1, "the binding's one prediction")
			helpers.assert_eq(suggestions[1].to_type, "See you tomorrow")
			helpers.assert_eq(suggestions[1].deletes, #SENTENCE)
			helpers.assert_eq(world.showing, true, "the tooltip offers it")

			helpers.assert_true(world.tab(), "Tab accepts the live rewrite")
			helpers.assert_eq(#world.injected, 1)
			helpers.assert_eq(world.injected[1].deletes, #SENTENCE, "the whole sentence is erased")
			helpers.assert_eq(world.injected[1].to_type, "See you tomorrow", "and replaced by its translation")
			helpers.assert_eq(world.showing, false, "the tooltip is gone")
			assert_menu_untouched(world)
		end)
	end)

	helpers.it("asks from the first word, below the menu's minimum word count", function()
		scenario({}, function(world)
			helpers.assert_true(require("modules.llm.settings").get("min_words") > 1,
				"the menu asks for several words")
			helpers.assert_eq(world.handlers.llm_live_prompt_toggle("tap_3", "translate_en|1"), true)
			world.type("on")
			world.scheduler.test.advance(live_json().debounce_ms / 1000)
			helpers.assert_eq(#world.posts, 1, "one word is enough")
			world.respond(1, "REWRITE: We")
			helpers.assert_eq(world.engine.get_suggestions()[1].to_type, "We", "a one-word rewrite is offered")
		end)
	end)

	helpers.it("runs with the menu's count when the binding names none", function()
		scenario({}, function(world)
			helpers.assert_eq(world.handlers.llm_live_prompt_toggle("tap_3", "translate_en"), true)
			helpers.assert_eq(world.notices[1], on_notice("translate_en", 3))
			world.type(SENTENCE)
			for index = 1, 3 do
				world.wait_for(index)
				world.respond(index, "REWRITE: See you tomorrow " .. index)
			end
			world.wait_for(4)
			helpers.assert_eq(#world.posts, 3, "the menu's three predictions")
			helpers.assert_eq(#world.engine.get_suggestions(), 3)
		end)
	end)

	helpers.it("ignores the answer of a request a new keystroke superseded", function()
		scenario({}, function(world)
			helpers.assert_eq(world.handlers.llm_live_prompt_toggle("tap_3", "translate_en|1"), true)
			world.type("on se")
			world.wait_for(1)
			world.type(" voit")
			world.wait_for(2)
			helpers.assert_eq(#world.posts, 2, "the new keystroke asks again")
			helpers.assert_eq(user_turn(world.posts[2]), 'PREFIX: "on se voit"\nTAIL: "on se voit"')
			world.respond(1, "REWRITE: We")
			helpers.assert_eq(#world.engine.get_suggestions(), 0, "the stale answer is dropped")
			world.respond(2, "REWRITE: We see")
			helpers.assert_eq(world.engine.get_suggestions()[1].to_type, "We see", "the current one is offered")
		end)
	end)

	helpers.it("does not ask again about the accepted sentence until the user types", function()
		scenario({}, function(world)
			type_translated(world)
			helpers.assert_true(world.tab())
			world.scheduler.test.advance(10)
			helpers.assert_eq(#world.posts, 1, "nothing is re-requested")
			world.type(" ok")
			world.wait_for(2)
			helpers.assert_eq(#world.posts, 2, "the next keystroke asks again")
			helpers.assert_eq(user_turn(world.posts[2]), 'PREFIX: " ok"\nTAIL: "ok"',
				"about the text typed since, never the accepted sentence")
		end)
	end)
end)





-- ===================================
-- ===================================
-- ======= 3/ On, off, refused =======
-- ===================================
-- ===================================

helpers.describe("live mode: turning it on and off", function()

	helpers.it("a second press turns it off, whatever its prompt, and typing is the menu's again", function()
		scenario({}, function(world)
			helpers.assert_eq(world.handlers.llm_live_prompt_toggle("tap_3", "translate_en|1"), true)
			helpers.assert_eq(world.handlers.llm_live_prompt_toggle("tap_4", "rewrite|2"), true)
			helpers.assert_eq(world.engine.get_live(), nil, "off")
			helpers.assert_eq(world.notices[2], require("infra.i18n").get("llm.live.off"))
			helpers.assert_eq(world.live_changes, 2)
			world.type("Bonjour Marc")
			world.scheduler.test.advance(live_json().debounce_ms / 1000 * 2)
			helpers.assert_eq(#world.posts, 0, "the live debounce no longer applies")
			world.scheduler.test.advance(require("modules.llm.trigger_settings").get("debounce_ms") / 1000)
			helpers.assert_eq(#world.posts, 1, "the menu's debounce does")
			helpers.assert_true(runs_prompt(world.posts[1], "basic"), "with the menu's prompt")
			for index = 1, 3 do
				world.wait_for(index)
				world.respond(index, "et toute l'équipe " .. index)
			end
			world.wait_for(4)
			helpers.assert_eq(#world.posts, 3, "and the menu's count")
			assert_menu_untouched(world)
		end)
	end)

	helpers.it("turning off withdraws the live offer on screen", function()
		scenario({}, function(world)
			type_translated(world)
			helpers.assert_eq(world.showing, true)
			helpers.assert_eq(world.handlers.llm_live_prompt_toggle("tap_3", "translate_en|1"), true)
			helpers.assert_eq(world.showing, false, "the live tooltip goes with live mode")
		end)
	end)

	helpers.it("refuses a prompt that no longer exists, and stays off", function()
		scenario({}, function(world)
			helpers.assert_eq(world.handlers.llm_live_prompt_toggle("tap_3", "user_deleted|2"), false)
			helpers.assert_eq(world.engine.get_live(), nil)
			helpers.assert_eq(world.notices[1], require("infra.i18n").get("llm.prompt_prediction.unknown_prompt"))
			helpers.assert_eq(world.live_changes, 0)
			assert_menu_untouched(world)
		end)
	end)

	helpers.it("stops, never falls back, when its prompt is deleted while it runs", function()
		scenario({ stored = {
			["llm.user_profiles"] = require("modules.llm.profile_registry_codec").encode({
				{ id = "user_pirate", label = "Pirate", system_single = "Rewrite as a pirate.\nREWRITE: <text>", batch = false },
			}),
		} }, function(world)
			helpers.assert_eq(world.handlers.llm_live_prompt_toggle("tap_3", "user_pirate|1"), true)
			helpers.assert_true(require("modules.llm.profile_settings").delete_user_profile("user_pirate"))
			world.type(SENTENCE)
			world.scheduler.test.advance(live_json().debounce_ms / 1000)
			helpers.assert_eq(#world.posts, 0, "nothing is sent with another prompt")
			helpers.assert_eq(world.engine.get_live(), nil, "live mode is off")
		end)
	end)

	helpers.it("refuses an invalid parameter without turning on", function()
		scenario({}, function(world)
			helpers.assert_eq(world.handlers.llm_live_prompt_toggle("tap_3", "translate_en|11"), false)
			helpers.assert_eq(world.engine.get_live(), nil)
		end)
	end)

	helpers.it("refuses like a manual prediction while the AI is off, paused or has no backend", function()
		scenario({ disabled = true }, function(world)
			helpers.assert_eq(world.handlers.llm_live_prompt_toggle("tap_3", "translate_en"), false)
			helpers.assert_eq(world.engine.get_live(), nil)
			helpers.assert_eq(world.notices[1], require("infra.i18n").get("llm.manual_prediction.disabled"))
		end)
		scenario({}, function(world)
			world.paused = true
			helpers.assert_eq(world.handlers.llm_live_prompt_toggle("tap_3", "translate_en"), false)
			helpers.assert_eq(world.notices[1], require("infra.i18n").get("llm.manual_prediction.paused"))
		end)
		scenario({}, function(world)
			package.loaded["modules.llm.api_entries"] = { active = function() return nil end }
			helpers.assert_eq(world.handlers.llm_live_prompt_toggle("tap_3", "translate_en"), false)
			helpers.assert_eq(world.notices[1], require("infra.i18n").get("llm.manual_prediction.backend_not_ready"))
		end)
	end)

	helpers.it("a pause turns it off silently, and resuming leaves it off", function()
		scenario({}, function(world)
			type_translated(world)
			world.paused = true
			world.engine.on_pause_change(true)
			helpers.assert_eq(world.engine.get_live(), nil)
			helpers.assert_eq(#world.notices, 1, "only the 'on' notice: the pause is silent")
			world.paused = false
			world.engine.on_pause_change(false)
			helpers.assert_eq(world.engine.get_live(), nil, "still off after resuming")
			world.type(" encore")
			world.scheduler.test.advance(live_json().debounce_ms / 1000 * 2)
			helpers.assert_eq(#world.posts, 1, "typing waits for the menu's debounce again")
			assert_menu_untouched(world)
		end)
	end)

	helpers.it("switching the AI off turns it off silently", function()
		scenario({}, function(world)
			helpers.assert_eq(world.handlers.llm_live_prompt_toggle("tap_3", "translate_en|1"), true)
			helpers.assert_true(world.engine.disable())
			helpers.assert_eq(world.engine.get_live(), nil)
			helpers.assert_eq(#world.notices, 1, "no 'off' notice")
			helpers.assert_true(world.engine.enable())
			helpers.assert_eq(world.engine.get_live(), nil, "switching it back on does not restore live mode")
		end)
	end)

	helpers.it("is off at every start", function()
		scenario({}, function(world)
			helpers.assert_eq(world.handlers.llm_live_prompt_toggle("tap_3", "translate_en|1"), true)
			world.engine.init({ scheduler = world.scheduler })
			helpers.assert_eq(world.engine.get_live(), nil)
		end)
	end)
end)





-- ==============================================
-- ==============================================
-- ======= 4/ One tooltip, and its rivals =======
-- ==============================================
-- ==============================================

helpers.describe("live mode: hotstrings, Tab and explicit actions", function()

	helpers.it("waits while a hotstring preview is shown, then asks once it is gone", function()
		scenario({ stored = { ["llm.trigger.after_hotstring"] = false } }, function(world)
			helpers.assert_eq(world.handlers.llm_live_prompt_toggle("tap_3", "translate_en|1"), true)
			world.preview = true
			world.type("on se voit dm")
			world.scheduler.test.advance(5)
			helpers.assert_eq(#world.posts, 0, "no live tooltip over the hotstring preview")
			world.preview = false
			helpers.assert_true(world.engine.on_hotstring_expired(world.buffer, { app_id = "editor" }),
				"the preview's expiry releases the request")
			world.scheduler.test.advance(0)
			helpers.assert_eq(#world.posts, 1)
			helpers.assert_eq(user_turn(world.posts[1]), 'PREFIX: "on se voit dm"\nTAIL: "on se voit dm"')
		end)
	end)

	helpers.it("an expansion dismisses the live tooltip and asks again about the expanded text", function()
		scenario({}, function(world)
			helpers.assert_eq(world.handlers.llm_live_prompt_toggle("tap_3", "translate_en|1"), true)
			world.type("on se voit dm")
			world.wait_for(1)
			world.respond(1, "REWRITE: See you dm")
			helpers.assert_eq(world.showing, true)
			-- The daemon expands before it feeds the engine: the buffer it passes
			-- already holds the replacement.
			world.buffer = "on se voit demain"
			world.engine.on_char(" ", world.buffer .. " ", { app_id = "editor" })
			world.buffer = world.buffer .. " "
			helpers.assert_eq(world.showing, false, "the hotstring wins: the live tooltip is dismissed")
			helpers.assert_eq(#world.engine.get_suggestions(), 0)
			world.wait_for(2)
			helpers.assert_eq(user_turn(world.posts[2]), 'PREFIX: "on se voit demain "\nTAIL: "on se voit demain "',
				"the request is re-issued on the expanded text")
		end)
	end)

	helpers.it("leaves Tab alone without a live tooltip on screen", function()
		scenario({ buffer = "Bonjour Marc. " .. SENTENCE }, function(world)
			helpers.assert_eq(world.tab(), false, "no offer: Tab is the application's")
			helpers.assert_eq(world.handlers.llm_predict_translate_en("tap_3", nil), true)
			world.wait_for(1)
			world.respond(1, "REWRITE: See you tomorrow")
			world.wait_for(3)
			helpers.assert_eq(world.showing, true, "an explicit action's offer is on screen")
			helpers.assert_eq(world.tab(), false, "Tab does not accept an offer live mode did not make")
			helpers.assert_eq(#world.injected, 0)
		end)
		scenario({}, function(world)
			helpers.assert_eq(world.handlers.llm_live_prompt_toggle("tap_3", "translate_en|1"), true)
			world.type(SENTENCE)
			helpers.assert_eq(world.tab(), false, "live mode on, nothing offered yet: Tab is untouched")
			world.scheduler.test.advance(live_json().debounce_ms / 1000)
			helpers.assert_eq(world.tab(), false, "still loading: Tab is untouched")
			world.respond(1, "REWRITE: See you tomorrow")
			helpers.assert_eq(world.tab({ shift = true }), false, "Shift+Tab is the application's")
			helpers.assert_eq(world.tab({ ctrl = true }), false, "and Ctrl+Tab")
			helpers.assert_eq(#world.injected, 0)
			helpers.assert_true(world.press(1), "the validation chord still accepts it")
			helpers.assert_eq(world.injected[1].to_type, "See you tomorrow")
		end)
	end)

	helpers.it("an explicit action takes over, and live mode resumes at the next keystroke", function()
		scenario({}, function(world)
			type_translated(world)
			helpers.assert_eq(world.handlers.llm_predict_rewrite("tap_4", nil), true)
			world.wait_for(2)
			helpers.assert_eq(#world.posts, 2, "the explicit request is sent")
			helpers.assert_true(runs_prompt(world.posts[2], "rewrite"), "with its own prompt")
			helpers.assert_eq(world.engine.get_live().profile_id, "translate_en", "live mode stays on")
			world.respond(2, "REWRITE: On se voit demain.")
			helpers.assert_eq(world.tab(), false, "its offer is not live mode's")
			world.type(" ?")
			world.wait_for(3)
			helpers.assert_true(runs_prompt(world.posts[#world.posts], "translate_en"),
				"the next keystroke is live again")
		end)
	end)
end)





-- ==============================
-- ==============================
-- ======= 5/ The AI menu =======
-- ==============================
-- ==============================

helpers.describe("live mode: one normal profile chooser and retained prompt actions", function()

	--- Finds the first rendered row with this title.
	local function find(rows, title)
		for _, row in ipairs(rows or {}) do
			if row.title == title then return row end
			local nested = find(row.menu, title)
			if nested then return nested end
		end
	end

	helpers.it("has one profile chooser, keeps prompt actions and retires their override on explicit selection", function()
		scenario({ stored = {
			["llm.user_profiles"] = require("modules.llm.profile_registry_codec").encode({
				{ id = "user_pirate", label = "Pirate", system_single = "Rewrite as a pirate.\nREWRITE: <text>", batch = false },
				{ id = "user_plain", label = "Plain", system_single = "Continue.", batch = false },
			}),
		} }, function(world)
			local builder = helpers.load_module("ui.menu.menu_builder")
			local rebuilt = 0
			local ctx = { llm = world.engine, on_menu_changed = function() rebuilt = rebuilt + 1 end }
			local i18n = require("infra.i18n")
			local settings = require("modules.llm.profile_settings")
			local rows = builder.build(ctx)
			helpers.assert_nil(find(rows, i18n.get("menu.llm.live_mode_title")), "the retired second profile chooser stays absent")
			for _, id in ipairs({ "rewrite", "tone_familiar", "tone_neutral", "tone_formal", "tone_very_formal",
				"translate_en", "translate_ja", "basic" }) do
				helpers.assert_not_nil(find(rows, settings.menu_label(settings.resolve_id(id), 3)), "the normal chooser retains " .. id)
			end
			helpers.assert_not_nil(find(rows, "Pirate")); helpers.assert_not_nil(find(rows, "Plain"))
			helpers.assert_eq(world.handlers.llm_live_prompt_toggle("tap_3", "translate_en"), true)
			helpers.assert_eq(world.engine.get_live().profile_id, "translate_en")
			helpers.assert_eq(world.engine.get_live().num_predictions, nil, "the retained shortcut uses the normal count")
			assert_menu_untouched(world)
			helpers.assert_eq(world.handlers.llm_live_prompt_toggle("tap_3", "translate_en"), true)
			helpers.assert_nil(world.engine.get_live(), "the retained action stops its own override")
			helpers.assert_eq(world.handlers.llm_live_prompt_toggle("tap_3", "user_pirate"), true)
			helpers.assert_eq(world.engine.get_live().profile_id, "user_pirate", "custom rewrite prompts still run")
			local use = find(find(builder.build(ctx), "Pirate").menu, i18n.get("menu.profiles.use_profile"))
			helpers.assert_not_nil(use, "the real custom profile command is retained")
			helpers.assert_eq(use.fn(), true, "the exact manual command confirms selection")
			helpers.assert_nil(world.engine.get_live(), "manual selection cannot remain hidden by the shortcut override")
			helpers.assert_eq(rebuilt, 1)
			rows = builder.build(ctx)
			helpers.assert_eq(find(find(rows, "Pirate").menu, i18n.get("menu.profiles.use_profile")).checked, true)
			helpers.assert_nil(find(rows, i18n.get("menu.llm.live_mode_title")))
			assert_menu_untouched(world, "user_pirate")
		end)
	end)

end)





-- =========================================
-- =========================================
-- ======= 6/ The daemon's two seams =======
-- =========================================
-- =========================================

helpers.describe("live mode: the daemon tells the engine", function()

	--- The body of the daemon's `name = function(...)` callback, up to its closing line.
	local function callback_body(source, name)
		local start = source:find("\n(%s*)" .. name .. " = function%(")
		helpers.assert_not_nil(start, "the daemon passes " .. name)
		local indent = source:match("\n(%s*)" .. name .. " = function%(", start)
		local finish = source:find("\n" .. indent .. "end,", start + 1, true)
		helpers.assert_not_nil(finish, name .. " closes")
		return source:sub(start, finish)
	end

	helpers.it("forwards every pause transition and redraws the tray on a live change", function()
		local fh = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
		local source = fh:read("*a")
		fh:close()
		helpers.assert_true(callback_body(source, "on_pause_change"):find("prediction_engine.on_pause_change(paused)",
			1, true) ~= nil, "a pause reaches the engine, which turns live mode off")
		helpers.assert_true(callback_body(source, "on_live_change"):find("rebuild_tray_menu()", 1, true) ~= nil,
			"the tray's live submenu follows the action")
	end)
end)


helpers.describe("manual profile selection retires retained Linux live actions", function()
	local function find_off(menu, label)
		for _, row in ipairs(menu or {}) do
			if row.title == label then return row end
			local found = find_off(row.menu, label)
			if found then return found end
		end
	end

	helpers.it("requires exact stop ACK before profile persistence and never redraws a refused cancellation", function()
		scenario({ stored = {
			["llm.user_profiles"] = require("modules.llm.profile_registry_codec").encode({
				{ id = "user_pirate", label = "Pirate", system_single = "Rewrite. REWRITE: <text>", batch = false },
			}),
		} }, function(world)
			local builder = helpers.load_module("ui.menu.menu_builder")
			local i18n = require("infra.i18n")
			local file = assert(io.open(helpers.driver_root() .. "/../_shared/tests/corpus/menus/llm_live_off.json", "r"))
			local spec = Json.decode(file:read("*a")); file:close()
			local redraws, calls, observed = 0, 0, {}
			local ctx = { llm = world.engine, on_menu_changed = function() redraws = redraws + 1 end }
			helpers.assert_true(world.engine.set_live("translate_en"))
			local before = world.engine.get_live()
			local setter = world.engine.set_live
			local function selected_row()
				local rows = builder.build(ctx)
				helpers.assert_nil(find_off(rows, i18n.get("menu.llm.live_mode_title")))
				local parent = find_off(rows, "Pirate")
				helpers.assert_not_nil(parent)
				return find_off(parent.menu, i18n.get("menu.profiles.use_profile"))
			end
			for _, refusal in ipairs(spec.refusals) do
				world.engine.set_live = function(value)
					helpers.assert_nil(value, "manual selection asks the exact existing owner to stop")
					calls = calls + 1
					if refusal == "throw" then error("owned live refusal") end
					if refusal == "number" then return 2 end
					if refusal == "nil" then return nil end
					return false
				end
				local row = selected_row(); helpers.assert_not_nil(row)
				local invoked, receipt = pcall(row.fn)
				observed[#observed + 1] = { refusal = refusal, invoked = invoked, receipt = receipt, state = world.engine.get_live() }
				assert_menu_untouched(world)
			end
			helpers.assert_eq(redraws, 0, "a truthy non-ACK cannot claim an applied profile change")
			for _, outcome in ipairs(observed) do
				helpers.assert_eq(outcome.invoked, true, "the menu owner reports each owned stop refusal")
				helpers.assert_eq(outcome.receipt, false)
				helpers.assert_eq(outcome.state, before)
			end
			world.engine.set_live = setter
			local row = selected_row(); helpers.assert_eq(row.fn(), true)
			helpers.assert_nil(world.engine.get_live())
			helpers.assert_eq(redraws, 1); helpers.assert_eq(calls, #spec.refusals)
			helpers.assert_eq(selected_row().checked, true)
			assert_menu_untouched(world, "user_pirate")
		end)
	end)

	helpers.it("retains the real shortcut stop notice in all locales while the second chooser stays absent", function()
		scenario({}, function(world)
			local builder = helpers.load_module("ui.menu.menu_builder")
			local i18n = require("infra.i18n")
			local saved_get = i18n.get
			local file = assert(io.open(helpers.driver_root() .. "/../_shared/tests/corpus/menus/llm_live_off.json", "r"))
			local spec = Json.decode(file:read("*a")); file:close()
			local count = 0
			local ok, err = xpcall(function()
				for _, code in ipairs(spec.locales) do
					local locale = assert(io.open(helpers.driver_root() .. "/../_shared/data/locales/" .. code .. ".json", "r"))
					local catalog = Json.decode(locale:read("*a")); locale:close()
					i18n.get = function(key) return catalog[key] or key end
					helpers.assert_true(world.engine.set_live("translate_en"))
					helpers.assert_eq(world.engine.get_live().profile_id, "translate_en")
					helpers.assert_nil(find_off(builder.build({ llm = world.engine }), catalog["menu.llm.live_mode_title"]), code)
					helpers.assert_eq(world.handlers.llm_live_prompt_toggle("tap_3", "translate_en"), true)
					helpers.assert_nil(world.engine.get_live())
					helpers.assert_eq(world.notices[#world.notices], catalog["llm.live.off"], code .. " retains its actual stop notice")
					assert_menu_untouched(world)
					count = count + 1
				end
			end, debug.traceback)
			i18n.get = saved_get
			helpers.assert_true(ok, err); helpers.assert_eq(count, #spec.locales)
		end)
	end)

end)

helpers.it("retains a free-language live receipt through the actual typing timer", function()
	scenario({}, function(world)
		helpers.assert_eq(world.engine.toggle_live("translate|1|Esperanto"), true)
		helpers.assert_eq(#world.posts, 0)
		world.type(SENTENCE)
		world.scheduler.test.advance(live_json().debounce_ms / 1000)
		helpers.assert_eq(#world.posts, 1)
		helpers.assert_true(world.posts[1].body.messages[1].content:find("Translate TAIL into Esperanto", 1, true) ~= nil)
		helpers.assert_eq(world.engine.get_live().translation_target, "Esperanto")
	end)
end)
