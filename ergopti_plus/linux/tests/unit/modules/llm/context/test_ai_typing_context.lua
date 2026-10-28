--- tests/unit/modules/llm/context/test_ai_typing_context.lua

--- ==============================================================================
--- MODULE: AI Typing Context — Unit Tests (Linux)
--- DESCRIPTION:
--- The prediction engine completes its own typing context, apart from the
--- hotstring engine's word buffer, as macOS keeps `llm_buffer` apart from
--- `buffer`. Before it the AI read the word buffer, which the hotstring
--- word-reset options (a pause, an arrow, a click, a shortcut) forget on
--- purpose, and `llm.generation.reset_on_nav` had no meaning on this driver.
---
--- Every case drives the real hotstring engine (and the real word-reset
--- policy) with the real context attached, over a fake preference store:
--- navigation clears the context only while the preference is on and never
--- depends on the hotstring options; Backspace, expansions and accepted
--- predictions keep it equal to the text in the field; everything the engine
--- cannot describe (focus, pause, paste, a failed output, a private
--- expansion) and the AI switched off forget it.
--- ==============================================================================

local helpers = require("tests.helpers")
local PreferencesFixture = require("tests.support.llm_preferences_fixture")

local KEYS = { "infra.llm_preferences", "modules.llm.settings", "modules.llm.context" }

--- Runs one case over a fresh store, settings, context and engine.
--- @param options table { reset_on_nav = boolean|nil, ai_on = boolean|nil, arrow_resets_word = boolean|nil }
--- @param body function Receives { engine, context, word_reset, ai }.
local function scenario(options, body)
	local saved = {}
	for _, name in ipairs(KEYS) do saved[name] = package.loaded[name] end
	local initial = {}
	if options.reset_on_nav ~= nil then initial["llm.generation.reset_on_nav"] = options.reset_on_nav end
	package.loaded["infra.llm_preferences"] = PreferencesFixture.new({ initial = initial })
	package.loaded["modules.llm.settings"] = nil
	package.loaded["modules.llm.context"] = nil
	require("modules.llm.settings")._reset()
	local ok, failure = xpcall(function()
		local ai = { on = options.ai_on ~= false }
		local engine = helpers.load_module("modules.hotstrings.engine").new()
		local context = require("modules.llm.context").new({ is_active = function() return ai.on end })
		engine:attach_ai_context(context)
		assert(engine:load_mappings({
			{ trigger = "btw", replacement = "by the way", auto_expand = true, is_word = false },
		}))
		local word_reset = helpers.load_module("modules.hotstrings.word_reset")
		local settings = word_reset.snapshot()
		settings.idle_seconds = 0
		settings.arrow_resets_word = options.arrow_resets_word ~= false
		assert(word_reset.restore_configuration(settings))
		body({ engine = engine, context = context, word_reset = word_reset, ai = ai })
	end, debug.traceback)
	for _, name in ipairs(KEYS) do package.loaded[name] = saved[name] end
	if not ok then error(failure, 0) end
end

--- Types text through the engine, as the daemon's handle_char does.
local function type_text(s, text)
	for _, code in utf8.codes(text) do s.engine:on_char(utf8.char(code)) end
end

