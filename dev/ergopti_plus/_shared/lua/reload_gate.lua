--- _shared/lua/reload_gate.lua

--- ==============================================================================
--- MODULE: Auto-Reload Safety Gate (shared)
--- DESCRIPTION:
--- Decides whether a driver's auto-reload should be HELD because the working tree
--- is still being written — by git, a cloud sync (OneDrive / Dropbox / iCloud),
--- rsync, or a mass editor save. Reloading mid-write boots the driver against a
--- half-updated, internally inconsistent tree, which errors out and (via repeated
--- reloads) cascades into the keyboard-freezing reload storm.
---
--- Pure Lua: every OS touch (path existence / read) is INJECTED, so the exact
--- same policy is shared by the macOS (Hammerspoon) and Linux drivers — one
--- source of truth, no cross-driver drift.
---
--- Two complementary signals:
--- 1. Git precision — a git operation holds `.git/index.lock` (plus merge / rebase
---    markers) for the ENTIRE working-tree update, so it is deferred exactly, even
---    if the file events pause partway through.
--- 2. Source-agnostic quiescence — any bulk write (git pull, cloud sync, rsync,
---    mass save) shows up as MANY distinct files changing in one burst. Such a
---    burst is held until file activity has been quiet for BULK_SETTLE_SEC — long
---    enough to bridge the gaps a cloud sync leaves between files — so the reload
---    fires ONCE after the whole operation settles instead of mid-write. A lone
---    edit (the dev round-trip) still reloads after the short EDIT_SETTLE_SEC.
--- ==============================================================================

local M = {}





-- ===================================
-- ===================================
-- ======= 1/ Tunables ===============
-- ===================================
-- ===================================

-- Quiet window (seconds) after a normal single-file edit before the reload fires.
-- Kept equal to each driver's debounce literal so a lone edit round-trips fast.
M.EDIT_SETTLE_SEC = 0.5

-- Quiet window (seconds) after a detected BULK change. Long enough to bridge the
-- sub-second-to-few-second gaps a cloud sync / large pull leaves between files,
-- so the reload fires once the whole operation settles rather than mid-write.
M.BULK_SETTLE_SEC = 3.0

-- More than this many DISTINCT files changing in one burst marks it as a bulk
-- operation (git pull, cloud sync, rsync, mass save) rather than a hand edit.
M.BULK_THRESHOLD = 3

-- Tolerance (seconds) applied when deciding a burst has settled. A lone edit's
-- first settle poll lands ~EDIT_SETTLE_SEC after the change; without this margin,
-- timer jitter could push it just under the window and cost an extra poll
-- interval on every single edit, doubling the dev round-trip latency.
M.SETTLE_EPSILON_SEC = 0.1

-- Git-directory markers whose presence means a write-operation is mid-flight.
-- `index.lock` is held for the ENTIRE index + working-tree update of a checkout /
-- fast-forward pull / merge / reset / commit; the *_HEAD markers cover a
-- multi-step merge / cherry-pick / revert between steps.
local GIT_MARKERS = {
	"index.lock",
	"MERGE_HEAD",
	"CHERRY_PICK_HEAD",
	"REVERT_HEAD",
}

-- Rebase states live in a directory; every backend writes a `head-name` file
-- inside it, so probing that file detects a rebase without directory-vs-file
-- mode detection (which the injected `exists` need only answer for regular files).
local GIT_REBASE_PROBES = {
	"rebase-merge/head-name",
	"rebase-apply/head-name",
}

-- Upper bound on the number of parent directories walked while locating the repo
-- root; guarantees termination on an unexpected path (e.g. a symlink cycle).
local MAX_WALK_DEPTH = 40





-- =========================================
-- =========================================
-- ======= 2/ Adaptive Settle ==============
-- =========================================
-- =========================================

--- Required quiet window (seconds) before a reload may fire, given how many
--- DISTINCT files changed in the current burst. A handful of files is a hand
--- edit (fast); more is a bulk operation whose write must be allowed to settle.
--- @param distinct_count number Distinct changed paths seen since the burst began.
--- @return number Seconds of quiet required before reloading.
function M.required_settle_sec(distinct_count)
	if (tonumber(distinct_count) or 0) > M.BULK_THRESHOLD then
		return M.BULK_SETTLE_SEC
	end
	return M.EDIT_SETTLE_SEC
end

--- True when `elapsed_sec` of quiet since the last change satisfies the settle
--- window for a burst of `distinct_count` distinct files (minus the jitter
--- tolerance). A driver holds its reload while this returns false.
--- @param elapsed_sec number Seconds since the most recent relevant change.
--- @param distinct_count number Distinct changed paths seen since the burst began.
--- @return boolean
function M.is_settled(elapsed_sec, distinct_count)
	return (tonumber(elapsed_sec) or 0) >= M.required_settle_sec(distinct_count) - M.SETTLE_EPSILON_SEC
end





-- =========================================
-- =========================================
-- ======= 3/ Git Operation Detection ======
-- =========================================
-- =========================================

--- Strips one trailing path component.
--- @param dir string
--- @return string|nil Parent path, or nil at the root.
local function parent_of(dir)
	local parent = dir:match("^(.*)/[^/]+$")
	if not parent or parent == "" then return nil end
	return parent
end

--- Resolves the git directory for the repository containing `start_dir`. Handles
--- a normal checkout (`.git` is a directory) and a linked worktree / submodule
--- (`.git` is a FILE holding a `gitdir: <path>` pointer).
--- @param fs table { exists = fun(path):boolean, read = fun(path):string|nil }
--- @param start_dir string
--- @return string|nil Absolute git-directory path, or nil when not in a repo.
local function resolve_git_dir(fs, start_dir)
	if type(start_dir) ~= "string" or start_dir == "" then return nil end

	local dir   = (start_dir:gsub("[/\\]+$", ""))
	local depth = 0
	while dir and dir ~= "" and depth < MAX_WALK_DEPTH do
		depth = depth + 1
		local dotgit = dir .. "/.git"

		-- Normal checkout: <dir>/.git/HEAD exists (a regular file — portable probe).
		if fs.exists(dotgit .. "/HEAD") then
			return dotgit
		end

		-- Linked worktree / submodule: <dir>/.git is a FILE `gitdir: <path>`.
		local content = type(fs.read) == "function" and fs.read(dotgit) or nil
		if type(content) == "string" then
			local pointer = content:match("^gitdir:%s*(.-)%s*$")
			if pointer and pointer ~= "" then
				if pointer:sub(1, 1) ~= "/" then pointer = dir .. "/" .. pointer end
				return (pointer:gsub("[/\\]+$", ""))
			end
		end

		dir = parent_of(dir)
	end
	return nil
end

--- Reports whether a git write-operation is currently rewriting the working tree
--- of the repository that contains `start_dir`.
--- @param fs table { exists = fun(path):boolean, read = fun(path):string|nil }
--- @param start_dir string Absolute path inside (or at the root of) a working tree.
--- @return boolean True while a pull / merge / checkout / rebase / commit is in flight.
function M.git_operation_in_progress(fs, start_dir)
	if type(fs) ~= "table" or type(fs.exists) ~= "function" then return false end

	local git_dir = resolve_git_dir(fs, start_dir)
	if not git_dir then return false end

	for _, marker in ipairs(GIT_MARKERS) do
		if fs.exists(git_dir .. "/" .. marker) then return true end
	end
	for _, probe in ipairs(GIT_REBASE_PROBES) do
		if fs.exists(git_dir .. "/" .. probe) then return true end
	end
	return false
end

return M
