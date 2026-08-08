--- tests/unit/modules/dynamic_hotstrings/test_synth_echo_includes_tabs.lua

--- ==============================================================================
--- MODULE: Regression — multi-field @-expansion carries exact event provenance
--- DESCRIPTION:
--- Drives the real interceptor through @ p n ★, executes its production emitter
--- inside one real SyntheticInput replacement transaction, and inspects the
--- callback-return event table. Every field character and the inter-field Tab
--- must carry an owned tag from the same generation. The logical buffer remains
--- tab-free because Tab changes focus rather than inserting text.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Keycode of a plain letter: not escape/return/backspace/navigation, so the
-- interceptor treats these events as ordinary character input.
local KEYCODE_LETTER = 0

local FIRST_NAME = "Prénom"   -- deliberately accented: exercises the codepoint count
local LAST_NAME  = "Nom"


--- Writes a two-field personal_info.toml to a temp path so M.start() does not
--- materialise defaults into the user's config tree.
--- @return string The temp file path.
local function write_personal_info_toml()
	local path = os.tmpname()
	local fh = assert(io.open(path, "w"))
	fh:write(string.format(
		'[info]\nfirst_name = "%s"\nlast_name = "%s"\n\n[letters]\np = "first_name"\nn = "last_name"\n',
		FIRST_NAME, LAST_NAME))
	fh:close()
	return path
end

--- Builds a synthetic key event for the interceptor.
--- @param chars string The character produced.
--- @return table The fake event.
local function fake_event(chars)
	return {
		getFlags      = function() return {} end,
		getKeyCode    = function() return KEYCODE_LETTER end,
		getCharacters = function() return chars end,
	}
end

--- Loads personal_info and drives the real interceptor through "@pn★".
--- @return table captured Transaction output and inject_dynamic arguments.
local function drive_real_expansion()
	local PI = helpers.load_with_stubs("modules.dynamic_hotstrings.personal_info")
	local SyntheticInput = require("adapters.synthetic_input")

	local captured = {}
	local interceptor
	local fake_km = {
		register_interceptor      = function(fn) interceptor = fn end,
		register_preview_provider = function() end,
		inject_dynamic = function(n_back, result_text, emit_action, variant)
			captured.n_back      = n_back
			captured.result_text = result_text
			captured.variant     = variant

			SyntheticInput.enter_callback()
			local transaction = SyntheticInput.begin("test.personal", "replacement")
			local ok_emit, count_or_err, _, logical_text = pcall(function()
				return SyntheticInput.with_transaction(transaction, emit_action)
			end)
			if not ok_emit then
				pcall(SyntheticInput.cancel, transaction)
				SyntheticInput.abort_callback()
				error(count_or_err, 0)
			end
			local sealed = SyntheticInput.seal(transaction)
			local consume, events = SyntheticInput.leave_callback(sealed == true)
			captured.count              = count_or_err
			captured.logical_text       = logical_text
			captured.consume            = consume
			captured.events             = events or {}
			return true
		end,
		classify_trigger = function() return nil end,
	}

	local toml_path = write_personal_info_toml()
	PI.start("", fake_km, toml_path)
	PI.enable()
	os.remove(toml_path)

	helpers.assert_type(interceptor, "function", "personal_info must register its interceptor")

	-- "@" arms collection, "p" and "n" accumulate the combo, the trigger fires it.
	interceptor(fake_event("@"), "")
	interceptor(fake_event("p"), "@")
	interceptor(fake_event("n"), "@p")
	local verdict = interceptor(fake_event(PI.get_trigger_char()), "@pn")
	helpers.assert_eq(verdict, "consume", "the trigger keystroke must be consumed by the expansion")
	PI.stop()

	return captured, SyntheticInput
end


helpers.describe("multi-field @-expansion: exact transaction provenance", function()
	helpers.it("returns every field character and Tab in one owned generation", function()
		local captured, SyntheticInput = drive_real_expansion()
		local expected_pairs = utf8.len(FIRST_NAME) + 1 + utf8.len(LAST_NAME)
		helpers.assert_true(captured.consume)
		helpers.assert_eq(#captured.events, expected_pairs * 2,
			"each field character and the inter-field Tab must return one key pair")

		local property = hs.eventtap.event.properties.eventSourceUserData
		local generation = nil
		for index, event in ipairs(captured.events) do
			local metadata = SyntheticInput.lookup_tag(event:getProperty(property))
			helpers.assert_true(metadata and metadata.owned,
				"every returned event must carry an Ergopti-owned Quartz tag")
			helpers.assert_eq(metadata.owner, "test.personal")
			helpers.assert_eq(metadata.effect, "replacement")
			generation = generation or metadata.generation
			helpers.assert_eq(metadata.generation, generation,
				"field values and focus navigation must never split into sibling actions")
			helpers.assert_eq(metadata.ordinal, math.floor((index + 1) / 2))
			helpers.assert_eq(metadata.phase, event.isDown and "down" or "up")
		end
	end)

	helpers.it("emits a named Tab between the two Unicode field sequences", function()
		local captured = drive_real_expansion()
		local downs = {}
		for _, event in ipairs(captured.events) do
			if event.isDown then downs[#downs + 1] = event end
		end
		local first_len = utf8.len(FIRST_NAME)
		helpers.assert_eq(downs[first_len + 1].key, "tab",
			"the separator must be a focus-navigation key, not a literal tab character")
		local first, last = {}, {}
		for index = 1, first_len do first[#first + 1] = downs[index].unicode end
		for index = first_len + 2, #downs do last[#last + 1] = downs[index].unicode end
		helpers.assert_eq(table.concat(first), FIRST_NAME)
		helpers.assert_eq(table.concat(last), LAST_NAME)
		helpers.assert_eq(captured.count, #downs)
	end)

	helpers.it("keeps both logical result channels tab-free", function()
		local captured = drive_real_expansion()
		helpers.assert_type(captured.logical_text, "string", "the emitter must return logical text")
		helpers.assert_true(not captured.logical_text:find("\t", 1, true),
			"logical_text must stay tab-free — a Tab inserts no character on screen")
		helpers.assert_eq(captured.logical_text, FIRST_NAME .. LAST_NAME)
		helpers.assert_type(captured.result_text, "string")
		helpers.assert_true(not captured.result_text:find("\t", 1, true),
			"inject_dynamic's result_text seeds CoreState.buffer and must contain no tab")
		helpers.assert_eq(captured.result_text, FIRST_NAME .. LAST_NAME)
	end)
end)
