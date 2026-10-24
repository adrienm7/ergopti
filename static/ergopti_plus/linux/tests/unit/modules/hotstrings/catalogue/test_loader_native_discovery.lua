--- tests/unit/modules/hotstrings/catalogue/test_loader_native_discovery.lua

--- ==============================================================================
--- MODULE: Hotstring Discovery Without find
--- DESCRIPTION:
--- The loader's three discovery walks (find_toml_files, list_subdirs,
--- unavailable_directories) run in this process through
--- infra/native_directory.lua instead of forking `find`.
---
--- ROOT CAUSE ENCODED:
--- A daemon start forked find five times to discover the hotstring packs
--- (measured with the boot of tests/e2e/startup_child.lua), and every catalogue
--- reload forked it again. The replacement must change nothing but the forks:
--- the same files in the same order, symbolic links reported and never
--- followed, the -maxdepth boundary, a root spelled with one or two trailing
--- slashes, and filenames that carry newlines.
---
--- FEATURES & RATIONALE:
--- 1. Differential: the expected lists come from the real GNU find over the same
---    fixture, with the command lines the loader used to run, order included.
--- 2. No fork: io.popen, os.execute and libuv spawn are counted while the walks
---    run, and must stay at zero.
--- 3. Native refusals: an impossible entry name raises, a directory the kernel
---    refuses is reported and the walk goes on, a filesystem without d_type is
---    answered by lstat.
--- ==============================================================================

local helpers = require("tests.helpers")
local Shell = require("adapters.shell_runner")

local ON_WINDOWS = package.config:sub(1, 1) == "\\"

--- Every name the walks must classify, relative to the fixture root.
local FILES = {
	"a.toml", "_index.toml", "notes.txt", ".hidden.toml", ".toml", "line\nbreak.toml", "trailing .toml",
	"sub/b.toml", "sub/deeper/c.toml", "sub/deeper/deepest/d.toml", "x.toml/y.toml", "outside/escaped.toml",
	"tree/team\\autocorrection.toml",
}

--- Writes one empty file.
--- @param path string
local function touch(path)
	local file = assert(io.open(path, "w"))
	assert(file:close())
end

--- Builds the fixture tree, more entries than one readdir batch included.
--- @return string root
local function fixture()
	local root = os.tmpname()
	os.remove(root)
	for _, dir in ipairs({ "sub/deeper/deepest", "x.toml", "outside", "empty", "many", "tree", "new\nline dir" }) do
		assert(Shell.run("mkdir -p " .. Shell.quote(root .. "/" .. dir)))
	end
	for _, relative in ipairs(FILES) do touch(root .. "/" .. relative) end
	for index = 1, 150 do touch(string.format("%s/many/f%03d.toml", root, index)) end
	touch(root .. "/new\nline dir/inner.toml")
	assert(Shell.run("ln -s " .. Shell.quote(root .. "/outside") .. " " .. Shell.quote(root .. "/linkdir")))
	assert(Shell.run("ln -s " .. Shell.quote(root .. "/a.toml") .. " " .. Shell.quote(root .. "/linkfile.toml")))
	assert(Shell.run("ln -s " .. Shell.quote(root) .. " " .. Shell.quote(root .. ".link")))
	assert(Shell.run("mkfifo " .. Shell.quote(root .. "/fifo.toml")))
	return root
end

--- Removes the fixture tree and its root link.
--- @param root string
local function remove(root)
	assert(Shell.run("rm -rf -- " .. Shell.quote(root) .. " " .. Shell.quote(root .. ".link")))
end

