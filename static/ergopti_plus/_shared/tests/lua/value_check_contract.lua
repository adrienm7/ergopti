--- _shared/tests/lua/value_check_contract.lua

--- ==============================================================================
--- MODULE: User Value Check Contract
--- DESCRIPTION:
--- Replays value_check_vectors.json against the Lua value check, so the macOS
--- and Linux suites refuse the same stored values and the same typed text as
--- the canonical JS check and the AHK port, for the same reason. Also checks
--- that every declaration of value_schema.json is well formed.
--- ==============================================================================

local ValueCheck = require("settings.engine.value_check")
local M = {}

local VECTORS = "settings/data/value_schema/value_check_vectors.json"
local SCHEMA = "settings/data/value_schema/value_schema.json"
local SPECIAL = { nan = 0 / 0, inf = math.huge, ["-inf"] = -math.huge }

--- Decodes one JSON file through the driver's shared-root resolver.
--- @param shared_path function Driver resolver for a path under _shared/.
--- @param relative string Path under _shared/.
--- @return table
local function load_json(shared_path, relative)
	local file = assert(io.open(shared_path(relative), "rb"))
	local text = assert(file:read("*a")); assert(file:close())
	return assert(require("core.text.engine.json").decode(text))
end

--- Decodes the stored values JSON cannot spell, only for numeric declarations:
--- a string declaration keeps the text « nan » as text.
--- @param declaration table
--- @param value any
--- @return any
local function decode(declaration, value)
	if (declaration.type == "integer" or declaration.type == "decimal") and SPECIAL[value] ~= nil then
		return SPECIAL[value]
	end
	return value
end

