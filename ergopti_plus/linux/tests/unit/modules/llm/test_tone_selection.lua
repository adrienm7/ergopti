--- tests/unit/modules/llm/test_tone_selection.lua

--- ==============================================================================
--- MODULE: Tone Ladder Actions On The Selection (Linux)
--- DESCRIPTION:
--- llm_tone_more_formal / llm_tone_more_familiar and their _cycle variants
--- rewrite the selection one register along the tone ladder, replace it at once
--- and leave the rewrite selected, so the next step applies to it. Each step
--- rewrites the ORIGINAL text.
---
--- The real engine, profile registry, prompt builder, remote client, tone
--- ladder and injector run; only the boundaries are scripted: the HTTP
--- transport, the preferences file, the clock, the selection read (a clipboard
--- probe in the daemon), the focused-window probe and the uinput channel.
---
--- ROOT CAUSE ENCODED:
--- Changing the register of a text meant a prompt action on the typing buffer,
--- a suggestion to accept and a retyped sentence; a selection could not be
--- rewritten in place, and a second step would have rewritten the first
--- rewrite and drifted from what the user wrote.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = require("tests.fakes")
local Json = require("json")
local EvdevCodes = require("infra.evdev_codes")

-- The Left arrow's kernel code (input-event-codes.h KEY_LEFT)
local KEY_LEFT = 105
local PreferencesFixture = require("tests.support.llm_preferences_fixture")
local Rewrite = require("llm.rewrite")

local ENTRY = { id = "cerebras-1", provider = "cerebras", label = "Cerebras", token = "k", model = "", base_url = "" }

-- Every character a scenario types, each given its own key on a fake layout
local TYPED_CHARS = "Merci pour votre aide.Je vous remercie vivement pour votre aide.Merci pour ton aide !Bonjour"
-- Codes a typed character must not take: the modifiers and the Left arrow
local RESERVED_CODES = { [42] = true, [54] = true, [29] = true, [97] = true, [56] = true, [100] = true,
	[125] = true, [126] = true, [58] = true, [105] = true, [194] = true }

local RELOADED = {
	"modules.llm.prediction_engine", "modules.llm.settings", "modules.llm.profile_settings",
	"modules.llm.display_settings", "modules.llm.trigger_settings", "modules.llm.navigation_settings",
	"modules.llm.api_remote", "modules.hotstrings.injector", "adapters.keyboard_layout", "adapters.xkb_capture",
}
local FAKED = {
	"adapters.secure_field_detector", "adapters.http_client", "modules.llm.api_entries",
	"modules.llm.profiles", "modules.llm.api_ollama",
}

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

--- A layout that types every character of TYPED_CHARS: lowercase and
--- punctuation on level 1, uppercase with Shift.
--- @return table layout { [char] = { keycode, level, mods } }
--- @return table char_of { [keycode] = char } for the unshifted and shifted key.
local function build_layout()
	local layout, char_of, next_code = {}, {}, 16
	for char in TYPED_CHARS:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		if not layout[char] then
			while RESERVED_CODES[next_code] do next_code = next_code + 1 end
			local upper = char:match("^%u$") ~= nil
			layout[char] = { keycode = next_code, level = upper and 2 or 1, mods = upper and { "shift" } or {} }
			char_of[next_code] = char
			next_code = next_code + 1
		end
	end
	return layout, char_of
end

