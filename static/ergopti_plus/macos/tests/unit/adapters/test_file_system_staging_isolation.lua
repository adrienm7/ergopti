--- tests/unit/adapters/test_file_system_staging_isolation.lua

--- ==============================================================================
--- MODULE: FileSystem Staging Isolation Regression Tests
--- DESCRIPTION:
--- Proves that atomic writes reserve a private staging pathname before opening
--- it and that a failed publication never deletes the live destination. These
--- are behavioral guards for cross-process staging collisions and fail-closed
--- publication on macOS.
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
				local removed, remove_err = HOST_RMDIR(path)
				if removed ~= true then return removed, remove_err end
				state.locks[path] = nil
				state.removed_locks[#state.removed_locks + 1] = path
				return true
			end,
			pathToAbsolute = function(path) return path end,
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

	helpers.it("retains the owned lock when payload removal is refused after rename failure", function()
		local path = os.tmpname():gsub("\\", "/")
		write_fixture(path, "personal-karabiner-config")
		local adapter, state = make_adapter(false)
		local original_rename = os.rename
		local original_open = io.open
		local original_remove = os.remove
		local staged_path = nil
		local remove_calls = {}

		io.open = function(open_path, mode)
			if mode == "w" and open_path ~= path then staged_path = open_path end
			return original_open(open_path, mode)
		end
		os.rename = function(old_path, new_path)
			if new_path == path then return nil, "injected publication failure" end
			return original_rename(old_path, new_path)
		end
		os.remove = function(remove_path)
			if staged_path ~= nil and remove_path == staged_path then
				remove_calls[#remove_calls + 1] = remove_path
				return nil, "injected cleanup refusal", 13
			end
			return original_remove(remove_path)
		end
		local call_ok, write_ok = pcall(adapter.write, path, "managed-content")
		os.rename = original_rename
		io.open = original_open
		os.remove = original_remove

		local lock_path = staged_path and staging_lock_path(staged_path) or nil
		local payload_content = staged_path and read_fixture(staged_path) or nil
		local lock_owner = lock_path and state.locks[lock_path] or nil
		local live_content = read_fixture(path)
		if staged_path then original_remove(staged_path) end
		if lock_path then HOST_RMDIR(lock_path) end
		original_remove(path)

		helpers.assert_true(call_ok, "the cleanup-refusal repro must not raise")
		helpers.assert_eq(write_ok, false, "the failed rename must remain visible")
		helpers.assert_true(staged_path ~= nil, "the repro must observe the private payload")
		helpers.assert_eq(#remove_calls, 1, "cleanup must attempt the owned payload exactly once")
		helpers.assert_eq(remove_calls[1], staged_path, "cleanup must target only its private payload")
		helpers.assert_eq(payload_content, "managed-content",
			"a refused removal must leave the staged bytes recoverable")
		helpers.assert_eq(lock_owner, "owned",
			"the ownership lock must remain while its unpublished payload survives")
		helpers.assert_eq(#state.removed_locks, 0,
			"cleanup must not release the lock after payload removal fails")
		helpers.assert_eq(live_content, "personal-karabiner-config")
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
