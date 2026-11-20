--- tests/unit/hotstrings/engine/injector/test_backspace_restore.lua

--- ==============================================================================
--- MODULE: Backspace Restore Through Main's Undo
--- DESCRIPTION:
--- Executes Main's actual character and control callbacks against a modelled
--- text field: the expansion commits through the scripted injector, the
--- application deletes one character for the re-emitted Backspace, then Main's
--- undo erases and types what the shared rule
--- (_shared/hotstrings/engine/backspace_restore.lua) gives back. The settings are
--- the real word-reset owner's, so the option and the window reach the undo
--- exactly as the menu writes them.
---
--- Before these cases the undo typed the trigger as stored in the record: « td★ »
--- came back with its magic key, « adn » and Space came back without the Space,
--- and a Backspace undid an expansion whatever the time elapsed or the option.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.text_owner_fixture")

local STAR = "★"

--- Extracts the actual two callbacks without reproducing their undo protocol.
--- @param environment table Controlled callback dependencies.
--- @return function character
--- @return function control
--- @return function undo Current undo record.
local function main_callbacks(environment)
	local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
	local source = file:read("*a"); assert(file:close())
	local first = assert(source:find("\tlocal function handle_char(", 1, true))
	local last = assert(source:find("\n\ton_char = input_capture_gate.guard(handle_char)", first, true))
	local body = "local _undoable; local on_char; " .. source:sub(first, last - 1)
	first = assert(source:find("\tlocal function handle_control(", 1, true))
	last = assert(source:find("\n\tlocal on_control = input_capture_gate.guard(handle_control)", first, true))
	body = body .. source:sub(first, last - 1)
		.. "\non_char=handle_char; return handle_char,handle_control,function() return _undoable end"
	local chunk
	if loadstring then chunk = assert(loadstring(body)); setfenv(chunk, environment)
	else chunk = assert(load(body, "actual Main backspace restore callbacks", "t", environment)) end
	return chunk()
end

--- The text without its last code point (the corpus holds no cluster).
--- @param text string
--- @return string
local function without_last(text)
	local offset = utf8.offset(text, -1)
	if not offset then return "" end
	return text:sub(1, offset - 1)
end

--- Removes `count` code points from the end of the text.
--- @param text string
--- @param count number
--- @return string
local function erase(text, count)
	for _ = 1, count do text = without_last(text) end
	return text
end

