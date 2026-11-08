--- tests/unit/modules/hotstrings/injector/test_repeat_main_commit.lua

--- ==============================================================================
--- MODULE: Magic-Key Repeat Through Main's Commit
--- DESCRIPTION:
--- URL-001 / URL-002. Executes Main's actual character callback with the real
--- Linux engine and RepeatKey owner, and a recording injector. The pure repeat
--- resolver was already covered; what these cases pin is the commit that follows
--- an acknowledged repeat: the repeated word and its boundary stay in the
--- matcher, and a character repeated out of a private expansion stays private.
--- ==============================================================================
local helpers = require("tests.helpers")
local Fixture = require("tests.support.text_owner_fixture")

local STAR = "★"

--- Extracts Main's actual character callback.
--- @param environment table Controlled callback dependencies.
--- @return function character
local function main_character(environment)
	local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
	local source = file:read("*a"); assert(file:close())
	local first = assert(source:find("\tlocal function handle_char(", 1, true))
	local last = assert(source:find("\n\ton_char = input_capture_gate.guard(handle_char)", first, true))
	local body = "local _undoable; local on_char; " .. source:sub(first, last - 1)
		.. "\non_char=handle_char; return handle_char"
	local chunk
	if loadstring then chunk = assert(loadstring(body)); setfenv(chunk, environment)
	else chunk = assert(load(body, "actual Main repeat commit", "t", environment)) end
	return chunk()
end

