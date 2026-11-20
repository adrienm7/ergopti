--- ai/engine/ollama/runtime_seal.lua

--- ==============================================================================
--- MODULE: Managed Ollama Runtime Seal (Linux)
--- DESCRIPTION:
--- Binds an installed runtime tree to the pinned archive it was extracted from:
--- the SHA-256 of every regular file, written once right after the install that
--- checked the archive against ollama_release.json, then re-hashed before each
--- start, as Windows re-hashes every file of its manifest and macOS its binary.
---
--- FEATURES & RATIONALE:
--- 1. Re-hashed at every start, not admitted by a change token. The size, mtime,
---    ctime and inode the descriptor already fences (installed_runtime.lua) say
---    whether a file was replaced or written through the file API since it was
---    captured; they say nothing of the bytes: a disk or filesystem fault, a
---    write below the file API or through a shared mapping, and a filesystem
---    whose timestamps are coarser than a write all keep the token while the
---    bytes change, and a token cannot prove the bytes came from the pinned
---    archive. A token would therefore not keep the guarantee Windows and macOS
---    give. The hash runs in a sha256sum child, off the event loop, under the
---    start's own budget: a few seconds for the 1.4 GB archive's files.
--- 2. The seal lives beside the tree, in its release folder, not inside it: the
---    descriptor fences the tree's own folders, which a new file would change.
--- 3. It names the archive digest of the release folder, so a seal copied from
---    another release, or a tree whose files differ from it in number, name or
---    bytes, is refused; an unsealed tree (one installed before seals existed)
---    is refused too and must be installed again.
--- ==============================================================================

local M = {}

local Json = require("core.text.engine.json")

local available, native = pcall(require, "luv")
if not available then native = nil end

-- The seal's name in the release folder (runtimes/ollama/<release>/).
M.NAME = "ollama.sha256.json"
local SCHEMA = 1
-- A seal names a few hundred files at most; anything larger is not one.
local MAX_SEAL_BYTES = 1048576
local PRIVATE_FILE_MODE = 384





-- =================================
-- =================================
-- ======= 1/ Digest Command =======
-- =================================
-- =================================

--- The shell-free command that hashes the files, NUL-terminated per file.
--- @param paths table Absolute file paths.
--- @return string program
--- @return table args
function M.command(paths)
	local args = { "--zero", "--" }
	for _, path in ipairs(paths) do args[#args + 1] = path end
	return "sha256sum", args
end

--- Reads a sha256sum --zero receipt naming exactly the requested files.
--- @param result table Settled process receipt { ok, exit_code, stdout }.
--- @param paths table The paths given to M.command.
--- @return table|nil digests Map path -> lowercase hex digest.
--- @return string|nil reason
function M.digests(result, paths)
	if type(result) ~= "table" or result.ok ~= true or result.exit_code ~= 0 or type(result.stdout) ~= "string" then
		return nil, "runtime_seal_hash_failed"
	end
	local expected, digests, count = {}, {}, 0
	for _, path in ipairs(paths) do expected[path] = true end
	local consumed = 0
	for digest, path in result.stdout:gmatch("([0-9a-f]+)  ([^%z]+)%z") do
		consumed = consumed + #digest + 2 + #path + 1
		if #digest ~= 64 or not expected[path] or digests[path] then return nil, "runtime_seal_hash_failed" end
		digests[path], count = digest, count + 1
	end
	if consumed ~= #result.stdout or count ~= #paths then return nil, "runtime_seal_hash_failed" end
	return digests
end





-- ================================
-- ================================
-- ======= 2/ Seal Contents =======
-- ================================
-- ================================

--- The path of each file relative to the tree root.
--- @param root string
--- @param path string
--- @return string|nil relative
local function relative(root, path)
	if path:sub(1, #root + 1) ~= root .. "/" then return nil end
	return path:sub(#root + 2)
end

--- Renders the seal of a tree.
--- @param root string The tree (plan.directory).
--- @param digests table Map absolute path -> digest.
--- @param archive_sha256 string The pinned archive digest.
--- @return string|nil text
function M.encode(root, digests, archive_sha256)
	local names = {}
	local files = {}
	for path, digest in pairs(digests) do
		local name = relative(root, path)
		if not name then return nil end
		names[#names + 1] = name
		files[name] = digest
	end
	table.sort(names)
	local rows = {}
	for _, name in ipairs(names) do rows[#rows + 1] = Json.encode(name) .. ":" .. Json.encode(files[name]) end
	return '{"schema":' .. SCHEMA .. ',"archive_sha256":' .. Json.encode(archive_sha256)
		.. ',"files":{' .. table.concat(rows, ",") .. "}}\n"
end

--- Compares a seal with freshly hashed files.
--- @param text string The seal's bytes.
--- @param root string The tree (plan.directory).
--- @param digests table Map absolute path -> digest, every file of the tree.
--- @param archive_sha256 string The pinned archive digest.
--- @return boolean matches
--- @return string|nil reason
function M.matches(text, root, digests, archive_sha256)
	local decoded = type(text) == "string" and Json.decode_lossless(text) or nil
	if type(decoded) ~= "table" or decoded.schema ~= SCHEMA or type(decoded.files) ~= "table" then
		return false, "runtime_seal_unreadable"
	end
	if decoded.archive_sha256 ~= archive_sha256 then return false, "runtime_seal_foreign" end
	local seen = 0
	for path, digest in pairs(digests) do
		local name = relative(root, path)
		if not name or decoded.files[name] ~= digest then return false, "runtime_seal_mismatch" end
		seen = seen + 1
	end
	for _ in pairs(decoded.files) do seen = seen - 1 end
	if seen ~= 0 then return false, "runtime_seal_mismatch" end
	return true
end





-- ============================
-- ============================
-- ======= 3/ Seal File =======
-- ============================
-- ============================

local DEFAULT_FS = {
	read = function(path)
		local handle, _, code = io.open(path, "rb")
		if not handle then return nil, code == 2 and "runtime_seal_missing" or "runtime_seal_unreadable" end
		local text = handle:read(MAX_SEAL_BYTES + 1)
		handle:close()
		if type(text) ~= "string" or #text > MAX_SEAL_BYTES then return nil, "runtime_seal_unreadable" end
		return text
	end,
	--- Writes the seal whole, then renames it into place: only the install that
	--- just checked the archive writes one, so an earlier seal is stale.
	write = function(path, text)
		if not native then return false end
		local partial = path .. ".partial"
		local ok, fd = pcall(native.fs_open, partial, "w", PRIVATE_FILE_MODE)
		if not ok or type(fd) ~= "number" then return false end
		local written = native.fs_write(fd, text, 0)
		local synced = native.fs_fsync(fd)
		local closed = native.fs_close(fd)
		if written ~= #text or synced == nil or closed == nil then
			pcall(native.fs_unlink, partial)
			return false
		end
		return native.fs_rename(partial, path) ~= nil
	end,
}

--- Reads the seal of a release folder.
--- @param path string
--- @param fs table|nil { read } (tests).
--- @return string|nil text
--- @return string|nil reason runtime_seal_missing or runtime_seal_unreadable.
function M.read(path, fs)
	return (fs or DEFAULT_FS).read(path)
end

--- Writes the seal of a release folder once.
--- @param path string
--- @param text string
--- @param fs table|nil { write } (tests).
--- @return boolean written
function M.write(path, text, fs)
	local ok, written = pcall((fs or DEFAULT_FS).write, path, text)
	return ok and written == true
end

return M
