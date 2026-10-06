--- modules/llm/ollama_install_files.lua

--- ==============================================================================
--- MODULE: User-Local Ollama Installation Files (Linux)
--- DESCRIPTION:
--- Owns private staging and native filesystem receipts for an explicitly chosen
--- official archive. Download and process lifecycle remain external capabilities.
--- Publication never replaces a foreign target; cleanup visits only captured
--- private directory identities and never follows symbolic links.
--- ==============================================================================

local M = {}
local available, native = pcall(require, "luv")
if not available then native = nil end

local PRIVATE_DIRECTORY_MODE = 448
local PRIVATE_FILE_MODE = 384
local EXECUTABLE_MODE = 493





-- ========================================
-- ========================================
-- ======= 1/ Native File Receipts =========
-- ========================================
-- ========================================

--- Accepts an absolute POSIX path without ambiguous traversal components.
--- @param path any
--- @return boolean
local function absolute(path)
	if type(path) ~= "string" or path:sub(1, 1) ~= "/" or path:find("\0", 1, true) then return false end
	for component in path:gmatch("[^/]+") do
		if component == "." or component == ".." then return false end
	end
	return true
end

--- Interprets one synchronous native syscall receipt.
--- @param fn function
--- @param ... any
--- @return boolean
local function acknowledged(fn, ...)
	local ok, result, detail = pcall(fn, ...)
	return ok and (result == true or result == 0) and detail == nil
end

--- Retains the kernel identity of an owned private directory or archive.
--- @param value any
--- @param kind string
--- @param uid number
--- @return table|nil
local function identity(value, kind, uid)
	if type(value) ~= "table" or value.type ~= kind or value.uid ~= uid
		or type(value.dev) ~= "number" or type(value.ino) ~= "number" then return nil end
	return { dev = value.dev, ino = value.ino, uid = value.uid, type = value.type }
end

--- Compares native object identity without accepting a same-named replacement.
--- @param first table|nil
--- @param second any
--- @return boolean
local function same(first, second)
	return first ~= nil and type(second) == "table" and first.dev == second.dev
		and first.ino == second.ino and first.uid == second.uid and first.type == second.type
end





-- ========================================
-- ========================================
-- ======= 2/ Private Native Owner =========
-- ========================================
-- ========================================

