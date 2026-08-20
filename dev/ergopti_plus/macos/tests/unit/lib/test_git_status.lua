--- tests/unit/lib/test_git_status.lua

--- ==============================================================================
--- MODULE: infra/git_status predicate contract
--- DESCRIPTION:
--- git_status.operation_in_progress() is what stops the auto-reload watchers from
--- firing hs.reload() in the middle of a `git pull` (macos-reload-during-git-pull).
--- This pins its behaviour with an injected fake FileSystem adapter so the
--- walk-up + marker logic is exercised deterministically, without touching the
--- real filesystem or depending on LuaFileSystem:
---   • an idle checkout reports NOT in progress,
---   • index.lock / MERGE_HEAD (the signals a running `git pull` leaves) report
---     in progress,
---   • a directory outside any git repo is a no-op (false),
---   • a linked worktree's `.git` FILE pointer is followed to the real git dir,
---   • a rebase state directory reports in progress.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Fake FileSystem adapter: exists()/read() answer from these in-memory tables so
-- the test controls exactly which paths "exist" and what a `.git` pointer file
-- contains. git_status captures FileSystem at require time, so it must be
-- injected BEFORE the module is required.
local existing = {}
local contents = {}
package.loaded["adapters.file_system"] = {
	exists = function(p) return existing[p] == true end,
	read   = function(p) return contents[p] end,
}

package.loaded["infra.git_status"] = nil
local git_status = require("infra.git_status")

local function reset()
	for k in pairs(existing) do existing[k] = nil end
	for k in pairs(contents) do contents[k] = nil end
end

-- The driver checkout sits a few levels below the repo root, exactly like the
-- real base_dir passed by init.lua.
local DRIVER_DIR = "/repo/static/ergopti_plus/macos"

helpers.describe("infra/git_status — operation_in_progress()", function()
	helpers.it("reports NOT in progress for an idle checkout", function()
		reset()
		existing["/repo/.git/HEAD"] = true
		helpers.assert_true(not git_status.operation_in_progress(DRIVER_DIR),
			"an idle repo (HEAD present, no lock) must not read as in progress")
	end)

	helpers.it("reports in progress while index.lock is held (checkout / ff pull / commit)", function()
		reset()
		existing["/repo/.git/HEAD"]       = true
		existing["/repo/.git/index.lock"] = true
		helpers.assert_true(git_status.operation_in_progress(DRIVER_DIR),
			"a held index.lock must read as in progress")
	end)

	helpers.it("reports in progress during a merge (MERGE_HEAD present)", function()
		reset()
		existing["/repo/.git/HEAD"]       = true
		existing["/repo/.git/MERGE_HEAD"] = true
		helpers.assert_true(git_status.operation_in_progress(DRIVER_DIR),
			"an in-progress merge must read as in progress")
	end)

	helpers.it("is a no-op (false) outside any git working tree", function()
		reset()
		-- No .git anywhere up the tree.
		helpers.assert_true(not git_status.operation_in_progress("/nowhere/deep/path"),
			"a non-git deployment must never read as in progress")
	end)

	helpers.it("follows a linked-worktree `.git` FILE pointer to the real git dir", function()
		reset()
		-- <wt>/.git is a FILE holding an absolute gitdir pointer (git worktree form).
		contents["/wt/.git"] = "gitdir: /main/.git/worktrees/wt\n"
		existing["/main/.git/worktrees/wt/index.lock"] = true
		helpers.assert_true(git_status.operation_in_progress("/wt/sub"),
			"a worktree's linked git dir must be probed for the in-progress markers")
	end)

	helpers.it("reports in progress during a rebase (rebase-merge state dir)", function()
		reset()
		existing["/repo/.git/HEAD"]                     = true
		existing["/repo/.git/rebase-merge/head-name"]   = true
		helpers.assert_true(git_status.operation_in_progress(DRIVER_DIR),
			"an in-progress rebase must read as in progress")
	end)
end)
