--- tests/unit/infra/test_bytecode_package.lua

--- ==============================================================================
--- MODULE: Installed-Tree Bytecode Package
--- DESCRIPTION:
--- The maintainer's contract (2026-11-11): an installed tree loads its modules
--- from the bytecode its installer compiled, only while the manifest is whole
--- and names this luajit; anything else loads from source with one warning, and
--- a checkout never reads bytecode. Each case builds a real tree on disk,
--- compiles it with the shipped compiler, then changes the sources so a module
--- tells which of the two it was loaded from.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNER = "infra.bytecode_package"

--- Writes a file, creating its parents.
local function write(path, content)
	local made = os.execute("mkdir -p '" .. path:match("^(.*)/[^/]+$") .. "'")
	assert(made == true or made == 0, "cannot create the parent of " .. path)
	local file = assert(io.open(path, "wb"))
	assert(file:write(content))
	file:close()
end

--- The physical path of a fresh scratch directory.
local function scratch()
	local path = os.tmpname()
	os.remove(path)
	local made = os.execute("mkdir -p '" .. path .. "'")
	assert(made == true or made == 0, "cannot create " .. path)
	local handle = assert(io.popen("cd '" .. path .. "' && pwd -P"))
	local physical = handle:read("*l")
	handle:close()
	return physical
end

--- Builds and compiles a tree; its sources then answer "source".
--- @param receipt boolean Whether the installer's receipt is beside the payload.
--- @return string root, table owner
local function tree(receipt)
	package.loaded[OWNER] = nil
	local Owner = require(OWNER)
	Owner._reset_for_test()
	local root = scratch()
	write(root .. "/linux/install/ownership_schema.sh",
		assert(io.open(helpers.driver_root() .. "/install/ownership_schema.sh", "rb")):read("*a"))
	write(root .. "/linux/bc_probe_driver.lua", "return 'compiled'\n")
	write(root .. "/_shared/bc_probe_shared/init.lua", "return 'compiled'\n")
	-- The file infra.paths probes to name a shared tree beside the driver
	write(root .. "/_shared/core/i18n/data/locales/en.json", "{}\n")
	if receipt then write(root .. "/.ergopti-owned-files", "") end
	local digest = string.rep("a", 64)
	local ok, failure = Owner.compile(root, {
		{ relative = "linux/bc_probe_driver.lua", digest = digest },
		{ relative = "_shared/bc_probe_shared/init.lua", digest = digest },
	})
	helpers.assert_true(ok, tostring(failure))
	write(root .. "/linux/bc_probe_driver.lua", "return 'source'\n")
	write(root .. "/_shared/bc_probe_shared/init.lua", "return 'source'\n")
	return root, Owner
end

--- Installs the decision over a private searcher list and resolves both probes
--- the way require() would: first the bytecode searcher, then the source one.
--- @return boolean used, table answers, table searchers
local function boot(root, Owner, runtime, script_dir)
	local saved_path = package.path
	local driver = script_dir or (root .. "/linux")
	package.path = driver .. "/?.lua;" .. driver .. "/../_shared/?/init.lua;" .. saved_path
	-- The preload searcher stays first; the bytecode searcher follows it.
	local searchers = { function() return "\n\tno preload" end }
	local used = Owner.install(driver, { runtime = runtime, searchers = searchers })
	local answers, names = {}, {}
	for _, name in ipairs({ "bc_probe_driver", "bc_probe_shared" }) do
		local loader = type(searchers[2]) == "function" and searchers[2](name)
		if type(loader) == "function" then
			answers[name] = loader(name)
			names[name] = debug.getinfo(loader, "S").source
		else
			answers[name] = assert(loadfile(package.searchpath(name, package.path)))()
		end
	end
	package.path = saved_path
	return used, answers, names
end

