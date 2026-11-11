--- ui/menu/refresh_scope.lua

--- ==============================================================================
--- MODULE: Menu Refresh Scope
--- DESCRIPTION:
--- Decides how much of the menubar tree a coalesced refresh rebuilds. hs.menubar
--- has no per-row update: a change re-pushes the whole tree, so the saving left
--- is in the Lua build. A refresh asked only from inside clicks on one
--- top-level branch rebuilds that branch alone; anything else rebuilds all.
---
--- FEATURES & RATIONALE:
--- 1. Fail towards the full rebuild: a request from outside a click (a watcher,
---    a timer, an asynchronous completion), from a branch the builder does not
---    admit, or from two different branches widens the scope to the whole tree.
--- 2. One scope per pending refresh: take() hands the scope to the refresh and
---    resets it, so the next request starts narrow again.
--- 3. No OS call and no menubar knowledge: the menu owner says which branch a
---    click belongs to (ui.menu.branch_rows.branch_of).
--- ==============================================================================

local M = {}

--- The scope of a refresh that rebuilds the whole tree.
M.ALL = "all"

--- Creates a scope tracker.
--- @return table scope { enter_click, leave_click, request, take }
function M.new()
	local self = {}
	-- Branch of the click being run: nil outside a click, false for a click no
	-- single branch owns.
	local clicking = nil
	-- Scope of the pending refresh: nil when none is pending.
	local pending = nil

	--- Marks the start of a click's synchronous run.
	--- @param branch string|nil The clicked row's branch, nil when it has none.
	--- @return any previous The enclosing click's branch, for leave_click.
	function self.enter_click(branch)
		local previous = clicking
		clicking = type(branch) == "string" and branch or false
		return previous
	end

	--- Marks the end of a click's synchronous run.
	--- @param previous any The value enter_click returned.
	function self.leave_click(previous) clicking = previous end

	--- Records that the tree must be refreshed.
	function self.request()
		local branch = clicking
		if type(branch) ~= "string" then
			pending = M.ALL
		elseif pending == nil then
			pending = branch
		elseif pending ~= branch then
			pending = M.ALL
		end
	end

	--- Hands the pending scope to the refresh that runs now, and resets it.
	--- @return string|nil scope A branch id, M.ALL, or nil when nothing was requested.
	function self.take()
		local scope = pending
		pending = nil
		return scope
	end

	return self
end

return M
