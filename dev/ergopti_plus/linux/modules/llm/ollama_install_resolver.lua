--- modules/llm/ollama_install_resolver.lua

--- ==============================================================================
--- MODULE: Native Per-User Ollama Install Resolver
--- DESCRIPTION:
--- Captures every native ancestor identity before user-local installation.
--- Rejects symlinks, traversal, other users' mutable ancestors and unsafe write
--- permissions. Preparation creates only admitted missing private directories.
--- No subprocess, daemon, download, preference write or guessed HOME is used.
--- ==============================================================================

local M = {}
local Policy = require("llm.ollama_install_policy")
local available, native = pcall(require, "luv")
if not available then native = nil end
local DIRECTORY_MODE = 448

local function accepted(fn, ...)
	local called, result, reason = pcall(fn, ...)
	return called and (result == true or result == 0) and reason == nil
end

local function snapshot(value)
	if type(value) ~= "table" or value.type ~= "directory" or type(value.uid) ~= "number"
		or type(value.mode) ~= "number" or type(value.dev) ~= "number" or type(value.ino) ~= "number" then return nil end
	return { uid = value.uid, mode = value.mode, dev = value.dev, ino = value.ino, type = value.type }
end

local function same(first, second)
	if not first or not second then return false end
	for _, field in ipairs({ "uid", "mode", "dev", "ino", "type" }) do
		if first[field] ~= second[field] then return false end
	end
	return true
end

local function safe_write_mode(mode)
	return math.floor(mode / 16) % 2 == 0 and math.floor(mode / 2) % 2 == 0
end

