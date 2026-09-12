--- tests/unit/adapters/test_file_system_atomic_write.lua

--- ==============================================================================
--- MODULE: FileSystem Atomic Write Regression
--- DESCRIPTION:
--- Preserves the filesystem transaction contract at its owning boundary.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.file_system_transaction_fixture").with_fixture

helpers.describe("adapters.file_system: write() is atomic (F-MED-16)", function()
	local TMP = os.tmpname()

	helpers.it("revalidates an expected source after staging and before rename", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local seed = assert(io.open(path, "w"))
			assert(seed:write("observed source"))
			assert(seed:close())
			local adapter = fixture.make_adapter()
			local original_open = io.open
			local original_rename = os.rename
			local renames = 0
			local foreign_edit_committed = false

			io.open = function(open_path, mode)
				local fh, open_err = original_open(open_path, mode)
				if fh and mode == "w"
						and open_path:find(fixture.STAGING_LOCK_SUFFIX .. "/payload", 1, true) then
					return {
						write = function(_, value) return fh:write(value) end,
						close = function()
							local closed, close_err = fh:close()
							local foreign = assert(original_open(path, "w"))
							assert(foreign:write("foreign concurrent edit"))
							assert(foreign:close())
							foreign_edit_committed = true
							return closed, close_err
						end,
					}
				end
				return fh, open_err
			end
			os.rename = function(old_path, new_path)
				if new_path == path then renames = renames + 1 end
				return original_rename(old_path, new_path)
			end
			local call_ok, written = xpcall(function()
				return adapter.write_if_unchanged(path, "our candidate", {
					status = "ok",
					content = "observed source",
				})
			end, debug.traceback)
			io.open = original_open
			os.rename = original_rename
			if not call_ok then
				os.remove(path)
				error(written, 0)
			end

			helpers.assert_true(foreign_edit_committed,
				"the fixture must replace the observed source only after staging closes")
			helpers.assert_eq(written, false,
				"a changed source must fail its publication precondition")
			helpers.assert_eq(renames, 0,
				"the source precondition must be checked before atomic rename")
			local live = assert(original_open(path, "r"))
			helpers.assert_eq(live:read("*a"), "foreign concurrent edit",
				"the concurrent writer's complete bytes must survive")
			live:close()
			os.remove(path)
		end)
	end)

	helpers.it("write() produces a complete, readable file", function()
		with_fixture(function(fixture)
			local adapter = fixture.make_adapter()
			os.remove(TMP)
			local ok = adapter.write(TMP, "atomic content")
			helpers.assert_true(ok, "write() must return true on success")
			local fh = io.open(TMP, "r")
			helpers.assert_true(fh ~= nil, "file must exist after write()")
			local content = fh:read("*a"); fh:close()
			helpers.assert_eq(content, "atomic content")
			os.remove(TMP)
		end)
	end)

	helpers.it("write() removes its dynamic staging payload and lock after success", function()
		with_fixture(function(fixture)
			local adapter, staging_locks = fixture.make_adapter()
			os.remove(TMP)
			local original_open = io.open
			local staged_paths = {}
			io.open = function(path, mode)
				if mode == "w" and path ~= TMP then staged_paths[#staged_paths + 1] = path end
				return original_open(path, mode)
			end
			local call_ok, write_ok = pcall(adapter.write, TMP, "no leftovers")
			io.open = original_open
			if not call_ok then error(write_ok) end

			helpers.assert_true(write_ok, "the success-path cleanup repro must publish")
			helpers.assert_eq(#staged_paths, 1, "write() must open exactly one private staging payload")
			local staged_path = staged_paths[1]
			helpers.assert_true(
				staged_path:match("%.tmp%.[%w]+%.%d+%.ergoptiplus%-stage%-lock/payload$") ~= nil,
				"the observed payload must use the dynamic adjacent staging namespace")
			local staged_fh = original_open(staged_path, "r")
			helpers.assert_nil(staged_fh, "the dynamic staging payload must not survive publication")
			if staged_fh then staged_fh:close() end
			helpers.assert_nil(next(staging_locks), "the dynamic staging ownership lock must be released")
			os.remove(TMP)
		end)
	end)

	helpers.it("write() never unlinks the payload pathname after successful rename", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local adapter, staging_locks = fixture.make_adapter()
			local original_open = io.open
			local original_rename = os.rename
			local staged_payload = nil
			os.remove(path)

			os.rename = function(old_path, new_path)
				local renamed, rename_err, rename_code = original_rename(old_path, new_path)
				if renamed and old_path ~= new_path then
					staged_payload = old_path
					local foreign = assert(original_open(old_path, "w"))
					foreign:write("foreign post-rename bytes")
					foreign:close()
				end
				return renamed, rename_err, rename_code
			end
			local call_ok, write_ok = xpcall(function()
				return adapter.write(path, "published bytes")
			end, debug.traceback)
			os.rename = original_rename
			if not call_ok then error(write_ok) end

			helpers.assert_true(write_ok, "foreign bytes at the consumed source path do not undo publication")
			local foreign = staged_payload and original_open(staged_payload, "r") or nil
			helpers.assert_true(foreign ~= nil, "published-payload cleanup must never call os.remove on that pathname")
			local foreign_content = foreign and foreign:read("*a") or nil
			if foreign then foreign:close() end
			helpers.assert_eq(foreign_content, "foreign post-rename bytes")
			local lock_path = staged_payload and staged_payload:match("^(.*)/payload$") or nil
			helpers.assert_eq(staging_locks[lock_path], true,
				"a non-empty sidecar must remain owned when its payload pathname is reused")
			local published = original_open(path, "r")
			helpers.assert_true(published ~= nil, "the destination must contain the published file")
			local published_content = published and published:read("*a") or nil
			if published then published:close() end
			helpers.assert_eq(published_content, "published bytes")
			if staged_payload then os.remove(staged_payload) end
			if lock_path then fixture.HOST_RMDIR(lock_path) end
			os.remove(path)
		end)
	end)

	helpers.it("write() overwrites existing content atomically (old content never partially visible)", function()
		with_fixture(function(fixture)
			local adapter = fixture.make_adapter()
			os.remove(TMP)
			adapter.write(TMP, "first version — long enough to detect truncation if the write were not atomic")
			local original_rename = os.rename
			-- Lua on Windows does not implement POSIX rename-over-existing semantics.
			-- Model the target macOS primitive here; destructive failure behavior has
			-- its own regression test in test_file_system_staging_isolation.lua.
			os.rename = function(old_path, new_path)
				local renamed, rename_err, rename_code = original_rename(old_path, new_path)
				if old_path == new_path or renamed or package.config:sub(1, 1) ~= "\\" then
					return renamed, rename_err, rename_code
				end
				os.remove(new_path)
				return original_rename(old_path, new_path)
			end
			local call_ok, write_ok = pcall(adapter.write, TMP, "second version")
			os.rename = original_rename
			if not call_ok then error(write_ok) end
			helpers.assert_true(write_ok, "the macOS rename-over-existing model must publish the second version")
			local fh = io.open(TMP, "r")
			local content = fh:read("*a"); fh:close()
			helpers.assert_eq(content, "second version",
				"the file must contain exactly the new content, with no leftover bytes from the old version")
			os.remove(TMP)
		end)
	end)

	helpers.it("write() preserves restrictive mode, ownership, ACLs, and xattrs on replacement", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local original = assert(io.open(path, "w"))
			assert(original:write("private old bytes")); assert(original:close())
			local metadata = {
				records = {
					[path] = {
						permissions = "rw-------",
						uid = 501,
						gid = 20,
						dev = 7,
						ino = 11,
						acl = " 0: group:privacy allow read\n",
						xattrs = {
							["com.apple.quarantine"] = "0081;fixture",
							["user.ergopti"] = "private-metadata",
						},
					},
				},
				default = {
					permissions = "rw-r--r--",
					uid = 501,
					gid = 20,
					acl = "",
					xattrs = {},
				},
			}
			local adapter = fixture.make_adapter(nil, nil, nil, nil, nil, nil, nil, metadata)
			local original_rename = os.rename
			os.rename = function(old_path, new_path)
				local renamed, rename_err, rename_code = original_rename(old_path, new_path)
				if not renamed and package.config:sub(1, 1) == "\\" then
					os.remove(new_path)
					renamed, rename_err, rename_code = original_rename(old_path, new_path)
				end
				if renamed and old_path ~= new_path then
					metadata.records[new_path] = metadata.records[old_path] or metadata.default
					metadata.records[old_path] = nil
					metadata.records[new_path].ino = 12
				end
				return renamed, rename_err, rename_code
			end
			local call_ok, write_ok = xpcall(function()
				return adapter.write(path, "private new bytes")
			end, debug.traceback)
			os.rename = original_rename
			if not call_ok then
				os.remove(path)
				error(write_ok, 0)
			end

			helpers.assert_true(write_ok, "the metadata-preserving atomic replacement must publish")
			helpers.assert_eq(metadata.copy_calls, 1,
				"an existing destination must seed exactly one private staging inode")
			helpers.assert_eq(metadata.records[path].ino, 12,
				"the control must exercise inode replacement rather than an in-place write")
			helpers.assert_eq(metadata.records[path].permissions, "rw-------")
			helpers.assert_eq(metadata.records[path].uid, 501)
			helpers.assert_eq(metadata.records[path].gid, 20)
			helpers.assert_eq(metadata.records[path].acl, " 0: group:privacy allow read\n")
			helpers.assert_eq(metadata.records[path].xattrs["com.apple.quarantine"], "0081;fixture")
			helpers.assert_eq(metadata.records[path].xattrs["user.ergopti"], "private-metadata")
			local published = assert(io.open(path, "r"))
			helpers.assert_eq(published:read("*a"), "private new bytes")
			published:close()
			os.remove(path)
		end)
	end)

	helpers.it("write() refuses publication when the staged metadata copy is incomplete", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local original = assert(io.open(path, "w"))
			assert(original:write("authoritative bytes")); assert(original:close())
			local metadata = {
				records = {
					[path] = {
						permissions = "rw-------",
						uid = 501,
						gid = 20,
						dev = 7,
						ino = 21,
						acl = " 0: group:privacy allow read\n",
						xattrs = { ["user.ergopti"] = "must-survive" },
					},
				},
				default = { permissions = "rw-r--r--", uid = 501, gid = 20, acl = "", xattrs = {} },
				after_copy = function(staged)
					staged.acl = ""
					staged.xattrs = {}
				end,
			}
			local adapter = fixture.make_adapter(nil, nil, nil, nil, nil, nil, nil, metadata)
			local original_rename = os.rename
			local renames = 0
			os.rename = function(old_path, new_path)
				if old_path ~= new_path then renames = renames + 1 end
				return original_rename(old_path, new_path)
			end
			local call_ok, write_ok = xpcall(function()
				return adapter.write(path, "must not publish")
			end, debug.traceback)
			os.rename = original_rename
			if not call_ok then
				os.remove(path)
				error(write_ok, 0)
			end

			helpers.assert_eq(write_ok, false, "partial security metadata must fail closed")
			helpers.assert_eq(renames, 0, "metadata must be verified before atomic publication")
			helpers.assert_eq(metadata.records[path].acl, " 0: group:privacy allow read\n")
			helpers.assert_eq(metadata.records[path].xattrs["user.ergopti"], "must-survive")
			local live = assert(io.open(path, "r"))
			helpers.assert_eq(live:read("*a"), "authoritative bytes",
				"the old content and metadata owner must survive a partial copy")
			live:close()
			os.remove(path)
		end)
	end)

	helpers.it("write() surfaces mkdir refusal before lock or staging (hs-112)", function()
		with_fixture(function(fixture)
			local root = os.tmpname():gsub("\\", "/") .. "_write_denied_parent"
			local denied_parent = root .. "/private"
			local destination = denied_parent .. "/managed.json"
			local original_open = io.open
			local unsafe_open_calls = 0
			local lock_calls = 0
			local written, detail
			local call_ok, call_err = xpcall(function()
				os.remove(root)
				assert(fixture.HOST_MKDIR(root))
				local adapter = fixture.make_adapter(nil, nil, nil, nil, function()
					lock_calls = lock_calls + 1
					return true
				end, nil, function(path)
					if path == denied_parent then return nil, "Permission denied" end
					return fixture.HOST_MKDIR(path)
				end)
				io.open = function(path, mode)
					local spelling = tostring(path)
					if spelling:find(fixture.WRITE_LOCK_SUFFIX, 1, true) ~= nil
							or spelling:find(fixture.STAGING_LOCK_SUFFIX, 1, true) ~= nil then
						unsafe_open_calls = unsafe_open_calls + 1
					end
					return original_open(path, mode)
				end

				written, detail = adapter.write(destination, "private bytes")
				io.open = original_open

				helpers.assert_eq(written, false, "a refused parent directory must fail the write")
				helpers.assert_true(
					type(detail) == "string" and detail:find(denied_parent, 1, true) ~= nil,
					"the write error must identify the refused parent directory"
				)
				helpers.assert_true(
					detail:find("Permission denied", 1, true) ~= nil,
					"the exact mkdir refusal must remain visible"
				)
				helpers.assert_eq(unsafe_open_calls, 0,
					"a parent refusal must stop before opening a lock or staging payload")
				helpers.assert_eq(lock_calls, 0,
					"a parent refusal must stop before the native lock boundary")
				helpers.assert_nil(fixture.HOST_ATTRIBUTES(denied_parent))
				helpers.assert_nil(fixture.HOST_ATTRIBUTES(destination))
			end, debug.traceback)
			io.open = original_open
			os.remove(destination)
			fixture.HOST_RMDIR(denied_parent)
			fixture.HOST_RMDIR(root)
			if not call_ok then error(call_err, 0) end
		end)
	end)

	helpers.it("write() creates multiple missing parent levels under an existing ancestor", function()
		with_fixture(function(fixture)
			local ancestor = os.tmpname():gsub("\\", "/")
			os.remove(ancestor)
			assert(fixture.HOST_MKDIR(ancestor))
			local first_parent = ancestor .. "/missing-one"
			local second_parent = first_parent .. "/missing-two"
			local path = second_parent .. "/managed.json"
			local adapter = fixture.make_adapter()

			local write_ok = adapter.write(path, "complete nested bytes")

			helpers.assert_true(write_ok, "write() must retain its recursive parent-creation contract")
			local fh = io.open(path, "r")
			helpers.assert_true(fh ~= nil, "the nested destination must exist after a successful write")
			local content = fh and fh:read("*a") or nil
			if fh then fh:close() end
			helpers.assert_eq(content, "complete nested bytes", "the nested file must contain every byte")
			os.remove(path)
			fixture.HOST_RMDIR(second_parent)
			fixture.HOST_RMDIR(first_parent)
			fixture.HOST_RMDIR(ancestor)
		end)
	end)
end)