--- Creates a per-user installation-file owner without writing anything.
--- @param directory string Resolver-owned absolute directory ending in /ollama.
--- @param backend table|nil Native libuv binding, or an explicit test backend.
--- @return table|nil owner
--- @return string|nil reason
function M.new(directory, backend)
	local fs = backend or native
	if not absolute(directory) or directory:sub(-7) ~= "/ollama" then return nil, "install_directory_invalid" end
	if not fs then return nil, "native_filesystem_unavailable" end
	for _, name in ipairs({ "getuid", "fs_lstat", "fs_access", "fs_mkdir", "fs_mkdtemp",
		"fs_open", "fs_close", "fs_chmod", "fs_scandir", "fs_scandir_next", "fs_unlink", "fs_rmdir" }) do
		if type(fs[name]) ~= "function" then return nil, "native_filesystem_unavailable" end
	end
	local ok_uid, uid = pcall(fs.getuid)
	if not ok_uid or type(uid) ~= "number" or uid < 0 or uid % 1 ~= 0 then return nil, "native_user_identity_unavailable" end
	local parent = assert(directory:match("^(.*)/[^/]+$"))
	if parent == "" then return nil, "install_parent_invalid" end
	local owner = { directory = directory, published = false }
	local directories, descriptors = {}, {}
	local prepared, checksum_admitted, extraction_admitted = false, false, false
	local archive_identity, stage_identity, verified_size
	local paths = {}

	local function stat(path)
		local called, value, _, code = pcall(fs.fs_lstat, path)
		if not called then return nil, "native_stat_refused" end
		if value == nil then return nil, code == "ENOENT" and "absent" or "native_stat_refused" end
		if type(value) ~= "table" then return nil, "native_stat_malformed" end
		return value
	end

	local function ensure_directory(path, owned)
		local value, reason = stat(path)
		if not value then
			if reason ~= "absent" then return false, reason end
			local ancestor = path:match("^(.*)/[^/]+$")
			if ancestor == "" then ancestor = "/" end
			if not ancestor then return false, "install_parent_invalid" end
			local accepted, failure = ensure_directory(ancestor, false)
			if not accepted then return false, failure end
			if not acknowledged(fs.fs_mkdir, path, PRIVATE_DIRECTORY_MODE) then return false, "install_parent_create_refused" end
			value, reason = stat(path)
			if not value then return false, reason end
		end
		if value.type ~= "directory" then return false, "install_parent_not_directory" end
		if owned then
			if value.uid ~= uid or type(value.mode) ~= "number" then return false, "install_parent_not_owned" end
			-- Group/other write access could replace the private stage's name.
			if math.floor(value.mode / 16) % 2 == 1 or math.floor(value.mode / 2) % 2 == 1 then
				return false, "install_parent_writable_by_others"
			end
		end
		return true
	end

	local function private_directory(prefix)
		local called, path = pcall(fs.fs_mkdtemp, parent .. "/" .. prefix .. "XXXXXX")
		if not called or not absolute(path) or path:sub(1, #parent + #prefix + 1) ~= parent .. "/" .. prefix
			or path:sub(#parent + 2):find("/", 1, true) then
			return nil, "install_stage_create_refused"
		end
		local record = { path = path }
		directories[#directories + 1] = record
		local value = stat(path)
		record.identity = identity(value, "directory", uid)
		if not record.identity then return nil, "install_stage_identity_refused" end
		if not acknowledged(fs.fs_chmod, path, PRIVATE_DIRECTORY_MODE) then return nil, "install_stage_permissions_refused" end
		return path, record.identity
	end

	local function exact_directory(path, expected)
		return same(expected, stat(path))
	end

	local function remove_tree(path)
		local value, reason = stat(path)
		if not value then return reason == "absent" end
		if value.type ~= "directory" then return acknowledged(fs.fs_unlink, path) end
		local called, iterator = pcall(fs.fs_scandir, path)
		if not called or not iterator then return false end
		while true do
			local scanned, name, kind, code = pcall(fs.fs_scandir_next, iterator)
			if not scanned or code ~= nil then return false end
			if name == nil then
				if kind ~= nil then return false end
				break
			end
			if type(kind) ~= "string" or type(name) ~= "string" or name == "." or name == ".."
				or name:find("/", 1, true) or name:find("\0", 1, true) then return false end
			if not remove_tree(path .. "/" .. name) then return false end
		end
		return acknowledged(fs.fs_rmdir, path)
	end

	--- Prepares private staging beside the final directory on its filesystem.
	--- @return table|nil paths { archive, stage, directory }.
	--- @return string|nil reason
	function owner.prepare()
		if prepared or #directories > 0 then return nil, "install_prepare_already_owned" end
		local target, target_reason = stat(directory)
		if target or target_reason ~= "absent" then return nil, "install_target_not_absent" end
		local accepted, reason = ensure_directory(parent, true)
		if not accepted then return nil, reason end
		local workspace, workspace_reason = private_directory(".ollama-download-")
		if not workspace then return nil, workspace_reason end
		local stage, stage_receipt = private_directory(".ollama-stage-")
		if not stage then return nil, stage_receipt end
		paths.archive, paths.stage, paths.directory = workspace .. "/archive.tar.zst", stage, directory
		stage_identity = stage_receipt
		local called, descriptor = pcall(fs.fs_open, paths.archive, "wx", PRIVATE_FILE_MODE)
		if not called or type(descriptor) ~= "number" then return nil, "install_archive_create_refused" end
		descriptors[descriptor] = true
		archive_identity = identity(stat(paths.archive), "file", uid)
		if not archive_identity then return nil, "install_archive_identity_refused" end
		if not acknowledged(fs.fs_close, descriptor) then return nil, "install_archive_close_refused" end
		descriptors[descriptor] = nil
		prepared = true
		return { archive = paths.archive, stage = paths.stage, directory = paths.directory }
	end

	--- Requires the exact downloaded regular file and the pinned byte count.
	--- @param asset table Canonical { bytes }.
	--- @return boolean
	--- @return string|nil reason
	function owner.admit_size(asset)
		if not prepared or type(asset) ~= "table" or type(asset.bytes) ~= "number" or asset.bytes <= 0
			or asset.bytes % 1 ~= 0 then return false, "archive_size_unavailable" end
		local value = stat(paths.archive)
		if not same(archive_identity, value) then return false, "archive_identity_changed" end
		if value.size ~= asset.bytes then return false, "archive_size_mismatch" end
		return true
	end

	--- Builds the shell-free GNU checksum command with an unescaped NUL receipt.
	--- @return string|nil program
	--- @return table|string args or refusal reason.
	function owner.hash_command()
		if not prepared then return nil, "install_not_prepared" end
		return "sha256sum", { "--zero", "--", paths.archive }
	end

	--- Admits a successful complete checksum receipt for the exact archive name.
	--- @param asset table Canonical { sha256, bytes }.
	--- @param result table Exact physically settled process receipt.
	--- @return boolean
	--- @return string|nil reason
	function owner.admit_checksum(asset, result)
		checksum_admitted, verified_size = false, nil
		local sized, reason = owner.admit_size(asset)
		if not sized then return false, reason end
		if type(result) ~= "table" or result.ok ~= true or result.exit_code ~= 0 or type(result.stdout) ~= "string" then
			return false, "archive_checksum_receipt_refused"
		end
		local digest, path = result.stdout:match("^([0-9a-f]+)  (.*)%z$")
		if type(asset.sha256) ~= "string" or #asset.sha256 ~= 64 or #tostring(digest) ~= 64
			or digest ~= asset.sha256 or path ~= paths.archive then return false, "archive_checksum_mismatch" end
		checksum_admitted = true
		verified_size = asset.bytes
		return true
	end

	--- Builds extraction only after the authoritative digest passed.
	--- @return string|nil program
	--- @return table|string args or refusal reason.
	function owner.extract_command()
		if not checksum_admitted then return nil, "archive_not_verified" end
		local archive = stat(paths.archive)
		if not same(archive_identity, archive) then return nil, "archive_identity_changed" end
		if archive.size ~= verified_size then return nil, "archive_size_mismatch" end
		if not exact_directory(paths.stage, stage_identity) then return nil, "archive_not_verified" end
		return "tar", { "--zstd", "--extract", "--file", paths.archive, "--directory", paths.stage,
			"--no-same-owner", "--no-same-permissions" }
	end

	--- Requires a complete regular executable and the archive's runtime library tree.
	--- @param result table Exact physically settled extraction receipt.
	--- @return boolean
	--- @return string|nil reason
	function owner.admit_extraction(result)
		extraction_admitted = false
		if not checksum_admitted or type(result) ~= "table" or result.ok ~= true or result.exit_code ~= 0
			or not exact_directory(paths.stage, stage_identity) then return false, "archive_extraction_refused" end
		-- lstat does not protect intermediate components. Reject bin/lib links
		-- before looking up or chmod'ing any descendant outside the private tree.
		local bin = identity(stat(paths.stage .. "/bin"), "directory", uid)
		local lib = identity(stat(paths.stage .. "/lib"), "directory", uid)
		if not bin or not lib then return false, "archive_runtime_tree_incomplete" end
		local binary = stat(paths.stage .. "/bin/ollama")
		local libraries = stat(paths.stage .. "/lib/ollama")
		if not identity(binary, "file", uid) or not identity(libraries, "directory", uid) then
			return false, "archive_runtime_tree_incomplete"
		end
		if not same(bin, stat(paths.stage .. "/bin")) or not same(lib, stat(paths.stage .. "/lib")) then
			return false, "archive_runtime_tree_changed"
		end
		if not acknowledged(fs.fs_chmod, paths.stage .. "/bin/ollama", EXECUTABLE_MODE)
			or not acknowledged(fs.fs_access, paths.stage .. "/bin/ollama", "X") then
			return false, "archive_binary_not_executable"
		end
		extraction_admitted = true
		return true
	end

	--- Builds no-clobber publication; a zero exit alone cannot prove it moved.
	--- @return string|nil program
	--- @return table|string args or refusal reason.
	function owner.publish_command()
		if not extraction_admitted or not exact_directory(paths.stage, stage_identity) then return nil, "install_stage_not_admitted" end
		return "mv", { "--no-clobber", "--no-target-directory", "--", paths.stage, directory }
	end

	--- Observes an actual atomic identity transfer, including late cancellation.
	--- @return boolean published
	function owner.observe_publication()
		if not extraction_admitted then return false end
		local stage, reason = stat(paths.stage)
		if stage or reason ~= "absent" then return false end
		if not same(stage_identity, stat(directory)) then return false end
		owner.published = true
		return true
	end

	--- Qualifies successful publication without replacing skipped foreign targets.
	--- @param result table Exact physically settled publication receipt.
	--- @return boolean
	--- @return string|nil reason
	function owner.admit_publication(result)
		if type(result) ~= "table" or result.ok ~= true or result.exit_code ~= 0 then return false, "install_publication_refused" end
		if not owner.observe_publication() then return false, "install_publication_not_owned" end
		return true
	end

	--- Removes only captured unpublished paths after external capabilities settle.
	--- The caller owns that settlement prerequisite; this method never cancels work.
	--- @return boolean
	function owner.cleanup()
		owner.observe_publication()
		for descriptor in pairs(descriptors) do
			if not acknowledged(fs.fs_close, descriptor) then return false end
			descriptors[descriptor] = nil
		end
		for _, record in ipairs(directories) do
			local current, reason = stat(record.path)
			if current then
				if not same(record.identity, current) or not remove_tree(record.path) then return false end
			elseif reason ~= "absent" then return false end
		end
		return true
	end

	return owner
end

return M
