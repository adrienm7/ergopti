--- tests/support/file_system_transaction_fixture.lua

--- ==============================================================================
--- MODULE: FileSystem Transaction Fixture
--- DESCRIPTION:
--- Owns native captures, module publications, and I/O overrides for one callback.
--- ==============================================================================

local helpers = require("tests.helpers")

local function with_fixture(callback)
	local saved_open, saved_rename = io.open, os.rename
	local outcome = table.pack(xpcall(function()
		return helpers.with_stub_scope({ "adapters.file_system", "infra.fs_dir", "infra.logger" }, function()
			-- Capture a fresh host before installing this transaction's filesystem doubles.
			local host = helpers.load_with_stubs("hs")
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			local STAGING_LOCK_SUFFIX = ".ergoptiplus-stage-lock"
			local WRITE_LOCK_SUFFIX = ".ergoptiplus-write-lock-v1"
			local HOST_ATTRIBUTES = host.fs.attributes
			local HOST_SYMLINK_ATTRIBUTES = host.fs.symlinkAttributes
			local HOST_MKDIR = host.fs.mkdir
			local HOST_RMDIR = host.fs.rmdir

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
					lock_override, unlock_override, mkdir_override, metadata_fixture)
				local staging_locks = {}
				local function copy_table(source)
					local target = {}
					for key, value in pairs(source or {}) do
						if type(value) == "table" then
							target[key] = copy_table(value)
						else
							target[key] = value
						end
					end
					return target
				end
				local function with_fixture_metadata(path, attributes)
					local record = type(metadata_fixture) == "table"
						and type(metadata_fixture.records) == "table"
						and metadata_fixture.records[path]
					if type(record) ~= "table" then return attributes end
					local merged = copy_table(attributes or { mode = "file" })
					for _, field in ipairs({ "permissions", "uid", "gid", "dev", "ino" }) do
						if record[field] ~= nil then merged[field] = record[field] end
					end
					return merged
				end
				local function quoted_arguments(command)
					local arguments = {}
					for argument in command:gmatch("'([^']*)'") do arguments[#arguments + 1] = argument end
					return arguments
				end
				package.loaded["adapters.file_system"] = nil
				package.loaded["infra.fs_dir"] = nil
				local adapter = helpers.load_with_stubs("adapters.file_system", {
					execute = function(command)
						local arguments = quoted_arguments(command)
						if command:find("/bin/cp -p ", 1, true) then
							local source_path = arguments[1]
							local destination_path = arguments[2]
							if type(metadata_fixture) == "table" then
								metadata_fixture.copy_calls = (metadata_fixture.copy_calls or 0) + 1
								metadata_fixture.records[destination_path] = copy_table(
									metadata_fixture.records[source_path] or metadata_fixture.default
								)
								if type(metadata_fixture.after_copy) == "function" then
									metadata_fixture.after_copy(metadata_fixture.records[destination_path])
								end
							end
							return "", true, "exit", 0
						end
						if command:find("/bin/ls -led ", 1, true) then
							local record = type(metadata_fixture) == "table"
								and metadata_fixture.records[arguments[1]]
							return "fixture header\n" .. tostring(record and record.acl or ""), true, "exit", 0
						end
						return "", true, "exit", 0
					end,
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
							return with_fixture_metadata(path, HOST_ATTRIBUTES(path))
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
							if type(attributes) == "table" then
								return with_fixture_metadata(path, attributes)
							end
							attributes = with_fixture_metadata(path, HOST_ATTRIBUTES(path))
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
						xattr = {
							list = function(path)
								local record = type(metadata_fixture) == "table"
									and metadata_fixture.records[path]
								local names = {}
								for name in pairs(record and record.xattrs or {}) do names[#names + 1] = name end
								return names
							end,
							get = function(path, name)
								local record = type(metadata_fixture) == "table"
									and metadata_fixture.records[path]
								return record and record.xattrs and record.xattrs[name] or nil
							end,
						},
					},
				})
				return adapter, staging_locks
			end

			return callback({
				STAGING_LOCK_SUFFIX = STAGING_LOCK_SUFFIX,
				WRITE_LOCK_SUFFIX = WRITE_LOCK_SUFFIX,
				HOST_ATTRIBUTES = HOST_ATTRIBUTES,
				HOST_SYMLINK_ATTRIBUTES = HOST_SYMLINK_ATTRIBUTES,
				HOST_MKDIR = HOST_MKDIR,
				HOST_RMDIR = HOST_RMDIR,
				make_adapter = make_adapter,
				split_parent = split_parent,
			})
		end)
	end, debug.traceback))
	io.open, os.rename = saved_open, saved_rename
	if not outcome[1] then error(outcome[2], 0) end
	return table.unpack(outcome, 2, outcome.n)
end

return { with_fixture = with_fixture }
