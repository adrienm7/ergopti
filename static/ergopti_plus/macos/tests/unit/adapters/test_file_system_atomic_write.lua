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

	helpers.it("write() publishes when macOS re-stamps its own provenance attribute", function()
		for _, case in ipairs({
			{ label = "a destination stamped by another app", destination = "01-previous-writer" },
			{ label = "a destination with no provenance yet", destination = nil },
		}) do
			with_fixture(function(fixture)
				local path = os.tmpname():gsub("\\", "/")
				local original = assert(io.open(path, "w"))
				assert(original:write("old settings")); assert(original:close())
				local metadata = {
					records = {
						[path] = {
							permissions = "rw-------",
							uid = 501,
							gid = 20,
							dev = 7,
							ino = 31,
							acl = "",
							xattrs = {
								["com.apple.provenance"] = case.destination,
								["user.ergopti"] = "must-survive",
							},
						},
					},
					default = { permissions = "rw-r--r--", uid = 501, gid = 20, acl = "", xattrs = {} },
					-- The kernel stamps the writing app's provenance on the staged
					-- inode; no copy can carry the destination's value over.
					after_copy = function(staged)
						staged.xattrs["com.apple.provenance"] = "02-ergoptiplus"
						staged.xattrs["com.apple.macl"] = "tcc-label"
					end,
				}
				local adapter = fixture.make_adapter(nil, nil, nil, nil, nil, nil, nil, metadata)
				local call_ok, write_ok = xpcall(function()
					return adapter.write(path, "new settings")
				end, debug.traceback)
				if not call_ok then
					os.remove(path)
					error(write_ok, 0)
				end

				helpers.assert_true(write_ok, case.label .. ": an OS-owned attribute must not block publication")
				local published = assert(io.open(path, "r"))
				helpers.assert_eq(published:read("*a"), "new settings", case.label)
				published:close()
				os.remove(path)
			end)
		end
	end)

	helpers.it("write() still refuses a changed attribute the OS does not own", function()
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
						ino = 41,
						acl = "",
						xattrs = { ["com.apple.provenance"] = "01-previous-writer", ["user.ergopti"] = "must-survive" },
					},
				},
				default = { permissions = "rw-r--r--", uid = 501, gid = 20, acl = "", xattrs = {} },
				after_copy = function(staged)
					staged.xattrs["com.apple.provenance"] = "02-ergoptiplus"
					staged.xattrs["user.ergopti"] = "lost"
				end,
			}
			local adapter = fixture.make_adapter(nil, nil, nil, nil, nil, nil, nil, metadata)
			local call_ok, write_ok = xpcall(function()
				return adapter.write(path, "must not publish")
			end, debug.traceback)
			if not call_ok then
				os.remove(path)
				error(write_ok, 0)
			end

			helpers.assert_eq(write_ok, false, "a user attribute that changed must still fail closed")
			local live = assert(io.open(path, "r"))
			helpers.assert_eq(live:read("*a"), "authoritative bytes")
			live:close()
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

local noop_file = assert(io.open(helpers.shared("tests/corpus/config_noop/vectors.json"), "rb"))
local noop_fixture = assert(require("json").decode(noop_file:read("*a")))
noop_file:close()

