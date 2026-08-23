--- tests/unit/platform/remap/test_onboarding_install_lifecycle.lua

--- ==============================================================================
--- MODULE: Karabiner Onboarding Installer Lifecycle Regression Tests
--- DESCRIPTION:
--- Drives the real download, checksum, mount, and privileged-install chain with
--- native-shaped task handles. It proves revocation retains every exact subprocess,
--- temporary artifact, and mounted volume; pause, disable, and teardown publish
--- success only after settlement, or an immediate terminal failure while cleanup
--- debt remains owned.
---
--- FEATURES & RATIONALE:
--- 1. Stage Fences: A completion delivered after stop cannot construct a successor.
--- 2. Native Settlement: False, thrown, and task-self terminate results retain the
---    exact handle until callback settlement or a successful retry.
--- 3. Artifact Isolation: Every attempt writes a unique partial and can remove only
---    that path; a verified cache remains available until atomic replacement.
--- 4. Mount Cleanup: A stale attach completion detaches its exact volume once.
--- ==============================================================================

local helpers = require("tests.helpers")

local TEST_SHA = string.rep("a", 64)
local CACHE_PATH = "/cache/Karabiner-Elements.dmg"
local OTHER_PARTIAL = "/cache/unrelated-download.part"
local CLEANUP_DEADLINE_PROBE_LIMIT = 10





-- ===========================================
-- ===========================================
-- ======= 1/ Native-Faithful Fixture ========
-- ===========================================
-- ===========================================

local MODULE_NAMES = {
	"adapters.task_lifecycle",
	"adapters.timer_scheduler",
	"hs",
	"infra.dialog_util",
	"infra.i18n",
	"infra.logger",
	"infra.notifications",
	"infra.text_utils",
	"platform.remap.ke_paths",
	"platform.remap.onboarding",
	"tests.stubs.hs",
}

--- Returns the installer stage represented by an executable path.
--- @param executable string Native executable path.
--- @return string stage Stable lifecycle stage.
local function stage_for_executable(executable)
	if executable == "/usr/bin/curl" then return "download" end
	if executable == "/usr/bin/shasum" then return "checksum" end
	if executable == "/usr/bin/hdiutil" then return "mount" end
	if executable == "/usr/bin/osascript" then return "install" end
	error("unexpected onboarding executable: " .. tostring(executable))
end

--- Reads one argv value following an exact option.
--- @param args table Native argv.
--- @param option string Option whose value follows it.
--- @return string|nil value
local function argument_after(args, option)
	for index, value in ipairs(args or {}) do
		if value == option then return args[index + 1] end
	end
	return nil
end

