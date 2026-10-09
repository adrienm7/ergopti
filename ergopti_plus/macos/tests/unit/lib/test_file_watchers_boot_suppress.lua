--- tests/unit/lib/test_file_watchers_boot_suppress.lua

--- ==============================================================================
--- MODULE: infra/file_watchers post-boot FSEvents-replay suppression
--- DESCRIPTION:
--- Second regression for macos-reload-during-git-pull. The git guard stops a
--- reload from firing WHILE git writes the tree, but macOS FSEvents replays the
--- pull's buffered change events to the freshly-armed watcher right AFTER the
--- post-pull reload boots — and git is idle by then, so the guard cannot help.
--- Without a boot-suppress window (the sibling menu_watchers already had, but
--- file_watchers did not) that replay re-fires the reload every boot and cascades
--- into the keyboard-freezing storm this driver first fixed in fe57ce045.
---
--- This drives a .lua change through the project watcher at two clock positions
--- and asserts a change INSIDE the boot window is dropped while one AFTER it
--- reloads normally. It fails against the pre-fix module, which armed a reload
--- regardless of how recently the watchers were (re)armed.
--- ==============================================================================

local helpers = require("tests.helpers")

local Fixture = require("tests.support.file_watcher_self_write_fixture")

helpers.describe("infra/file_watchers — post-boot FSEvents-replay suppression (macos-reload-during-git-pull)", function()
	helpers.it("drops a change inside the boot window, then reloads once the window passes", function()
		Fixture.with_watchers(function(w)
			-- The fixture constructs at clock zero; replay the original 1/10/11 sequence.
			w.set_clock(1)
			w.fire("/fake/base/modules/foo.lua")
			helpers.assert_nil(w.scheduled(), "a change inside the boot suppress window must NOT schedule a reload")
			helpers.assert_eq(w.reloads(), 0, "and must NOT reload")

			w.set_clock(10)
			w.fire("/fake/base/modules/foo.lua")
			helpers.assert_type(w.scheduled(), "function", "a change after the window must schedule a reload")
			local scheduled_count = w.scheduled_count()
			w.settle(1)
			helpers.assert_eq(w.reloads(), 1, "and must reload once")
			helpers.assert_eq(w.scheduled_count(), scheduled_count, "an accepted reload must not schedule a retry")
		end)
	end)
end)
