--- tests/unit/adapters/file_system/test_cooperative_writer_lock.lua

--- ==============================================================================
--- MODULE: FileSystem Cooperative Writer Lock Regression
--- DESCRIPTION:
--- Preserves the filesystem transaction contract at its owning boundary.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.file_system_transaction_fixture").with_fixture

helpers.describe("adapters.file_system: cooperative writer lock", function()
	local function seed(path, content)
		local handle = assert(io.open(path, "w"))
		assert(handle:write(content))
		assert(handle:close())
	end

	local function read_all(path)
		local handle = assert(io.open(path, "r"))
		local content = handle:read("*a")
		handle:close()
		return content
	end

	local function dot_alias(fixture, path)
		local parent, basename = fixture.split_parent(path)
		return parent .. "/./" .. basename
	end

	helpers.it("rejects equivalent spellings before acquiring a native group lock", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local alias = dot_alias(fixture, path)
			local lock_path = path .. fixture.WRITE_LOCK_SUFFIX
			os.remove(lock_path)
			local lock_calls = 0
			local adapter = fixture.make_adapter(nil, nil, nil, nil, function()
				lock_calls = lock_calls + 1
				return true
			end)

			local group, committed, detail = adapter.acquire_write_locks({ path, alias })
			local release_ok = true
			if group ~= nil then release_ok = adapter.release_write_locks(group) end
			local lock_probe = io.open(lock_path, "r")
			local lock_created = lock_probe ~= nil
			if lock_probe then lock_probe:close() end
			os.remove(path)
			os.remove(lock_path)

			helpers.assert_nil(group,
				"equivalent spellings must be rejected before any lock capability is acquired")
			helpers.assert_eq(committed, false)
			helpers.assert_true(type(detail) == "string"
				and detail:find("cooperative write lock", 1, true) ~= nil,
				"the refusal must identify the shared logical lock")
			helpers.assert_eq(lock_calls, 0,
				"duplicate lock keys must be detected before the native lock boundary")
			helpers.assert_eq(lock_created, false,
				"duplicate lock keys must not even create the stable lock inode")
			helpers.assert_eq(release_ok, true,
				"the historical implementation's unexpected owner must remain cleanable")
		end)
	end)

	helpers.it("acquires distinct logical lock keys in deterministic order", function()
		with_fixture(function(fixture)
			local first = os.tmpname():gsub("\\", "/")
			local second = os.tmpname():gsub("\\", "/")
			local lock_calls = 0
			local adapter = fixture.make_adapter(nil, nil, nil, nil, function()
				lock_calls = lock_calls + 1
				return true
			end)

			local group, committed, detail = adapter.acquire_write_locks({ second, first })
			local released, release_err = adapter.release_write_locks(group)
			os.remove(first)
			os.remove(second)
			os.remove(first .. fixture.WRITE_LOCK_SUFFIX)
			os.remove(second .. fixture.WRITE_LOCK_SUFFIX)

			helpers.assert_true(group ~= nil, tostring(detail))
			helpers.assert_eq(committed, true)
			helpers.assert_eq(lock_calls, 2,
				"distinct destinations must retain independent native lock owners")
			helpers.assert_eq(released, true, tostring(release_err))
			helpers.assert_eq(group.routes[1].resolved < group.routes[2].resolved, true,
				"distinct logical lock keys must keep a deterministic acquisition order")
		end)
	end)

	helpers.it("blocks a nested writer that uses a dot-segment alias", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local alias = dot_alias(fixture, path)
			local lock_path = path .. fixture.WRITE_LOCK_SUFFIX
			os.remove(path)
			os.remove(lock_path)
			local lock_calls = 0
			local adapter = fixture.make_adapter(nil, nil, nil, nil, function()
				lock_calls = lock_calls + 1
				return true
			end)
			local original_rename = os.rename
			local inner_written, inner_err = nil, nil
			local in_publication = false
			os.rename = function(old_path, new_path)
				local is_publication = old_path ~= new_path
					and old_path:sub(-#"/payload") == "/payload"
				if is_publication and new_path == path and not in_publication then
					in_publication = true
					inner_written, inner_err = adapter.write(alias, "inner alias bytes")
					in_publication = false
				end
				if is_publication and (new_path == path or new_path == alias) then
					os.remove(path) -- model POSIX replacement on Windows
				end
				return original_rename(old_path, new_path)
			end

			local call_ok, outer_written = xpcall(function()
				return adapter.write(path, "outer authoritative bytes")
			end, debug.traceback)
			os.rename = original_rename
			local final_content = io.open(path, "r")
			if final_content then
				local handle = final_content
				final_content = handle:read("*a")
				handle:close()
			end
			os.remove(path)
			os.remove(lock_path)
			if not call_ok then error(outer_written, 0) end

			helpers.assert_eq(outer_written, true,
				"the original logical lock owner must finish publication")
			helpers.assert_eq(inner_written, false,
				"a lexical alias must not enter the same destination's publication boundary")
			helpers.assert_true(type(inner_err) == "string" and inner_err ~= "",
				"same-process alias contention must return a concrete refusal")
			helpers.assert_eq(lock_calls, 1,
				"equivalent spellings must share the same-process ownership key")
			helpers.assert_eq(final_content, "outer authoritative bytes")
		end)
	end)

	local function run_nested_competitor(fixture, use_unconditional_writer)
		local path = os.tmpname():gsub("\\", "/")
		local lock_path = path .. fixture.WRITE_LOCK_SUFFIX
		os.remove(path)
		os.remove(lock_path)
		seed(path, "v0")

		local owner = nil
		local lock_calls = { A = 0, B = 0 }
		local unlock_calls = { A = 0, B = 0 }
		local function lock_api(name)
			return function()
				lock_calls[name] = lock_calls[name] + 1
				if owner ~= nil then return nil, "injected busy lock" end
				owner = name
				return true
			end, function()
				unlock_calls[name] = unlock_calls[name] + 1
				if owner ~= name then return nil, "wrong injected owner" end
				owner = nil
				return true
			end
		end
		local lock_a, unlock_a = lock_api("A")
		local lock_b, unlock_b = lock_api("B")
		local adapter_a = fixture.make_adapter(nil, nil, nil, nil, lock_a, unlock_a)
		local adapter_b = fixture.make_adapter(nil, nil, nil, nil, lock_b, unlock_b)
		local original_open = io.open
		local original_rename = os.rename
		local competitor_written, competitor_err = nil, nil
		local competitor_renames = 0
		local in_publication_hook = false

		io.open = function(open_path, mode)
			if open_path == lock_path and mode == "a+" then
				return { close = function() return true end }
			end
			return original_open(open_path, mode)
		end
		os.rename = function(old_path, new_path)
			if new_path == path and in_publication_hook then
				competitor_renames = competitor_renames + 1
			end
			if new_path == path and not in_publication_hook then
				in_publication_hook = true
				if use_unconditional_writer then
					competitor_written, competitor_err = adapter_b.write(path, "writer B")
				else
					competitor_written, competitor_err = adapter_b.write_if_unchanged(path, "writer B", {
						status = "ok",
						content = "v0",
					})
				end
				in_publication_hook = false
			end
			if new_path == path then os.remove(new_path) end -- model POSIX replacement on Windows
			return original_rename(old_path, new_path)
		end

		local call_ok, writer_a_result = xpcall(function()
			return adapter_a.write_if_unchanged(path, "writer A", {
				status = "ok",
				content = "v0",
			})
		end, debug.traceback)
		io.open = original_open
		os.rename = original_rename
		local final_content = read_all(path)
		os.remove(path)
		os.remove(lock_path)
		if not call_ok then error(writer_a_result, 0) end

		helpers.assert_eq(writer_a_result, true, "the lock owner must publish its complete candidate")
		helpers.assert_eq(competitor_written, false,
			"a nested cooperating writer must fail closed instead of entering the compare/rename gap")
		helpers.assert_true(type(competitor_err) == "string" and competitor_err ~= "",
			"lock contention must surface a concrete refusal")
		helpers.assert_eq(competitor_renames, 0, "the losing writer must never reach publication")
		helpers.assert_eq(lock_calls.A, 1)
		helpers.assert_eq(lock_calls.B, 1,
			"the behavioral repro must reach the shared non-blocking kernel-lock boundary")
		helpers.assert_eq(unlock_calls.A, 1)
		helpers.assert_eq(unlock_calls.B, 0, "a process that never acquired must never unlock")
		helpers.assert_nil(owner, "the winning transaction must release its process lock")
		helpers.assert_eq(final_content, "writer A",
			"exactly the sole lock owner may determine the committed bytes")
	end

	helpers.it("serializes two conditional Ergopti writers across the final compare/rename gap", function()
		with_fixture(function(fixture)
			run_nested_competitor(fixture, false)
		end)
	end)

	helpers.it("serializes unconditional reset against a conditional Ergopti writer", function()
		with_fixture(function(fixture)
			run_nested_competitor(fixture, true)
		end)
	end)

	helpers.it("serializes create-only publication against an absent-source conditional writer", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local lock_path = path .. fixture.WRITE_LOCK_SUFFIX
			os.remove(path)
			os.remove(lock_path)

			local owner = nil
			local lock_calls = { creator = 0, replacer = 0 }
			local unlock_calls = { creator = 0, replacer = 0 }
			local function lock_api(name)
				return function()
					lock_calls[name] = lock_calls[name] + 1
					if owner ~= nil then return nil, "injected busy lock" end
					owner = name
					return true
				end, function()
					unlock_calls[name] = unlock_calls[name] + 1
					if owner ~= name then return nil, "wrong injected owner" end
					owner = nil
					return true
				end
			end

			local creator_lock, creator_unlock = lock_api("creator")
			local replacer_lock, replacer_unlock = lock_api("replacer")
			local replacer = nil
			local replacer_written, replacer_err = nil, nil
			local creator = fixture.make_adapter(nil, nil, nil, function(source, destination)
				replacer_written, replacer_err = replacer.write_if_unchanged(destination, "replacer", {
					status = "absent",
				})
				local existing_handle = io.open(destination, "r")
				if existing_handle ~= nil then
					existing_handle:close()
					return nil, "destination already exists"
				end
				local source_handle = assert(io.open(source, "r"))
				local content = source_handle:read("*a")
				source_handle:close()
				local destination_handle = assert(io.open(destination, "w"))
				assert(destination_handle:write(content))
				assert(destination_handle:close())
				return true
			end, creator_lock, creator_unlock)
			replacer = fixture.make_adapter(nil, nil, nil, nil, replacer_lock, replacer_unlock)

			local created, status, detail = creator.create_if_absent(path, "creator")
			local final_content = read_all(path)
			os.remove(path)
			os.remove(lock_path)

			helpers.assert_eq(created, true, tostring(detail))
			helpers.assert_eq(status, "created")
			helpers.assert_eq(replacer_written, false,
				"the conditional replacer must not enter create-only publication's compare/link gap")
			helpers.assert_true(type(replacer_err) == "string" and replacer_err ~= "",
				"lock contention must surface a concrete refusal")
			helpers.assert_eq(lock_calls.creator, 1,
				"create_if_absent() must own the same cooperative mutex as replacement writers")
			helpers.assert_eq(lock_calls.replacer, 1)
			helpers.assert_eq(unlock_calls.creator, 1)
			helpers.assert_eq(unlock_calls.replacer, 0)
			helpers.assert_nil(owner)
			helpers.assert_eq(final_content, "creator",
				"exactly the create-only lock owner may determine the committed bytes")
		end)
	end)

	helpers.it("checks the expected source only after lock acquisition and releases after rename", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local lock_path = path .. fixture.WRITE_LOCK_SUFFIX
			os.remove(path)
			os.remove(lock_path)
			seed(path, "v0")
			local events = {}
			local held = false
			local adapter = fixture.make_adapter(nil, nil, nil, nil, function()
				events[#events + 1] = "lock"
				held = true
				seed(path, "changed before comparison")
				return true
			end, function()
				events[#events + 1] = "unlock"
				held = false
				return true
			end)
			local original_open = io.open
			local original_rename = os.rename
			local renames = 0
			io.open = function(open_path, mode)
				if open_path == lock_path and mode == "a+" then
					return { close = function()
						events[#events + 1] = "close"
						return true
					end }
				end
				if open_path == path and mode == "r" and held then
					events[#events + 1] = "expected-read"
				end
				return original_open(open_path, mode)
			end
			os.rename = function(old_path, new_path)
				if new_path == path then
					renames = renames + 1
					events[#events + 1] = "rename"
				end
				return original_rename(old_path, new_path)
			end
			local call_ok, written = xpcall(function()
				return adapter.write_if_unchanged(path, "candidate", {
					status = "ok",
					content = "v0",
				})
			end, debug.traceback)
			io.open = original_open
			os.rename = original_rename
			local final_content = read_all(path)
			os.remove(path)
			os.remove(lock_path)
			if not call_ok then error(written, 0) end

			helpers.assert_eq(written, false, "a source changed before the protected comparison must lose")
			helpers.assert_eq(renames, 0)
			helpers.assert_eq(events[1], "lock", "kernel ownership must precede every source read")
			helpers.assert_eq(events[#events - 1], "unlock")
			helpers.assert_eq(events[#events], "close")
			helpers.assert_true(table.concat(events, ","):find("expected-read", 1, true) ~= nil,
				"the protected transaction must re-read its expected source")
			helpers.assert_eq(final_content, "changed before comparison")
		end)
	end)

	helpers.it("releases after rename failure so the next cooperating writer can progress", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local lock_path = path .. fixture.WRITE_LOCK_SUFFIX
			os.remove(path)
			os.remove(lock_path)
			seed(path, "old")
			local held = false
			local locks, unlocks, closes = 0, 0, 0
			local adapter = fixture.make_adapter(nil, nil, nil, nil, function()
				locks = locks + 1
				if held then return nil, "still held" end
				held = true
				return true
			end, function()
				unlocks = unlocks + 1
				held = false
				return true
			end)
			local original_open = io.open
			local original_rename = os.rename
			local refuse_first = true
			io.open = function(open_path, mode)
				if open_path == lock_path and mode == "a+" then
					return { close = function() closes = closes + 1; return true end }
				end
				return original_open(open_path, mode)
			end
			os.rename = function(old_path, new_path)
				if new_path == path and refuse_first then
					refuse_first = false
					return nil, "injected rename refusal"
				end
				if new_path == path then os.remove(new_path) end -- model POSIX replacement on Windows
				return original_rename(old_path, new_path)
			end
			local call_ok, first, second = xpcall(function()
				local first_result = adapter.write(path, "first")
				local second_result = adapter.write(path, "second")
				return first_result, second_result
			end, debug.traceback)
			io.open = original_open
			os.rename = original_rename
			local final_content = read_all(path)
			os.remove(path)
			os.remove(lock_path)
			if not call_ok then error(first, 0) end

			helpers.assert_eq(first, false)
			helpers.assert_eq(second, true, "a failed transaction must not strand the process mutex")
			helpers.assert_eq(locks, 2)
			helpers.assert_eq(unlocks, 2)
			helpers.assert_eq(closes, 2)
			helpers.assert_true(not held)
			helpers.assert_eq(final_content, "second")
		end)
	end)

	helpers.it("keeps one stable regular lock inode and rejects a directory at that pathname", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local lock_path = path .. fixture.WRITE_LOCK_SUFFIX
			os.remove(path)
			os.remove(lock_path)
			local adapter = fixture.make_adapter()
			local original_rename = os.rename
			os.rename = function(old_path, new_path)
				if new_path == path then os.remove(new_path) end -- model POSIX replacement on Windows
				return original_rename(old_path, new_path)
			end
			local first_written = adapter.write(path, "one")
			local first_lock = io.open(lock_path, "r")
			helpers.assert_true(first_lock ~= nil, "the stable cooperative lock file must persist")
			if first_lock then first_lock:close() end
			local second_written = adapter.write(path, "two")
			os.rename = original_rename
			helpers.assert_eq(first_written, true)
			helpers.assert_eq(second_written, true,
				"a later writer must reuse, not unlink/recreate, the stable lock pathname")
			os.remove(path)
			os.remove(lock_path)

			local directory_target = os.tmpname():gsub("\\", "/")
			local directory_lock = directory_target .. fixture.WRITE_LOCK_SUFFIX
			os.remove(directory_target)
			os.remove(directory_lock)
			assert(fixture.HOST_MKDIR(directory_lock))
			local directory_adapter = fixture.make_adapter()
			local written = directory_adapter.write(directory_target, "blocked")
			helpers.assert_eq(written, false,
				"a directory/symlink collision must fail closed before staging or publication")
			helpers.assert_nil(io.open(directory_target, "r"))
			fixture.HOST_RMDIR(directory_lock)
		end)
	end)
end)
