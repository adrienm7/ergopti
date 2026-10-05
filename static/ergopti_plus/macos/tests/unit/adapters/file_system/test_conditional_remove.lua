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

helpers.describe("FileSystem private publication physical ownership", function()
	for _, refusal in ipairs({ "false", "nil" }) do
		helpers.it("private receipt retains unpublished staging after " .. refusal .. " write and cleanup refusal", function()
			with_fixture(function(fixture)
				local path = os.tmpname():gsub("\\", "/")
				assert(os.remove(path))
				local original_open, original_remove = io.open, os.remove
				local retained, payload, unlocks = true, nil, 0
				local adapter = fixture.make_adapter(nil, nil, nil, nil, nil, function()
					unlocks = unlocks + 1
					return true
				end)
				local categories = {}
				local function reporter(category, ...)
					helpers.assert_eq(select("#", ...), 0)
					categories[#categories + 1] = category
				end
				local expected, candidate = { status = "absent" }, "independent private staged bytes"
				local ok, failure = xpcall(function()
					io.open = function(target, mode)
						local handle, detail = original_open(target, mode)
						if not handle or mode ~= "w" or not target:match("/payload$") then return handle, detail end
						payload = target
						return {
							write = function(_, content)
								assert(handle:write(content))
								if refusal == "nil" then return nil, "closed fixture refusal" end
								return false, "closed fixture refusal"
							end,
							close = function() return handle:close() end,
						}
					end
					os.remove = function(target)
						if retained and target == payload then
							if refusal == "nil" then return nil, "closed cleanup refusal" end
							return false, "closed cleanup refusal"
						end
						return original_remove(target)
					end
					local written, _, receipt = adapter.write_if_unchanged(path, candidate, expected, reporter)
					io.open = original_open
					helpers.assert_eq(written, false)
					helpers.assert_eq(unlocks, 1, "acknowledged lock release cannot conceal retained staging")
					local physical = assert(original_open(payload, "rb"))
					helpers.assert_eq(physical:read("*a"), candidate, "independent native partial-write control")
					assert(physical:close())
					helpers.assert_eq(type(receipt), "table", "unpublished native staging needs its exact private capability")
					local view = adapter.publication_receipt_view(receipt, path, expected, candidate, reporter)
					helpers.assert_eq(view, { published = false, source = { status = "absent" } })
					helpers.assert_eq(receipt.is_settled(), false)
					helpers.assert_eq(receipt.retry(), false)
					helpers.assert_eq(adapter.write(path, "successor"), false, "the same physical staging debt blocks a successor")
					local foreign = assert(original_open(path, "w")); assert(foreign:write(candidate)); assert(foreign:close())
					retained = false
					helpers.assert_eq(receipt.retry(), false, "foreign source must not borrow the unchanged-source cleanup fence")
					helpers.assert_true(fixture.HOST_ATTRIBUTES(payload) ~= nil)
					assert(original_remove(path))
					helpers.assert_eq(receipt.retry(), true)
					helpers.assert_eq(receipt.is_settled(), true)
					helpers.assert_eq(fixture.HOST_ATTRIBUTES(payload), nil)
					helpers.assert_eq(fixture.HOST_ATTRIBUTES(payload:match("^(.*)/payload$")), nil)
					helpers.assert_true(#categories > 0)
				end, debug.traceback)
				io.open, os.remove = original_open, original_remove
				retained = false
				pcall(adapter.write, path, "fixture cleanup")
				original_remove(path); original_remove(path .. fixture.WRITE_LOCK_SUFFIX)
				if not ok then error(failure, 0) end
			end)
		end)
	end

	helpers.it("published receipt rejects a foreign same-byte inode and accepts its actual inode restored", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			assert(os.remove(path))
			local foreign_path, owned_backup = path .. ".foreign", path .. ".owned"
			local adapter = fixture.make_adapter()
			local candidate, expected = "independently authored same bytes", { status = "absent" }
			local function reporter() end
			local ok, failure = xpcall(function()
				local written, _, receipt = adapter.write_if_unchanged(path, candidate, expected, reporter)
				helpers.assert_eq(written, true)
				helpers.assert_eq(receipt.matches_source(), true)
				local original = assert(fixture.HOST_ATTRIBUTES(path))
				local file = assert(io.open(foreign_path, "w")); assert(file:write(candidate)); assert(file:close())
				local foreign = assert(fixture.HOST_ATTRIBUTES(foreign_path))
				helpers.assert_true(original.dev ~= foreign.dev or original.ino ~= foreign.ino,
					"native positive control requires physically distinct live regular files")
				assert(os.rename(path, owned_backup))
				assert(os.rename(foreign_path, path))
				helpers.assert_eq(adapter.read(path), candidate)
				helpers.assert_eq(receipt.matches_source(), false, "equal bytes do not transfer native publication ownership")
				helpers.assert_eq(adapter.publication_receipt_view(receipt, path, expected, candidate, reporter).published, true)
				assert(os.remove(path)); assert(os.rename(owned_backup, path))
				helpers.assert_eq(receipt.matches_source(), true, "restored exact owned inode remains a positive control")
			end, debug.traceback)
			os.remove(path); os.remove(foreign_path); os.remove(owned_backup)
			os.remove(path .. fixture.WRITE_LOCK_SUFFIX)
			if not ok then error(failure, 0) end
		end)
	end)

	helpers.it("receipt identity comes from staging before a foreign replacement inside rename returns", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			assert(os.remove(path))
			local foreign_path, owned_backup = path .. ".foreign", path .. ".owned"
			local candidate, expected = "same bytes after native publication", { status = "absent" }
			local file = assert(io.open(foreign_path, "w")); assert(file:write(candidate)); assert(file:close())
			local adapter = fixture.make_adapter()
			local original_rename, staging_identity = os.rename, nil
			local ok, failure = xpcall(function()
				os.rename = function(source, target)
					if target == path and source:match("/payload$") then
						staging_identity = assert(fixture.HOST_ATTRIBUTES(source))
						assert(original_rename(source, target))
						assert(original_rename(target, owned_backup))
						assert(original_rename(foreign_path, target))
						return true
					end
					return original_rename(source, target)
				end
				local written, _, receipt = adapter.write_if_unchanged(path, candidate, expected, function() end)
				os.rename = original_rename
				helpers.assert_eq(written, false, "postpublication foreign inode cannot certify this native publication")
				helpers.assert_eq(adapter.read(path), candidate)
				local foreign_identity = assert(fixture.HOST_ATTRIBUTES(path))
				helpers.assert_true(staging_identity.dev ~= foreign_identity.dev or staging_identity.ino ~= foreign_identity.ino)
				helpers.assert_eq(receipt.matches_source(), false)
				assert(os.remove(path)); assert(original_rename(owned_backup, path))
				helpers.assert_eq(receipt.matches_source(), true)
			end, debug.traceback)
			os.rename = original_rename
			os.remove(path); os.remove(foreign_path); os.remove(owned_backup)
			os.remove(path .. fixture.WRITE_LOCK_SUFFIX)
			if not ok then error(failure, 0) end
		end)
	end)
end)

