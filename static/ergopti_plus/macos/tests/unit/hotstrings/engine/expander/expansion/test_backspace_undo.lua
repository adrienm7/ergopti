--- tests/unit/hotstrings/engine/expander/expansion/test_backspace_undo.lua

--- ==============================================================================
--- MODULE: Backspace Undo (macOS)
--- DESCRIPTION:
--- A Backspace pressed right after an expansion erases what it typed and types
--- the trigger back (decision of 2026-11-06, Expander.undo_on_backspace). These
--- tests drive the real registry and expander and read the replacement
--- transactions. Pinned here: a literal expansion, an expansion whose French
--- typographic no-break space was stripped, and the magic-key repeat, which
--- Windows and Linux also make undoable; a key output is not. The shared rule
--- (hotstrings/engine/backspace_restore.lua) decides what comes back: a final
--- magic key does not, a replayed terminator does, and only within
--- hotstrings.backspace_restore_window_ms while hotstrings.backspace_restore_enabled.
--- The shared vectors are replayed through this same undo path.
--- ==============================================================================

local helpers = require("tests.helpers")

local _     = helpers.load_with_stubs("core.logger.engine.logger")
local State = helpers.load_with_stubs("hotstrings.engine.expander.state")
local Manifest = require("menu.engine.manifest_reader")
local ConfigKeys = require("settings.engine.keys")
local TimerScheduler = require("core.events.timer_scheduler")

local STAR = "★"
local MS_PER_SEC = 1000
local DEFAULT_WINDOW_MS = Manifest.default_for(ConfigKeys.KEY.HOTSTRINGS_BACKSPACE_RESTORE_WINDOW_MS)





-- =================================================
-- =================================================
-- ======= 1/ Harness: registry and expander =======
-- =================================================
-- =================================================

-- The keystroke clock the expander stamps its undo records with, in seconds.
local clock = { now = 0 }

--- Runs a body with the keystroke clock under the test's hand, and always
--- gives the real clock back.
--- @param body function
local function with_clock(body)
	local original = TimerScheduler.hotstring_time
	clock.now = 0
	TimerScheduler.hotstring_time = function() return clock.now end
	local ok, err = pcall(body)
	TimerScheduler.hotstring_time = original
	if not ok then error(err, 0) end
end

--- Moves the keystroke clock on.
--- @param ms number Milliseconds.
local function advance(ms)
	clock.now = clock.now + ms / MS_PER_SEC
end

--- Builds a live registry + expander pair with the OS-facing collaborators stubbed
--- and the replacement transaction recorded. The Backspace restore is on with
--- its shipped window, as keymap/init.lua seeds it.
--- @param entries table Array of { trigger, replacement, opts } entries.
--- @param depth number hotstrings.cascade_max_arrows (arrows; 1 = a single expansion).
--- @return table state, table expander, table log
local function fresh_engine(entries, depth)
	package.loaded["core.ui.ui.tooltip"]        = { hide = function() end, hide_forced = function() end }
	package.loaded["modules.keystats"] = {
		notify_synthetic = function() end,
		set_buffer       = function() end,
		log_hotstring    = function() end,
	}
	for name in pairs(package.loaded) do
		if type(name) == "string" and helpers.in_module_family(name, "hotstrings.engine.expander", true)
			and name ~= "hotstrings.engine.expander.state" then
			package.loaded[name] = nil
		end
	end
	package.loaded["core.text.engine.utils"] = nil
	package.loaded["core.text.engine.utils_core"]       = nil

	local R = require("hotstrings.engine.expander.registry")
	local E = require("hotstrings.engine.expander.expander")
	local state = State.new({ trigger_char = STAR, expansion_delay = 0.4 }, {})
	R.init(state)
	E.init(state, R, {
		update_preview  = function() end,
		get_llm_enabled = function() return false end,
		start_timer     = function() end,
	})
	for _, entry in ipairs(entries) do
		local opts = { auto_expand = true }
		for key, value in pairs(entry[3] or {}) do opts[key] = value end
		R.add(entry[1], entry[2], opts)
	end
	R.sort_mappings()
	state.start_is_word_boundary = true
	state.CASCADE_MAX_ARROWS = depth
	state.backspace_restore_enabled = Manifest.default_for(ConfigKeys.KEY.HOTSTRINGS_BACKSPACE_RESTORE_ENABLED)
	state.backspace_restore_window_ms = DEFAULT_WINDOW_MS

	-- The transaction, as the engine builds it: how many characters it erases,
	-- what it types, and what it replays afterwards.
	local log = { transactions = {} }
	local typed
	local utils = require("hotstrings.engine.expander.utils")
	utils.emit_text = function(text)
		typed = text
		return require("core.text.engine.utils").utf8_len(text), text, text
	end
	E.perform_text_replacement = function(deletes, emit_action, buffer_action, is_final,
		_ignored, _source, _variant, is_private, terminator_spec)
		typed = nil
		emit_action()
		buffer_action()
		log.transactions[#log.transactions + 1] = {
			deletes = deletes, typed = typed, is_final = is_final, is_private = is_private,
			replay = terminator_spec and terminator_spec.chars or nil,
		}
		return true
	end
	return state, E, log