helpers.describe("FileSystem native no-op publication parity", function()
	for _, vector in ipairs(noop_fixture.cases) do
		helpers.it("native-toml-noop-parity " .. vector.id, function()
			with_fixture(function(fixture)
				local path = os.tmpname():gsub("\\", "/")
				local seed = assert(io.open(path, "w"))
				assert(seed:write(vector.input))
				assert(seed:close())
				-- The fixture simulates cp -p rather than spawning macOS cp. Carry
				-- the real source metadata into that simulation: tmpname is 0600,
				-- while a newly opened staging file follows the runner's umask.
				local metadata = { records = { [path] = fixture.HOST_ATTRIBUTES(path) } }
				local held, locks, unlocks, stages, publications = false, 0, 0, 0, 0
				local adapter = fixture.make_adapter(nil, nil, nil, nil,
					function() locks, held = locks + 1, true; return true end,
					function() unlocks, held = unlocks + 1, false; return true end, nil, metadata)
				local original_read = adapter.read_with_status
				local original_open, original_rename = io.open, os.rename
				local prepared, detail, candidate, source = require("toml_codec.writer").prepare_batch(path, {
					{ section = vector.section, key = vector.key, value = vector.value, delete = vector.delete },
				}, adapter)
				helpers.assert_eq(prepared, true, detail)
				adapter.read_with_status = function(target)
					helpers.assert_eq(held, true, "an unchanged acknowledgement must retain the native lock")
					return original_read(target)
				end
				io.open = function(target, mode)
					if mode == "w" and target:find(fixture.STAGING_LOCK_SUFFIX .. "/payload", 1, true) then
						stages = stages + 1
					end
					return original_open(target, mode)
				end
				os.rename = function(from, target)
					if target == path then publications = publications + 1 end
					return original_rename(from, target)
				end
				local ran, committed, commit_detail = xpcall(function()
					return adapter.write_if_unchanged(path, candidate, source)
				end, debug.traceback)
				io.open, os.rename = original_open, original_rename
				local live = assert(io.open(path, "r"))
				local actual = live:read("*a")
				assert(live:close())
				os.remove(path)
				os.remove(path .. fixture.WRITE_LOCK_SUFFIX)
				if not ran then error(committed, 0) end
				helpers.assert_eq(committed, true, commit_detail)
				helpers.assert_eq(actual, candidate)
				helpers.assert_eq(locks, 1)
				helpers.assert_eq(unlocks, 1)
				helpers.assert_eq(held, false)
				helpers.assert_eq(stages, vector.writes)
				helpers.assert_eq(publications, vector.writes)
			end)
		end)
	end
end)

helpers.describe("FileSystem no-op retains its native source fence", function()
	helpers.it("native-toml-noop-parity an owned sibling refuses even identical bytes", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local handle = assert(io.open(path, "w"))
			assert(handle:write("same bytes"))
			assert(handle:close())
			local adapter = fixture.make_adapter()
			local group, acquired = adapter.acquire_write_locks({ path })
			helpers.assert_eq(acquired, true)
			local committed = adapter.write_if_unchanged(path, "same bytes", { status = "ok", content = "same bytes" })
			local released = adapter.release_write_locks(group)
			os.remove(path)
			os.remove(path .. fixture.WRITE_LOCK_SUFFIX)
			helpers.assert_eq(committed, false, "a no-op may not bypass the exact existing writer owner")
			helpers.assert_eq(released, true)
		end)
	end)

	helpers.it("native-toml-noop-parity a source changed during lock acquisition is refused", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local handle = assert(io.open(path, "w"))
			assert(handle:write("same bytes"))
			assert(handle:close())
			local adapter, staging = fixture.make_adapter(nil, nil, nil, nil, function()
				local foreign = assert(io.open(path, "w"))
				assert(foreign:write("foreign bytes"))
				assert(foreign:close())
				return true
			end)
			local committed = adapter.write_if_unchanged(path, "same bytes", { status = "ok", content = "same bytes" })
			local live = assert(io.open(path, "r"))
			local content = live:read("*a")
			assert(live:close())
			os.remove(path)
			os.remove(path .. fixture.WRITE_LOCK_SUFFIX)
			helpers.assert_eq(committed, false)
			helpers.assert_eq(content, "foreign bytes")
			helpers.assert_eq(next(staging), nil)
		end)
	end)
end)