helpers.describe("FileSystem retained private receipt source fences", function()
	helpers.it("unpublished receipt rejects a foreign same-byte prior source inode", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local file = assert(io.open(path, "w")); assert(file:write("prior bytes")); assert(file:close())
			local original_remove, original_rename = os.remove, os.rename
			local foreign_path, owned_backup = path .. ".foreign", path .. ".owned"
			local retained, payload, receipt = true, nil, nil
			local adapter = fixture.make_adapter()
			local ok, failure = xpcall(function()
				os.rename = function(source, target)
					if source:match("/payload$") and target == path then
						payload = source
						return false, "closed prepublication refusal"
					end
					return original_rename(source, target)
				end
				os.remove = function(target)
					if retained and target == payload then return false, "closed cleanup refusal" end
					return original_remove(target)
				end
				local written, detail
				written, detail, receipt = adapter.write_if_unchanged(path, "candidate bytes",
					{ status = "ok", content = "prior bytes" }, function() end)
				helpers.assert_eq(written, false)
				helpers.assert_eq(type(receipt), "table")
				helpers.assert_eq(receipt.matches_source(), true)
				local original_identity = assert(fixture.HOST_ATTRIBUTES(path))
				local foreign = assert(io.open(foreign_path, "w")); assert(foreign:write("prior bytes")); assert(foreign:close())
				local foreign_identity = assert(fixture.HOST_ATTRIBUTES(foreign_path))
				helpers.assert_true(original_identity.dev ~= foreign_identity.dev or original_identity.ino ~= foreign_identity.ino)
				assert(original_rename(path, owned_backup)); assert(original_rename(foreign_path, path))
				helpers.assert_eq(adapter.read(path), "prior bytes")
				helpers.assert_eq(receipt.matches_source(), false)
				retained = false
				helpers.assert_eq(receipt.retry(), false)
				helpers.assert_true(fixture.HOST_ATTRIBUTES(payload) ~= nil)
				assert(original_remove(path)); assert(original_rename(owned_backup, path))
				helpers.assert_eq(receipt.matches_source(), true)
				helpers.assert_eq(receipt.retry(), true)
				helpers.assert_eq(receipt.is_settled(), true)
				helpers.assert_eq(fixture.HOST_ATTRIBUTES(payload), nil)
			end, debug.traceback)
			os.remove, os.rename = original_remove, original_rename
			retained = false
			if fixture.HOST_ATTRIBUTES(owned_backup) then
				original_remove(path); original_rename(owned_backup, path)
			end
			if receipt then pcall(receipt.retry) end
			pcall(adapter.write, path, "fixture cleanup")
			original_remove(path); original_remove(foreign_path); original_remove(owned_backup)
			original_remove(path .. fixture.WRITE_LOCK_SUFFIX)
			if not ok then error(failure, 0) end
		end)
	end)

	helpers.it("retained receipt rechecks its source after acquiring a retry lock", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			assert(os.remove(path))
			local original_remove, original_rename = os.remove, os.rename
			local locks, retained, payload, receipt = 0, true, nil, nil
			local adapter = fixture.make_adapter(nil, nil, nil, nil, function()
				locks = locks + 1
				if locks == 2 then
					local foreign = assert(io.open(path, "w")); assert(foreign:write("foreign winner")); assert(foreign:close())
				end
				return true
			end)
			local ok, failure = xpcall(function()
				os.rename = function(source, target)
					if source:match("/payload$") and target == path then
						payload = source
						return false, "closed prepublication refusal"
					end
					return original_rename(source, target)
				end
				os.remove = function(target)
					if retained and target == payload then return false, "closed cleanup refusal" end
					return original_remove(target)
				end
				local written, detail
				written, detail, receipt = adapter.write_if_unchanged(path, "candidate bytes", { status = "absent" }, function() end)
				helpers.assert_eq(written, false)
				helpers.assert_eq(type(receipt), "table")
				retained = false
				helpers.assert_eq(receipt.retry(), false, "lock acquisition reentry must not cross the source cleanup fence")
				helpers.assert_eq(adapter.read(path), "foreign winner")
				helpers.assert_true(fixture.HOST_ATTRIBUTES(payload) ~= nil)
				helpers.assert_eq(receipt.is_settled(), false)
				assert(original_remove(path))
				helpers.assert_eq(receipt.retry(), true)
				helpers.assert_eq(locks, 2, "the exact already-acquired retry lock remains owned")
				helpers.assert_eq(receipt.is_settled(), true)
				helpers.assert_eq(fixture.HOST_ATTRIBUTES(payload), nil)
			end, debug.traceback)
			os.remove, os.rename = original_remove, original_rename
			retained = false
			original_remove(path)
			if receipt then pcall(receipt.retry) end
			pcall(adapter.write, path, "fixture cleanup")
			original_remove(path); original_remove(path .. fixture.WRITE_LOCK_SUFFIX)
			if not ok then error(failure, 0) end
		end)
	end)
