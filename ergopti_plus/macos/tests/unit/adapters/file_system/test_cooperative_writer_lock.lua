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

helpers.describe("adapters.file_system: conditional removal ownership", function()
	local function with_owned_file(callback)
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local original_remove = os.remove
			local original_open = io.open
			local seed = assert(original_open(path, "w"))
			assert(seed:write("owned preset")); assert(seed:close())
			local call_ok, detail = xpcall(function() callback(fixture, path) end, debug.traceback)
			os.remove = original_remove
			io.open = original_open
			original_remove(path)
			original_remove(path .. fixture.WRITE_LOCK_SUFFIX)
			if not call_ok then error(detail, 0) end
		end)
	end

	local function writer()
		return require("toml_codec.writer")
	end

	local function expected()
		return { status = "ok", content = "owned preset" }
	end

	helpers.it("holds the canonical writer mutex around exact unlink and releases it", function()
		with_owned_file(function(fixture, path)
			local held, locks, unlocks, unlinks = false, 0, 0, 0
			local adapter = fixture.make_adapter(nil, nil, nil, nil, function()
				held, locks = true, locks + 1; return true
			end, function() held, unlocks = false, unlocks + 1; return true end)
			local original_remove = os.remove
			os.remove = function(target)
				if target == path then
					helpers.assert_eq(held, true, "the source check and unlink must share publication ownership")
					unlinks = unlinks + 1
				end
				return original_remove(target)
			end
			helpers.assert_eq(writer().remove_if_unchanged(path, adapter, expected()), true)
			helpers.assert_eq(locks, 1); helpers.assert_eq(unlocks, 1)
			helpers.assert_eq(unlinks, 1); helpers.assert_eq(held, false)
			helpers.assert_eq(adapter.read_with_status(path), nil)
			local lock_file = assert(io.open(path .. fixture.WRITE_LOCK_SUFFIX, "r"))
			assert(lock_file:close())
		end)
	end)

	helpers.it("rejects a cooperating replacement inside the final read/unlink gap", function()
		with_owned_file(function(fixture, path)
			local owner, contender_calls, contender_written = nil, 0, nil
			local function lock_api(name)
				return function()
					if name == "writer" then contender_calls = contender_calls + 1 end
					if owner ~= nil then return false, "native lease already held" end
					owner = name; return true
				end, function() helpers.assert_eq(owner, name); owner = nil; return true end
			end
			local lock_remove, unlock_remove = lock_api("remover")
			local lock_write, unlock_write = lock_api("writer")
			local remover = fixture.make_adapter(nil, nil, nil, nil, lock_remove, unlock_remove)
			local competitor = fixture.make_adapter(nil, nil, nil, nil, lock_write, unlock_write)
			local original_remove = os.remove
			os.remove = function(target)
				if target == path then contender_written = competitor.write(path, "replacement") end
				return original_remove(target)
			end
			helpers.assert_eq(writer().remove_if_unchanged(path, remover, expected()), true)
			helpers.assert_eq(contender_calls, 1, "the second native owner must actually contest the lease")
			helpers.assert_eq(contender_written, false, "replacement must not enter the protected unlink gap")
			helpers.assert_eq(owner, nil)
		end)
	end)

	helpers.it("rejects removal through an alias while a canonical writer owns its mutex", function()
		with_owned_file(function(fixture, path)
			local adapter = fixture.make_adapter()
			local group, acquired = adapter.acquire_write_locks({ path })
			helpers.assert_eq(acquired, true)
			local parent, basename = fixture.split_parent(path)
			local removed = writer().remove_if_unchanged(parent .. "/./" .. basename, adapter, expected())
			local released = adapter.release_write_locks(group)
			helpers.assert_eq(removed, false)
			helpers.assert_eq(released, true)
			helpers.assert_eq(adapter.read_with_status(path), "owned preset")
		end)
	end)

	helpers.it("rechecks changed bytes after acquiring its canonical native mutex", function()
		with_owned_file(function(fixture, path)
			local adapter = fixture.make_adapter(nil, nil, nil, nil, function()
				local file = assert(io.open(path, "w")); assert(file:write("new cooperator bytes")); assert(file:close())
				return true
			end)
			helpers.assert_eq(writer().remove_if_unchanged(path, adapter, expected()), false)
			helpers.assert_eq(adapter.read_with_status(path), "new cooperator bytes")
		end)
	end)

	helpers.it("refuses a route retargeted while acquiring its old target mutex", function()
		with_owned_file(function(fixture, path)
			local alias = path .. "-link"
			local routes = { [alias] = path }
			local adapter = fixture.make_adapter(routes, nil, nil, nil, function()
				routes[alias] = path .. "-foreign"; return true
			end)
			helpers.assert_eq(writer().remove_if_unchanged(alias, adapter, expected()), false)
			helpers.assert_eq(adapter.read_with_status(path), "owned preset")
		end)
	end)

	for _, refusal in ipairs({ "false", "nil", "truthy", "throw" }) do
		helpers.it("retains original bytes on native unlink " .. refusal .. " refusal", function()
			with_owned_file(function(fixture, path)
				local unlocks = 0
				local adapter = fixture.make_adapter(nil, nil, nil, nil, nil, function()
					unlocks = unlocks + 1; return true
				end)
				local original_remove = os.remove
				os.remove = function(target)
					if target ~= path then return original_remove(target) end
					if refusal == "throw" then error("native unlink exception") end
					if refusal == "nil" then return nil, "native refusal" end
					if refusal == "truthy" then return "true" end
					return false, "native refusal"
				end
				local removed, detail = writer().remove_if_unchanged(path, adapter, expected())
				helpers.assert_eq(removed, false)
				helpers.assert_true(type(detail) == "string" and detail ~= "")
				helpers.assert_eq(unlocks, 1)
				helpers.assert_eq(adapter.read_with_status(path), "owned preset")
			end)
		end)
	end

	for _, after_unlink in ipairs({ "absent", "foreign" }) do
		helpers.it("retains release debt before the " .. after_unlink .. " layer shortcut", function()
			with_owned_file(function(fixture, path)
				local blocked, lock_calls, unlinks = true, 0, 0
				local adapter = fixture.make_adapter(nil, nil, nil, nil, function()
					lock_calls = lock_calls + 1; return true
				end, function()
					if blocked then return false, "unlock refused" end
					return true
				end)
				local original_open, original_remove = io.open, os.remove
				io.open = function(target, mode)
					if target == path .. fixture.WRITE_LOCK_SUFFIX and mode == "a+" then
						return { close = function() return not blocked end }
					end
					return original_open(target, mode)
				end
				os.remove = function(target)
					if target == path then unlinks = unlinks + 1 end
					return original_remove(target)
				end
				local preset = require("keymap.layer_preset")
				local record = { status = preset.IMPORTED, path = path, content = "owned preset" }
				helpers.assert_eq(preset.undo(record, adapter), false)
				helpers.assert_eq(type(record.removal_cleanup), "function")
				if after_unlink == "foreign" then
					local file = assert(original_open(path, "w")); assert(file:write("foreign bytes")); assert(file:close())
				end
				helpers.assert_eq(preset.undo(record, adapter), false,
					"absence or changed bytes cannot acknowledge a retained native lease")
				helpers.assert_eq(adapter.write(path, "new request"), false,
					"the authoritative process registry must continue fencing same-path writers")
				helpers.assert_eq(lock_calls, 1)
				blocked = false
				helpers.assert_eq(preset.undo(record, adapter), true)
				helpers.assert_eq(record.removal_cleanup, nil)
				helpers.assert_eq(unlinks, 1, "release retry must never unlink a successor")
				if after_unlink == "foreign" then helpers.assert_eq(adapter.read_with_status(path), "foreign bytes") end
			end)
		end)
	end

	helpers.it("keeps a refused removal retryable once the native owner releases", function()
		with_owned_file(function(fixture, path)
			local blocked, attempts = true, 0
			local adapter = fixture.make_adapter(nil, nil, nil, nil, nil, function() return not blocked end)
			local original_open, original_remove = io.open, os.remove
			io.open = function(target, mode)
				if target == path .. fixture.WRITE_LOCK_SUFFIX and mode == "a+" then
					return { close = function() return not blocked end }
				end
				return original_open(target, mode)
			end
			os.remove = function(target)
				if target == path then
					attempts = attempts + 1
					if attempts == 1 then return false, "unlink refused" end
				end
				return original_remove(target)
			end
			local preset = require("keymap.layer_preset")
			local record = { status = preset.IMPORTED, path = path, content = "owned preset" }
			helpers.assert_eq(preset.undo(record, adapter), false)
			blocked = false
			helpers.assert_eq(preset.undo(record, adapter), true)
			helpers.assert_eq(attempts, 2)
		end)
	end)
