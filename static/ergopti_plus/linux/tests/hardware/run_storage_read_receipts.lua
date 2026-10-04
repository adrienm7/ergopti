--- tests/hardware/run_storage_read_receipts.lua
--- Exercises the production JSON Storage adapter with actual Linux permission
--- failures and native environment changes. An unreadable existing store must
--- never become an empty store that a subsequent mutation overwrites.
--- No filesystem API is mocked; TOML persistence is outside this fixture.
local uv = require("luv")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-storage-XXXXXX"))
local previous_xdg = uv.os_getenv("XDG_CONFIG_HOME")
local directories, files = { root }, {}
local checks, failures = 0, 0
local ORIGINAL = '{"preserve":"original","nested":{"value":"é"}}'
local operations = {
	{ name = "set", apply = function(s) return s.set("replacement", true) end },
	{ name = "set_many", apply = function(s) return s.set_many({ replacement = true }) end },
	{ name = "delete", apply = function(s) return s.delete("preserve") end },
	{ name = "clear", apply = function(s) return s.clear() end },
}

local function mkdir(path)
	assert(uv.fs_mkdir(path, 448))
	directories[#directories + 1] = path
	return path
end

local function write(path, bytes)
	local file = assert(io.open(path, "wb"))
	assert(file:write(bytes) and file:close())
	files[#files + 1] = path
end

local function read(path)
	local file = assert(io.open(path, "rb"))
	local bytes = assert(file:read("*a"))
	assert(file:close())
	return bytes
end

local function fresh(path)
	assert(uv.os_setenv("XDG_CONFIG_HOME", path))
	package.loaded["adapters.storage"] = nil
	-- Lua 5.4 also returns loader data. A final table-list call would expand
	-- that path into a second owner; expose exactly the adapter to the fixture.
	return (require("adapters.storage"))
end

--- Restores only this fixture's private paths, even after a regression fails.
local function restore_permissions()
	for _, path in ipairs(directories) do assert(uv.fs_chmod(path, 448)) end
	for _, path in ipairs(files) do
		local ok, _, code = uv.fs_chmod(path, 384)
		assert(ok or code == "ENOENT", "owned file permission restoration failed")
	end
end

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	restore_permissions()
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

assert(uv.getuid() ~= 0, "permission regressions require an unprivileged user")
for _, operation in ipairs(operations) do
	for _, refusal in ipairs({ "unreadable-file", "unsearchable-parent", "non-directory" }) do
		check(operation.name .. " rejects " .. refusal, function()
			local config = mkdir(root .. "/" .. operation.name .. "-" .. refusal)
			local parent = config .. "/ergopti_plus"
			local store = parent .. "/storage.json"
			if refusal == "non-directory" then
				write(parent, ORIGINAL)
			else
				mkdir(parent)
				write(store, ORIGINAL)
				if refusal == "unreadable-file" then assert(uv.fs_chmod(store, 0))
				else assert(uv.fs_chmod(parent, 0)) end
			end
			local storage = fresh(config)
			local accepted = operation.apply(storage)
			local recovery = storage.recovery_status()
			restore_permissions()
			assert(read(refusal == "non-directory" and parent or store) == ORIGINAL,
				"native read refusal was followed by data loss")
			assert(accepted == false, "mutation accepted an unclassified store")
			assert(recovery and recovery.reason == "read_failed" and recovery.preserved == true)
			assert(uv.fs_lstat(store .. ".tmp") == nil, "refused mutation wrote a temporary store")
		end)
	end
	check(operation.name .. " accepts a genuinely missing store", function()
		local config = mkdir(root .. "/" .. operation.name .. "-missing")
		local parent = mkdir(config .. "/ergopti_plus")
		local store = parent .. "/storage.json"
		files[#files + 1] = store
		local storage = fresh(config)
		assert(operation.apply(storage) == true)
		assert(storage.recovery_status() == nil)
		if operation.name == "set" or operation.name == "set_many" then
			assert(fresh(config).get("replacement") == true, "new store did not survive reload")
		else assert(uv.fs_lstat(store) == nil, "empty-store no-op unexpectedly created data") end
	end)
end

check("readable native store preserves unrelated nested values", function()
	local config = mkdir(root .. "/readable")
	local parent = mkdir(config .. "/ergopti_plus")
	write(parent .. "/storage.json", ORIGINAL)
	local storage = fresh(config)
	assert(storage.get("preserve") == "original")
	assert(storage.set_many({ replacement = true }))
	storage = fresh(config)
	assert(storage.get("preserve") == "original" and storage.get("nested").value == "é")
	assert(storage.get("replacement") == true)
end)

check("fresh owner recovers after native permissions are repaired", function()
	local config = mkdir(root .. "/repaired")
	local parent = mkdir(config .. "/ergopti_plus")
	local store = parent .. "/storage.json"
	write(store, ORIGINAL)
	assert(uv.fs_chmod(store, 0))
	local blocked = fresh(config)
	local accepted = blocked.set("replacement", true)
	restore_permissions()
	assert(accepted == false and read(store) == ORIGINAL)
	local recovered = fresh(config)
	assert(recovered.get("preserve") == "original")
	assert(recovered.set("replacement", true))
	assert(fresh(config).get("preserve") == "original")
end)

for index, body in ipairs({ "[]", '["original"]', '[{"keep":"é","nested":[1,2]}]', '[null,"original"]' }) do
	check("preserves non-object store history " .. index, function()
		local config = mkdir(root .. "/shape-array-" .. index)
		local parent = mkdir(config .. "/ergopti_plus")
		local store = parent .. "/storage.json"
		write(store, body)
		files[#files + 1] = store .. ".corrupt"
		local storage = fresh(config)
		assert(storage.get("any", "default") == "default")
		local recovery = storage.recovery_status()
		assert(recovery and recovery.preserved == true, "JSON array masqueraded as a key-value store")
		assert(read(recovery.path) == body, "invalid store shape lost its original bytes")
		assert(storage.set("replacement", true))
		assert(fresh(config).get("replacement") == true)
		assert(read(recovery.path) == body, "new valid store overwrote the preserved history")
	end)
end

for index, body in ipairs({ "{}", " \n\t{}", '{"1":"original","nested":{"values":[false,0,"é"]}}' }) do
	check("accepts object store control " .. index, function()
		local config = mkdir(root .. "/shape-object-" .. index)
		local parent = mkdir(config .. "/ergopti_plus")
		write(parent .. "/storage.json", body)
		local storage = fresh(config)
		assert(storage.set("replacement", true) and storage.recovery_status() == nil)
		storage = fresh(config)
		assert(storage.get("replacement") == true)
		if index == 3 then
			assert(storage.get("1") == "original")
			local values = storage.get("nested").values
			assert(values[1] == false and values[2] == 0 and values[3] == "é")
		end
	end)
end

for _, method in ipairs({ "set", "set_many" }) do
	for _, source in ipairs({ "input", "returned", "refused" }) do
		check(method .. " owns its durable snapshot after " .. source .. " mutation", function()
			local config = mkdir(root .. "/snapshot-" .. method .. "-" .. source)
			local parent = mkdir(config .. "/ergopti_plus")
			local store = parent .. "/storage.json"
			files[#files + 1] = store
			local storage = fresh(config)
			local profile = { title = "original", nested = { count = 7, values = { "é", "original" } } }
			local function persist(value)
				if method == "set" then return storage.set("profile", value) end
				return storage.set_many({ profile = value, peer = { enabled = true } })
			end
			assert(persist(profile))
			local bytes = read(store)
			local changed = source == "input" and profile or storage.get("profile")
			changed.title, changed.nested.count, changed.nested.values[2] = "changed", 99, "changed"
			if source == "refused" then
				assert(uv.fs_chmod(parent, 320)) -- 0500: permit reads, refuse new writes.
				local accepted = persist(changed)
				restore_permissions()
				assert(accepted == false, "real parent permission control did not refuse publication")
			end
			assert(read(store) == bytes, "unpublished caller mutation changed native bytes")
			local retained = storage.get("profile")
			assert(retained.title == "original" and retained.nested.count == 7
				and retained.nested.values[2] == "original", "caller reference escaped into durable cache")
			local reloaded = fresh(config).get("profile")
			assert(reloaded.title == retained.title and reloaded.nested.count == retained.nested.count)
		end)
	end
end

check("durable native snapshots retain scalar JSON values", function()
	local config = mkdir(root .. "/snapshot-scalars")
	local parent = mkdir(config .. "/ergopti_plus")
	files[#files + 1] = parent .. "/storage.json"
	local storage = fresh(config)
	assert(storage.set_many({ flag = false, count = 0, text = "é\0\n" }))
	for _, owner in ipairs({ storage, fresh(config) }) do
		assert(owner.get("flag", true) == false and owner.get("count", 10) == 0)
		assert(owner.get("text") == "é\0\n")
	end
end)

for _, suffix in ipairs({ 0, 1, 3 }) do
	for _, inaccessible in ipairs({ true, false }) do
		check("corrupt backup suffix " .. suffix .. (inaccessible and " is protected after refusal" or " is preserved before recovery"), function()
			local config = mkdir(root .. "/backup-" .. suffix .. (inaccessible and "-denied" or "-readable"))
			local parent = mkdir(config .. "/ergopti_plus")
			local store = parent .. "/storage.json"
			local broken = "{ broken current bytes"
			write(store, broken)
			local backups = {}
			for index = 0, suffix do
				local path = store .. ".corrupt" .. (index == 0 and "" or "." .. index)
				local bytes = "{ older recovery bytes " .. index
				write(path, bytes)
				backups[#backups + 1] = { path = path, bytes = bytes }
			end
			local blocked_path = backups[#backups].path
			if inaccessible then assert(uv.fs_chmod(blocked_path, 0)) end
			local storage = fresh(config)
			assert(storage.get("any", "default") == "default")
			local recovery = storage.recovery_status()
			restore_permissions()
			for _, backup in ipairs(backups) do
				assert(read(backup.path) == backup.bytes, "older corrupt-store backup was overwritten")
			end
			if inaccessible then
				assert(read(store) == broken, "failed backup classification moved the source")
				assert(storage.set("replacement", true) == false)
				assert(recovery and recovery.path == store and recovery.preserved == false)
			else
				local path = store .. ".corrupt." .. (suffix + 1)
				files[#files + 1] = path
				assert(recovery and recovery.path == path and recovery.preserved == true)
				assert(read(path) == broken)
				assert(storage.set("replacement", true))
				assert(fresh(config).get("replacement") == true)
			end
		end)
	end
end

if previous_xdg then assert(uv.os_setenv("XDG_CONFIG_HOME", previous_xdg))
else assert(uv.os_unsetenv("XDG_CONFIG_HOME")) end
for index = #files, 1, -1 do
	local ok, _, code = uv.fs_unlink(files[index])
	assert(ok or code == "ENOENT", "owned fixture file cleanup failed")
end
for index = #directories, 1, -1 do assert(uv.fs_rmdir(directories[index])) end
print(string.format("Native JSON storage read receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
