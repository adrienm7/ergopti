--- tests/unit/infra/test_config_migrate.lua

--- ==============================================================================
--- MODULE: Config Migration (Linux)
--- DESCRIPTION:
--- Runs the shared config migration contract with the Linux driver id under
--- the Linux runner (LuaJIT in CI): the cross-driver corpus replayed through
--- _shared/lua/config_migrate.lua, byte preservation of every record no step
--- touches, and the boot run's backup, publication and read-only refusal of a
--- newer file. It also pins where the daemon runs the migration: at the top
--- of main(), before the hotstring, gesture and shortcut readers.
--- ==============================================================================

local helpers = require("tests.helpers")

require("test.config_migrate_contract").register(helpers, { driver = "linux" })
require("test.config_migrate_records_contract").register(helpers, { driver = "linux" })
require("test.common_autocorrection_migration_contract").register(helpers, require("infra.paths").shared)

--- The daemon entry point with line comments removed: main() cannot run
--- headless, so its order is read from the source.
local function daemon_code()
	local fh = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
	local source = fh:read("*a")
	fh:close()
	return (source:gsub("%-%-[^\n]*", ""))
end

helpers.describe("config migration: daemon boot order (config-migrate-boot-order)", function()
	helpers.it("migrates config.toml at the start of main, before any config reader", function()
		local code = daemon_code()
		local main_at = code:find("local function main()", 1, true)
		local migrate = code:find("require(\"config_migrate\").boot(", 1, true)
		local hotstrings = code:find("hotstrings_config.init(", 1, true)
		local gestures = code:find("gestures.init({", 1, true)
		local shortcuts = code:find("shortcuts.init({", 1, true)
		helpers.assert_true(main_at and migrate and hotstrings and gestures and shortcuts,
			"every boot marker must still exist")
		helpers.assert_true(main_at < migrate and migrate < hotstrings and migrate < gestures
			and migrate < shortcuts,
			"the migration runs inside main, before the hotstring, gesture and shortcut readers")
		local _, calls = code:gsub("require%(\"config_migrate\"%)%.boot%(", "")
		helpers.assert_eq(calls, 1, "the daemon migrates exactly once")
		local call = code:sub(migrate, (code:find("})", migrate, true) or migrate))
		helpers.assert_true(call:find("driver%s*=%s*\"linux\"") ~= nil,
			"the daemon migrates with its own driver id")
		helpers.assert_true(call:find("REGISTRY_PATH", 1, true) ~= nil,
			"the daemon loads the shared registry")
	end)
end)

helpers.describe("trusted normal-loader source spelling preserves constructor identity", function()
	helpers.it("compares handwritten file-source spellings without changing case or inventing a cwd", function()
		local identity = require("module_source_identity")
		local vectors = {
			{ "@/r/linux/../_shared/lua/config_migrate.lua", nil, "@/r/_shared/lua/config_migrate.lua" },
			{ "@../_shared/lua/config_migrate.lua", "/r/linux", "@/r/_shared/lua/config_migrate.lua" },
			{ "@./adapters/file_system.lua", "/r/linux", "@/r/linux/adapters/file_system.lua" },
			{ "@/r//./native.lua", nil, "@/r/native.lua" },
			{ "@../native.lua", "/r/driver", "@/r/native.lua" },
			{ "@./native.lua", nil, false },
			{ "@./native.lua", "relative-cwd", false },
			{ "@/../../native.lua", "/r", false },
			{ "=copied source", "/r", false },
			{ "@", "/r", false },
		}
		for _, vector in ipairs(vectors) do
			helpers.assert_eq(identity.normalize(vector[1], vector[2]), vector[3] or nil)
		end
		helpers.assert_eq(identity.same("@/r/Native.lua", "@/r/native.lua"), false)
		helpers.assert_eq(identity.same("@native.lua", "@/r/native.lua"), false)
		helpers.assert_eq(identity.same("@native.lua", "@/r/native.lua", "/wrong"), false)
		helpers.assert_eq(identity.same(nil, nil), false)
	end)

	helpers.it("derives only exact platform sibling paths and retains captured pure helper behavior", function()
		local identity = require("module_source_identity")
		local same, sibling, normalize = identity.same, identity.sibling, identity.normalize
		local before = sibling("@./adapters/file_system.lua", "linux/adapters/file_system.lua",
			"_shared/lua/config_migrate.lua", "/r/linux")
		local ok, detail = xpcall(function()
			identity.normalize = function() error("withdrawn public normalizer must not run") end
			helpers.assert_eq(before, "@/r/_shared/lua/config_migrate.lua")
			helpers.assert_eq(sibling("@./adapters/file_system.lua", "macos/adapters/file_system.lua",
				"_shared/lua/config_migrate.lua", "/r/linux"), nil)
			helpers.assert_eq(same("@./native.lua", "@/r/linux/native.lua", "/r/linux"), true)
		end, debug.traceback)
		identity.normalize = normalize
		if not ok then error(detail, 0) end
	end)

	helpers.it("captures the actual native directory and keeps lexical comparisons query-free", function()
		local identity, directory = require("module_source_identity"), require("module_source_directory")
		local lfs = require("lfs")
		local captured, original, calls = directory.capture(), directory.capture, 0
		local ok, detail = xpcall(function()
			directory.capture = function() calls = calls + 1; error("a later comparison must not query cwd") end
			helpers.assert_eq(captured, lfs.currentdir())
			helpers.assert_eq(identity.same("@./native.lua", "@" .. captured .. "/native.lua", captured), true)
			helpers.assert_eq(calls, 0)
		end, debug.traceback)
		directory.capture = original
		if not ok then error(detail, 0) end
	end)

	for _, mode in ipairs({ "relative", "absolute_dot", "mixed_cached" }) do
		helpers.it("the genuine native constructor reads and publishes from driver CWD " .. mode, function()
			local driver = helpers.driver_root()
			local script = os.tmpname()
			local source = [[
local driver, mode = assert(arg[1]), assert(arg[2])
local relative = './?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;'
local absolute = driver .. '/?.lua;' .. driver .. '/?/init.lua;' .. driver .. '/../_shared/lua/?.lua;' .. driver .. '/../_shared/lua/?/init.lua;'
local canonical = driver:gsub('/linux$', '/_shared/lua') .. '/?.lua;'
package.path = mode == 'mixed_cached' and canonical .. absolute .. package.path or (mode == 'relative' and relative or absolute) .. package.path
local engine = require('config_migrate')
if mode == 'mixed_cached' then package.path = relative .. package.path end
local writer, files = require('toml_codec.writer'), require('adapters.file_system')
local registry = assert(engine.load_registry(driver .. '/../_shared/core/config_schema/migrations.toml'))
local path = os.tmpname(); os.remove(path)
local ok, detail = xpcall(function()
 local result = engine.boot({path=path,driver='linux',registry=registry,file_adapter=files})
 assert(result.status=='absent', result.detail)
 assert(writer.batch_write(path,{{section='llm',key='enabled',value=false}},files))
 local content,status = writer.read_classified(path,files)
 assert(status=='ok' and content:find('enabled = false',1,true))
 local replaced = {configuration_ports=function() error('copied initializer must not run') end}
 local original = files.configuration_ports; files.configuration_ports = replaced.configuration_ports
 local refused = writer.batch_write(path,{{section='llm',key='enabled',value=true}},files)
 files.configuration_ports = original
 assert(refused==false)
 print('LOADER_NATIVE_READY '..mode)
end,debug.traceback)
os.remove(path)
if not ok then error(detail,0) end
]]
			local file = assert(io.open(script, "wb")); assert(file:write(source)); assert(file:close())
			local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
			local command = "cd " .. quote(driver) .. " && " .. quote(assert(arg[-1])) .. " "
				.. quote(script) .. " " .. quote(driver) .. " " .. quote(mode) .. " 2>&1"
			local pipe = assert(io.popen(command, "r"))
			local output = pipe:read("*a")
			local first, kind, code = pipe:close()
			os.remove(script)
			helpers.assert_true(first == 0 or first == true and (kind == nil or kind == "exit") and (code == nil or code == 0), output)
			helpers.assert_true(output:find("LOADER_NATIVE_READY " .. mode, 1, true) ~= nil, output)
		end)
	end
end)