--- Registers the vector replay and the schema shape checks.
--- @param helpers table Driver test API.
--- @param shared_path function Driver resolver for a path under _shared/.
function M.register(helpers, shared_path)
	local corpus = load_json(shared_path, VECTORS)
	assert(#corpus.stored >= 30 and #corpus.entry >= 25, "value check corpus lost its vectors")
	helpers.describe("value-check: shared vectors", function()
		for _, vector in ipairs(corpus.stored) do
			local row = vector
			helpers.it("value-check: stored " .. row.id, function()
				local declaration = corpus.declarations[row.declaration]
				local result = ValueCheck.check_value(declaration, decode(declaration, row.value))
				helpers.assert_eq(result.ok, row.ok)
				if not row.ok then helpers.assert_eq(result.reason, row.reason) end
			end)
		end
		for _, vector in ipairs(corpus.entry) do
			local row = vector
			helpers.it("value-check: entry " .. row.id, function()
				local result = ValueCheck.parse_entry(corpus.declarations[row.declaration], row.text)
				helpers.assert_eq(result.ok, row.ok)
				if row.ok then helpers.assert_eq(result.value, row.value) else helpers.assert_eq(result.reason, row.reason) end
				if row.min ~= nil then
					helpers.assert_eq(result.min, row.min)
					helpers.assert_eq(result.max, row.max)
				end
			end)
		end
		for _, vector in ipairs(corpus.messages) do
			local row = vector
			helpers.it("value-check: message " .. row.id, function()
				local declaration = corpus.declarations[row.declaration]
				local parts = ValueCheck.message_parts(declaration, ValueCheck.parse_entry(declaration, row.text))
				helpers.assert_eq(#parts, #row.parts)
				for index, expected in ipairs(row.parts) do
					helpers.assert_eq(parts[index].key, expected.key)
					helpers.assert_eq(#parts[index].args, #expected.args)
					for position, arg in ipairs(expected.args) do
						local actual = parts[index].args[position]
						if type(arg) == "table" then helpers.assert_eq(actual.key, arg.key) else helpers.assert_eq(actual, arg) end
					end
				end
			end)
		end
		helpers.it("value-check: a rendered message fills the bounds and the translated unit", function()
			local templates = {
				["dialog.value_check.range_integer_unit"] = "From {1} to {2} {3}.",
				["value_check.unit.ms"] = "ms",
				["dialog.value_check.range_integer"] = "From {1} to {2}.",
				["dialog.value_check.special"] = "{1} = {2}.",
				["value_check.special.no_time_limit"] = "no limit",
			}
			local translate = function(key) return templates[key] end
			local delay = corpus.declarations.delay_seconds
			helpers.assert_eq(ValueCheck.render_message(ValueCheck.message_parts(delay,
				ValueCheck.parse_entry(delay, "0")), translate), "From 1 to 10000 ms.")
			local timeout = corpus.declarations.timeout_ms
			helpers.assert_eq(ValueCheck.render_message(ValueCheck.message_parts(timeout,
				ValueCheck.parse_entry(timeout, "-3")), translate), "From 1 to 600000. 0 = no limit.")
			helpers.assert_eq(ValueCheck.format_number(0.001), "0.001")
			helpers.assert_eq(ValueCheck.format_number(2.0), "2")
		end)
		helpers.it("value-check: a refusal carries the declared bounds", function()
			local result = ValueCheck.check_value(corpus.declarations.timeout_ms, 600001)
			helpers.assert_eq(result.min, 1)
			helpers.assert_eq(result.max, 600000)
		end)
		helpers.it("value-check: the boundary raises with the setting name", function()
			local schema = { settings = { ["a.b"] = corpus.declarations.timeout_ms } }
			helpers.assert_eq(ValueCheck.require_value(schema, "a.b", 42), 42)
			local ok, message = pcall(ValueCheck.require_value, schema, "a.b", "42")
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(message):find("a.b refused (wrong_type)", 1, true) ~= nil, tostring(message))
		end)
		helpers.it("value-check: the generated key constants name declared settings", function()
			helpers.assert_eq(ValueCheck.KEY.TAP_HOLD_TIME_ACTIVATION_SECONDS, "tap_hold.time_activation_seconds")
			helpers.assert_eq(ValueCheck.KEY.TAP_HOLD_KEYS_ANY_TIME_ACTIVATION_SECONDS, "tap_hold.keys.*.time_activation_seconds")
			helpers.assert_eq(pcall(function() return ValueCheck.KEY.NO_SUCH_SETTING end), false)
			for _, key in pairs(require("settings.engine.value_schema_data").keys) do
				helpers.assert_eq(type(ValueCheck.declaration(key)), "table")
			end
		end)
		helpers.it("value-check: an unknown setting raises", function()
			local ok = pcall(ValueCheck.entry_for, { settings = {} }, "no.such")
			helpers.assert_eq(ok, false)
		end)
		helpers.it("value-check: a pattern key matches one segment", function()
			local schema = { settings = { ["hotstrings.*.delay"] = corpus.declarations.seconds } }
			helpers.assert_eq(ValueCheck.entry_for(schema, "hotstrings.rolls.delay"), corpus.declarations.seconds)
			helpers.assert_eq(pcall(ValueCheck.entry_for, schema, "hotstrings.a.b.delay"), false)
		end)
	end)
	helpers.describe("value-check: shared schema", function()
		helpers.it("value-check: every declaration of value_schema.json is complete", function()
			local schema = load_json(shared_path, SCHEMA)
			local count = 0
			for key, entry in pairs(schema.settings) do
				count = count + 1
				-- A refusal names the range, so a number declares both bounds.
				if entry.type == "integer" or entry.type == "decimal" then
					helpers.assert_true(type(entry.min) == "number" and type(entry.max) == "number",
						key .. " declares both bounds")
				end
				helpers.assert_eq(ValueCheck.entry_for(schema, key), entry)
			end
			helpers.assert_true(count > 0, "value_schema.json declares no setting")
		end)
		helpers.it("value-check: the gesture step coercer admits exactly the declared 1..60 mm", function()
			local Sensitivity = require("gestures.engine.sensitivity")
			helpers.assert_eq(Sensitivity.coerce(1), 1)
			helpers.assert_eq(Sensitivity.coerce(60), 60)
			-- A hand-edited text number keeps reading as before.
			helpers.assert_eq(Sensitivity.coerce("7.25"), 7.25)
			helpers.assert_eq(Sensitivity.coerce(0.5), nil)
			helpers.assert_eq(Sensitivity.coerce(61), nil)
			helpers.assert_eq(Sensitivity.coerce("fast"), nil)
			helpers.assert_eq(Sensitivity.coerce(0 / 0), nil)
		end)
	end)
end

return M
