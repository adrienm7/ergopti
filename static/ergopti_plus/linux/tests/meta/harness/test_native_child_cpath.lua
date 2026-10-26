--- tests/meta/harness/test_native_child_cpath.lua

--- ==============================================================================
--- MODULE: Native Child Interpreter Module Path
--- DESCRIPTION:
--- The distribution rows build luv and lfs for their own LuaJIT and expose them
--- only through LUA_CPATH. A test that starts a native child with LUA_CPATH
--- removed loses luv there and fails with "module 'luv' not found", although
--- the same test passes on Ubuntu, whose packaged luv sits on the default path.
--- ==============================================================================

local helpers = require("tests.helpers")
local Manifest = require("tests.test_manifest")

-- Built from parts so this file does not match its own search.
local REMOVAL = "-u " .. "LUA_CPATH"

helpers.describe("native child interpreters keep the admitted C module path", function()
	helpers.it("no test module starts a child without LUA_CPATH", function()
		helpers.assert_true(#Manifest > 400, "the scan must see the whole suite, saw " .. #Manifest)
		local offenders = {}
		for _, module_name in ipairs(Manifest) do
			local path = helpers.driver_root() .. "/" .. module_name:gsub("%.", "/") .. ".lua"
			local file = assert(io.open(path, "rb"))
			local source = assert(file:read("*a"))
			assert(file:close())
			-- A removal is admitted only when the same command line appends the
			-- interpreter's own path again (`-u LUA_CPATH" .. <provider>`) and the
			-- module builds that provider from package.cpath.
			local reassigns = source:find('LUA_CPATH=" .. quote(package.cpath)', 1, true) ~= nil
			for line in source:gmatch("[^\n]+") do
				local at = line:find(REMOVAL, 1, true)
				if at and not (reassigns and line:sub(at + #REMOVAL, at + #REMOVAL + 4) == '" .. ') then
					offenders[#offenders + 1] = module_name
					break
				end
			end
		end
		helpers.assert_eq(offenders, {}, "these tests remove LUA_CPATH from a native child")
	end)
end)
