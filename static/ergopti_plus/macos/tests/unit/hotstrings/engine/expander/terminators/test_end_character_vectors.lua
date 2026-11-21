--- tests/unit/hotstrings/engine/expander/terminators/test_end_character_vectors.lua

--- ==============================================================================
--- MODULE: End-Character Corpus (hcd-2-bare-colon)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/hotstrings/end_character_vectors.json through
--- the macOS registry and expander: the end-character path asks
--- try_terminator_expand, which owns the French spacing strip, and the auto
--- path try_auto_expand. A bare ":" or ";" ends a trigger on the three OS
--- (maintainer decision HCD-2, 2026-11-21); macOS has done so since 2026-11-04,
--- and the shared engine and Windows replay the same vectors.
--- ==============================================================================

local helpers = require("tests.helpers")

local _     = helpers.load_with_stubs("core.logger.engine.logger")
local State = helpers.load_with_stubs("hotstrings.engine.expander.state")

--- Reads the shared vectors.
--- @return table
local function read_vectors()
	local fh = assert(io.open(helpers.shared("tests/corpus/hotstrings/end_character_vectors.json"), "r"))
	local raw = fh:read("*a")
	fh:close()
	local ok, corpus = pcall(require("hs").json.decode, raw)
	assert(ok, "end-character corpus is not valid JSON")
	return corpus.vectors
end

--- Builds a live registry + expander pair recording each replacement.
--- @param mappings table The vector's mappings.
--- @return table state, table expander, table log
local function fresh_engine(mappings)
	package.loaded["core.ui.ui.tooltip"] = { hide = function() end, hide_forced = function() end }
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
	local R = require("hotstrings.engine.expander.registry")
	local E = require("hotstrings.engine.expander.expander")
	local state = State.new({ trigger_char = "★", expansion_delay = 0.4 }, {})
	R.init(state)
	E.init(state, R, {
		update_preview  = function() end,
		get_llm_enabled = function() return false end,
		start_timer     = function() end,
	})
	for _, m in ipairs(mappings) do
		R.add(m.trigger, m.replacement, { auto_expand = m.auto_expand == true })
	end
	R.sort_mappings()
	state.start_is_word_boundary = true
	state.CASCADE_MAX_ARROWS = 1
	local log = {}
	local typed
	local utils = require("hotstrings.engine.expander.utils")
	utils.emit_text = function(text)
		typed = text
		return require("core.text.engine.utils").utf8_len(text), text, text
	end
	E.perform_text_replacement = function(_deletes, emit_action, buffer_action)
		typed = nil
		emit_action()
		buffer_action()
		log[#log + 1] = typed
		return true
	end
	return state, E, log
end

--- Types one character: an end character asks every end-character mapping,
--- any other character every auto mapping, as run_trigger_checks does.
--- @return boolean fired
local function type_char(state, expander, registry, char)
	state.buffer = state.buffer .. char
	if registry.is_terminator(char) then
		for _, mapping in ipairs(state.mappings) do
			if not mapping.auto and expander.try_terminator_expand(mapping, char, 1, false) == true then
				return true
			end
		end
	end
	for _, mapping in ipairs(state.mappings) do
		if mapping.auto and expander.try_auto_expand(mapping, 1, false) == true then return true end
	end
	return false
end

helpers.describe("end characters: the shared corpus (hcd-2-bare-colon)", function()
	for _, vector in ipairs(read_vectors()) do
		helpers.it(vector.id .. " (hcd-2-bare-colon)", function()
			local state, expander, log = fresh_engine(vector.mappings)
			local registry = require("hotstrings.engine.expander.registry")
			local fired = false
			for index, char in ipairs(vector.typed) do
				fired = type_char(state, expander, registry, char)
				if index < #vector.typed then
					helpers.assert_true(not fired, "only the last character may fire")
				end
			end
			helpers.assert_eq(vector.expected.fires == true, fired, "whether the last character fires")
			if vector.expected.fires then
				helpers.assert_eq(vector.expected.replacement, log[1], "the typed replacement")
			end
		end)
	end
end)