--- Native filesystem primitives are modeled; host bytes and inodes are real.
helpers.describe("private unchanged publication issuer", function()
	helpers.it("issues an exact immutable unchanged receipt without staging or rename", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local handle = assert(io.open(path, "wb")); assert(handle:write("complete")); assert(handle:close())
			local before = fixture.HOST_ATTRIBUTES(path)
			local held, locks, unlocks = false, 0, 0
			local adapter, staging = fixture.make_adapter(nil, nil, nil, nil,
				function() locks, held = locks + 1, true; return true end,
				function() unlocks, held = unlocks + 1, false; return true end)
			local original_read = adapter.read_with_status
			adapter.read_with_status = function(target, diagnostic)
				helpers.assert_eq(held, true, "the no-op observation must own its native writer lock")
				return original_read(target, diagnostic)
			end
			local reporter = function() end
			local expected = { status = "ok", content = "complete" }
			local written, detail, receipt = adapter.write_if_unchanged(path, "complete", expected, reporter)
			adapter.read_with_status = original_read
			local after = fixture.HOST_ATTRIBUTES(path)
			os.remove(path); os.remove(path .. fixture.WRITE_LOCK_SUFFIX)
			helpers.assert_eq(written, true, detail)
			helpers.assert_eq(type(receipt), "table", "a private no-op needs its actual issuer receipt")
			helpers.assert_eq(adapter.publication_receipt_view(receipt, path, expected, "complete", reporter),
				{ published = false, unchanged = true, source = { status = "ok", content = "complete" } })
			helpers.assert_eq(receipt.is_settled(), true)
			helpers.assert_eq(adapter.publication_receipt_view({}, path, expected, "complete", reporter), nil)
			helpers.assert_eq(adapter.publication_receipt_view(receipt, path, expected, "wrong", reporter), nil)
			helpers.assert_eq(adapter.publication_receipt_view(receipt, path, {status="ok",content="wrong"}, "complete", reporter), nil)
			helpers.assert_eq(adapter.publication_receipt_view(receipt, path, expected, "complete", function() end), nil)
			local mutation_called, mutation_error = pcall(function() receipt.unchanged = true end)
			helpers.assert_eq(mutation_called, false)
			helpers.assert_eq(type(mutation_error), "string")
			helpers.assert_eq(mutation_error:match("native publication capabilities are immutable$"),
				"native publication capabilities are immutable")
			helpers.assert_eq(before.dev, after.dev); helpers.assert_eq(before.ino, after.ino)
			helpers.assert_eq(before.permissions, after.permissions)
			helpers.assert_eq(locks, 1); helpers.assert_eq(unlocks, 1); helpers.assert_eq(held, false)
			helpers.assert_eq(next(staging), nil)
		end)
	end)

	helpers.it("retains the no-op issuer lock debt until its exact native release succeeds", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local handle = assert(io.open(path, "wb")); assert(handle:write("complete")); assert(handle:close())
			local releases = 0
			local adapter = fixture.make_adapter(nil, nil, nil, nil, nil,
				function() releases = releases + 1; return releases > 1 end)
			local reporter = function() end
			local expected = {status="ok",content="complete"}
			local original_open = io.open
			io.open = function(target, mode)
				local handle, detail = original_open(target, mode)
				if not handle or target ~= path .. fixture.WRITE_LOCK_SUFFIX then return handle, detail end
				return {
					close = function()
						if releases <= 1 then return false, "modeled retained native descriptor" end
						return handle:close()
					end,
				}
			end
			local written, _, receipt = adapter.write_if_unchanged(path, "complete", expected, reporter)
			io.open = original_open
			helpers.assert_eq(written, false, "pending lock release is no publication acknowledgement")
			helpers.assert_eq(type(receipt), "table")
			helpers.assert_eq(receipt.is_settled(), false)
			helpers.assert_eq(adapter.publication_receipt_view(receipt, path, expected, "complete", reporter).unchanged, true)
			helpers.assert_eq(receipt.matches_source(), true)
			helpers.assert_eq(receipt.retry(), true)
			helpers.assert_eq(receipt.is_settled(), true); helpers.assert_eq(releases, 2)
			os.remove(path); os.remove(path .. fixture.WRITE_LOCK_SUFFIX)
		end)
	end)

	helpers.it("a same-byte successor inode cannot inherit the no-op issuer source", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local handle = assert(io.open(path, "wb")); assert(handle:write("complete")); assert(handle:close())
			local adapter = fixture.make_adapter()
			local written, _, receipt = adapter.write_if_unchanged(path, "complete", {status="ok",content="complete"}, function() end)
			helpers.assert_eq(written, true); helpers.assert_eq(type(receipt), "table")
			helpers.assert_eq(receipt.matches_source(), true)
			local replacement = os.tmpname():gsub("\\", "/")
			local next_handle = assert(io.open(replacement, "wb")); assert(next_handle:write("complete")); assert(next_handle:close())
			assert(os.rename(replacement, path))
			helpers.assert_eq(receipt.matches_source(), false, "equal bytes do not grant a successor inode authority")
			os.remove(path); os.remove(path .. fixture.WRITE_LOCK_SUFFIX)
		end)
	end)

	helpers.it("the actual adapter acknowledges an initial publish followed by the same complete document", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/"); os.remove(path)
			local adapter = fixture.make_adapter()
			local owner, token, active, stopped = {}, {}, true, false
			local source = {
				identity = function(who) if rawequal(who, owner) then return token end end,
				current = function(who, which) return rawequal(who, owner) and rawequal(which, token) and active end,
				route = function(who, which) if rawequal(who, owner) and rawequal(which, token) then return path end end,
				detach = function(who, which)
					if rawequal(who, owner) and rawequal(which, token) then active, stopped = false, true; return true end
					return false
				end,
				retired = function(who, which) return rawequal(who, owner) and rawequal(which, token) and stopped end,
			}
			local ports = {
				build = function(input) return input end,
				encode = function(input) return input.bytes end,
				prepare = function() return true end,
				read = function(target)
					local bytes, status = adapter.read_with_status(target)
					return {status=status,content=bytes}
				end,
				write = adapter.write_if_unchanged,
				receipt_view = adapter.publication_receipt_view,
				on_error = function() end,
			}
			local publisher = assert(require("remap.owned_configuration_publication").new(owner, source, ports))
			local first, first_reason = publisher.publish(owner, token, {bytes="complete independent document"})
			local second, second_reason = publisher.publish(owner, token, {bytes="complete independent document"})
			local detached, retired = publisher.detach(owner, token), publisher.retired(owner, token)
			local bytes = adapter.read(path)
			os.remove(path); os.remove(path .. fixture.WRITE_LOCK_SUFFIX)
			helpers.assert_eq(first, true, first_reason)
			helpers.assert_eq(second, true, second_reason)
			helpers.assert_eq(detached, true); helpers.assert_eq(retired, true)
			helpers.assert_eq(bytes, "complete independent document")
		end)
	end)
