--- tests/unit/ai/engine/features/test_selected_write_partial.lua

--- ==============================================================================
--- MODULE: Partial Selected Rewrite Consumers
--- DESCRIPTION:
--- Runs actual Engine and Main through the real selected-write owner. A partial
--- payload cannot learn, retry or reuse its consumed read receipt.
--- ==============================================================================
local helpers = require("tests.helpers")
local Fixture = require("tests.support.adapters.synthetic_input.selection_write_fixture")
local Preferences = require("tests.support.llm_preferences_fixture")
local Fakes = require("tests.fakes")

local function scenario(mode, body)
	Preferences.with(function()
		Fixture.with(function(state, owner)
			local names = { "ai.engine.prediction.engine", "ai.engine.settings.settings", "ai.engine.settings.profile_settings",
				"ai.engine.settings.display_settings", "ai.engine.settings.trigger_settings", "ai.engine.settings.navigation_settings",
				"ai.engine.settings.api_entries", "ai.engine.settings.profiles", "ai.engine.api.api_remote" }
			local previous, callback, requests, output, remembered, reset = {}, nil, 0, 0, 0, 0
			for _, name in ipairs(names) do previous[name] = package.loaded[name] end
			for index = 1, 6 do package.loaded[names[index]] = nil end
			package.loaded["ai.engine.settings.profiles"] = { init = function() end, is_enabled = function() return true end }
			package.loaded["ai.engine.settings.api_entries"] = { active = function() return { id = "original", provider = "openai_compat", model = "fixture" } end }
			package.loaded["ai.engine.api.api_remote"] = {
				provider = function() return { default_model = "fixture" } end, serves = function() return true end,
				chat = function(_, _, _, _, _, done) requests = requests + 1; callback = done; return true end,
				cancel = function() return true end,
			}
			local Tone = require("ai.engine.prediction.tone")
			local remember = Tone.remember
			Tone.remember = function(...) remembered = remembered + 1; return remember(...) end
			local engine, scheduler = require("ai.engine.prediction.engine"), Fakes.timer_scheduler()
			local ok, detail = pcall(function()
				local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
				local source = file:read("*a"); file:close()
				local prefix = "replace_selection = function(text, receipt, authorized, callback)"
				local first = assert(source:find(prefix, 1, true))
				local last = assert(source:find("\n\t\t\tend,", first, true))
				local callback_source = source:sub(first + #"replace_selection = ", last + #"\n\t\t\tend" - 1)
				local compile = loadstring or load
				local factory = assert(compile("return function(injector,privacy_owners,opts,engine) local _undoable; return " .. callback_source .. " end"))()
				local replace = factory(state.injector, { selection = owner }, { dry_run = false }, { reset = function() reset = reset + 1 end })
				engine.init({ scheduler = scheduler, clock_ms = function() return scheduler.now * 1000 end,
					focus_id = state.guard.focused_text_identity, privacy_guard = state.guard.blocks_text,
					read_selection = owner.read, cancel_selection = owner.cancel, replace_selection = replace,
					on_output = function() output = output + 1 end })
				local started = mode == "translation" and engine.translate_selection("en")
					or mode == "tone" and engine.shift_tone(Tone.MORE_FORMAL, false)
				helpers.assert_true(started)
				state.deliver()
				for _ = 1, 10 do if callback then break end; scheduler.test.advance(.5) end
				helpers.assert_eq(requests, 1)
				state.inserted = { first = 0, last = 1, text = "☃" }
				state.on_boundary = function(at) if at == "reselect" then state.inserted = nil end end
				callback((mode == "translation" and "TRANSLATION: " or "REWRITE: ") .. "☃", nil)
				body(state, owner, engine, function() return requests, output, remembered, reset end)
			end)
			engine.shutdown_runtime()
			Tone.remember = remember
			for _, name in ipairs(names) do package.loaded[name] = previous[name] end
			if not ok then error(detail, 0) end
		end)
	end, { initial = { ["llm.models.selected"] = "api", ["llm.profiles.auto_profile_for_model"] = false,
		["llm.trigger.secure_filter_enabled"] = true, ["llm.trigger.url_bar_filter_enabled"] = false } })
end

helpers.describe("partial selected output cannot publish learning", function()
	helpers.it("does not replay a partially written translation on a second manual acceptance", function()
		scenario("translation", function(state, owner, engine, counts)
			local completed
			helpers.assert_true(engine.accept(1, function(value) completed = value end))
			state.deliver(); state.deliver()
			helpers.assert_eq(completed, false)
			helpers.assert_true(owner.is_settled())
			local starts, wire = state.starts, #state.wire
			helpers.assert_eq(engine.accept(1), false)
			helpers.assert_eq(state.starts, starts)
			helpers.assert_eq(#state.wire, wire)
			helpers.assert_eq({ counts() }, { 1, 0, 0, 1 })
			helpers.assert_eq(state.clipboard, "SAVED")
		end)
	end)
	helpers.it("does not remember or announce a tone payload whose final caret was refused", function()
		scenario("tone", function(state, owner, _, counts)
			state.deliver(); state.deliver()
			helpers.assert_true(owner.is_settled())
			helpers.assert_eq({ counts() }, { 1, 0, 0, 1 })
			helpers.assert_eq(state.clipboard, "SAVED")
			for _, event in ipairs(state.wire) do helpers.assert_eq(event == "105:1", false) end
		end)
	end)
end)
