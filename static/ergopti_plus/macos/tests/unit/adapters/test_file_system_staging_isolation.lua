--- tests/unit/adapters/test_file_system_staging_isolation.lua

--- ==============================================================================
--- MODULE: FileSystem Staging Isolation Regression Tests
--- DESCRIPTION:
--- Proves that atomic writes reserve a private staging pathname before opening
--- it, that a failed publication never deletes the live destination, and that
--- refused cleanup remains an exact owner which blocks successor staging until
--- it settles. These are behavioral guards for cross-process isolation and
--- fail-closed publication on macOS.
--- ==============================================================================

local helpers = require("tests.helpers")

local LOCK_SUFFIX = ".ergoptiplus-stage-lock"
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

--- Reads a fixture without using the adapter under test.
--- @param path string Fixture path.
--- @return string|nil content
local function read_fixture(path)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local content = fh:read("*a")
	fh:close()
	return content
end

--- Writes a fixture without using the adapter under test.
--- @param path string Fixture path.
--- @param content string Complete content.
local function write_fixture(path, content)
	local fh = assert(io.open(path, "w"))
	fh:write(content)
	fh:close()
end

--- Returns the ownership lock for both legacy sibling and private-directory payloads.
--- @param payload_path string Observed staging payload.
--- @return string lock_path
local function staging_lock_path(payload_path)
	return payload_path:match("^(.*)/payload$") or (payload_path .. LOCK_SUFFIX)
end