end)

helpers.describe("final native issuer source admission", function()
	for _, interference in ipairs({ false, true }) do
		helpers.it("rechecks the original issuer after final readback, replacement=" .. tostring(interference), function()
			with_fixture(function(f)
  local path=os.tmpname()
  local seed=assert(io.open(path,'wb')); assert(seed:write('complete')); assert(seed:close())
  -- Hold the original real inode open through both genuine cooperative replacements.
  local held=assert(io.open(path,'rb'))
  local original=assert(f.HOST_ATTRIBUTES(path))
  local adapter=f.make_adapter()
  local owner,token={},{}
  local active,stopped=true,false
  local source={}
  function source.identity(o) if rawequal(o,owner) then return token end end
  function source.current(o,t) return rawequal(o,owner) and rawequal(t,token) and active end
  function source.route(o,t) if rawequal(o,owner) and rawequal(t,token) then return path end end
  function source.detach(o,t) if rawequal(o,owner) and rawequal(t,token) then active,stopped=false,true; return true end end
  function source.retired(o,t) return rawequal(o,owner) and rawequal(t,token) and stopped end
  local reads,receipt,first_write,second_write=0,nil,nil,nil
  local ports={}
  function ports.build(input) return input end
  function ports.encode(input) return input.bytes end
  function ports.prepare() return true end
  function ports.read(target)
    reads=reads+1
    if interference and reads==2 then
      first_write=adapter.write(target,'temporary different complete document')
      assert(first_write==true,'First genuine cooperative write must complete')
      second_write=adapter.write(target,'complete')
      assert(second_write==true,'Second genuine cooperative write must complete')
    end
    local bytes,status=adapter.read_with_status(target)
    return {status=status,content=bytes}
  end
  function ports.write(target,bytes,expected,diagnostic)
    local accepted,detail,native=adapter.write_if_unchanged(target,bytes,expected,diagnostic)
    receipt=native
    return accepted,detail,native
  end
  ports.receipt_view=adapter.publication_receipt_view
  function ports.on_error() end
  local publisher=assert(require('remap.owned_configuration_publication').new(owner,source,ports))
  local accepted,reason=publisher.publish(owner,token,{bytes='complete'})
  local final=assert(f.HOST_ATTRIBUTES(path))
  local receipt_current=type(receipt)=='table' and receipt.matches_source()==true
  local bytes=assert(io.open(path,'rb')); local content=bytes:read('*a'); assert(bytes:close())
  print('OBSERVATION '..tostring(accepted)..' '..tostring(reason)..' '..tostring(receipt_current)..' '..tostring(original.ino)..' '..tostring(final.ino)..' '..tostring(reads)..' '..tostring(first_write)..' '..tostring(second_write))
  assert(held:close()); assert(os.remove(path))
  os.remove(path..f.WRITE_LOCK_SUFFIX)
  assert(content=='complete','Final genuine bytes must equal desired bytes')
  assert(reads==2,'Final readback port must actually run')
  if interference then
    assert(original.ino~=final.ino,'Held original inode must differ from genuine replacement inode')
    assert(receipt_current==false,'Actual issuer must detect the original source is no longer current')
    assert(accepted==false,'Final no-op admission must refuse an observably replaced issuer source')
  else
    assert(original.ino==final.ino and receipt_current==true,'Healthy original no-op receipt must remain current')
    assert(accepted==true,'Healthy exact no-op must remain accepted')
  end
			end)
		end)
	end
end)


