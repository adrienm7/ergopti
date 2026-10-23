--- tests/unit/modules/keymap/test_time_gate_corpus.lua

--- ==============================================================================
--- MODULE: Expansion-delay corpus (time-gate-corpus)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/hotstrings/time_gate_vectors.json through the
--- macOS delay gate. The expansion delay is the time between the LAST LETTER OF
--- THE INPUT and the EXPANDER: the magic key when the trigger ends with it, else
--- the end character that completes the trigger. The keyDown tap measures the
--- time since the preceding physical key, which is that letter by construction;
--- the replay derives the elapsed time the same way and asks the shared delay
--- policy (CoreState.mapping_delay_remaining) for the verdict, so the rule
--- cannot drift from the Windows engine, which replays the same vectors.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_vectors()
	local fh = assert(io.open(helpers.shared("tests/corpus/hotstrings/time_gate_vectors.json"), "r"))
	local raw = fh:read("*a")
	fh:close()
	local ok, corpus = pcall(require("hs").json.decode, raw)
	assert(ok, "time-gate corpus is not valid JSON")
	return corpus.vectors
end

helpers.describe("expansion delay: the shared time-gate corpus", function()
	local State = helpers.load_with_stubs("modules.keymap.state")
	for _, vector in ipairs(read_vectors()) do
		helpers.it(vector.id .. " (time-gate-corpus)", function()
			local s = State.new({ expansion_delay = vector.delay_s }, {})
			local before_expander = vector.typed[#vector.typed]
			helpers.assert_eq(before_expander.char, vector.reference_char,
				"the reference is the character typed immediately before the expander")
			local elapsed_s = nil
			if not vector.reference_time_missing then
				local elapsed_ms = vector.expander.down_ms - before_expander.down_ms
				helpers.assert_eq(elapsed_ms, vector.elapsed_ms,
					"the preceding-key interval is the vector's elapsed time")
				elapsed_s = elapsed_ms / 1000
			end
			local allowed = s.mapping_delay_remaining({ has_magic = vector.ends_with_magic }, elapsed_s, 1)
			helpers.assert_eq(allowed, vector.fires, "the delay gate verdict")
		end)
	end
end)
