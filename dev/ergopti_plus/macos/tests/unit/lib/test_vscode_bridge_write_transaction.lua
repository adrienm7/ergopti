--- tests/unit/lib/test_vscode_bridge_write_transaction.lua

--- ==============================================================================
--- MODULE: VS Code Extension Write Transaction Regression Tests
--- DESCRIPTION:
--- Exercises the generated extension installer against a stateful in-memory
--- filesystem whose file methods and rename boundary can refuse without throwing.
--- The pair must remain byte-for-byte old until both candidates are durable, and
--- a partial publication must compensate or retain exact retry ownership.
--- ==============================================================================

local helpers = require("tests.helpers")

local ORIGINAL_PACKAGE = "original package bytes"
local ORIGINAL_EXTENSION = "original extension bytes"
local PACKAGE_SUFFIX = "/package.json"
local EXTENSION_SUFFIX = "/extension.js"
local STAGE_MARKER = ".ergoptiplus-stage"
local BACKUP_MARKER = ".ergoptiplus-backup"
local RESTORE_MARKER = ".ergoptiplus-restore"
local JOURNAL_SUFFIX = "/.ergoptiplus-extension-transaction"
local JOURNAL_STAGE_SUFFIX = "/.ergoptiplus-extension-transaction-stage"
local JOURNAL_MAGIC = "ergoptiplus-vscode-extension-transaction-v1"
local JOURNAL_BOTH_EXIST = JOURNAL_MAGIC
	.. "\npackage_existed=true\nextension_existed=true\n"





-- =======================================
-- =======================================
-- ======= 1/ Transaction Test Rig =======
-- =======================================
-- =======================================

