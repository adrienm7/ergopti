--- _shared/lua/test/caps_word_auto_off_contract.lua

--- ==============================================================================
--- MODULE: CapsWord Auto-Off Policy Contract
--- DESCRIPTION:
--- Replays the hand-written CapsWord auto-off vectors against the shared
--- policy, so the macOS and Linux suites hold the same rule as the AHK port.
--- Native detection, timers and the deactivation remain adapter-owned.
--- ==============================================================================

local M = {}
local Policy = require("caps_word.auto_off")
local Json = require("json")

--- Registers the compile, delimiter, key, pointer, delay and menu vectors.
--- @param helpers table Driver assertions and case registration.
--- @param corpus_path string Canonical shared corpus path.
function M.run(helpers, corpus_path)
	local file = assert(io.open(corpus_path, "rb"))
	local content = file:read("*a")
	assert(file:close())
	local corpus = Json.decode(content)
	local kinds = corpus.pointer_kinds

	local function compile(idle, terminators, pointer_set)
		return Policy.compile({
			idle_timeout_seconds = idle,
			terminators = terminators,
			pointer = corpus.pointer_sets[pointer_set],
		}, kinds)
	end

	helpers.describe("Shared CapsWord auto-off policy", function()
		helpers.it("compiles valid settings and refuses each malformed one by name", function()
			helpers.assert_eq(#corpus.compile, 13, "complete compile vectors")
			for _, row in ipairs(corpus.compile) do
				local policy, reason = compile(row.idle, row.terminators, row.pointer)
				if row.valid then
					helpers.assert_type(policy, "table", row.name)
					-- 0 in the corpus: the policy never times out.
					local expected_ms = row.idle_ms > 0 and row.idle_ms or nil
					helpers.assert_eq(Policy.idle_delay_ms(policy), expected_ms, row.name .. " delay")
				else
					helpers.assert_nil(policy, row.name)
					helpers.assert_eq(reason, row.reason, row.name .. " reason")
				end
			end
			helpers.assert_nil(Policy.compile({ idle_timeout_seconds = 0, terminators = {},
				pointer = corpus.pointer_sets.all_true }, {}), "no declared pointer kind")
			helpers.assert_nil(Policy.compile(nil, kinds), "no settings")
		end)

		helpers.it("ends CapsWord on a typed payload only through a checked delimiter", function()
			helpers.assert_eq(#corpus.text, 26, "complete text vectors")
			for _, row in ipairs(corpus.text) do
				local policy = assert(compile(0, row.terminators, "all_true"))
				helpers.assert_eq(Policy.ends_on_text(policy, row.text), row.expected,
					string.format("%q with %s", row.text, table.concat(row.terminators, ",")))
			end
		end)

		helpers.it("answers native key bindings by delimiter key and refuses unknown keys", function()
			for _, row in ipairs(corpus.keys) do
				local policy = assert(compile(0, row.terminators, "all_true"))
				helpers.assert_eq(Policy.ends_on_key(policy, row.key), row.expected, row.key)
			end
			local policy = assert(compile(0, { "space" }, "all_true"))
			for _, key in ipairs(corpus.unknown_keys) do
				helpers.assert_eq(pcall(Policy.ends_on_key, policy, key), false, "unknown key " .. key)
			end
		end)

		helpers.it("answers pointer kinds and refuses undeclared ones", function()
			for _, row in ipairs(corpus.pointer) do
				local policy = assert(compile(0, {}, row.pointer))
				helpers.assert_eq(Policy.ends_on_pointer(policy, row.kind), row.expected,
					row.pointer .. ":" .. row.kind)
			end
			local policy = assert(compile(0, {}, "all_true"))
			for _, kind in ipairs(corpus.unknown_kinds) do
				helpers.assert_eq(pcall(Policy.ends_on_pointer, policy, kind), false, "unknown kind " .. kind)
			end
		end)

		helpers.it("expires only after the whole delay and never at 0", function()
			for _, row in ipairs(corpus.idle) do
				local policy = assert(compile(row.idle, {}, "all_true"))
				helpers.assert_eq(Policy.idle_expired(policy, row.last, row.now), row.expected,
					string.format("%s s from %d to %d", tostring(row.idle), row.last, row.now))
			end
		end)

		helpers.it("stores a checkbox change in catalogue order and refuses invalid ones", function()
			for _, row in ipairs(corpus.with_terminator) do
				local out = Policy.with_terminator(row.list, row.key, row.checked)
				helpers.assert_eq(table.concat(out, ","), table.concat(row.expected, ","), row.key)
			end
			for _, row in ipairs(corpus.with_terminator_refusals) do
				local out, reason = Policy.with_terminator(row.list, row.key, row.checked)
				helpers.assert_nil(out, row.reason)
				helpers.assert_eq(reason, row.reason, row.reason)
			end
		end)

		helpers.it("draws the delimiter rows from the catalogue, separators included", function()
			local drawn = {}
			for _, row in ipairs(Policy.terminator_rows()) do
				drawn[#drawn + 1] = row.separator and "-" or row.key
				if not row.separator then
					helpers.assert_eq(row.label_key, "terminators.label_" .. row.key, row.key .. " label")
				end
			end
			helpers.assert_eq(table.concat(drawn, ","), table.concat(corpus.terminator_rows, ","),
				"catalogue order")
		end)
	end)
end

return M
