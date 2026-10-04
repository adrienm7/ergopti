--- tests/unit/adapters/file_system/test_conditional_remove.lua

--- Exercises the actual adapter and shared conditional removal boundary.
local helpers = require("tests.helpers")
local with_fixture = require("tests.support.file_system_transaction_fixture").with_fixture

helpers.describe("FileSystem conditional removal ownership", function()
	helpers.it("conditional-remove serializes a nested replacement under its real destination lock", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local handle = assert(io.open(path, "w")); assert(handle:write("owned")); assert(handle:close())
			local adapter = fixture.make_adapter()
			local original_remove, nested, inside = os.remove, nil, false
			local ok, failure = xpcall(function()
				os.remove = function(target)
					if target == path and not inside then
						inside = true
						nested = adapter.write(path, "foreign")
						inside = false
					end
					return original_remove(target)
				end
				local removed = require("toml_codec.writer").remove_if_unchanged(path, adapter, { status = "ok", content = "owned" })
				helpers.assert_eq(removed, true)
				helpers.assert_eq(nested, false, "a nested cooperating replacement must not cross the unlink boundary")
				helpers.assert_eq(adapter.read_with_status(path), nil)
			end, debug.traceback)
			os.remove = original_remove
			original_remove(path); original_remove(path .. fixture.WRITE_LOCK_SUFFIX)
			if not ok then error(failure, 0) end
		end)
	end)
	helpers.it("conditional-remove shared writer uses the explicit atomic conditional capability", function()
		local content, called = "owned", 0
		local adapter = {
			read_with_status = function() return content, "ok" end,
			remove_exact = function() content = nil; return true end,
			remove_if_unchanged = function(_, expected)
				called = called + 1
				helpers.assert_eq(expected, { status = "ok", content = "owned" })
				content = "foreign"
				return false
			end,
		}
		helpers.assert_eq(require("toml_codec.writer").remove_if_unchanged("config", adapter, { status = "ok", content = "owned" }), false)
		helpers.assert_eq(called, 1)
		helpers.assert_eq(content, "foreign")
	end)
	helpers.it("conditional-remove retains post-unlink native release and never deletes a foreign recreation", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local handle = assert(io.open(path, "w")); assert(handle:write("owned")); assert(handle:close())
			local original_open, original_remove = io.open, os.remove
			local release_refused, unlinks = true, 0
			local adapter = fixture.make_adapter(nil, nil, nil, nil, nil, function() return not release_refused end)
			local ok, failure = xpcall(function()
				io.open = function(target, mode)
					local opened, detail = original_open(target, mode)
					if target ~= path .. fixture.WRITE_LOCK_SUFFIX or mode ~= "a+" then return opened, detail end
					return { close = function() if release_refused then return false end; return opened:close() end }
				end
				os.remove = function(target) if target == path then unlinks = unlinks + 1 end; return original_remove(target) end
				local removed, _, receipt = adapter.remove_if_unchanged(path, { status = "ok", content = "owned" })
				helpers.assert_eq(removed, false)
				helpers.assert_eq(receipt.removed, true)
				helpers.assert_eq(receipt.is_settled(), false)
				helpers.assert_eq(unlinks, 1)
				local recreated = assert(original_open(path, "w")); assert(recreated:write("foreign")); assert(recreated:close())
				release_refused = false
				helpers.assert_eq(receipt.retry(), false)
				helpers.assert_eq(adapter.read(path), "foreign")
				helpers.assert_eq(unlinks, 1)
				assert(original_remove(path))
				helpers.assert_eq(receipt.retry(), true)
				helpers.assert_eq(receipt.is_settled(), true)
				helpers.assert_eq(receipt.retry(), true)
				helpers.assert_eq(unlinks, 1)
			end, debug.traceback)
			io.open, os.remove = original_open, original_remove
			original_remove(path); original_remove(path .. fixture.WRITE_LOCK_SUFFIX)
			if not ok then error(failure, 0) end
		end)
	end)
	helpers.it("conditional-remove rejects a newly foreign final symlink while preserving its target", function()
		with_fixture(function(fixture)
			local target = os.tmpname():gsub("\\", "/")
			local handle = assert(io.open(target, "w")); assert(handle:write("owned")); assert(handle:close())
			local alias = target .. ".alias"
			local adapter = fixture.make_adapter({ [alias] = target })
			local removed = adapter.remove_if_unchanged(alias, { status = "ok", content = "owned" })
			helpers.assert_eq(removed, false)
			helpers.assert_eq(adapter.read(target), "owned")
			assert(os.remove(target))
		end)
	end)
	helpers.it("conditional-remove refuses stale bytes before unlink", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local handle = assert(io.open(path, "w")); assert(handle:write("foreign")); assert(handle:close())
			local adapter = fixture.make_adapter()
			helpers.assert_eq(adapter.remove_if_unchanged(path, { status = "ok", content = "owned" }), false)
			helpers.assert_eq(adapter.read(path), "foreign")
			assert(os.remove(path)); os.remove(path .. fixture.WRITE_LOCK_SUFFIX)
		end)
	end)
end)
