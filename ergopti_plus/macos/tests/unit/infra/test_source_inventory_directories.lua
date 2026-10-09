--- tests/unit/infra/test_source_inventory_directories.lua

--- ==============================================================================
--- MODULE: Native Source Directory Enumeration Regression
--- DESCRIPTION:
--- A directory ending in .lua is not a source file. Exercises the actual host
--- enumeration and strict reader against an owned temporary directory tree.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("native source file enumeration", function()
	helpers.it("(source-inventory-directories) reads nested files without reading their .lua directory", function()
		helpers.with_stub_scope({ "tests.helpers", "tests.stubs.hs" }, function()
			local fs = require("tests.stubs.hs").fs
			local subject = require("tests.helpers")
			local root = assert(os.tmpname()):gsub("\\", "/")
			local removed, reason, code = os.remove(root)
			assert(removed or code == 2, reason)
			local directory, leaf = root .. "/folder.lua", root .. "/folder.lua/leaf.lua"
			local root_owned, directory_owned = false, false
			local outcome = table.pack(pcall(function()
				assert(fs.attributes(root) == nil, "temporary root must not preexist")
				root_owned = true
				assert(fs.mkdir(root))
				directory_owned = true
				assert(fs.mkdir(directory))
				local handle = assert(io.open(leaf, "w"))
				local written = table.pack(pcall(handle.write, handle, "-- nested source\n"))
				local closed = table.pack(pcall(handle.close, handle))
				assert(written[1] and written[2], tostring(written[3] or written[2]))
				assert(closed[1] and closed[2], tostring(closed[3] or closed[2]))
				subject.driver_root = function() return root .. "/" end
				helpers.assert_eq(subject.read_driver_source(), "-- nested source\n")
			end))
			local errors = {}
			local function cleanup(label, callback)
				local ok, result, failure = pcall(callback)
				if not ok or not result then errors[#errors + 1] = label .. ": " .. tostring(ok and failure or result) end
			end
			if directory_owned then
				cleanup("leaf removal", function()
					local ok, failure, errno = os.remove(leaf)
					if errno == 2 then return true end
					return ok, failure
				end)
				if fs.attributes(directory) then cleanup("directory removal", function() return fs.rmdir(directory) end) end
			end
			if root_owned and fs.attributes(root) then cleanup("root removal", function() return fs.rmdir(root) end) end
			if #errors > 0 then
				error((outcome[1] and "fixture cleanup failed" or tostring(outcome[2])) .. "; " .. table.concat(errors, "; "), 0)
			end
			if not outcome[1] then error(outcome[2], 0) end
		end)
	end)
end)