end

--- Types one character the way the tap does: it joins the buffer, then the entry
--- whose trigger ends the buffer is fired (auto first, then end-char).
--- @return boolean fired
local function type_char(state, expander, char)
	state.buffer = state.buffer .. char
	for _, mapping in ipairs(state.mappings) do
		local trigger = mapping.trigger
		if mapping.auto and #state.buffer >= #trigger and state.buffer:sub(-#trigger) == trigger then
			if expander.try_auto_expand(mapping, 1, false) == true then return true end
		end
	end
	return false
end

--- Types a string character by character; returns whether the last one fired.
local function type_string(state, expander, text)
	local fired = false
	for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		fired = type_char(state, expander, char)
	end
	return fired
end

--- Types the end character after the buffer: the terminator path.
--- @return boolean fired
local function type_terminator(state, expander, chars)
	state.buffer = state.buffer .. chars
	for _, mapping in ipairs(state.mappings) do
		if not mapping.auto then
			if expander.try_terminator_expand(mapping, chars, 1, false) == true then return true end
		end
	end
	return false
end

local NNBSP = "\u{202F}"

--- Runs the undo the next Backspace would run and returns its transaction.
--- @return boolean restored, table|nil transaction
local function press_backspace(state, expander, log)
	local undo = state.undoable
	state.undoable = nil
	local before = #log.transactions
	local restored = expander.undo_on_backspace(undo) == true
	return restored, log.transactions[before + 1]
end

--- Fires « adn » with an end character, as the terminator path does.
--- @param chars string The end character.
--- @return table state, table expander, table log
local function fire_adn(chars)
	local state, expander, log = fresh_engine({ { "adn", "ADN", { auto_expand = false } } }, 1)
	state.buffer = "adn"
	helpers.assert_true(type_terminator(state, expander, chars), "adn and its end character must fire")
	return state, expander, log
end