helpers.describe("native constructor source anchor refuses unavailable receipts", function()
	helpers.it("a failed genuine-present cwd port never falls back to inherited environment or another provider", function()
		local directory = require("module_source_directory")
		local saved_hs, calls, fallback = rawget(_G, "hs"), 0, 0
		local lfs, old = require("lfs"), nil
		old = lfs.currentdir
		local ok, detail = xpcall(function()
			_G.hs = { fs = { currentDir = function() calls = calls + 1; return nil end } }
			lfs.currentdir = function() fallback = fallback + 1; return "/fake-fallback" end
			helpers.assert_eq(directory.capture(), nil)
			helpers.assert_eq(calls, 1); helpers.assert_eq(fallback, 0)
			helpers.assert_eq(require("module_source_identity").same("@./native.lua", "@/fake-fallback/native.lua", nil), false)
		end, debug.traceback)
		lfs.currentdir = old; rawset(_G, "hs", saved_hs)
		if not ok then error(detail, 0) end
	end)
end)

helpers.describe("constructor source anchor supports the advertised lazy host port", function()
	for _, mode in ipairs({ "lazy", "throwing", "noncallable" }) do
		helpers.it("captures the host cwd lookup once and preserves refusal for " .. mode, function()
			local directory, lfs = require("module_source_directory"), require("lfs")
			local original_hs, native = rawget(_G, "hs"), lfs.currentdir
			local module_lookups, callable_lookups, calls, fallback = 0, 0, 0, 0
			local current = native()
			local ok, detail = xpcall(function()
				local host = setmetatable({}, { __index = function(_, key)
					if key == "currentDir" then
						callable_lookups = callable_lookups + 1
						if mode == "throwing" then error("advertised host getter refused") end
						if mode == "noncallable" then return false end
						return function() calls = calls + 1; return native() end
					end
				end })
				_G.hs = setmetatable({}, { __index = function(_, key)
					if key == "fs" then module_lookups = module_lookups + 1; return host end
				end })
				lfs.currentdir = function() fallback = fallback + 1; return current end
				local captured = directory.capture()
				helpers.assert_eq(captured, mode == "lazy" and current or nil)
				helpers.assert_eq(module_lookups, 1); helpers.assert_eq(callable_lookups, 1)
				helpers.assert_eq(calls, mode == "lazy" and 1 or 0); helpers.assert_eq(fallback, 0)
			end, debug.traceback)
			lfs.currentdir = native; rawset(_G, "hs", original_hs)
			if not ok then error(detail, 0) end
		end)
	end
end)