end)

helpers.describe("conditional removal composed scope", function()
	helpers.it("retains the real native cleanup owner in the actual configuration inverse", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local backup = path .. "-backup"
			os.remove(path); os.remove(backup)
			local blocked, restores, unlinks = false, 0, 0
			local adapter = fixture.make_adapter(nil, nil, nil, nil, nil, function() return not blocked end)
			local original_open, original_remove = io.open, os.remove
			io.open = function(target, mode)
				if target == path .. fixture.WRITE_LOCK_SUFFIX and mode == "a+" then
					return { close = function() return not blocked end }
				end
				return original_open(target, mode)
			end
			os.remove = function(target)
				if target == path then unlinks = unlinks + 1 end
				return original_remove(target)
			end
			local call_ok, detail = xpcall(function()
				local owner = require("config_scope_transaction").new({
					path = path, backup_path = backup, files = adapter,
					manifest = { scope_plan = function() return {
						presets = {}, operations = { { section = "scope", key = "enabled", value = true } },
					} end },
					capture = function() return {} end,
					apply = function() return true end,
					restore = function() restores = restores + 1; return true end,
				})
				helpers.assert_eq(owner.apply("scope", "recommended"), true)
				blocked = true
				helpers.assert_eq(owner.revert(), false)
				helpers.assert_eq(owner.pending(), true)
				helpers.assert_eq(owner.retry_restore(), false)
				helpers.assert_eq(owner.apply("scope", "clear"), false)
				local successor = assert(original_open(path, "w"))
				assert(successor:write("successor bytes")); assert(successor:close())
				blocked = false
				helpers.assert_eq(owner.retry_restore(), true)
				helpers.assert_eq(owner.pending(), false)
				helpers.assert_eq(unlinks, 1, "the exact retained cleanup cannot unlink a successor")
				helpers.assert_eq(restores, 1)
				helpers.assert_eq(adapter.read_with_status(path), "successor bytes")
			end, debug.traceback)
			io.open, os.remove = original_open, original_remove
			original_remove(path); original_remove(backup)
			original_remove(path .. fixture.WRITE_LOCK_SUFFIX)
			original_remove(backup .. fixture.WRITE_LOCK_SUFFIX)
			if not call_ok then error(detail, 0) end
		end)
	end)
end)

