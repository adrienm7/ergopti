--- tests/unit/platform/remap/generator_managed_lease/test_publication.lua

--- ==============================================================================
--- MODULE: Managed Lease Generator Publication
--- DESCRIPTION:
--- Verifies exact ownership and non-destructive generation with isolated fixtures.
--- ==============================================================================

local helpers = require("tests.helpers")
local support = require("tests.support.generator_managed_lease_fixture")
local TOKEN = support.TOKEN
local managed_rule = support.managed_rule
local personal_rule = support.personal_rule
local generated_config = support.generated_config
local with_fixture = support.with_fixture

helpers.describe("Karabiner generator publication uses the proven filesystem writer", function()

	local function selected_rules(encoded)
		local decoded = _G.hs.json.decode(encoded)
		for _, profile in ipairs(decoded.profiles or {}) do
			if profile.selected == true then
				return profile.complex_modifications and profile.complex_modifications.rules or {}
			end
		end
		return {}
	end

	helpers.it("re-reads, preserves personal rules, and publishes exactly once", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local incoming = generated_config({ managed_rule(TOKEN, "normal", "current") })
			local path = "/merge/publish.json"
			fixture.file_data[path] = _G.hs.json.encode({
				profiles = {
					{
						name = "Personal",
						selected = true,
						complex_modifications = { rules = { personal_rule("keep me") } },
					},
				},
			})
			fixture.file_writes = {}
			fixture.file_reads = {}
			fixture.parent_prepare_calls = {}
			fixture.write_succeeds = true
			fixture.before_publication = nil

			local ok, detail, attempts = Generator.merge_and_deploy_config(incoming, path)
			helpers.assert_true(ok, tostring(detail))
			helpers.assert_eq(attempts, 1)
			helpers.assert_eq(#fixture.parent_prepare_calls, 1)
			helpers.assert_eq(fixture.parent_prepare_calls[1], path)
			helpers.assert_eq(#fixture.file_reads, 1, "publication must merge from one exact post-preparation read")
			helpers.assert_eq(#fixture.file_writes, 1)
			helpers.assert_eq(fixture.file_writes[1].path, path)
			helpers.assert_eq(fixture.file_writes[1].method, "write_if_unchanged")
			local rules = selected_rules(fixture.file_writes[1].content)
			helpers.assert_eq(#rules, 2)
			helpers.assert_eq(rules[1].description, "keep me")
			helpers.assert_true(rules[2].description:find("[ErgoptiPlus managed:", 1, true) == 1)
		end)
	end)

	helpers.it("skips a semantically unchanged publication after exact revalidation", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local incoming = generated_config({ managed_rule(TOKEN, "normal", "current") })
			local path = "/merge/publish-unchanged.json"
			fixture.file_data[path] = _G.hs.json.encode({
				profiles = {
					{
						name = "Personal",
						selected = true,
						complex_modifications = { rules = { personal_rule("keep me") } },
					},
				},
			})
			fixture.file_writes = {}
			fixture.file_reads = {}
			fixture.parent_prepare_calls = {}
			fixture.write_succeeds = true
			fixture.before_publication = nil

			local first_ok, first_detail = Generator.merge_and_deploy_config(incoming, path)
			helpers.assert_true(first_ok, tostring(first_detail))
			helpers.assert_eq(#fixture.file_writes, 1,
				"the fixture must first publish the managed block")
			local published_bytes = fixture.file_data[path]
			fixture.file_writes = {}
			fixture.file_reads = {}

			local ok, detail, attempts = Generator.merge_and_deploy_config(incoming, path)

			helpers.assert_true(ok, tostring(detail))
			helpers.assert_eq(detail, "unchanged")
			helpers.assert_eq(attempts, 0,
				"an unchanged merge must make no publication attempt")
			helpers.assert_eq(#fixture.file_reads, 2,
				"the unchanged decision must revalidate the exact source snapshot")
			helpers.assert_eq(#fixture.file_writes, 0,
				"a semantic no-op must not rewrite karabiner.json")
			helpers.assert_eq(fixture.file_data[path], published_bytes,
				"the deployed bytes must remain untouched")
		end)
	end)

	helpers.it("refuses an unchanged verdict after the exact source moves", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local incoming = generated_config({ managed_rule(TOKEN, "normal", "current") })
			local path = "/merge/publish-unchanged-race.json"
			fixture.file_data[path] = _G.hs.json.encode({
				profiles = {
					{
						name = "Personal",
						selected = true,
						complex_modifications = { rules = { personal_rule("keep me") } },
					},
				},
			})
			fixture.file_writes = {}
			fixture.file_reads = {}
			fixture.parent_prepare_calls = {}
			fixture.write_succeeds = true
			fixture.before_read = nil
			fixture.before_publication = nil

			local first_ok, first_detail = Generator.merge_and_deploy_config(incoming, path)
			helpers.assert_true(first_ok, tostring(first_detail))
			local foreign_bytes = _G.hs.json.encode({
				profiles = {
					{
						name = "Personal",
						selected = true,
						complex_modifications = { rules = { personal_rule("foreign winner") } },
					},
				},
			})
			fixture.file_writes = {}
			fixture.file_reads = {}
			fixture.before_read = function(read_path, read_number)
				helpers.assert_eq(read_path, path)
				if read_number == 2 then fixture.file_data[path] = foreign_bytes end
			end

			local ok, detail, attempts = Generator.merge_and_deploy_config(incoming, path)
			fixture.before_read = nil

			helpers.assert_eq(ok, false,
				"a moved source must never be reported as unchanged")
			helpers.assert_true(type(detail) == "string"
				and detail:find("source changed", 1, true) ~= nil,
				"the exact-source conflict must be surfaced")
			helpers.assert_eq(attempts, 0,
				"a no-op revalidation conflict must not enter publication")
			helpers.assert_eq(#fixture.file_reads, 2,
				"the source change must be observed by the second exact read")
			helpers.assert_eq(#fixture.file_writes, 0,
				"a no-op conflict must never call the writer")
			helpers.assert_eq(fixture.file_data[path], foreign_bytes,
				"the foreign winner's exact bytes must survive")
		end)
	end)

	helpers.it("prepares a missing parent before the exact absent read and publishes once", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local incoming = generated_config({ managed_rule(TOKEN, "normal", "current") })
			local path = "/merge/fresh-parent/karabiner.json"
			fixture.file_data[path] = nil
			fixture.missing_parent_paths[path] = true
			fixture.parent_prepare_failures[path] = nil
			fixture.file_writes = {}
			fixture.file_reads = {}
			fixture.parent_prepare_calls = {}
			fixture.write_succeeds = true
			fixture.before_publication = nil

			local ok, detail, attempts = Generator.merge_and_deploy_config(incoming, path)

			helpers.assert_true(ok, tostring(detail))
			helpers.assert_eq(attempts, 1)
			helpers.assert_eq(#fixture.parent_prepare_calls, 1,
				"the parent must be prepared exactly once before source classification")
			helpers.assert_eq(fixture.parent_prepare_calls[1], path)
			helpers.assert_eq(#fixture.file_reads, 1, "the prepared path must be classified exactly once for the merge")
			helpers.assert_eq(fixture.file_reads[1], path)
			helpers.assert_eq(#fixture.file_writes, 1, "fresh publication must use one conditional write")
			helpers.assert_eq(fixture.file_writes[1].method, "write_if_unchanged")
			helpers.assert_eq(fixture.file_writes[1].expected_source.status, "absent")
		end)
	end)

	helpers.it("fails closed when safe parent preparation reports permission or symlink failure", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local incoming = generated_config({ managed_rule(TOKEN, "normal", "current") })
			local cases = {
				{ suffix = "permission", detail = "mkdir refused: Permission denied" },
				{ suffix = "symlink", detail = "symlink target changed before preparation" },
			}
			for _, case in ipairs(cases) do
				local path = "/merge/unsafe-" .. case.suffix .. "/karabiner.json"
				fixture.file_data[path] = nil
				fixture.missing_parent_paths[path] = true
				fixture.parent_prepare_failures[path] = case.detail
				fixture.file_writes = {}
				fixture.file_reads = {}
				fixture.parent_prepare_calls = {}
				fixture.write_succeeds = true
				fixture.before_publication = nil

				local ok, detail, attempts = Generator.merge_and_deploy_config(incoming, path)

				helpers.assert_eq(ok, false)
				helpers.assert_eq(attempts, 1)
				helpers.assert_true(type(detail) == "string" and detail:find(case.detail, 1, true) ~= nil,
					"the concrete parent-preparation failure must be surfaced")
				helpers.assert_eq(#fixture.parent_prepare_calls, 1)
				helpers.assert_eq(#fixture.file_reads, 0,
					"an unsafe parent must abort before absence can be inferred")
				helpers.assert_eq(#fixture.file_writes, 0,
					"an unsafe parent must never reach publication")
			fixture.parent_prepare_failures[path] = nil
			fixture.missing_parent_paths[path] = nil
			end
		end)
	end)

	helpers.it("refuses a foreign edit after merge instead of overwriting its exact bytes", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local incoming = generated_config({ managed_rule(TOKEN, "normal", "current") })
			local path = "/merge/publish-concurrent.json"
			local source_a = _G.hs.json.encode({
				profiles = {
					{
						name = "Personal",
						selected = true,
						complex_modifications = { rules = { personal_rule("source A") } },
					},
				},
			})
			local foreign_b = _G.hs.json.encode({
				profiles = {
					{
						name = "Personal",
						selected = true,
						complex_modifications = { rules = { personal_rule("foreign B") } },
					},
				},
			})
			fixture.file_data[path] = source_a
			fixture.file_writes = {}
			fixture.file_reads = {}
			fixture.parent_prepare_calls = {}
			fixture.write_succeeds = true
			fixture.before_publication = function(write_path)
				helpers.assert_eq(write_path, path)
				fixture.file_data[path] = foreign_b
			end

			local ok, detail, attempts = Generator.merge_and_deploy_config(incoming, path)

			helpers.assert_eq(ok, false, "a stale merge must never report publication success")
			helpers.assert_true(type(detail) == "string" and detail:find("source changed", 1, true) ~= nil)
			helpers.assert_eq(attempts, 1, "a source conflict must never enter mkdir/retry")
			helpers.assert_eq(#fixture.parent_prepare_calls, 1,
				"a source conflict must never re-prepare the parent as a retry strategy")
			helpers.assert_eq(#fixture.file_writes, 1, "the stale candidate must be offered exactly once")
			helpers.assert_eq(fixture.file_writes[1].method, "write_if_unchanged")
			helpers.assert_eq(fixture.file_writes[1].expected_source.status, "ok")
			helpers.assert_eq(fixture.file_writes[1].expected_source.content, source_a)
			helpers.assert_eq(fixture.file_data[path], foreign_b, "the foreign writer's exact bytes must survive")
		end)
	end)

	helpers.it("fails closed without publishing when the live config is malformed", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local incoming = generated_config({ managed_rule(TOKEN, "normal", "current") })
			local path = "/merge/publish-malformed.json"
			fixture.file_data[path] = "{ invalid"
			fixture.file_writes = {}
			fixture.file_reads = {}
			fixture.parent_prepare_calls = {}
			fixture.write_succeeds = true
			fixture.before_publication = nil

			local ok, detail, attempts = Generator.merge_and_deploy_config(incoming, path)
			helpers.assert_true(ok == false)
			helpers.assert_true(type(detail) == "string" and detail:find("merge failed", 1, true) ~= nil)
			helpers.assert_eq(attempts, 1)
			helpers.assert_eq(#fixture.file_writes, 0)
		end)
	end)

	helpers.it("reports a failed atomic writer and never claims publication", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local incoming = generated_config({ managed_rule(TOKEN, "normal", "current") })
			local path = "/merge/publish-write-failure.json"
			fixture.file_data[path] = _G.hs.json.encode({
				profiles = {
					{
						name = "Personal",
						selected = true,
						complex_modifications = { rules = { personal_rule("keep me") } },
					},
				},
			})
			fixture.file_writes = {}
			fixture.file_reads = {}
			fixture.parent_prepare_calls = {}
			fixture.write_succeeds = false
			fixture.before_publication = nil

			local ok, detail, attempts = Generator.merge_and_deploy_config(incoming, path)
			helpers.assert_true(ok == false)
			helpers.assert_true(type(detail) == "string" and detail:find("write failed", 1, true) ~= nil)
			helpers.assert_eq(attempts, 1)
			helpers.assert_true(#fixture.file_writes >= 1)
			fixture.write_succeeds = true
		end)
	end)
end)
