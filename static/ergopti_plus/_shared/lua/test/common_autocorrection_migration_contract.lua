--- _shared/lua/test/common_autocorrection_migration_contract.lua

--- ==============================================================================
--- MODULE: Common Autocorrection Independent Migration Contract
--- DESCRIPTION:
--- Pins conditional fan-out, original foreign bytes, explicit choices, strict
--- operation validation and acknowledged publication through the shared owner.
--- ==============================================================================

local M = {}
local Migration = require("hotstrings.common_autocorrection_migration")
local Engine = require("config_migrate")
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")

local function read(path)
	local handle = assert(io.open(path, "rb"))
	local content = assert(handle:read("*a")); assert(handle:close())
	return content
end

--- Register the same immutable input/output contract in both native suites.
--- @param helpers table Native test harness.
--- @param shared function Shared-tree path resolver.
function M.register(helpers, shared)
	require("test.publication_recovery_contract").register(helpers)
	local policy_path = shared(Migration.POLICY_PATH)
	local operations = Codec.decode(read(policy_path)).migration.ops
	local input = read(shared("tests/corpus/common_autocorrection_migration/input.toml"))
	local expected = read(shared("tests/corpus/common_autocorrection_migration/expected.toml"))
	helpers.describe("common autocorrection independent override migration", function()
		helpers.it("(common-autocorrection-split) preserves every independently authored foreign byte and explicit new choice", function()
			local plan = Migration.plan(input, operations)
			helpers.assert_eq(plan.outcome, "migrated", tostring(plan.detail))
			helpers.assert_eq(plan.candidate, expected)
			helpers.assert_eq(Migration.plan(expected, operations).outcome, "current")
			helpers.assert_eq(Migration.plan(expected, operations).candidate, expected)
			helpers.assert_nil(Codec.decode(plan.candidate)._meta, "independent override migration never stamps config metadata")
		end)
		helpers.it("(common-autocorrection-split) keeps occupied ancestor and descendant namespaces", function()
			local source = '[autocorrection]\nnames = { delay = 0.2, future = true }\n'
				.. '[autocorrection.caps]\ndelay = 0.875\n'
				.. '[autocorrection.abbreviations.delay]\nowned = "future"\n'
			local plan = Migration.plan(source, operations)
			helpers.assert_eq(plan.outcome, "migrated", tostring(plan.detail))
			local document = Codec.decode(plan.candidate)
			helpers.assert_eq(document.autocorrection.names, { delay = 0.2, future = true })
			helpers.assert_eq(document.autocorrection.abbreviations.delay, { owned = "future" })
			helpers.assert_eq(document.autocorrection.technical_terms.delay, 0.875)
		end)
		helpers.it("(common-autocorrection-split) refuses unaddressable legacy inline records and malformed operations", function()
			helpers.assert_eq(Migration.plan('[autocorrection]\ncaps = { delay = 0.3 }\n', operations).outcome, "failed")
			for _, invalid in ipairs({ false, { { op = "missing" } }, { { op = "delete", section = "autocorrection", surprise = true } } }) do
				helpers.assert_eq(Engine.plan_operations(input, invalid).outcome, "failed")
			end
		end)
		helpers.it("(common-autocorrection-split) delegates quoted comment identity to the canonical codec", function()
			for _, case in ipairs({
				{ 'color = "#abcdef" # external notes', 'color = "#abcdef" ' },
				{ "text = 'literal # value' # external notes", "text = 'literal # value' " },
				{ '[autocorrection.names] # header notes', '[autocorrection.names] ' },
				{ 'text = "escaped \\" # retained inside" # removed outside', 'text = "escaped \\" # retained inside" ' },
			}) do
				helpers.assert_eq(Codec.strip_inline_comment(case[1]), case[2])
			end
			local accepted = pcall(Codec.strip_inline_comment, false)
			helpers.assert_true(not accepted)
			accepted = pcall(Codec.strip_inline_comment, "two\nlines")
			helpers.assert_true(not accepted)
		end)
		helpers.it("(common-autocorrection-split) leaves absent sources absent and requires native publication acknowledgement", function()
			local path = os.tmpname(); os.remove(path)
			helpers.assert_eq(Migration.run(path, policy_path).status, "absent")
			local handle = io.open(path, "r"); helpers.assert_nil(handle)
			local handle = assert(io.open(path, "wb")); assert(handle:write(input)); assert(handle:close())
			local original = Writer.publish_if_unchanged
			local ok, detail = pcall(function()
				Writer.publish_if_unchanged = function(target, candidate, adapter, snapshot)
					helpers.assert_eq(target, path)
					helpers.assert_eq(candidate, expected)
					helpers.assert_eq(snapshot, { status = "ok", content = input })
					return false, "independent native refusal"
				end
				helpers.assert_eq(Migration.run(path, policy_path).status, "failed")
				helpers.assert_eq(read(path), input, "publication refusal preserves all source bytes")
				Writer.publish_if_unchanged = original
				helpers.assert_eq(Migration.run(path, policy_path).status, "migrated")
				helpers.assert_eq(read(path), expected)
				helpers.assert_eq(Migration.run(path, policy_path).status, "current")
			end)
			Writer.publish_if_unchanged = original; os.remove(path)
			if not ok then error(detail) end
		end)
		helpers.it("(common-autocorrection-split) the actual conditional publisher preserves an intervening external replacement", function()
			local path = os.tmpname()
			local handle = assert(io.open(path, "wb")); assert(handle:write(input)); assert(handle:close())
			local original = Writer.publish_if_unchanged
			local external = '# independent intervening writer\n[autocorrection.names]\ndelay = 0.65\n'
			local ok, detail = pcall(function()
				Writer.publish_if_unchanged = function(target, candidate, adapter, snapshot)
					local changed = assert(io.open(target, "wb")); assert(changed:write(external)); assert(changed:close())
					return original(target, candidate, adapter, snapshot)
				end
				helpers.assert_eq(Migration.run(path, policy_path).status, "failed")
				helpers.assert_eq(read(path), external, "stale migration never replaces the external writer's exact bytes")
			end)
			Writer.publish_if_unchanged = original; os.remove(path)
			if not ok then error(detail) end
		end)
	end)
end

return M
