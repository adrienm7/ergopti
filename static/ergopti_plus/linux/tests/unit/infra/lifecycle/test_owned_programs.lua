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
		helpers.assert_true(read("adapters/sqlite_process_worker.lua"):find('owned_programs").resolve("sqlite3")', 1, true) ~= nil,
			"the worker must use the logging-free resolver")
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
