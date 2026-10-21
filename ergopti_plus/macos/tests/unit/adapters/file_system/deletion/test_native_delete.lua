--- tests/unit/adapters/file_system/deletion/test_native_delete.lua

--- ==============================================================================
--- MODULE: FileSystem Native Path Deletion
--- DESCRIPTION:
--- Stat follows the target of a link; unlink removes the pathname itself.
--- A missing or uninspectable target must never certify an undeleted link.
--- Actual private files, LuaFileSystem metadata and libc remove supply receipts.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED = { "adapters.file_system", "infra.logger", "diagnostics.operation_reporter",
	"infra.fs_dir", "infra.text_utils", "text_utils", "compat.utf8", "lfs" }

local function write(path, content)
	local handle = assert(io.open(path, "wb"))
	assert(handle:write(content or "private sentinel"))
	assert(handle:close())
end

--- Unlinks symlinks instead of following them during private-tree cleanup.
local function cleanup(fs, root)
	for name in fs.dir(root) do
		if name ~= "." and name ~= ".." then
			local path = root .. "/" .. name
			if fs.symlinkattributes(path, "mode") == "directory" then cleanup(fs, path)
			else assert(os.remove(path)) end
		end
	end
	assert(fs.rmdir(root))
end

local function fixture(callback)
	local previous_hs, previous_lfs, native_remove = rawget(_G, "hs"), rawget(_G, "lfs"), os.remove
	local fs, root
	local ok, detail = xpcall(function()
		helpers.with_fresh_modules(OWNED, function()
			rawset(_G, "lfs", nil)
			fs = require("lfs")
			root = os.tmpname()
			assert(native_remove(root))
			assert(fs.mkdir(root))
			local state = { fs = fs, root = root, removes = 0, errors = {} }
			local logger = helpers.make_logger_stub()
			logger.error = function(_, message, ...)
				state.errors[#state.errors + 1] = string.format(message, ...)
			end
			package.loaded["infra.logger"] = logger
			package.loaded["infra.fs_dir"] = {}
			package.loaded["diagnostics.operation_reporter"] = {}
			_G.hs = { fs = { attributes = fs.attributes, symlinkAttributes = fs.symlinkattributes } }
			local adapter = require("adapters.file_system")
			os.remove = function(path)
				helpers.assert_eq(path, state.requested, "unlink must receive the unchanged pathname")
				state.removes = state.removes + 1
				state.receipt = table.pack(native_remove(path))
				return table.unpack(state.receipt, 1, state.receipt.n)
			end
			callback(adapter, state)
		end)
	end, debug.traceback)
	os.remove, _G.hs = native_remove, previous_hs
	local cleaned, cleanup_error = pcall(function() if root then cleanup(fs, root) end end)
	rawset(_G, "lfs", previous_lfs)
	if not ok then error(detail, 0) end
	assert(cleaned, cleanup_error)
end

helpers.describe("FileSystem deletion receives native pathname outcomes", function()
	for _, kind in ipairs({ "file", "absent", "live link", "broken link", "loop link", "directory link",
		"empty directory", "nonempty directory", "nondirectory parent" }) do
		helpers.it("handles a real " .. kind .. " without mistaking stat for removal", function()
			fixture(function(adapter, s)
				local path = s.root .. "/entry"
				local target = s.root .. "/target"
				if kind == "file" then write(path)
				elseif kind == "live link" then write(target); assert(s.fs.link(target, path, true))
				elseif kind == "broken link" then assert(s.fs.link(target, path, true))
				elseif kind == "loop link" then assert(s.fs.link(path, path, true))
				elseif kind == "directory link" then
					assert(s.fs.mkdir(target)); write(target .. "/kept")
					assert(s.fs.link(target, path, true))
				elseif kind == "empty directory" then assert(s.fs.mkdir(path))
				elseif kind == "nonempty directory" then assert(s.fs.mkdir(path)); write(path .. "/kept")
				elseif kind == "nondirectory parent" then write(target); path = target .. "/entry" end
				s.requested = path
				local rejected = kind == "nonempty directory" or kind == "nondirectory parent"
				helpers.assert_eq(adapter.delete(path), not rejected)
				if rejected then
					helpers.assert_eq(s.removes, 1)
					helpers.assert_nil(s.receipt[1])
					helpers.assert_true(type(s.receipt[3]) == "number" and s.receipt[3] ~= 2,
						"non-ENOENT native errors must remain refusals on each host")
					helpers.assert_eq(#s.errors, 1)
					if kind == "nonempty directory" then
						helpers.assert_eq(s.fs.attributes(path .. "/kept", "mode"), "file")
					else helpers.assert_eq(s.fs.attributes(target, "mode"), "file") end
				else
					helpers.assert_nil(s.fs.symlinkattributes(path), "the pathname must actually be absent")
					helpers.assert_eq(#s.errors, 0)
					if kind ~= "absent" then helpers.assert_eq(s.removes, 1) end
					if kind == "live link" then helpers.assert_eq(s.fs.attributes(target, "mode"), "file") end
					if kind == "directory link" then
						helpers.assert_eq(s.fs.attributes(target .. "/kept", "mode"), "file")
					end
				end
			end)
		end)
	end

	helpers.it("preserves native parent-link traversal and the exact requested path", function()
		fixture(function(adapter, s)
			local parent = s.root .. "/target"
			assert(s.fs.mkdir(parent)); assert(s.fs.mkdir(parent .. "/leaf"))
			write(parent .. "/victim"); write(s.root .. "/victim")
			assert(s.fs.link(parent .. "/leaf", s.root .. "/route", true))
			s.requested = s.root .. "/route/../victim"
			helpers.assert_true(adapter.delete(s.requested))
			helpers.assert_eq(s.removes, 1)
			helpers.assert_nil(s.fs.symlinkattributes(parent .. "/victim"))
			helpers.assert_eq(s.fs.attributes(s.root .. "/victim", "mode"), "file",
				"lexical normalization would delete the wrong file")
		end)
	end)
end)
