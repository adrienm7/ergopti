--- tests/unit/adapters/file_system/test_observed_symlink_paths.lua

--- ==============================================================================
--- MODULE: FileSystem Observed Symlink Paths Regression
--- DESCRIPTION:
--- Preserves the filesystem transaction contract at its owning boundary.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.file_system_transaction_fixture").with_fixture

helpers.describe("adapters.file_system: write() preserves observed symlink paths (F-MED-16)", function()
	local SYMLINK_PATH = os.tmpname()
	local REAL_TARGET  = os.tmpname()

	helpers.it("writes land on the resolved real target, not a new file at the symlink path", function()
		with_fixture(function(fixture)
			os.remove(SYMLINK_PATH)
			os.remove(REAL_TARGET)

			-- Hammerspoon's symlinkAttributes() adds the realpath result as `.target`
			-- for an existing link whose target exists.
			local adapter = fixture.make_adapter({ [SYMLINK_PATH] = REAL_TARGET })

			local ok = adapter.write(SYMLINK_PATH, "deployed via symlink")
			helpers.assert_true(ok, "write() must succeed when the destination resolves through a symlink")

			local real_fh = io.open(REAL_TARGET, "r")
			helpers.assert_true(real_fh ~= nil, "the RESOLVED real target must contain the written content")
			local content = real_fh:read("*a"); real_fh:close()
			helpers.assert_eq(content, "deployed via symlink")

			-- Critically: no NEW plain file must have been created directly at the
			-- symlink path itself — that would mean the rename replaced the symlink.
			local symlink_path_fh = io.open(SYMLINK_PATH, "r")
			helpers.assert_true(symlink_path_fh == nil,
				"write() must NOT create a plain file at the symlink path — that would destroy the symlink")
			if symlink_path_fh then symlink_path_fh:close() end

			os.remove(SYMLINK_PATH)
			os.remove(REAL_TARGET)
		end)
	end)

	helpers.it("resolves dot-dot after a preceding symlink with POSIX ordering", function()
		with_fixture(function(fixture)
			local request_root = os.tmpname():gsub("\\", "/")
			local target_root = os.tmpname():gsub("\\", "/")
			local target_subdirectory = target_root .. "/sub"
			local link_path = request_root .. "/link"
			local requested_path = link_path .. "/../karabiner.json"
			local kernel_target = target_root .. "/karabiner.json"
			local lexically_collapsed_target = request_root .. "/karabiner.json"
			local staging_locks = {}
			local write_ok = nil
			local kernel_content = nil
			local collapsed_content = nil
			local call_ok, call_err = xpcall(function()
				os.remove(request_root)
				os.remove(target_root)
				assert(fixture.HOST_MKDIR(request_root))
				assert(fixture.HOST_MKDIR(target_root))
				assert(fixture.HOST_MKDIR(target_subdirectory))
				local adapter = nil
				adapter, staging_locks = fixture.make_adapter({ [link_path] = target_subdirectory })
				write_ok = adapter.write(requested_path, "posix symlink ordering")

				local function read_all(path)
					local fh = io.open(path, "r")
					if not fh then return nil end
					local content = fh:read("*a")
					fh:close()
					return content
				end
				kernel_content = read_all(kernel_target)
				collapsed_content = read_all(lexically_collapsed_target)
			end, debug.traceback)
			os.remove(kernel_target)
			os.remove(lexically_collapsed_target)
			for lock_path in pairs(staging_locks) do
				os.remove(lock_path .. "/payload")
				fixture.HOST_RMDIR(lock_path)
			end
			fixture.HOST_RMDIR(target_subdirectory)
			fixture.HOST_RMDIR(target_root)
			fixture.HOST_RMDIR(request_root)
			if not call_ok then error(call_err) end

			helpers.assert_true(write_ok, "the legitimate dot-dot destination must remain writable")
			helpers.assert_eq(kernel_content, "posix symlink ordering",
				"dot-dot must apply to the symlink target, as the kernel resolves it")
			helpers.assert_nil(collapsed_content,
				"lexical normalization must not bypass the preceding symlink")
		end)
	end)

	helpers.it("fails before staging when a dangling final symlink has no readable target", function()
		with_fixture(function(fixture)
			local symlink_path = os.tmpname():gsub("\\", "/")
			os.remove(symlink_path)
			local adapter = fixture.make_adapter({ [symlink_path] = { mode = "link" } })
			local original_open = io.open
			local original_rename = os.rename
			local staging_opens = 0
			local rename_calls = 0
			io.open = function(path, mode)
				if mode == "w" then staging_opens = staging_opens + 1 end
				return original_open(path, mode)
			end
			os.rename = function(old_path, new_path)
				if old_path ~= new_path then rename_calls = rename_calls + 1 end
				return original_rename(old_path, new_path)
			end
			local call_ok, write_ok = xpcall(function()
				return adapter.write(symlink_path, "must not replace link")
			end, debug.traceback)
			io.open = original_open
			os.rename = original_rename
			if not call_ok then error(write_ok) end

			helpers.assert_eq(write_ok, false,
				"without a readlink target, replacing the dangling link would be unsafe")
			helpers.assert_eq(staging_opens, 0, "an unresolved dangling link must fail before staging")
			helpers.assert_eq(rename_calls, 0, "an unresolved dangling link must fail before publication")
			local link_path_fh = original_open(symlink_path, "r")
			helpers.assert_nil(link_path_fh, "the dangling symlink pathname must not become a regular file")
			if link_path_fh then link_path_fh:close() end
			os.remove(symlink_path)
		end)
	end)

	helpers.it("revalidates a symlinked config directory while the final file is absent", function()
		with_fixture(function(fixture)
			local unique = os.tmpname():gsub("\\", "/"):match("([^/]+)$")
			local virtual_parent = "ergopti-parent-link-" .. unique
			local file_name = "karabiner-" .. unique .. ".json"
			local first_directory = os.tmpname():gsub("\\", "/")
			local second_directory = os.tmpname():gsub("\\", "/")
			os.remove(first_directory)
			os.remove(second_directory)
			assert(fixture.HOST_MKDIR(first_directory))
			assert(fixture.HOST_MKDIR(second_directory))
			local first_target = first_directory .. "/" .. file_name
			local second_target = second_directory .. "/" .. file_name
			local current_parent_target = first_directory
			local adapter, staging_locks = fixture.make_adapter({
				[virtual_parent] = function() return current_parent_target end,
			})
			local original_rename = os.rename
			os.remove(first_target)
			os.remove(second_target)

			os.rename = function(old_path, new_path)
				local renamed, rename_err, rename_code = original_rename(old_path, new_path)
				if renamed and new_path == first_target then current_parent_target = second_directory end
				return renamed, rename_err, rename_code
			end
			local write_ok = nil
			local call_ok, call_err = xpcall(function()
				write_ok = adapter.write(virtual_parent .. "/" .. file_name, "prior-directory-target")
			end, debug.traceback)
			os.rename = original_rename
			if not call_ok then error(call_err) end

			helpers.assert_eq(write_ok, false,
				"retargeting the official directory-symlink layout must not return success")
			local old_target_fh = io.open(first_target, "r")
			helpers.assert_true(old_target_fh ~= nil,
				"content already published before the retarget must remain recoverable")
			local old_content = old_target_fh:read("*a")
			old_target_fh:close()
			helpers.assert_eq(old_content, "prior-directory-target")
			local new_target_fh = io.open(second_target, "r")
			helpers.assert_nil(new_target_fh, "the newly selected directory must remain untouched")
			if new_target_fh then new_target_fh:close() end
			os.remove(first_target)
			os.remove(second_target)
			for lock_path in pairs(staging_locks) do fixture.HOST_RMDIR(lock_path) end
			fixture.HOST_RMDIR(first_directory)
			fixture.HOST_RMDIR(second_directory)
		end)
	end)

	helpers.it("returns false if the symlink retargets inside publication", function()
		with_fixture(function(fixture)
			local symlink_path = os.tmpname():gsub("\\", "/")
			local parent = assert(symlink_path:match("^(.+)/[^/]+$"))
			local first_name = "ergopti-write-old-target-" .. symlink_path:match("([^/]+)$")
			local second_name = "ergopti-write-new-target-" .. symlink_path:match("([^/]+)$")
			local first_target = parent .. "/" .. first_name
			local second_target = parent .. "/" .. second_name
			local current_target = first_target
			local adapter, staging_locks = fixture.make_adapter({
				[symlink_path] = function() return current_target end,
			})
			local original_rename = os.rename
			os.remove(symlink_path)
			os.remove(first_target)
			os.remove(second_target)

			os.rename = function(old_path, new_path)
				local renamed, rename_err, rename_code = original_rename(old_path, new_path)
				if renamed and new_path == first_target then current_target = second_target end
				return renamed, rename_err, rename_code
			end
			local write_ok = nil
			local call_ok, call_err = xpcall(function()
				write_ok = adapter.write(symlink_path, "managed-on-prior-target")
			end, debug.traceback)
			os.rename = original_rename
			if not call_ok then error(call_err) end

			helpers.assert_eq(write_ok, false, "write() must not report success for a now-unreachable old target")
			local old_target_fh = io.open(first_target, "r")
			helpers.assert_true(old_target_fh ~= nil, "the already-published old target must remain recoverable")
			local old_content = old_target_fh:read("*a")
			old_target_fh:close()
			helpers.assert_eq(old_content, "managed-on-prior-target")
			local new_target_fh = io.open(second_target, "r")
			helpers.assert_nil(new_target_fh, "the new target remains untouched for the caller's retry")
			if new_target_fh then new_target_fh:close() end
			for lock_path in pairs(staging_locks) do fixture.HOST_RMDIR(lock_path) end
			os.remove(symlink_path)
			os.remove(first_target)
			os.remove(second_target)
		end)
	end)

	helpers.it("preserves a foreign payload if the symlink retargets immediately after publication", function()
		with_fixture(function(fixture)
			local symlink_path = os.tmpname():gsub("\\", "/")
			local first_target = os.tmpname():gsub("\\", "/")
			local second_target = os.tmpname():gsub("\\", "/")
			local current_target = first_target
			local adapter, staging_locks = fixture.make_adapter({
				[symlink_path] = function() return current_target end,
			})
			local original_open = io.open
			local original_rename = os.rename
			local staged_payload = nil
			os.remove(symlink_path)
			os.remove(first_target)
			os.remove(second_target)

			os.rename = function(old_path, new_path)
				local renamed, rename_err, rename_code = original_rename(old_path, new_path)
				if renamed and new_path == first_target then
					staged_payload = old_path
					current_target = second_target
					local foreign = assert(original_open(old_path, "w"))
					foreign:write("foreign payload bytes")
					foreign:close()
				end
				return renamed, rename_err, rename_code
			end
			local call_ok, write_ok = xpcall(function()
				return adapter.write(symlink_path, "published before retarget")
			end, debug.traceback)
			os.rename = original_rename
			if not call_ok then error(write_ok) end

			helpers.assert_eq(write_ok, false, "a post-publication retarget must remain visible to the caller")
			helpers.assert_type(staged_payload, "string", "the publication hook must observe the payload pathname")
			local foreign = staged_payload and original_open(staged_payload, "r") or nil
			helpers.assert_true(foreign ~= nil,
				"cleanup must never remove a payload pathname after rename has published ours")
			local foreign_content = foreign and foreign:read("*a") or nil
			if foreign then foreign:close() end
			helpers.assert_eq(foreign_content, "foreign payload bytes",
				"bytes placed at the old pathname by another owner must survive")
			local lock_path = staged_payload and staged_payload:match("^(.*)/payload$") or nil
			helpers.assert_eq(staging_locks[lock_path], true,
				"a changed resolution chain must preserve the staging sidecar instead of deleting through it")
			local published = original_open(first_target, "r")
			helpers.assert_true(published ~= nil, "the already-published content must remain recoverable")
			local published_content = published and published:read("*a") or nil
			if published then published:close() end
			helpers.assert_eq(published_content, "published before retarget")
			local new_target = original_open(second_target, "r")
			helpers.assert_nil(new_target, "the new symlink target must remain untouched")
			if new_target then new_target:close() end
			if staged_payload then os.remove(staged_payload) end
			if lock_path then fixture.HOST_RMDIR(lock_path) end
			os.remove(symlink_path)
			os.remove(first_target)
			os.remove(second_target)
		end)
	end)

	helpers.it("preserves a foreign payload if the symlink retargets before failure cleanup", function()
		with_fixture(function(fixture)
			local symlink_path = os.tmpname():gsub("\\", "/")
			local first_target = os.tmpname():gsub("\\", "/")
			local second_target = os.tmpname():gsub("\\", "/")
			local current_target = first_target
			local adapter, staging_locks = fixture.make_adapter({
				[symlink_path] = function() return current_target end,
			})
			local original_open = io.open
			local staged_payload = nil
			os.remove(symlink_path)
			os.remove(first_target)
			os.remove(second_target)

			io.open = function(open_path, mode)
				if mode == "w" and open_path:match("/payload$") then
					staged_payload = open_path
					local raw_handle = assert(original_open(open_path, mode))
					local handle = {}
					handle.write = function(_, bytes) return raw_handle:write(bytes) and handle end
					handle.close = function()
						raw_handle:close()
						current_target = second_target
						local foreign = assert(original_open(open_path, "w"))
						foreign:write("foreign pre-cleanup bytes")
						foreign:close()
						return false, "injected close refusal after retarget"
					end
					return handle
				end
				return original_open(open_path, mode)
			end
			local call_ok, write_ok = xpcall(function()
				return adapter.write(symlink_path, "managed bytes")
			end, debug.traceback)
			io.open = original_open
			if not call_ok then error(write_ok) end

			helpers.assert_eq(write_ok, false, "the injected close failure must reject publication")
			local foreign = staged_payload and original_open(staged_payload, "r") or nil
			helpers.assert_true(foreign ~= nil,
				"failure cleanup must preserve the payload when the resolution chain changed")
			local foreign_content = foreign and foreign:read("*a") or nil
			if foreign then foreign:close() end
			helpers.assert_eq(foreign_content, "foreign pre-cleanup bytes",
				"failure cleanup must not unlink bytes at a pathname it can no longer prove owned")
			local lock_path = staged_payload and staged_payload:match("^(.*)/payload$") or nil
			helpers.assert_eq(staging_locks[lock_path], true,
				"the ownership sidecar must remain when failure cleanup cannot revalidate its path")
			local first = original_open(first_target, "r")
			helpers.assert_nil(first, "a close failure must not publish to the original target")
			if first then first:close() end
			local second = original_open(second_target, "r")
			helpers.assert_nil(second, "a close failure must not publish to the new target")
			if second then second:close() end
			if staged_payload then os.remove(staged_payload) end
			if lock_path then fixture.HOST_RMDIR(lock_path) end
			os.remove(symlink_path)
			os.remove(first_target)
			os.remove(second_target)
		end)
	end)

	helpers.it("fails closed when lstat cannot inspect the final destination", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local original_open = io.open
			local original_rename = os.rename
			os.remove(path)
			local seed = assert(original_open(path, "w"))
			seed:write("live destination bytes")
			seed:close()
			local adapter = fixture.make_adapter(nil, { [path] = true })
			local staging_opens = 0
			local rename_calls = 0

			io.open = function(open_path, mode)
				if mode == "w" then staging_opens = staging_opens + 1 end
				return original_open(open_path, mode)
			end
			os.rename = function(old_path, new_path)
				if old_path ~= new_path then rename_calls = rename_calls + 1 end
				return original_rename(old_path, new_path)
			end
			local call_ok, write_ok = xpcall(function()
				return adapter.write(path, "must not publish")
			end, debug.traceback)
			io.open = original_open
			os.rename = original_rename
			if not call_ok then error(write_ok) end

			helpers.assert_eq(write_ok, false, "an unknown final pathname is not proven absent")
			helpers.assert_eq(staging_opens, 0, "resolution failure must precede every staging write")
			helpers.assert_eq(rename_calls, 0, "resolution failure must precede publication")
			local live = assert(original_open(path, "r"))
			helpers.assert_eq(live:read("*a"), "live destination bytes",
				"an lstat failure must leave the live destination untouched")
			live:close()
			os.remove(path)
		end)
	end)

	helpers.it("fails closed when lstat cannot inspect an intermediate symlink", function()
		with_fixture(function(fixture)
			local virtual_parent_seed = os.tmpname():gsub("\\", "/")
			os.remove(virtual_parent_seed)
			local virtual_parent = virtual_parent_seed .. ".ergopti-lstat-link"
			local real_target = os.tmpname():gsub("\\", "/")
			local link_target, file_name = fixture.split_parent(real_target)
			local requested_path = virtual_parent .. "/" .. file_name
			local original_open = io.open
			local original_rename = os.rename
			local body_ok, body_err = xpcall(function()
				os.remove(requested_path)
				os.remove(real_target)
				fixture.HOST_RMDIR(virtual_parent)
				assert(fixture.HOST_MKDIR(virtual_parent))
				local seed = assert(original_open(real_target, "w"))
				seed:write("live symlink target bytes")
				seed:close()
				local adapter = fixture.make_adapter({
					[virtual_parent] = function() return link_target end,
				}, { [virtual_parent] = true }, { [requested_path] = true })
				local staging_opens = 0
				local rename_calls = 0

				io.open = function(open_path, mode)
					if mode == "w" then staging_opens = staging_opens + 1 end
					return original_open(open_path, mode)
				end
				os.rename = function(old_path, new_path)
					if old_path ~= new_path then rename_calls = rename_calls + 1 end
					return original_rename(old_path, new_path)
				end
				local write_ok = adapter.write(requested_path, "must not publish")

				helpers.assert_eq(write_ok, false, "an unreadable intermediate component is not absent")
				helpers.assert_eq(staging_opens, 0, "component resolution must precede every staging write")
				helpers.assert_eq(rename_calls, 0, "component resolution must precede publication")
				helpers.assert_type(link_target, "string", "the simulated absolute symlink target must remain available")
				local live = assert(original_open(real_target, "r"))
				helpers.assert_eq(live:read("*a"), "live symlink target bytes",
					"an intermediate lstat failure must leave the live target untouched")
				live:close()
			end, debug.traceback)
			io.open = original_open
			os.rename = original_rename
			os.remove(requested_path)
			os.remove(real_target)
			local removed, remove_err = fixture.HOST_RMDIR(virtual_parent)
			local cleanup_ok = removed == true or fixture.HOST_ATTRIBUTES(virtual_parent) == nil
			if not body_ok then
				if not cleanup_ok then
					error(body_err .. "\nfixture cleanup failed: " .. tostring(remove_err))
				end
				error(body_err)
			end
			helpers.assert_true(cleanup_ok, "fixture directory cleanup must succeed: " .. tostring(remove_err))
		end)
	end)
end)
