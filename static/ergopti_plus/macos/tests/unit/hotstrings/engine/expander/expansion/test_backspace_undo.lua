--- tests/unit/hotstrings/engine/expander/expansion/test_backspace_undo.lua

--- ==============================================================================
--- MODULE: Backspace Undo (macOS)
--- DESCRIPTION:
--- A Backspace pressed right after an expansion erases what it typed and types
--- the trigger back (decision of 2026-11-06, Expander.undo_on_backspace). These
--- tests drive the real registry and expander and read the replacement
--- transactions. Pinned here: a literal expansion, an expansion whose French
--- typographic no-break space was stripped, and the magic-key repeat, which
--- Windows and Linux also make undoable; a key output is not.
--- ==============================================================================

local helpers = require("tests.helpers")

local _     = helpers.load_with_stubs("core.logger.engine.logger")
local State = helpers.load_with_stubs("hotstrings.engine.expander.state")

local STAR = "★"





-- =================================================
-- =================================================
-- ======= 1/ Harness: registry and expander =======
-- =================================================
-- =================================================

--- Builds a live registry + expander pair with the OS-facing collaborators stubbed
--- and the replacement transaction recorded.
--- @param entries table Array of { trigger, replacement, opts } entries.
--- @param depth number hotstrings.cascade_max_arrows (arrows; 1 = a single expansion).
--- @return table state, table expander, table log
local function fresh_engine(entries, depth)
	package.loaded["core.ui.ui.tooltip"]        = { hide = function() end, hide_forced = function() end }
	package.loaded["metrics.engine"] = {
		notify_synthetic = function() end,
		set_buffer       = function() end,
		log_hotstring    = function() end,
	}
	for name in pairs(package.loaded) do
		if type(name) == "string" and name:match("^hotstrings%.engine%.expander%.")
			and name ~= "hotstrings.engine.expander.state" then
			package.loaded[name] = nil
		end
	end
	package.loaded["core.text.engine.utils"] = nil
	package.loaded["core.text.engine.utils_core"]       = nil

	local R = require("settings.engine.registry")
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
	for _, char in ipairs(helpers.utf8_chars and helpers.utf8_chars(text) or (function()
		local out = {}
		for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do out[#out + 1] = ch end
		return out
	end)()) do
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

helpers.describe("keymap: the Backspace undo", function()

	helpers.it("a literal expansion gives its trigger back (undo-literal)", function()
		local state, expander, log = fresh_engine({ { "ab", "cd", { auto_expand = false } } }, 1)
		state.buffer = "ab"
		helpers.assert_true(type_terminator(state, expander, " "), "ab+space must fire")
		local restored, transaction = press_backspace(state, expander, log)
		helpers.assert_true(restored, "the Backspace restores the trigger")
		helpers.assert_eq(3, transaction.deletes, "cd and the replayed space are erased")
		helpers.assert_eq("ab", transaction.typed, "the trigger alone is typed back")
	end)

	-- Windows (dispatch, trigger only) and Linux restore an expansion whose
	-- typographic space before ":" was stripped; macOS kept no record for it.
	helpers.it("an expansion that stripped a no-break space gives its trigger back (undo-nbsp-stripped)", function()
		local state, expander, log = fresh_engine({ { "ab", "cd", { auto_expand = false } } }, 1)
		state.buffer = "ab" .. NNBSP
		helpers.assert_true(type_terminator(state, expander, ":"), "ab, a no-break space and : must fire")
		local restored, transaction = press_backspace(state, expander, log)
		helpers.assert_true(restored, "the Backspace restores the trigger")
		helpers.assert_eq(3, transaction.deletes, "cd and the replayed colon are erased")
		helpers.assert_eq("ab", transaction.typed, "the trigger alone, as on Windows and Linux")
	end)

	-- Windows (the repeat Spec goes through the atomic fire) and Linux (Main
	-- records the repeat result) let a Backspace give the magic key back.
	helpers.it("the magic-key repeat gives the magic key back (undo-repeat)", function()
		local state, expander, log = fresh_engine({}, 1)
		state.is_repeat_feature_enabled = function() return true end
		state.buffer = "po" .. STAR
		helpers.assert_true(expander.try_repeat_feature(STAR, false), "po and the magic key repeat the o")
		helpers.assert_eq("poo", state.buffer)
		local restored, transaction = press_backspace(state, expander, log)
		helpers.assert_true(restored, "the Backspace restores the magic key")
		helpers.assert_eq(1, transaction.deletes, "the repeated o is erased")
		helpers.assert_eq(STAR, transaction.typed, "the magic key is typed back")
	end)

	helpers.it("a key output keeps no record (undo-literal)", function()
		local state, expander = fresh_engine({ { "ab", "cd{Left}", { auto_expand = false } } }, 1)
		state.buffer = "ab"
		type_terminator(state, expander, " ")
		helpers.assert_eq(nil, state.undoable, "what a pressed key left is not known")
	end)

end)