--- Runs one isolated installer scenario and restores every global boundary.
--- @param options table|nil Failure injection and initial-file options.
--- @param scenario function Scenario receiving onboarding, calls, and files.
local function with_fixture(options, scenario)
	options = options or {}
	local saved_modules = {}
	for _, name in ipairs(MODULE_NAMES) do
		saved_modules[name] = package.loaded[name]
		package.loaded[name] = nil
	end

	local saved_hs = _G.hs
	local saved_open = io.open
	local saved_remove = os.remove
	local saved_rename = os.rename
	local files = {}
	for path, present in pairs(options.files or {}) do files[path] = present end
	local calls = {
		detach_failures_remaining = options.detach_failures or 0,
		detaches = {},
		detach_result_index = 0,
		removes = {},
		remove_result_index = 0,
		renames = {},
		tasks = {},
		timer_after_attempts = 0,
		timer_cancel_attempts = 0,
		timer_every_attempts = 0,
		timers = {},
	}
	local onboarding

	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub

	io.open = function(path, mode)
		if mode == "r" and files[path] == true then
			return { close = function() end }
		end
		return nil, "No such file"
	end
	os.remove = function(path)
		calls.removes[#calls.removes + 1] = path
		calls.remove_result_index = calls.remove_result_index + 1
		local configured_result = nil
		if type(options.remove_results) == "table" then
			configured_result = options.remove_results[calls.remove_result_index]
		end
		if configured_result == "throw" then error("synthetic remove failure") end
		if configured_result == false then return nil, "remove refused", 13 end
		if options.remove_refuses == true or options.remove_refuses == path then
			return nil, "remove refused", 13
		end
		files[path] = nil
		return true
	end
	os.rename = function(source, destination)
		calls.renames[#calls.renames + 1] = { source = source, destination = destination }
		if options.rename_refuses == true then return nil, "rename refused", 13 end
		if files[source] ~= true then return nil, "source missing", 2 end
		files[source] = nil
		files[destination] = true
		return true
	end

	hs_stub.execute = function(command)
		if command:find("/usr/bin/hdiutil detach ", 1, true) then
			calls.detaches[#calls.detaches + 1] = command
			calls.detach_result_index = calls.detach_result_index + 1
			local configured_result = nil
			if type(options.detach_results) == "table" then
				configured_result = options.detach_results[calls.detach_result_index]
			end
			if configured_result == "throw" then error("synthetic detach failure") end
			if configured_result == false then
				return "detach refused", false, "exit", 1
			end
			if calls.detach_failures_remaining > 0 then
				calls.detach_failures_remaining = calls.detach_failures_remaining - 1
				return "detach refused", false, "exit", 1
			end
			return "", true, "exit", 0
		end
		if command:find("/bin/ls ", 1, true) then
			return "Karabiner-Elements.pkg\n", true, "exit", 0
		end
		return "", true, "exit", 0
	end

	local start_indexes = {}
	local terminate_indexes = {}
	hs_stub.task.new = function(executable, callback, args)
		local stage = stage_for_executable(executable)
		local task = {
			args = args or {},
			callback = callback,
			executable = executable,
			stage = stage,
			start_calls = 0,
			terminate_calls = 0,
		}
		calls.tasks[#calls.tasks + 1] = task

		function task:start()
			self.start_calls = self.start_calls + 1
			start_indexes[stage] = (start_indexes[stage] or 0) + 1
			local start_sequence = options.start_results and options.start_results[stage]
			local start_result = nil
			if type(start_sequence) == "table" then
				start_result = start_sequence[start_indexes[stage]]
			end
			if start_result == nil then start_result = "self" end
			self.pinned_at_start = onboarding ~= nil
				and onboarding._active_tasks[self] ~= nil
			if stage == "download" then
				local output = argument_after(self.args, "--output")
				if output then files[output] = true end
			end
			local complete_on_start = options.complete_on_start == true
			if type(options.complete_on_start_stages) == "table" then
				complete_on_start = options.complete_on_start_stages[stage] == true
			end
			if complete_on_start then
				if stage == "checksum" then
					self:complete(0, TEST_SHA .. "  synchronous.dmg\n", "")
				elseif stage == "mount" then
					self:complete(0,
						"/dev/disk9\tApple_HFS\t/Volumes/Synchronous Karabiner\n", "")
				else
					self:complete(0, "", "")
				end
			end
			if start_result == "throw" then
				self.last_start_kind = "throw"
				error("synthetic " .. stage .. " start failure")
			end
			if start_result == "nil" then
				self.last_start_kind = "nil"
				return nil
			end
			if start_result == "self" then
				self.last_start_kind = "self"
				return self
			end
			self.last_start_kind = start_result == false and "false" or tostring(start_result)
			return start_result
		end

		function task:terminate()
			self.terminate_calls = self.terminate_calls + 1
			terminate_indexes[stage] = (terminate_indexes[stage] or 0) + 1
			local sequence = options.terminate_results and options.terminate_results[stage]
			local result = nil
			if type(sequence) == "table" then
				result = sequence[terminate_indexes[stage]]
			end
			if result == nil then result = "self" end
			local complete_on_terminate = options.complete_on_terminate == true
			if type(options.complete_on_terminate_stages) == "table" then
				complete_on_terminate = options.complete_on_terminate_stages[stage] == true
			end
			if complete_on_terminate then
				self:complete(1, "", "synchronous termination")
			end
			if result == "throw" then
				self.last_terminate_kind = "throw"
				error("synthetic " .. stage .. " terminate failure")
			end
			if result == "nil" then
				self.last_terminate_kind = "nil"
				return nil
			end
			if result == "self" then
				self.last_terminate_kind = "self"
				return self
			end
			self.last_terminate_kind = result == false and "false" or tostring(result)
			return result
		end

		function task:complete(rc, stdout, stderr)
			return self.callback(rc or 0, stdout or "", stderr or "")
		end

		return task
	end

	local function noop() end
	local timer_scheduler = {}
	function timer_scheduler.after(delay, callback)
			for _, retained in ipairs(calls.timers) do
				if retained.timer ~= nil and retained.committed ~= true then
					timer_scheduler.cancel(retained)
				end
			end
			calls.timer_after_attempts = calls.timer_after_attempts + 1
			local configured_result = nil
			if type(options.timer_after_results) == "table" then
				configured_result = options.timer_after_results[calls.timer_after_attempts]
			end
			calls.last_timer_after_kind = tostring(configured_result)
			if configured_result == "throw" then error("synthetic timer arm failure") end
			local timer = {
				callback = callback,
				cancelled = false,
				committed = true,
				delay = delay,
				fired = false,
				timer = {},
			}
			calls.timers[#calls.timers + 1] = timer
			if configured_result == false then
				timer.committed = false
				return timer, false
			end
			if configured_result == "nil" then
				timer.committed = false
				return timer, nil
			end
			return timer, true
	end
	function timer_scheduler.cancel(timer)
			if not timer or timer.timer == nil then return true end
			calls.timer_cancel_attempts = calls.timer_cancel_attempts + 1
			timer.committed = false
			local configured_result = nil
			if type(options.timer_cancel_results) == "table" then
				configured_result = options.timer_cancel_results[calls.timer_cancel_attempts]
			end
			if configured_result == "throw" then error("synthetic timer cancel failure") end
			if configured_result == false then return false end
			if configured_result == "nil" then return nil end
			timer.cancelled = true
			timer.timer = nil
			return true
	end
	function timer_scheduler.every(delay, callback)
		calls.timer_every_attempts = calls.timer_every_attempts + 1
		local timer = {
			callback = callback,
			cancelled = false,
			committed = true,
			delay = delay,
			fired = false,
			timer = {},
		}
		calls.timers[#calls.timers + 1] = timer
		return timer, true
	end
	package.loaded["adapters.timer_scheduler"] = timer_scheduler
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.logger"] = setmetatable({}, { __index = function() return noop end })
	package.loaded["infra.notifications"] = { notify = noop }
	package.loaded["infra.text_utils"] = {
		applescript_format = function(format, value) return string.format(format, value) end,
		escape_gsub_replacement = function(value) return value end,
		shell_quote = function(value) return value end,
	}
	package.loaded["platform.remap.ke_paths"] = {
		CLI = "/test/karabiner_cli",
		CORE_SERVICE = "/test/Karabiner-Core-Service",
		GRABBER = "/test/karabiner_grabber",
	}

	package.loaded["adapters.task_lifecycle"] = nil
	package.loaded["platform.remap.onboarding"] = nil
	onboarding = require("platform.remap.onboarding")
	onboarding.load_manifest = function()
		return {
			file_name = "Karabiner-Elements.dmg",
			sha256 = TEST_SHA,
			source_url = "https://example.invalid/Karabiner-Elements.dmg",
			version = "99.0.0",
		}
	end
	onboarding.get_cache_dmg_path = function() return CACHE_PATH end
	function calls.fire_next_timer()
		for _, timer in ipairs(calls.timers) do
			if timer.timer ~= nil and timer.cancelled ~= true
				and timer.committed == true and timer.fired ~= true then
				timer.fired = true
				timer.committed = false
				timer_scheduler.cancel(timer)
				timer.callback()
				return true
			end
		end
		for _, timer in ipairs(calls.timers) do
			if timer.timer ~= nil and timer.cancelled ~= true then
				timer_scheduler.cancel(timer)
				return true
			end
		end
		return false
	end

	local ok, err = xpcall(function() scenario(onboarding, calls, files) end, debug.traceback)
	io.open = saved_open
	os.remove = saved_remove
	os.rename = saved_rename
	_G.hs = saved_hs
	for _, name in ipairs(MODULE_NAMES) do package.loaded[name] = saved_modules[name] end
	if not ok then error(err, 0) end
end

--- Returns every constructed task for one stable stage.
--- @param calls table Fixture observations.
--- @param stage string Stable lifecycle stage.
--- @return table[] tasks
local function tasks_for_stage(calls, stage)
	local matches = {}
	for _, task in ipairs(calls.tasks) do
		if task.stage == stage then matches[#matches + 1] = task end
	end
	return matches
end

--- Advances a cache-miss install until the requested task is active.
--- @param onboarding table Onboarding module.
--- @param calls table Fixture observations.
--- @param target_stage string download | checksum | mount | install.
--- @param callback function|nil Public installer terminal observer.
--- @return table task Exact active task.
local function advance_to_stage(onboarding, calls, target_stage, callback)
	helpers.assert_true(onboarding.install_karabiner_elements(callback or function() end) ~= false)
	local downloads = tasks_for_stage(calls, "download")
	local download = downloads[#downloads]
	helpers.assert_not_nil(download, "the real pipeline must construct its download task")
	if target_stage == "download" then return download end

	download:complete(0, "", "")
	local checksums = tasks_for_stage(calls, "checksum")
	local checksum = checksums[#checksums]
	helpers.assert_not_nil(checksum, "download success must construct its checksum successor")
	if target_stage == "checksum" then return checksum end

	checksum:complete(0, TEST_SHA .. "  partial.dmg\n", "")
	local mounts = tasks_for_stage(calls, "mount")
	local mount = mounts[#mounts]
	helpers.assert_not_nil(mount, "verified bytes must construct their mount successor")
	if target_stage == "mount" then return mount end

	mount:complete(0, "/dev/disk9\tApple_HFS\t/Volumes/Karabiner Test\n", "")
	local installs = tasks_for_stage(calls, "install")
	local install = installs[#installs]
	helpers.assert_not_nil(install, "mounted package discovery must construct the installer successor")
	return install
end

--- Counts exact path occurrences in an array.
--- @param values string[] Recorded paths.
--- @param expected string Exact path.
--- @return number count
local function count_path(values, expected)
	local count = 0
	for _, value in ipairs(values) do
		if value == expected then count = count + 1 end
	end
	return count
end





-- =============================================
-- =============================================
-- ======= 2/ Exact Stage Revocation ===========
-- =============================================
-- =============================================

helpers.describe("HS-011 onboarding installer owns every asynchronous stage", function()
	for _, stage in ipairs({ "download", "checksum", "mount", "install" }) do
		helpers.it("HS-011 stop after " .. stage .. " fences its old completion", function()
			with_fixture({}, function(onboarding, calls)
				local task = advance_to_stage(onboarding, calls, stage)
				local constructions_before_stop = #calls.tasks
				helpers.assert_true(task.pinned_at_start == true,
					stage .. " must be pinned before native start can synchronously complete")
				helpers.assert_true(onboarding.stop() == false,
					"native terminate returning the task itself is acceptance, not settlement")
				helpers.assert_eq(task.terminate_calls, 1)

				if stage == "checksum" then
					task:complete(0, TEST_SHA .. "  stale.dmg\n", "")
				elseif stage == "mount" then
					task:complete(0, "/dev/disk9\tApple_HFS\t/Volumes/Stale Karabiner\n", "")
				else
					task:complete(0, "", "")
				end

				helpers.assert_eq(#calls.tasks, constructions_before_stop,
					"a revoked " .. stage .. " callback must construct zero successors")
				helpers.assert_true(onboarding.stop() == true,
					"callback settlement must release the exact retained task")
				if stage == "mount" then
					helpers.assert_eq(#calls.detaches, 1,
						"a stale successful attach must detach its exact volume once")
					helpers.assert_contains(calls.detaches[1], "/Volumes/Stale Karabiner")
				elseif stage == "install" then
					helpers.assert_eq(#calls.detaches, 1,
						"stop and late install completion must not detach the owned mount twice")
				end
			end)
		end)
	end

	helpers.it("HS-011 retains stale mount cleanup debt until exact detach retry", function()
		with_fixture({ detach_failures = 1 }, function(onboarding, calls)
			local mount = advance_to_stage(onboarding, calls, "mount")
			helpers.assert_true(onboarding.stop() == false)
			mount:complete(0, "/dev/disk9\tApple_HFS\t/Volumes/Stale Retry\n", "")

			helpers.assert_eq(#calls.detaches, 1,
				"one stale completion gets one exact detach attempt")
			helpers.assert_not_nil(onboarding._install_owner,
				"a refused detach must retain cleanup ownership")
			helpers.assert_true(calls.fire_next_timer(),
				"the exact retained mount must retry without another user action")
			helpers.assert_eq(#calls.detaches, 2)
			helpers.assert_eq(calls.detaches[2], calls.detaches[1])
			helpers.assert_nil(onboarding._install_owner)
		end)
	end)
end)





-- ===========================================
-- ===========================================
-- ======= 3/ Native Termination Debt ========
-- ===========================================
-- ===========================================

helpers.describe("HS-011 onboarding retains exact native termination debt", function()
	for _, signal in ipairs({ true, "self" }) do
		helpers.it("HS-011 terminate signal " .. tostring(signal) .. " waits for exact exit", function()
			with_fixture({ terminate_results = { download = { signal } } },
				function(onboarding, calls)
				local order = {}
				local task = advance_to_stage(onboarding, calls, "download", function(ok, detail)
					order[#order + 1] = { kind = "installer", ok = ok, detail = detail }
				end)

				helpers.assert_true(onboarding.stop(function(ok, detail)
					order[#order + 1] = { kind = "stop", ok = ok, detail = detail }
				end), "callback-form stop must join an accepted termination signal")
				helpers.assert_eq(#order, 0,
					"truthy terminate return is not proof that the subprocess exited")
				helpers.assert_true(onboarding._active_tasks[task] ~= nil)
				helpers.assert_eq(task.terminate_calls, 1)

				local construction_count = #calls.tasks
				task:complete(1, "", "cancelled")
				helpers.assert_eq(#order, 2)
				helpers.assert_eq(order[1].kind, "installer",
					"the installer terminal must precede the joined stop continuation")
				helpers.assert_true(order[1].ok == false)
				helpers.assert_eq(order[2].kind, "stop")
				helpers.assert_true(order[2].ok == true)
				helpers.assert_nil(onboarding._install_owner)
				helpers.assert_nil(onboarding._active_tasks[task])
				helpers.assert_eq(#calls.tasks, construction_count,
					"revoked task completion must construct zero successors")
			end)
		end)
	end

	helpers.it("HS-011 retries join an already accepted terminate signal", function()
		with_fixture({ terminate_results = { download = { true, false } } },
			function(onboarding, calls)
				local order = {}
				local task = advance_to_stage(onboarding, calls, "download", function(ok)
					order[#order + 1] = { kind = "installer", ok = ok }
				end)
				helpers.assert_true(onboarding.stop(function(ok)
					order[#order + 1] = { kind = "stop", ok = ok }
				end))
				helpers.assert_eq(task.terminate_calls, 1)
				helpers.assert_true(calls.fire_next_timer())
				helpers.assert_eq(task.terminate_calls, 1,
					"cleanup deadline ticks must not re-signal an accepted task")
				helpers.assert_eq(#order, 0,
					"an accepted signal waits for exact completion or the named deadline")

				task:complete(1, "", "cancelled")
				helpers.assert_eq(#order, 2)
				helpers.assert_eq(order[1].kind, "installer")
				helpers.assert_true(order[1].ok == false)
				helpers.assert_eq(order[2].kind, "stop")
				helpers.assert_true(order[2].ok == true)
			end)
	end)

	helpers.it("HS-011 repeated stop joins an already accepted terminate signal", function()
		with_fixture({ terminate_results = { download = { "self", false } } },
			function(onboarding, calls)
				local order = {}
				local task = advance_to_stage(onboarding, calls, "download", function(ok)
					order[#order + 1] = { kind = "installer", ok = ok }
				end)
				helpers.assert_true(onboarding.stop(function(ok)
					order[#order + 1] = { kind = "stop-1", ok = ok }
				end))
				helpers.assert_true(onboarding.stop(function(ok)
					order[#order + 1] = { kind = "stop-2", ok = ok }
				end))
				helpers.assert_eq(task.terminate_calls, 1,
					"a joined lifecycle caller must not re-signal an accepted task")
				helpers.assert_eq(#order, 0)

				task:complete(1, "", "cancelled")
				helpers.assert_eq(#order, 3)
				helpers.assert_eq(order[1].kind, "installer")
				helpers.assert_true(order[1].ok == false)
				helpers.assert_eq(order[2].kind, "stop-1")
				helpers.assert_true(order[2].ok == true)
				helpers.assert_eq(order[3].kind, "stop-2")
				helpers.assert_true(order[3].ok == true)
			end)
	end)

	for _, refusal in ipairs({ false, "nil", "throw" }) do
		helpers.it("HS-011 terminate refusal " .. tostring(refusal) .. " is terminal", function()
			with_fixture({
				terminate_results = { download = { refusal, "self" } },
			}, function(onboarding, calls)
				local order = {}
				local task = advance_to_stage(onboarding, calls, "download", function(ok)
					order[#order + 1] = { kind = "installer", ok = ok }
				end)
				helpers.assert_true(onboarding.stop(function(ok)
					order[#order + 1] = { kind = "stop", ok = ok }
				end))
				helpers.assert_eq(#order, 2,
					"a refused termination request must publish terminal failure immediately")
				helpers.assert_eq(order[1].kind, "installer")
				helpers.assert_true(order[1].ok == false)
				helpers.assert_eq(order[2].kind, "stop")
				helpers.assert_true(order[2].ok == false)
				helpers.assert_eq(task.last_terminate_kind, tostring(refusal),
					"the fixture must preserve a literal false rather than coalescing it")
				helpers.assert_true(onboarding._active_tasks[task] ~= nil,
					"terminal failure must retain exact cleanup debt")
				helpers.assert_eq(task.terminate_calls, 1)

				helpers.assert_true(calls.fire_next_timer(),
					"cleanup retry must be autonomous after the public terminal")
				helpers.assert_eq(task.terminate_calls, 2,
					"the timer must signal the same exact task without a second user action")
				local construction_count = #calls.tasks
				task:complete(0, "", "")
				helpers.assert_nil(onboarding._active_tasks[task])
				helpers.assert_nil(onboarding._install_owner)
				helpers.assert_eq(#order, 2,
					"cleanup completion must not redeliver terminal failure")
				helpers.assert_eq(#calls.tasks, construction_count,
					"cleanup retry must never construct a new installer stage")
			end)
		end)
	end

	helpers.it("HS-011 accepted terminate reaches a bounded cleanup deadline", function()
		with_fixture({}, function(onboarding, calls)
			local order = {}
			local task = advance_to_stage(onboarding, calls, "download", function(ok)
				order[#order + 1] = { kind = "installer", ok = ok }
			end)
			local construction_count = #calls.tasks
			helpers.assert_true(onboarding.stop(function(ok)
				order[#order + 1] = { kind = "stop", ok = ok }
			end))
			helpers.assert_eq(#order, 0)

			local timer_fires = 0
			while calls.fire_next_timer() do
				timer_fires = timer_fires + 1
				if timer_fires >= CLEANUP_DEADLINE_PROBE_LIMIT then break end
			end
			helpers.assert_true(timer_fires > 0 and timer_fires < CLEANUP_DEADLINE_PROBE_LIMIT,
				"silent native exit must reach a finite cleanup deadline")
			helpers.assert_eq(#order, 2)
			helpers.assert_eq(order[1].kind, "installer")
			helpers.assert_true(order[1].ok == false)
			helpers.assert_eq(order[2].kind, "stop")
			helpers.assert_true(order[2].ok == false)
			helpers.assert_true(onboarding._active_tasks[task] ~= nil)
			helpers.assert_not_nil(onboarding._install_owner)
			helpers.assert_eq(#calls.tasks, construction_count,
				"deadline retries must never create a replacement task")
		end)
	end)

	for _, refusal in ipairs({ false, "nil", "throw" }) do
		helpers.it("HS-011 cleanup timer " .. tostring(refusal)
			.. " settles joined lifecycle failure", function()
			with_fixture({ timer_after_results = { refusal, refusal, refusal } },
				function(onboarding, calls)
				local order = {}
				local task = advance_to_stage(onboarding, calls, "download", function(ok)
					order[#order + 1] = { kind = "installer", ok = ok }
				end)
				helpers.assert_true(onboarding.stop(function(ok, detail)
					order[#order + 1] = { kind = "stop", ok = ok, detail = detail }
				end))
				helpers.assert_eq(calls.last_timer_after_kind, tostring(refusal),
					"the fixture must preserve the exact timer refusal shape")
				helpers.assert_eq(calls.timer_after_attempts, 3,
					"constructor refusal must consume one bounded autonomous fallback series")
				helpers.assert_eq(#order, 2,
					"retry timer refusal must not leave the lifecycle waiter pending")
				helpers.assert_eq(order[1].kind, "installer")
				helpers.assert_true(order[1].ok == false)
				helpers.assert_eq(order[2].kind, "stop")
				helpers.assert_true(order[2].ok == false)
				helpers.assert_eq(order[2].detail, "onboarding-cleanup-timer-refused")
				helpers.assert_true(onboarding._active_tasks[task] ~= nil)
				helpers.assert_not_nil(onboarding._install_owner)

				task:complete(1, "", "cancelled")
				helpers.assert_nil(onboarding._active_tasks[task])
				helpers.assert_nil(onboarding._install_owner)
				helpers.assert_eq(#order, 2,
					"late exact cleanup must not redeliver a terminal")
			end)
		end)
	end

	helpers.it("HS-011 cleanup timer constructor refusal rolls back before retry", function()
		with_fixture({ timer_after_results = { false, true } }, function(onboarding, calls)
			local order = {}
			local task = advance_to_stage(onboarding, calls, "download", function(ok)
				order[#order + 1] = { kind = "installer", ok = ok }
			end)
			local construction_count = #calls.tasks
			helpers.assert_true(onboarding.stop(function(ok)
				order[#order + 1] = { kind = "stop", ok = ok }
			end))
			helpers.assert_eq(calls.timer_after_attempts, 2,
				"a settled constructor refusal must acquire its bounded successor autonomously")
			helpers.assert_nil(calls.timers[1].timer,
				"the refused exact timer wrapper must settle before replacement")
			helpers.assert_not_nil(calls.timers[2].timer)
			helpers.assert_eq(#order, 0)

			task:complete(1, "", "cancelled")
			helpers.assert_eq(#order, 2)
			helpers.assert_eq(order[1].kind, "installer")
			helpers.assert_true(order[1].ok == false)
			helpers.assert_eq(order[2].kind, "stop")
			helpers.assert_true(order[2].ok == true)
			helpers.assert_nil(onboarding._install_owner)
			helpers.assert_eq(#calls.tasks, construction_count,
				"timer acquisition fallback must never restart the installer")
		end)
	end)

	for _, refusal in ipairs({ false, "throw" }) do
		helpers.it("HS-011 cleanup retry timer cancel " .. tostring(refusal)
			.. " retains the exact handle until autonomous settlement", function()
			with_fixture({ timer_cancel_results = { refusal, true } },
				function(onboarding, calls)
					local order = {}
					local task = advance_to_stage(onboarding, calls, "download", function(ok)
						order[#order + 1] = { kind = "installer", ok = ok }
					end)
					local construction_count = #calls.tasks
					helpers.assert_true(onboarding.stop(function(ok)
						order[#order + 1] = { kind = "stop", ok = ok }
					end))
					task:complete(1, "", "cancelled")
					helpers.assert_eq(#order, 0,
						"a refused exact timer cancellation must retain the joined waiter")
					helpers.assert_eq(calls.timer_after_attempts, 2,
						"timer debt must acquire one autonomous cleanup successor")
					helpers.assert_nil(calls.timers[1].timer,
						"the adapter retry must settle the refused predecessor exactly")
					helpers.assert_true(calls.fire_next_timer())
					helpers.assert_eq(#order, 2)
					helpers.assert_eq(order[1].kind, "installer")
					helpers.assert_true(order[1].ok == false)
					helpers.assert_eq(order[2].kind, "stop")
					helpers.assert_true(order[2].ok == true)
					helpers.assert_nil(onboarding._install_owner)
					helpers.assert_eq(#calls.tasks, construction_count)
				end)
		end)
	end

	helpers.it("HS-011 cleanup retry timer survives multiple cancel refusals", function()
		with_fixture({ timer_cancel_results = { false, false, true } },
			function(onboarding, calls)
				local order = {}
				local task = advance_to_stage(onboarding, calls, "download", function(ok)
					order[#order + 1] = { kind = "installer", ok = ok }
				end)
				local construction_count = #calls.tasks
				helpers.assert_true(onboarding.stop(function(ok)
					order[#order + 1] = { kind = "stop", ok = ok }
				end))
				task:complete(1, "", "cancelled")
				helpers.assert_eq(#order, 0)
				helpers.assert_not_nil(calls.timers[1].timer,
					"two native refusals must retain the predecessor wrapper")
				helpers.assert_true(calls.fire_next_timer())
				helpers.assert_eq(#order, 2)
				helpers.assert_eq(order[1].kind, "installer")
				helpers.assert_true(order[1].ok == false)
				helpers.assert_eq(order[2].kind, "stop")
				helpers.assert_true(order[2].ok == true)
				helpers.assert_nil(onboarding._install_owner)
				helpers.assert_nil(calls.timers[1].timer)
				helpers.assert_eq(#calls.tasks, construction_count)
			end)
	end)

	helpers.it("HS-011 cleanup retry timer cancel exhaustion is terminal and retains debt", function()
		local refusals = {}
		for index = 1, 40 do refusals[index] = false end
		with_fixture({ timer_cancel_results = refusals }, function(onboarding, calls)
			local order = {}
			local task = advance_to_stage(onboarding, calls, "download", function(ok)
				order[#order + 1] = { kind = "installer", ok = ok }
			end)
			local construction_count = #calls.tasks
			helpers.assert_true(onboarding.stop(function(ok, detail)
				order[#order + 1] = { kind = "stop", ok = ok, detail = detail }
			end))
			task:complete(1, "", "cancelled")
			for _ = 1, CLEANUP_DEADLINE_PROBE_LIMIT do
				if #order == 2 then break end
				calls.fire_next_timer()
			end
			helpers.assert_eq(calls.timer_after_attempts, 3,
				"persistent timer debt must consume only the named retry budget")
			helpers.assert_eq(#order, 2,
				"timer cancellation exhaustion must not strand the lifecycle waiter")
			helpers.assert_eq(order[1].kind, "installer")
			helpers.assert_true(order[1].ok == false)
			helpers.assert_eq(order[2].kind, "stop")
			helpers.assert_true(order[2].ok == false)
			helpers.assert_eq(order[2].detail, "onboarding-cleanup-timeout")
			helpers.assert_not_nil(onboarding._install_owner,
				"terminal failure must retain the exact timer cleanup debt")
		local retained = 0
		for _, timer in ipairs(calls.timers) do
			if timer.timer ~= nil then retained = retained + 1 end
		end
		helpers.assert_true(retained > 0)
		helpers.assert_eq(#calls.tasks, construction_count)
		end)
	end)

	for _, artifact in ipairs({ "partial", "mount" }) do
		for _, refusal in ipairs({ false, "throw" }) do
			helpers.it("HS-011 " .. artifact .. " cleanup " .. tostring(refusal)
				.. " retries autonomously", function()
				local options = { remove_results = { refusal, true } }
				if artifact == "mount" then
					options = { detach_results = { refusal, true } }
				end
				with_fixture(options, function(onboarding, calls)
					local order = {}
					local stage = "download"
					if artifact == "mount" then stage = "install" end
					local task = advance_to_stage(onboarding, calls, stage, function(ok)
						order[#order + 1] = { kind = "installer", ok = ok }
					end)
					local construction_count = #calls.tasks
					helpers.assert_true(onboarding.stop(function(ok)
						order[#order + 1] = { kind = "stop", ok = ok }
					end))
					helpers.assert_eq(#order, 0)

					task:complete(1, "", "cancelled")
					helpers.assert_eq(#order, 0,
						"artifact refusal must retain the joined lifecycle until retry")
					helpers.assert_not_nil(onboarding._install_owner)
					helpers.assert_true(calls.fire_next_timer())
					helpers.assert_eq(#order, 2)
					helpers.assert_eq(order[1].kind, "installer")
					helpers.assert_true(order[1].ok == false)
					helpers.assert_eq(order[2].kind, "stop")
					helpers.assert_true(order[2].ok == true)
					helpers.assert_nil(onboarding._install_owner)
					local attempts = #calls.removes
					if artifact == "mount" then attempts = #calls.detaches end
					helpers.assert_eq(attempts, 2)
					helpers.assert_eq(#calls.tasks, construction_count,
						"artifact cleanup retry must not create a new installer")
				end)
			end)
		end
	end

	for _, artifact in ipairs({ "partial", "mount" }) do
		for _, refusal in ipairs({ false, "throw" }) do
			helpers.it("HS-011 terminal " .. artifact .. " debt " .. tostring(refusal)
				.. " retries without another lifecycle action", function()
				local options = { remove_results = { refusal, true } }
				if artifact == "mount" then
					options = { detach_results = { refusal, true } }
				end
				with_fixture(options, function(onboarding, calls)
					local outcomes = {}
					local stage = "download"
					if artifact == "mount" then stage = "install" end
					local task = advance_to_stage(onboarding, calls, stage, function(ok, detail)
						outcomes[#outcomes + 1] = { ok = ok, detail = detail }
					end)
					local construction_count = #calls.tasks

					task:complete(1, "", "synthetic terminal failure")
					helpers.assert_eq(#outcomes, 1)
					helpers.assert_true(outcomes[1].ok == false)
					helpers.assert_not_nil(onboarding._install_owner,
						"terminal cleanup refusal must retain the exact owner")
					helpers.assert_true(calls.fire_next_timer(),
						"terminal cleanup debt must retry without Pause, Disable, or Stop")
					helpers.assert_nil(onboarding._install_owner)
					helpers.assert_eq(#outcomes, 1,
						"cleanup settlement must not redeliver the installer terminal")
					local attempts = #calls.removes
					if artifact == "mount" then attempts = #calls.detaches end
					helpers.assert_eq(attempts, 2)
					helpers.assert_eq(#calls.tasks, construction_count,
						"terminal cleanup retry must not construct a new installer stage")
				end)
			end)
		end
	end

	for _, artifact in ipairs({ "partial", "mount" }) do
		helpers.it("HS-011 terminal " .. artifact
			.. " debt retries through multiple refusals", function()
			local options = { remove_results = { false, false, true } }
			if artifact == "mount" then
				options = { detach_results = { false, false, true } }
			end
			with_fixture(options, function(onboarding, calls)
				local outcomes = {}
				local stage = artifact == "mount" and "install" or "download"
				local task = advance_to_stage(onboarding, calls, stage, function(ok)
					outcomes[#outcomes + 1] = ok
				end)
				task:complete(1, "", "synthetic terminal failure")
				helpers.assert_eq(#outcomes, 1)
				helpers.assert_true(outcomes[1] == false)
				helpers.assert_true(calls.fire_next_timer())
				helpers.assert_not_nil(onboarding._install_owner,
					"a second refusal must retain autonomous cleanup ownership")
				helpers.assert_true(calls.fire_next_timer(),
					"the same terminal debt must re-arm without user action")
				helpers.assert_nil(onboarding._install_owner)
				local attempts = #calls.removes
				if artifact == "mount" then attempts = #calls.detaches end
				helpers.assert_eq(attempts, 3)
				helpers.assert_eq(#outcomes, 1)
			end)
		end)

		helpers.it("HS-011 terminal " .. artifact
			.. " debt exhausts its bounded retry owner", function()
			local refusals = { false, false, false, false, false }
			local options = { remove_results = refusals }
			if artifact == "mount" then options = { detach_results = refusals } end
			with_fixture(options, function(onboarding, calls)
				local outcomes = {}
				local stage = artifact == "mount" and "install" or "download"
				local task = advance_to_stage(onboarding, calls, stage, function(ok)
					outcomes[#outcomes + 1] = ok
				end)
				task:complete(1, "", "synthetic terminal failure")
				local timer_fires = 0
				while calls.fire_next_timer() do
					timer_fires = timer_fires + 1
					if timer_fires >= CLEANUP_DEADLINE_PROBE_LIMIT then break end
				end
				helpers.assert_true(timer_fires > 1
					and timer_fires < CLEANUP_DEADLINE_PROBE_LIMIT)
				helpers.assert_not_nil(onboarding._install_owner,
					"exhaustion must retain exact cleanup debt")
				helpers.assert_eq(#outcomes, 1,
					"retry exhaustion must not redeliver the installer terminal")
				local attempts = #calls.removes
				if artifact == "mount" then attempts = #calls.detaches end
				helpers.assert_eq(attempts, 4,
					"one immediate attempt plus three bounded retries are expected")
			end)
		end)
	end

	helpers.it("HS-011 protects the installer terminal before stop continuation", function()
		with_fixture({}, function(onboarding, calls)
			local order = {}
			local download = advance_to_stage(onboarding, calls, "download", function(ok)
				order[#order + 1] = { kind = "installer", ok = ok }
				error("synthetic cancellation observer failure")
			end)
			helpers.assert_true(onboarding.stop(function(ok)
				order[#order + 1] = { kind = "stop", ok = ok }
			end))
			helpers.assert_eq(#order, 0)
			download:complete(1, "", "cancelled")
			helpers.assert_eq(#order, 2)
			helpers.assert_eq(order[1].kind, "installer")
			helpers.assert_eq(order[2].kind, "stop")
			helpers.assert_true(order[2].ok == true)
		end)
	end)

	helpers.it("HS-011 joins installer terminal before reporting wizard timer failure", function()
		with_fixture({ timer_cancel_results = { false, false, false } },
			function(onboarding, calls)
				local order = {}
				local task = advance_to_stage(onboarding, calls, "download", function(ok)
					order[#order + 1] = { kind = "installer", ok = ok }
				end)
				local construction_count = #calls.tasks
				package.loaded["infra.dialog_util"] = {
					block_alert = function()
						return "karabiner.onboarding.btn_open_settings"
					end,
				}
				onboarding.health_check = function()
					return {
						all_ok = false,
						ke_installed = true,
						grabber_present = true,
						sysext_activated = false,
						grabber_running = true,
					}
				end
				onboarding.open_system_extensions_pane = function() end
				onboarding.is_sysext_activated = function() return false end
				onboarding.run_first_run_wizard()
				helpers.assert_eq(calls.timer_every_attempts, 1)

				helpers.assert_true(onboarding.stop(function(ok)
					order[#order + 1] = { kind = "stop", ok = ok }
				end))
				helpers.assert_eq(#order, 0,
					"timer failure cannot overtake an accepted task termination")
				helpers.assert_eq(calls.timer_cancel_attempts, 3)
				task:complete(1, "", "cancelled")

				helpers.assert_eq(#order, 2)
				helpers.assert_eq(order[1].kind, "installer")
				helpers.assert_true(order[1].ok == false)
				helpers.assert_eq(order[2].kind, "stop")
				helpers.assert_true(order[2].ok == false)
				helpers.assert_nil(onboarding._active_tasks[task])
				helpers.assert_eq(#calls.tasks, construction_count)
			end)
	end)

	helpers.it("HS-011 a late predecessor completion cannot clear its successor owner", function()
		with_fixture({}, function(onboarding, calls)
			local predecessor = advance_to_stage(onboarding, calls, "download")
			helpers.assert_true(onboarding.stop() == false)
			predecessor:complete(1, "", "cancelled")
			advance_to_stage(onboarding, calls, "download")
			local downloads = tasks_for_stage(calls, "download")
			local successor = downloads[#downloads]
			helpers.assert_true(successor ~= predecessor)

			predecessor:complete(0, "", "duplicate")
			helpers.assert_true(onboarding._active_tasks[successor] ~= nil,
				"the old exact callback must not clear the current task pin")
			helpers.assert_eq(#tasks_for_stage(calls, "checksum"), 0)
		end)
	end)
end)





-- ==============================================
-- ==============================================
-- ======= 4/ Partial and Cache Ownership =======
-- ==============================================
-- ==============================================

helpers.describe("HS-011 onboarding stages downloads without sacrificing verified cache", function()
	for _, stage in ipairs({ "download", "checksum", "mount", "install" }) do
		helpers.it("HS-011 current " .. stage .. " completion advances its stage once", function()
			with_fixture({}, function(onboarding, calls)
				local outcomes = {}
				local task = advance_to_stage(onboarding, calls, stage, function(ok, detail)
					outcomes[#outcomes + 1] = { ok = ok, detail = detail }
				end)
				local function complete_success()
					if stage == "checksum" then
						task:complete(0, TEST_SHA .. "  exact.part\n", "")
					elseif stage == "mount" then
						task:complete(0,
							"/dev/disk9\tApple_HFS\t/Volumes/Exact Karabiner\n", "")
					else
						task:complete(0, "", "")
					end
				end

				complete_success()
				complete_success()

				if stage == "download" then
					helpers.assert_eq(#tasks_for_stage(calls, "checksum"), 1,
						"one download task may construct only one checksum successor")
				elseif stage == "checksum" then
					helpers.assert_eq(#calls.renames, 1,
						"one checksum task may promote its exact partial only once")
					helpers.assert_eq(#tasks_for_stage(calls, "mount"), 1,
						"one checksum task may construct only one mount successor")
				elseif stage == "mount" then
					helpers.assert_eq(#tasks_for_stage(calls, "install"), 1,
						"one mount task may construct only one privileged installer")
				else
					helpers.assert_eq(#outcomes, 1,
						"one installer task may publish only one terminal")
					helpers.assert_eq(#calls.detaches, 1,
						"one installer task may detach its exact volume only once")
				end
			end)
		end)
	end

	helpers.it("HS-011 owns a real completion delivered synchronously from native start", function()
		with_fixture({ complete_on_start = true }, function(onboarding, calls)
			local outcomes = {}
			helpers.assert_true(onboarding.install_karabiner_elements(function(ok, detail)
				outcomes[#outcomes + 1] = { ok = ok, detail = detail }
			end))

			helpers.assert_eq(#calls.tasks, 4)
			for _, task in ipairs(calls.tasks) do
				helpers.assert_true(task.pinned_at_start == true,
					task.stage .. " must be owned before start can call back synchronously")
			end
			helpers.assert_eq(#outcomes, 1)
			helpers.assert_true(outcomes[1].ok == true)
			helpers.assert_nil(onboarding._install_owner)
			helpers.assert_nil(next(onboarding._active_tasks),
				"synchronous native completion must leave the task GC root empty")
			helpers.assert_eq(#calls.renames, 1)
			helpers.assert_eq(#calls.detaches, 1)
		end)
	end)

	for _, stage in ipairs({ "download", "checksum", "mount", "install" }) do
		for _, refusal in ipairs({ false, "throw" }) do
			helpers.it("HS-011 buffers synchronous " .. stage .. " completion before start "
				.. tostring(refusal), function()
				local options = {
					complete_on_start_stages = { [stage] = true },
					start_results = { [stage] = { refusal } },
				}
				with_fixture(options, function(onboarding, calls)
					local outcomes = {}
					local task = advance_to_stage(onboarding, calls, stage, function(ok, detail)
						outcomes[#outcomes + 1] = { ok = ok, detail = detail }
					end)
					helpers.assert_eq(task.last_start_kind, tostring(refusal))
					helpers.assert_eq(#outcomes, 1,
						"a refused start must choose one failure terminal")
					helpers.assert_true(outcomes[1].ok == false)
					helpers.assert_nil(onboarding._install_owner)
					helpers.assert_nil(next(onboarding._active_tasks))

					local successor = {
						download = "checksum",
						checksum = "mount",
						mount = "install",
					}
					if successor[stage] then
						helpers.assert_eq(#tasks_for_stage(calls, successor[stage]), 0,
							"pre-commit completion must not construct a successor")
					end
					local construction_count = #calls.tasks
					task:complete(0, "", "late duplicate")
					helpers.assert_eq(#outcomes, 1)
					helpers.assert_eq(#calls.tasks, construction_count)
				end)
			end)
		end
	end

	for _, stage in ipairs({ "download", "checksum", "mount", "install" }) do
		helpers.it("HS-011 joins synchronous " .. stage .. " termination completion", function()
			with_fixture({ complete_on_terminate_stages = { [stage] = true } },
				function(onboarding, calls)
					local order = {}
					local task = advance_to_stage(onboarding, calls, stage, function(ok)
						order[#order + 1] = { kind = "installer", ok = ok }
					end)
					local construction_count = #calls.tasks
					helpers.assert_true(onboarding.stop(function(ok)
						order[#order + 1] = { kind = "stop", ok = ok }
					end))
					helpers.assert_eq(#order, 2)
					helpers.assert_eq(order[1].kind, "installer")
					helpers.assert_true(order[1].ok == false)
					helpers.assert_eq(order[2].kind, "stop")
					helpers.assert_true(order[2].ok == true)
					helpers.assert_nil(onboarding._install_owner)
					helpers.assert_nil(onboarding._active_tasks[task])
					helpers.assert_eq(#calls.tasks, construction_count)
				end)
		end)
	end

	for _, stage in ipairs({ "download", "checksum", "mount", "install" }) do
		for _, refusal in ipairs({ false, "nil", "throw" }) do
			helpers.it("HS-011 keeps synchronous " .. stage .. " termination "
				.. tostring(refusal) .. " terminal", function()
				with_fixture({
					complete_on_terminate_stages = { [stage] = true },
					terminate_results = { [stage] = { refusal } },
				}, function(onboarding, calls)
					local order = {}
					local task = advance_to_stage(onboarding, calls, stage, function(ok)
						order[#order + 1] = { kind = "installer", ok = ok }
					end)
					local construction_count = #calls.tasks
					helpers.assert_true(onboarding.stop(function(ok, detail)
						order[#order + 1] = { kind = "stop", ok = ok, detail = detail }
					end))

					helpers.assert_eq(task.last_terminate_kind, tostring(refusal))
					helpers.assert_eq(#order, 2,
						"one synchronous completion and one refusal must publish exactly once")
					helpers.assert_eq(order[1].kind, "installer")
					helpers.assert_true(order[1].ok == false)
					helpers.assert_eq(order[2].kind, "stop")
					helpers.assert_true(order[2].ok == false,
						"false, nil, or thrown terminate remains a terminal stop refusal")
					helpers.assert_eq(order[2].detail,
						"onboarding-task-termination-refused")
					helpers.assert_nil(onboarding._install_owner)
					helpers.assert_nil(onboarding._active_tasks[task])
					helpers.assert_eq(#calls.tasks, construction_count,
						"synchronous termination must construct zero successor stages")
				end)
			end)
		end
	end

	for _, stage in ipairs({ "download", "checksum", "mount", "install" }) do
		for _, refusal in ipairs({ false, "nil", "throw" }) do
			helpers.it("HS-011 returns synchronous " .. stage .. " termination "
				.. tostring(refusal) .. " refusal", function()
				with_fixture({
					complete_on_terminate_stages = { [stage] = true },
					terminate_results = { [stage] = { refusal } },
				}, function(onboarding, calls)
					local outcomes = {}
					local task = advance_to_stage(onboarding, calls, stage, function(ok)
						outcomes[#outcomes + 1] = ok
					end)
					local construction_count = #calls.tasks

					helpers.assert_true(onboarding.stop() == false,
						"callback-free stop must preserve false, nil, and thrown refusal")
					helpers.assert_eq(task.last_terminate_kind, tostring(refusal))
					helpers.assert_eq(#outcomes, 1)
					helpers.assert_true(outcomes[1] == false)
					helpers.assert_nil(onboarding._install_owner)
					helpers.assert_nil(onboarding._active_tasks[task])
					helpers.assert_eq(#calls.tasks, construction_count)
				end)
			end)
		end
	end

	helpers.it("HS-011 consecutive attempts allocate distinct partial paths", function()
		with_fixture({ terminate_results = { download = { true, true } } },
			function(onboarding, calls)
				local first = advance_to_stage(onboarding, calls, "download")
				local first_partial = argument_after(first.args, "--output")
				helpers.assert_true(onboarding.stop() == false)
				first:complete(1, "", "cancelled")
				helpers.assert_nil(onboarding._install_owner)

				local second = advance_to_stage(onboarding, calls, "download")
				local second_partial = argument_after(second.args, "--output")
				helpers.assert_not_nil(first_partial)
				helpers.assert_not_nil(second_partial)
				helpers.assert_true(first_partial ~= second_partial,
					"each installer attempt must own a collision-free staging path")
			end)
	end)

	helpers.it("HS-011 stop removes only the owner unique partial", function()
		with_fixture({ files = { [OTHER_PARTIAL] = true } }, function(onboarding, calls, files)
			local task = advance_to_stage(onboarding, calls, "download")
			local output = argument_after(task.args, "--output")
			helpers.assert_not_nil(output)
			helpers.assert_true(output ~= CACHE_PATH)
			helpers.assert_true(output:match("%.part$") ~= nil,
				"download destination must be an attempt-unique .part path")
			helpers.assert_true(files[output] == true)

			helpers.assert_true(onboarding.stop() == false)
			task:complete(1, "", "cancelled")
			helpers.assert_true(files[output] ~= true,
				"the revoked owner must delete its own temporary bytes")
			helpers.assert_true(files[OTHER_PARTIAL] == true,
				"cleanup must never sweep a sibling attempt partial")
			helpers.assert_eq(count_path(calls.removes, OTHER_PARTIAL), 0)
		end)
	end)

	helpers.it("HS-011 checksum precedes atomic cache replacement without deleting the old cache", function()
		with_fixture({ files = { [CACHE_PATH] = true } }, function(onboarding, calls, files)
			helpers.assert_true(onboarding.install_karabiner_elements(function() end) ~= false)
			local cache_checksum = tasks_for_stage(calls, "checksum")[1]
			helpers.assert_not_nil(cache_checksum)
			cache_checksum:complete(0, string.rep("b", 64) .. "  cached.dmg\n", "")

			local download = tasks_for_stage(calls, "download")[1]
			helpers.assert_not_nil(download)
			local partial = argument_after(download.args, "--output")
			helpers.assert_true(partial ~= CACHE_PATH and partial:match("%.part$") ~= nil)
			helpers.assert_eq(count_path(calls.removes, CACHE_PATH), 0,
				"redownload must not unlink the previously published cache")
			helpers.assert_true(files[CACHE_PATH] == true)

			download:complete(0, "", "")
			local checksums = tasks_for_stage(calls, "checksum")
			helpers.assert_eq(#checksums, 2)
			checksums[2]:complete(0, TEST_SHA .. "  fresh.part\n", "")
			helpers.assert_eq(#calls.renames, 1)
			helpers.assert_eq(calls.renames[1].source, partial)
			helpers.assert_eq(calls.renames[1].destination, CACHE_PATH)
			helpers.assert_true(files[CACHE_PATH] == true)
			helpers.assert_true(files[partial] ~= true)
			helpers.assert_eq(#tasks_for_stage(calls, "mount"), 1,
				"mount may start only after checksum and atomic promotion commit")
		end)
	end)

	helpers.it("HS-011 rename refusal preserves the old cache and starts zero mounts", function()
		with_fixture({ files = { [CACHE_PATH] = true }, rename_refuses = true },
			function(onboarding, calls, files)
				local outcomes = {}
				helpers.assert_true(onboarding.install_karabiner_elements(function(ok, detail)
					outcomes[#outcomes + 1] = { ok = ok, detail = detail }
				end))
				local checksums = tasks_for_stage(calls, "checksum")
				checksums[1]:complete(0, string.rep("b", 64) .. "  old-cache.dmg\n", "")
				local download = tasks_for_stage(calls, "download")[1]
				local partial = argument_after(download.args, "--output")
				download:complete(0, "", "")
				checksums = tasks_for_stage(calls, "checksum")
				checksums[2]:complete(0, TEST_SHA .. "  verified.part\n", "")

				helpers.assert_eq(#outcomes, 1)
				helpers.assert_true(outcomes[1].ok == false)
				helpers.assert_true(files[CACHE_PATH] == true,
					"failed atomic promotion must preserve the prior published cache")
				helpers.assert_true(files[partial] ~= true,
					"a refused promotion must clean only the failed attempt partial")
				helpers.assert_eq(#tasks_for_stage(calls, "mount"), 0,
					"mount must remain fenced below successful atomic promotion")
				helpers.assert_eq(#calls.detaches, 0)
			end)
	end)

	helpers.it("HS-011 successful install settles one terminal callback and one detach", function()
		with_fixture({}, function(onboarding, calls)
			local outcomes = {}
			helpers.assert_true(onboarding.install_karabiner_elements(function(ok, err)
				outcomes[#outcomes + 1] = { ok = ok, err = err }
			end) ~= false)
			tasks_for_stage(calls, "download")[1]:complete(0, "", "")
			tasks_for_stage(calls, "checksum")[1]:complete(0, TEST_SHA .. "  fresh.part\n", "")
			tasks_for_stage(calls, "mount")[1]:complete(
				0, "/dev/disk9\tApple_HFS\t/Volumes/Karabiner Test\n", "")
			tasks_for_stage(calls, "install")[1]:complete(0, "", "")

			helpers.assert_eq(#outcomes, 1)
			helpers.assert_true(outcomes[1].ok == true)
			helpers.assert_nil(outcomes[1].err)
			helpers.assert_eq(#calls.detaches, 1)
			helpers.assert_nil(onboarding._install_owner)
			helpers.assert_true(onboarding.stop() == true)
		end)
	end)
end)
