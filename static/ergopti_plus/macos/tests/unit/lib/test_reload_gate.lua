--- tests/unit/lib/test_reload_gate.lua

--- ==============================================================================
--- MODULE: reload_gate shared policy contract
--- DESCRIPTION:
--- reload_gate (_shared/lua) is the single source of truth both drivers consult
--- to decide whether an auto-reload must be held because the working tree is
--- still being written (macos-reload-during-git-pull). This pins its two policies
--- directly: the source-agnostic adaptive settle (a lone edit reloads fast, a
--- bulk write waits for a long quiet window) and the precise git-operation probe
--- (index.lock / MERGE_HEAD / rebase markers, worktree pointer), driven by a fake
--- filesystem so no real FS or git is needed.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["reload_gate"] = nil
local reload_gate = require("reload_gate")

local function fs_from(existing, contents)
	return {
		exists = function(p) return existing[p] == true end,
		read   = function(p) return contents[p] end,
	}
end

helpers.describe("reload_gate — adaptive settle", function()
	helpers.it("scales the settle window with the number of distinct changed files", function()
		helpers.assert_true(reload_gate.required_settle_sec(1) == reload_gate.EDIT_SETTLE_SEC,
			"a lone edit uses the short edit settle")
		helpers.assert_true(reload_gate.required_settle_sec(reload_gate.BULK_THRESHOLD) == reload_gate.EDIT_SETTLE_SEC,
			"at the threshold it is still a hand edit")
		helpers.assert_true(reload_gate.required_settle_sec(reload_gate.BULK_THRESHOLD + 1) == reload_gate.BULK_SETTLE_SEC,
			"over the threshold it is a bulk write and uses the long settle")
	end)

	helpers.it("holds a bulk burst until the long window while releasing a lone edit at the short one", function()
		helpers.assert_true(not reload_gate.is_settled(0, 1), "0s of quiet is never settled")
		helpers.assert_true(reload_gate.is_settled(reload_gate.EDIT_SETTLE_SEC, 1),
			"a lone edit is settled once the edit window elapsed")

		local many = reload_gate.BULK_THRESHOLD + 5
		helpers.assert_true(not reload_gate.is_settled(reload_gate.EDIT_SETTLE_SEC, many),
			"a bulk write must NOT count as settled after only the edit window")
		helpers.assert_true(reload_gate.is_settled(reload_gate.BULK_SETTLE_SEC, many),
			"a bulk write is settled after the bulk window")
	end)
end)

helpers.describe("reload_gate — git_operation_in_progress", function()
	helpers.it("detects index.lock / MERGE_HEAD and is a no-op outside a repo", function()
		local existing, contents = {}, {}
		local fs = fs_from(existing, contents)
		local DIR = "/repo/static/ergopti_plus/macos"

		existing["/repo/.git/HEAD"] = true
		helpers.assert_true(not reload_gate.git_operation_in_progress(fs, DIR),
			"an idle repo (HEAD, no lock) is not in progress")

		existing["/repo/.git/index.lock"] = true
		helpers.assert_true(reload_gate.git_operation_in_progress(fs, DIR), "a held index.lock is in progress")
		existing["/repo/.git/index.lock"] = nil

		existing["/repo/.git/MERGE_HEAD"] = true
		helpers.assert_true(reload_gate.git_operation_in_progress(fs, DIR), "an in-progress merge is in progress")

		helpers.assert_true(not reload_gate.git_operation_in_progress(fs, "/nowhere/deep/path"),
			"a directory outside any repo is never in progress")
	end)

	helpers.it("follows a linked-worktree `.git` FILE pointer to the real git dir", function()
		local existing, contents = {}, {}
		contents["/wt/.git"] = "gitdir: /main/.git/worktrees/wt\n"
		existing["/main/.git/worktrees/wt/index.lock"] = true
		helpers.assert_true(reload_gate.git_operation_in_progress(fs_from(existing, contents), "/wt/sub"),
			"the worktree's linked git dir is probed for the markers")
	end)
end)