helpers.describe("AI typing context: fed by the typed text", function()
	helpers.it("(ai-context) accumulates what is typed and follows Backspace", function()
		scenario({}, function(s)
			type_text(s, "Bonjour tout")
			helpers.assert_eq(s.context:text(), "Bonjour tout")
			s.engine:backspace()
			helpers.assert_eq(s.context:text(), "Bonjour tou")
			helpers.assert_eq(s.engine:current_buffer(), "Bonjour tou", "the word buffer moves with it")
		end)
	end)

	helpers.it("(ai-context) holds the expansion that replaced the trigger, not the trigger", function()
		scenario({}, function(s)
			type_text(s, "Il dit b")
			s.engine:on_char("t")
			local result = s.engine:on_char("w")
			helpers.assert_not_nil(result, "the control must match the trigger")
			helpers.assert_eq(s.context:text(), "Il dit btw", "before the driver commits the output the field holds the trigger")
			s.engine:apply_expansion(result)
			helpers.assert_eq(s.context:text(), "Il dit by the way")
			s.engine:reset(nil, nil, "keep")
			helpers.assert_eq(s.context:text(), "Il dit by the way", "a final result drops the word buffer, not the AI context")
			helpers.assert_eq(s.engine:current_buffer(), "")
		end)
	end)

	helpers.it("(ai-context) forgets a private expansion whose text is a secret", function()
		scenario({}, function(s)
			type_text(s, "iban ")
			s.context:replaced(0, "FR76 SECRET", true)
			helpers.assert_eq(s.context:text(), "", "a secret never reaches a prompt")
		end)
	end)

	helpers.it("(private-ai-context) a private mapping fired by the engine never reaches the context", function()
		scenario({}, function(s)
			assert(s.engine:load_mappings({
				{ trigger = "28401", replacement = "2840175123456", auto_expand = true, is_word = false, is_private = true },
			}))
			type_text(s, "Mon numero 2840")
			local result = s.engine:on_char("1")
			helpers.assert_not_nil(result, "the control must match the private trigger")
			helpers.assert_eq(result.is_private, true, "the engine flags the result as private")
			s.engine:apply_expansion(result)
			helpers.assert_eq(s.context:text(), "", "neither the secret, nor its trigger, nor the text before it")
			s.engine:reset(nil, nil, "keep")
			type_text(s, " merci")
			helpers.assert_eq(s.context:text(), " merci", "what is typed afterwards is the context")
		end)
	end)

	helpers.it("(ai-context) keeps an accepted prediction in the context", function()
		scenario({}, function(s)
			type_text(s, "Je pense //")
			s.context:replaced(2, "que oui")
			helpers.assert_eq(s.context:text(), "Je pense que oui")
		end)
	end)
end)

helpers.describe("AI typing context: forgets what it cannot describe", function()
	helpers.it("(ai-context) a plain reset (focus change, failed output, paste) forgets it", function()
		scenario({}, function(s)
			type_text(s, "hello")
			s.engine:reset(false)
			helpers.assert_eq(s.context:text(), "")
			type_text(s, "again")
			s.engine:reset()
			helpers.assert_eq(s.context:text(), "")
		end)
	end)

	helpers.it("(ai-context) a pause longer than the idle setting forgets it, as on macOS", function()
		scenario({}, function(s)
			type_text(s, "hello")
			helpers.assert_true(s.engine:reset_after_pause())
			helpers.assert_eq(s.context:text(), "")
		end)
	end)

	helpers.it("(ai-context) a word deletion (Ctrl+Backspace) removes text by an unknown amount", function()
		scenario({ reset_on_nav = false }, function(s)
			type_text(s, "one two")
			s.word_reset.apply_control(s.engine, "backspace", { mods = { ctrl = true } }, "editor")
			helpers.assert_eq(s.context:text(), "", "even with navigation retained, a deletion is no navigation")
		end)
	end)

	helpers.it("(ai-context) switching the AI off forgets it and keeps nothing while it stays off", function()
		scenario({}, function(s)
			type_text(s, "secret words")
			s.ai.on = false
			helpers.assert_eq(s.context:text(), "")
			type_text(s, "typed while off")
			s.ai.on = true
			helpers.assert_eq(s.context:text(), "", "text typed while off never waits for the day it is switched on")
			type_text(s, "x")
			helpers.assert_eq(s.context:text(), "x")
		end)
	end)

	helpers.it("(ai-context) rejects a second context on one engine", function()
		scenario({}, function(s)
			helpers.assert_throws(function() s.engine:attach_ai_context({}) end)
		end)
	end)
end)

