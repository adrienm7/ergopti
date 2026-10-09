--- tests/unit/lib/test_config_paths_managed_bootstrap.lua

--- ==============================================================================
--- MODULE: Config Paths — Managed-App Bootstrap Persistence
--- DESCRIPTION:
--- Proves that the packaged launcher can place paths.toml in a stable,
--- user-writable location instead of beside the signed Lua resources.
---
--- ROOT CAUSE ENCODED:
--- The packaged launcher points MJConfigFile at
--- ErgoptiPlus.app/Contents/Resources/.../init.lua. ConfigPaths historically
--- derived paths.toml from that source directory, so first boot and every path
--- editor save attempted to write inside the installed application bundle.
--- io.open then failed under a normal /Applications install, while the in-memory
--- override still moved and the UI reloaded as if persistence had succeeded.
---
--- These tests drive the production resolver with the launcher's managed path
--- environment contract. The load-bearing assertion is where the bytes land;
--- merely scanning for the environment-variable name would stay green if the
--- writer continued using the bundle path.
--- ==============================================================================

local helpers = require("tests.helpers")

local MANAGED_FILE = "/Users/test/Library/Application Support/ErgoptiPlus/paths.toml"
local BUNDLE_DIR = "/Applications/ErgoptiPlus.app/Contents/Resources/static/ergopti_plus/macos/"
local CUSTOM_DIR = "/Volumes/User Config/"

--- Loads ConfigPaths with the exact environment exported by the packaged
--- launcher, then restores process-global getenv even when require raises.
--- @param memory table Exact filesystem owner for this test.
--- @return table config_paths Fresh production module.
local function load_managed(memory)
	local real_getenv = os.getenv
	os.getenv = function(name)
		if name == "ERGOPTI_PATHS_FILE" then return MANAGED_FILE end
		if name == "HOME" then return "/Users/test" end
		return real_getenv(name)
	end

	local ok, loaded = pcall(helpers.load_with_stubs, "infra.config_paths", {
		fs = memory.fs, execute = memory.execute,
	})
	os.getenv = real_getenv
	if not ok then error(loaded, 0) end
	return loaded
end