end)

helpers.describe("FileSystem retained staging identity", function()
	for _, cleanup in ipairs({ "opaque", "generic" }) do
		for _, replacement in ipairs({ "payload", "directory" }) do
			helpers.it(cleanup .. " cleanup preserves a foreign " .. replacement .. " and its original staged inode", function()
				with_fixture(function(fixture)
					local path = os.tmpname():gsub("\\", "/")
					assert(os.remove(path))
					local original_open, original_remove, original_rename = io.open, os.remove, os.rename
					local payload, directory, backup, receipt
					local retained, foreign_live, foreign_unlinks, foreign_rmdirs = true, false, 0, 0
					local candidate = "independent same-byte staged payload"
					local adapter = fixture.make_adapter()
					local native_rmdir = hs.fs.rmdir
					local function bytes(target)
						local handle = assert(original_open(target, "rb"))
						local content = handle:read("*a"); assert(handle:close()); return content
					end
					local function restore()
						if not foreign_live then return end
						if fixture.HOST_ATTRIBUTES(payload) then assert(original_remove(payload)) end
						if replacement == "directory" and fixture.HOST_ATTRIBUTES(directory) then
							assert(fixture.HOST_RMDIR(directory))
						end
						assert(original_rename(backup, replacement == "directory" and directory or payload))
						foreign_live = false
					end
					local ok, failure = xpcall(function()
						io.open = function(target, mode)
							if mode == "w" and target:match("/payload$") then payload = target end
							return original_open(target, mode)
						end
						os.rename = function(source, target)
							if source == payload and target == path then return false, "closed publication refusal" end
							return original_rename(source, target)
						end
						os.remove = function(target)
							if target == payload and foreign_live then foreign_unlinks = foreign_unlinks + 1 end
							if retained and target == payload then return false, "closed cleanup refusal" end
							return original_remove(target)
						end
						hs.fs.rmdir = function(target)
							if foreign_live and target == directory then foreign_rmdirs = foreign_rmdirs + 1 end
							return native_rmdir(target)
						end
						local written
						written, _, receipt = adapter.write_if_unchanged(path, candidate, { status = "absent" }, function() end)
						helpers.assert_eq(written, false)
						helpers.assert_eq(type(receipt), "table")
						helpers.assert_eq(receipt.is_settled(), false)
						directory = payload:match("^(.*)/payload$")
						local own_path = replacement == "directory" and directory or payload
						local owned = assert(fixture.HOST_SYMLINK_ATTRIBUTES(own_path))
						backup = own_path .. ".original"
						assert(original_rename(own_path, backup))
						if replacement == "directory" then assert(fixture.HOST_MKDIR(directory)) end
						local foreign = assert(original_open(payload, "w")); assert(foreign:write(candidate)); assert(foreign:close())
						local other = assert(fixture.HOST_SYMLINK_ATTRIBUTES(own_path))
						helpers.assert_true(owned.dev ~= other.dev or owned.ino ~= other.ino,
							"independent simultaneous native identities must differ")
						foreign_live, retained = true, false
						local original_payload = replacement == "directory" and backup .. "/payload" or backup
						if cleanup == "opaque" then helpers.assert_eq(receipt.retry(), false)
						else helpers.assert_eq(adapter.write(path, "successor"), false) end
						helpers.assert_eq(foreign_unlinks, 0, "foreign inode must never reach unlink")
						helpers.assert_eq(foreign_rmdirs, 0, "foreign directory must never reach rmdir")
						helpers.assert_eq(bytes(payload), candidate)
						helpers.assert_eq(bytes(original_payload), candidate)
						helpers.assert_eq(receipt.is_settled(), false, "renamed original remains exact native cleanup debt")
						helpers.assert_eq(adapter.read_with_status(path), nil)
						restore()
						helpers.assert_eq(receipt.retry(), true, "restoring original dev/ino is a positive physical control")
						helpers.assert_eq(receipt.is_settled(), true)
						helpers.assert_eq(fixture.HOST_ATTRIBUTES(payload), nil)
						helpers.assert_eq(fixture.HOST_ATTRIBUTES(directory), nil)
					end, debug.traceback)
					io.open, os.remove, os.rename, hs.fs.rmdir = original_open, original_remove, original_rename, native_rmdir
					retained = false
					local restored, restore_failure = pcall(restore)
					if restored and receipt then pcall(receipt.retry) end
					original_remove(path); original_remove(path .. fixture.WRITE_LOCK_SUFFIX)
					if not restored then error(restore_failure, 0) end
					if not ok then error(failure, 0) end
				end)
			end)
		end
	end
end)