--- Runs one expansion then one Backspace through Main.
--- @param case table `{ trigger, output, terminator, terminator_consumed,
---   magic_key, enabled, window_ms, elapsed_ms, key_between }`, the corpus shape.
--- @return table observations `{ screen, resets, injected, undo }`.
local function run_case(case)
	local observations
	Fixture.with(function(guard)
		local WordReset = require("hotstrings.engine.word_reset")
		local saved = WordReset.snapshot()
		local ok, failure = pcall(function()
			local settings = WordReset.snapshot()
			settings.idle_seconds = 0
			settings.backspace_restore_enabled = case.enabled
			settings.backspace_restore_window_ms = case.window_ms
			assert(WordReset.restore_configuration(settings), "the case's settings are admissible")
			WordReset.forget_last_key()
			local replayed = (case.terminator ~= nil and case.terminator_consumed ~= true) and case.terminator or nil
			-- The field holds the trigger as typed; the firing terminator was held
			-- back by the grab and comes back only as the replayed one.
			observations = { screen = case.trigger, resets = {}, injected = {} }
			local clock = 1000
			local fired = false
			local environment = setmetatable({ secure_focus_guard = guard,
				script_actions = { is_paused = function() return false end },
				keyboard_hook = { held_modifiers = function() return {} end },
				Monotonic = { now_ms = function() return clock end, resolution_ms = function() return 0 end },
				_cached_app_id = "owned-editor", WordReset = WordReset,
				terminators_mod = { is_terminator = function(ch) return ch == " " or ch == "," or ch == "\n" end,
					terminator_is_consumed = function() return case.terminator_consumed == true end },
				MagicKey = { get = function() return case.magic_key end },
				RepeatKey = { is_enabled = function() return false end }, opts = { dry_run = false },
				keystats = { is_password_app = function() return false end, is_unrecorded_app = function() return false end,
					suppress = function() end, unsuppress = function() end, on_keydown = function() end,
					record_roi_text = function() end, discard_roi = function() end, record_roi_key = function() end,
					record_hotstring = function() end, record_correction = function() end },
				engine = {
					reset = function(_, at_word_start) observations.resets[#observations.resets + 1] = at_word_start == true end,
					backspace = function() observations.backspaced = true end,
					apply_expansion = function() end, navigated = function() end,
					on_char = function()
						if fired then return nil end
						fired = true
						return { trigger = case.trigger, typed_trigger = case.trigger, replacement = case.output,
							backspace_count = utf8.len(case.trigger), replay_terminator = replayed, is_private = false }
					end,
				},
				injector = { _is_injecting = function() return false end, _begin_injection = function() end,
					_end_injection = function() return {} end, caret_steps = function(text) return utf8.len(text) end,
					inject = function(backspaces, text, _, replay)
						observations.injected[#observations.injected + 1] = { backspaces = backspaces, text = text }
						observations.screen = erase(observations.screen, backspaces) .. text .. (replay or "")
						return { ok = true, cleanup_ok = true }
					end },
				Logger = require("core.logger.engine.shim"),
			}, { __index = _G })
			local character, control, undo = main_callbacks(environment)
			character(case.terminator or "x", 30)
			helpers.assert_eq(observations.screen, case.output .. (replayed or ""), "the expansion committed")
			if case.key_between then control("escape", {}) end
			clock = clock + case.elapsed_ms
			-- Under the grab the application received the Backspace first.
			observations.screen = without_last(observations.screen)
			observations.resets = {}
			control("backspace", {})
			observations.undo = undo()
		end)
		assert(WordReset.restore_configuration(saved))
		if not ok then error(failure, 0) end
	end)
	return observations
end

local DEFAULTS = { magic_key = STAR, enabled = true, window_ms = 500, elapsed_ms = 100 }

--- A case with the defaults filled in.
--- @param fields table
--- @return table
local function case(fields)
	local filled = {}
	for key, value in pairs(DEFAULTS) do filled[key] = value end
	for key, value in pairs(fields) do filled[key] = value end
	return filled
end

helpers.describe("Linux Main: Backspace restore (backspace-restore)", function()
	helpers.it("gives a magic-key trigger back without its magic key (backspace-restore-star)", function()
		local seen = run_case(case({ trigger = "td" .. STAR, output = "2026-08-01" }))
		helpers.assert_eq(seen.screen, "td", "td★ comes back as td")
		helpers.assert_eq(seen.resets, { false }, "the restored word ends at an unknown start")
	end)

	helpers.it("gives nothing back for the repeat key's lone magic key (backspace-restore-repeat)", function()
		local seen = run_case(case({ trigger = STAR, output = "o" }))
		helpers.assert_eq(seen.screen, "", "po★ -> poo, Backspace leaves po")
		helpers.assert_eq(#seen.injected, 1, "no empty restore is injected")
		helpers.assert_eq(seen.resets, { false })
		helpers.assert_nil(seen.backspaced, "the Backspace was the undo, not a buffer edit")
	end)

	for _, terminator in ipairs({ " ", ",", "\n" }) do
		helpers.it("gives the trigger and its replayed terminator " .. string.format("%q", terminator)
			.. " back (backspace-restore-terminator)", function()
			local seen = run_case(case({ trigger = "adn", output = "ADN", terminator = terminator }))
			helpers.assert_eq(seen.screen, "adn" .. terminator, "the terminator the user typed comes back")
			helpers.assert_eq(seen.resets, { true }, "a restore ending with a terminator leaves a word start")
		end)
	end

	helpers.it("does not type back a consumed terminator (backspace-restore-consumed)", function()
		local seen = run_case(case({ trigger = "btw", output = "by the way", terminator = STAR, terminator_consumed = true }))
		helpers.assert_eq(seen.screen, "btw")
	end)

	helpers.it("undoes at the window's end, inclusive (backspace-restore-window)", function()
		helpers.assert_eq(run_case(case({ trigger = "adn", output = "ADN", terminator = " ", elapsed_ms = 500 })).screen, "adn ")
		helpers.assert_eq(run_case(case({ trigger = "adn", output = "ADN", terminator = " ",
			window_ms = 2000, elapsed_ms = 1000 })).screen, "adn ", "a longer window still undoes")
	end)

	helpers.it("is a plain Backspace past the window (backspace-restore-window)", function()
		local seen = run_case(case({ trigger = "adn", output = "ADN", terminator = " ", elapsed_ms = 501 }))
		helpers.assert_eq(seen.screen, "ADN", "the Backspace deleted the Space only")
		helpers.assert_eq(#seen.injected, 1, "no restore was typed")
		helpers.assert_true(seen.backspaced, "the late Backspace edits the buffer")
		helpers.assert_nil(seen.undo, "the record is dropped")
	end)

	helpers.it("keeps no record and is a plain Backspace with the option off (backspace-restore-off)", function()
		local seen = run_case(case({ trigger = "td" .. STAR, output = "2026-08-01", enabled = false }))
		helpers.assert_eq(seen.screen, "2026-08-0")
		helpers.assert_eq(#seen.injected, 1, "no restore was typed")
		helpers.assert_true(seen.backspaced, "the Backspace edits the buffer")
	end)

	helpers.it("ends the undo on any other key (backspace-restore-key-between)", function()
		local seen = run_case(case({ trigger = "adn", output = "ADN", terminator = " ", key_between = true }))
		helpers.assert_eq(seen.screen, "ADN")
		helpers.assert_eq(#seen.injected, 1, "no restore was typed")
	end)
end)

require("tests.lua.hotstrings.backspace_restore_contract").register(helpers,
	require("core.fs.engine.paths").shared("tests/corpus/hotstrings/backspace_restore_vectors.json"), "Linux",
	function(vector)
		local seen = run_case(vector)
		-- The corpus reads the expansion's part of the line: the repeat's « po »
		-- lies before it.
		return seen.screen
	end)
