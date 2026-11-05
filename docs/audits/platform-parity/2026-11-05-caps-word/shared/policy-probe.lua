-- Retained CapsWord shared-policy audit: actual corpus owner and boundary probes.
local root = assert(arg[1], "Pass repository root")
package.path = root .. "/static/ergopti_plus/_shared/lua/?.lua;"
	.. root .. "/static/ergopti_plus/_shared/lua/?/init.lua;" .. package.path
local Policy = require("caps_word.auto_off")
local Json = require("json")
local function read(path)
	local file = assert(io.open(path, "rb"))
	local bytes = file:read("*a")
	assert(file:close())
	return bytes
end
local corpus = Json.decode(read(root .. "/static/ergopti_plus/_shared/tests/corpus/caps_word/auto_off_vectors.json"))
local assertions, registered = 0, 0
local function eq(actual, expected, message)
	assertions = assertions + 1
	assert(actual == expected, (message or "value") .. ": actual=" .. tostring(actual) .. ", expected=" .. tostring(expected))
end
local helpers = {
	describe = function(_, callback) callback() end,
	it = function(name, callback) registered = registered + 1; callback(); print("corpus " .. name) end,
	assert_eq = eq,
	assert_nil = function(value, message) eq(value, nil, message) end,
	assert_type = function(value, wanted, message) eq(type(value), wanted, message) end,
	assert_true = function(value, message) eq(value, true, message) end,
}
require("test.caps_word_auto_off_contract").run(helpers,
	root .. "/static/ergopti_plus/_shared/tests/corpus/caps_word/auto_off_vectors.json")
local corpus_assertions = assertions
local function compile(idle, terms)
	return assert(Policy.compile({ idle_timeout_seconds = idle, terminators = terms or {},
		pointer = corpus.pointer_sets.all_false }, corpus.pointer_kinds))
end
local rows = {}
for _, row in ipairs({
	{ seconds = 0, milliseconds = false, expires = false },
	{ seconds = 0.0001, milliseconds = 0, expires = true },
	{ seconds = 0.00049, milliseconds = 0, expires = true },
	{ seconds = 0.0005, milliseconds = 1, expires = false },
	{ seconds = 0.001, milliseconds = 1, expires = false },
	{ seconds = 2.5, milliseconds = 2500, expires = false },
}) do
	local valid = Policy.validate_idle_timeout(row.seconds)
	eq(valid, true, "fraction is accepted")
	local p = compile(row.seconds)
	local delay = Policy.idle_delay_ms(p)
	if row.milliseconds == 1 then eq(Policy.idle_expired(p, 100, 101), true, "one millisecond boundary expires exactly") end
	eq(delay or false, row.milliseconds, "exact quantized delay")
	eq(Policy.idle_expired(p, 100, 100), row.expires, "expiry at activation time")
	rows[#rows + 1] = { seconds = row.seconds, delay = delay or "disabled",
		expires_at_activation = Policy.idle_expired(p, 100, 100) }
end
for _, invalid in ipairs({ -1, math.huge, -math.huge, "0.0001", false }) do
	eq(Policy.validate_idle_timeout(invalid), false, "malformed nonnegative delay refused")
end
eq(Policy.validate_idle_timeout(0 / 0), false, "NaN refused")
local huge_finite = 1e308
eq(Policy.validate_idle_timeout(huge_finite), true, "finite upper edge is accepted")
local huge_policy = compile(huge_finite)
eq(Policy.idle_delay_ms(huge_policy), math.huge, "finite seconds overflow millisecond conversion")
eq(Policy.idle_expired(huge_policy, 0, 1e308), false, "overflowed policy does not expire at finite clocks")
local independent = {
	{ terms = { "nnbsp" }, text = "ab😀 ?xy", expected = true },
	{ terms = { "nbsp" }, text = "ab😀 ?xy", expected = false },
	{ terms = { "space" }, text = "AB CD", expected = true },
	{ terms = { "enter" }, text = "\r\n", expected = true },
	{ terms = { "comma" }, text = "a,b", expected = true },
	{ terms = { "comma" }, text = "A.B", expected = false },
	{ terms = { "star" }, text = "★", expected = true },
	{ terms = { "star" }, text = "§", expected = false },
}
for _, row in ipairs(independent) do
	eq(Policy.ends_on_text(compile(0, row.terms), row.text), row.expected, "independent mixed scalar control")
end
local catalogue = require("keymap.terminators_catalogue")
local checked, catalogue_characters = {}, 0
for _, def in ipairs(catalogue) do
	if def.key and not def.custom then
		checked[#checked + 1] = def.key
		local p = compile(0, { def.key })
		for _, char in ipairs(def.chars) do
			catalogue_characters = catalogue_characters + 1
			eq(Policy.ends_on_text(p, char), true, "each catalogue character is selectable")
			eq(Policy.ends_on_text(compile(0, {}), char), false, "each catalogue character can be unchecked")
		end
		eq(Policy.ends_on_key(p, def.key), true, "each native semantic key can be selected")
	end
end
-- Explicit exclusions: custom hotstring delimiters are not CapsWord choices.
local before = #Policy.terminator_rows()
catalogue[#catalogue + 1] = { key = "custom_audit", chars = { "µ" }, custom = true, label = "µ" }
eq(#Policy.terminator_rows(), before, "custom delimiter remains excluded")
eq(Policy.is_terminator_key("custom_audit"), false, "custom delimiter cannot be compiled")
catalogue[#catalogue] = nil
local output = {
	registered_corpus_cases = registered,
	registered_corpus_assertions = corpus_assertions,
	extended_assertions = assertions - corpus_assertions,
	total_assertions = assertions,
	catalogue_keys = #checked,
	catalogue_characters = catalogue_characters,
	fractional_idle = rows,
	finite_upper_edge = { accepted_seconds = "1e308", compiled_milliseconds = "positive infinity", finite_clock_expired = false, qualification = "Shared policy only; no actual timer admission or AHK arithmetic execution." },
	qualification = "Actual shared Lua policy and actual registered corpus owner; no AHK execution, native timer, compositor or keyboard receiving.",
}
print(Json.encode(output))
