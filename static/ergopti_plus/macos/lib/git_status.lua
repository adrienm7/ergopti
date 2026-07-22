--- lib/git_status.lua

--- ==============================================================================
--- MODULE: Git Repository State (macOS binding)
--- DESCRIPTION:
--- Thin macOS binding around the shared reload_gate git-operation probe: it feeds
--- the FileSystem adapter (exists/read) into reload_gate.git_operation_in_progress
--- so the auto-reload watchers can tell whether a git pull / merge / checkout /
--- rebase is currently rewriting the working tree.
---
--- WHY A BINDING, NOT THE LOGIC:
--- The detection itself (walk to the .git dir, probe index.lock and the
--- merge/rebase markers, follow a linked-worktree pointer) lives in
--- _shared/lua/reload_gate.lua so the macOS and Linux drivers share ONE
--- implementation that can never drift. This file only supplies the OS-specific
--- filesystem access, keeping every hs.*/io call inside the adapter layer
--- (macos-reload-during-git-pull).
--- ==============================================================================

local M = {}

local reload_gate = require("reload_gate")
local FileSystem  = require("adapters.file_system")

--- Reports whether a git write-operation is rewriting the working tree of the
--- repository that contains `start_dir`.
--- @param start_dir string Absolute path inside (or at the root of) a working tree.
--- @return boolean True while a pull / merge / checkout / rebase / commit is in flight.
function M.operation_in_progress(start_dir)
	return reload_gate.git_operation_in_progress(FileSystem, start_dir)
end

return M