--- Runs a body with an explicit inode namespace, including private staging.
--- Opens publish their inode before write/close; unlink/recreation gets a fresh
--- identity, rename moves the same inode, and hard links retain the same owner.
--- This models resource identity, not native filesystem or locking support.
--- @param initial table<string,string>|nil Initial file contents.
--- @param fn fun(files: table<string,string>, writes: string[], memory: table)
local function with_memory_files(initial, fn)
	local files, writes, entries = {}, {}, {}
	local next_inode = 0
	local function normalize(path) return path == "/" and path or path:gsub("/+$", "") end
	local function parent(path) return path:match("^(.+)/[^/]+$") or "/" end
	local function allocate(mode, content)
		next_inode = next_inode + 1
		return { mode = mode, dev = 1, ino = next_inode, content = content,
			permissions = mode == "file" and "rw-------" or "rwx------", uid = 501, gid = 20 }
	end
	local function publish_bytes(entry)
		for path, current in pairs(entries) do
			if current == entry then files[path] = entry.content end
		end
	end
	local function seed_directory(path)
		path = normalize(path)
		if entries[path] then return end
		if path ~= "/" then seed_directory(parent(path)) end
		entries[path] = allocate("directory")
	end
	seed_directory(parent(MANAGED_FILE))
	seed_directory(BUNDLE_DIR)
	seed_directory(CUSTOM_DIR)
	for path, content in pairs(initial or {}) do
		seed_directory(parent(path))
		entries[path] = allocate("file", content)
		files[path] = content
	end
	local function attributes(path)
		local entry = entries[normalize(path)]
		if not entry then return nil, "not found" end
		return { mode = entry.mode, dev = entry.dev, ino = entry.ino,
			permissions = entry.permissions, uid = entry.uid, gid = entry.gid,
			size = entry.mode == "file" and #entry.content or nil }
	end
	local memory = { fs = {} }
	memory.fs.attributes, memory.fs.symlinkAttributes = attributes, attributes
	memory.fs.xattr = { list = function() return {} end, get = function() return nil end }
	memory.fs.mkdir = function(path)
		path = normalize(path)
		if entries[path] then return nil, "already exists" end
		if not entries[parent(path)] or entries[parent(path)].mode ~= "directory" then return nil, "missing parent" end
		entries[path] = allocate("directory")
		return true
	end
	memory.fs.rmdir = function(path)
		path = normalize(path)
		if not entries[path] or entries[path].mode ~= "directory" then return nil, "missing directory" end
		for child in pairs(entries) do
			if child ~= path and parent(child) == path then return nil, "directory not empty" end
		end
		entries[path] = nil
		return true
	end
	memory.fs.dir = function(path)
		path = normalize(path)
		assert(entries[path] and entries[path].mode == "directory", "cannot list an absent directory")
		local names, state, index = {}, {}, 0
		for child in pairs(entries) do
			if child ~= path and parent(child) == path then names[#names + 1] = child:match("([^/]+)$") end
		end
		table.sort(names)
		return function(current)
			assert(current == state, "directory iterator must retain its owner")
			index = index + 1
			return names[index]
		end, state
	end
	memory.fs.link = function(source, destination)
		local entry = entries[source]
		if not entry or entry.mode ~= "file" then return nil, "missing source" end
		if entries[destination] then return nil, "already exists" end
		if not entries[parent(destination)] or entries[parent(destination)].mode ~= "directory" then return nil, "missing parent" end
		entries[destination], files[destination] = entry, entry.content
		return true
	end
	memory.fs.lock, memory.fs.unlock = function() return true end, function() return true end
	memory.execute = function(command)
		if command:find("/bin/cp -p ", 1, true) == 1 then
			local source, destination = command:match("^/bin/cp %-p '([^']*)' '([^']*)'$")
			local prior = source and entries[source]
			if not prior or prior.mode ~= "file" or not entries[parent(destination)]
				or entries[parent(destination)].mode ~= "directory" then return "", false, "exit", 1 end
			local target = entries[destination] or allocate("file", "")
			if target.mode ~= "file" then return "", false, "exit", 1 end
			target.content, target.permissions, target.uid, target.gid = prior.content, prior.permissions, prior.uid, prior.gid
			entries[destination] = target
			publish_bytes(target)
			return "", true, "exit", 0
		elseif command:find("LC_ALL=C /bin/ls -led ", 1, true) == 1 then
			local path = command:match("^LC_ALL=C /bin/ls %-led '([^']*)'$")
			if path and entries[path] then return "memory namespace header\n", true, "exit", 0 end
		end
		return "", false, "exit", 1
	end
	local real_open, real_remove, real_rename = io.open, os.remove, os.rename
	io.open = function(path, mode)
		if mode == "r" or mode == "rb" then
			local entry = entries[path]
			if not entry or entry.mode ~= "file" then return nil, "not found" end
			return { read = function() return entry.content end, close = function() return true end }
		end
		if mode == "w" or mode == "a+" then
			if not entries[parent(path)] then return nil, "missing parent" end
			local entry = entries[path]
			if entry and entry.mode ~= "file" then return nil, "not a regular file" end
			if not entry then entry = allocate("file", ""); entries[path] = entry end
			if mode == "w" then entry.content = "" end
			publish_bytes(entry)
			return {
				write = function(_, content) entry.content = entry.content .. tostring(content); publish_bytes(entry); return true end,
				close = function() writes[#writes + 1] = path; return true end,
			}
		end
		return real_open(path, mode)
	end
	os.remove = function(path)
		if not entries[path] then return nil, "not found", 2 end
		if entries[path].mode == "directory" then return memory.fs.rmdir(path) end
		entries[path], files[path] = nil, nil
		return true
	end
	os.rename = function(from, to)
		local entry = entries[from]
		if not entry then return nil, "not found", 2 end
		if not entries[parent(to)] then return nil, "missing parent", 2 end
		entries[to], entries[from] = entry, nil
		files[to], files[from] = entry.content, nil
		return true
	end

	local ok, err = xpcall(function()
		return helpers.with_stub_scope({ "infra.config_paths", "adapters.file_system", "infra.fs_dir" }, function()
			return fn(files, writes, memory)
		end)
	end, debug.traceback)
	io.open, os.remove, os.rename = real_open, real_remove, real_rename
	if not ok then error(err, 0) end
end

helpers.describe("managed ConfigPaths bootstrap lives outside the app bundle", function()
	helpers.it("managed bootstrap: writes first-boot and user overrides outside the bundle", function()
		with_memory_files({}, function(files, writes, memory)
			local ConfigPaths = load_managed(memory)
			helpers.assert_true(ConfigPaths.init(BUNDLE_DIR))
			helpers.assert_true(ConfigPaths.set_config_dir(CUSTOM_DIR))

			helpers.assert_not_nil(files[MANAGED_FILE],
				"the managed bootstrap must be persisted in the user-writable location")
			helpers.assert_true(files[MANAGED_FILE]:find(CUSTOM_DIR, 1, true) ~= nil,
				"the persisted bootstrap must contain the directory selected by the user")
		for _, path in ipairs(writes) do
			helpers.assert_true(path:sub(1, #BUNDLE_DIR) ~= BUNDLE_DIR,
				"paths.toml must never be written inside the signed app resources: " .. path)
		end
		end)
	end)

	helpers.it("managed bootstrap: migrates a legacy adjacent override", function()
		local legacy = BUNDLE_DIR .. "paths.toml"
		with_memory_files({
			[legacy] = 'ConfigDirPath = "' .. CUSTOM_DIR .. '"\n',
		}, function(files, _, memory)
			local ConfigPaths = load_managed(memory)
			helpers.assert_true(ConfigPaths.init(BUNDLE_DIR))

			helpers.assert_eq(ConfigPaths.get_config_dir(), CUSTOM_DIR,
				"migration must preserve the user's existing override")
			helpers.assert_not_nil(files[MANAGED_FILE],
				"the legacy override must be copied to the stable managed location")
			helpers.assert_true(files[MANAGED_FILE]:find(CUSTOM_DIR, 1, true) ~= nil)
		end)
	end)

	-- dev.108 to dev.117 wrote "~/..." here; the stricter validator then made
	-- M.init() refuse and the launcher died with a bare exit code (legacy-tilde).
	helpers.it("managed bootstrap: expands and persists a legacy tilde override (legacy-tilde)", function()
		with_memory_files({
			[MANAGED_FILE] = 'ConfigDirPath = "~/gitcfg/ergopti_plus/"\n',
		}, function(files, _, memory)
			local ConfigPaths = load_managed(memory)
			helpers.assert_true(ConfigPaths.init(BUNDLE_DIR),
				"a legacy tilde value must not abort the boot")
			helpers.assert_eq(ConfigPaths.get_config_dir(), "/Users/test/gitcfg/ergopti_plus/")
			helpers.assert_contains(files[MANAGED_FILE],
				'ConfigDirPath = "/Users/test/gitcfg/ergopti_plus/"',
				"the expansion must be persisted once as an absolute path")
			helpers.assert_true(files[MANAGED_FILE]:find("~/", 1, true) == nil,
				"no tilde value may remain: " .. files[MANAGED_FILE])
		end)
	end)

	helpers.it("managed bootstrap: still refuses a relative override", function()
		with_memory_files({
			[MANAGED_FILE] = 'ConfigDirPath = "gitcfg/ergopti_plus/"\n',
		}, function(_, _, memory)
			local ConfigPaths = load_managed(memory)
			helpers.assert_eq(ConfigPaths.init(BUNDLE_DIR), false)
		end)
	end)
end)

helpers.describe("managed bootstrap memory namespace identity", function()
	helpers.it("pins opened inodes and distinguishes foreign file and directory recreation", function()
		with_memory_files({}, function(files, _, memory)
			local path = MANAGED_FILE .. ".identity-probe"
			local alias = path .. ".alias"
			local handle = assert(io.open(path, "w"))
			local acquired = assert(memory.fs.symlinkAttributes(path))
			helpers.assert_eq(acquired.mode, "file", "open must publish the inode before writes or close")
			helpers.assert_eq(files[path], "")
			assert(handle:write("owned"))
			assert(memory.fs.link(path, alias))
			helpers.assert_eq(memory.fs.symlinkAttributes(alias).ino, acquired.ino, "hard links retain their exact inode")
			assert(os.remove(path))
			local replacement = assert(io.open(path, "w"))
			assert(replacement:write("foreign")); assert(replacement:close())
			helpers.assert_true(memory.fs.symlinkAttributes(path).ino ~= acquired.ino, "recreation must never adopt the prior inode")
			assert(handle:write(" retained")); assert(handle:close())
			helpers.assert_eq(files[path], "foreign", "an old handle cannot write through a replacement pathname")
			helpers.assert_eq(files[alias], "owned retained")
			assert(os.rename(alias, alias .. ".moved"))
			helpers.assert_eq(memory.fs.symlinkAttributes(alias .. ".moved").ino, acquired.ino)
			local directory = MANAGED_FILE .. ".identity-directory"
			assert(memory.fs.mkdir(directory))
			local old_directory = assert(memory.fs.symlinkAttributes(directory))
			assert(memory.fs.rmdir(directory)); assert(memory.fs.mkdir(directory))
			helpers.assert_true(memory.fs.symlinkAttributes(directory).ino ~= old_directory.ino,
				"directory recreation must have a distinct acquired identity")
		end)
	end)

	helpers.it("the actual publisher refuses a recreated staging directory and preserves its foreign inode", function()
		with_memory_files({}, function(files, _, memory)
			local ConfigPaths = load_managed(memory)
			local original_open = io.open
			local replaced, foreign_identity, foreign_directory = 0, nil, nil
			io.open = function(path, mode)
				if mode == "w" and path:find("stage-lock/payload", 1, true) then
					foreign_directory = path:match("^(.+)/payload$")
					assert(memory.fs.rmdir(foreign_directory))
					assert(memory.fs.mkdir(foreign_directory))
					foreign_identity = assert(memory.fs.symlinkAttributes(foreign_directory))
					replaced = replaced + 1
				end
				return original_open(path, mode)
			end
			helpers.assert_eq(ConfigPaths.init(BUNDLE_DIR), false)
			helpers.assert_eq(replaced, 1, "the actual create/open boundary must be exercised")
			helpers.assert_eq(files[MANAGED_FILE], nil, "foreign staging cannot publish bootstrap bytes")
			helpers.assert_eq(memory.fs.symlinkAttributes(foreign_directory), foreign_identity,
				"cleanup must retain the foreign directory rather than delete it")
		end)
	end)
end)
