--- tests/support/onboarding_install_fixture.lua

--- ==============================================================================
--- MODULE: Onboarding Installer Fixture
--- DESCRIPTION:
--- Owns the native task, timer, filesystem, and module doubles used by installer
--- lifecycle scenarios and their fixture isolation regressions.
--- ==============================================================================

local helpers = require("tests.helpers")
local TEST_SHA = string.rep("a", 64)
local CACHE_PATH = "/cache/Karabiner-Elements.dmg"

local MODULE_NAMES = {
	"adapters.task_environment",
	"adapters.task_lifecycle",
	"adapters.timer_scheduler",
	"hs",
	"infra.dialog_util",
	"infra.i18n",
	"infra.launcher_environment",
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

--- Builds the native doubles and invokes a scenario within its owner's scope.
--- @param options table|nil Failure injection and initial-file options.
--- @param scenario function Scenario receiving onboarding, calls, and files.
local function run_fixture(options, scenario)
	options = options or {}
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

		return helpers.attach_native_task_environment(task)
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

	return scenario(onboarding, calls, files)
end

--- Restores all owned boundaries even when native or module construction fails.
--- @param options table|nil Failure injection and initial-file options.
--- @param scenario function Scenario receiving onboarding, calls, and files.
--- @return any ... Scenario results.
local function with_fixture(options, scenario)
	local saved_modules = {}
	for _, name in ipairs(MODULE_NAMES) do
		saved_modules[name] = package.loaded[name]
	end
	local saved_hs = _G.hs
	local saved_open = io.open
	local saved_remove = os.remove
	local saved_rename = os.rename
	local outcome = table.pack(xpcall(function()
		for _, name in ipairs(MODULE_NAMES) do package.loaded[name] = nil end
		return run_fixture(options, scenario)
	end, debug.traceback))
	io.open = saved_open
	os.remove = saved_remove
	os.rename = saved_rename
	_G.hs = saved_hs
	for _, name in ipairs(MODULE_NAMES) do package.loaded[name] = saved_modules[name] end
	if not outcome[1] then error(outcome[2], 0) end
	return table.unpack(outcome, 2, outcome.n)
end

return {
	argument_after = argument_after,
	with_fixture = with_fixture,
	TEST_SHA = TEST_SHA,
	CACHE_PATH = CACHE_PATH,
}
