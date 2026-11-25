--- tests/unit/hotstrings/engine/injector/test_backspace_restore.lua

--- ==============================================================================
--- MODULE: Backspace Restore Through Main's Undo
--- DESCRIPTION:
--- Executes Main's actual character and control callbacks with the real Linux
--- engine and repeat owner against a modelled text field: every typed key lands
--- in the field, the expansion commits through the scripted injector, the
--- application deletes one character for the re-emitted Backspace, then Main's
--- undo erases and types what the shared rule
--- (_shared/hotstrings/engine/backspace_restore.lua) gives back. The settings are
--- the real word-reset owner's, so the option and the window reach the undo
--- exactly as the menu writes them.
---
--- Before these cases the undo typed the trigger as stored in the record: « td★ »
--- came back with its magic key, « adn » and Space came back without the Space,
--- and a Backspace undid an expansion whatever the time elapsed or the option.
--- Then the undo emptied the buffer, so « adn★ », Backspace, « ★ » typed a star
--- instead of expanding again (decision of 2026-11-20): the buffer now holds the
--- restored text.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.text_owner_fixture")

local STAR = "★"
local BACKSPACE = "{BS}"

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

--- The mapping a case fires: a magic-key or other auto trigger, or a word-only
--- terminator trigger in any casing (the shipped « adn » entry is case-folded),
--- then the case's `extra_mappings`.
--- @param case table The corpus shape.
--- @return table mappings
local function mappings_for(case)
	local mappings = {}
	if case.trigger == case.magic_key then
		-- The repeat key owns the lone magic key.
	elseif case.terminator == nil then
		mappings[1] = { trigger = case.trigger, replacement = case.output, auto_expand = true, is_word = true }
	else
		mappings[1] = { trigger = case.trigger:lower(), replacement = case.output, auto_expand = false,
			is_word = true, is_case_sensitive = true }
	end
	for _, mapping in ipairs(case.extra_mappings or {}) do mappings[#mappings + 1] = mapping end
	return mappings
end

--- Runs a body against Main with a case's mapping, option and window.
--- @param case table `{ trigger, output, terminator, terminator_consumed, magic_key,
---   enabled, window_ms }`, the corpus shape.
--- @param body function Receives the field: type(text), backspace(), advance(ms),
---   escape(), screen(), buffer(), boundary(), undo(), and its observations.
local function with_field(case, body)
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
			local engine = helpers.load_module("hotstrings.engine.engine").new()
			engine:load_mappings(mappings_for(case))
			local RepeatKey = helpers.load_module("hotstrings.engine.repeat_key")
			local observations = { injected = {}, backspaced = 0 }
			local screen = ""
			local clock = 1000
			local shared_backspace = engine.backspace
			engine.backspace = function(self)
				observations.backspaced = observations.backspaced + 1
				return shared_backspace(self)
			end
			local environment = setmetatable({ secure_focus_guard = guard,
				script_actions = { is_paused = function() return false end },
				keyboard_hook = { held_modifiers = function() return {} end },
				Monotonic = { now_ms = function() return clock end, resolution_ms = function() return 0 end },
				_cached_app_id = "owned-editor", WordReset = WordReset,
				terminators_mod = {
					is_terminator = function(ch)
						return ch == " " or ch == "," or ch == "\n" or ch == case.terminator
					end,
					terminator_is_consumed = function(ch)
						return case.terminator_consumed == true and ch == case.terminator
					end,
				},
				MagicKey = { get = function() return case.magic_key end },
				CommitFollowup = require("hotstrings.engine.commit_followup"),
				RepeatKey = { is_enabled = function() return true end, resolve = RepeatKey.resolve,
					WINDOW_CATEGORY = RepeatKey.WINDOW_CATEGORY },
				opts = { dry_run = false },
				keystats = { is_password_app = function() return false end, is_unrecorded_app = function() return false end,
					suppress = function() end, unsuppress = function() end, on_keydown = function() end,
					record_roi_text = function() end, discard_roi = function() end, record_roi_key = function() end,
					record_hotstring = function() end, record_correction = function() end },
				engine = engine,
				injector = { _is_injecting = function() return false end, _begin_injection = function() end,
					_end_injection = function() return {} end, caret_steps = function(text) return utf8.len(text) end,
					inject = function(backspaces, text, _, replay)
						observations.injected[#observations.injected + 1] = { backspaces = backspaces, text = text }
						screen = erase(screen, backspaces) .. text .. (replay or "")
						return { ok = true, cleanup_ok = true }
					end },
				Logger = require("core.logger.engine.shim"),
			}, { __index = _G })
			local character, control, undo = main_callbacks(environment)
			local field = {}
			--- Types text key by key: each key lands in the field, then reaches Main.
			function field.type(text)
				for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
					screen = screen .. ch
					character(ch, 30)
				end
			end
			--- A Backspace: under the grab the application deletes first.
			function field.backspace()
				screen = without_last(screen)
				control("backspace", {})
			end
			function field.escape() control("escape", {}) end
			function field.advance(ms) clock = clock + ms end
			function field.screen() return screen end
			function field.buffer() return engine:current_buffer() end
			function field.boundary() return engine:buffer_starts_at_word_boundary() end
			function field.undo() return undo() end
			--- Types each key of a corpus `then` list.
			function field.keys(keys)
				for _, key in ipairs(keys) do
					if key == BACKSPACE then field.backspace() else field.type(key) end
				end
			end
			body(field, observations)
		end)
		assert(WordReset.restore_configuration(saved))
		if not ok then error(failure, 0) end
	end)