helpers.describe("adapters.file_system: final logical publication admission", function()
	local with_fixture = require("tests.support.file_system_transaction_fixture").with_fixture
	for _, unchanged in ipairs({ false, true }) do
		local no_op = unchanged
		for _, result in ipairs({ "true", "false", "nil", "truthy", "throw" }) do
			local mode = result
			helpers.it("checks " .. mode .. " admission after the final source read, unchanged=" .. tostring(no_op), function()
				with_fixture(function(fixture)
					local path = os.tmpname()
					local file = assert(io.open(path, "wb")); assert(file:write("original")); assert(file:close())
					local adapter = fixture.make_adapter()
					local read, rename = adapter.read_with_status, os.rename
					local reads, admitted_after, admissions, replacements = 0, 0, 0, 0
					adapter.read_with_status = function(...)
						local content, status, detail = read(...)
						reads = reads + 1
						return content, status, detail
					end
					os.rename = function(...)
						replacements = replacements + 1
						return rename(...)
					end
					local called, written, detail = pcall(adapter.write_if_unchanged_admitted,
						path, no_op and "original" or "changed", { status = "ok", content = "original" }, nil,
						function()
							admissions, admitted_after = admissions + 1, reads
							if mode == "throw" then error("controlled logical refusal") end
							if mode == "true" then return true end
							if mode == "false" then return false end
							if mode == "truthy" then return {} end
						end)
					os.rename, adapter.read_with_status = rename, read
					local handle = assert(io.open(path, "rb"))
					local actual = assert(handle:read("*a")); assert(handle:close())
					os.remove(path); os.remove(path .. fixture.WRITE_LOCK_SUFFIX)
					helpers.assert_eq(called, true)
					helpers.assert_eq(written, mode == "true", tostring(detail))
					helpers.assert_eq(admissions, 1)
					helpers.assert_true(reads > 0)
					helpers.assert_eq(admitted_after, reads, "no logical/source reader follows final admission")
					helpers.assert_eq(replacements, mode == "true" and not no_op and 1 or 0)
					helpers.assert_eq(actual, mode == "true" and not no_op and "changed" or "original")
				end)
			end)
		end
	end
end)


