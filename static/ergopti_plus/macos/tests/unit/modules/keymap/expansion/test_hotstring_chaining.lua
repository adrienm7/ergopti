--- tests/unit/modules/keymap/expansion/test_hotstring_chaining.lua

--- ==============================================================================
--- MODULE: Hotstring Chaining (macOS)
--- DESCRIPTION:
--- The engine's matching buffer follows the screen, so the text an expansion
--- produced takes part in the next match: "ab" gives "cd" and "cde" gives "xyz",
--- hence typing "abe" gives "xyz"; "at★" gives "att", "att★" gives "attention"
--- and "attention★" gives a warning sign. Only a typed keystroke completes a
--- trigger: a trigger wholly inside an expansion's output fires nothing alone, so
--- no loop is possible. The same examples are pinned on Windows
--- (test_hotstring_chaining.ahk) and Linux (test_shared_hotstring_engine.lua).
--- ==============================================================================

local helpers = require("tests.helpers")

local _     = helpers.load_with_stubs("infra.logger")
local State = helpers.load_with_stubs("modules.keymap.state")

local STAR = "★"
local SIGN = "\u{26A0}\u{FE0F}"





-- =================================================
-- =================================================
-- ======= 1/ Harness: registry and expander =======
-- =================================================
-- =================================================

--- Builds a live registry + expander pair with the OS-facing collaborators stubbed.
--- @param entries table Array of { trigger, replacement } star (auto) entries.
--- @return table state, table expander
local function fresh_engine(entries)
	package.loaded["ui.tooltip"]        = { hide = function() end, hide_forced = function() end }
	package.loaded["modules.keystats"] = {
		notify_synthetic = function() end,
		set_buffer       = function() end,
		log_hotstring    = function() end,
	}
	-- Every keymap module keeps the state it was initialised with and refuses a
	-- different one, so a fresh engine needs a fresh copy of each of them.
	for name in pairs(package.loaded) do
		if type(name) == "string" and name:match("^modules%.keymap%.")
			and name ~= "modules.keymap.state" then
			package.loaded[name] = nil
		end
	end
	package.loaded["infra.text_utils"]           = nil
	package.loaded["text_utils"]                 = nil

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
		R.add(entry[1], entry[2], { auto_expand = true })
	end
	R.sort_mappings()
	state.start_is_word_boundary = true
	return state, E
end

--- Types one character the way the tap does: it joins the buffer, then the entry
--- whose trigger ends the buffer is fired.
--- @return boolean fired
local function type_char(state, expander, char)
	state.buffer = state.buffer .. char
	for _, mapping in ipairs(state.mappings) do
		local trigger = mapping.trigger
		if #state.buffer >= #trigger and state.buffer:sub(-#trigger) == trigger then
			if expander.try_auto_expand(mapping, 1, false) == true then return true end
		end
	end
	return false
end





-- ====================================
-- ====================================
-- ======= 2/ The chain, driven =======
-- ====================================
-- ====================================

helpers.describe("keymap: an expansion's output joins the next match", function()

	helpers.it("ab gives cd and cde gives xyz, so abe gives xyz", function()
		local state, expander = fresh_engine({ { "ab", "cd" }, { "cde", "xyz" } })
		state.buffer = ""
		helpers.assert_true(not type_char(state, expander, "a"), "a alone fires nothing")
		helpers.assert_true(type_char(state, expander, "b"), "ab must fire")
		helpers.assert_eq("cd", state.buffer, "the buffer must hold the output")
		helpers.assert_true(type_char(state, expander, "e"), "the typed e must complete cde from the output")
		helpers.assert_eq("xyz", state.buffer, "the buffer must follow the second expansion")
	end)

	helpers.it("at, att and attention chain through three magic keys", function()
		local state, expander = fresh_engine({
			{ "at" .. STAR, "att" },
			{ "att" .. STAR, "attention" },
			{ "attention" .. STAR, SIGN },
		})
		state.buffer = ""
		for _, char in ipairs({ "a", "t" }) do type_char(state, expander, char) end
		for _ = 1, 3 do
			helpers.assert_true(type_char(state, expander, STAR), "each magic key must complete the next trigger")
		end
		helpers.assert_eq(SIGN, state.buffer, "three magic keys after at must end on the sign")
	end)

	helpers.it("an output that holds a whole trigger fires nothing alone", function()
		local state, expander = fresh_engine({ { "ab", "cde" }, { "cde", "xyz" } })
		state.buffer = ""
		type_char(state, expander, "a")
		helpers.assert_true(type_char(state, expander, "b"), "ab must fire")
		helpers.assert_eq("cde", state.buffer,
			"the trigger inside the output must wait for a keystroke: no loop is possible")
	end)

end)
