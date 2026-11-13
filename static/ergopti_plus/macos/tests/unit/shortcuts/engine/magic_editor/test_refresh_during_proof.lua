--- tests/unit/shortcuts/engine/magic_editor/test_refresh_during_proof.lua

--- ==============================================================================
--- MODULE: Editor Shortcut Retarget During A Running Source Proof
--- DESCRIPTION:
--- A retarget that arrives while the native source proof still runs fences
--- that proof and accepts: the proof's settlement starts the new one, once.
---
--- ROOT CAUSE ENCODED: a bulk edit that settles at once (Restore recommended
--- while Ergopti's own remapping runtime is not admitted) retargeted the editor
--- shortcut twice in a row. The second refresh reported the first proof's
--- pending cancel as cleanup debt, so the boot logged an ERROR and the E2E
--- world opened its error path.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.shortcuts.magic_editor_source_owner_fixture"] = nil
local Fixture = require("tests.support.shortcuts.magic_editor_source_owner_fixture")

helpers.describe("magic editor: a retarget during a running source proof", function()
	helpers.it("accepts, waits for the running proof, then proves the source once more", function()
		Fixture.with_fixture(function(subject, registrar, _, state, spec)
			state.cancel_refuses = true
			helpers.assert_eq(subject.start(spec), true)
			helpers.assert_eq(#state.requests, 1)
			helpers.assert_eq(subject.refresh(), true, "a cancel that settles later is not cleanup debt")
			helpers.assert_eq(#state.requests, 1, "no second proof starts beside the running one")
			state.cancel_refuses = false
			local first = state.requests[1]
			first.settled = true
			first.on_settled()
			helpers.assert_eq(#state.requests, 2, "the settled proof starts the retarget")
			helpers.assert_eq(registrar.live_count(), 0)
			helpers.assert_eq(subject.stop(), true)
		end)
	end)

	helpers.it("keeps a cancel that raised as cleanup debt", function()
		Fixture.with_fixture(function(subject, _, _, state, spec)
			helpers.assert_eq(subject.start(spec), true)
			state.requests[1].operation.cancel = function() error("native cancel failed") end
			helpers.assert_eq(subject.refresh(), false)
		end)
	end)
end)
