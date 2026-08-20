--- tests/unit/adapters/test_file_system_atomic_write.lua

--- ==============================================================================
--- MODULE: FileSystem Adapter — Atomic Write Regression (F-MED-16)
--- DESCRIPTION:
--- Guards the fix for F-MED-16: adapters.file_system.write() used a direct
--- io.open(path, "w") write with no temp-file-then-rename step, unlike the
--- sibling karabiner/config.lua's save_user_config(), which correctly writes
--- via a ".tmp" file and os.rename(). karabiner.json is the single most
--- important file this adapter writes (deploy_string -> FileSystem.write in
--- karabiner/generator.lua); a crash mid-write could leave Karabiner-Elements'
--- own FSEvents watcher picking up a torn/truncated config.
---
--- Coverage:
---   1. write() creates a real, complete file (behavioral, real I/O).
---   2. write() releases its dynamic staging payload and ownership lock.
---   3. write() preserves a pre-existing symlink: writing through that path
---      replaces the REAL target file's content, and the symlink itself
---      survives (renaming directly over a symlink path would replace it with a
---      plain file, breaking deploy_string's documented symlink support).
--- ==============================================================================

local helpers = require("tests.helpers")
local STAGING_LOCK_SUFFIX = ".ergoptiplus-stage-lock"
local WRITE_LOCK_SUFFIX = ".ergoptiplus-write-lock-v1"
local HOST_ATTRIBUTES = hs.fs.attributes
local HOST_SYMLINK_ATTRIBUTES = hs.fs.symlinkAttributes
local HOST_MKDIR = hs.fs.mkdir
local HOST_RMDIR = hs.fs.rmdir

local function make_directory_iterator(entries)
	local index = 0
	local directory_state = {}
	return function(state)
		helpers.assert_eq(state, directory_state, "hs.fs.dir iterator state must be forwarded")
		index = index + 1
		return entries[index]
	end, directory_state
end

local function split_parent(path)
	local parent, basename = path:match("^(.+)/([^/]+)$")
	if parent == nil then return ".", path end
	if parent:match("^%a:$") then parent = parent .. "/" end
	return parent, basename
end

-- Real I/O, mirroring the existing FileSystem contract-vector test: stub only
-- the filesystem primitives needed to model lstat, listing, and atomic staging
-- without a live Hammerspoon runtime.
-- @param symlink_targets table|nil Optional final-link targets returned by lstat.
-- @param lstat_failures table|nil Optional paths whose lstat probe must throw.
-- @param confirmed_absences table|nil Optional paths absent from their listed parent.
local function make_adapter(symlink_targets, lstat_failures, confirmed_absences, link_override,
		lock_override, unlock_override, mkdir_override)
	local staging_locks = {}
	package.loaded["adapters.file_system"] = nil
	package.loaded["infra.fs_dir"] = nil
	local adapter = helpers.load_with_stubs("adapters.file_system", {
		fs = {
			dir = function(parent)
				local listed_parent = parent
				local target = type(symlink_targets) == "table" and symlink_targets[parent]
				if type(target) == "function" then target = target(parent) end
				if type(target) == "string" then listed_parent = target end
				if type(target) == "table" and type(target.target) == "string" then
					listed_parent = target.target
				end
				local parent_attributes = HOST_ATTRIBUTES(listed_parent)
				if type(parent_attributes) ~= "table" or parent_attributes.mode ~= "directory" then
					error("cannot list missing fixture parent " .. parent)
				end
				local entries = {}
				for failed_path in pairs(lstat_failures or {}) do
					local failed_parent, basename = split_parent(failed_path)
					if failed_parent == parent then entries[#entries + 1] = basename end
				end
				return make_directory_iterator(entries)
			end,
			attributes = function(path)
				if staging_locks[path] then return { mode = "directory" } end
				return HOST_ATTRIBUTES(path)
			end,
			symlinkAttributes = function(path)
				if type(lstat_failures) == "table" and lstat_failures[path] then
					error("injected lstat failure for " .. path)
				end
				if type(confirmed_absences) == "table" and confirmed_absences[path] then
					return nil, "injected missing path"
				end
				if staging_locks[path] then return { mode = "directory" } end
				local target = type(symlink_targets) == "table" and symlink_targets[path]
				if type(target) == "function" then target = target(path) end
				if type(target) == "string" then return { mode = "link", target = target } end
				if type(target) == "table" then return target end
				local attributes, attributes_err = HOST_SYMLINK_ATTRIBUTES(path)
				if type(attributes) == "table" then return attributes end
				attributes = HOST_ATTRIBUTES(path)
				if type(attributes) == "table" then return attributes end
				-- Stock Windows Lua cannot lstat a zero-byte file while another
				-- fixture handle owns it. Model the stable lock inode explicitly so
				-- contention reaches the injected fcntl primitive, as it does on macOS.
				if path:sub(-#WRITE_LOCK_SUFFIX) == WRITE_LOCK_SUFFIX then
					return { mode = "file" }
				end
				return nil, attributes_err or "lstat failed"
			end,
			mkdir = function(path)
				if path:sub(-#STAGING_LOCK_SUFFIX) ~= STAGING_LOCK_SUFFIX then
					if type(mkdir_override) == "function" then return mkdir_override(path) end
					return HOST_MKDIR(path)
				end
				if staging_locks[path] then return nil, "File exists" end
				local created, create_err = HOST_MKDIR(path)
				if created ~= true then return created, create_err end
				staging_locks[path] = true
				return true
			end,
			rmdir = function(path)
				if not staging_locks[path] then return nil, "No such directory" end
				local removed, remove_err = HOST_RMDIR(path)
				if removed ~= true then return removed, remove_err end
				staging_locks[path] = nil
				return true
			end,
			link = link_override,
			lock = lock_override or function() return true end,
			unlock = unlock_override or function() return true end,
		},
	})
	return adapter, staging_locks
end





-- =====================================================
-- =====================================================
-- ======= 0/ Classified reads + create-only ===========
-- =====================================================
-- =====================================================

helpers.describe("adapters.file_system: classified reads and create-only publication", function()
	helpers.it("distinguishes a proven absent file from unsafe lookups", function()
		local root = os.tmpname():gsub("\\", "/") .. "_classified"
		local absent = root .. "/absent.toml"
		local dangling = root .. "/dangling.toml"
		local target = root .. "/missing-target.toml"
		local inaccessible = root .. "/locked.toml"
		local missing_parent = root .. "/missing/config.toml"
		local directory = root .. "/directory"
		HOST_MKDIR(root)
		HOST_MKDIR(directory)

		local adapter = make_adapter({
			[dangling] = target,
		}, {
			[inaccessible] = true,
		}, {
			[absent] = true,
			[target] = true,
			[root .. "/missing"] = true,
		})

		local content, status = adapter.read_with_status(absent)
		helpers.assert_nil(content)
		helpers.assert_eq(status, "absent", "only a listed final-name absence may be classified absent")

		content, status = adapter.read_with_status(dangling)
		helpers.assert_nil(content)
		helpers.assert_eq(status, "error", "a dangling symlink must never be classified absent")

		content, status = adapter.read_with_status(directory)
		helpers.assert_nil(content)
		helpers.assert_eq(status, "error", "a directory at the requested pathname is not absence")

		content, status = adapter.read_with_status(inaccessible)
		helpers.assert_nil(content)
		helpers.assert_eq(status, "error", "an lstat/EACCES-style failure is not absence")

		content, status = adapter.read_with_status(missing_parent)
		helpers.assert_nil(content)
		helpers.assert_eq(status, "error", "a missing path prefix is not a creatable final-name absence")

		HOST_RMDIR(directory)
		HOST_RMDIR(root)
	end)

	helpers.it("resolves dot-dot after an intermediate symlink before a classified read", function()
		local request_root = os.tmpname():gsub("\\", "/") .. "_read_request"
		local target_root = os.tmpname():gsub("\\", "/") .. "_read_target"
		local target_subdirectory = target_root .. "/sub"
		local link_path = request_root .. "/link"
		local requested_path = link_path .. "/../preferences.toml"
		local kernel_target = target_root .. "/preferences.toml"
		local lexically_collapsed_target = request_root .. "/preferences.toml"
		local content, status
		local call_ok, call_err = xpcall(function()
			os.remove(request_root)
			os.remove(target_root)
			assert(HOST_MKDIR(request_root))
			assert(HOST_MKDIR(target_root))
			assert(HOST_MKDIR(target_subdirectory))

			local kernel_file = assert(io.open(kernel_target, "w"))
			assert(kernel_file:write("kernel target")); assert(kernel_file:close())
			local collapsed_file = assert(io.open(lexically_collapsed_target, "w"))
			assert(collapsed_file:write("lexically collapsed target")); assert(collapsed_file:close())

			local adapter = make_adapter({ [link_path] = target_subdirectory })
			content, status = adapter.read_with_status(requested_path)
		end, debug.traceback)
		os.remove(kernel_target)
		os.remove(lexically_collapsed_target)
		HOST_RMDIR(target_subdirectory)
		HOST_RMDIR(target_root)
		HOST_RMDIR(request_root)
		if not call_ok then error(call_err) end

		helpers.assert_eq(status, "ok")
		helpers.assert_eq(content, "kernel target",
			"classified reads must apply dot-dot to the symlink target, not the link's parent")
	end)

	helpers.it("resolves dot-dot after an intermediate symlink before create-only publication", function()
		local request_root = os.tmpname():gsub("\\", "/") .. "_create_request"
		local target_root = os.tmpname():gsub("\\", "/") .. "_create_target"
		local target_subdirectory = target_root .. "/sub"
		local link_path = request_root .. "/link"
		local requested_path = link_path .. "/../personal_shortcuts.toml"
		local kernel_target = target_root .. "/personal_shortcuts.toml"
		local lexically_collapsed_target = request_root .. "/personal_shortcuts.toml"
		local staging_locks = {}
		local created, status, kernel_content, collapsed_content, published_path
		local call_ok, call_err = xpcall(function()
			os.remove(request_root)
			os.remove(target_root)
			assert(HOST_MKDIR(request_root))
			assert(HOST_MKDIR(target_root))
			assert(HOST_MKDIR(target_subdirectory))

			local collapsed_file = assert(io.open(lexically_collapsed_target, "w"))
			assert(collapsed_file:write("foreign collapsed file")); assert(collapsed_file:close())

			local adapter = nil
			adapter, staging_locks = make_adapter(
				{ [link_path] = target_subdirectory },
				nil,
				nil,
				function(source, destination, is_symlink)
					helpers.assert_eq(is_symlink, false)
					published_path = destination
					local source_file = assert(io.open(source, "r"))
					local payload = source_file:read("*a"); assert(source_file:close())
					local destination_file = assert(io.open(destination, "w"))
					assert(destination_file:write(payload)); assert(destination_file:close())
					return true
				end
			)
			created, status = adapter.create_if_absent(requested_path, "our defaults")

			local kernel_file = io.open(kernel_target, "r")
			if kernel_file then kernel_content = kernel_file:read("*a"); kernel_file:close() end
			local collapsed_read = assert(io.open(lexically_collapsed_target, "r"))
			collapsed_content = collapsed_read:read("*a"); collapsed_read:close()
		end, debug.traceback)
		os.remove(kernel_target)
		os.remove(lexically_collapsed_target)
		for lock_path in pairs(staging_locks) do
			os.remove(lock_path .. "/payload")
			HOST_RMDIR(lock_path)
		end
		HOST_RMDIR(target_subdirectory)
		HOST_RMDIR(target_root)
		HOST_RMDIR(request_root)
		if not call_ok then error(call_err) end

		helpers.assert_eq(created, true, "the POSIX destination is absent and must be creatable")
		helpers.assert_eq(status, "created")
		helpers.assert_eq(published_path, kernel_target,
			"create-only publication must target the symlink target's parent")
		helpers.assert_eq(kernel_content, "our defaults")
		helpers.assert_eq(collapsed_content, "foreign collapsed file",
			"the lexically collapsed sibling belongs to another pathname and must remain untouched")
	end)

	helpers.it("requires read and close to commit before returning ok", function()
		local path = os.tmpname():gsub("\\", "/")
		local seed = assert(io.open(path, "w")); seed:write("seed"); seed:close()
		local adapter = make_adapter({ [path] = { mode = "file" } })
		local original_open = io.open
		local close_calls = 0

		io.open = function(open_path, mode)
			if open_path == path and mode == "r" then
				return {
					read = function() return "complete" end,
					close = function() close_calls = close_calls + 1; return nil, "flush failed" end,
				}
			end
			return original_open(open_path, mode)
		end
		local call_ok, content, status = pcall(adapter.read_with_status, path)
		io.open = original_open
		os.remove(path)
		if not call_ok then error(content) end

		helpers.assert_nil(content)
		helpers.assert_eq(status, "error", "a failed close must not publish read content")
		helpers.assert_eq(close_calls, 1, "the read handle must be closed exactly once")
	end)

	helpers.it("rejects a regular file replaced after its bytes were read", function()
		local path = os.tmpname():gsub("\\", "/")
		local seed = assert(io.open(path, "w")); seed:write("old bytes"); seed:close()
		local probes = 0
		local adapter = make_adapter({
			[path] = function()
				probes = probes + 1
				if probes == 1 then return { mode = "file", dev = 7, ino = 11 } end
				return { mode = "file", dev = 7, ino = 12 }
			end,
		})

		local content, status, detail = adapter.read_with_status(path)
		helpers.assert_nil(content, "bytes from a replaced file must never be committed")
		helpers.assert_eq(status, "error")
		helpers.assert_true(type(detail) == "string" and detail:find("identity changed", 1, true) ~= nil,
			"the failure must identify the ordinary-file replacement race")
		os.remove(path)
	end)

	helpers.it("rejects removal of the ordinary target behind a stable symlink", function()
		local link_path = os.tmpname():gsub("\\", "/")
		local target_path = link_path .. ".target"
		local seed = assert(io.open(target_path, "w")); seed:write("target bytes"); seed:close()
		local target_probes = 0
		local adapter = make_adapter({
			[link_path] = { mode = "link", target = target_path, dev = 3, ino = 5 },
			[target_path] = function()
				target_probes = target_probes + 1
				if target_probes == 1 then return { mode = "file", dev = 7, ino = 11 } end
				os.remove(target_path)
				return nil
			end,
		}, nil, { [target_path] = function() return target_probes > 1 end })

		local content, status = adapter.read_with_status(link_path)
		helpers.assert_nil(content, "a removed symlink target must not commit stale handle bytes")
		helpers.assert_eq(status, "error", "target removal is not absence of the requested symlink")
		os.remove(target_path)
	end)

	helpers.it("does not overwrite a target created between absence proof and publication", function()
		local target = os.tmpname():gsub("\\", "/")
		os.remove(target)
		local confirmed_absences = { [target] = true }
		local link_calls = 0
		local adapter = make_adapter(nil, nil, confirmed_absences, function(_, destination, is_symlink)
			link_calls = link_calls + 1
			helpers.assert_eq(destination, target)
			helpers.assert_eq(is_symlink, false)
			confirmed_absences[target] = nil
			local foreign = assert(io.open(target, "w"))
			foreign:write("foreign winner")
			foreign:close()
			return nil, "File exists"
		end)

		local created, status = adapter.create_if_absent(target, "our defaults")
		helpers.assert_eq(created, false, "the losing creator must report that it did not publish")
		helpers.assert_eq(status, "exists", "a readable concurrent winner is an idempotent exists result")
		helpers.assert_eq(link_calls, 1, "publication must use one create-only hard-link operation")
		local fh = assert(io.open(target, "r"))
		local content = fh:read("*a"); fh:close()
		helpers.assert_eq(content, "foreign winner", "the concurrent winner must never be overwritten")
		os.remove(target)
	end)

	helpers.it("prepares multiple missing parent levels before classifying the final file absent", function()
		local root = os.tmpname():gsub("\\", "/") .. "_prepared_parent"
		local first = root .. "/.config"
		local second = first .. "/karabiner"
		local destination = second .. "/karabiner.json"
		local prepared, detail, content, status
		local call_ok, call_err = xpcall(function()
			os.remove(root)
			assert(HOST_MKDIR(root))
			local adapter = make_adapter()
			prepared, detail = adapter.prepare_parent_for_create(destination)
			content, status = adapter.read_with_status(destination)
		end, debug.traceback)
		HOST_RMDIR(second)
		HOST_RMDIR(first)
		HOST_RMDIR(root)
		if not call_ok then error(call_err) end

		helpers.assert_eq(prepared, true, tostring(detail))
		helpers.assert_nil(content)
		helpers.assert_eq(status, "absent",
			"only the final name may remain absent after parent preparation")
	end)

	helpers.it("fails closed when mkdir cannot create a missing parent", function()
		local root = os.tmpname():gsub("\\", "/") .. "_denied_parent"
		local denied_parent = root .. "/karabiner"
		local destination = denied_parent .. "/karabiner.json"
		os.remove(root)
		assert(HOST_MKDIR(root))
		local adapter = make_adapter(nil, nil, nil, nil, nil, nil, function(path)
			if path == denied_parent then return nil, "Permission denied" end
			return HOST_MKDIR(path)
		end)

		local prepared, detail = adapter.prepare_parent_for_create(destination)

		helpers.assert_eq(prepared, false)
		helpers.assert_true(type(detail) == "string" and detail:find("Permission denied", 1, true) ~= nil,
			"the exact mkdir refusal must remain visible")
		helpers.assert_nil(HOST_ATTRIBUTES(denied_parent),
			"a refused parent must not be reported or modelled as created")
		HOST_RMDIR(root)
	end)

	helpers.it("accepts a concurrent directory winner after mkdir reports File exists", function()
		local root = os.tmpname():gsub("\\", "/") .. "_parent_winner"
		local won_parent = root .. "/karabiner"
		local destination = won_parent .. "/karabiner.json"
		local mkdir_calls = 0
		local prepared, detail, content, status
		local call_ok, call_err = xpcall(function()
			os.remove(root)
			assert(HOST_MKDIR(root))
			local adapter = make_adapter(nil, nil, nil, nil, nil, nil, function(path)
				mkdir_calls = mkdir_calls + 1
				if path == won_parent then
					assert(HOST_MKDIR(path))
					return nil, "File exists"
				end
				return HOST_MKDIR(path)
			end)
			prepared, detail = adapter.prepare_parent_for_create(destination)
			content, status = adapter.read_with_status(destination)
		end, debug.traceback)
		HOST_RMDIR(won_parent)
		HOST_RMDIR(root)
		if not call_ok then error(call_err) end

		helpers.assert_eq(prepared, true, tostring(detail))
		helpers.assert_eq(mkdir_calls, 1,
			"the concurrent winner must be accepted without a second mkdir attempt")
		helpers.assert_nil(content)
		helpers.assert_eq(status, "absent",
			"the winner authorizes only the final classified-absence read")
	end)

	helpers.it("rejects a concurrent non-directory winner after mkdir reports File exists", function()
		local root = os.tmpname():gsub("\\", "/") .. "_parent_file_winner"
		local won_path = root .. "/karabiner"
		local destination = won_path .. "/karabiner.json"
		local prepared, detail
		local call_ok, call_err = xpcall(function()
			os.remove(root)
			assert(HOST_MKDIR(root))
			local adapter = make_adapter(nil, nil, nil, nil, nil, nil, function(path)
				if path == won_path then
					local winner = assert(io.open(path, "w"))
					assert(winner:write("foreign winner")); assert(winner:close())
					return nil, "File exists"
				end
				return HOST_MKDIR(path)
			end)
			prepared, detail = adapter.prepare_parent_for_create(destination)
		end, debug.traceback)
		os.remove(won_path)
		HOST_RMDIR(root)
		if not call_ok then error(call_err) end

		helpers.assert_eq(prepared, false)
		helpers.assert_true(type(detail) == "string" and detail:find("not a directory", 1, true) ~= nil,
			"a file or symlink winner must never authorize descendant creation")
	end)

	helpers.it("rejects a parent symlink retargeted during directory creation", function()
		local request_root = os.tmpname():gsub("\\", "/") .. "_prepare_request"
		local target_a = os.tmpname():gsub("\\", "/") .. "_prepare_target_a"
		local target_b = os.tmpname():gsub("\\", "/") .. "_prepare_target_b"
		local link_path = request_root .. "/karabiner-link"
		local created_parent_a = target_a .. "/karabiner"
		local untouched_parent_b = target_b .. "/karabiner"
		local destination = link_path .. "/karabiner/karabiner.json"
		local current_target = target_a
		local prepared, detail
		local call_ok, call_err = xpcall(function()
			os.remove(request_root)
			os.remove(target_a)
			os.remove(target_b)
			assert(HOST_MKDIR(request_root))
			assert(HOST_MKDIR(target_a))
			assert(HOST_MKDIR(target_b))
			local adapter = make_adapter({
				[link_path] = function()
					return { mode = "link", target = current_target, dev = 7, ino = 11 }
				end,
			}, nil, nil, nil, nil, nil, function(path)
				local created, create_err = HOST_MKDIR(path)
				if path == created_parent_a and created == true then current_target = target_b end
				return created, create_err
			end)
			prepared, detail = adapter.prepare_parent_for_create(destination)
		end, debug.traceback)
		HOST_RMDIR(created_parent_a)
		HOST_RMDIR(untouched_parent_b)
		HOST_RMDIR(target_a)
		HOST_RMDIR(target_b)
		HOST_RMDIR(request_root)
		if not call_ok then error(call_err) end

		helpers.assert_eq(prepared, false)
		helpers.assert_true(type(detail) == "string" and detail:find("symlink target changed", 1, true) ~= nil,
			"retargeting must invalidate the observed route")
		helpers.assert_nil(HOST_ATTRIBUTES(untouched_parent_b),
			"preparation must never follow the replacement target after the race")
	end)
end)





-- =====================================
-- =====================================
-- ======= 1/ Basic atomic write =======
-- =====================================
-- =====================================

helpers.describe("adapters.file_system: write() is atomic (F-MED-16)", function()
	local TMP = os.tmpname()

	helpers.it("revalidates an expected source after staging and before rename", function()
		local path = os.tmpname():gsub("\\", "/")
		local seed = assert(io.open(path, "w"))
		assert(seed:write("observed source"))
		assert(seed:close())
		local adapter = make_adapter()
		local original_open = io.open
		local original_rename = os.rename
		local renames = 0
		local foreign_edit_committed = false

		io.open = function(open_path, mode)
			local fh, open_err = original_open(open_path, mode)
			if fh and mode == "w"
					and open_path:find(STAGING_LOCK_SUFFIX .. "/payload", 1, true) then
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

	helpers.it("write() produces a complete, readable file", function()
		local adapter = make_adapter()
		os.remove(TMP)
		local ok = adapter.write(TMP, "atomic content")
		helpers.assert_true(ok, "write() must return true on success")
		local fh = io.open(TMP, "r")
		helpers.assert_true(fh ~= nil, "file must exist after write()")
		local content = fh:read("*a"); fh:close()
		helpers.assert_eq(content, "atomic content")
		os.remove(TMP)
	end)

	helpers.it("write() removes its dynamic staging payload and lock after success", function()
		local adapter, staging_locks = make_adapter()
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

	helpers.it("write() never unlinks the payload pathname after successful rename", function()
		local path = os.tmpname():gsub("\\", "/")
		local adapter, staging_locks = make_adapter()
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
		if lock_path then HOST_RMDIR(lock_path) end
		os.remove(path)
	end)

	helpers.it("write() overwrites existing content atomically (old content never partially visible)", function()
		local adapter = make_adapter()
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

	helpers.it("write() creates multiple missing parent levels under an existing ancestor", function()
		local ancestor = os.tmpname():gsub("\\", "/")
		os.remove(ancestor)
		assert(HOST_MKDIR(ancestor))
		local first_parent = ancestor .. "/missing-one"
		local second_parent = first_parent .. "/missing-two"
		local path = second_parent .. "/managed.json"
		local adapter = make_adapter()

		local write_ok = adapter.write(path, "complete nested bytes")

		helpers.assert_true(write_ok, "write() must retain its recursive parent-creation contract")
		local fh = io.open(path, "r")
		helpers.assert_true(fh ~= nil, "the nested destination must exist after a successful write")
		local content = fh and fh:read("*a") or nil
		if fh then fh:close() end
		helpers.assert_eq(content, "complete nested bytes", "the nested file must contain every byte")
		os.remove(path)
		HOST_RMDIR(second_parent)
		HOST_RMDIR(first_parent)
		HOST_RMDIR(ancestor)
	end)
end)




-- =====================================================
-- =====================================================
-- ======= 2/ Pre-existing symlink resolution ==========
-- =====================================================
-- =====================================================

-- Regression: renaming a temp file directly OVER a symlinked destination path
-- would replace the symlink itself with a plain file, breaking deploy_string's
-- documented "works for regular paths and Unix symlinks" contract for
-- karabiner.json (a common deployment where ~/.config/karabiner is itself a
-- symlink, or the file is manually symlinked elsewhere). write() must walk and
-- record every symlink component BEFORE deciding where to stage and rename the
-- temp file, so the write lands on the REAL target and the link is untouched.
helpers.describe("adapters.file_system: write() preserves observed symlink paths (F-MED-16)", function()
	local SYMLINK_PATH = os.tmpname()
	local REAL_TARGET  = os.tmpname()

	helpers.it("writes land on the resolved real target, not a new file at the symlink path", function()
		os.remove(SYMLINK_PATH)
		os.remove(REAL_TARGET)

		-- Hammerspoon's symlinkAttributes() adds the realpath result as `.target`
		-- for an existing link whose target exists.
		local adapter = make_adapter({ [SYMLINK_PATH] = REAL_TARGET })

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

	helpers.it("resolves dot-dot after a preceding symlink with POSIX ordering", function()
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
			assert(HOST_MKDIR(request_root))
			assert(HOST_MKDIR(target_root))
			assert(HOST_MKDIR(target_subdirectory))
			local adapter = nil
			adapter, staging_locks = make_adapter({ [link_path] = target_subdirectory })
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
			HOST_RMDIR(lock_path)
		end
		HOST_RMDIR(target_subdirectory)
		HOST_RMDIR(target_root)
		HOST_RMDIR(request_root)
		if not call_ok then error(call_err) end

		helpers.assert_true(write_ok, "the legitimate dot-dot destination must remain writable")
		helpers.assert_eq(kernel_content, "posix symlink ordering",
			"dot-dot must apply to the symlink target, as the kernel resolves it")
		helpers.assert_nil(collapsed_content,
			"lexical normalization must not bypass the preceding symlink")
	end)

	helpers.it("fails before staging when a dangling final symlink has no readable target", function()
		local symlink_path = os.tmpname():gsub("\\", "/")
		os.remove(symlink_path)
		local adapter = make_adapter({ [symlink_path] = { mode = "link" } })
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

	helpers.it("revalidates a symlinked config directory while the final file is absent", function()
		local unique = os.tmpname():gsub("\\", "/"):match("([^/]+)$")
		local virtual_parent = "ergopti-parent-link-" .. unique
		local file_name = "karabiner-" .. unique .. ".json"
		local first_directory = os.tmpname():gsub("\\", "/")
		local second_directory = os.tmpname():gsub("\\", "/")
		os.remove(first_directory)
		os.remove(second_directory)
		assert(HOST_MKDIR(first_directory))
		assert(HOST_MKDIR(second_directory))
		local first_target = first_directory .. "/" .. file_name
		local second_target = second_directory .. "/" .. file_name
		local current_parent_target = first_directory
		local adapter, staging_locks = make_adapter({
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
		for lock_path in pairs(staging_locks) do HOST_RMDIR(lock_path) end
		HOST_RMDIR(first_directory)
		HOST_RMDIR(second_directory)
	end)

	helpers.it("returns false if the symlink retargets inside publication", function()
		local symlink_path = os.tmpname():gsub("\\", "/")
		local parent = assert(symlink_path:match("^(.+)/[^/]+$"))
		local first_name = "ergopti-write-old-target-" .. symlink_path:match("([^/]+)$")
		local second_name = "ergopti-write-new-target-" .. symlink_path:match("([^/]+)$")
		local first_target = parent .. "/" .. first_name
		local second_target = parent .. "/" .. second_name
		local current_target = first_target
		local adapter, staging_locks = make_adapter({
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
		for lock_path in pairs(staging_locks) do HOST_RMDIR(lock_path) end
		os.remove(symlink_path)
		os.remove(first_target)
		os.remove(second_target)
	end)

	helpers.it("preserves a foreign payload if the symlink retargets immediately after publication", function()
		local symlink_path = os.tmpname():gsub("\\", "/")
		local first_target = os.tmpname():gsub("\\", "/")
		local second_target = os.tmpname():gsub("\\", "/")
		local current_target = first_target
		local adapter, staging_locks = make_adapter({
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
		if lock_path then HOST_RMDIR(lock_path) end
		os.remove(symlink_path)
		os.remove(first_target)
		os.remove(second_target)
	end)

	helpers.it("preserves a foreign payload if the symlink retargets before failure cleanup", function()
		local symlink_path = os.tmpname():gsub("\\", "/")
		local first_target = os.tmpname():gsub("\\", "/")
		local second_target = os.tmpname():gsub("\\", "/")
		local current_target = first_target
		local adapter, staging_locks = make_adapter({
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
		if lock_path then HOST_RMDIR(lock_path) end
		os.remove(symlink_path)
		os.remove(first_target)
		os.remove(second_target)
	end)

	helpers.it("fails closed when lstat cannot inspect the final destination", function()
		local path = os.tmpname():gsub("\\", "/")
		local original_open = io.open
		local original_rename = os.rename
		os.remove(path)
		local seed = assert(original_open(path, "w"))
		seed:write("live destination bytes")
		seed:close()
		local adapter = make_adapter(nil, { [path] = true })
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

	helpers.it("fails closed when lstat cannot inspect an intermediate symlink", function()
		local virtual_parent_seed = os.tmpname():gsub("\\", "/")
		os.remove(virtual_parent_seed)
		local virtual_parent = virtual_parent_seed .. ".ergopti-lstat-link"
		local real_target = os.tmpname():gsub("\\", "/")
		local link_target, file_name = split_parent(real_target)
		local requested_path = virtual_parent .. "/" .. file_name
		local original_open = io.open
		local original_rename = os.rename
		local body_ok, body_err = xpcall(function()
			os.remove(requested_path)
			os.remove(real_target)
			HOST_RMDIR(virtual_parent)
			assert(HOST_MKDIR(virtual_parent))
			local seed = assert(original_open(real_target, "w"))
			seed:write("live symlink target bytes")
			seed:close()
			local adapter = make_adapter({
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
		local removed, remove_err = HOST_RMDIR(virtual_parent)
		local cleanup_ok = removed == true or HOST_ATTRIBUTES(virtual_parent) == nil
		if not body_ok then
			if not cleanup_ok then
				error(body_err .. "\nfixture cleanup failed: " .. tostring(remove_err))
			end
			error(body_err)
		end
		helpers.assert_true(cleanup_ok, "fixture directory cleanup must succeed: " .. tostring(remove_err))
	end)
end)




-- =====================================================
-- =====================================================
-- ======= 2/ Cooperative writer serialization ========
-- =====================================================
-- =====================================================

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

	local function run_nested_competitor(use_unconditional_writer)
		local path = os.tmpname():gsub("\\", "/")
		local lock_path = path .. WRITE_LOCK_SUFFIX
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
		local adapter_a = make_adapter(nil, nil, nil, nil, lock_a, unlock_a)
		local adapter_b = make_adapter(nil, nil, nil, nil, lock_b, unlock_b)
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
		run_nested_competitor(false)
	end)

	helpers.it("serializes unconditional reset against a conditional Ergopti writer", function()
		run_nested_competitor(true)
	end)

	helpers.it("serializes create-only publication against an absent-source conditional writer", function()
		local path = os.tmpname():gsub("\\", "/")
		local lock_path = path .. WRITE_LOCK_SUFFIX
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
		local creator = make_adapter(nil, nil, nil, function(source, destination)
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
		replacer = make_adapter(nil, nil, nil, nil, replacer_lock, replacer_unlock)

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

	helpers.it("checks the expected source only after lock acquisition and releases after rename", function()
		local path = os.tmpname():gsub("\\", "/")
		local lock_path = path .. WRITE_LOCK_SUFFIX
		os.remove(path)
		os.remove(lock_path)
		seed(path, "v0")
		local events = {}
		local held = false
		local adapter = make_adapter(nil, nil, nil, nil, function()
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

	helpers.it("releases after rename failure so the next cooperating writer can progress", function()
		local path = os.tmpname():gsub("\\", "/")
		local lock_path = path .. WRITE_LOCK_SUFFIX
		os.remove(path)
		os.remove(lock_path)
		seed(path, "old")
		local held = false
		local locks, unlocks, closes = 0, 0, 0
		local adapter = make_adapter(nil, nil, nil, nil, function()
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

	helpers.it("keeps one stable regular lock inode and rejects a directory at that pathname", function()
		local path = os.tmpname():gsub("\\", "/")
		local lock_path = path .. WRITE_LOCK_SUFFIX
		os.remove(path)
		os.remove(lock_path)
		local adapter = make_adapter()
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
		local directory_lock = directory_target .. WRITE_LOCK_SUFFIX
		os.remove(directory_target)
		os.remove(directory_lock)
		assert(HOST_MKDIR(directory_lock))
		local directory_adapter = make_adapter()
		local written = directory_adapter.write(directory_target, "blocked")
		helpers.assert_eq(written, false,
			"a directory/symlink collision must fail closed before staging or publication")
		helpers.assert_nil(io.open(directory_target, "r"))
		HOST_RMDIR(directory_lock)
	end)
end)




-- ==========================================
-- ==========================================
-- ======= 3/ Source-shape assertion ========
-- ==========================================
-- ==========================================

-- Behavioral coverage above proves write() works; this pins the actual
-- temp+rename SHAPE in source so a future refactor cannot silently revert to
-- a direct io.open(path, "w") without a regression test catching it.
helpers.describe("adapters.file_system: write() source uses temp+rename (F-MED-16)", function()
	local function read_source()
		-- Selected by a declaration unique to adapters/file_system.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("function M.expand_path")
		helpers.assert_true(src ~= nil, "adapters/file_system.lua source must be locatable")
		return src
	end

	helpers.it("write() reserves a private adjacent staging path before publication", function()
		local src = read_source()
		local fn_start = src:find("local function write_atomic", 1, true)
		helpers.assert_true(fn_start ~= nil, "the shared atomic writer must exist")
		local fn_end = src:find("\nfunction M.append", fn_start, true)
		local body = src:sub(fn_start, fn_end)
		local public_write = src:match("function M%.write%(path, content%)(.-)end") or ""

		helpers.assert_true(public_write:find("write_atomic(path, content, nil)", 1, true) ~= nil,
			"the canonical two-argument port must delegate to the reviewed atomic writer")
		helpers.assert_true(body:find("reserve_staging_area(resolved_path)", 1, true) ~= nil,
			"write() must exclusively reserve its staging pathname before opening it (F-MED-16)")
		helpers.assert_true(body:find("os.rename(", 1, true) ~= nil,
			"write() must publish the staged content via os.rename (F-MED-16)")
	end)

	helpers.it("write() delegates final-link resolution to the symlink-aware resolver", function()
		local src = read_source()
		local fn_start = src:find("local function write_atomic", 1, true)
		local fn_end   = src:find("\nfunction M.append", fn_start, true)
		local body = src:sub(fn_start, fn_end)
		local resolver_start = src:find("local function resolve_write_path(path)", 1, true)
		local resolver_end = src:find("local function revalidate_write_path", resolver_start, true)
		local resolver = src:sub(resolver_start, resolver_end)

		helpers.assert_true(body:find("resolve_write_path(path)", 1, true) ~= nil,
			"write() must invoke the shared resolver before it creates or renames the staging file")
		helpers.assert_true(resolver:find("inspect_path(prefix, component_parent, component)", 1, true) ~= nil,
			"the resolver must classify every component, including the final pathname")
		helpers.assert_nil(resolver:find("inspect_path(current)", 1, true),
			"a duplicate full-path probe must not reject a destination whose parent is meant to be created")
	end)
end)
