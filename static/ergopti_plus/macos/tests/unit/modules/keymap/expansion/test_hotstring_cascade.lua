--- tests/unit/modules/keymap/expansion/test_hotstring_cascade.lua

--- ==============================================================================
--- MODULE: Hotstring Cascade (macOS)
--- DESCRIPTION:
--- With hotstrings.cascade_depth above 0 the text a hotstring produced may complete
--- further hotstrings: `chatg` gives `chatgpt` and `chatgpt` gives `ChatGPT`, so
--- typing `chatg` ends on `ChatGPT` from depth 1. The chain is resolved before
--- anything is typed and goes out as ONE replacement (one deletion count, one
--- text), so these tests read the replacement transaction itself, not only the
--- buffer. Pinned here: depth 0 is today's behaviour, depth 1 and 2, the
--- same-spec guard, a final_result link, an end character that is replayed or
--- swallowed, and the undo-friendly net edit (the erased text is what was typed).
--- The same scenarios are pinned on Windows (test_hotstring_cascade.ahk) and
--- Linux (test_hotstring_cascade.lua).
--- ==============================================================================

local helpers = require("tests.helpers")

local _     = helpers.load_with_stubs("infra.logger")
local State = helpers.load_with_stubs("modules.keymap.state")

local STAR = "★"





-- =================================================
-- =================================================
-- ======= 1/ Harness: registry and expander =======
-- =================================================
-- =================================================

--- Builds a live registry + expander pair with the OS-facing collaborators stubbed
--- and the replacement transaction recorded.
--- @param entries table Array of { trigger, replacement, opts } entries.
--- @param depth number hotstrings.cascade_depth.
--- @return table state, table expander, table log
local function fresh_engine(entries, depth)
	package.loaded["ui.tooltip"]        = { hide = function() end, hide_forced = function() end }
	package.loaded["modules.keystats"] = {
		notify_synthetic = function() end,
		set_buffer       = function() end,
		log_hotstring    = function() end,
	}
	for name in pairs(package.loaded) do
		if type(name) == "string" and name:match("^modules%.keymap%.")
			and name ~= "modules.keymap.state" then
			package.loaded[name] = nil
		end
	end
	package.loaded["infra.text_utils"] = nil
	package.loaded["text_utils"]       = nil

	local R = require("modules.keymap.registry")
	local E = require("modules.keymap.expander")
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
	state.CASCADE_DEPTH = depth

	-- The transaction, as the engine builds it: how many characters it erases,
	-- what it types, and what it replays afterwards.
	local log = { transactions = {} }
	local typed
	local utils = require("modules.keymap.utils")
	utils.emit_text = function(text)
		typed = text
		return require("infra.text_utils").utf8_len(text), text, text
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

local CHAIN = {
	{ "chatg", "chatgpt" },
	{ "chatgpt", "ChatGPT", { is_case_sensitive = true } },
}





-- ====================================
-- ====================================
-- ======= 2/ The chain, driven =======
-- ====================================
-- ====================================

