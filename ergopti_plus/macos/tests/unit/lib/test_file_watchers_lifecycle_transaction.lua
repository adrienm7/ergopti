--- tests/unit/lib/test_file_watchers_lifecycle_transaction.lua

--- ==============================================================================
--- MODULE: File-Watcher Startup Lifecycle Transaction Regressions
--- DESCRIPTION:
--- Exercises the three reload pathwatchers through native-faithful Lua ownership
--- boundaries. The fixture models documented constructor/start/void-stop return
--- contracts and explicit refusal doubles; it does not claim to exercise native
--- FSEvents delivery hidden behind Hammerspoon.
---
--- FEATURES & RATIONALE:
--- 1. Exact Acquisition: Every constructor and start boundary must commit before
---    the composite owner or literal startup success is published.
--- 2. Reverse Rollback: A failed stage revokes all callbacks, then releases the
---    failing candidate and committed predecessors in strict reverse order.
--- 3. Exact Cleanup Debt: False/throw stop refusal retains only the same native
---    object for retry while its queued callback remains inert.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===========================================
-- ===========================================
-- ======= 1/ Isolated Native Fixture ========
-- ===========================================
-- ===========================================

local ROOT_ANCHOR = 'Boot.mark("File watchers armed")'
local START_ASSIGNMENT = 'local file_watchers_committed = require("infra.file_watchers").start({'
local PERSONAL_INFO_WIRING = "personal_info_path       = personal_info_toml_path,"
local EXACT_BOOT_GUARD = "if file_watchers_committed ~= true then"
local BOOT_FAILURE = 'error("file-watcher startup did not commit")'

local START_CONTEXT = {
	hotstrings_dir = "/fake/hotstrings/",
	base_dir = "/fake/base/",
	personal_hotstrings_dir = "/fake/personal/",
}

local CALLBACK_PATHS = {
	{ "/fake/hotstrings/change.toml" },
	{ "/fake/personal/change.toml" },
	{ "/fake/base/modules/change.lua" },
}

--- Joins a numeric trace for stable failure diagnostics.
--- @param values table Numeric sequence.
--- @return string joined
local function join_trace(values)
	local rendered = {}
	for index, value in ipairs(values) do rendered[index] = tostring(value) end
	return table.concat(rendered, ",")
end