local function ancestors(path)
	local paths, accumulated = { "/" }, ""
	for component in path:gmatch("[^/]+") do
		accumulated = accumulated .. "/" .. component
		paths[#paths + 1] = accumulated
	end
	return paths
end

local function copy(source)
	local result = {}
	for key, value in pairs(source) do result[key] = value end
	return result
end

--- Reads only the packaged canonical asset through the installed-layout owner.
--- @return table|nil catalogue
--- @return string|nil reason
local function catalogue()
	local path = require("infra.paths").shared("modules/llm/ollama_release.json")
	if not path then return nil, "ollama_release_unreadable" end
	local file = io.open(path, "rb")
	if not file then return nil, "ollama_release_unreadable" end
	local data = file:read("*a")
	local closed = file:close()
	if not closed or type(data) ~= "string" then return nil, "ollama_release_unreadable" end
	local Json = require("json")
	local decoded = Json.decode_lossless(data)
	if type(decoded) ~= "table" or Json.is_array(decoded) then return nil, "ollama_release_unreadable" end
	return decoded
end

--- Captures a read-only per-user plan and its actual native identity receipts.
--- @param options table|nil { native, catalogue, app_dirs, environment }.
--- @return table|nil resolver
--- @return string|nil reason
function M.new(options)
	options = type(options) == "table" and options or {}
	local fs = options.native
	if fs == nil then fs = native end
	for _, name in ipairs({ "getuid", "os_uname", "fs_lstat", "fs_access", "fs_mkdir" }) do
		if type(fs) ~= "table" or type(fs[name]) ~= "function" then return nil, "native_install_resolver_unavailable" end
	end
	local called, uid = pcall(fs.getuid)
	if not called or type(uid) ~= "number" or uid < 0 or uid % 1 ~= 0 then return nil, "native_user_identity_unavailable" end
	local named, uname = pcall(fs.os_uname)
	if not named or type(uname) ~= "table" or type(uname.machine) ~= "string" then return nil, "native_architecture_unavailable" end
	local release, release_reason = options.catalogue
	if release == nil then
		local read, value, reason = pcall(catalogue)
		if not read then return nil, "ollama_release_unreadable" end
		release, release_reason = value, reason
	end
	if not release then return nil, release_reason or "ollama_release_unreadable" end
	local asset, reason = Policy.asset(release, "linux", uname.machine)
	if not asset then return nil, reason end
	local environment = {}
	if options.environment ~= nil then
		if type(options.environment) ~= "table" then return nil, "user_directories_unreadable" end
		for _, name in ipairs({ "XDG_DATA_HOME", "HOME" }) do environment[name] = rawget(options.environment, name) end
	else
		for _, name in ipairs({ "XDG_DATA_HOME", "HOME" }) do
			local ok, value = pcall(os.getenv, name)
			if not ok then return nil, "user_directories_unreadable" end
			environment[name] = value
		end
	end
	local app_dirs = options.app_dirs
	if app_dirs == nil then
		local loaded, value = pcall(require, "app_dirs")
		if not loaded then return nil, "application_directory_unreadable" end
		app_dirs = value
	end
	local plan, plan_reason = Policy.posix_plan(environment, app_dirs, asset)
	if not plan then return nil, plan_reason end
	local receipts, prepared, preparing = {}, false, false
	local resolver = {}

	local function stat(path)
		local ok, value, _, code = pcall(fs.fs_lstat, path)
		if not ok then return nil, "native_install_stat_refused" end
		if value == nil then return nil, code == "ENOENT" and "absent" or "native_install_stat_refused" end
		local identity = snapshot(value)
		if not identity then return nil, "install_ancestor_not_directory" end
		return identity
	end

	local deepest, missing
	for _, path in ipairs(ancestors(plan.parent)) do
		local value, failure = stat(path)
		if value then
			if missing then return nil, "install_ancestor_substituted" end
			if value.uid ~= uid and value.uid ~= 0 then return nil, "install_ancestor_foreign_owner" end
			if not safe_write_mode(value.mode) then return nil, "install_ancestor_writable_by_others" end
			if path == plan.data_root or path:sub(1, #plan.data_root + 1) == plan.data_root .. "/" then
				if value.uid ~= uid then return nil, "install_parent_not_owned" end
			end
			deepest = { path = path, identity = value }
		elseif failure ~= "absent" then return nil, failure
		else missing = true end
		receipts[#receipts + 1] = { path = path, identity = value }
	end
	if not deepest or deepest.identity.uid ~= uid then return nil, "install_writable_anchor_not_owned" end
	if not accepted(fs.fs_access, deepest.path, "WX") then return nil, "install_writable_anchor_unavailable" end

	--- Returns fresh snapshots; callers cannot rewrite the captured owner paths.
	--- @return table plan
	function resolver.plan()
		local result = copy(plan)
		result.uid, result.asset = uid, copy(asset)
		return result
	end

	--- Rejects observed ancestor replacements and privilege/permission changes.
	--- This is path-receipt fencing, not fd-relative hostile same-UID race proof.
	--- @return boolean
	--- @return string|nil reason
	local function current()
		local observed, live_uid = pcall(fs.getuid)
		if not observed or live_uid ~= uid then return false, "native_user_identity_changed" end
		for _, receipt in ipairs(receipts) do
			local value, failure = stat(receipt.path)
			if receipt.identity then
				if not same(receipt.identity, value) then return false, "install_ancestor_substituted" end
			elseif value or failure ~= "absent" then return false, "install_ancestor_substituted" end
		end
		return true
	end
	resolver.current = current

	--- Creates missing owner-only parents only inside explicit current consent.
	--- Created app-data parents are durable user state and are never recursively
	--- removed by this resolver. The archive-file owner cleans its private stage.
	--- @param admission table { explicit_consent, authorized }.
	--- @return boolean
	--- @return string|nil reason
	function resolver.prepare(admission)
		if preparing or prepared then return false, "install_resolver_already_prepared" end
		if type(admission) ~= "table" or admission.explicit_consent ~= true or type(admission.authorized) ~= "function" then
			return false, "install_consent_unavailable"
		end
		-- A predicate may mutate its caller's table while native preparation waits.
		-- Every later mutation belongs to this exact originating admission.
		local authorized = admission.authorized
		preparing = true
		local function admitted()
			local ok, allowed = pcall(authorized)
			return ok and allowed == true and current() == true
		end
		local function refused(failure) preparing = false return false, failure end
		for _, receipt in ipairs(receipts) do
			if not admitted() then return refused("install_source_or_parent_stale") end
			if not receipt.identity then
				if not accepted(fs.fs_mkdir, receipt.path, DIRECTORY_MODE) then return refused("install_parent_create_refused") end
				local value = stat(receipt.path)
				if not value or value.uid ~= uid or not safe_write_mode(value.mode) then return refused("install_created_parent_not_owned") end
				receipt.identity = value
			end
		end
		if not admitted() or not accepted(fs.fs_access, plan.parent, "WX") or current() ~= true then
			return refused("install_parent_admission_refused")
		end
		prepared, preparing = true, false
		return true
	end

	if current() ~= true then return nil, "install_ancestor_substituted" end
	return resolver
end

return M