--- Reports whether one string ends with a literal suffix.
--- @param value string Candidate string.
--- @param suffix string Required suffix.
--- @return boolean matches Whether the suffix matches.
local function ends_with(value, suffix)
	return value:sub(-#suffix) == suffix
end

--- Formats one captured logger invocation defensively.
--- @param format_value any Log format or value.
--- @param ... any Format arguments.
--- @return string message Formatted message.
local function format_log(format_value, ...)
	if select("#", ...) == 0 then return tostring(format_value) end
	local ok, message = pcall(string.format, tostring(format_value), ...)
	return ok and message or tostring(format_value)
end

--- Counts captured messages containing one literal fragment.
--- @param messages table Captured messages.
--- @param fragment string Literal fragment.
--- @return number count Number of matches.
local function count_messages(messages, fragment)
	local count = 0
	for _, message in ipairs(messages) do
		if message:find(fragment, 1, true) then count = count + 1 end
	end
	return count
end

--- Builds an isolated bridge plus a faithful, failure-injectable filesystem.
--- @param behavior table|nil Requested stage/publication/rollback failures.
--- @return table fixture Observable transaction fixture.
local function load_fixture(behavior)
	behavior = behavior or {}
	local logs = { debug = {}, info = {}, warn = {}, error = {} }
	local logger = helpers.make_logger_stub()
	for _, level in ipairs({ "debug", "info", "warn", "error" }) do
		local captured_level = level
		logger[level] = function(_module_name, format_value, ...)
			logs[captured_level][#logs[captured_level] + 1] = format_log(format_value, ...)
		end
	end
	local notifications = 0
	local notification_module = {
		notify = function()
			notifications = notifications + 1
			return true
		end,
	}

	--- Loads one genuinely fresh bridge instance with the same observable ports.
	--- @return table bridge Fresh production module.
	local function load_bridge_module()
		package.loaded["infra.logger"] = logger
		package.loaded["infra.notifications"] = notification_module
		return helpers.load_with_stubs("infra.vscode_bridge")
	end

	local bridge = load_bridge_module()
	local files = {}
	local initialized = {}
	local final_paths = {}
	local calls = {
		read_open = 0,
		read = 0,
		read_close = 0,
		journal_read_open = 0,
		write = 0,
		flush = 0,
		close = 0,
		journal_publication = 0,
		journal_remove = 0,
		publication = 0,
		rollback = 0,
		rollback_remove = 0,
		post_commit_remove = 0,
		remove = 0,
	}
	local operation_sequence = {}
	local publication_observations = {}
	local read_handles = 0
	local journal_read_handles = 0
	local stage_handles = 0

	--- Initializes one final pathname exactly once with its old bytes.
	--- @param path string Opened pathname.
	local function initialize_final(path)
		local root = nil
		if ends_with(path, PACKAGE_SUFFIX) then
			root = path:sub(1, #path - #PACKAGE_SUFFIX)
		elseif ends_with(path, EXTENSION_SUFFIX) then
			root = path:sub(1, #path - #EXTENSION_SUFFIX)
		end
		if not root then return end

		final_paths.package = root .. PACKAGE_SUFFIX
		final_paths.extension = root .. EXTENSION_SUFFIX
		if not behavior.originals_absent then
			if not initialized[final_paths.package] then
				files[final_paths.package] = ORIGINAL_PACKAGE
			end
			if not initialized[final_paths.extension] then
				files[final_paths.extension] = ORIGINAL_EXTENSION
			end
		end
		initialized[final_paths.package] = true
		initialized[final_paths.extension] = true
	end

	--- Initializes the deterministic journal and derives its adjacent final pair.
	--- @param path string Opened pathname.
	local function initialize_journal(path)
		if not ends_with(path, JOURNAL_SUFFIX) then return end
		local root = path:sub(1, #path - #JOURNAL_SUFFIX)
		initialize_final(root .. PACKAGE_SUFFIX)
		final_paths.journal = path
		if not initialized[path] then
			files[path] = behavior.journal_content
			initialized[path] = true
		end
	end

	--- Consumes one configured failure when its index and operation match.
	--- @param failure table|nil Failure descriptor.
	--- @param index number Current operation index.
	--- @param operation string Current operation name.
	--- @return string|nil mode Failure mode, or nil.
	local function consume_failure(failure, index, operation)
		local index_matches = type(failure) == "table"
			and (failure.index == index
				or (failure.repeat_from_index == true and index >= failure.index))
		if type(failure) ~= "table"
			or not index_matches
			or failure.operation ~= operation
			or (failure.remaining or 1) <= 0 then
			return nil
		end
		failure.remaining = (failure.remaining or 1) - 1
		return failure.mode or "nil"
	end

	--- Applies a nil-return or thrown native failure.
	--- @param mode string|nil Failure mode.
	--- @param message string Diagnostic message.
	--- @return boolean failed Whether a failure was applied.
	local function apply_failure(mode, message)
		if mode == "throw" then error(message, 0) end
		if mode == "nil" then return true end
		return false
	end

	--- Opens a stateful in-memory file handle.
	--- @param path string Opened path.
	--- @param mode string Open mode.
	--- @return table|nil handle File handle.
	--- @return string|nil error_message Failure detail.
	local function fake_open(path, mode)
		if mode == "r" or mode == "rb" then
			initialize_final(path)
			initialize_journal(path)
			local handle_index = 0
			local read_failure = nil
			if ends_with(path, PACKAGE_SUFFIX) or ends_with(path, EXTENSION_SUFFIX) then
				read_handles = read_handles + 1
				handle_index = read_handles
				calls.read_open = calls.read_open + 1
				read_failure = behavior.read_failure
			elseif ends_with(path, JOURNAL_SUFFIX) then
				journal_read_handles = journal_read_handles + 1
				handle_index = journal_read_handles
				calls.journal_read_open = calls.journal_read_open + 1
				read_failure = behavior.journal_read_failure
			end
			local open_failure_mode = consume_failure(
				read_failure,
				handle_index,
				"open"
			)
			if open_failure_mode and apply_failure(open_failure_mode, "open exploded") then
				return nil, "open refused", 13
			end
			if files[path] == nil then return nil, "missing", 2 end
			local reader = { closed = false }
			reader.read = function()
				calls.read = calls.read + 1
				if reader.closed then error("attempt to use a closed file", 0) end
				local failure_mode = consume_failure(read_failure, handle_index, "read")
				if failure_mode and apply_failure(failure_mode, "read exploded") then
					return nil, "read refused"
				end
				return files[path]
			end
			reader.close = function()
				calls.read_close = calls.read_close + 1
				if reader.closed then error("attempt to use a closed file", 0) end
				local failure_mode = consume_failure(read_failure, handle_index, "close")
				reader.closed = true
				if failure_mode and apply_failure(failure_mode, "read close exploded") then
					return nil, "read close refused"
				end
				return true
			end
			return reader
		end

		if mode ~= "w" and mode ~= "wb" then return nil, "unsupported mode" end
		stage_handles = stage_handles + 1
		local handle_index = stage_handles
		local handle = { buffer = "", closed = false }

		handle.write = function(self, content)
			calls.write = calls.write + 1
			local failure_mode = consume_failure(behavior.stage_failure, handle_index, "write")
			if failure_mode then
				files[path] = "partial bytes"
				if apply_failure(failure_mode, "write exploded") then
					return nil, "write refused"
				end
			end
			self.buffer = content
			files[path] = content
			return self
		end

		handle.flush = function()
			calls.flush = calls.flush + 1
			local failure_mode = consume_failure(behavior.stage_failure, handle_index, "flush")
			if failure_mode and apply_failure(failure_mode, "flush exploded") then
				return nil, "flush refused"
			end
			return true
		end

		handle.close = function()
			calls.close = calls.close + 1
			if handle.closed then error("attempt to use a closed file", 0) end
			local failure_mode = consume_failure(behavior.stage_failure, handle_index, "close")
			handle.closed = true
			if failure_mode and apply_failure(failure_mode, "close exploded") then
				return nil, "close refused"
			end
			return true
		end

		return handle
	end

	--- Renames one in-memory path with independent publish/rollback failures.
	--- @param source string Source path.
	--- @param destination string Destination path.
	--- @return boolean|nil renamed Exact native-style result.
	--- @return string|nil error_message Failure detail.
	local function fake_rename(source, destination)
		local failure_mode = nil
		if ends_with(source, JOURNAL_STAGE_SUFFIX) then
			calls.journal_publication = calls.journal_publication + 1
			operation_sequence[#operation_sequence + 1] = "journal_publish"
			failure_mode = consume_failure(
				behavior.journal_publication_failure,
				calls.journal_publication,
				"rename"
			)
		elseif source:find(RESTORE_MARKER, 1, true) then
			calls.rollback = calls.rollback + 1
			operation_sequence[#operation_sequence + 1] = "rollback_rename"
			failure_mode = consume_failure(
				behavior.rollback_failure,
				calls.rollback,
				"rename"
			)
		elseif source:find(STAGE_MARKER, 1, true) then
			calls.publication = calls.publication + 1
			local target_name = ends_with(destination, PACKAGE_SUFFIX)
				and "package.json" or "extension.js"
			operation_sequence[#operation_sequence + 1] = "publish:" .. target_name
			publication_observations[#publication_observations + 1] = {
				target = destination,
				before = files[destination],
				journal = files[final_paths.journal],
			}
			failure_mode = consume_failure(
				behavior.publication_failure,
				calls.publication,
				"rename"
			)
		end

		if failure_mode and apply_failure(failure_mode, "rename exploded") then
			return nil, "rename refused"
		end
		if files[source] == nil then return nil, "source missing" end
		files[destination] = files[source]
		files[source] = nil
		return true
	end

	--- Removes one in-memory path exactly like a successful unlink.
	--- @param path string Removed path.
	--- @return boolean removed Exact success.
	local function fake_remove(path)
		local failure_mode = nil
		if ends_with(path, JOURNAL_SUFFIX) then
			calls.journal_remove = calls.journal_remove + 1
			operation_sequence[#operation_sequence + 1] = "journal_remove"
			failure_mode = consume_failure(
				behavior.journal_remove_failure,
				calls.journal_remove,
				"remove"
			)
		elseif path == final_paths.package or path == final_paths.extension then
			calls.rollback_remove = calls.rollback_remove + 1
			operation_sequence[#operation_sequence + 1] = "rollback_remove"
			failure_mode = consume_failure(
				behavior.rollback_remove_failure,
				calls.rollback_remove,
				"remove"
			)
		else
			calls.remove = calls.remove + 1
			if calls.journal_remove > 0 then
				calls.post_commit_remove = calls.post_commit_remove + 1
				failure_mode = consume_failure(
					behavior.post_commit_remove_failure,
					calls.post_commit_remove,
					"remove"
				)
			end
		end
		if failure_mode and apply_failure(failure_mode, "remove exploded") then
			return nil, "remove refused"
		end
		files[path] = nil
		return true
	end

	--- Runs one installer call with all process globals restored afterward.
	--- @return boolean call_ok Whether the call stayed contained.
	--- @return any result Installer result or traceback.
	local function run_install()
		local real_open = io.open
		local real_execute = os.execute
		local real_rename = os.rename
		local real_remove = os.remove
		io.open = fake_open
		os.execute = function() return true end
		os.rename = fake_rename
		os.remove = fake_remove
		local call_ok, result = xpcall(bridge.install_extension, debug.traceback)
		io.open = real_open
		os.execute = real_execute
		os.rename = real_rename
		os.remove = real_remove
		return call_ok, result
	end

	local fixture = {
		bridge = bridge,
		behavior = behavior,
		calls = calls,
		files = files,
		final_paths = final_paths,
		logs = logs,
		operation_sequence = operation_sequence,
		publication_observations = publication_observations,
		notifications = function() return notifications end,
		run_install = run_install,
	}
	fixture.reload_bridge = function()
		bridge = load_bridge_module()
		fixture.bridge = bridge
		return bridge
	end
	return fixture
end

--- Runs one whole test case with the exact module cache and hs global restored.
--- @param callback function Test case body.
local function with_fixture_isolation(callback)
	local saved_hs = _G.hs
	local saved_loaded = {}
	for module_name, loaded in pairs(package.loaded) do
		saved_loaded[module_name] = loaded
	end

	local call_ok, error_message = xpcall(callback, debug.traceback)
	local current_names = {}
	for module_name in pairs(package.loaded) do
		current_names[#current_names + 1] = module_name
	end
	for _, module_name in ipairs(current_names) do
		if saved_loaded[module_name] == nil then package.loaded[module_name] = nil end
	end
	for module_name, loaded in pairs(saved_loaded) do
		package.loaded[module_name] = loaded
	end
	_G.hs = saved_hs
	if not call_ok then error(error_message, 0) end
end

--- Wraps one discoverable test callback in guaranteed fixture restoration.
--- @param callback function Test case body.
--- @return function isolated_callback Wrapped callback.
local function fixture_isolated(callback)
	return function()
		with_fixture_isolation(callback)
	end
end

--- Asserts that both committed paths still contain the exact old pair.
--- @param fixture table Transaction fixture.
local function assert_original_pair(fixture)
	helpers.assert_eq(fixture.files[fixture.final_paths.package], ORIGINAL_PACKAGE,
		"package.json must retain its exact original bytes")
	helpers.assert_eq(fixture.files[fixture.final_paths.extension], ORIGINAL_EXTENSION,
		"extension.js must retain its exact original bytes")
end

--- Counts all still-observable private staging and backup paths.
--- @param files table In-memory path map.
--- @return number count Live sidecar count.
local function count_sidecars(files)
	local count = 0
	for path, content in pairs(files) do
		if content ~= nil and (path:find(STAGE_MARKER, 1, true)
			or path:find(BACKUP_MARKER, 1, true)
			or path:find(RESTORE_MARKER, 1, true)
			or ends_with(path, JOURNAL_SUFFIX)
			or ends_with(path, JOURNAL_STAGE_SUFFIX)) then
			count = count + 1
		end
	end
	return count
end





-- =======================================
-- =======================================
-- ======= 2/ Failure Matrix =============
-- =======================================
-- =======================================

helpers.describe("vscode_bridge extension two-file transaction", function()
	helpers.it("HS-023 aborts before staging when either original read is uncertain",
		fixture_isolated(function()
		for _, handle_index in ipairs({ 1, 2 }) do
			for _, operation in ipairs({ "open", "read", "close" }) do
				for _, mode in ipairs({ "nil", "throw" }) do
					local fixture = load_fixture({
						read_failure = {
							index = handle_index,
							operation = operation,
							mode = mode,
						},
					})
					local label = string.format("original %d %s %s", handle_index, operation, mode)
					local call_ok, result = fixture.run_install()
					helpers.assert_true(call_ok, label .. " must stay contained")
					helpers.assert_eq(result, false, label .. " must fail closed")
					assert_original_pair(fixture)
					helpers.assert_eq(fixture.calls.write, 0,
						"an uncertain original must abort before creating a sidecar")
					helpers.assert_eq(fixture.calls.publication, 0,
						"an uncertain original must abort before publication")
					helpers.assert_eq(count_sidecars(fixture.files), 0)
					helpers.assert_true(#fixture.logs.error >= 1,
						"an uncertain original must be diagnosed")
					helpers.assert_eq(count_messages(fixture.logs.info, "Extension installed in"), 0)
				end
			end
		end
	end))

	helpers.it("HS-023 fails closed on an uncertain or invalid recovery journal",
		fixture_isolated(function()
		local cases = {
			{ label = "invalid", journal_content = "not a transaction journal" },
		}
		for _, operation in ipairs({ "open", "read", "close" }) do
			for _, mode in ipairs({ "nil", "throw" }) do
				cases[#cases + 1] = {
					label = operation .. " " .. mode,
					journal_content = JOURNAL_BOTH_EXIST,
					journal_read_failure = {
						index = 1,
						operation = operation,
						mode = mode,
					},
				}
			end
		end

		for _, case in ipairs(cases) do
			local fixture = load_fixture(case)
			local call_ok, result = fixture.run_install()
			helpers.assert_true(call_ok, case.label .. " must stay contained")
			helpers.assert_eq(result, false, case.label .. " must fail closed")
			assert_original_pair(fixture)
			helpers.assert_eq(fixture.calls.write, 0,
				"an uncertain journal must abort before staging")
			helpers.assert_eq(fixture.calls.publication, 0)
			helpers.assert_eq(fixture.calls.journal_remove, 0,
				"an uncertain journal must never be deleted as an orphan")
			helpers.assert_eq(fixture.calls.remove, 0,
				"journal uncertainty must not clean recovery sidecars")
			helpers.assert_true(#fixture.logs.error >= 1,
				"journal uncertainty must be diagnosed")
		end
	end))

	helpers.it("HS-023 stages write flush and close exactly before publication",
		fixture_isolated(function()
		for _, handle_index in ipairs({ 1, 2, 3, 4, 5 }) do
			for _, operation in ipairs({ "write", "flush", "close" }) do
				for _, mode in ipairs({ "nil", "throw" }) do
					local fixture = load_fixture({
						stage_failure = {
							index = handle_index,
							operation = operation,
							mode = mode,
						},
					})
					local label = string.format("sidecar %d %s %s", handle_index, operation, mode)
					local call_ok, result = fixture.run_install()
					helpers.assert_true(call_ok, label .. " must not escape the install boundary")
					helpers.assert_eq(result, false, label .. " must return exact false")
					assert_original_pair(fixture)
					helpers.assert_eq(fixture.calls.publication, 0,
						"no final path may publish before every candidate and backup is durable")
					helpers.assert_eq(count_sidecars(fixture.files), 0,
						"a refused stage must settle every private sidecar")
					helpers.assert_eq(count_messages(fixture.logs.info, "Extension installed in"), 0,
						"a staging refusal must never emit the install success line")

					call_ok, result = fixture.run_install()
					helpers.assert_true(call_ok, label .. " retry must stay contained")
					helpers.assert_eq(result, true,
						label .. " must not retain a consumed file handle as cleanup debt")
				end
			end
		end
	end))

	helpers.it("HS-023 compensates every refused publication rename",
		fixture_isolated(function()
		for _, publish_index in ipairs({ 1, 2 }) do
			for _, mode in ipairs({ "nil", "throw" }) do
				local fixture = load_fixture({
					publication_failure = {
						index = publish_index,
						operation = "rename",
						mode = mode,
					},
				})
				local label = string.format("publication %d %s", publish_index, mode)
				local call_ok, result = fixture.run_install()
				helpers.assert_true(call_ok, label .. " must be contained")
				helpers.assert_eq(result, false, label .. " must refuse commit")
				assert_original_pair(fixture)
				helpers.assert_eq(fixture.calls.publication, publish_index,
					"the refusal must occur at the selected final-path publication")
				helpers.assert_eq(fixture.calls.journal_publication, 1,
					"the durable journal must precede every final-path rename")
				helpers.assert_eq(fixture.calls.rollback, 2,
					"recovery must idempotently restore both originals")
				helpers.assert_eq(
					fixture.publication_observations[1].journal,
					JOURNAL_BOTH_EXIST,
					"no final path may change before the exact journal is observable"
				)
				helpers.assert_eq(count_sidecars(fixture.files), 0,
					"a settled rollback must remove every private sidecar")
				helpers.assert_eq(count_messages(fixture.logs.info, "Extension installed in"), 0)
			end
		end
	end))

	helpers.it("HS-023 reload recovers refused restore renames before retry",
		fixture_isolated(function()
		for _, mode in ipairs({ "nil", "throw" }) do
			local fixture = load_fixture({
				publication_failure = {
					index = 2,
					operation = "rename",
					mode = "nil",
				},
				rollback_failure = {
					index = 1,
					operation = "rename",
					mode = mode,
				},
			})
			local call_ok, result = fixture.run_install()
			helpers.assert_true(call_ok, mode .. " compensation must stay contained")
			helpers.assert_eq(result, false)
			helpers.assert_eq(fixture.files[fixture.final_paths.journal], JOURNAL_BOTH_EXIST,
				"a refused restore must retain the durable journal")
			helpers.assert_true(count_sidecars(fixture.files) >= 3,
				"a refused restore must retain journal and exact backups")
			helpers.assert_true(#fixture.logs.error >= 1,
				"a retained recovery debt must be diagnosed")

			fixture.reload_bridge()
			call_ok, result = fixture.run_install()
			helpers.assert_true(call_ok, "fresh require recovery must stay contained")
			helpers.assert_eq(result, true,
				"a fresh module must recover the old pair before committing a new pair")
			helpers.assert_eq(fixture.publication_observations[3].before, ORIGINAL_EXTENSION,
				"reload recovery must restore extension.js before the retry publishes")
			helpers.assert_eq(fixture.publication_observations[4].before, ORIGINAL_PACKAGE,
				"reload recovery must restore package.json before the retry publishes")
			helpers.assert_true(fixture.files[fixture.final_paths.package]
				:find("hs-caret-bridge", 1, true) ~= nil)
			helpers.assert_true(fixture.files[fixture.final_paths.extension]
				:find("module.exports", 1, true) ~= nil)
			helpers.assert_eq(count_sidecars(fixture.files), 0)
		end
	end))

	helpers.it("HS-023 reload recovers refused rollback removals before retry",
		fixture_isolated(function()
		for _, mode in ipairs({ "nil", "throw" }) do
			local fixture = load_fixture({
				originals_absent = true,
				publication_failure = {
					index = 2,
					operation = "rename",
					mode = "nil",
				},
				rollback_remove_failure = {
					index = 1,
					operation = "remove",
					mode = mode,
				},
			})
			local call_ok, result = fixture.run_install()
			helpers.assert_true(call_ok, mode .. " rollback removal must stay contained")
			helpers.assert_eq(result, false)
			helpers.assert_true(fixture.files[fixture.final_paths.journal]
				:find("package_existed=false", 1, true) ~= nil,
				"absence recovery must remain durable across reload")
			helpers.assert_true(count_sidecars(fixture.files) >= 1)

			fixture.reload_bridge()
			call_ok, result = fixture.run_install()
			helpers.assert_true(call_ok)
			helpers.assert_eq(result, true,
				"reload must restore exact absence before committing both fresh files")
			helpers.assert_eq(fixture.publication_observations[3].before, nil,
				"extension.js must be absent immediately before retry publication")
			helpers.assert_eq(fixture.publication_observations[4].before, nil,
				"package.json must be absent immediately before retry publication")
			helpers.assert_true(fixture.files[fixture.final_paths.package]
				:find("hs-caret-bridge", 1, true) ~= nil)
			helpers.assert_true(fixture.files[fixture.final_paths.extension]
				:find("module.exports", 1, true) ~= nil)
			helpers.assert_eq(count_sidecars(fixture.files), 0)
		end
	end))





-- =======================================
-- =======================================
-- ======= 3/ Positive Commit =============
-- =======================================
-- =======================================

	helpers.it("HS-023 publishes both durable candidates exactly once",
		fixture_isolated(function()
		local fixture = load_fixture()
		local call_ok, result = fixture.run_install()
		helpers.assert_true(call_ok)
		helpers.assert_eq(result, true)
		helpers.assert_eq(fixture.calls.write, 5,
			"two candidates, two exact originals, and one journal must be staged")
		helpers.assert_eq(fixture.calls.flush, 5,
			"every staged payload must flush before publication")
		helpers.assert_eq(fixture.calls.close, 5,
			"every staged payload must close exactly before publication")
		helpers.assert_eq(fixture.calls.journal_publication, 1)
		helpers.assert_eq(fixture.calls.publication, 2)
		helpers.assert_eq(fixture.operation_sequence[1], "journal_publish",
			"the durable journal must publish before either final path")
		helpers.assert_eq(fixture.operation_sequence[2], "publish:extension.js",
			"extension.js must publish before the manifest")
		helpers.assert_eq(fixture.operation_sequence[3], "publish:package.json",
			"package.json is the manifest-last commit marker")
		helpers.assert_eq(fixture.operation_sequence[4], "journal_remove",
			"the journal must disappear before any backup cleanup")
		helpers.assert_eq(fixture.publication_observations[1].before, ORIGINAL_EXTENSION,
			"the script original must remain in place until its commit rename")
		helpers.assert_eq(fixture.publication_observations[2].before, ORIGINAL_PACKAGE,
			"the package original must remain in place until its manifest-last rename")
		helpers.assert_eq(fixture.publication_observations[1].journal, JOURNAL_BOTH_EXIST)
		helpers.assert_eq(fixture.publication_observations[2].journal, JOURNAL_BOTH_EXIST)
		helpers.assert_true(fixture.files[fixture.final_paths.package]
			:find("hs-caret-bridge", 1, true) ~= nil)
		helpers.assert_true(fixture.files[fixture.final_paths.extension]
			:find("module.exports", 1, true) ~= nil)
		helpers.assert_eq(count_sidecars(fixture.files), 0)
		helpers.assert_eq(fixture.files[fixture.final_paths.journal], nil)
		helpers.assert_eq(count_messages(fixture.logs.info, "Extension installed in"), 1)
		helpers.assert_eq(fixture.notifications(), 1)

		call_ok, result = fixture.run_install()
		helpers.assert_true(call_ok)
		helpers.assert_eq(result, false,
			"an exact second read must take the already-up-to-date path")
		helpers.assert_eq(fixture.calls.publication, 2,
			"an already-current pair must not republish either file")
	end))

	helpers.it("HS-023 never rolls back a committed pair to settle cleanup debt",
		fixture_isolated(function()
		local fixture = load_fixture({
			post_commit_remove_failure = {
				index = 1,
				operation = "remove",
				mode = "nil",
				remaining = 3,
				repeat_from_index = true,
			},
		})
		local call_ok, result = fixture.run_install()
		helpers.assert_true(call_ok)
		helpers.assert_eq(result, true,
			"sidecar cleanup debt must not falsify an already committed pair")
		helpers.assert_true(fixture.files[fixture.final_paths.package]
			:find("hs-caret-bridge", 1, true) ~= nil)
		helpers.assert_true(fixture.files[fixture.final_paths.extension]
			:find("module.exports", 1, true) ~= nil)
		helpers.assert_true(count_sidecars(fixture.files) >= 1,
			"the refused cleanup path must remain owned for retry")

		call_ok, result = fixture.run_install()
		helpers.assert_true(call_ok)
		helpers.assert_eq(result, false,
			"a repeated cleanup refusal must block a fresh install attempt")
		helpers.assert_true(fixture.files[fixture.final_paths.package]
			:find("hs-caret-bridge", 1, true) ~= nil,
			"cleanup retry must never compensate a committed package")
		helpers.assert_true(fixture.files[fixture.final_paths.extension]
			:find("module.exports", 1, true) ~= nil,
			"cleanup retry must never compensate a committed script")
		helpers.assert_eq(fixture.calls.rollback, 0,
			"post-commit cleanup cannot enter the rollback path")
		helpers.assert_eq(fixture.calls.publication, 2)
		helpers.assert_true(count_sidecars(fixture.files) >= 1,
			"repeated cleanup refusal must preserve the retry owner")

		call_ok, result = fixture.run_install()
		helpers.assert_true(call_ok)
		helpers.assert_eq(result, false,
			"settled cleanup must reveal that the committed pair is already current")
		helpers.assert_eq(fixture.calls.rollback, 0)
		helpers.assert_eq(count_sidecars(fixture.files), 0)
	end))

	helpers.it("HS-023 retains journal and backups when the commit marker cannot clear",
		fixture_isolated(function()
		for _, mode in ipairs({ "nil", "throw" }) do
			local fixture = load_fixture({
				journal_remove_failure = {
					index = 1,
					operation = "remove",
					mode = mode,
				},
			})
			local call_ok, result = fixture.run_install()
			helpers.assert_true(call_ok, mode .. " journal removal must stay contained")
			helpers.assert_eq(result, false,
				"the install cannot report success while its recovery journal remains")
			helpers.assert_eq(fixture.files[fixture.final_paths.journal], JOURNAL_BOTH_EXIST)
			helpers.assert_true(count_sidecars(fixture.files) >= 3,
				"journal removal refusal must preserve both exact backups")
			helpers.assert_eq(fixture.calls.rollback, 0,
				"same-process commit finalization must not roll a complete pair back")
			helpers.assert_eq(count_messages(fixture.logs.info, "Extension installed in"), 0)

			call_ok, result = fixture.run_install()
			helpers.assert_true(call_ok)
			helpers.assert_eq(result, false,
				"retry settles the commit then observes an already-current pair")
			helpers.assert_eq(fixture.files[fixture.final_paths.journal], nil)
			helpers.assert_eq(count_sidecars(fixture.files), 0)
			helpers.assert_eq(fixture.calls.publication, 2,
				"commit-finalization retry must not republish either final")
		end
	end))
end)
