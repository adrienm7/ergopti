--- tests/unit/lib/test_file_watchers_adaptive_settle.lua

--- ==============================================================================
--- MODULE: infra/file_watchers adaptive quiescence for bulk writes
--- DESCRIPTION:
--- The git guard only covers git; a OneDrive / Dropbox / rsync sync (or any bulk
--- write) leaves no lock and would still let the watcher reload mid-operation.
--- The source-agnostic defence is quiescence: a burst of MANY distinct files is
--- held until file activity has been quiet for the long bulk-settle window, while
--- a lone edit still reloads after the short edit window.
---
--- This fires a many-file batch through the project watcher and, stepping the
--- clock, asserts it is STILL held at the edit-settle window and reloads exactly
--- once at the bulk-settle window — with git idle throughout, so only the
--- quiescence policy is under test. It fails against a watcher that reloads on
--- the short debounce regardless of how many files changed.
--- ==============================================================================

local helpers = require("tests.helpers")

local Fixture = require("tests.support.file_watcher_self_write_fixture")

helpers.describe("infra/file_watchers — adaptive quiescence for bulk writes (macos-reload-during-git-pull)", function()
	helpers.it("holds a many-file burst until the bulk settle, not the lone-edit settle", function()
		Fixture.with_watchers(function(w)
			local reload_gate = require("reload_gate")
			-- A bulk write lands: many distinct .lua files in one FSEvents batch.
			w.set_clock(1000)
			local batch = {}
			for i = 1, reload_gate.BULK_THRESHOLD + 5 do batch[i] = "/fake/base/m" .. i .. ".lua" end
			w.fire(batch)
			helpers.assert_true(type(w.scheduled()) == "function", "the bulk change must arm a settle poll")

			-- At the lone-edit settle window the bulk burst must STILL be held.
			w.set_clock(1000 + reload_gate.EDIT_SETTLE_SEC)
			w.poll()
			helpers.assert_true(w.reloads() == 0, "a bulk burst must NOT reload after only the edit settle window")
			helpers.assert_true(type(w.scheduled()) == "function", "it must keep polling until the bulk window")

			-- Once the bulk-settle window of quiet has elapsed, it reloads exactly once.
			w.set_clock(1000 + reload_gate.BULK_SETTLE_SEC)
			w.poll()
			helpers.assert_true(w.reloads() == 1, "the bulk write reloads once settled (got " .. w.reloads() .. ")")

		end)
	end)
end)
