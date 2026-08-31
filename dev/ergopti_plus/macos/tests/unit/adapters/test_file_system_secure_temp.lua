--- tests/unit/adapters/test_file_system_secure_temp.lua

--- ==============================================================================
--- MODULE: FileSystem Secure Temporary File
--- DESCRIPTION:
--- Exercises the real adapter method against controlled os.tmpname and no-follow
--- classification boundaries. The method must publish only an already-created
--- regular file and must propagate every allocation/classification refusal.
--- ==============================================================================

local helpers = require("tests.helpers")


local function with_fresh_file_system(tmpname, attributes, fn)
	local original_tmpname = os.tmpname
	local original_hs = rawget(_G, "hs")
	local original_loaded_hs = package.loaded["hs"]
	local original_file_system = package.loaded["adapters.file_system"]
	local hs_stub = require("tests.stubs.hs")
	local original_symlink_attributes = hs_stub.fs.symlinkAttributes
	local ok, result = xpcall(function()
		os.tmpname = tmpname
		hs_stub.__reset()
		hs_stub.fs.symlinkAttributes = attributes
		_G.hs = hs_stub
		package.loaded["hs"] = hs_stub
		package.loaded["adapters.file_system"] = nil
		return fn(require("adapters.file_system"))
	end, debug.traceback)
	os.tmpname = original_tmpname
	hs_stub.fs.symlinkAttributes = original_symlink_attributes
	_G.hs = original_hs
	package.loaded["hs"] = original_loaded_hs
	package.loaded["adapters.file_system"] = original_file_system
	if not ok then error(result, 0) end
	return result
end


helpers.describe("FileSystem.create_secure_temp_file", function()
	helpers.it("returns only the exact regular file created by os.tmpname", function()
		local calls = 0
		with_fresh_file_system(function()
			calls = calls + 1
			return "/private/tmp/ergopti-owned-1"
		end, function(path)
			helpers.assert_eq(path, "/private/tmp/ergopti-owned-1")
			return { mode = "file" }
		end, function(FileSystem)
			local path, detail = FileSystem.create_secure_temp_file()
			helpers.assert_eq(path, "/private/tmp/ergopti-owned-1")
			helpers.assert_eq(detail, nil)
		end)
		helpers.assert_eq(calls, 1)
	end)

	for _, mode in ipairs({ "missing", "directory", "throw" }) do
		helpers.it("rejects a " .. mode .. " os.tmpname result", function()
			with_fresh_file_system(function()
				if mode == "throw" then error("tmpname exploded") end
				return mode == "missing" and "" or "/private/tmp/not-a-file"
			end, function()
				return { mode = "directory" }
			end, function(FileSystem)
				local path, detail = FileSystem.create_secure_temp_file()
				helpers.assert_eq(path, nil)
				helpers.assert_type(detail, "string")
			end)
		end)
	end
end)