--- Builds the descending acquisition indices from last down to one.
--- @param last number Last acquired index.
--- @return string trace
local function descending_trace(last)
	local values = {}
	for index = last, 1, -1 do values[#values + 1] = index end
	return join_trace(values)
end

--- Builds the ascending acquisition indices from one through last.
--- @param last number Last acquired index.
--- @return string trace
local function ascending_trace(last)
	local values = {}
	for index = 1, last do values[#values + 1] = index end
	return join_trace(values)
end

--- Delivers every captured callback with a relevant path for its watcher.
--- @param runtime table Fixture runtime.
local function fire_captured_callbacks(runtime)
	for index, callback in ipairs(runtime.callbacks) do
		callback(CALLBACK_PATHS[index])
	end
end

--- Runs one startup scenario with a fresh module and stateful native doubles.
--- @param options table Constructor/start/stop fault injection.
--- @param scenario function Scenario receiving module and runtime state.
local function with_fixture(options, scenario)
	options = options or {}
	local saved_file_watchers = package.loaded["infra.file_watchers"]
	local saved_ui_restore = package.loaded["infra.ui_restore"]
	local saved_logger = package.loaded["infra.logger"]
	local saved_pathwatcher = hs.pathwatcher
	local saved_timer = hs.timer
	local saved_reload = hs.reload
	local saved_roots = rawget(_G, "script_watchers")

	local runtime = {
		callbacks = {},
		construct_count = 0,
		deferred_reloads = 0,
		errors = {},
		publication_counts = {},
		reloads = 0,
		start_order = {},
		stop_handles = {},
		stop_order = {},
		stop_publication_counts = {},
		timer_arms = 0,
		timer_callbacks = {},
		timer_stops = 0,
		watchers = {},
		wrong_owner_stops = 0,
		clock = 0,
	}

	local function noop() end
	package.loaded["infra.logger"] = setmetatable({
		error = function(_, message, ...)
			runtime.errors[#runtime.errors + 1] = string.format(message, ...)
		end,
	}, { __index = function() return noop end })
	package.loaded["infra.ui_restore"] = {
		defer_reload = function(callback)
			runtime.deferred_reloads = runtime.deferred_reloads + 1
			callback()
		end,
		snapshot = noop,
	}

	local function root_count()
		local roots = rawget(_G, "script_watchers")
		return type(roots) == "table" and #roots or 0
	end

	hs.pathwatcher = {
		new = function(_path, callback)
			runtime.construct_count = runtime.construct_count + 1
			local index = runtime.construct_count
			runtime.callbacks[index] = callback
			local constructor_mode = index == options.constructor_at
				and options.constructor_mode or "commit"
			if constructor_mode == "throw" then error("constructor refused") end
			if constructor_mode == "nil" then return nil end
			if constructor_mode == "false" then return false end
			if constructor_mode == "malformed-primitive" then return "watcher" end
			if constructor_mode == "malformed-missing-start" then
				return { stop = function() return nil end }
			end
			if constructor_mode == "malformed-missing-stop" then
				return { start = function(self) return self end }
			end

			local watcher = {
				index = index,
				running = false,
				start_mode = index == options.start_at and options.start_mode or "commit",
				stop_mode = options.stop_modes and options.stop_modes[index] or "void",
			}
			function watcher:start()
				runtime.start_order[#runtime.start_order + 1] = self.index
				runtime.publication_counts[#runtime.publication_counts + 1] = root_count()
				self.running = true
				if options.callback_during_start then
					runtime.callbacks[self.index](CALLBACK_PATHS[self.index])
				end
				if self.start_mode == "throw" then error("start refused after activation") end
				if self.start_mode == "nil" then return nil end
				if self.start_mode == "false" then return false end
				if self.start_mode == "wrong-owner" then
					local wrong_owner = {}
					function wrong_owner:stop()
						runtime.wrong_owner_stops = runtime.wrong_owner_stops + 1
					end
					return wrong_owner
				end
				return self
			end
			function watcher:stop()
				runtime.stop_order[#runtime.stop_order + 1] = self.index
				runtime.stop_handles[#runtime.stop_handles + 1] = self
				runtime.stop_publication_counts[#runtime.stop_publication_counts + 1] = root_count()
				if self.stop_mode == "throw" then error("stop refused") end
				if self.stop_mode == "false" then return false end
				self.running = false
				if self.stop_mode == "self" then return self end
				return nil
			end
			runtime.watchers[index] = watcher
			return watcher
		end,
	}

	hs.timer = {
		doAfter = function(_delay, callback)
			runtime.timer_arms = runtime.timer_arms + 1
			runtime.timer_callbacks[#runtime.timer_callbacks + 1] = callback
			return { stop = function()
				runtime.timer_stops = runtime.timer_stops + 1
				return nil
			end }
		end,
		secondsSinceEpoch = function() return runtime.clock end,
	}
	hs.reload = function() runtime.reloads = runtime.reloads + 1 end
	_G.script_watchers = nil
	package.loaded["infra.file_watchers"] = nil

	local ok, err = xpcall(function()
		local FileWatchers = require("infra.file_watchers")
		scenario(FileWatchers, runtime)
	end, debug.traceback)

	package.loaded["infra.file_watchers"] = saved_file_watchers
	package.loaded["infra.ui_restore"] = saved_ui_restore
	package.loaded["infra.logger"] = saved_logger
	hs.pathwatcher = saved_pathwatcher
	hs.timer = saved_timer
	hs.reload = saved_reload
	_G.script_watchers = saved_roots

	if not ok then error(err, 0) end
end





-- =============================================
-- =============================================
-- ======= 2/ Acquisition Failure Matrix =======
-- =============================================
-- =============================================

helpers.describe("file watchers stage every native acquisition before publication", function()
	local constructor_modes = {
		"nil",
		"false",
		"throw",
		"malformed-primitive",
		"malformed-missing-start",
		"malformed-missing-stop",
	}
	for _, mode in ipairs(constructor_modes) do
		for _, failed_index in ipairs({ 1, 3 }) do
			helpers.it("rejects constructor " .. mode .. " at stage " .. failed_index, function()
				with_fixture({
					constructor_at = failed_index,
					constructor_mode = mode,
				}, function(FileWatchers, runtime)
					helpers.assert_eq(FileWatchers.start(START_CONTEXT), false,
						"constructor refusal must return literal false")
					helpers.assert_eq(runtime.construct_count, failed_index,
						"no successor may be acquired after refusal")
					helpers.assert_eq(join_trace(runtime.start_order),
						ascending_trace(failed_index - 1))
					helpers.assert_eq(join_trace(runtime.stop_order),
						descending_trace(failed_index - 1),
						"committed predecessors must roll back in reverse order")
					helpers.assert_nil(rawget(_G, "script_watchers"),
						"a fully settled refusal must publish no composite owner")
					fire_captured_callbacks(runtime)
					helpers.assert_eq(runtime.timer_arms, 0,
						"never-committed callbacks must remain inert")
				end)
			end)
		end
	end

	for _, mode in ipairs(constructor_modes) do
		helpers.it("allows unavailable personal-root constructor " .. mode, function()
			with_fixture({
				constructor_at = 2,
				constructor_mode = mode,
			}, function(FileWatchers, runtime)
				helpers.assert_eq(FileWatchers.start(START_CONTEXT), true,
					"the personal root is optional only at constructor availability")
				helpers.assert_eq(runtime.construct_count, 3,
					"the required project watcher must still be acquired")
				helpers.assert_eq(join_trace(runtime.start_order), "1,3")
				helpers.assert_eq(join_trace(runtime.publication_counts), "0,0",
					"optional unavailability must not publish between required stages")
				helpers.assert_eq(#_G.script_watchers, 1)
				runtime.clock = 10
				runtime.callbacks[2](CALLBACK_PATHS[2])
				helpers.assert_eq(runtime.timer_arms, 0,
					"an unavailable constructor's escaped callback must stay inert")
				helpers.assert_eq(_G.script_watchers[1]:stop(), true)
				helpers.assert_eq(join_trace(runtime.stop_order), "3,1")
			end)
		end)
	end

	for _, mode in ipairs({ "nil", "false", "throw", "wrong-owner" }) do
		for failed_index = 1, 3 do
			helpers.it("rejects start " .. mode .. " at stage " .. failed_index, function()
				with_fixture({
					start_at = failed_index,
					start_mode = mode,
				}, function(FileWatchers, runtime)
					helpers.assert_eq(FileWatchers.start(START_CONTEXT), false,
						"start refusal must return literal false")
					helpers.assert_eq(runtime.construct_count, failed_index,
						"no successor may be constructed over a refused start")
					helpers.assert_eq(join_trace(runtime.stop_order), descending_trace(failed_index),
						"the failing candidate and predecessors must roll back in reverse order")
					for index = 1, failed_index do
						helpers.assert_eq(runtime.watchers[index].running, false,
							"rollback must settle watcher " .. index)
						helpers.assert_true(runtime.stop_handles[failed_index - index + 1]
							== runtime.watchers[index], "rollback must stop the exact staged object")
					end
					helpers.assert_eq(runtime.wrong_owner_stops, 0,
						"a foreign return value is not the constructed capability")
					helpers.assert_nil(rawget(_G, "script_watchers"))
					fire_captured_callbacks(runtime)
					helpers.assert_eq(runtime.timer_arms, 0,
						"rolled-back callbacks must remain inert")
				end)
			end)
		end
	end
end)





-- ========================================
-- ========================================
-- ======= 3/ Cleanup Debt & Commit =======
-- ========================================
-- ========================================

helpers.describe("file watcher rollback retains only exact cleanup debt", function()
	for _, stop_mode in ipairs({ "false", "throw" }) do
		helpers.it("retries the same rollback-refused watcher after " .. stop_mode, function()
			with_fixture({
				start_at = 3,
				start_mode = "false",
				stop_modes = { [2] = stop_mode },
			}, function(FileWatchers, runtime)
				helpers.assert_eq(FileWatchers.start(START_CONTEXT), false)
				helpers.assert_eq(join_trace(runtime.stop_order), "3,2,1",
					"rollback must continue past one refusing stop")
				helpers.assert_eq(join_trace(runtime.stop_publication_counts), "0,0,0",
					"cleanup-debt ownership must publish only after the rollback pass")
				helpers.assert_true(type(_G.script_watchers) == "table")
				helpers.assert_eq(#_G.script_watchers, 1,
					"cleanup debt needs one rooted retry owner, not a success publication")
				helpers.assert_eq(runtime.watchers[1].running, false)
				helpers.assert_eq(runtime.watchers[2].running, true)
				helpers.assert_eq(runtime.watchers[3].running, false)
				fire_captured_callbacks(runtime)
				helpers.assert_eq(runtime.timer_arms, 0,
					"rollback-debt callbacks must already be revoked")

				runtime.watchers[2].stop_mode = "void"
				local retained = runtime.watchers[2]
				helpers.assert_eq(_G.script_watchers[1]:stop(), true,
					"shutdown retry must settle the retained exact debt")
				helpers.assert_eq(join_trace(runtime.stop_order), "3,2,1,2")
				helpers.assert_true(runtime.stop_handles[4] == retained,
					"retry must target the exact object whose first stop refused")
				helpers.assert_eq(retained.running, false)
				helpers.assert_eq(_G.script_watchers[1]:stop(), true)
				helpers.assert_eq(join_trace(runtime.stop_order), "3,2,1,2",
					"settled cleanup must not be stopped twice")
			end)
		end)
	end

	helpers.it("publishes one owner only after all exact starts commit", function()
		with_fixture({ callback_during_start = true }, function(FileWatchers, runtime)
			helpers.assert_eq(FileWatchers.start(START_CONTEXT), true,
				"the sole success exit must be literal true")
			helpers.assert_eq(join_trace(runtime.start_order), "1,2,3")
			helpers.assert_eq(join_trace(runtime.publication_counts), "0,0,0",
				"no start boundary may observe a prematurely published owner")
			helpers.assert_eq(runtime.timer_arms, 0,
				"callbacks delivered synchronously by start must remain pre-commit inert")
			helpers.assert_true(type(_G.script_watchers) == "table")
			helpers.assert_eq(#_G.script_watchers, 1)

			runtime.clock = 10
			runtime.callbacks[3](CALLBACK_PATHS[3])
			helpers.assert_eq(runtime.timer_arms, 1,
				"a committed project watcher callback must reach the debounce owner")
			local queued_timer = runtime.timer_callbacks[1]
			helpers.assert_eq(_G.script_watchers[1]:stop(), true,
				"native void stop returns must commit teardown")
			helpers.assert_eq(join_trace(runtime.stop_order), "3,2,1")
			helpers.assert_eq(runtime.timer_stops, 1)

			queued_timer()
			fire_captured_callbacks(runtime)
			helpers.assert_eq(runtime.reloads, 0,
				"queued native callbacks must be inert after logical revocation")
			helpers.assert_eq(runtime.timer_arms, 1,
				"revoked callbacks must not acquire successor timers")
		end)
	end)
end)





-- ======================================
-- ======================================
-- ======= 4/ Root Boot Admission =======
-- ======================================
-- ======================================

--- Removes Lua line and long-bracket comments before executable assertions.
--- @param source string Lua source.
--- @return string code
local function strip_comments(source)
	local code = source
	local cursor = 1
	while true do
		local open_at, open_end, equals = code:find("%-%-%[(=*)%[", cursor)
		if not open_at then break end
		local close_token = "]" .. equals .. "]"
		local _, close_end = code:find(close_token, open_end + 1, true)
		if not close_end then
			code = code:sub(1, open_at - 1)
			break
		end
		local block = code:sub(open_at, close_end)
		local newlines = block:gsub("[^\n]", "")
		code = code:sub(1, open_at - 1) .. newlines .. code:sub(close_end + 1)
		cursor = open_at + #newlines
	end
	return (code:gsub("%-%-[^\n]*", ""))
end

--- Replaces one exact spelling and proves the mutation precondition.
--- @param source string Original source.
--- @param needle string Exact text to replace.
--- @param replacement string Replacement text.
--- @return string mutant
local function replace_plain(source, needle, replacement)
	local at = source:find(needle, 1, true)
	helpers.assert_true(at ~= nil, "mutation precondition missing: " .. needle)
	return source:sub(1, at - 1) .. replacement .. source:sub(at + #needle)
end

--- Proves only literal true crosses into post-watcher warmup.
--- @param source string Root source or mutation.
--- @return boolean valid
local function boot_contract_is_exact(source)
	local code = strip_comments(source)
	local assignment_at = code:find(START_ASSIGNMENT, 1, true)
	local personal_info_at = code:find(PERSONAL_INFO_WIRING, 1, true)
	local guard_at = code:find(EXACT_BOOT_GUARD, 1, true)
	local failure_at = code:find(BOOT_FAILURE, 1, true)
	local warmup_at = code:find(ROOT_ANCHOR, 1, true)
	return assignment_at ~= nil
		and personal_info_at ~= nil
		and guard_at ~= nil
		and failure_at ~= nil
		and warmup_at ~= nil
		and assignment_at < personal_info_at
		and personal_info_at < guard_at
		and guard_at < failure_at
		and failure_at < warmup_at
end

helpers.describe("root boot consumes file-watcher startup refusal", function()
	local root_source, root_source_err = helpers.read_driver_unit(ROOT_ANCHOR)

	helpers.it("locates the root and aborts before post-watcher warmup", function()
		helpers.assert_nil(root_source_err)
		helpers.assert_true(type(root_source) == "string" and root_source ~= "")
		helpers.assert_true(boot_contract_is_exact(root_source),
			"nil/false watcher startup must abort before warmup and boot success")
	end)

	helpers.it("kills unwired, truthy, false-only, and log-only boot mutants", function()
		local unwired_mutant = replace_plain(
			root_source,
			PERSONAL_INFO_WIRING,
			"-- " .. PERSONAL_INFO_WIRING
		)
		local block_unwired_mutant = replace_plain(
			root_source,
			PERSONAL_INFO_WIRING,
			"--[=[" .. PERSONAL_INFO_WIRING .. "]=]"
		)
		local truthy_mutant = replace_plain(
			root_source,
			EXACT_BOOT_GUARD,
			"if not file_watchers_committed then"
		)
		local false_only_mutant = replace_plain(
			root_source,
			EXACT_BOOT_GUARD,
			"if file_watchers_committed == false then"
		)
		local log_only_mutant = replace_plain(
			root_source,
			BOOT_FAILURE,
			'Logger.error(LOG, "file-watcher startup did not commit")'
		)
		helpers.assert_eq(boot_contract_is_exact(unwired_mutant), false)
		helpers.assert_eq(boot_contract_is_exact(block_unwired_mutant), false)
		helpers.assert_eq(boot_contract_is_exact(truthy_mutant), false)
		helpers.assert_eq(boot_contract_is_exact(false_only_mutant), false)
		helpers.assert_eq(boot_contract_is_exact(log_only_mutant), false)
	end)
end)
