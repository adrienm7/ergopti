--- tests/unit/ui/metrics/typing/test_manifest_completion_publication.lua

--- ==============================================================================
--- MODULE: Typing Manifest Completion Publication Regression
--- DESCRIPTION:
--- Incomplete manifests are shown flagged, never saved over the accepted
--- snapshot, and the next complete read is saved again.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.ui.metrics.typing.manifest_completion_fixture")
local Json = require("json")
local ReadLogs = require("tests.support.ui.metrics.typing.read_completion_logs")

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
		helpers.it("(incomplete-history-partial) full shows a partial manifest after " .. failure .. " without saving it", function()
			Fixture.with_publication({}, function(control)
				control.bootstrap()
				helpers.assert_eq(control.state.saves[1].accepted, true)
				local accepted = control.state.saves[1].payload
				local stored = control.state.disk_files[control.snapshot_path]
				helpers.assert_eq(Fixture.title(Json.decode(accepted).manifest, Fixture.TODAY), 3)
				local logs = ReadLogs.capture()
				Fixture.arm(control.state, failure)
				control.reopen()
				helpers.assert_eq(control.state.manifest_receipts[2].complete, false)
				helpers.assert_eq(#control.state.saves, 1, "an incomplete refresh is never saved as the snapshot")
				helpers.assert_eq(control.state.saves[1].payload, accepted)
				helpers.assert_eq(control.state.disk_files[control.snapshot_path], stored)
				helpers.assert_eq(#control.publications, 3, "the stale snapshot paints, then the partial read")
				helpers.assert_eq(control.publications[2].metadata.freshness.state, "stale")
				local partial = control.publications[3]
				helpers.assert_eq(partial.payload.manifest_incomplete, true, "the page is told the history is incomplete")
				helpers.assert_eq(partial.metadata.freshness.state, "fresh")
				helpers.assert_true(not contains(control.evaluations, '"state":"failed"'), "partial counts are not a failure")
				helpers.assert_eq(#logs.warnings, 1, "the incomplete read is logged once")
				helpers.assert_true(#control.errors > 0, "the SQLite read failure itself is still logged")
				Fixture.arm(control.state, nil)
				control.reopen()
				helpers.assert_eq(control.state.manifest_receipts[#control.state.manifest_receipts].complete, true)
				helpers.assert_eq(#control.state.saves, 2, "the next open retried a full read and saved it")
				helpers.assert_eq(control.state.saves[2].accepted, true)
				helpers.assert_eq(#control.publications, 5)
				helpers.assert_eq(Fixture.title(control.publications[5].payload.manifest, Fixture.TODAY), 3)
				helpers.assert_eq(control.publications[5].payload.manifest_incomplete, nil)
				helpers.assert_eq(control.publications[5].metadata.freshness.state, "fresh")
				helpers.assert_eq(#logs.infos, 1, "the recovery closes the incomplete-read log pair")
			end)
		end)
		helpers.it("(incomplete-history-partial) live shows a partial manifest after " .. failure .. " then recovers", function()
			Fixture.with_publication({}, function(control)
				control.bootstrap()
				control.live()
				helpers.assert_eq(#control.publications, 2)
				local accepted = control.publications[2]
				helpers.assert_eq(Fixture.title(accepted.payload.manifest, Fixture.TODAY), 3)
				local logs = ReadLogs.capture()
				Fixture.arm(control.state, failure)
				control.live()
				helpers.assert_eq(control.state.manifest_receipts[3].complete, false)
				helpers.assert_eq(#control.state.saves, 1)
				helpers.assert_eq(#control.publications, 3, "a partial live manifest is shown, not refused")
				helpers.assert_eq(control.publications[3].payload.manifest_incomplete, true)
				helpers.assert_eq(#logs.warnings, 1)
				Fixture.arm(control.state, nil)
				control.live()
				helpers.assert_eq(#control.publications, 4)
				helpers.assert_eq(#control.state.saves, 1)
				helpers.assert_eq(Fixture.title(control.publications[4].payload.manifest, Fixture.TODAY), 3)
				helpers.assert_eq(control.publications[4].payload.manifest_incomplete, nil)
				helpers.assert_eq(control.publications[4].metadata.manifest_revision, accepted.metadata.manifest_revision + 2)
				helpers.assert_eq(#logs.infos, 1)
			end)
		end)
	end
end)