end

--- What a case types before its trigger: the repeat key repeats a letter of it.
--- @param case table
--- @return string
local function typed_before(case)
	return case.trigger == case.magic_key and ("p" .. case.output) or ""
end

--- Fires a case's expansion in the field.
--- @param field table
--- @param case table
local function fire(field, case)
	local replayed = (case.terminator ~= nil and case.terminator_consumed ~= true) and case.terminator or ""
	field.type(typed_before(case) .. case.trigger .. (case.terminator or ""))
	helpers.assert_eq(field.screen(), typed_before(case) .. case.output .. replayed, "the expansion committed")
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

--- Fires a case, waits its elapsed time and presses Backspace.
--- @param fields table
--- @param body function Receives the field and the observations after the Backspace.
local function after_backspace(fields, body)
	local filled = case(fields)
	with_field(filled, function(field, observations)
		fire(field, filled)
		if filled.key_between then field.escape() end
		field.advance(filled.elapsed_ms)
		field.backspace()
		body(field, observations)
	end)
end

helpers.describe("Linux Main: Backspace restore (backspace-restore)", function()
	helpers.it("gives a magic-key trigger back without its magic key (backspace-restore-star)", function()
		after_backspace({ trigger = "td" .. STAR, output = "2026-08-01" }, function(field)
			helpers.assert_eq(field.screen(), "td", "td★ comes back as td")
			helpers.assert_eq(field.buffer(), "td", "the buffer holds the restored trigger")
		end)
	end)

	helpers.it("gives nothing back for the repeat key's lone magic key (backspace-restore-repeat)", function()
		after_backspace({ trigger = STAR, output = "o" }, function(field, observations)
			helpers.assert_eq(field.screen(), "po", "po★ -> poo, Backspace leaves po")
			helpers.assert_eq(#observations.injected, 1, "no empty restore is injected")
			helpers.assert_eq(field.buffer(), "po", "the buffer holds the line again")
			helpers.assert_eq(observations.backspaced, 0, "the Backspace was the undo, not a buffer edit")
		end)
	end)

	for _, terminator in ipairs({ " ", ",", "\n" }) do
		helpers.it("gives the trigger and its replayed terminator " .. string.format("%q", terminator)
			.. " back (backspace-restore-terminator)", function()
			after_backspace({ trigger = "adn", output = "ADN", terminator = terminator }, function(field)
				helpers.assert_eq(field.screen(), "adn" .. terminator, "the terminator the user typed comes back")
				helpers.assert_eq(field.buffer(), "adn" .. terminator, "and the buffer holds it after the trigger")
			end)
		end)
	end

	helpers.it("does not type back a consumed terminator (backspace-restore-consumed)", function()
		after_backspace({ trigger = "btw", output = "by the way", terminator = STAR, terminator_consumed = true },
			function(field) helpers.assert_eq(field.screen(), "btw") end)
	end)

	helpers.it("undoes at the window's end, inclusive (backspace-restore-window)", function()
		after_backspace({ trigger = "adn", output = "ADN", terminator = " ", elapsed_ms = 500 },
			function(field) helpers.assert_eq(field.screen(), "adn ") end)
		after_backspace({ trigger = "adn", output = "ADN", terminator = " ", window_ms = 2000, elapsed_ms = 1000 },
			function(field) helpers.assert_eq(field.screen(), "adn ", "a longer window still undoes") end)
	end)

	helpers.it("is a plain Backspace past the window (backspace-restore-window)", function()
		after_backspace({ trigger = "adn", output = "ADN", terminator = " ", elapsed_ms = 501 },
			function(field, observations)
				helpers.assert_eq(field.screen(), "ADN", "the Backspace deleted the Space only")
				helpers.assert_eq(#observations.injected, 1, "no restore was typed")
				helpers.assert_eq(observations.backspaced, 1, "the late Backspace edits the buffer")
				helpers.assert_eq(field.buffer(), "ADN", "which follows the line")
				helpers.assert_nil(field.undo(), "the record is dropped")
			end)
	end)

	helpers.it("keeps no record and is a plain Backspace with the option off (backspace-restore-off)", function()
		after_backspace({ trigger = "td" .. STAR, output = "2026-08-01", enabled = false },
			function(field, observations)
				helpers.assert_eq(field.screen(), "2026-08-0")
				helpers.assert_eq(#observations.injected, 1, "no restore was typed")
				helpers.assert_eq(observations.backspaced, 1, "the Backspace edits the buffer")
			end)
	end)

	helpers.it("ends the undo on any other key (backspace-restore-key-between)", function()
		after_backspace({ trigger = "adn", output = "ADN", terminator = " ", key_between = true },
			function(field, observations)
				helpers.assert_eq(field.screen(), "ADN")
				helpers.assert_eq(#observations.injected, 1, "no restore was typed")
			end)
	end)
end)

-- The maintainer's rule of 2026-11-20: « adn★ Backspace ★ doit donner ADN si
-- adn★ donne ADN ». The undo used to reset the buffer, so the star after it
-- matched nothing and stayed a star.
helpers.describe("Linux Main: the restored trigger expands again (backspace-restore-again)", function()
	helpers.it("adn★, Backspace, ★ gives ADN, and again after a second undo (backspace-restore-again)", function()
		after_backspace({ trigger = "adn" .. STAR, output = "ADN" }, function(field, observations)
			helpers.assert_eq(field.screen(), "adn", "control: the undo restored adn")
			field.type(STAR)
			helpers.assert_eq(field.screen(), "ADN", "the magic key expands the restored trigger at once")
			field.backspace()
			helpers.assert_eq(field.screen(), "adn", "the second expansion undoes too")
			field.type(STAR)
			helpers.assert_eq(field.screen(), "ADN", "and expands once more")
			helpers.assert_eq(#observations.injected, 5, "three expansions and two restores")
		end)
	end)

	helpers.it("expands again after the undo window and after a pause (backspace-restore-again)", function()
		after_backspace({ trigger = "adn" .. STAR, output = "ADN" }, function(field)
			field.advance(2000)
			field.type(STAR)
			helpers.assert_eq(field.screen(), "ADN", "the restored trigger does not age with the window")
		end)
	end)

	helpers.it("po★, Backspace, ★ repeats the o again (backspace-restore-again)", function()
		after_backspace({ trigger = STAR, output = "o" }, function(field)
			helpers.assert_eq(field.screen(), "po", "control: the repeat is undone")
			field.type(STAR)
			helpers.assert_eq(field.screen(), "poo", "the magic key repeats the o once more")
		end)
	end)

	helpers.it("adn and Space, Backspace, Backspace, Space gives ADN and Space again (backspace-restore-again)", function()
		after_backspace({ trigger = "adn", output = "ADN", terminator = " " }, function(field)
			helpers.assert_eq(field.screen(), "adn ", "control: the undo restored adn and its Space")
			helpers.assert_true(field.boundary(), "the restored line starts at the word adn began at")
			field.backspace()
			helpers.assert_eq(field.buffer(), "adn", "deleting the restored Space leaves adn in the buffer")
			field.type(" ")
			helpers.assert_eq(field.screen(), "ADN ", "Space fires adn as typing it would")
		end)
		after_backspace({ trigger = "adn", output = "ADN", terminator = " " }, function(field)
			field.advance(2000)
			field.backspace()
			field.type(" ")
			helpers.assert_eq(field.screen(), "ADN ", "the same after the undo window")
		end)
	end)

	helpers.it("a word-only trigger still fires after a restored terminator (backspace-restore-again)", function()
		after_backspace({ trigger = "adn", output = "ADN", terminator = " " }, function(field)
			field.type("adn ")
			helpers.assert_eq(field.screen(), "adn ADN ", "the restored Space ended the word")
		end)
	end)

	helpers.it("no word starts inside a trigger restored without a terminator (backspace-restore-again)", function()
		local adn = { trigger = "adn", replacement = "ADN", auto_expand = false, is_word = true, is_case_sensitive = true }
		after_backspace({ trigger = "pk" .. STAR, output = "PK", extra_mappings = { adn } }, function(field)
			helpers.assert_eq(field.buffer(), "pk", "control: the buffer holds the restored pk")
			field.type("adn ")
			helpers.assert_eq(field.screen(), "pkadn ", "adn continues the word pk, so the word-only rule stays silent")
		end)
	end)

	helpers.it("with the option off the buffer follows each Backspace (backspace-restore-again)", function()
		after_backspace({ trigger = "adn", output = "ADN", terminator = " ", enabled = false }, function(field)
			helpers.assert_eq(field.screen(), "ADN", "control: a plain Backspace")
			field.keys({ BACKSPACE, BACKSPACE, BACKSPACE })
			helpers.assert_eq(field.buffer(), "", "the buffer emptied with the line")
			field.type("adn ")
			helpers.assert_eq(field.screen(), "ADN ", "adn and Space expand again")
		end)
	end)
end)

require("tests.lua.hotstrings.backspace_restore_contract").register(helpers,
	require("core.fs.engine.paths").shared("tests/corpus/hotstrings/backspace_restore_vectors.json"), "Linux",
	function(vector)
		local seen = {}
		after_backspace(vector, function(field)
			-- The corpus reads the expansion's part of the line and of the buffer:
			-- the repeat's « po » lies before it.
			local before = typed_before(vector)
			local function own(text)
				return text:sub(1, #before) == before and text:sub(#before + 1) or ("<" .. text .. ">")
			end
			seen.screen = own(field.screen())
			seen.buffer = own(field.buffer())
			if vector["then"] ~= nil then
				field.keys(vector["then"])
				seen.screen_then = own(field.screen())
			end
		end)
		return seen
	end)