helpers.describe("FileSystem admitted publication captures exact source before callbacks", function()
	local with_fixture = require("tests.support.file_system_transaction_fixture").with_fixture
	for _, unchanged in ipairs({ false, true }) do
		local no_op = unchanged
		helpers.it("refuses a mutated caller precondition and keeps the genuine external image, unchanged=" .. tostring(no_op), function()
			with_fixture(function(fixture)
				local path = os.tmpname()
				local function put(content)
					local file = assert(io.open(path, "wb")); assert(file:write(content)); assert(file:close())
				end
				put("original")
				local adapter = fixture.make_adapter()
				local read, rename = adapter.read_with_status, os.rename
				local expected = { status = "ok", content = "original" }
				local observed, reads, replacements, admissions = false, 0, 0, 0
				adapter.read_with_status = function(...)
					reads = reads + 1
					if not observed then
						observed = true
						put("external-successor")
						expected.content = "external-successor"
					end
					return read(...)
				end
				os.rename = function(...) replacements = replacements + 1; return rename(...) end
				local called, written = pcall(adapter.write_if_unchanged_admitted,
					path, no_op and "original" or "candidate", expected, nil,
					function() admissions = admissions + 1; return true end)
				os.rename, adapter.read_with_status = rename, read
				local file = assert(io.open(path, "rb"))
				local actual = assert(file:read("*a")); assert(file:close())
				os.remove(path); os.remove(path .. fixture.WRITE_LOCK_SUFFIX)
				helpers.assert_eq(called, true)
				helpers.assert_eq(written, false)
				helpers.assert_eq(actual, "external-successor")
				helpers.assert_true(reads > 0)
				helpers.assert_eq(replacements, 0)
				helpers.assert_eq(admissions, 0, "source drift is rejected before logical admission")
			end)
		end)
	end
end)


helpers.describe("FileSystem admitted source requires raw plain classified scalars", function()
	local with_fixture = require("tests.support.file_system_transaction_fixture").with_fixture
	helpers.it("rejects malformed and inherited source fields before any native reader or admission", function()
		with_fixture(function(fixture)
			local path = os.tmpname()
			local handle = assert(io.open(path, "wb")); assert(handle:write("owned")); assert(handle:close())
			local adapter = fixture.make_adapter()
			local effects, reads, admissions = 0, 0, 0
			local read = adapter.read_with_status
			adapter.read_with_status = function(...) reads = reads + 1; return read(...) end
			local inherited = setmetatable({}, { __index = function()
				effects = effects + 1; return "owned"
			end, __eq = function() effects = effects + 1; return true end })
			local shapes = { false, {}, { status = "ok", content = 1 }, { status = false, content = "owned" },
				{ status = "OK", content = "owned" }, { status = "absent", content = "owned" }, inherited,
				setmetatable({ status = "ok", content = "owned" }, { __eq = function() effects = effects + 1; return true end }) }
			for _, expected in ipairs(shapes) do
				local pub_called, written = pcall(adapter.write_if_unchanged_admitted,
					path, "candidate", expected, nil, function() admissions = admissions + 1; return true end)
				local remove_called, removed = pcall(adapter.remove_if_unchanged_admitted,
					path, expected, nil, function() admissions = admissions + 1; return true end)
				helpers.assert_eq(pub_called, true)
				helpers.assert_eq(written, false)
				helpers.assert_eq(remove_called, true)
				helpers.assert_eq(removed, false)
			end
			adapter.read_with_status = read
			local file = assert(io.open(path, "rb"))
			local actual = assert(file:read("*a")); assert(file:close())
			os.remove(path)
			helpers.assert_eq(actual, "owned")
			helpers.assert_eq(reads, 0)
			helpers.assert_eq(effects, 0)
			helpers.assert_eq(admissions, 0)
		end)
	end)
end)


helpers.describe("FileSystem final logical removal admission", function()
	for _, result in ipairs({ "true", "false", "nil", "truthy", "throw" }) do
		local mode = result
		helpers.it("conditional-remove admits only literal true after its final native read: " .. mode, function()
			with_fixture(function(fixture)
				local path = os.tmpname()
				local handle = assert(io.open(path, "wb")); assert(handle:write("owned")); assert(handle:close())
				local adapter = fixture.make_adapter()
				local read, remove = adapter.read_with_status, os.remove
				local reads, admission_read, admissions, unlinks = 0, 0, 0, 0
				adapter.read_with_status = function(...)
					local content, status, detail = read(...)
					reads = reads + 1
					return content, status, detail
				end
				os.remove = function(target)
					if target == path then
						unlinks = unlinks + 1
						helpers.assert_eq(admission_read, reads, "no reader intervenes between final admission and unlink")
					end
					return remove(target)
				end
				local called, removed, detail, receipt = pcall(adapter.remove_if_unchanged_admitted,
					path, { status = "ok", content = "owned" }, nil, function()
						admissions, admission_read = admissions + 1, reads
						if mode == "throw" then error("controlled removal refusal") end
						if mode == "true" then return true end
						if mode == "false" then return false end
						if mode == "truthy" then return {} end
					end)
				os.remove, adapter.read_with_status = remove, read
				local actual, status = adapter.read_with_status(path)
				remove(path); remove(path .. fixture.WRITE_LOCK_SUFFIX)
				helpers.assert_eq(called, true)
				helpers.assert_eq(removed, mode == "true", tostring(detail))
				helpers.assert_eq(admissions, 1)
				helpers.assert_true(admission_read > 0)
				helpers.assert_eq(unlinks, mode == "true" and 1 or 0)
				helpers.assert_eq(status, mode == "true" and "absent" or "ok")
				if mode == "true" then helpers.assert_nil(actual) else helpers.assert_eq(actual, "owned") end
				helpers.assert_eq(receipt.is_settled(), true)
			end)
		end)
	end
end)