helpers.describe("AI typing context: llm.generation.reset_on_nav", function()
	local NAVIGATIONS = {
		{ "left", "left", {} }, { "up", "up", {} }, { "home", "home", {} }, { "enter", "enter", {} },
		{ "escape", "escape", {} }, { "delete", "delete", {} }, { "shortcut", "shortcut", { key = "s", mods = { ctrl = true } } },
	}

	for _, navigation in ipairs(NAVIGATIONS) do
		helpers.it("(ai-context) clears the context on " .. navigation[1] .. " when the preference is on (the default)", function()
			scenario({}, function(s)
				type_text(s, "hello world")
				s.word_reset.apply_control(s.engine, navigation[2], navigation[3], "editor")
				helpers.assert_eq(s.context:text(), "")
			end)
		end)

		helpers.it("(ai-context) keeps the context on " .. navigation[1] .. " when the preference is off, whatever the hotstring buffer does", function()
			scenario({ reset_on_nav = false }, function(s)
				type_text(s, "hello world")
				s.word_reset.apply_control(s.engine, navigation[2], navigation[3], "editor")
				helpers.assert_eq(s.context:text(), "hello world")
				type_text(s, "!")
				helpers.assert_eq(s.context:text(), "hello world!", "typing goes on after the move")
			end)
		end)
	end

	helpers.it("(ai-context) treats a word buffer that an arrow did not reset the same way", function()
		scenario({ arrow_resets_word = false }, function(s)
			type_text(s, "hello")
			s.word_reset.apply_control(s.engine, "left", {}, "editor")
			helpers.assert_eq(s.engine:current_buffer(), "hello", "arrow_resets_word=false keeps the word")
			helpers.assert_eq(s.context:text(), "", "the AI context has its own preference")
		end)
	end)

	helpers.it("(ai-context) keeps the context across the hotstring word reset an arrow causes", function()
		scenario({ reset_on_nav = false }, function(s)
			type_text(s, "hello")
			s.word_reset.apply_control(s.engine, "left", {}, "editor")
			helpers.assert_eq(s.engine:current_buffer(), "", "the hotstring word was forgotten")
			helpers.assert_eq(s.context:text(), "hello", "the AI context was not")
		end)
	end)

	helpers.it("(ai-context) applies the preference to a tap-hold command and to a terminal's submitted line", function()
		scenario({ reset_on_nav = false }, function(s)
			type_text(s, "hello")
			helpers.assert_eq(s.word_reset.apply_tap_action(s.engine, "tap_hold__caps_lock"), "word_start")
			helpers.assert_eq(s.context:text(), "hello")
		end)
		scenario({}, function(s)
			type_text(s, "hello")
			s.word_reset.apply_tap_action(s.engine, "tap_hold__caps_lock")
			helpers.assert_eq(s.context:text(), "")
		end)
		scenario({}, function(s)
			type_text(s, "ls")
			helpers.assert_true(s.word_reset.apply_typed_newline(s.engine, "\n", "org.gnome.Terminal"))
			helpers.assert_eq(s.context:text(), "")
		end)
	end)

	helpers.it("(ai-context) reads the preference live, so the menu takes effect at the next move", function()
		scenario({ reset_on_nav = false }, function(s)
			local settings = require("modules.llm.settings")
			type_text(s, "hello")
			s.engine:navigated()
			helpers.assert_eq(s.context:text(), "hello")
			helpers.assert_true(settings.set("reset_on_nav", true))
			s.engine:navigated()
			helpers.assert_eq(s.context:text(), "")
		end)
	end)
end)

helpers.describe("AI typing context: the generation setting", function()
	helpers.it("(ai-context) ships on, like the other drivers, from the one manifest declaration", function()
		scenario({}, function()
			local settings = require("modules.llm.settings")
			local manifest = helpers.load_module("infra.manifest_reader")
			helpers.assert_eq(settings.get("reset_on_nav"), true)
			helpers.assert_eq(settings.get("reset_on_nav"), manifest.default_for("llm.generation.reset_on_nav"))
		end)
	end)

	helpers.it("(ai-context) stores only a change and refuses a non-boolean", function()
		scenario({}, function()
			local settings = require("modules.llm.settings")
			helpers.assert_eq(settings.set("reset_on_nav", "yes"), false)
			helpers.assert_true(settings.set("reset_on_nav", false))
			helpers.assert_eq(package.loaded["infra.llm_preferences"].get("llm.generation.reset_on_nav"), false)
			helpers.assert_true(settings.set("reset_on_nav", true))
			helpers.assert_nil(package.loaded["infra.llm_preferences"].get("llm.generation.reset_on_nav"),
				"back to the default means no entry")
		end)
	end)
end)
