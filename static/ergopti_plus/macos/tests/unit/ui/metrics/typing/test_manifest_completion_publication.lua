--- tests/unit/ui/metrics/typing/test_manifest_completion_publication.lua

--- ==============================================================================
--- MODULE: Typing Manifest Completion Publication Regression
--- DESCRIPTION:
--- Refused manifests preserve accepted snapshots and cannot reach full or live delivery.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.ui.metrics.typing.manifest_completion_fixture")
local Json = require("json")

local function contains(evaluations, fragment)
	for _, call in ipairs(evaluations) do if call.code:find(fragment, 1, true) then return true end end
	return false
end

helpers.describe("manifest-completion-publication", function()
	for _, empty in ipairs({ false, true }) do
		helpers.it("(manifest-completion-publication) keeps " .. (empty and "empty" or "populated") .. " full and live healthy", function()
			Fixture.with_publication({ empty = empty }, function(control)
				control.bootstrap()
				helpers.assert_eq(#control.state.saves, 1)
				helpers.assert_eq(control.state.saves[1].accepted, true)
				helpers.assert_eq(#control.publications, 1)
				helpers.assert_eq(control.publications[1].metadata.freshness.state, "fresh")
				control.live()
				helpers.assert_eq(#control.publications, 2)
				helpers.assert_eq(#control.state.saves, 1)
				helpers.assert_eq(#control.errors, 0)
				local manifest = control.publications[2].payload.manifest
				if empty then helpers.assert_eq(next(manifest), nil)
				else helpers.assert_eq(Fixture.title(manifest, Fixture.TODAY), 3) end
			end)
		end)
	end
	for _, failure in ipairs({ "rows", "after-row", "bounds", "open" }) do
		helpers.it("(manifest-completion-publication) full preserves accepted snapshot after " .. failure, function()
			Fixture.with_publication({}, function(control)
				control.bootstrap()
				helpers.assert_eq(control.state.saves[1].accepted, true)
				local accepted = control.state.saves[1].payload
				local stored = control.state.disk_files[control.snapshot_path]
				helpers.assert_eq(Fixture.title(Json.decode(accepted).manifest, Fixture.TODAY), 3)
				Fixture.arm(control.state, failure)
				control.reopen()
				helpers.assert_eq(control.state.manifest_receipts[2].complete, false)
				helpers.assert_eq(#control.state.saves, 1, "a failed refresh cannot replace its accepted snapshot")
				helpers.assert_eq(control.state.saves[1].payload, accepted)
				helpers.assert_eq(control.state.disk_files[control.snapshot_path], stored)
				helpers.assert_eq(#control.publications, 2, "only the accepted stale snapshot may repaint")
				helpers.assert_eq(control.publications[2].metadata.freshness.state, "stale")
				helpers.assert_eq(Fixture.title(control.publications[2].payload.manifest, Fixture.TODAY), 3)
				helpers.assert_true(contains(control.evaluations, '"state":"failed"'))
				helpers.assert_true(table.concat(control.errors, "\n"):find("Typing metrics manifest prefetch was incomplete", 1, true) ~= nil)
				Fixture.arm(control.state, nil)
				control.reopen()
				helpers.assert_eq(#control.state.saves, 2)
				helpers.assert_eq(control.state.saves[2].accepted, true)
				helpers.assert_eq(#control.publications, 4)
				helpers.assert_eq(Fixture.title(control.publications[4].payload.manifest, Fixture.TODAY), 3)
				helpers.assert_eq(control.publications[4].metadata.freshness.state, "fresh")
			end)
		end)
		helpers.it("(manifest-completion-publication) live preserves accepted publication after " .. failure, function()
			Fixture.with_publication({}, function(control)
				control.bootstrap()
				control.live()
				helpers.assert_eq(#control.publications, 2)
				local accepted = control.publications[2]
				helpers.assert_eq(Fixture.title(accepted.payload.manifest, Fixture.TODAY), 3)
				Fixture.arm(control.state, failure)
				control.live()
				helpers.assert_eq(control.state.manifest_receipts[3].complete, false)
				helpers.assert_eq(#control.state.saves, 1)
				helpers.assert_eq(#control.publications, 2, "a partial live manifest cannot replace the accepted page")
				helpers.assert_true(rawequal(control.publications[2], accepted))
				helpers.assert_true(table.concat(control.errors, "\n"):find("Typing metrics live manifest read was incomplete", 1, true) ~= nil)
				Fixture.arm(control.state, nil)
				control.live()
				helpers.assert_eq(#control.publications, 3)
				helpers.assert_eq(#control.state.saves, 1)
				helpers.assert_eq(Fixture.title(control.publications[3].payload.manifest, Fixture.TODAY), 3)
				helpers.assert_eq(control.publications[3].metadata.manifest_revision, accepted.metadata.manifest_revision + 1)
			end)
		end)
	end
end)