--- Loads the real adapter with an exclusive-directory filesystem model.
--- The first staging reservation can be pre-owned by a foreign process; later
--- reservations are owned by this adapter and may be released only by it.
--- @param scenario boolean|string Collision or ambiguous-payload scenario.
--- @return table adapter
--- @return table state Reservation observations.
local function make_adapter(scenario)
	local raw_open = io.open
	local state = {
		foreign_payload = nil,
		lstat_errors = {},
		locks = {},
		lock_attempts = {},
		rmdir_calls = {},
		rmdir_refused = false,
		removed_locks = {},
	}

	local function file_attributes(path)
		if state.locks[path] ~= nil then return { mode = "directory" } end
		return HOST_ATTRIBUTES(path)
	end

	package.loaded["adapters.file_system"] = nil
	package.loaded["infra.fs_dir"] = nil
	local adapter = helpers.load_with_stubs("adapters.file_system", {
		fs = {
			dir = function(parent)
				local entries = {}
				for failed_path in pairs(state.lstat_errors) do
					local failed_parent, basename = split_parent(failed_path)
					if failed_parent == parent then entries[#entries + 1] = basename end
				end
				return make_directory_iterator(entries)
			end,
			attributes = file_attributes,
			symlinkAttributes = function(path)
				if state.lstat_errors[path] then error("injected lstat failure") end
				local attributes = file_attributes(path)
				if attributes then return attributes end
				attributes = HOST_SYMLINK_ATTRIBUTES(path)
				if type(attributes) == "table" then return attributes end
				return nil, "lstat failed"
			end,
			mkdir = function(path)
				if path:sub(-#LOCK_SUFFIX) ~= LOCK_SUFFIX then return true end
				state.lock_attempts[#state.lock_attempts + 1] = path
				if (scenario == true or scenario == "disappearing")
					and #state.lock_attempts == 1 then
					state.locks[path] = "foreign"
					if scenario == "disappearing" then state.locks[path] = nil end
					return nil, "File exists"
				end
				if state.locks[path] ~= nil then return nil, "File exists" end
				local created, create_err = HOST_MKDIR(path)
				if created ~= true then return created, create_err end
				state.locks[path] = "owned"
				if scenario == "ambiguous_payload_lstat_error"
					and #state.lock_attempts == 1 then
					local sibling_payload = path:sub(1, -#LOCK_SUFFIX - 1)
					local foreign_fh = assert(raw_open(sibling_payload, "w"))
					foreign_fh:write("foreign-staging-bytes")
					foreign_fh:close()
					state.foreign_payload = sibling_payload
					state.lstat_errors[sibling_payload] = true
				end
				return true
			end,
			rmdir = function(path)
				if state.locks[path] ~= "owned" then return nil, "not owned" end
				state.rmdir_calls[#state.rmdir_calls + 1] = path
				if state.rmdir_refused then return nil, "injected rmdir refusal" end
				local removed, remove_err = HOST_RMDIR(path)
				if removed ~= true then return removed, remove_err end
				state.locks[path] = nil
				state.removed_locks[#state.removed_locks + 1] = path
				return true
			end,
			link = function(source_path, destination_path)
				if read_fixture(destination_path) ~= nil then return nil, "File exists" end
				local source_bytes = assert(read_fixture(source_path), "source is unreadable")
				write_fixture(destination_path, source_bytes)
				return true
			end,
			pathToAbsolute = function(path) return path end,
			lock = function() return true end,
			unlock = function() return true end,
			xattr = {
				list = function() return {} end,
				get = function() return nil end,
			},
		},
	})
	return adapter, state
end





-- =====================================================
-- =====================================================
-- ======= 1/ Cross-process staging isolation ==========
-- =====================================================
-- =====================================================

helpers.describe("adapters.file_system: staging path ownership", function()
	helpers.it("retries without opening a staging pathname reserved by another process", function()
		local path = os.tmpname():gsub("\\", "/")
		os.remove(path)
		local adapter, state = make_adapter(true)
		local original_open = io.open
		local opened_for_write = {}

		io.open = function(open_path, mode)
			if mode == "w" and open_path ~= path then
				opened_for_write[open_path] = true
			end
			return original_open(open_path, mode)
		end
		local call_ok, write_ok = pcall(adapter.write, path, "managed-content")
		io.open = original_open

		helpers.assert_true(call_ok, "the collision repro must not raise")
		helpers.assert_true(write_ok, "a later private staging reservation must allow publication")
		helpers.assert_true(#state.lock_attempts >= 2,
			"the adapter must retry after the first exclusive reservation collides")
		local foreign_payload = state.lock_attempts[1] .. "/payload"
		local owned_payload = state.lock_attempts[2] .. "/payload"
		helpers.assert_nil(opened_for_write[foreign_payload],
			"the foreign process's associated staging pathname must never be opened or truncated")
		helpers.assert_true(opened_for_write[owned_payload] == true,
			"publication must use only the pathname protected by this instance's lock")
		helpers.assert_eq(state.locks[state.lock_attempts[1]], "foreign",
			"cleanup must not remove another process's reservation")
		helpers.assert_nil(state.locks[state.lock_attempts[2]],
			"the owned reservation must be released after publication")
		helpers.assert_eq(read_fixture(path), "managed-content")
		os.remove(path)
	end)

	helpers.it("retries when a colliding owner releases its lock before retry", function()
		local path = os.tmpname():gsub("\\", "/")
		os.remove(path)
		local adapter, state = make_adapter("disappearing")

		local write_ok = adapter.write(path, "after-disappearing-collision")

		helpers.assert_true(write_ok,
			"an EEXIST-to-absent race must retry instead of becoming a visible write failure")
		helpers.assert_true(#state.lock_attempts >= 2)
		helpers.assert_eq(read_fixture(path), "after-disappearing-collision")
		os.remove(path)
	end)

	helpers.it("does not open a foreign sibling payload when its lstat is unknown", function()
		local path = os.tmpname():gsub("\\", "/")
		os.remove(path)
		local adapter, state = make_adapter("ambiguous_payload_lstat_error")
		local original_open = io.open
		local opened_for_write = {}

		io.open = function(open_path, mode)
			if mode == "w" and open_path ~= path then opened_for_write[open_path] = true end
			return original_open(open_path, mode)
		end
		local call_ok, write_ok = pcall(adapter.write, path, "managed-content")
		io.open = original_open

		helpers.assert_true(call_ok, "the unknown-lstat reservation repro must not raise")
		helpers.assert_true(write_ok, "the private in-lock payload must remain usable")
		helpers.assert_true(state.foreign_payload ~= nil, "the repro must install a foreign sibling payload")
		helpers.assert_nil(opened_for_write[state.foreign_payload],
			"an unclassifiable sibling payload must never be opened or truncated")
		helpers.assert_eq(read_fixture(state.foreign_payload), "foreign-staging-bytes",
			"foreign staging bytes must survive an unknown lstat result")
		helpers.assert_eq(read_fixture(path), "managed-content")
		os.remove(state.foreign_payload)
		os.remove(path)
	end)
end)





-- ====================================================
-- ====================================================
-- ======= 2/ Failed publication preserves live =======
-- ====================================================
-- ====================================================

helpers.describe("adapters.file_system: failed rename is non-destructive", function()
	helpers.it("leaves the existing destination byte-for-byte when rename fails", function()
		local path = os.tmpname():gsub("\\", "/")
		write_fixture(path, "personal-karabiner-config")
		local adapter, state = make_adapter(false)
		local original_rename = os.rename
		local original_open = io.open
		local staged_paths = {}

		io.open = function(open_path, mode)
			if mode == "w" and open_path ~= path then staged_paths[#staged_paths + 1] = open_path end
			return original_open(open_path, mode)
		end
		os.rename = function(old_path, new_path)
			if new_path == path then return nil, "injected publication failure" end
			return original_rename(old_path, new_path)
		end
		local call_ok, write_ok = pcall(adapter.write, path, "managed-content")
		os.rename = original_rename
		io.open = original_open

		helpers.assert_true(call_ok, "the failed-publication repro must not raise")
		helpers.assert_eq(write_ok, false, "a failed rename must be reported")
		helpers.assert_eq(read_fixture(path), "personal-karabiner-config",
			"publication failure must never delete the user's live Karabiner configuration")
		helpers.assert_eq(#staged_paths, 1, "the repro must observe the private staging payload")
		local staged_path = staged_paths[1]
		helpers.assert_nil(read_fixture(staged_path),
			"a failed rename must remove the adapter-owned staging payload")
		local lock_path = staging_lock_path(staged_path)
		helpers.assert_nil(state.locks[lock_path],
			"a failed rename must release the adapter-owned staging lock")
		os.remove(path)
	end)

	helpers.it("settles the exact cleanup debt before reserving a successor staging area", function()
		local path = os.tmpname():gsub("\\", "/")
		write_fixture(path, "personal-karabiner-config")
		local adapter, state = make_adapter(false)
		local original_rename = os.rename
		local original_open = io.open
		local original_remove = os.remove
		local staged_paths = {}
		local remove_calls = {}
		local publication_attempts = 0
		local refuse_cleanup = true
		local old_owner_released_before_successor = false

		io.open = function(open_path, mode)
			if mode == "w" and open_path ~= path then
				staged_paths[#staged_paths + 1] = open_path
				if #staged_paths > 1 then
					local old_path = staged_paths[1]
					local old_lock = staging_lock_path(old_path)
					old_owner_released_before_successor = read_fixture(old_path) == nil
						and state.locks[old_lock] == nil
				end
			end
			return original_open(open_path, mode)
		end
		os.rename = function(old_path, new_path)
			if new_path == path then
				publication_attempts = publication_attempts + 1
				if publication_attempts == 1 then return nil, "injected publication failure" end
				-- The Windows test host cannot replace an existing destination through
				-- os.rename(). Model Darwin's replacement contract after the injected
				-- first failure so the debt assertions remain about staging ownership.
				original_remove(new_path)
			end
			return original_rename(old_path, new_path)
		end
		os.remove = function(remove_path)
			if staged_paths[1] ~= nil and remove_path == staged_paths[1] then
				remove_calls[#remove_calls + 1] = remove_path
				if refuse_cleanup then return nil, "injected cleanup refusal", 13 end
			end
			return original_remove(remove_path)
		end
		local first_call_ok, first_write_ok, first_detail = pcall(
			adapter.write, path, "managed-content")
		local attempts_after_first = #state.lock_attempts
		local second_call_ok, second_write_ok, second_detail = pcall(
			adapter.write, path, "must-not-publish")
		local attempts_after_second = #state.lock_attempts
		refuse_cleanup = false
		local third_call_ok, third_write_ok, third_detail = pcall(
			adapter.write, path, "published-after-cleanup")
		os.rename = original_rename
		io.open = original_open
		os.remove = original_remove

		local staged_path = staged_paths[1]
		local lock_path = staged_path and staging_lock_path(staged_path) or nil
		local payload_content = staged_path and read_fixture(staged_path) or nil
		local lock_owner = lock_path and state.locks[lock_path] or nil
		local live_content = read_fixture(path)
		for _, candidate in ipairs(staged_paths) do
			original_remove(candidate)
			HOST_RMDIR(staging_lock_path(candidate))
		end
		original_remove(path)

		helpers.assert_true(first_call_ok, "the initial cleanup-refusal repro must not raise")
		helpers.assert_eq(first_write_ok, false, "the failed rename must remain visible")
		helpers.assert_contains(first_detail, "injected publication failure")
		helpers.assert_true(staged_path ~= nil, "the repro must observe the private payload")
		helpers.assert_true(second_call_ok, "the exact cleanup retry must not raise")
		helpers.assert_eq(second_write_ok, false,
			"a retained cleanup owner must refuse a successor write")
		helpers.assert_contains(second_detail, "prior staging cleanup remains pending")
		helpers.assert_eq(attempts_after_second, attempts_after_first,
			"a pending cleanup owner must block every new staging reservation")
		helpers.assert_true(third_call_ok, "the cleanup-recovery write must not raise")
		helpers.assert_true(third_write_ok,
			"a later write must proceed after the exact cleanup owner settles")
		helpers.assert_nil(third_detail)
		helpers.assert_true(#remove_calls >= 3,
			"each writer retry must target the exact retained payload")
		for _, removed_path in ipairs(remove_calls) do
			helpers.assert_eq(removed_path, staged_path,
				"cleanup retries must never drift to a fresh staging candidate")
		end
		helpers.assert_true(old_owner_released_before_successor,
			"the retained payload and lock must settle before a successor opens")
		helpers.assert_nil(payload_content, "the retained staged bytes must eventually be removed")
		helpers.assert_nil(lock_owner, "the retained ownership lock must eventually be released")
		helpers.assert_eq(#state.removed_locks, 2,
			"the old cleanup owner and the later successful owner must each release once")
		helpers.assert_eq(live_content, "published-after-cleanup")
	end)

	helpers.it("reports a published empty-lock debt and settles it before the next write", function()
		local path = os.tmpname():gsub("\\", "/")
		os.remove(path)
		local adapter, state = make_adapter(false)
		local original_open = io.open
		local original_rename = os.rename
		local original_remove = os.remove
		local staged_paths = {}
		local old_owner_released_before_successor = false
		state.rmdir_refused = true

		io.open = function(open_path, mode)
			if mode == "w" and open_path ~= path then
				staged_paths[#staged_paths + 1] = open_path
				if #staged_paths > 1 then
					local old_lock = staging_lock_path(staged_paths[1])
					old_owner_released_before_successor = state.locks[old_lock] == nil
				end
			end
			return original_open(open_path, mode)
		end
		os.rename = function(old_path, new_path)
			if new_path == path and read_fixture(new_path) ~= nil then original_remove(new_path) end
			return original_rename(old_path, new_path)
		end

		local first_ok, first_detail = adapter.write(path, "published-before-cleanup")
		local attempts_after_first = #state.lock_attempts
		local second_ok, second_detail = adapter.write(path, "must-not-publish")
		local attempts_after_second = #state.lock_attempts
		state.rmdir_refused = false
		local third_ok, third_detail = adapter.write(path, "published-after-cleanup")
		io.open = original_open
		os.rename = original_rename

		local first_stage = staged_paths[1]
		local first_lock = first_stage and staging_lock_path(first_stage) or nil
		local live_content = read_fixture(path)
		for _, candidate in ipairs(staged_paths) do
			original_remove(candidate)
			HOST_RMDIR(staging_lock_path(candidate))
		end
		original_remove(path)

		helpers.assert_true(first_ok,
			"a consumed payload remains a successful publication while its lock debt is retained")
		helpers.assert_contains(first_detail, "prior staging cleanup remains pending")
		helpers.assert_eq(second_ok, false, "the retained empty lock must refuse a successor")
		helpers.assert_contains(second_detail, "prior staging cleanup remains pending")
		helpers.assert_eq(attempts_after_second, attempts_after_first,
			"an empty-lock debt must block a fresh staging reservation")
		helpers.assert_true(third_ok, "the successor must proceed after exact rmdir settlement")
		helpers.assert_nil(third_detail)
		helpers.assert_true(old_owner_released_before_successor,
			"the old empty lock must be gone before the successor payload opens")
		helpers.assert_true(first_stage ~= nil, "the repro must publish through private staging")
		helpers.assert_nil(read_fixture(first_stage), "rename must consume the first payload")
		helpers.assert_nil(state.locks[first_lock], "the old empty lock must eventually settle")
		helpers.assert_eq(#state.removed_locks, 2,
			"the retained and successor lock owners must each release exactly once")
		helpers.assert_eq(live_content, "published-after-cleanup")
	end)

	helpers.it("shares cleanup debt between create_if_absent() and replacement writes", function()
		local created_path = os.tmpname():gsub("\\", "/")
		local successor_path = os.tmpname():gsub("\\", "/")
		os.remove(created_path)
		os.remove(successor_path)
		local adapter, state = make_adapter(false)
		state.rmdir_refused = true

		local created, create_status, create_detail = adapter.create_if_absent(
			created_path,
			"created-before-cleanup"
		)
		local attempts_after_create = #state.lock_attempts
		local blocked, blocked_detail = adapter.write(successor_path, "must-not-publish")
		local attempts_after_block = #state.lock_attempts
		state.rmdir_refused = false
		local written, write_detail = adapter.write(successor_path, "published-after-cleanup")

		local created_content = read_fixture(created_path)
		local successor_content = read_fixture(successor_path)
		for lock_path in pairs(state.locks) do
			os.remove(lock_path .. "/payload")
			HOST_RMDIR(lock_path)
		end
		os.remove(created_path)
		os.remove(successor_path)

		helpers.assert_true(created,
			"create-only publication must preserve its already-committed creation result")
		helpers.assert_eq(create_status, "created")
		helpers.assert_contains(create_detail, "prior staging cleanup remains pending")
		helpers.assert_eq(created_content, "created-before-cleanup",
			"the explicit error must preserve the already-published destination bytes")
		helpers.assert_eq(blocked, false,
			"a create-only cleanup owner must block a replacement writer")
		helpers.assert_contains(blocked_detail, "prior staging cleanup remains pending")
		helpers.assert_eq(attempts_after_block, attempts_after_create,
			"the cross-API debt gate must precede successor staging reservation")
		helpers.assert_true(written, "the replacement writer must proceed after debt settlement")
		helpers.assert_nil(write_detail)
		helpers.assert_eq(successor_content, "published-after-cleanup")
	end)
end)





-- =============================================
-- =============================================
-- ======= 3/ File-handle failure values =======
-- =============================================
-- =============================================

helpers.describe("adapters.file_system: file-handle failures are fail-closed", function()
	local function run_handle_failure_case(failing_method, failure_kind)
		local path = os.tmpname():gsub("\\", "/")
		local adapter, state = make_adapter(false)
		local original_open = io.open
		local original_rename = os.rename
		local rename_calls = 0
		local staged_path = nil
		os.remove(path)

		local function injected_failure()
			local message = "injected " .. failing_method .. " " .. failure_kind
			if failure_kind == "false" then return false, message end
			if failure_kind == "nil" then return nil, message end
			error(message)
		end

		io.open = function(open_path, mode)
			if mode == "w" and open_path ~= path then
				staged_path = open_path
				local handle = {}
				handle.write = function()
					if failing_method == "write" then return injected_failure() end
					return handle
				end
				handle.close = function()
					if failing_method == "close" then return injected_failure() end
					return true
				end
				return handle
			end
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

		local lock_path = staged_path and staging_lock_path(staged_path) or nil
		local retained_owner = lock_path and state.locks[lock_path] or nil
		local removed_lock_count = #state.removed_locks
		local removed_lock_path = state.removed_locks[1]
		local lock_still_exists = lock_path and HOST_ATTRIBUTES(lock_path) ~= nil or false
		local destination = original_open(path, "r")
		if destination then destination:close() end
		os.remove(path)
		if lock_still_exists then
			if staged_path then os.remove(staged_path) end
			HOST_RMDIR(lock_path)
		end
		if not call_ok then error(write_ok) end

		local label = failing_method .. " " .. failure_kind
		helpers.assert_eq(write_ok, false, label .. " must reject the write")
		helpers.assert_eq(rename_calls, 0, label .. " must precede publication")
		helpers.assert_true(staged_path ~= nil, label .. " must exercise a reserved staging area")
		helpers.assert_nil(retained_owner, label .. " must release owned staging when cleanup succeeds")
		helpers.assert_eq(removed_lock_count, 1, label .. " must remove exactly one owned lock")
		helpers.assert_eq(removed_lock_path, lock_path, label .. " must remove its own lock")
		helpers.assert_eq(lock_still_exists, false, label .. " must leave no lock directory")
		helpers.assert_nil(destination, label .. " must not create the destination")
	end

	local cases = {
		{ method = "write", kind = "false" },
		{ method = "write", kind = "nil" },
		{ method = "write", kind = "throw" },
		{ method = "close", kind = "false" },
		{ method = "close", kind = "nil" },
		{ method = "close", kind = "throw" },
	}
	local function register_case(case)
		local method = case.method
		local kind = case.kind
		helpers.it("rejects fh:" .. method .. "() " .. kind .. " failure", function()
			run_handle_failure_case(method, kind)
		end)
	end
	for _, case in ipairs(cases) do register_case(case) end
end)
