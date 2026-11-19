--- _shared/core/lifecycle/engine/entry_guard.lua

--- ==============================================================================
--- MODULE: Entry Guard
--- DESCRIPTION:
--- Runs a driver entry point once more inside xpcall, so that an error at its
--- top level (a module that will not load from a half-updated tree) is caught
--- with its stack instead of reaching the host's own handler. The macOS init.lua
--- and the Linux daemon both run themselves under it; each driver then reports
--- the failure through its own channel.
---
--- FEATURES & RATIONALE:
--- 1. One marker: the inner run recognises itself by the table it receives as
---    its first chunk argument, and that key is spelled here only, so the two
---    drivers cannot drift apart on it.
--- 2. Needs nothing at load: the entry points load this file by path, before
---    package.path holds the shared tree.
--- ==============================================================================

local M = {}

-- The key of the table an entry chunk receives when the guard runs it.
local MARKER = "ergopti_boot_guard"

--- Whether an entry chunk was started by run() rather than by its host.
--- @param first any The chunk's first argument.
--- @return boolean
function M.is_guarded(first)
	return type(first) == "table" and first[MARKER] == true
end

--- Runs the entry point once more, inside xpcall, marked as guarded.
--- @param entry string Path of the entry file.
--- @param load function|nil Test seam replacing loadfile.
--- @return boolean booted True when the entry point returned normally.
--- @return any failure The raised error, when it did not.
--- @return string|nil traceback Stack captured before the unwind.
function M.run(entry, load)
	assert(type(entry) == "string" and entry ~= "", "the entry guard needs the entry point path")
	local chunk = assert((load or loadfile)(entry))
	local traceback = nil
	local booted, failure = xpcall(chunk, function(err)
		traceback = debug.traceback(tostring(err), 2)
		return err
	end, { [MARKER] = true })
	return booted, failure, traceback
end

return M
