--- infra/native_directory.lua

--- ==============================================================================
--- MODULE: Native Directory Listing (Linux)
--- DESCRIPTION:
--- Lists directories and walks trees in this process through libuv, for the
--- callers that used to fork `find` for it: the hotstring pack discovery
--- (modules/hotstrings/loader.lua) and the log retention purge
--- (infra/logger_sink.lua).
---
--- FEATURES & RATIONALE:
--- 1. GNU `find -P` semantics, kept exactly. walk() visits the root, then every
---    entry depth-first in pre-order, the children of a directory in the
---    kernel's readdir order (the order GNU find's fts keeps below its
---    10 000-entry inode-sort threshold). A symbolic link is reported, never
---    followed; a root spelled with a trailing slash resolves through the
---    kernel, as it does for find. Child paths are composed the way find prints
---    them, so the same tree yields byte-identical paths in the same order.
--- 2. Kinds come from the directory entry (d_type); lstat(2) answers only when
---    the filesystem does not report one.
--- 3. Every native refusal reaches the caller with libuv's error code, so a
---    caller can admit absence on ENOENT alone. A name no directory entry can
---    carry (empty, a slash, a NUL) raises: it would become a wrong path.
--- 4. No logger dependency: the logger sink lists its folder through this
---    module before any adapter loads.
--- 5. luv is captured at load. The daemon cannot start without it, so a runtime
---    without it raises at the first call instead of answering "empty".
--- ==============================================================================

local M = {}





-- =================================
-- =================================
-- ======= 1/ Native Backend =======
-- =================================
-- =================================

--- Directory entries returned per readdir round trip.
local READDIR_BATCH = 64

--- libuv entry and stat types this module names; any other one is "other".
local KINDS = { file = "file", directory = "directory", link = "link" }

local Native = (function()
	local ok, uv = pcall(require, "luv")
	if not ok or type(uv) ~= "table" then return nil end
	for _, name in ipairs({ "fs_opendir", "fs_readdir", "fs_closedir", "fs_lstat" }) do
		if type(uv[name]) ~= "function" then return nil end
	end
	return { opendir = uv.fs_opendir, readdir = uv.fs_readdir, closedir = uv.fs_closedir, lstat = uv.fs_lstat }
end)()

--- Returns the captured backend, or raises when the runtime has none.
--- @return table
local function native()
	if Native == nil then
		error("native_directory: luv with fs_opendir, fs_readdir, fs_closedir and fs_lstat is required", 3)
	end
	return Native
end





-- ==========================
-- ==========================
-- ======= 2/ Listing =======
-- ==========================
-- ==========================

--- Composes a child path the way find prints it: one trailing slash of the
--- parent is dropped before the separator, so "d/" gives "d/x" and "d//"
--- gives "d//x".
--- @param parent string Directory path.
--- @param name string Entry name.
--- @return string
function M.join(parent, name)
	local base = parent:sub(-1) == "/" and parent:sub(1, -2) or parent
	return base .. "/" .. name
end

--- lstat(2) of a path: its own kind and modification time, a final symbolic
--- link not followed.
--- @param path string
--- @return table|nil stat { kind = "file"|"directory"|"link"|"other",
---   modified = seconds since the epoch with the fraction, or nil when the
---   backend reported no modification time }.
--- @return string|nil message libuv's refusal.
--- @return string|nil code libuv's error code (e.g. "ENOENT").
function M.stat(path)
	local stat, message, code = native().lstat(path)
	if type(stat) ~= "table" then return nil, message, code end
	local mtime, modified = stat.mtime, nil
	if type(mtime) == "table" and type(mtime.sec) == "number" and type(mtime.nsec) == "number" then
		modified = mtime.sec + mtime.nsec / 1e9
	end
	return { kind = KINDS[stat.type] or "other", modified = modified }
end

--- Kind of a path itself, without following a final symbolic link.
--- @param path string
--- @return string|nil kind "file", "directory", "link" or "other".
--- @return string|nil message libuv's refusal.
--- @return string|nil code libuv's error code (e.g. "ENOENT").
function M.kind(path)
	local stat, message, code = M.stat(path)
	if stat == nil then return nil, message, code end
	return stat.kind
end

--- Lists a directory's entries in the kernel's readdir order, without "." and
--- "..". A listing the kernel refuses part-way is refused whole.
--- @param path string Directory path.
--- @return table|nil entries Array of { name = string, kind = string }.
--- @return string|nil message libuv's refusal.
--- @return string|nil code libuv's error code.
function M.entries(path)
	local backend = native()
	local dir, open_message, open_code = backend.opendir(path, nil, READDIR_BATCH)
	if dir == nil then return nil, open_message, open_code end
	local listed, names, read_message, read_code = pcall(function()
		local found = {}
		while true do
			local batch, message, code = backend.readdir(dir)
			if batch == nil then
				if message ~= nil then return nil, message, code end
				return found
			end
			for _, entry in ipairs(batch) do
				local name = type(entry) == "table" and entry.name or nil
				if type(name) ~= "string" or name == "" or name:find("[/%z]") then
					error("native_directory: the native listing of " .. path .. " returned an invalid entry name", 0)
				end
				if name ~= "." and name ~= ".." then found[#found + 1] = { name = name, type = entry.type } end
			end
		end
	end)
	local closed, close_message, close_code = backend.closedir(dir)
	if not listed then error(names, 0) end
	if names == nil then return nil, read_message, read_code end
	if closed ~= true then return nil, close_message or "closedir refused", close_code end
	local entries = {}
	for index, entry in ipairs(names) do
		local kind = KINDS[entry.type]
		if kind == nil and entry.type ~= nil and entry.type ~= "unknown" then kind = "other" end
		-- No d_type from this filesystem: lstat answers, and an entry that
		-- vanished meanwhile is neither a file nor a directory.
		if kind == nil then kind = M.kind(M.join(path, entry.name)) or "other" end
		entries[index] = { name = entry.name, kind = kind }
	end
	return entries
end

--- Walks a tree as `find -P <root> [-maxdepth <max_depth>]` does: visit(path,
--- kind, depth) runs for the root (depth 0) and then for every entry below it,
--- depth-first in pre-order. A directory at max_depth is visited but not
--- listed; a symbolic link is never followed.
--- @param root string Starting path.
--- @param max_depth number|nil Deepest level visited; nil walks the whole tree.
--- @param visit function(path, kind, depth)
--- @param on_error function|nil(path, message, code) A root that cannot be
---   inspected or a directory that cannot be listed; the walk continues.
function M.walk(root, max_depth, visit, on_error)
	if type(root) ~= "string" or root == "" or root:find("%z") then
		error("native_directory: walk() needs a nonempty path without NUL", 2)
	end
	if type(visit) ~= "function" then error("native_directory: walk() needs a visit function", 2) end
	local kind, message, code = M.kind(root)
	if kind == nil then
		if on_error then on_error(root, message, code) end
		return
	end
	local function descend(path, path_kind, depth)
		visit(path, path_kind, depth)
		if path_kind ~= "directory" or (max_depth ~= nil and depth >= max_depth) then return end
		local entries, list_message, list_code = M.entries(path)
		if entries == nil then
			if on_error then on_error(path, list_message, list_code) end
			return
		end
		for _, entry in ipairs(entries) do descend(M.join(path, entry.name), entry.kind, depth + 1) end
	end
	descend(root, kind, 0)
end

return M