helpers.describe("FileSystem admitted removal retains release ownership", function()
	for _, permitted in ipairs({ false, true }) do
		local accepted = permitted
		helpers.it("settles release-only cleanup without readmission or repeat unlink, accepted=" .. tostring(accepted), function()
			with_fixture(function(fixture)
				local path = os.tmpname()
				local file = assert(io.open(path, "wb")); assert(file:write("owned")); assert(file:close())
				local release_refused, allowed, admissions, unlinks = true, accepted, 0, 0
				local adapter = fixture.make_adapter(nil, nil, nil, nil, nil, function() return not release_refused end)
				local remove, open = os.remove, io.open
				io.open = function(target, mode)
					local handle, detail = open(target, mode)
					if target ~= path .. fixture.WRITE_LOCK_SUFFIX or mode ~= "a+" then return handle, detail end
					return { close = function() if release_refused then return false end; return handle:close() end }
				end
				os.remove = function(target)
					if target == path then unlinks = unlinks + 1 end
					return remove(target)
				end
				local called, removed, detail, receipt, cleanup = pcall(adapter.remove_if_unchanged_admitted,
					path, { status = "ok", content = "owned" }, nil, function()
						admissions = admissions + 1
						return allowed
					end)
				os.remove, io.open = remove, open
				local actual, status = adapter.read_with_status(path)
				allowed, release_refused = false, false
				local cleaned = cleanup()
				local cleaned_again = cleanup()
				remove(path); remove(path .. fixture.WRITE_LOCK_SUFFIX)
				helpers.assert_eq(called, true, tostring(detail))
				helpers.assert_eq(removed, false)
				helpers.assert_eq(receipt.removed, accepted)
				helpers.assert_eq(unlinks, accepted and 1 or 0)
				helpers.assert_eq(status, accepted and "absent" or "ok")
				if accepted then helpers.assert_nil(actual) else helpers.assert_eq(actual, "owned") end
				helpers.assert_eq(cleaned, true)
				helpers.assert_eq(cleaned_again, true)
				helpers.assert_eq(receipt.is_settled(), true)
				helpers.assert_eq(admissions, 1, "release-only cleanup does not repeat logical admission")
			end)
		end)
	end
end)


helpers.describe("FileSystem admitted removal captures exact source before callbacks", function()
	helpers.it("refuses mutated expected bytes and never unlinks the genuine external source", function()
		with_fixture(function(fixture)
			local path = os.tmpname()
			local function put(content)
				local file = assert(io.open(path, "wb")); assert(file:write(content)); assert(file:close())
			end
			put("owned")
			local adapter = fixture.make_adapter()
			local read, remove = adapter.read_with_status, os.remove
			local expected = { status = "ok", content = "owned" }
			local observed, admissions, unlinks = false, 0, 0
			adapter.read_with_status = function(...)
				if not observed then
					observed = true; put("external-successor"); expected.content = "external-successor"
				end
				return read(...)
			end
			os.remove = function(target)
				if target == path then unlinks = unlinks + 1 end
				return remove(target)
			end
			local called, removed = pcall(adapter.remove_if_unchanged_admitted,
				path, expected, nil, function() admissions = admissions + 1; return true end)
			os.remove, adapter.read_with_status = remove, read
			local file = assert(io.open(path, "rb"))
			local actual = assert(file:read("*a")); assert(file:close())
			remove(path); remove(path .. fixture.WRITE_LOCK_SUFFIX)
			helpers.assert_eq(called, true)
			helpers.assert_eq(removed, false)
			helpers.assert_eq(actual, "external-successor")
			helpers.assert_eq(unlinks, 0)
			helpers.assert_eq(admissions, 0)
		end)
	end)
end)