--- Types text through Main and records what the injector and telemetry saw.
--- @param mappings table Mappings loaded into the real engine.
--- @param body function Receives type(text), the observations and the engine.
--- @param overrides table|nil Environment entries replacing the defaults.
local function with_main(mappings, body, overrides)
	Fixture.with(function(guard, state)
		local observations = { injected = {}, recorded = {} }
		local RepeatKey = helpers.load_module("modules.hotstrings.repeat_key")
		local engine = helpers.load_module("modules.hotstrings.engine").new()
		engine:load_mappings(mappings)
		local environment = setmetatable({
			secure_focus_guard = guard,
			script_actions = { is_paused = function() return false end },
			keyboard_hook = { held_modifiers = function() return {} end },
			Monotonic = { now_ms = function() state.now = state.now + 10; return state.now end },
			_cached_app_id = "owned-editor",
			WordReset = { observe_key = function() return false end,
				apply_typed_newline = function() return false end, cascade_max_arrows = function() return 0 end },
			terminators_mod = { is_terminator = function() return false end,
				terminator_is_consumed = function() return false end },
			MagicKey = { get = function() return STAR end },
			RepeatKey = { is_enabled = function() return true end, resolve = RepeatKey.resolve },
			opts = { dry_run = false },
			keystats = { is_password_app = function() return false end,
				is_unrecorded_app = function() return false end, suppress = function() end,
				unsuppress = function() end, on_keydown = function() end, record_roi_text = function() end,
					discard_roi = function() end, record_roi_key = function() end,
				record_correction = function() end,
				record_hotstring = function(_, trigger, replacement, _, _, _, private)
					observations.recorded[#observations.recorded + 1] = { replacement = replacement, private = private }
				end },
			injector = { _is_injecting = function() return false end, _begin_injection = function() end, _end_injection = function() return {} end,
				inject = function(backspaces, text, private)
					observations.injected[#observations.injected + 1] = { backspaces = backspaces, text = text, private = private }
					return { ok = true, cleanup_ok = true }
				end },
			engine = engine, Logger = require("logger.shim"),
		}, { __index = _G })
		for name, value in pairs(overrides or {}) do environment[name] = value end
		local character = main_character(environment)
		local function type_text(text)
			for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do character(ch, 30) end
		end
		body(type_text, observations, engine)
	end)
end

helpers.describe("Linux Main: the commit after an acknowledged repeat", function()
	helpers.it("keeps the repeated word, so a second repeat still fires (URL-001)", function()
		with_main({}, function(type_text, observations, engine)
			type_text("po" .. STAR)
			helpers.assert_eq(#observations.injected, 1, "the first repeat fires")
			helpers.assert_eq(engine:current_buffer(), "poo", "the matcher keeps the repeated word")
			type_text(STAR)
			helpers.assert_eq(#observations.injected, 2, "a second repeat needs the retained word")
			helpers.assert_eq(engine:current_buffer(), "pooo")
		end)
	end)

	helpers.it("does not invent a word start for a word-only mapping (URL-001)", function()
		local mappings = { { trigger = "x", replacement = "z", auto_expand = true, is_word = true } }
		with_main(mappings, function(type_text, observations)
			type_text("po" .. STAR .. "x")
			helpers.assert_eq(#observations.injected, 1,
				"x inside the retained word must not fire a word-start mapping")
		end)
	end)

	helpers.it("a character repeated from a private expansion stays private (URL-002)", function()
		local mappings = { { trigger = "12345", replacement = "9876543", auto_expand = true,
			is_word = false, is_private = true } }
		with_main(mappings, function(type_text, observations)
			type_text("12345")
			helpers.assert_eq(observations.injected[1].private, true, "positive control: the expansion is private")
			type_text(STAR)
			local repeat_call = observations.injected[2]
			helpers.assert_eq(repeat_call.text, "3", "the repeat repeats the last private character")
			helpers.assert_eq(repeat_call.private, true, "the injector must receive the private classification")
			helpers.assert_eq(observations.recorded[2].private, true, "so must telemetry")
		end)
	end)

	helpers.it("a repeat of public text after a private expansion stays public", function()
		local mappings = { { trigger = "12345", replacement = "9876543", auto_expand = true,
			is_word = false, is_private = true } }
		with_main(mappings, function(type_text, observations)
			type_text("12345 ab" .. STAR)
			local repeat_call = observations.injected[#observations.injected]
			helpers.assert_eq(repeat_call.text, "b")
			helpers.assert_eq(repeat_call.private, false)
		end)
	end)
end)

-- The repeat answers the magic key within the magic category's window, as on
-- macOS (decision of 2026-11-06); before it, Linux repeated after any pause.
helpers.describe("Linux Main: the repeat activation window (repeat-window)", function()
	local function timed(delay_sec, gaps)
		local clock, step = 1000, 1
		return {
			Monotonic = {
				now_ms = function()
					clock = clock + (gaps[step] or 10)
					step = step + 1
					return clock
				end,
				resolution_ms = function() return 0 end,
			},
			hotstrings_config = { resolve = function(category)
				helpers.assert_eq(category, "magickey", "the window is the magic key category's delay")
				return { delay = delay_sec }
			end },
			ExpansionDelay = require("modules.hotstrings.expansion_delay"),
			RepeatKey = { is_enabled = function() return true end,
				resolve = helpers.load_module("modules.hotstrings.repeat_key").resolve,
				WINDOW_CATEGORY = "magickey" },
		}
	end

	helpers.it("refuses a magic key typed after the window (repeat-window)", function()
		with_main({}, function(type_text, observations)
			type_text("po" .. STAR)
			helpers.assert_eq(#observations.injected, 0, "3 s after the letter, 2 s allowed: no repeat")
		end, timed(2, { 10, 10, 3000 }))
	end)

	helpers.it("repeats within the window, and always at 0 (repeat-window)", function()
		with_main({}, function(type_text, observations)
			type_text("po" .. STAR)
			helpers.assert_eq(#observations.injected, 1, "control: 1 s after the letter, 2 s allowed")
		end, timed(2, { 10, 10, 1000 }))
		with_main({}, function(type_text, observations)
			type_text("po" .. STAR)
			helpers.assert_eq(#observations.injected, 1, "a 0 window always repeats")
		end, timed(0, { 10, 10, 60000 }))
	end)
end)
