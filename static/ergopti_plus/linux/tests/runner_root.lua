--- tests/runner_root.lua

--- ==============================================================================
--- MODULE: Native Linux Test Runner Root
--- DESCRIPTION:
--- Resolves the shared unit and E2E bootstrap from its own native file before
--- package.path, logging or configuration can be loaded. Realpath uses the actual
--- process cwd for a relative entry and preserves every legal POSIX filename byte.
--- Windows alone treats a backslash as a separator; WSL uses the POSIX branch.
--- ==============================================================================

local source = debug.getinfo(1, "S").source
assert(source:sub(1, 1) == "@", "the test bootstrap needs its native source file")
local native, detail = require("luv").fs_realpath(source:sub(2))
assert(type(native) == "string" and native ~= "", detail or "the test bootstrap path could not be resolved")
if package.config:sub(1, 1) == "\\" then native = native:gsub("\\", "/") end
return assert(native:match("^(.*)/tests/runner_root%.lua$"), "the test bootstrap is outside its driver root")