helpers.describe("FileSystem initial staging capture ordering", function()
	helpers.it("pins its live payload before the write callback can replace it with identical bytes", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/"); assert(os.remove(path))
			local original_open, original_remove, original_rename = io.open, os.remove, os.rename
			local adapter = fixture.make_adapter()
			local payload, backup, receipt, foreign_live
			local candidate = "same bytes after live-handle swap"
			local function restore()
				if not foreign_live then return end
				original_remove(payload); original_remove(path)
				assert(original_rename(backup, payload)); foreign_live = false
			end
			local ok, failure = xpcall(function()
				io.open = function(target, mode)
					local handle, detail = original_open(target, mode)
					if not handle or mode ~= "w" or not target:match("/payload$") then return handle, detail end
					payload, backup = target, target .. ".original"
					return {
						write = function(_, content)
							assert(handle:write(content)); assert(handle:flush())
							local owned = assert(fixture.HOST_ATTRIBUTES(payload))
							assert(original_rename(payload, backup))
							local other = assert(original_open(payload, "w")); assert(other:write(content)); assert(other:close())
							local foreign = assert(fixture.HOST_ATTRIBUTES(payload))
							helpers.assert_true(owned.dev ~= foreign.dev or owned.ino ~= foreign.ino)
							foreign_live = true
							return handle
						end,
						close = function() return handle:close() end,
					}
				end
				local written
				written, _, receipt = adapter.write_if_unchanged(path, candidate, { status = "absent" }, function() end)
				io.open = original_open
				helpers.assert_eq(written, false, "post-write attributes cannot adopt a replacement payload")
				helpers.assert_eq(type(receipt), "table")
				helpers.assert_eq(receipt.is_settled(), false)
				helpers.assert_eq(adapter.read_with_status(path), nil)
				helpers.assert_true(fixture.HOST_ATTRIBUTES(payload) ~= nil)
				helpers.assert_true(fixture.HOST_ATTRIBUTES(backup) ~= nil)
				helpers.assert_eq(receipt.retry(), false)
				restore()
				helpers.assert_eq(receipt.retry(), true)
				helpers.assert_eq(receipt.is_settled(), true)
			end, debug.traceback)
			io.open = original_open
			local restored, detail = pcall(restore)
			if restored and receipt then pcall(receipt.retry) end
			original_remove(path); original_remove(path .. fixture.WRITE_LOCK_SUFFIX)
			if not restored then error(detail, 0) end
			if not ok then error(failure, 0) end
		end)
	end)

	helpers.it("rechecks its directory after successful owned unlink before rmdir", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/"); assert(os.remove(path))
			local original_open, original_remove, original_rename = io.open, os.remove, os.rename
			local adapter = fixture.make_adapter()
			local payload, directory, backup, receipt, foreign_live
			local native_rmdir, foreign_rmdirs = hs.fs.rmdir, 0
			local function restore()
				if not foreign_live then return end
				if fixture.HOST_ATTRIBUTES(directory) then assert(fixture.HOST_RMDIR(directory)) end
				assert(original_rename(backup, directory)); foreign_live = false
			end
			local ok, failure = xpcall(function()
				io.open = function(target, mode)
					if mode == "w" and target:match("/payload$") then
						payload, directory = target, target:match("^(.*)/payload$"); backup = directory .. ".original"
					end
					return original_open(target, mode)
				end
				os.rename = function(source, target)
					if source == payload and target == path then return false, "closed publication refusal" end
					return original_rename(source, target)
				end
				os.remove = function(target)
					local removed, detail, code = original_remove(target)
					if target == payload and removed == true and not foreign_live then
						local owned = assert(fixture.HOST_ATTRIBUTES(directory))
						assert(original_rename(directory, backup)); assert(fixture.HOST_MKDIR(directory))
						local foreign = assert(fixture.HOST_ATTRIBUTES(directory))
						helpers.assert_true(owned.dev ~= foreign.dev or owned.ino ~= foreign.ino)
						foreign_live = true
					end
					return removed, detail, code
				end
				hs.fs.rmdir = function(target)
					if target == directory and foreign_live then foreign_rmdirs = foreign_rmdirs + 1 end
					return native_rmdir(target)
				end
				local written
				written, _, receipt = adapter.write_if_unchanged(path, "independent owned payload", { status = "absent" }, function() end)
				helpers.assert_eq(written, false)
				helpers.assert_eq(foreign_rmdirs, 0, "unlink acknowledgement must not authorize a replacement directory")
				helpers.assert_eq(type(receipt), "table")
				helpers.assert_eq(receipt.is_settled(), false)
				helpers.assert_eq(receipt.retry(), false)
				helpers.assert_true(fixture.HOST_ATTRIBUTES(directory) ~= nil)
				helpers.assert_true(fixture.HOST_ATTRIBUTES(backup) ~= nil)
				restore()
				helpers.assert_eq(receipt.retry(), true, "owned unlink receipt survives while original directory is restored")
				helpers.assert_eq(receipt.is_settled(), true)
				helpers.assert_eq(fixture.HOST_ATTRIBUTES(directory), nil)
			end, debug.traceback)
			io.open, os.remove, os.rename, hs.fs.rmdir = original_open, original_remove, original_rename, native_rmdir
			local restored, detail = pcall(restore)
			if restored and receipt then pcall(receipt.retry) end
			original_remove(path); original_remove(path .. fixture.WRITE_LOCK_SUFFIX)
			if not restored then error(detail, 0) end
			if not ok then error(failure, 0) end
		end)
	end)
