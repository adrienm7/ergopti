--- lib/git_status.lua

--- ==============================================================================
--- MODULE: Git Repository State
--- DESCRIPTION:
--- Detects whether a git write-operation (pull / merge / checkout / rebase /
--- reset / commit) is currently rewriting the working tree of the repository
--- that contains a given directory.
---
--- WHY IT EXISTS:
--- The auto-reload file watchers (lib/file_watchers, ui/menu/menu_watchers)
--- fire hs.reload() when a project .lua/.toml file changes on disk. A `git pull`
--- run against a live driver rewrites init.lua and dozens of required modules;
--- if a reload fires mid-pull it boots against a half-updated, internally
--- inconsistent tree, errors during boot, and leaves Hammerspoon with no config
--- AND no watchers armed — a dead, must-relaunch state. The watchers consult
--- this module so they hold the reload until git has finished
--- (macos-reload-during-git-pull).
---
--- FEATURES & RATIONALE:
--- 1. Boundary-clean: every filesystem probe routes through adapters.file_system
---    (exists/read), so this lib holds no direct hs.* / io / os call and stays
---    inside the OS-purity ratchet with a zero contribution.
--- 2. No-op off git: when the directory is not inside a git working tree the
---    probe returns false, so a plain (non-clone) deployment reloads exactly as
---    before.
--- 3. Cheap and subprocess-free: a bounded upward walk plus a handful of
---    file-existence checks — safe to call from a debounce timer callback where
---    shelling out to `git` would violate the no-blocking-work rule.
--- ==============================================================================

local M = {}

local Logger     = require("lib.logger")
local FileSystem = require("adapters.file_system")

local LOG = "git_status"

-- Upper bound on the number of parent directories walked while locating the
-- repository root. The driver checkout is only a handful of levels below the
-- repo root; the cap guarantees termination on an unexpected path (e.g. a cycle
-- through symlinked parents) instead of looping to the filesystem root forever.
local MAX_WALK_DEPTH = 40

-- Marker FILES whose presence in the git directory means a write-operation is
-- mid-flight. `index.lock` is held for the ENTIRE index + working-tree update of
-- a checkout / merge / fast-forward pull / reset / commit and renamed onto
-- `index` only when the operation completes, so it is the decisive "git is
-- writing right now" signal. The *_HEAD markers cover a multi-step merge /
-- cherry-pick / revert that leaves the tree inconsistent between steps.
local IN_PROGRESS_MARKERS = {
	"index.lock",
	"MERGE_HEAD",
	"CHERRY_PICK_HEAD",
	"REVERT_HEAD",
}

-- Multi-step rebase states live in a directory, not a file. Every rebase backend
-- (`rebase-merge` for the interactive/merge backend, `rebase-apply` for the
-- am/apply backend) writes a `head-name` file inside it, so probing that file
-- detects the rebase without needing directory-vs-file mode detection — which
-- FileSystem.exists cannot answer portably.
local IN_PROGRESS_REBASE_PROBES = {
	"rebase-merge/head-name",
	"rebase-apply/head-name",
}





-- =====================================
-- =====================================
-- ======= 1/ Git-Dir Resolution =======
-- =====================================
-- =====================================

--- Strips one trailing path component from an absolute path.
--- @param dir string A path with at least one component.
--- @return string|nil The parent path, or nil once the root is reached.
local function parent_of(dir)
	local parent = dir:match("^(.*)/[^/]+$")
	if not parent or parent == "" then return nil end
	return parent
end

--- Resolves the git directory for the repository containing `start_dir`.
--- Handles both a normal checkout (`.git` is a directory) and a linked worktree
--- or submodule (`.git` is a file holding a `gitdir: <path>` pointer).
--- @param start_dir string Absolute path inside (or at the root of) a working tree.
--- @return string|nil The absolute git-directory path, or nil when not in a repo.
local function resolve_git_dir(start_dir)
	if type(start_dir) ~= "string" or start_dir == "" then return nil end

	local dir   = (start_dir:gsub("[/\\]+$", ""))
	local depth = 0
	while dir and dir ~= "" and depth < MAX_WALK_DEPTH do
		depth = depth + 1
		local dotgit = dir .. "/.git"

		-- Normal checkout: <dir>/.git/HEAD exists. Probing HEAD (a regular file)
		-- rather than the .git directory keeps the check portable.
		if FileSystem.exists(dotgit .. "/HEAD") then
			return dotgit
		end

		-- Linked worktree / submodule: <dir>/.git is a FILE `gitdir: <path>`.
		local content = FileSystem.read(dotgit)
		if type(content) == "string" then
			local pointer = content:match("^gitdir:%s*(.-)%s*$")
			if pointer and pointer ~= "" then
				-- A relative pointer resolves against the directory holding .git.
				if pointer:sub(1, 1) ~= "/" then pointer = dir .. "/" .. pointer end
				return (pointer:gsub("[/\\]+$", ""))
			end
		end

		dir = parent_of(dir)
	end
	return nil
end





-- ===================================
-- ===================================
-- ======= 2/ Public API =============
-- ===================================
-- ===================================

--- Reports whether a git write-operation is currently rewriting the working
--- tree of the repository that contains `start_dir`.
--- @param start_dir string Absolute path inside (or at the root of) a working tree.
--- @return boolean True while a pull / merge / checkout / rebase / commit is in flight.
function M.operation_in_progress(start_dir)
	local git_dir = resolve_git_dir(start_dir)
	if not git_dir then return false end

	for _, marker in ipairs(IN_PROGRESS_MARKERS) do
		if FileSystem.exists(git_dir .. "/" .. marker) then
			Logger.debug(LOG, "Git operation in progress — '%s/%s' present.", git_dir, marker)
			return true
		end
	end

	for _, probe in ipairs(IN_PROGRESS_REBASE_PROBES) do
		if FileSystem.exists(git_dir .. "/" .. probe) then
			Logger.debug(LOG, "Git rebase in progress — '%s/%s' present.", git_dir, probe)
			return true
		end
	end

	return false
end

return M