helpers.describe("FileSystem initializer configuration identities", function()
	local fields = { "read_with_status", "write_if_unchanged", "write_if_unchanged_admitted",
		"remove_if_unchanged", "remove_if_unchanged_admitted", "remove_exact", "delete" }
	local function exercise(body)
		with_fixture(function(fixture) body(fixture.make_adapter()) end)
	end
	helpers.it("returns genuine native identities without IO or invoking any native method", function()
		exercise(function(adapter)
			local open, remove, calls = io.open, os.remove, 0
			local function unexpected() calls = calls + 1; error("identity lookup invoked IO") end
			io.open, os.remove = unexpected, unexpected
			local called, owner, reader, writer, publisher, remover, admitted, exact, delete =
				pcall(adapter.configuration_ports)
			io.open, os.remove = open, remove
			helpers.assert_true(called)
			helpers.assert_true(rawequal(owner, adapter))
			local actual = { reader, writer, publisher, remover, admitted, exact, delete }
			for index, field in ipairs(fields) do
				helpers.assert_true(rawequal(actual[index], rawget(adapter, field)), field)
			end
			helpers.assert_eq(calls, 0)
		end)
	end)
	for index, field in ipairs(fields) do
		helpers.it("retains initializer identity after public export replacement: " .. field, function()
			exercise(function(adapter)
				local original = rawget(adapter, field)
				local calls = 0
				local function fake() calls = calls + 1; return true end
				rawset(adapter, field, fake)
				local called, owner, reader, writer, publisher, remover, admitted, exact, delete =
					pcall(adapter.configuration_ports)
				rawset(adapter, field, original)
				local actual = { reader, writer, publisher, remover, admitted, exact, delete }
				helpers.assert_true(called)
				helpers.assert_true(rawequal(owner, adapter))
				helpers.assert_true(rawequal(actual[index], original), "the receipt retains original absence or method")
				helpers.assert_eq(rawequal(actual[index], fake), false)
				helpers.assert_eq(calls, 0)
			end)
		end)
	end

	helpers.it("a borrowed getter retains the actual initializer owner, never a copied receiver", function()
		exercise(function(adapter)
			local getter = rawget(adapter, "configuration_ports")
			local copy = setmetatable({ configuration_ports = getter }, { __eq = function() return true end })
			local owner = copy.configuration_ports(copy)
			helpers.assert_true(rawequal(owner, adapter))
			helpers.assert_eq(rawequal(owner, copy), false)
		end)
	end)
	helpers.it("returned identities are independent scalar values, not a mutable authority table", function()
		exercise(function(adapter)
			local owner, reader = adapter.configuration_ports()
			owner, reader = {}, function() error("mutated result must not be invoked") end
			local current_owner, current_reader = adapter.configuration_ports()
			helpers.assert_true(rawequal(current_owner, adapter))
			helpers.assert_true(rawequal(current_reader, rawget(adapter, "read_with_status")))
			helpers.assert_eq(rawequal(current_owner, owner), false)
			helpers.assert_eq(rawequal(current_reader, reader), false)
		end)
	end)
	helpers.it("raw issuer withdrawal is distinguishable from an accessor fallback", function()
		exercise(function(adapter)
			local getter, previous = rawget(adapter, "configuration_ports"), getmetatable(adapter)
			local reached = 0
			rawset(adapter, "configuration_ports", nil)
			setmetatable(adapter, { __index = function(_, key)
				if key == "configuration_ports" then reached = reached + 1; return getter end
			end })
			local issuer = rawget(adapter, "configuration_ports")
			setmetatable(adapter, previous); rawset(adapter, "configuration_ports", getter)
			helpers.assert_nil(issuer)
			helpers.assert_eq(reached, 0)
		end)
	end)
end)