helpers.describe("navigation-layer cohort native release debt", function()
	for _, phase in ipairs({ "prepare", "restore", "no_effect_restore" }) do
		helpers.it("settles the exact release before cohort " .. phase .. " acknowledgement", function()
			with_fixture(function(fixture)
				helpers.with_stub_scope({ "platform.remap.nav_layer", "platform.remap.scope_layer" }, function()
					local path = os.tmpname():gsub("\\", "/")
					local file = assert(io.open(path, "w")); assert(file:write("owned preset")); assert(file:close())
					local blocked, unlinks = true, 0
					local adapter = fixture.make_adapter(nil, nil, nil, nil, nil, function() return not blocked end)
					local original_open, original_remove = io.open, os.remove
					io.open = function(target, mode)
						if target == path .. fixture.WRITE_LOCK_SUFFIX and mode == "a+" then
							return { close = function() return not blocked end }
						end
						return original_open(target, mode)
					end
					os.remove = function(target)
						if target == path then
							unlinks = unlinks + 1
							if phase == "no_effect_restore" then return false, "unlink refused without effect" end
						end
						return original_remove(target)
					end
					local call_ok, detail = xpcall(function()
						local preset = require("keymap.layer_preset")
						package.loaded["platform.remap.nav_layer"] = {
							import_recommended = function() return {
								status = preset.IMPORTED, path = path, content = "owned preset",
							} end,
							undo_import = preset.undo, reconcile_wheel = function() end,
						}
						package.loaded["platform.remap.scope_layer"] = nil
						local cohort = require("platform.remap.scope_layer")
						local imported = cohort.import()
						helpers.assert_eq(imported.prepare(), true); imported.settled(true)
						local inverse = assert(cohort.inverse(imported.receipt()))
						helpers.assert_eq(inverse.prepare(), false)
						if phase == "prepare" then
							helpers.assert_eq(inverse.prepare(), false, "absence cannot discard a retained release")
							blocked = false
							helpers.assert_eq(inverse.prepare(), true)
							helpers.assert_eq(inverse.restore(), true,
								"a later refusal still owes the removal effect retained across prepare retries")
							helpers.assert_eq(adapter.read_with_status(path), "owned preset")
						else
							helpers.assert_eq(inverse.restore(), false, "compensation must settle the old unlink lease first")
							blocked = false
							helpers.assert_eq(inverse.restore(), true)
							helpers.assert_eq(adapter.read_with_status(path), "owned preset")
						end
						helpers.assert_eq(unlinks, 1)
					end, debug.traceback)
					io.open, os.remove = original_open, original_remove
					original_remove(path); original_remove(path .. fixture.WRITE_LOCK_SUFFIX)
					if not call_ok then error(detail, 0) end
				end)
			end)
		end)
	end
end)

helpers.describe("conditional removal classified read refusal", function()
	helpers.it("keeps unreadable bytes and releases the lease without unlinking", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local file = assert(io.open(path, "w")); assert(file:write("owned preset")); assert(file:close())
			local locks, unlocks, unlinks = 0, 0, 0
			local adapter = fixture.make_adapter(nil, nil, nil, nil, function()
				locks = locks + 1; return true
			end, function() unlocks = unlocks + 1; return true end)
			local original_open, original_remove = io.open, os.remove
			io.open = function(target, mode)
				if target == path and mode == "r" then return nil, "controlled read refusal" end
				return original_open(target, mode)
			end
			os.remove = function(target)
				if target == path then unlinks = unlinks + 1 end
				return original_remove(target)
			end
			local call_ok, removed, detail = pcall(require("toml_codec.writer").remove_if_unchanged,
				path, adapter, { status = "ok", content = "owned preset" })
			io.open, os.remove = original_open, original_remove
			local observed = assert(original_open(path, "r")); local source = observed:read("*a"); assert(observed:close())
			original_remove(path); original_remove(path .. fixture.WRITE_LOCK_SUFFIX)
			helpers.assert_eq(call_ok, true)
			helpers.assert_eq(removed, false)
			helpers.assert_contains(detail, "controlled read refusal")
			helpers.assert_eq(source, "owned preset")
			helpers.assert_eq(locks, 1); helpers.assert_eq(unlocks, 1); helpers.assert_eq(unlinks, 0)
		end)
	end)
end)

