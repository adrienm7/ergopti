--- modules/llm/ollama_installed_runtime.lua

--- Reads a canonical managed runtime without spawning, writing or acquiring FDs.
--- The descriptor fences observed native inventory drift; its logical release
--- never represents process exit, immutable bytes or a physical executable lease.
local M = {}
local available, native = pcall(require, "luv")
if not available then native = nil end

local function timestamp(value)
	if type(value) ~= "table" or type(value.sec) ~= "number" or type(value.nsec) ~= "number" then return nil end
	return { sec = value.sec, nsec = value.nsec }
end

local function identity(value, uid)
	if type(value) ~= "table" or value.uid ~= uid or type(value.mode) ~= "number"
		or type(value.dev) ~= "number" or type(value.ino) ~= "number" or type(value.size) ~= "number" then return nil end
	local mtime, ctime = timestamp(value.mtime), timestamp(value.ctime)
	if not mtime or not ctime then return nil end
	if value.type ~= "directory" and value.type ~= "file" and value.type ~= "link" then return nil end
	if value.type ~= "link" and (math.floor(value.mode / 16) % 2 ~= 0 or math.floor(value.mode / 2) % 2 ~= 0) then return nil end
	return { uid = uid, mode = value.mode, dev = value.dev, ino = value.ino, size = value.size,
		type = value.type, mtime = mtime, ctime = ctime }
end

local function same(first, second)
	for _, field in ipairs({ "uid", "mode", "dev", "ino", "size", "type", "target", "resolved" }) do
		if first[field] ~= second[field] then return false end
	end
	for _, field in ipairs({ "mtime", "ctime" }) do
		if first[field].sec ~= second[field].sec or first[field].nsec ~= second[field].nsec then return false end
	end
	return true
end

--- Captures a read-only inventory for the exact managed release target.
--- @param resolver table Native immutable plan/current owner.
--- @param backend table|nil Native libuv binding or explicit controlled backend.
--- @return table result { status = installed|missing|unavailable, runtime?, reason? }.
function M.capture(resolver, backend)
	local fs = backend or native
	local function unavailable(reason) return { status = "unavailable", reason = reason } end
	if type(resolver) ~= "table" or type(resolver.plan) ~= "function" or type(resolver.current) ~= "function" then
		return unavailable("installed_runtime_resolver_unavailable")
	end
	for _, name in ipairs({ "getuid", "fs_lstat", "fs_access", "fs_scandir", "fs_scandir_next", "fs_readlink", "fs_realpath" }) do
		if type(fs) ~= "table" or type(fs[name]) ~= "function" then return unavailable("installed_runtime_native_unavailable") end
	end
	local get_plan, ancestry = resolver.plan, resolver.current
	local planned, plan = pcall(get_plan)
	if not planned or type(plan) ~= "table" or type(plan.directory) ~= "string"
		or type(plan.executable) ~= "string" or type(plan.libraries) ~= "string" or type(plan.uid) ~= "number" then
		return unavailable("installed_runtime_plan_unavailable")
	end
	local directory, executable, libraries, uid = plan.directory, plan.executable, plan.libraries, plan.uid
	local function rooted()
		local called, actual = pcall(fs.getuid)
		if not called or actual ~= uid then return false end
		local checked, receipt = pcall(ancestry)
		return checked and receipt == true
	end
	local function stat(path)
		local called, value, _, code = pcall(fs.fs_lstat, path)
		if not called then return nil, "installed_runtime_stat_refused" end
		if value == nil then return nil, code == "ENOENT" and "absent" or "installed_runtime_stat_refused" end
		local receipt = identity(value, uid)
		return receipt, receipt == nil and "installed_runtime_identity_refused" or nil
	end
	if not rooted() then return unavailable("installed_runtime_ancestry_stale") end
	local target, reason = stat(directory)
	if not target then
		if reason == "absent" and rooted() then return { status = "missing" } end
		return unavailable(reason)
	end
	if target.type ~= "directory" then return unavailable("installed_runtime_tree_invalid") end
	local function inventory()
		if not rooted() then return nil, "installed_runtime_ancestry_stale" end
		local records, library_files = {}, 0
		local function scan(path)
			local receipt, failure = stat(path)
			if not receipt then return false, failure end
			records[path] = receipt
			if receipt.type == "file" then library_files = library_files + 1 return true end
			if receipt.type == "link" then
				local read, value = pcall(fs.fs_readlink, path)
				local resolved, actual = pcall(fs.fs_realpath, path)
				if not read or type(value) ~= "string" or not resolved or type(actual) ~= "string"
					or actual:sub(1, #libraries + 1) ~= libraries .. "/" then return false, "installed_runtime_library_link_unavailable" end
				receipt.target, receipt.resolved = value, actual
				return true
			end
			local called, iterator = pcall(fs.fs_scandir, path)
			if not called or not iterator then return false, "installed_runtime_scan_refused" end
			while true do
				local listed, name, kind, code = pcall(fs.fs_scandir_next, iterator)
				if not listed or code ~= nil then return false, "installed_runtime_scan_refused" end
				if name == nil then if kind ~= nil then return false, "installed_runtime_scan_refused" end break end
				if type(name) ~= "string" or name == "." or name == ".." or name:find("/", 1, true) or name:find("\0", 1, true) then
					return false, "installed_runtime_scan_refused"
				end
				local admitted, nested_reason = scan(path .. "/" .. name)
				if not admitted then return false, nested_reason end
			end
			return true
		end
		for _, path in ipairs({ directory, directory .. "/bin", directory .. "/lib", libraries }) do
			local receipt, failure = stat(path)
			if not receipt or receipt.type ~= "directory" then return nil, failure or "installed_runtime_tree_invalid" end
			records[path] = receipt
		end
		local binary, failure = stat(executable)
		if not binary or binary.type ~= "file" then return nil, failure or "installed_runtime_binary_invalid" end
		local checked, access, detail = pcall(fs.fs_access, executable, "X")
		if not checked or not (access == 0 or access == true) or detail ~= nil then return nil, "installed_runtime_binary_not_executable" end
		records[executable] = binary
		local admitted, scan_reason = scan(libraries)
		if not admitted then return nil, scan_reason end
		if library_files == 0 then return nil, "installed_runtime_libraries_empty" end
		if not rooted() then return nil, "installed_runtime_ancestry_stale" end
		return records
	end
	local captured, failure = inventory()
	if not captured then return unavailable(failure) end
	local released, listeners, runtime = false, {}, {}
	local function current()
		if released then return false, "installed_runtime_descriptor_released" end
		local observed, refusal = inventory()
		if not observed then return false, refusal end
		for path, receipt in pairs(captured) do
			if not observed[path] or not same(receipt, observed[path]) then return false, "installed_runtime_inventory_changed" end
			observed[path] = nil
		end
		if next(observed) ~= nil then return false, "installed_runtime_inventory_changed" end
		return true
	end
	runtime.current = current
	function runtime.executable()
		local admitted, refusal = current()
		if admitted then return executable end
		return nil, refusal
	end
	function runtime.release()
		if released then return true end
		released = true
		local pending = listeners; listeners = {}
		for _, listener in ipairs(pending) do pcall(listener) end
		return true -- No native handle was acquired by this descriptor.
	end
	runtime.cancel = runtime.release
	function runtime.is_settled() return released end
	function runtime.on_settled(listener)
		if type(listener) ~= "function" then return false end
		if released then pcall(listener) else listeners[#listeners + 1] = listener end
		return true
	end
	local admitted, stale_reason = current()
	if not admitted then return unavailable(stale_reason) end
	return { status = "installed", runtime = runtime }
end

return M
