--- tests/unit/infra/lifecycle/test_owned_programs.lua

--- ==============================================================================
--- MODULE: Owned Programs
--- DESCRIPTION:
--- Every package carries a private runtime prefix, yet the driver started
--- `curl`, `sqlite3`, `openssl` and `tar --zstd` by name, so whatever came first
--- on PATH (or the host tar's zstd support) answered. These cases pin the one
--- resolver and sweep the driver for a bare start of an owned program.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A getenv double answering only the runtime prefix.
--- @param prefix string|nil
--- @return function
local function env(prefix)
	return function(name) if name == "ERGOPTI_RUNTIME_PREFIX" then return prefix end return nil end
end

--- Reads a driver file.
--- @param rel string
--- @return string
local function read(rel)
	local fh = assert(io.open(helpers.driver_root() .. "/" .. rel, "r"))
	local text = fh:read("*a")
	fh:close()
	return text
end

helpers.describe("owned_programs: the private runtime's programs only", function()

	helpers.it("resolves every owned program inside the prefix (owned-runtimes-programs)", function()
		local Owned = helpers.load_module("infra.owned_programs")
		for _, name in ipairs({ "luajit", "curl", "sqlite3", "openssl", "zstd" }) do
			helpers.assert_eq(Owned.path(name, env("/usr/lib/ergopti/runtime")), "/usr/lib/ergopti/runtime/bin/" .. name)
		end
	end)

	helpers.it("a source run uses PATH and says so once (owned-runtimes-programs)", function()
		local Owned = helpers.load_module("infra.owned_programs")
		Owned._reset_for_test()
		helpers.assert_eq(Owned.path("sqlite3", env(nil)), "sqlite3")
		helpers.assert_eq(Owned.path("curl", env("")), "curl")
	end)

	helpers.it("the SQLite helper process resolves without the logger it cannot load (owned-runtimes-programs)", function()
		local Owned = helpers.load_module("infra.owned_programs")
		Owned._reset_for_test()
		local loaded, preload = package.loaded["logger.shim"], package.preload["logger.shim"]
		package.loaded["logger.shim"] = nil
		package.preload["logger.shim"] = function() error("the worker has only the driver tree on package.path") end
		local ok, program = pcall(Owned.resolve, "sqlite3", env(nil))
		package.loaded["logger.shim"], package.preload["logger.shim"] = loaded, preload
		helpers.assert_true(ok, tostring(program))
		helpers.assert_eq(program, "sqlite3")
	end)

	helpers.it("the SQLite helper process execs the program the logging-free resolver names (owned-runtimes-programs)", function()
		-- The worker replaces itself through execvp: an ffi double records the
		-- call, and an owned_programs double offers only resolve, so a worker
		-- reaching the logging path() or a bare "sqlite3" fails here.
		local execs, resolved = {}, {}
		local fake_ffi = {
			cdef = function() end,
			cast = function(_, value) return value end,
			new = function() return {} end,
			C = {
				prctl = function() return 0 end,
				getppid = function() return 4242 end,
				umask = function() return 0 end,
				execvp = function(file, argv) execs[#execs + 1] = { file = file, database = argv[5] } return -1 end,
			},
		}
		local names = { "ffi", "infra.private_sqlite_file", "infra.owned_programs", "adapters.sqlite_process_worker" }
		local saved, saved_path = {}, package.path
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local ok, err = pcall(function()
			package.loaded["ffi"] = fake_ffi
			package.loaded["infra.private_sqlite_file"] = { admit = function() return true end, creation_mask = 63 }
			package.loaded["infra.owned_programs"] = setmetatable({
				resolve = function(name) resolved[#resolved + 1] = name return "/opt/runtime/bin/" .. name end,
			}, { __index = function(_, key) error("the worker must not reach owned_programs." .. tostring(key)) end })
			package.loaded["adapters.sqlite_process_worker"] = nil
			local Worker = require("adapters.sqlite_process_worker")
			return Worker.run("4242", "/private/keystats.db")
		end)
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		package.path = saved_path
		helpers.assert_eq(ok, false, "a refused exec must raise")
		helpers.assert_true(tostring(err):find("SQLite process replacement refused", 1, true) ~= nil, tostring(err))
		helpers.assert_eq(resolved, { "sqlite3" })
		helpers.assert_eq(execs, { { file = "/opt/runtime/bin/sqlite3", database = "/private/keystats.db" } })
	end)

	helpers.it("refuses a program the prefix does not carry and a relative prefix (owned-runtimes-programs)", function()
		local Owned = helpers.load_module("infra.owned_programs")
		helpers.assert_true(not pcall(Owned.path, "python3", env("/opt/runtime")))
		helpers.assert_true(not pcall(Owned.path, "curl", env("relative/runtime")))
	end)

	helpers.it("unpacks zstd through the prefix's zstd, not tar's own (owned-runtimes-zstd)", function()
		local Owned = helpers.load_module("infra.owned_programs")
		helpers.assert_eq(Owned.zstd_tar_option(env("/tmp/.mount_Ergo/usr")), "--use-compress-program=/tmp/.mount_Ergo/usr/bin/zstd")
		local option, reason = Owned.zstd_tar_option(env("/home/a user/runtime"))
		helpers.assert_nil(option, "tar would split the program at the blank")
		helpers.assert_eq(reason, "owned_zstd_path_has_blank")
	end)

	helpers.it("the package environment exports the prefix the resolver reads (owned-runtimes-programs)", function()
		local template = read("../../../tools/build/templates/linux-portable-runtime-env.sh")
		helpers.assert_true(template:find('export ERGOPTI_RUNTIME_PREFIX="$ERGOPTI_PACKAGE_PREFIX"', 1, true) ~= nil)
		helpers.assert_true(read("install/launch.sh"):find('exec "$ERGOPTI_RUNTIME_PREFIX/bin/luajit"', 1, true) ~= nil)
	end)

	helpers.it("no driver file starts an owned program by name (owned-runtimes-programs)", function()
		-- The whole class: every start of curl, sqlite3, openssl or a zstd tar.
		local patterns = {
			{ 'spawn%("curl"', "curl spawned by name" },
			{ 'curl_executable or "curl"', "curl defaulted by name" },
			{ '{ "sqlite3",', "sqlite3 argv by name" },
			{ 'command %-v sqlite3', "sqlite3 found on PATH" },
			{ '"%-%-zstd"', "tar's own zstd support" },
			{ '"openssl enc', "openssl started by name" },
			{ '"openssl base64', "openssl started by name" },
			{ '| openssl dgst', "openssl started by name" },
		}
		local listing = assert(io.popen("cd " .. helpers.driver_root() .. " && find . -name '*.lua' -not -path './tests/*' -print"))
		local found, scanned = {}, 0
		for file in listing:lines() do
			scanned = scanned + 1
			local source = read(file:sub(3))
			for _, pattern in ipairs(patterns) do
				if source:find(pattern[1]) then found[#found + 1] = file .. ": " .. pattern[2] end
			end
		end
		listing:close()
		helpers.assert_true(scanned > 100, "the sweep read " .. scanned .. " files")
		helpers.assert_eq(found, {})
	end)
end)