helpers.describe("keymap: the hotstring cascade", function()

	helpers.it("depth 0 is today's behaviour: the output is final", function()
		local state, expander, log = fresh_engine(CHAIN, 0)
		state.buffer = ""
		helpers.assert_true(type_string(state, expander, "chatg"), "chatg must fire")
		helpers.assert_eq("chatgpt", state.buffer, "the output waits for a keystroke at depth 0")
		helpers.assert_eq(1, #log.transactions, "one transaction")
		helpers.assert_eq("gpt", log.transactions[1].typed, "only the missing tail is typed")
	end)

	helpers.it("depth 1 completes the second hotstring in the same transaction", function()
		local state, expander, log = fresh_engine(CHAIN, 1)
		state.buffer = ""
		helpers.assert_true(type_string(state, expander, "chatg"), "chatg must fire")
		helpers.assert_eq("ChatGPT", state.buffer, "the buffer follows the chain")
		helpers.assert_eq(1, #log.transactions, "the chain goes out as ONE transaction")
		helpers.assert_eq("ChatGPT", log.transactions[1].typed, "the final text is typed")
		helpers.assert_eq(4, log.transactions[1].deletes,
			"the four characters of 'chat' already on screen are erased, the fifth was never shown")
	end)

	helpers.it("depth 1 stops after one more link, depth 2 goes on", function()
		local three = {
			{ "ab", "cd" },
			{ "cd", "ef" },
			{ "ef", "gh" },
		}
		local state, expander = fresh_engine(three, 1)
		state.buffer = ""
		type_string(state, expander, "ab")
		helpers.assert_eq("ef", state.buffer, "depth 1 allows exactly one more link")
		state, expander = fresh_engine(three, 2)
		state.buffer = ""
		type_string(state, expander, "ab")
		helpers.assert_eq("gh", state.buffer, "depth 2 allows two more links")
	end)

	helpers.it("a replacement that ends with its own trigger does not loop", function()
		local state, expander, log = fresh_engine({ { "ab", "xab" } }, 3)
		state.buffer = ""
		type_string(state, expander, "ab")
		helpers.assert_eq("xab", state.buffer, "the same spec never fires twice in one chain")
		helpers.assert_eq(1, #log.transactions)
	end)

	helpers.it("the guard folds case: the Title variant of the same rule is the same spec", function()
		local state, expander = fresh_engine({ { "ab", "xAB", { is_case_sensitive = true } } }, 3)
		state.buffer = ""
		type_string(state, expander, "ab")
		helpers.assert_eq("xAB", state.buffer, "AB is the rule that just fired, case aside")
	end)

	helpers.it("a final_result link ends the chain", function()
		local state, expander = fresh_engine({
			{ "ab", "cd", { final_result = true } },
			{ "cd", "ef" },
		}, 3)
		state.buffer = ""
		type_string(state, expander, "ab")
		helpers.assert_eq("cd", state.buffer, "nothing may chain off a final result")
	end)

	helpers.it("a link that is final ends it after itself", function()
		local state, expander, log = fresh_engine({
			{ "ab", "cd" },
			{ "cd", "ef", { final_result = true } },
			{ "ef", "gh" },
		}, 3)
		state.buffer = ""
		type_string(state, expander, "ab")
		helpers.assert_eq("ef", state.buffer, "cd fired, ef is final: gh never")
		helpers.assert_true(log.transactions[1].is_final, "the transaction is final")
	end)

	helpers.it("the second hotstring may reach back into the text typed before the first", function()
		local state, expander, log = fresh_engine({
			{ "ab", "cd" },
			{ "xcd", "YZ" },
		}, 1)
		state.buffer = "x"
		type_string(state, expander, "ab")
		helpers.assert_eq("YZ", state.buffer, "xcd is completed by the first output")
		helpers.assert_eq(2, log.transactions[1].deletes, "x and the shown a are erased")
		helpers.assert_eq("YZ", log.transactions[1].typed)
	end)

	helpers.it("a private link is never composed into another hotstring's output", function()
		local state, expander, log = fresh_engine({
			{ "ab", "cd" },
			{ "cd", "ef", { is_private = true } },
		}, 1)
		state.buffer = ""
		type_string(state, expander, "ab")
		helpers.assert_eq("cd", state.buffer, "the private link takes no part")
		helpers.assert_true(not log.transactions[1].is_private, "and the transaction stays the first one's")
	end)

	helpers.it("a private first hotstring starts no chain", function()
		local state, expander = fresh_engine({
			{ "ab", "cd", { is_private = true } },
			{ "cd", "ef" },
		}, 1)
		state.buffer = ""
		type_string(state, expander, "ab")
		helpers.assert_eq("cd", state.buffer)
	end)

end)





-- ======================================
-- ======================================
-- ======= 3/ End characters ===========
-- ======================================
-- ======================================

helpers.describe("keymap: the cascade and end characters", function()

	helpers.it("an auto link that stops before the replayed terminator waits for a key", function()
		local state, expander, log = fresh_engine({
			{ "ab", "cd", { auto_expand = false } },
			{ "cd", "ef" },
		}, 1)
		-- The buffer ends with the replayed space, so the auto link, whose trigger
		-- ends at "d", does not complete.
		state.buffer = "ab"
		helpers.assert_true(type_terminator(state, expander, " "), "ab+space must fire")
		helpers.assert_eq("cd ", state.buffer)
		helpers.assert_eq(" ", log.transactions[1].replay, "the space is replayed")
	end)

	helpers.it("an auto link whose trigger reaches the terminator swallows it", function()
		local state, expander, log = fresh_engine({
			{ "ab", "cd", { auto_expand = false } },
			{ "cd ", "X" },
		}, 1)
		state.buffer = "ab"
		helpers.assert_true(type_terminator(state, expander, " "), "ab+space must fire")
		helpers.assert_eq("X", state.buffer, "the space was part of the second trigger")
		helpers.assert_eq(nil, log.transactions[1].replay, "nothing is replayed after a swallowed terminator")
		helpers.assert_eq("X", log.transactions[1].typed)
		helpers.assert_eq(2, log.transactions[1].deletes, "only 'ab' is on screen: the space never was")
	end)

	helpers.it("an end-character hotstring cascades into another end-character one", function()
		local state, expander, log = fresh_engine({
			{ "ab", "cd", { auto_expand = false } },
			{ "cd", "ef", { auto_expand = false } },
		}, 1)
		state.buffer = "ab"
		helpers.assert_true(type_terminator(state, expander, " "), "ab+space must fire")
		helpers.assert_eq("ef ", state.buffer, "the same space ends the second link")
		helpers.assert_eq(1, #log.transactions, "one transaction")
		helpers.assert_eq("ef", log.transactions[1].typed, "the final text, without the replayed space")
		helpers.assert_eq(" ", log.transactions[1].replay, "the terminator is replayed once")
	end)

	helpers.it("depth 0 leaves the end-character chain to the next keystroke", function()
		local state, expander = fresh_engine({
			{ "ab", "cd", { auto_expand = false } },
			{ "cd", "ef", { auto_expand = false } },
		}, 0)
		state.buffer = "ab"
		type_terminator(state, expander, " ")
		helpers.assert_eq("cd ", state.buffer)
	end)

end)
