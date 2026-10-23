--- tests/unit/ui/metrics/typing/test_manifest_projection_completion.lua

--- ==============================================================================
--- MODULE: Typing Manifest Projection Completion Regression
--- DESCRIPTION:
--- Preserve partial manifests while carrying a strict independent admission receipt.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.ui.metrics.typing.manifest_completion_fixture")
local Json = require("json")

local function project(state, reader, projection)
	return projection.session(reader, "/fixture/db.sqlite", Fixture.TODAY, state.pacer).manifest()
end

helpers.describe("manifest-projection-completion", function()
	for _, empty in ipairs({ false, true }) do
		helpers.it("(manifest-projection-completion) accepts " .. (empty and "empty" or "populated") .. " manifest", function()
			Fixture.run({ empty = empty }, function(state, reader, projection)
				local days, encoded, complete = project(state, reader, projection)
				helpers.assert_eq(complete, true)
				helpers.assert_eq(state.manifest_receipts[1].complete, true)
				if empty then
					helpers.assert_eq(next(days), nil)
					helpers.assert_eq(encoded, "{}")
				else
					helpers.assert_eq(Fixture.title(days, Fixture.PAST), 3)
					helpers.assert_eq(Fixture.title(Json.decode(encoded), Fixture.TODAY), 3)
				end
				helpers.assert_eq(#state.errors, 0)
				helpers.assert_eq(state.opens, state.closes)
			end)
		end)
	end
	for _, failure in ipairs({ "rows", "after-row", "bounds", "open" }) do
		helpers.it("(manifest-projection-completion) refuses " .. failure .. " and retries unchanged source", function()
			Fixture.run({}, function(state, reader, projection)
				local healthy, _, complete = project(state, reader, projection)
				helpers.assert_eq(complete, true)
				helpers.assert_eq(Fixture.title(healthy, Fixture.TODAY), 3)
				Fixture.arm(state, failure)
				local partial, encoded, refused = project(state, reader, projection)
				helpers.assert_eq(refused, false)
				helpers.assert_eq(state.manifest_receipts[2].complete, false)
				helpers.assert_true(type(partial) == "table" and type(encoded) == "string")
				if failure ~= "open" then helpers.assert_eq(partial[Fixture.TODAY].Editor.chars, 11) end
				if failure == "bounds" then helpers.assert_eq(Fixture.title(partial, Fixture.TODAY), 3) end
				helpers.assert_true(#state.errors > 0)
				local errors = #state.errors
				Fixture.arm(state, nil)
				local recovered, recovered_json, accepted = project(state, reader, projection)
				helpers.assert_eq(accepted, true)
				helpers.assert_eq(Fixture.title(recovered, Fixture.PAST), 3)
				helpers.assert_eq(Fixture.title(Json.decode(recovered_json), Fixture.TODAY), 3)
				helpers.assert_eq(#state.errors, errors)
			end)
		end)
	end
	helpers.it("(manifest-projection-completion) a missing reader receipt cannot certify successful rows", function()
		Fixture.run({}, function(state, reader, projection)
			local original = reader.read_manifest
			reader.read_manifest = function(...)
				local days = original(...)
				return days
			end
			local days, encoded, complete = project(state, reader, projection)
			helpers.assert_eq(Fixture.title(days, Fixture.TODAY), 3)
			helpers.assert_eq(Fixture.title(Json.decode(encoded), Fixture.TODAY), 3)
			helpers.assert_eq(complete, false, "only an explicit true acknowledges successful reads")
		end)
	end)
end)