--- Runs GNU find, as the loader used to, and decodes its NUL records.
--- @param command string Command line ending in -print0.
--- @return table paths
local function find(command)
	local pipe = assert(io.popen(command .. " 2>/dev/null", "r"))
	local output = pipe:read("*a")
	pipe:close()
	local paths = {}
	for path in output:gmatch("([^%z]+)%z") do paths[#paths + 1] = path end
	return paths
end

--- Counts every way the walks could fork while body runs.
--- @param body function
--- @return number forks
local function count_forks(body)
	local forks = 0
	local popen, execute = io.popen, os.execute
	local uv = package.loaded.luv
	local spawn = type(uv) == "table" and uv.spawn or nil
	io.popen = function(...) forks = forks + 1; return popen(...) end
	os.execute = function(...) forks = forks + 1; return execute(...) end
	if spawn then uv.spawn = function(...) forks = forks + 1; return spawn(...) end end
	local ok, err = pcall(body)
	io.popen, os.execute = popen, execute
	if spawn then uv.spawn = spawn end
	if not ok then error(err, 0) end
	return forks
end





-- =========================================
-- =========================================
-- ======= 1/ Same paths, same order =======
-- =========================================
-- =========================================

helpers.describe("hotstring discovery matches find byte for byte", function()
	helpers.it("lists the packs find listed, in find's order, at every depth and root spelling", function()
		if ON_WINDOWS then print("  SKIP native POSIX discovery: Windows has no GNU find or symbolic links here"); return end
		local Loader = helpers.load_module("modules.hotstrings.loader")
		local root = fixture()
		local ok, err = pcall(function()
			local compared = 0
			for _, start in ipairs({ root, root .. "/", root .. "//", root .. ".link", root .. ".link/",
				root .. "/a.toml", root .. "/notes.txt", root .. "/linkdir", root .. "/missing" }) do
				for _, depth in ipairs({ false, 0, 1, 2, 3 }) do
					local limit = depth and (" -maxdepth " .. depth) or ""
					local expected = {}
					for _, path in ipairs(find("find " .. Shell.quote(start) .. limit .. " -type f -name '*.toml' -print0")) do
						if Loader.is_pack_file(path) then expected[#expected + 1] = path end
					end
					helpers.assert_eq(Loader.find_toml_files(start, depth or nil), expected,
						"find_toml_files(" .. start:sub(#root + 1) .. ", " .. tostring(depth) .. ")")
					compared = compared + #expected
				end
			end
			helpers.assert_true(compared > 300, "the differential must compare real discoveries, not empty lists")
		end)
		remove(root)
		if not ok then error(err, 0) end
	end)

	helpers.it("lists the extension folders find listed, in find's order", function()
		if ON_WINDOWS then print("  SKIP native POSIX discovery: Windows has no GNU find or symbolic links here"); return end
		local Loader = helpers.load_module("modules.hotstrings.loader")
		local root = fixture()
		local ok, err = pcall(function()
			for _, start in ipairs({ root, root .. "/", root .. ".link", root .. ".link/", root .. "/a.toml", root .. "/missing" }) do
				local expected = find("find " .. Shell.quote(start) .. " -mindepth 1 -maxdepth 1 -type d -print0")
				helpers.assert_eq(Loader.list_subdirs(start), expected, "list_subdirs(" .. start:sub(#root + 1) .. ")")
			end
			helpers.assert_eq(#Loader.list_subdirs(root), 7, "every real folder, never the linked one")
		end)
		remove(root)
		if not ok then error(err, 0) end
	end)

	helpers.it("reports the linked and depth-boundary folders find reached", function()
		if ON_WINDOWS then print("  SKIP native POSIX discovery: Windows has no GNU find or symbolic links here"); return end
		local Loader = helpers.load_module("modules.hotstrings.loader")
		local root = fixture()
		local ok, err = pcall(function()
			local rows = {}
			for _, row in ipairs(Loader.unavailable_directories(root, 1)) do
				rows[#rows + 1] = row.reason .. " " .. row.label
				helpers.assert_eq(row.path, root .. "/" .. row.label)
			end
			helpers.assert_eq(rows, { "scan-depth empty", "linked-directory linkdir", "scan-depth many",
				"scan-depth new\nline dir", "scan-depth outside", "scan-depth sub", "scan-depth tree", "scan-depth x.toml" })
			rows = {}
			for _, row in ipairs(Loader.unavailable_directories(root, 2)) do rows[#rows + 1] = row.reason .. " " .. row.label end
			helpers.assert_eq(rows, { "linked-directory linkdir", "scan-depth sub/deeper" })
			helpers.assert_eq(Loader.unavailable_directories(root .. ".link", 2), {
				{ path = root .. ".link", label = (root .. ".link"):match("([^/]+)$"), reason = "linked-directory" },
			}, "a linked root is itself skipped without following it")
			helpers.assert_eq(Loader.unavailable_directories(root .. "/missing", 2), {})
		end)
		remove(root)
		if not ok then error(err, 0) end
	end)
end)





-- ==========================
-- ==========================
-- ======= 2/ No fork =======
-- ==========================
-- ==========================

helpers.describe("hotstring discovery forks nothing", function()
	helpers.it("walks packs, extension folders and diagnostics with zero io.popen, os.execute or spawn", function()
		if ON_WINDOWS then print("  SKIP native POSIX discovery: Windows has no GNU find or symbolic links here"); return end
		local Loader = helpers.load_module("modules.hotstrings.loader")
		local root = fixture()
		local found
		local ok, err = pcall(function()
			local forks = count_forks(function()
				found = Loader.find_toml_files(root)
				Loader.find_toml_files(root, 2)
				Loader.list_subdirs(root)
				Loader.unavailable_directories(root, 2)
				Loader.find_toml_files(require("infra.paths").shared("modules/hotstrings"))
			end)
			helpers.assert_eq(forks, 0, "discovery must not fork find or any other process")
			helpers.assert_true(#found > 150, "the counted walk discovered the fixture")
		end)
		remove(root)
		if not ok then error(err, 0) end
	end)
end)





-- ==================================
-- ==================================
-- ======= 3/ Native refusals =======
-- ==================================
-- ==================================

--- Loads the walker over scripted libuv entries, then a loader bound to it.
--- @param listing table Map of directory path to an array of entries, or to
---   { error = code } for a refused listing.
--- @param kinds table Map of path to lstat type.
--- @param body function(Loader, Walker)
local function with_scripted_native(listing, kinds, body)
	local previous_walker = package.loaded["infra.native_directory"]
	local fake = {
		fs_opendir = function(path)
			if listing[path] == nil then return nil, "ENOENT: " .. path, "ENOENT" end
			return { path = path, served = false }
		end,
		fs_readdir = function(dir)
			local entries = listing[dir.path]
			if entries.error then return nil, entries.error .. ": " .. dir.path, entries.error end
			if dir.served then return nil end
			dir.served = true
			return entries
		end,
		fs_closedir = function() return true end,
		fs_lstat = function(path)
			if kinds[path] == nil then return nil, "ENOENT: " .. path, "ENOENT" end
			return { type = kinds[path] }
		end,
	}
	local Walker = helpers.load_module_with_dependency("infra.native_directory", "luv", fake)
	package.loaded["infra.native_directory"] = Walker
	local ok, err = pcall(body, helpers.load_module("modules.hotstrings.loader"), Walker)
	package.loaded["infra.native_directory"] = previous_walker
	helpers.load_module("modules.hotstrings.loader")
	if not ok then error(err, 0) end
end

helpers.describe("hotstring discovery refuses what a directory cannot hold", function()
	helpers.it("raises on an entry name with a slash, a NUL or nothing (native-discovery-framing)", function()
		for _, name in ipairs({ "nested/escape.toml", "nul\0byte.toml", "" }) do
			with_scripted_native({ ["/isolated"] = { { name = name, type = "file" } } }, { ["/isolated"] = "directory" },
				function(Loader)
					for _, discover in ipairs({ Loader.find_toml_files, Loader.list_subdirs }) do
						local admitted, reason = pcall(discover, "/isolated")
						helpers.assert_eq(admitted, false, "an impossible native name must not become a source")
						helpers.assert_true(tostring(reason):find("invalid entry name", 1, true) ~= nil, tostring(reason))
					end
				end)
		end
	end)

	helpers.it("asks lstat for the kind a filesystem without d_type does not report", function()
		with_scripted_native({
			["/isolated"] = { { name = "pack.toml" }, { name = "folder", type = "unknown" }, { name = "gone.toml" } },
			["/isolated/folder"] = { { name = "inner.toml", type = "file" } },
		}, { ["/isolated"] = "directory", ["/isolated/pack.toml"] = "file", ["/isolated/folder"] = "directory" },
		function(Loader)
			helpers.assert_eq(Loader.find_toml_files("/isolated"), { "/isolated/pack.toml", "/isolated/folder/inner.toml" },
				"an entry that vanished before its lstat is neither a pack nor a folder")
		end)
	end)

	helpers.it("reports a refused folder and keeps every other pack", function()
		with_scripted_native({
			["/isolated"] = { { name = "locked", type = "directory" }, { name = "kept.toml", type = "file" } },
			["/isolated/locked"] = { error = "EACCES" },
		}, { ["/isolated"] = "directory" }, function(Loader)
			local Logger = require("logger.shim")
			local warned = {}
			local warn = Logger.warn
			Logger.warn = function(_, message, path, detail) warned[#warned + 1] = string.format(message, path, detail) end
			local ok, found = pcall(Loader.find_toml_files, "/isolated")
			Logger.warn = warn
			helpers.assert_true(ok, tostring(found))
			helpers.assert_eq(found, { "/isolated/kept.toml" })
			helpers.assert_eq(#warned, 1, "a refusal other than absence is reported once")
			helpers.assert_true(warned[1]:find("/isolated/locked", 1, true) ~= nil and warned[1]:find("EACCES", 1, true) ~= nil,
				warned[1])
			helpers.assert_eq(Loader.find_toml_files("/missing"), {}, "absence stays silent")
		end)
	end)

	helpers.it("raises when the runtime has no libuv directory listing", function()
		local Walker = helpers.load_module_with_dependency("infra.native_directory", "luv", false)
		local admitted, reason = pcall(Walker.walk, "/isolated", nil, function() end)
		helpers.load_module("infra.native_directory")
		helpers.assert_eq(admitted, false, "no backend must not read as an empty folder")
		helpers.assert_true(tostring(reason):find("luv", 1, true) ~= nil, tostring(reason))
	end)
end)