--- Runs body against the real engine and injector with scripted boundaries.
--- @param opts table { selection?, stored?, disabled?, paused? }
--- @param body function Receives the scenario's world.
local function scenario(opts, body)
	local stored = {}
	for key, value in pairs(BASE_PREFERENCES) do stored[key] = value end
	for key, value in pairs(opts.stored or {}) do stored[key] = value end
	PreferencesFixture.with(function(preferences)
		local previous = {}
		for _, name in ipairs(RELOADED) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
		for _, name in ipairs(FAKED) do previous[name] = package.loaded[name] end
		local world = { posts = {}, ollama = {}, notices = {}, reads = 0, focus = "editor\1Draft",
			selection = opts.selection, preferences = preferences, emitted = {} }
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

		-- The injector types on a recording uinput channel over a fake layout
		require("adapters.xkb_capture").caps_locked = function() return false end
		local layout, char_of = build_layout()
		require("adapters.keyboard_layout")._set_table_for_test(layout)
		local channel = {
			is_open = function() return true end,
			emit = function(code, value)
				world.emitted[#world.emitted + 1] = { code = code, value = value }
				return true
			end,
			sync = function() return true end,
		}
		local injector = require("modules.hotstrings.injector")
		injector._set_uinput(channel)
		injector._set_nanosleep_for_test(function() end)
		world.char_of = char_of

		local scheduler = Fakes.timer_scheduler()
		local engine = require("modules.llm.prediction_engine")
		engine.init({
			scheduler = scheduler,
			clock_ms = function() return scheduler.now * 1000 end,
			engine = { current_buffer = function() return "" end, reset = function() end },
			is_paused = function() return opts.paused == true end,
			notify = function(text) world.notices[#world.notices + 1] = text; return true end,
			-- The daemon's seams: a copy probe, the injector, the window probe
			read_selection = function()
				world.reads = world.reads + 1
				if world.selection == nil then return false, "", "no_selection" end
				return true, world.selection, nil
			end,
			replace_selection = function(text)
				local result = injector.inject_selected(text, false)
				if type(result) ~= "table" or result.ok ~= true then return false end
				-- The application now shows the rewrite, selected
				world.selection = text
				return true
			end,
			focus_id = function() return world.focus end,
		})
		world.engine = engine
		world.handlers = engine.action_handlers()

		--- The remote server answers request `index` with `text`.
		function world.respond(index, text)
			local post = assert(world.posts[index], "no request " .. index .. " was sent")
			post.callback({ ok = true, status = 200,
				body = Json.encode({ choices = { { message = { role = "assistant", content = text } } } }) })
		end

		--- Lets the pacing timer run until request `index` is sent, to either
		--- backend, or long past it.
		function world.wait_for(index)
			for _ = 1, 20 do
				if world.posts[index] or world.ollama[index] then return end
				scheduler.test.advance(0.5)
			end
		end

		local ok, err = pcall(body, world)
		engine.dismiss()
		injector._set_uinput(nil)
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

--- The system turn a request carried.
--- @param post table
--- @return string
local function system_turn(post)
	return post.body.messages[1].content
end

--- The first line of a built-in's prompt, which the resolved system turn keeps.
--- @param id string
--- @return string
local function prompt_head(id)
	local profile = assert(require("modules.llm.profile_settings").resolve_id(id), id .. " is a built-in")
	return profile.system_single:sub(1, 120)
end

--- Reads back what the injector typed and what it pressed after the text.
--- @param world table
--- @return string typed The text the key presses spell.
--- @return table after The events after the last typed character, as "code:value".
local function read_output(world)
	local typed, last_char = {}, 0
	for index, event in ipairs(world.emitted) do
		local char = world.char_of[event.code]
		if char then
			if event.value == 1 then typed[#typed + 1] = char end
			last_char = index
		end
	end
	local after = {}
	for index = last_char + 1, #world.emitted do
		local event = world.emitted[index]
		after[#after + 1] = event.code .. ":" .. event.value
	end
	return table.concat(typed), after
end

--- The events that select `steps` characters back from the caret.
--- @param steps integer
--- @return table sequence As "code:value".
local function selection_keys(steps)
	local sequence = { EvdevCodes.KEY_LEFTSHIFT .. ":1" }
	for _ = 1, steps do
		sequence[#sequence + 1] = KEY_LEFT .. ":1"
		sequence[#sequence + 1] = KEY_LEFT .. ":0"
	end
	sequence[#sequence + 1] = EvdevCodes.KEY_LEFTSHIFT .. ":0"
	return sequence
end

--- Asserts the selection was replaced by `text` and `text` selected back.
--- @param world table
--- @param text string ASCII text, one caret step per byte.
local function assert_replaced(world, text)
	local typed, after = read_output(world)
	helpers.assert_eq(typed, text, "the selection is typed over with the rewrite, exactly")
	helpers.assert_eq(table.concat(after, " "), table.concat(selection_keys(#text), " "),
		"then Shift+Left once per character selects exactly the inserted text")
end





-- ==============================================
-- ==============================================
-- ======= 2/ The ladder, end to end ============
-- ==============================================
-- ==============================================

helpers.describe("tone actions: the selection moves along the ladder", function()

	helpers.it("registers the four actions and a preset per tone prompt", function()
		scenario({}, function(world)
			for _, id in ipairs({ "llm_tone_more_formal", "llm_tone_more_familiar",
				"llm_tone_more_formal_cycle", "llm_tone_more_familiar_cycle",
				"llm_predict_tone_familiar", "llm_predict_tone_neutral",
				"llm_predict_tone_formal", "llm_predict_tone_very_formal" }) do
				helpers.assert_eq(type(world.handlers[id]), "function", id .. " has a handler")
			end
		end)
	end)

	helpers.it("rewrites the selection, keeps it selected, and steps from the original", function()
		scenario({ selection = "merci pour ton aide" }, function(world)
			helpers.assert_eq(world.handlers.llm_tone_more_formal("gesture_swipe_right", nil), true,
				"the step starts a request")
			helpers.assert_eq(#world.posts, 1, "one request")
			local post = world.posts[1]
			helpers.assert_eq(system_turn(post):sub(1, 120), prompt_head("tone_formal"),
				"neutral + more formal = the formal prompt")
			helpers.assert_eq(user_turn(post), 'PREFIX: "merci pour ton aide"\nTAIL: "merci pour ton aide"',
				"the selection is both PREFIX and TAIL")
			helpers.assert_eq(post.body.max_tokens, Rewrite.max_tokens("merci pour ton aide"))
			helpers.assert_eq(post.body.stream, false, "no streaming")
			helpers.assert_eq(#world.emitted, 0, "nothing is typed before the answer")

			world.respond(1, "REWRITE: Merci pour votre aide.")
			assert_replaced(world, "Merci pour votre aide.")
			helpers.assert_eq(#world.notices, 0, "no notice, no tooltip")

			-- Second step, on the re-selected rewrite: the ORIGINAL is rewritten
			world.emitted = {}
			helpers.assert_eq(world.handlers.llm_tone_more_formal("gesture_swipe_right", nil), true)
			world.wait_for(2)
			helpers.assert_eq(#world.posts, 2, "a second request")
			helpers.assert_eq(system_turn(world.posts[2]):sub(1, 120), prompt_head("tone_very_formal"))
			helpers.assert_eq(user_turn(world.posts[2]),
				'PREFIX: "merci pour ton aide"\nTAIL: "merci pour ton aide"',
				"the original text, not the previous rewrite")
			world.respond(2, "REWRITE: Je vous remercie vivement pour votre aide.")
			assert_replaced(world, "Je vous remercie vivement pour votre aide.")

			-- Third step without cycling: the end of the ladder
			world.emitted = {}
			helpers.assert_eq(world.handlers.llm_tone_more_formal("gesture_swipe_right", nil), false)
			world.wait_for(3)
			helpers.assert_eq(#world.posts, 2, "no request past the most formal register")
			helpers.assert_eq(world.notices[1], require("infra.i18n").get("llm.tone.most_formal"))
			helpers.assert_eq(#world.emitted, 0)

			-- With cycling: wraps around to the most familiar register
			helpers.assert_eq(world.handlers.llm_tone_more_formal_cycle("gesture_swipe_right", nil), true)
			world.wait_for(3)
			helpers.assert_eq(#world.posts, 3)
			helpers.assert_eq(system_turn(world.posts[3]):sub(1, 120), prompt_head("tone_familiar"))
			helpers.assert_eq(user_turn(world.posts[3]),
				'PREFIX: "merci pour ton aide"\nTAIL: "merci pour ton aide"')
			world.respond(3, "REWRITE: Merci pour ton aide !")
			assert_replaced(world, "Merci pour ton aide !")
		end)
	end)

	helpers.it("more familiar stops at the bottom with its own notice", function()
		scenario({ selection = "Bonjour" }, function(world)
			helpers.assert_eq(world.handlers.llm_tone_more_familiar("tap_3", nil), true)
			helpers.assert_eq(system_turn(world.posts[1]):sub(1, 120), prompt_head("tone_familiar"))
			world.respond(1, "REWRITE: Bonjour")
			helpers.assert_eq(world.handlers.llm_tone_more_familiar("tap_3", nil), false)
			helpers.assert_eq(world.notices[1], require("infra.i18n").get("llm.tone.most_familiar"))
			helpers.assert_eq(world.handlers.llm_tone_more_familiar_cycle("tap_3", nil), true)
			world.wait_for(2)
			helpers.assert_eq(system_turn(world.posts[2]):sub(1, 120), prompt_head("tone_very_formal"),
				"cycling wraps to the most formal register")
		end)
	end)

	helpers.it("works through Ollama with one unstreamed request", function()
		scenario({ selection = "merci pour ton aide", stored = { ["llm.models.selected"] = "ollama" } }, function(world)
			helpers.assert_eq(world.handlers.llm_tone_more_formal("tap_3", nil), true)
			helpers.assert_eq(#world.ollama, 1)
			local request = world.ollama[1]
			helpers.assert_eq(request.opts.stream, false)
			helpers.assert_eq(request.opts.max_tokens, Rewrite.max_tokens("merci pour ton aide"))
			helpers.assert_eq(request.messages[#request.messages].content,
				'PREFIX: "merci pour ton aide"\nTAIL: "merci pour ton aide"')
			request.on_done("<think>register</think>REWRITE: **Merci pour votre aide.**", nil)
			assert_replaced(world, "Merci pour votre aide.")
		end)
	end)
end)





-- ==============================================
-- ==============================================
-- ======= 3/ When nothing must be typed ========
-- ==============================================
-- ==============================================

helpers.describe("tone actions: refusals and dropped answers", function()

	helpers.it("does nothing when nothing is selected", function()
		scenario({ selection = nil }, function(world)
			helpers.assert_eq(world.handlers.llm_tone_more_formal("tap_3", nil), false)
			helpers.assert_eq(world.reads, 1, "the selection was probed")
			helpers.assert_eq(#world.posts, 0, "no request")
			helpers.assert_eq(#world.notices, 0, "and no notice")
		end)
	end)

	helpers.it("does nothing for a blank selection", function()
		scenario({ selection = "  \n " }, function(world)
			helpers.assert_eq(world.handlers.llm_tone_more_familiar("tap_3", nil), false)
			helpers.assert_eq(#world.posts, 0)
			helpers.assert_eq(#world.notices, 0)
		end)
	end)

	helpers.it("refuses like the manual prediction while the AI is off, without probing", function()
		scenario({ selection = "merci", disabled = true }, function(world)
			helpers.assert_eq(world.handlers.llm_tone_more_formal("tap_3", nil), false)
			helpers.assert_eq(world.notices[1], require("infra.i18n").get("llm.manual_prediction.disabled"))
			helpers.assert_eq(world.reads, 0, "no copy chord is sent")
			helpers.assert_eq(#world.posts, 0)
		end)
	end)

	helpers.it("refuses while paused", function()
		scenario({ selection = "merci", paused = true }, function(world)
			helpers.assert_eq(world.handlers.llm_tone_more_formal_cycle("tap_3", nil), false)
			helpers.assert_eq(world.notices[1], require("infra.i18n").get("llm.manual_prediction.paused"))
			helpers.assert_eq(#world.posts, 0)
		end)
	end)

	helpers.it("drops the answer when the focus moved to another window", function()
		scenario({ selection = "merci pour ton aide" }, function(world)
			helpers.assert_eq(world.handlers.llm_tone_more_formal("tap_3", nil), true)
			world.focus = "terminal\1bash"
			world.respond(1, "REWRITE: Merci pour votre aide.")
			helpers.assert_eq(#world.emitted, 0, "nothing is typed into the other window")
			-- Nothing was remembered: the same selection starts from neutral again
			world.focus = "editor\1Draft"
			helpers.assert_eq(world.handlers.llm_tone_more_formal("tap_3", nil), true)
			world.wait_for(2)
			helpers.assert_eq(system_turn(world.posts[2]):sub(1, 120), prompt_head("tone_formal"))
		end)
	end)

	helpers.it("ignores a superseded answer and applies the newer one", function()
		scenario({ selection = "merci pour ton aide", stored = { ["llm.models.selected"] = "ollama" } }, function(world)
			helpers.assert_eq(world.handlers.llm_tone_more_formal("tap_3", nil), true)
			helpers.assert_eq(world.handlers.llm_tone_more_familiar("tap_3", nil), true)
			world.wait_for(2)
			helpers.assert_eq(#world.ollama, 2, "the second step is sent")
			world.ollama[1].on_done("REWRITE: Merci pour votre aide.", nil)
			helpers.assert_eq(#world.emitted, 0, "the stale answer is ignored")
			world.ollama[2].on_done("REWRITE: Merci pour ton aide !", nil)
			assert_replaced(world, "Merci pour ton aide !")
		end)
	end)

	helpers.it("drops the answer when the user typed while it ran", function()
		scenario({ selection = "merci pour ton aide" }, function(world)
			helpers.assert_eq(world.handlers.llm_tone_more_formal("tap_3", nil), true)
			world.engine.on_char("x", "x", {})
			world.respond(1, "REWRITE: Merci pour votre aide.")
			helpers.assert_eq(#world.emitted, 0, "the typed character replaced the selection")
		end)
	end)

	helpers.it("types nothing when the answer holds no rewrite", function()
		scenario({ selection = "merci pour ton aide" }, function(world)
			helpers.assert_eq(world.handlers.llm_tone_more_formal("tap_3", nil), true)
			world.respond(1, "Sure! Here is a more formal version.")
			helpers.assert_eq(#world.emitted, 0)
		end)
	end)
end)





-- ==============================================
-- ==============================================
-- ======= 4/ Caret steps =======================
-- ==============================================
-- ==============================================

helpers.describe("injector: one Left arrow per user-perceived character", function()

	helpers.it("counts a character, not a byte or a code point", function()
		local Injector = require("modules.hotstrings.injector")
		local cases = {
			{ "Merci", 5 },
			{ "\195\169t\195\169", 3 },                                   -- "été", precomposed
			{ "e\204\129t\195\169", 3 },                                  -- e + U+0301 combining acute
			{ "ok \240\159\152\128", 4 },                                 -- 😀 is one step
			{ "\240\159\145\141\240\159\143\189", 1 },                    -- 👍 + skin tone
			{ "\240\159\145\168\226\128\141\240\159\145\169\226\128\141\240\159\145\167", 1 }, -- ZWJ family
			{ "\240\159\135\171\240\159\135\183\240\159\135\169\240\159\135\170", 2 },         -- 🇫🇷🇩🇪
			{ "\226\157\164\239\184\143", 1 },                            -- ❤️ with VS16
			{ "a\r\nb", 3 },
			{ "", 0 },
		}
		for _, case in ipairs(cases) do
			helpers.assert_eq(Injector.caret_steps(case[1]), case[2], "steps for " .. case[1])
		end
	end)
end)