helpers.describe("conditional publication retained admission", function()
	local function with_owned_publication(body)
		with_fixture(function(fixture)
			helpers.with_stub_scope({ "platform.remap.nav_layer", "platform.remap.scope_layer" }, function()
				local dir = os.tmpname():gsub("\\", "/")
				os.remove(dir)
				assert(fixture.HOST_MKDIR(dir))
				local path = dir .. "/layers.toml"
				local control = { blocked = true, target = path, unlocks = 0, closes = 0, writes = 0 }
				local original_open, original_rename = io.open, os.rename
				local held = {}
				io.open = function(name, mode)
					if name == control.target .. fixture.WRITE_LOCK_SUFFIX and mode == "a+" then
						local handle = { close = function()
							control.closes = control.closes + 1
							local closed = not control.blocked
							if closed and type(control.after_close) == "function" then control.after_close() end
							return closed
						end }
						held[handle] = true
						return handle
					end
					return original_open(name, mode)
				end
				os.rename = function(old, new)
					if new == path then
						control.writes = control.writes + 1
						if control.refuse_rename then return nil, "controlled pre-publication refusal" end
						os.remove(new) -- POSIX replacement in stock Windows Lua fixtures.
					end
					return original_rename(old, new)
				end
				local fs = fixture.make_adapter(nil, nil, nil, nil, function() return true end, function(handle)
					if held[handle] then control.unlocks = control.unlocks + 1; return not control.blocked end
					return true
				end)
				local function seed(name, bytes)
					local file = assert(original_open(name, "w")); assert(file:write(bytes)); assert(file:close())
				end
				local called, detail = xpcall(function() body(path, fs, control, seed, fixture) end, debug.traceback)
				io.open, os.rename = original_open, original_rename
				for _, name in ipairs({ path, path .. ".backup", path .. fixture.WRITE_LOCK_SUFFIX,
					path .. ".backup" .. fixture.WRITE_LOCK_SUFFIX }) do os.remove(name) end
				fixture.HOST_RMDIR(dir)
				if not called then error(detail, 0) end
			end)
		end)
	end

	for _, prepublication in ipairs({ false, true }) do
		helpers.it("retains a failed real layer import after publication=" .. tostring(not prepublication), function()
			with_owned_publication(function(path, fs, control, seed)
				control.refuse_rename = prepublication
				local nav = require("platform.remap.nav_layer")
				package.loaded["platform.remap.nav_layer"] = {
					import_recommended = function() return nav.import_recommended({
						shared_root = helpers.shared(), config_dir = path:match("^(.*)/[^/]+$"), file_adapter = fs,
					}) end,
					undo_import = nav.undo_import, reconcile_wheel = function() end,
				}
				local sibling = require("platform.remap.scope_layer").import()
				helpers.assert_eq(sibling.prepare(), false, "no success before native release")
				helpers.assert_eq(sibling.receipt(), nil, "failed preparation issues no successful public capability")
				helpers.assert_eq(sibling.restore(), false, "no-record and absence shortcuts cannot settle debt")
				helpers.assert_eq(sibling.prepare(), false, "a retained private import cannot be replaced")
				local bytes, status = fs.read_with_status(path)
				helpers.assert_eq(status, prepublication and "absent" or "ok")
				if not prepublication then helpers.assert_true(#bytes > 0) end
				if prepublication then seed(path, "foreign successor") end
				control.blocked = false
				helpers.assert_eq(sibling.restore(), true, "the exact native cleanup remains retryable")
				local current, restored = fs.read_with_status(path)
				helpers.assert_eq(restored, prepublication and "ok" or "absent")
				if prepublication then helpers.assert_eq(current, "foreign successor") end
				local group, acquired = fs.acquire_write_locks({ path })
				helpers.assert_eq(acquired, true, "release frees the original canonical owner")
				helpers.assert_eq(fs.release_write_locks(group), true)
				helpers.assert_eq(control.writes, 1, "cleanup never retries publication")
			end)
		end)
	end

	for _, source_present in ipairs({ false, true }) do
		helpers.it("retains actual generic scope publication with source_present=" .. tostring(source_present), function()
			with_owned_publication(function(path, fs, control, seed)
				local source = "[custom]\nvalue = 0\n"
				if source_present then seed(path, source) end
				local runtime = 0
				local owner = require("config_scope_transaction").new({ path = path, backup_path = path .. ".backup",
					files = fs, manifest = { scope_plan = function() return { presets = {},
						operations = { { section = "custom", key = "value", value = 1 } } } end },
					capture = function() return { value = runtime } end,
					apply = function() runtime = 1; return true end,
					restore = function(snapshot) runtime = snapshot.value; return true end,
				})
				helpers.assert_eq(owner.apply("custom", "recommended"), false)
				helpers.assert_eq(owner.pending(), true, "false publication cannot settle a changed file")
				helpers.assert_eq(runtime, 1, "native release precedes runtime compensation")
				helpers.assert_eq(owner.retry_restore(), false)
				control.blocked = false
				helpers.assert_eq(owner.retry_restore(), true)
				helpers.assert_eq(owner.pending(), false)
				helpers.assert_eq(runtime, 0)
				local bytes, status = fs.read_with_status(path)
				helpers.assert_eq(status, source_present and "ok" or "absent")
				if source_present then helpers.assert_eq(bytes, source) end
			end)
		end)
	end

	helpers.it("keeps a refused backup's data while retaining its exact native release", function()
		with_owned_publication(function(path, fs, control, seed)
			local source = "[custom]\nvalue = 0\n"
			seed(path, source)
			control.target = path .. ".backup"
			local runtime = 0
			local owner = require("config_scope_transaction").new({ path = path, backup_path = path .. ".backup",
				files = fs, manifest = { scope_plan = function() return { presets = {},
					operations = { { section = "custom", key = "value", value = 1 } } } end },
				capture = function() return {} end, apply = function() runtime = 1; return true end,
				restore = function() runtime = 0; return true end,
			})
			helpers.assert_eq(owner.apply("custom", "recommended"), false)
			helpers.assert_eq(owner.pending(), true)
			helpers.assert_eq(runtime, 0, "backup refusal precedes runtime mutation")
			control.blocked = false
			helpers.assert_eq(owner.retry_restore(), true)
			helpers.assert_eq(fs.read_with_status(path), source)
			helpers.assert_eq(fs.read_with_status(path .. ".backup"), source, "recovery never deletes backup data")
		end)
	end)

	helpers.it("retains an inverse publication and verifies it without replacing an external successor", function()
		with_owned_publication(function(path, fs, control, seed)
			local source = "[custom]\nvalue = 0\n"
			seed(path, source); control.blocked = false
			local owner = require("config_scope_transaction").new({ path = path, backup_path = path .. ".backup",
				files = fs, manifest = { scope_plan = function() return { presets = {},
					operations = { { section = "custom", key = "value", value = 1 } } } end },
				capture = function() return {} end, apply = function() return true end, restore = function() return true end,
			})
			helpers.assert_eq(owner.apply("custom", "recommended"), true)
			control.blocked = true
			helpers.assert_eq(owner.revert(), false)
			helpers.assert_eq(owner.pending(), true)
			helpers.assert_eq(fs.read_with_status(path), source)
			seed(path, "external successor")
			control.blocked = false
			local writes = control.writes
			helpers.assert_eq(owner.retry_restore(), false, "native release alone does not verify the inverse target")
			helpers.assert_eq(owner.retry_restore(), false)
			helpers.assert_eq(fs.read_with_status(path), "external successor")
			helpers.assert_eq(control.writes, writes, "a published inverse is never republished on retry")
			seed(path, source)
			helpers.assert_eq(owner.retry_restore(), true)
		end)
	end)

	helpers.it("makes a settled native publication capability harmless to a later lock owner", function()
		with_owned_publication(function(path, fs, control)
			local written, _, cleanup = fs.write_if_unchanged(path, "owned bytes", { status = "absent" })
			helpers.assert_eq(written, false); helpers.assert_eq(type(cleanup), "function")
			control.blocked = false
			local settled, _, published = cleanup()
			helpers.assert_eq(settled, true); helpers.assert_eq(published, true)
			local group, acquired = fs.acquire_write_locks({ path })
			helpers.assert_eq(acquired, true)
			local unlocks, closes = control.unlocks, control.closes
			helpers.assert_eq(cleanup(), true)
			helpers.assert_eq(control.unlocks, unlocks)
			helpers.assert_eq(control.closes, closes, "duplicate cleanup cannot release a successor")
			helpers.assert_eq(fs.release_write_locks(group), true)
		end)
	end)
	for _, phase in ipairs({ "backup", "publication", "inverse" }) do
		helpers.it("retains actual secondary-file " .. phase .. " publication cleanup", function()
			with_owned_publication(function(path, fs, control, seed)
				local source = "[custom]\nvalue = 0\n"
				seed(path, source)
				local secondary = require("config_scope_file").new({ path = path, backup_path = path .. ".backup",
					files = fs, remove = fs.remove_exact })
				helpers.assert_eq(secondary.prepare({ { section = "custom", key = "value", value = 1 } }), true)
				if phase == "backup" then
					control.target = path .. ".backup"
					helpers.assert_eq(secondary.backup(), false)
				else
					if phase == "inverse" then control.blocked = false end
					helpers.assert_eq(secondary.publish(), phase == "inverse")
					control.blocked = true
				end
				helpers.assert_eq(secondary.restore(), false, "native debt precedes no-effect shortcuts")
				helpers.assert_eq(secondary.pending(), true)
				control.blocked = false
				helpers.assert_eq(secondary.restore(), true)
				helpers.assert_eq(secondary.pending(), false)
				helpers.assert_eq(fs.read_with_status(path), source)
				if phase == "backup" then helpers.assert_eq(fs.read_with_status(path .. ".backup"), source) end
			end)
		end)
	end

	helpers.it("retains only its pre-publication staging and writer cleanup identities", function()
		with_owned_publication(function(path, fs, control)
			control.refuse_rename = true
			local original_remove, stage_blocked = os.remove, true
			os.remove = function(name)
				if name:sub(-#"/payload") == "/payload" and stage_blocked then return nil, "private stage removal refused" end
				return original_remove(name)
			end
			local called, detail = xpcall(function()
				local written, _, cleanup = fs.write_if_unchanged(path, "candidate", { status = "absent" })
				helpers.assert_eq(written, false); helpers.assert_eq(type(cleanup), "function")
				helpers.assert_eq(cleanup(), false)
				control.blocked = false
				helpers.assert_eq(cleanup(), false, "freeing the writer does not discard private staging debt")
				stage_blocked = false
				local settled, _, published = cleanup()
				helpers.assert_eq(settled, true); helpers.assert_eq(published, false)
				local _, status = fs.read_with_status(path)
				helpers.assert_eq(status, "absent", "cleanup never retries refused publication")
			end, debug.traceback)
			os.remove = original_remove
			if not called then error(detail, 0) end
		end)
	end)

	helpers.it("retains the cohort inverse's restoration publication before acknowledging its target", function()
		with_owned_publication(function(path, fs, control, seed)
			control.blocked = false
			local nav = require("platform.remap.nav_layer")
			package.loaded["platform.remap.nav_layer"] = {
				import_recommended = function() return nav.import_recommended({
					shared_root = helpers.shared(), config_dir = path:match("^(.*)/[^/]+$"), file_adapter = fs,
				}) end,
				undo_import = nav.undo_import, reconcile_wheel = function() end,
			}
			local cohort = require("platform.remap.scope_layer")
			local sibling = cohort.import()
			helpers.assert_eq(sibling.prepare(), true); sibling.settled(true)
			local bytes = fs.read_with_status(path)
			local inverse = assert(cohort.inverse(sibling.receipt()))
			helpers.assert_eq(inverse.prepare(), true)
			control.blocked = true
			helpers.assert_eq(inverse.restore(), false)
			helpers.assert_eq(inverse.restore(), false, "published restoration still owes the same native cleanup")
			seed(path, "external successor"); control.blocked = false
			helpers.assert_eq(inverse.restore(), false, "release does not verify a changed restoration target")
			helpers.assert_eq(inverse.restore(), false)
			helpers.assert_eq(fs.read_with_status(path), "external successor")
			seed(path, bytes)
			helpers.assert_eq(inverse.restore(), true)
			helpers.assert_eq(control.writes, 2, "inverse restoration is published only once")
		end)
	end)

	--- Runs the actual Config and bulk facade against this native file owner.
	--- Lifecycle and fcntl receipts remain controlled; the source and staging I/O
	--- are real, and no dummy writer supplies the publication/effect capability.
	local function with_native_remap(path, fs, control, seed, body)
		require("tests.support.remap_transaction_fixture")(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			local configured = package.loaded["platform.remap.config"]
			configured.build_default_state = function()
				return { tap_holds_enabled = false, tap_hold_config = { left_shift = { tap = "none", hold = "none" } },
					mod_combos_config = {}, tap_hold_timeout_ms = 200, sticky_timeout_ms = 1000,
					simultaneous_threshold_ms = 50, combo_symmetric = false }
			end
			package.loaded["infra.config_paths"].get = function() return path end
			local captured_files = require("adapters.file_system")
			for _, method in ipairs({ "read_with_status", "write_if_unchanged", "write", "remove_if_unchanged", "remove_exact" }) do
				captured_files[method] = fs[method]
			end
			package.loaded["adapters.file_system"] = fs
			package.loaded["platform.remap.config"] = nil
			local actual = helpers.load_with_stubs("platform.remap.config")
			configured.save_user_config = actual.save_user_config
			package.loaded["platform.remap.config"] = configured
			seed(path, "[custom]\nkeep = 17\n")
			control.blocked = false
			helpers.assert_eq(remap.set_tap_action("left_shift", "escape"), true)
			local source = assert(fs.read_with_status(path))
			control.blocked, control.writes = true, 0
			local driver = { regenerations = 0, terminals = {} }
			remap.regenerate = function(callback)
				driver.regenerations = driver.regenerations + 1
				driver.terminals[#driver.terminals + 1] = callback
				return true
			end
			body(remap, source, driver, calls)
		end)
	end

	for _, source_present in ipairs({ false, true }) do
		helpers.it("retains actual remap publication debt with source_present=" .. tostring(source_present), function()
			with_owned_publication(function(path, fs, control, seed)
				with_native_remap(path, fs, control, seed, function(remap, source, driver)
					if not source_present then assert(os.remove(path)) end
					local completed = 0
					local accepted = remap.apply_scope({ scope = "tap_holds", mode = "clear", backup_path = path .. ".backup" },
						function(ok) helpers.assert_eq(ok, false); completed = completed + 1 end)
					helpers.assert_eq(accepted, false)
					helpers.assert_eq(remap.settings_pending(), true, "published native refusal retains the final bulk owner")
					helpers.assert_eq(remap.get_tap_action("left_shift"), "escape", "false publication never adopts live settings")
					helpers.assert_eq(driver.regenerations, 0)
					helpers.assert_eq(control.writes, 1)
					helpers.assert_eq(remap.retry_settings_recovery(), false)
					helpers.assert_eq(remap.set_tap_action("left_shift", "paste"), false, "a sibling cannot replace release debt")
					helpers.assert_eq(control.writes, 1)
					control.blocked = false
					helpers.assert_eq(remap.retry_settings_recovery(), true)
					helpers.assert_eq(remap.settings_pending(), false)
					local bytes, status = fs.read_with_status(path)
					helpers.assert_eq(status, source_present and "ok" or "absent")
					if source_present then helpers.assert_eq(bytes, source); helpers.assert_eq(fs.read_with_status(path .. ".backup"), source) end
					helpers.assert_eq(completed, 1, "the original failure callback is never repeated")
					local writes, unlocks = control.writes, control.unlocks
					helpers.assert_eq(remap.retry_settings_recovery(), true)
					helpers.assert_eq(control.writes, writes); helpers.assert_eq(control.unlocks, unlocks)
				end)
			end)
		end)
	end

	helpers.it("keeps a foreign successor after a proven no-effect remap refusal", function()
		with_owned_publication(function(path, fs, control, seed)
			with_native_remap(path, fs, control, seed, function(remap)
				control.refuse_rename = true
				helpers.assert_eq(remap.apply_scope({ scope = "tap_holds", mode = "clear", backup_path = path .. ".backup" }), false)
				helpers.assert_eq(remap.settings_pending(), true, "unchanged-source shortcuts still owe native release")
				seed(path, "foreign successor")
				control.blocked = false
				helpers.assert_eq(remap.retry_settings_recovery(), true)
				helpers.assert_eq(fs.read_with_status(path), "foreign successor")
				helpers.assert_eq(control.writes, 1, "no-effect acknowledgement never republishes an inverse")
			end)
		end)
	end)

	helpers.it("retains a refused remap backup's native cleanup without deleting its data", function()
		with_owned_publication(function(path, fs, control, seed)
			with_native_remap(path, fs, control, seed, function(remap, source, driver)
				control.target = path .. ".backup"
				helpers.assert_eq(remap.apply_scope({ scope = "tap_holds", mode = "clear", backup_path = path .. ".backup" }), false)
				helpers.assert_eq(remap.settings_pending(), true)
				helpers.assert_eq(fs.read_with_status(path), source)
				helpers.assert_eq(fs.read_with_status(path .. ".backup"), source)
				helpers.assert_eq(remap.retry_settings_recovery(), false)
				control.blocked = false
				helpers.assert_eq(remap.retry_settings_recovery(), true)
				helpers.assert_eq(remap.settings_pending(), false)
				helpers.assert_eq(fs.read_with_status(path .. ".backup"), source, "verified backup data is retained")
				helpers.assert_eq(control.writes, 0); helpers.assert_eq(driver.regenerations, 0)
			end)
		end)
	end)

	helpers.it("keeps a changed forward source pending after native remap cleanup settles", function()
		with_owned_publication(function(path, fs, control, seed)
			with_native_remap(path, fs, control, seed, function(remap)
				helpers.assert_eq(remap.apply_scope({ scope = "tap_holds", mode = "clear", backup_path = path .. ".backup" }), false)
				local candidate = assert(fs.read_with_status(path))
				seed(path, "foreign successor")
				control.blocked = false
				helpers.assert_eq(remap.retry_settings_recovery(), false)
				helpers.assert_eq(remap.settings_pending(), true)
				helpers.assert_eq(remap.retry_settings_recovery(), false)
				helpers.assert_eq(fs.read_with_status(path), "foreign successor")
				helpers.assert_eq(control.writes, 1, "a later writer's bytes are never replaced")
				seed(path, candidate)
				helpers.assert_eq(remap.retry_settings_recovery(), true)
			end)
		end)
	end)

	helpers.it("verifies the actual remap inverse after its retained native release without republishing", function()
		with_owned_publication(function(path, fs, control, seed)
			with_native_remap(path, fs, control, seed, function(remap, source, driver)
				control.blocked = false
				helpers.assert_eq(remap.apply_scope({ scope = "tap_holds", mode = "clear", backup_path = path .. ".backup" }), true)
				helpers.assert_eq(remap.get_tap_action("left_shift"), "none")
				control.blocked = true
				driver.terminals[1](false, "controlled-deploy-failure")
				helpers.assert_eq(remap.settings_pending(), true)
				helpers.assert_eq(fs.read_with_status(path), source, "the refused inverse really published its source")
				helpers.assert_eq(remap.get_tap_action("left_shift"), "none", "runtime compensation waits for native release")
				seed(path, "foreign successor")
				control.blocked = false
				helpers.assert_eq(remap.retry_settings_recovery(), false)
				helpers.assert_eq(remap.retry_settings_recovery(), false)
				helpers.assert_eq(fs.read_with_status(path), "foreign successor")
				helpers.assert_eq(control.writes, 2, "an already published inverse is never repeated")
				seed(path, source)
				helpers.assert_eq(remap.retry_settings_recovery(), false, "exact inverse regeneration still owns its terminal")
				helpers.assert_eq(remap.get_tap_action("left_shift"), "escape")
				helpers.assert_eq(driver.regenerations, 2)
				driver.terminals[2](true, "ready")
				helpers.assert_eq(remap.settings_pending(), false)
			end)
		end)
	end)

	helpers.it("retains a created remap inverse after unlink and verifies absence after native release", function()
		with_owned_publication(function(path, fs, control, seed)
			with_native_remap(path, fs, control, seed, function(remap)
				assert(os.remove(path))
				helpers.assert_eq(remap.apply_scope({ scope = "tap_holds", mode = "clear", backup_path = path .. ".backup" }), false)
				control.blocked = false
				control.after_close = function() control.blocked = true; control.after_close = nil end
				helpers.assert_eq(remap.retry_settings_recovery(), false, "the created source was removed but inverse native release remains owed")
				local _, status = fs.read_with_status(path)
				helpers.assert_eq(status, "absent")
				seed(path, "foreign successor")
				control.blocked = false
				helpers.assert_eq(remap.retry_settings_recovery(), false, "an exact unlink receipt does not prove current absence")
				helpers.assert_eq(remap.retry_settings_recovery(), false)
				helpers.assert_eq(fs.read_with_status(path), "foreign successor")
				assert(os.remove(path))
				helpers.assert_eq(remap.retry_settings_recovery(), true)
				helpers.assert_eq(remap.settings_pending(), false)
				helpers.assert_eq(control.writes, 1)
			end)
		end)
	end)

	helpers.it("retains explicit remap repair publication and restores its exact corrupt source", function()
		with_owned_publication(function(path, fs, control, seed)
			with_native_remap(path, fs, control, seed, function(remap)
				local corrupt = "[tap_holds\nrecoverable = true\n"
				seed(path, corrupt)
				helpers.assert_eq(remap.reset_to_defaults(), false)
				helpers.assert_eq(remap.settings_pending(), true)
				helpers.assert_true(fs.read_with_status(path) ~= corrupt, "explicit repair really published before native release refused")
				control.blocked = false
				helpers.assert_eq(remap.retry_settings_recovery(), true)
				helpers.assert_eq(fs.read_with_status(path), corrupt, "raw corrupt bytes are restored without requiring a decode")
				helpers.assert_eq(remap.get_tap_action("left_shift"), "escape")
			end)
		end)
	end)

	helpers.it("retains immediate remap unlink identity when its released source has an exact-byte successor", function()
		with_owned_publication(function(path, fs, control, seed)
			with_native_remap(path, fs, control, seed, function(remap)
				assert(os.remove(path))
				helpers.assert_eq(remap.apply_scope({ scope = "tap_holds", mode = "clear", backup_path = path .. ".backup" }), false)
				local candidate = assert(fs.read_with_status(path))
				local original_remove, inverse_phase, unlinks, closes = os.remove, false, 0, 0
				os.remove = function(name)
					if inverse_phase and name == path then unlinks = unlinks + 1 end
					return original_remove(name)
				end
				local called, detail = xpcall(function()
					control.blocked = false
					control.after_close = function()
						closes = closes + 1
						if closes == 1 then inverse_phase = true end
						if closes == 2 then seed(path, candidate); control.after_close = nil end
					end
					helpers.assert_eq(remap.retry_settings_recovery(), false, "immediate unlink acknowledgement must verify the Config inverse target")
					helpers.assert_eq(remap.settings_pending(), true)
					helpers.assert_eq(fs.read_with_status(path), candidate)
					helpers.assert_eq(unlinks, 1, "the original inverse really unlinked its exact source")
					helpers.assert_eq(remap.retry_settings_recovery(), false)
					helpers.assert_eq(unlinks, 1, "an acknowledged inverse cannot unlink a same-byte successor")
					helpers.assert_eq(fs.read_with_status(path), candidate)
					assert(original_remove(path))
					helpers.assert_eq(remap.retry_settings_recovery(), true)
					helpers.assert_eq(remap.settings_pending(), false)
				end, debug.traceback)
				os.remove = original_remove
				if not called then error(detail, 0) end
			end)
		end)
	end)

	for _, source_present in ipairs({ false, true }) do
		helpers.it("retains refused scalar setter publication with source_present=" .. tostring(source_present), function()
			with_owned_publication(function(path, fs, control, seed)
				with_native_remap(path, fs, control, seed, function(remap, source, driver)
					if not source_present then assert(os.remove(path)) end
					helpers.assert_eq(remap.set_tap_action("left_shift", "paste"), false)
					helpers.assert_eq(remap.settings_pending(), true, "the failed scalar setter retains its actual file effect")
					helpers.assert_eq(remap.get_tap_action("left_shift"), "escape")
					helpers.assert_eq(remap.retry_settings_recovery(), false)
					helpers.assert_eq(remap.set_hold_action("left_shift", "shift"), false)
					helpers.assert_eq(control.writes, 1)
					control.blocked = false
					helpers.assert_eq(remap.retry_settings_recovery(), true)
					local bytes, status = fs.read_with_status(path)
					helpers.assert_eq(status, source_present and "ok" or "absent")
					if source_present then helpers.assert_eq(bytes, source) end
					helpers.assert_eq(remap.get_tap_action("left_shift"), "escape")
					helpers.assert_eq(driver.regenerations, 0, "a refused setter never adopted or deployed its candidate")
				end)
			end)
		end)
	end

	helpers.it("does not replace a successor when a scalar setter's inverse release settles", function()
		with_owned_publication(function(path, fs, control, seed)
			with_native_remap(path, fs, control, seed, function(remap, source)
				helpers.assert_eq(remap.set_tap_action("left_shift", "paste"), false)
				control.blocked = false
				control.after_close = function() control.blocked = true; control.after_close = nil end
				helpers.assert_eq(remap.retry_settings_recovery(), false)
				helpers.assert_eq(fs.read_with_status(path), source)
				seed(path, "foreign setter successor")
				control.blocked = false
				helpers.assert_eq(remap.retry_settings_recovery(), false)
				helpers.assert_eq(remap.settings_pending(), true)
				helpers.assert_eq(remap.set_tap_action("left_shift", "copy"), false)
				helpers.assert_eq(fs.read_with_status(path), "foreign setter successor")
				helpers.assert_eq(control.writes, 2, "inverse cleanup cannot republish an already restored source")
				seed(path, source)
				helpers.assert_eq(remap.retry_settings_recovery(), true)
			end)
		end)
	end)

	--- Uses the actual serializer and classified file port before the remap
	--- facade has any runtime state. Only its lifecycle/data/fcntl ports are controlled.
	local function with_native_detached(path, fs, control, seed, body)
		require("tests.support.remap_transaction_fixture")(function(fixture)
			local remap, calls = fixture.load_enabled_remap({ skip_init = true })
			local configured = package.loaded["platform.remap.config"]
			configured.build_default_state = function()
				return { tap_holds_enabled = false, tap_hold_config = { left_shift = { tap = "none", hold = "none" } },
					mod_combos_config = {}, tap_hold_timeout_ms = 200, sticky_timeout_ms = 1000,
					simultaneous_threshold_ms = 50, combo_symmetric = false }
			end
			package.loaded["platform.remap.defaults"].tap_hold = { left_shift = { "escape", "none" } }
			package.loaded["infra.config_paths"].get = function() return path end
			local captured_files = require("adapters.file_system")
			for _, method in ipairs({ "read_with_status", "write_if_unchanged", "write", "remove_if_unchanged", "remove_exact" }) do
				captured_files[method] = fs[method]
			end
			package.loaded["adapters.file_system"] = fs
			package.loaded["platform.remap.config"] = nil
			local actual = helpers.load_with_stubs("platform.remap.config")
			configured.save_user_config, configured.load_user_config = actual.save_user_config, actual.load_user_config
			package.loaded["platform.remap.config"] = configured
			body(remap, calls)
		end)
	end

	for _, phase in ipairs({ "created", "replaced", "backup", "no-effect" }) do
		helpers.it("retains detached wizard " .. phase .. " native publication debt before init", function()
			with_owned_publication(function(path, fs, control, seed)
				with_native_detached(path, fs, control, seed, function(remap, calls)
					local source = "[custom]\nkeep = 19\n[karabiner]\nintegration_enabled = false\n"
					if phase ~= "created" then seed(path, source) end
					if phase == "backup" then control.target = path .. ".backup" end
					if phase == "no-effect" then control.refuse_rename = true end
					local request = { keys = { "left_shift" }, path = path, backup_path = path .. ".backup" }
					helpers.assert_eq(remap.save_recommended_keys(request), false)
					helpers.assert_eq(remap.has_pending_settings_save(), true, "a detached refusal retains its private owner")
					helpers.assert_eq(remap.is_running(), false)
					helpers.assert_eq(remap.retry_settings_recovery(), false)
					helpers.assert_eq(remap.save_recommended_keys(request), false)
					helpers.assert_eq(remap.init({ expand_path = function(value) return value end }), false, "init cannot adopt unacknowledged file bytes")
					helpers.assert_eq(calls.lease_init, 0)
					if phase == "no-effect" then seed(path, "foreign detached successor") end
					control.blocked = false
					helpers.assert_eq(remap.retry_settings_recovery(), true)
					helpers.assert_eq(remap.settings_pending(), false)
					local bytes, status = fs.read_with_status(path)
					helpers.assert_eq(status, phase == "created" and "absent" or "ok")
					if phase ~= "created" then
						helpers.assert_eq(bytes, phase == "no-effect" and "foreign detached successor" or source)
						helpers.assert_eq(fs.read_with_status(path .. ".backup"), source, "verified wizard backup data survives cleanup")
					end
					local writes, unlocks = control.writes, control.unlocks
					helpers.assert_eq(remap.retry_settings_recovery(), true)
					helpers.assert_eq(control.writes, writes); helpers.assert_eq(control.unlocks, unlocks)
				end)
			end)
		end)
	end

end)