helpers.describe("keymap: the Backspace undo", function()

	helpers.it("a literal expansion gives its trigger and its space back (undo-literal)", function()
		with_clock(function()
			local state, expander, log = fresh_engine({ { "ab", "cd", { auto_expand = false } } }, 1)
			state.buffer = "ab"
			helpers.assert_true(type_terminator(state, expander, " "), "ab+space must fire")
			local restored, transaction = press_backspace(state, expander, log)
			helpers.assert_true(restored, "the Backspace restores the trigger")
			helpers.assert_eq(3, transaction.deletes, "cd and the replayed space are erased")
			helpers.assert_eq("ab ", transaction.typed, "the trigger and the replayed space are typed back")
		end)
	end)

	-- Windows (dispatch, trigger only) and Linux restore an expansion whose
	-- typographic space before ":" was stripped; macOS kept no record for it.
	helpers.it("an expansion that stripped a no-break space gives its trigger back (undo-nbsp-stripped)", function()
		with_clock(function()
			local state, expander, log = fresh_engine({ { "ab", "cd", { auto_expand = false } } }, 1)
			state.buffer = "ab" .. NNBSP
			helpers.assert_true(type_terminator(state, expander, ":"), "ab, a no-break space and : must fire")
			local restored, transaction = press_backspace(state, expander, log)
			helpers.assert_true(restored, "the Backspace restores the trigger")
			helpers.assert_eq(3, transaction.deletes, "cd and the replayed colon are erased")
			helpers.assert_eq("ab:", transaction.typed, "the trigger and the replayed colon, without the no-break space")
		end)
	end)

	-- The repeat key's trigger is the lone magic key, an action and not text: the
	-- Backspace erases the repeated character and types nothing back.
	helpers.it("the magic-key repeat gives nothing of the star back (backspace-restore-repeat)", function()
		with_clock(function()
			local state, expander, log = fresh_engine({}, 1)
			state.is_repeat_feature_enabled = function() return true end
			state.buffer = "po" .. STAR
			helpers.assert_true(expander.try_repeat_feature(STAR, false), "po and the magic key repeat the o")
			helpers.assert_eq("poo", state.buffer)
			local restored, transaction = press_backspace(state, expander, log)
			helpers.assert_true(restored, "the Backspace undoes the repeat")
			helpers.assert_eq(1, transaction.deletes, "the repeated o is erased")
			helpers.assert_eq(nil, transaction.typed, "no magic key is typed back: po stays")
		end)
	end)

	helpers.it("a trigger ended by the magic key comes back without it (backspace-restore-star)", function()
		with_clock(function()
			local state, expander, log = fresh_engine({ { "td" .. STAR, "2026-08-01" } }, 1)
			helpers.assert_true(type_string(state, expander, "td" .. STAR), "td★ must fire")
			local restored, transaction = press_backspace(state, expander, log)
			helpers.assert_true(restored, "the Backspace restores the trigger")
			helpers.assert_eq(10, transaction.deletes, "the date is erased")
			helpers.assert_eq("td", transaction.typed, "td comes back, not td★")
			helpers.assert_eq(false, state.start_is_word_boundary, "the caret stays inside the restored word")
		end)
	end)

	helpers.it("Space, punctuation and Enter come back after the trigger (backspace-restore-terminator)", function()
		with_clock(function()
			for _, chars in ipairs({ " ", ",", "\n" }) do
				local state, expander, log = fire_adn(chars)
				local restored, transaction = press_backspace(state, expander, log)
				helpers.assert_true(restored, "the Backspace restores the trigger")
				helpers.assert_eq(4, transaction.deletes, "ADN and the replayed end character are erased")
				helpers.assert_eq("adn" .. chars, transaction.typed, "adn and its end character, not ADN")
				helpers.assert_eq("", state.buffer, "the restored text is not in the buffer")
				helpers.assert_eq(true, state.start_is_word_boundary,
					"the restored end character opens the next word")
			end
		end)
	end)

	helpers.it("undoes within the window, inclusive, and not one millisecond after (backspace-restore-window)", function()
		with_clock(function()
			local state, expander, log = fire_adn(" ")
			advance(DEFAULT_WINDOW_MS)
			helpers.assert_true((press_backspace(state, expander, log)), "the window's last millisecond still undoes")

			state, expander, log = fire_adn(" ")
			advance(DEFAULT_WINDOW_MS + 1)
			local restored, transaction = press_backspace(state, expander, log)
			helpers.assert_eq(false, restored, "past the window the Backspace is a plain Backspace")
			helpers.assert_nil(transaction, "nothing is erased or typed")

			state, expander, log = fire_adn(" ")
			state.backspace_restore_window_ms = 2000
			advance(1000)
			helpers.assert_true((press_backspace(state, expander, log)), "a longer window still undoes")
		end)
	end)

	helpers.it("the option off keeps no record and leaves a plain Backspace (backspace-restore-off)", function()
		with_clock(function()
			local state, expander, log = fresh_engine({ { "adn", "ADN", { auto_expand = false } } }, 1)
			state.backspace_restore_enabled = false
			state.buffer = "adn"
			helpers.assert_true(type_terminator(state, expander, " "), "adn+space must fire")
			helpers.assert_nil(state.undoable, "no undo record is kept")
			helpers.assert_eq(false, expander.undo_on_backspace(nil), "the Backspace is a plain Backspace")

			-- Switched off after the expansion: the record kept before does not undo.
			state, expander, log = fire_adn(" ")
			state.backspace_restore_enabled = false
			local restored, transaction = press_backspace(state, expander, log)
			helpers.assert_eq(false, restored)
			helpers.assert_nil(transaction)
		end)
	end)

	-- The tap drops the record on any other key (init.lua takes CoreState.undoable
	-- off for every keystroke); a record kept and then edited away undoes nothing.
	helpers.it("another key in between ends the undo (backspace-restore-key-between)", function()
		with_clock(function()
			local state, expander, log = fire_adn(" ")
			local undo = state.undoable
			helpers.assert_eq(" ", undo and undo.replayed, "the record keeps the replayed terminator")
			state.buffer = state.buffer .. "x"
			state.undoable = nil
			helpers.assert_eq(false, expander.undo_on_backspace(undo), "the record no longer matches the buffer")
			helpers.assert_eq(0, #log.transactions - 1, "no undo transaction went out")
		end)
	end)

	-- One Backspace deletes a whole emoji, flag or accent cluster: counting the
	-- replacement in code points also erased characters typed before it.
	helpers.it("erases an emoji or accent replacement by character (macos-undo-graphemes)", function()
		with_clock(function()
			for _, case in ipairs({
				{ "Z👍🏽", 3 }, { "Z👨‍👩‍👧", 3 }, { "Z🇫🇷", 3 }, { "Ze\u{0301}", 3 }, { "Z❤️", 3 },
			}) do
				local state, expander, log = fresh_engine({ { "ab", case[1], { auto_expand = false } } }, 1)
				state.buffer = "ab"
				helpers.assert_true(type_terminator(state, expander, " "), "ab+space must fire")
				local restored, transaction = press_backspace(state, expander, log)
				helpers.assert_true(restored, "the Backspace restores the trigger")
				helpers.assert_eq(case[2], transaction.deletes, "Z, the cluster and the space only: " .. case[1])
				helpers.assert_eq("ab ", transaction.typed)
			end
		end)
	end)

	helpers.it("a key output keeps no record (undo-literal)", function()
		with_clock(function()
			local state, expander = fresh_engine({ { "ab", "cd{Left}", { auto_expand = false } } }, 1)
			state.buffer = "ab"
			type_terminator(state, expander, " ")
			helpers.assert_eq(nil, state.undoable, "what a pressed key left is not known")
		end)
	end)

end)





-- =============================================
-- =============================================
-- ======= 2/ The shared vectors' replay =======
-- =============================================
-- =============================================

--- Removes the last n user-perceived characters of a screen text. The corpus
--- texts hold one-code-point characters only, so a code point is a character.
--- @param text string
--- @param n number
--- @return string
local function erase(text, n)
	for _ = 1, n do
		local last = text:match("[%z\1-\127\194-\244][\128-\191]*$") or ""
		text = text:sub(1, #text - #last)
	end
	return text
end

--- Fires one vector's expansion through the path that types it, then presses
--- the Backspace through the real undo, and reads the expansion's part of the line.
--- @param vector table One corpus vector.
--- @return string screen_after
local function replay(vector)
	local screen
	with_clock(function()
		local state, expander, log
		local replayed = (vector.terminator ~= nil and vector.terminator_consumed ~= true) and vector.terminator or nil
		if vector.trigger == vector.magic_key then
			-- The repeat key: what precedes the magic key is not part of the expansion.
			state, expander, log = fresh_engine({}, 1)
			state.is_repeat_feature_enabled = function() return true end
			state.buffer = "p" .. vector.output .. vector.magic_key
			assert(expander.try_repeat_feature(vector.magic_key, false), vector.id .. ": the repeat fires")
		elseif vector.terminator == nil then
			state, expander, log = fresh_engine({ { vector.trigger, vector.output } }, 1)
			assert(type_string(state, expander, vector.trigger), vector.id .. ": the trigger fires")
		else
			state, expander, log = fresh_engine({ { vector.trigger:lower(), vector.output, { auto_expand = false } } }, 1)
			state.buffer = vector.trigger
			assert(type_terminator(state, expander, vector.terminator), vector.id .. ": the terminator fires")
			-- The engine's own consumption decides: a consumed end keeps no replay.
			assert((state.undoable.replayed == nil) == (vector.terminator_consumed == true),
				vector.id .. ": the record's replayed terminator follows the consumption")
		end
		state.magic_key = vector.magic_key
		state.backspace_restore_enabled = vector.enabled
		state.backspace_restore_window_ms = vector.window_ms
		screen = vector.output .. (replayed or "")
		advance(vector.elapsed_ms)
		-- Any key in between drops the record, as the tap does for every keystroke.
		if vector.key_between == true then state.undoable = nil end
		local restored, transaction = press_backspace(state, expander, log)
		if restored then
			screen = erase(screen, transaction.deletes) .. (transaction.typed or "")
		else
			screen = erase(screen, 1)
		end
	end)
	return screen
end

require("tests.lua.hotstrings.backspace_restore_contract").register(helpers,
	helpers.shared("tests/corpus/hotstrings/backspace_restore_vectors.json"), "macOS", replay)
