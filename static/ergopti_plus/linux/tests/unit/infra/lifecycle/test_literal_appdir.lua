--- tests/unit/infra/lifecycle/test_literal_appdir.lua
--- A real AppDir and owned workers must accept literal template delimiters.
local helpers = require("tests.helpers")

helpers.describe("literal AppDir paths", function()
	helpers.it("launches the daemon and native workers under semicolon and question mark (literal-appdir)", function()
		-- This is a Linux LuaJIT/native integration, not a Lua 5.4 or Windows double.
		if not jit or jit.os ~= "Linux" then return end
		local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
		local root = helpers.driver_root()
		local command = "python3 " .. quote(root .. "/tests/fixtures/literal_appdir_contract.py")
			.. " " .. quote(root) .. " 2>&1"
		local pipe = assert(io.popen(command, "r"))
		local output = pipe:read("*a")
		local ok, why, status = pipe:close()
		helpers.assert_true(ok == true or ok == 0, output .. " (" .. tostring(why) .. ":" .. tostring(status) .. ")")
		helpers.assert_contains(output, "literal AppDir integration passed")
	end)
end)
