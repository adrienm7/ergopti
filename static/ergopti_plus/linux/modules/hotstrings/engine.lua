--- static/ergopti_plus/linux/modules/hotstrings/engine.lua

--- ==============================================================================
--- MODULE: Hotstring Engine (Linux — thin re-export)
--- DESCRIPTION:
--- Re-exports the canonical pure-Lua hotstring engine from the shared library
--- at shared/lua/hotstring_engine/. Placing the canonical implementation in
--- shared/ lets every Lua-based driver (Hammerspoon, Linux, future drivers)
--- share a single source of truth for the matching algorithm.
---
--- All matching logic, tail-char bucketing, longest-match-first sorting, word
--- boundary enforcement, and the Logger shim live in the shared module. This
--- file is intentionally minimal — it only adjusts the Lua search path and
--- delegates to the canonical implementation.
--- ==============================================================================

-- Resolve the path to shared/lua/ relative to this file's location so the
-- engine can be required without the caller needing to configure LUA_PATH.
-- __FILE__ is not available in standard Lua; we use a debug trick that works
-- in both LuaJIT and Lua 5.4 (which both support debug.getinfo).
local _this_file = debug.getinfo(1, "S").source:gsub("^@", "")
-- Navigate: …/linux/modules/hotstrings/ → …/linux/ → …/shared/lua/
local _linux_root = _this_file:match("^(.*[/\\])modules[/\\]hotstrings[/\\]")
local _shared_lua = _linux_root and (_linux_root .. "../../shared/lua") or nil

if _shared_lua then
	-- Prepend to package.path only when the entry is not already present.
	local entry = _shared_lua .. "/?.lua"
	if not package.path:find(entry, 1, true) then
		package.path = entry .. ";" .. package.path
	end
end

-- Delegate entirely to the shared implementation.
return require("hotstring_engine")
