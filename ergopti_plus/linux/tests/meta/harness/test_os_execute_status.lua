--- tests/meta/harness/test_os_execute_status.lua

--- ==============================================================================
--- MODULE: Portable os.execute Status
--- DESCRIPTION:
--- Lua 5.1 LuaJIT returns 0 from a successful os.execute, but the Fedora and
--- Alpine LuaJIT builds enable 5.2 compatibility and return true. A comparison
--- of os.execute(...) with 0 alone therefore failed only on those distributions
--- (run_sqlite_private_no_luv.lua). Every Linux Lua file must accept both.
--- ==============================================================================

local helpers = require("tests.helpers")
local quote = require("text_utils").shell_quote

--- Lists every Lua file of the driver, relative to its root.
--- @return table paths
local function lua_files()
	local root = helpers.driver_root()
	local pipe = assert(io.popen("cd " .. quote(root) .. " && find . -type f -name '*.lua' -not -path './vendor/*'"))
	local files = {}
	for line in pipe:lines() do files[#files + 1] = root .. "/" .. line:sub(3) end
	assert(pipe:close())
	return files
end

helpers.describe("os.execute status is read under both ABIs", function()
	helpers.it("no Linux Lua file compares an os.execute result with 0 alone", function()
		local files, offenders = lua_files(), {}
		helpers.assert_true(#files > 400, "the scan must see the whole driver, saw " .. #files)
		for _, path in ipairs(files) do
			local file = assert(io.open(path, "rb"))
			local source = assert(file:read("*a"))
			assert(file:close())
			local number = 0
			for line in (source .. "\n"):gmatch("([^\n]*)\n") do
				number = number + 1
				local at = line:find("os.execute(", 1, true)
				if at and not line:match("^%s*%-%-") and line:find(") == 0", at, true) and not line:find("== true", 1, true) then
					offenders[#offenders + 1] = path:sub(#helpers.driver_root() + 2) .. ":" .. number
				end
			end
		end
		helpers.assert_eq(offenders, {}, "these lines read os.execute as Lua 5.1 only")
	end)
end)
