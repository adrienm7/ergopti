--- modules/hotstrings/engine.lua

--- ==============================================================================
--- MODULE: Hotstring Engine (Linux — thin re-export)
--- DESCRIPTION:
--- Re-exports the canonical pure-Lua hotstring engine from the shared library
--- at _shared/lua/hotstring_engine/. Placing the canonical implementation in
--- _shared/ lets every Lua-based driver (Hammerspoon, Linux, future drivers)
--- share a single source of truth for the matching algorithm.
---
--- All matching logic, tail-char bucketing, longest-match-first sorting, word
--- boundary enforcement, and the Logger shim live in the shared module. This
--- file is intentionally minimal — it adjusts the Lua search path, counts and
--- times each on_char call (infra/perf_counters), and
--- delegates to the canonical implementation.
--- ==============================================================================

-- Resolve the path to _shared/lua/ relative to this file's location so the
-- engine can be required without the caller needing to configure LUA_PATH.
-- __FILE__ is not available in standard Lua; we use a debug trick that works
-- in both LuaJIT and Lua 5.4 (which both support debug.getinfo).
local _this_file = debug.getinfo(1, "S").source:gsub("^@", "")
-- Navigate: …/linux/modules/hotstrings/ → …/linux/ → …/_shared/lua/
--
-- _linux_root already IS the driver root — the pattern above strips
-- modules/hotstrings/ — so _shared is ONE level up, not two. This read "../../"
-- and resolved outside the tree entirely, so the shared engine was never added
-- to package.path from here; whatever else had already put it there was
-- carrying this module. It runs before package.path is set, which is why it
-- resolves by hand rather than through lib.paths: requiring the resolver here
-- would need the very path it is computing. tools/test/
-- test-linux-shared-path-resolver.cjs asserts this depth instead.
-- A backslash is a Linux filename byte, and the shared path owner is not yet
-- reachable: split at slashes alone.
local _linux_root = _this_file:match("^(.*/)modules/hotstrings/")
local _shared_lua = _linux_root and (_linux_root .. "../_shared/lua") or nil

if _shared_lua then
	-- Prepend to package.path only when the entry is not already present.
	local entry = _shared_lua .. "/?.lua"
	if not package.path:find(entry, 1, true) then
		package.path = entry .. ";" .. package.path
	end
end

-- Delegate to the shared implementation; the only addition is the permanent
-- match counter and (at DEBUG) timing span, kept here so the shared engine,
-- which the other drivers load, carries no Linux-only instrumentation.
local Shared = require("hotstring_engine")
local Perf = require("infra.perf_counters")

local M = setmetatable({}, { __index = Shared })

--- Creates a shared engine whose on_char is counted and timed.
--- @return table engine
function M.new(...)
	local engine = Shared.new(...)
	local shared_on_char = engine.on_char
	function engine:on_char(ch, opts)
		local started = Perf.clock()
		local result = shared_on_char(self, ch, opts)
		Perf.span("hotstring.match", started)
		if result then Perf.count("hotstring.matches") end
		return result
	end
	return engine
end

return M
