--- adapters/write_lock_path.lua

--- ==============================================================================
--- MODULE: Cooperative Write-Lock Pathname
--- DESCRIPTION:
--- Names the stable lock inode that every cooperating Ergopti writer takes
--- before it publishes, replaces or removes one destination.
---
--- FEATURES & RATIONALE:
--- 1. One per-user directory: a lock inode cannot be unlinked after use (a
---    waiter would lock the orphan while a newcomer locks a fresh one), so a
---    lock beside its destination stayed forever next to every result,
---    settings file and export, and inside private directories whose exact
---    census then refused them (the field run of 2026-10-31 kept an Ollama
---    pull slot over `authority.json.ergoptiplus-write-lock-v1`).
--- 2. Fixed-length names: FNV-1a 64 of the canonical destination spelling, so
---    a long path never exceeds the file-name limit. A collision only makes two
---    destinations share one mutex.
--- 3. Pure: no I/O, so file_system and its test fixtures derive the same name.
--- ==============================================================================

local M = {}

local NativePath = require("native_path")

M.SUFFIX = ".ergoptiplus-write-lock-v1"
M.DIRECTORY = "Library/Application Support/ErgoptiPlus/write-locks"

local FNV64_OFFSET_BASIS = -3750763034362895579 -- 0xcbf29ce484222325 as a signed integer
local FNV64_PRIME = 1099511628211

--- Derives the lock pathname of one canonical destination spelling.
--- @param canonical_path string Destination with `.`/`..` segments removed.
--- @param home string|nil The user's home directory.
--- @return string|nil lock_path Absolute lock pathname.
--- @return string|nil error_message Why no lock pathname can be derived.
function M.for_canonical(canonical_path, home)
	if type(canonical_path) ~= "string" or canonical_path == "" then
		return nil, "the destination spelling is empty"
	end
	if type(home) ~= "string" or home:sub(1, 1) ~= "/" then
		return nil, "HOME is not an absolute path; the cooperative write-lock directory is unknown"
	end
	-- Lua integers wrap on overflow, which is exactly the FNV modulus 2^64.
	local digest = FNV64_OFFSET_BASIS
	for index = 1, #canonical_path do
		digest = (digest ~ canonical_path:byte(index)) * FNV64_PRIME
	end
	return NativePath.without_trailing_separators(home) .. "/" .. M.DIRECTORY
		.. "/" .. string.format("%016x", digest) .. M.SUFFIX
end

return M
