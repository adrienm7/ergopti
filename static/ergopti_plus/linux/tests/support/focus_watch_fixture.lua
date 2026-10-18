--- tests/support/focus_watch_fixture.lua

--- ==============================================================================
--- MODULE: Explicit Native Focus Watch Fixture
--- DESCRIPTION:
--- Supplies one admitted ordinary native field to daemon tests whose keyboard
--- and desktop ports are controlled. Native watcher gates use the real owner.
--- ==============================================================================

local M = {}

--- Creates an ordinary-field watcher with the production ownership interface.
--- @return table watcher
function M.new()
	local listener = nil
	local receipt = { role = 61, bus = ":1.1", path = "/fixture/field" }
	local watcher = {}
	function watcher.on_change(callback) listener = callback end
	function watcher.start() return true end
	function watcher.wait_ready() return true end
	function watcher.pump() return true end
	function watcher.invalidate() if listener then listener(nil) end; return true end
	function watcher.barrier() if listener then listener(receipt) end; return receipt end
	function watcher.snapshot() return receipt end
	function watcher.stop() if listener then listener(nil) end; return true end
	function watcher.is_settled() return true end
	return watcher
end

return M