end)

helpers.describe("FileSystem unavailable initial staging identity", function()
	for _, invalid in ipairs({ "nil", "false" }) do
		helpers.it("retains its actual open allocation after " .. invalid .. " initial identity and never adopts a later inode", function()
			with_fixture(function(fixture)
				local path = os.tmpname():gsub("\\", "/"); assert(os.remove(path))
				local original_open, original_remove, original_rename = io.open, os.remove, os.rename
				local adapter = fixture.make_adapter()
				local native_lstat = hs.fs.symlinkAttributes
				local payload, directory, opened, receipt
				local backup = path .. ".original-open-inode"
				local hidden, writes = true, 0
				local ok, failure = xpcall(function()
					io.open = function(target, mode)
						local handle, detail = original_open(target, mode)
						if not handle or mode ~= "w" or not target:match("/payload$") then return handle, detail end
						payload, directory, opened = target, target:match("^(.*)/payload$"), handle
						assert(original_rename(payload, backup))
						return { write = function(_, content) writes = writes + 1; return handle:write(content) end,
							close = function() return handle:close() end }
					end
					hs.fs.symlinkAttributes = function(target)
						if target == payload and hidden then
							if invalid == "false" then return false end
							return nil, "closed native identity refusal"
						end
						return native_lstat(target)
					end
					local written
					written, _, receipt = adapter.write_if_unchanged(path, "must not write through unknown owner", { status = "absent" }, function() end)
					io.open = original_open
					helpers.assert_eq(written, false)
					helpers.assert_eq(writes, 0, "missing initial identity must refuse before user bytes")
					helpers.assert_eq(type(receipt), "table")
					helpers.assert_eq(receipt.is_settled(), false, "an absent path cannot retire a retained actual allocation")
					helpers.assert_true(fixture.HOST_ATTRIBUTES(backup) ~= nil)
					helpers.assert_true(fixture.HOST_ATTRIBUTES(directory) ~= nil)
					helpers.assert_eq(receipt.retry(), false)
					helpers.assert_eq(adapter.write(path, "successor"), false)
					assert(original_rename(backup, payload)); hidden = false
					helpers.assert_eq(receipt.retry(), false, "a retry must not learn a previously unavailable payload identity")
					helpers.assert_eq(receipt.is_settled(), false)
					helpers.assert_true(fixture.HOST_ATTRIBUTES(payload) ~= nil)
					helpers.assert_true(fixture.HOST_ATTRIBUTES(directory) ~= nil)
				end, debug.traceback)
				io.open, hs.fs.symlinkAttributes = original_open, native_lstat
				if opened then pcall(function() return opened:close() end) end
				-- The capability intentionally cannot invent its missing original receipt.
				-- Only this fixture's independently known allocations are reclaimed here.
				original_remove(backup)
				if payload then original_remove(payload) end
				if directory then fixture.HOST_RMDIR(directory) end
				original_remove(path); original_remove(path .. fixture.WRITE_LOCK_SUFFIX)
				if not ok then error(failure, 0) end
			end)
		end)
	end
end)