--- Collects what report() logs.
local function report(Owner)
	local infos, warnings = {}, {}
	Owner.report(function(fmt, ...) infos[#infos + 1] = fmt:format(...) end,
		function(fmt, ...) warnings[#warnings + 1] = fmt:format(...) end)
	return infos, warnings
end

local function remove(root)
	os.execute("rm -rf -- '" .. root .. "'")
	package.loaded[OWNER] = nil
end

helpers.describe("bytecode package: an installed tree loads what its installer compiled", function()
	helpers.it("loads both trees from the bundle under their source names, and says so once", function()
		local root, Owner = tree(true)
		local used, answers, names = boot(root, Owner)
		helpers.assert_true(used)
		helpers.assert_eq(answers.bc_probe_driver, "compiled")
		helpers.assert_eq(answers.bc_probe_shared, "compiled")
		helpers.assert_eq(names.bc_probe_driver, "@" .. root .. "/linux/bc_probe_driver.lua",
			"tracebacks and source-identity checks see the source's name")
		helpers.assert_eq(names.bc_probe_shared, "@" .. root .. "/linux/../_shared/bc_probe_shared/init.lua")
		local infos, warnings = report(Owner)
		helpers.assert_eq(#infos, 1)
		helpers.assert_eq(#warnings, 0)
		remove(root)
	end)

	helpers.it("takes the decision once per process", function()
		local root, Owner = tree(true)
		boot(root, Owner)
		helpers.assert_eq(pcall(Owner.install, root .. "/linux"), false)
		remove(root)
	end)

	helpers.it("raises for an application module the trusted package does not hold", function()
		local root, Owner = tree(true)
		write(root .. "/linux/bc_probe_added.lua", "return 'added'\n")
		local saved_path = package.path
		package.path = root .. "/linux/?.lua;" .. saved_path
		local searchers = { function() return "\n\tno preload" end }
		helpers.assert_true(Owner.install(root .. "/linux", { searchers = searchers }))
		local raised, detail = pcall(searchers[2], "bc_probe_added")
		package.path = saved_path
		helpers.assert_eq(raised, false, "a tree changed after installation never mixes source and bytecode")
		helpers.assert_true(tostring(detail):find("bc_probe_added.lua", 1, true) ~= nil, tostring(detail))
		remove(root)
	end)
end)

helpers.describe("bytecode package: anything but a whole, matching package loads from source", function()
	helpers.it("a package compiled by another luajit falls back with one warning", function()
		local root, Owner = tree(true)
		local runtime = Owner.runtime()
		runtime.version = "LuaJIT 2.1.0-beta3"
		local used, answers = boot(root, Owner, runtime)
		helpers.assert_eq(used, false)
		helpers.assert_eq(answers.bc_probe_driver, "source")
		helpers.assert_eq(answers.bc_probe_shared, "source")
		local infos, warnings = report(Owner)
		helpers.assert_eq(#infos, 0)
		helpers.assert_eq(#warnings, 1)
		helpers.assert_true(warnings[1]:find("another runtime", 1, true) ~= nil, warnings[1])
		remove(root)
	end)

	local tamperings = {
		{ "a truncated bundle", function(directory)
			local bytes = assert(io.open(directory .. "/bundle", "rb")):read("*a")
			write(directory .. "/bundle", bytes:sub(1, -2))
		end, "bundle holds" },
		{ "a manifest without its end marker", function(directory)
			local text = assert(io.open(directory .. "/manifest", "rb")):read("*a")
			write(directory .. "/manifest", (text:gsub("end\n$", "")))
		end, "partial" },
		{ "a shifted chunk offset", function(directory)
			local text = assert(io.open(directory .. "/manifest", "rb")):read("*a")
			write(directory .. "/manifest", (text:gsub("\nchunk 0 ", "\nchunk 1 ", 1)))
		end, "malformed" },
		{ "a manifest of another root", function(directory)
			local text = assert(io.open(directory .. "/manifest", "rb")):read("*a")
			write(directory .. "/manifest", (text:gsub("\nroot [^\n]+", "\nroot /elsewhere", 1)))
		end, "another root" },
		{ "a missing bundle", function(directory) os.remove(directory .. "/bundle") end, "missing" },
		{ "a missing manifest", function(directory) os.remove(directory .. "/manifest") end, "no bytecode manifest" },
		-- The shared prefix comes from infra.paths, which names no tree here.
		{ "a tree without its shared tree", function(directory)
			os.remove(directory .. "/../_shared/core/i18n/data/locales/en.json")
		end, "no shared tree" },
	}
	for _, case in ipairs(tamperings) do
		helpers.it(case[1] .. " falls back to source with one warning", function()
			local root, Owner = tree(true)
			case[2](root .. "/.bytecode")
			local used, answers = boot(root, Owner)
			helpers.assert_eq(used, false)
			helpers.assert_eq(answers.bc_probe_driver, "source")
			local infos, warnings = report(Owner)
			helpers.assert_eq(#infos, 0)
			helpers.assert_eq(#warnings, 1)
			helpers.assert_true(warnings[1]:find(case[3], 1, true) ~= nil, warnings[1])
			remove(root)
		end)
	end
end)

helpers.describe("bytecode package: a checkout never reads bytecode", function()
	helpers.it("ignores a complete package without the installer's receipt, silently", function()
		local root, Owner = tree(false)
		local used, answers = boot(root, Owner)
		helpers.assert_eq(used, false)
		helpers.assert_eq(answers.bc_probe_driver, "source", "a saved source file always takes effect")
		local infos, warnings = report(Owner)
		helpers.assert_eq(#infos + #warnings, 0)
		remove(root)
	end)

	helpers.it("ignores a relative driver spelling, as a checkout run from its folder has", function()
		local root, Owner = tree(true)
		local used = Owner.install(".", { searchers = {} })
		helpers.assert_eq(used, false)
		local infos, warnings = report(Owner)
		helpers.assert_eq(#infos + #warnings, 0)
		remove(root)
	end)
end)
