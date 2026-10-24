--- tests/unit/infra/file_watchers/test_file_watchers_awake_boot_window.lua

--- ==============================================================================
--- MODULE: File Watcher Awake Boot Window Regression Tests
--- DESCRIPTION:
--- Delivers ordinary personal hotstring edits through the committed native root
--- callback. Real FileWatchers, ReloadGate, GitStatus, UIRestore and Scheduler
--- compose over independent clocks, healthy native handles and explicit UI state.
--- Only the private boot window changes domains; the existing epoch settle policy
--- and public menu-watcher deadline remain outside this correction.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"infra.file_watchers", "infra.ui_restore", "infra.git_status", "infra.fs_dir",
	"infra.logger", "infra.i18n", "infra.notifications", "reload_gate", "native_path",
	"diagnostics.runtime_log", "adapters.timer_scheduler", "error_description", "number_policy",
	"adapters.storage", "infra.timings", "adapters.file_system",
	"ui.metrics_typing", "ui.metrics_apps", "ui.metrics_apps.init", "ui.hotstring_editor",
}

local BASE_ROOT = "/Users/test/Ergopti"
local PERSONAL_ROOT = "/Users/test/PersonalHotstrings"
local PERSONAL_TOML = PERSONAL_ROOT .. "/notes/user.toml"


--- Preserves the process root even if setup, a business oracle or teardown fails.
--- @param callback function Receives the composed native world and owners.
local function with_watchers(callback)
	local previous_roots = rawget(_G, "script_watchers")
	local ok, failure = xpcall(function()
		helpers.with_stub_scope(OWNED_MODULES, function()
			local world = {
				awake = 10000, civil = 1700000000, ui_open = true, git_locked = false,
				watchers = {}, timers = {}, reloads = 0, notices = 0, errors = {},
			}
			local function make_timer(delay, fn, repeating)
				local timer = { delay = delay, fn = fn, repeating = repeating, active = false, stop_calls = 0 }
				function timer:start() self.active = true; return self end
				function timer:stop() self.active = false; self.stop_calls = self.stop_calls + 1; return self end
				function timer:running() return self.active end
				function timer:fire()
					assert(self.active, "only an armed native timer may deliver")
					if not self.repeating then self.active = false end
					self.fn()
				end
				world.timers[#world.timers + 1] = timer
				return timer
			end
			_G.hs = {
				timer = {
					absoluteTime = function() return world.awake * 1e9 end,
					secondsSinceEpoch = function() return world.civil end,
					new = function(delay, fn) return make_timer(delay, fn, true) end,
					doAfter = function(delay, fn) return make_timer(delay, fn, false):start() end,
				},
				pathwatcher = { new = function(path, fn)
					local watcher = { path = path, fn = fn, active = false, stop_calls = 0 }
					function watcher:start() self.active = true; return self end
					function watcher:stop() self.active = false; self.stop_calls = self.stop_calls + 1 end
					world.watchers[#world.watchers + 1] = watcher
					return watcher
				end },
				reload = function() world.reloads = world.reloads + 1; return true end,
			}
			local logger = helpers.make_logger_stub()
			logger.error = function(_, format, ...) world.errors[#world.errors + 1] = string.format(format, ...) end
			package.loaded["infra.logger"] = logger
			package.loaded["infra.i18n"] = { get = function(key) return key end }
			package.loaded["infra.notifications"] = { notify = function()
				world.notices = world.notices + 1
				return true
			end }
			package.loaded["infra.fs_dir"] = {}
			package.loaded["infra.timings"] = { sec = function(group, key)
				assert(group == "ui" and key == "ui_restore_poll_ms", "unexpected UI timing")
				return 1
			end }
			local stored = {}
			package.loaded["adapters.storage"] = {
				set = function(key, value) stored[key] = value; return true end,
				delete = function(key) stored[key] = nil; return true end,
			}
			package.loaded["adapters.file_system"] = {
				exists = function(path)
					return path == BASE_ROOT .. "/.git/HEAD" or path == PERSONAL_ROOT .. "/.git/HEAD"
						or (world.git_locked and path == PERSONAL_ROOT .. "/.git/index.lock")
				end,
				read = function() return nil end,
			}
			package.loaded["ui.hotstring_editor"] = { is_open = function() return world.ui_open end }
			local Watchers = require("infra.file_watchers")
			local Restore = require("infra.ui_restore")
			local Scheduler = require("adapters.timer_scheduler")
			_G.script_watchers = nil
			local body_ok, body_failure = xpcall(function()
				helpers.assert_eq(Watchers.start({
					hotstrings_dir = BASE_ROOT .. "/hotstrings", base_dir = BASE_ROOT,
					personal_hotstrings_dir = PERSONAL_ROOT, git_roots = { BASE_ROOT, PERSONAL_ROOT },
				}), true, "all three healthy native root watchers must commit")
				helpers.assert_eq(#world.watchers, 3)
				helpers.assert_eq(world.watchers[2].path, PERSONAL_ROOT)
				helpers.assert_eq(#_G.script_watchers, 1)
				world.owner = _G.script_watchers[1]
				callback(world, Restore, Scheduler)
			end, debug.traceback)
			for _, owner in ipairs(rawget(_G, "script_watchers") or {}) do
				helpers.assert_eq(owner:stop(), true, "the exact file-watcher owner must retire")
			end
			helpers.assert_eq(Restore.stop(), true, "the real UI queue must retire its exact poller")
			helpers.assert_eq(Scheduler.cancelAll(), true)
			for _, watcher in ipairs(world.watchers) do
				helpers.assert_eq(watcher.active, false)
				helpers.assert_eq(watcher.stop_calls, 1, "each exact native watcher must stop once")
			end
			for _, timer in ipairs(world.timers) do helpers.assert_eq(timer.active, false) end
			helpers.assert_eq(#world.errors, 0, "guarded callback errors must not hide a failed reload")
			if not body_ok then error(body_failure, 0) end
		end)
	end, debug.traceback)
	rawset(_G, "script_watchers", previous_roots)
	if not ok then error(failure, 0) end
end


--- Advances both clocks normally after the one deliberate civil correction.
--- @param world table Native observations.
--- @param seconds number Elapsed duration.
local function advance(world, seconds)
	world.awake = world.awake + seconds
	world.civil = world.civil + seconds
end


--- Returns the exact current native timer for one known owner interval.
--- @param world table Native observations.
--- @param delay number Native interval.
--- @return table|nil timer
local function active_timer(world, delay)
	local found
	for _, timer in ipairs(world.timers) do
		if timer.active and timer.delay == delay then
			helpers.assert_nil(found, "one exact native timer must own this phase")
			found = timer
		end
	end
	return found
end


--- Delivers a valid user-editable TOML through the native personal-root callback.
--- @param world table Native observations.
local function edit_personal_toml(world)
	helpers.assert_true(world.watchers[2].active)
	world.watchers[2].fn({ PERSONAL_TOML })
end


--- Settles the real burst, waits in the real UI queue, then accepts one reload.
--- @param world table Native observations.
local function settle_and_close_ui(world)
	local settle = active_timer(world, 0.5)
	helpers.assert_not_nil(settle, "an admitted personal edit must arm the normal settle timer")
	advance(world, 0.5)
	settle:fire()
	helpers.assert_eq(world.reloads, 0, "the real open UI must hold the settled reload")
	local poll = active_timer(world, 1)
	helpers.assert_not_nil(poll, "the real UI owner must retain the deferred reload poll")
	world.ui_open = false
	advance(world, 1)
	poll:fire()
	helpers.assert_eq(world.reloads, 1, "the settled personal edit must reload once after the UI closes")
	helpers.assert_eq(world.notices, 1)
	helpers.assert_eq(poll.active, false)
	helpers.assert_eq(poll.stop_calls, 1, "the exact UI poll timer must stop on delivery")
	helpers.assert_nil(active_timer(world, 0.5), "an accepted reload must leave no source retry")
end


--- Observes only boot suppression; the deliberate civil step precedes the edit.
--- @param elapsed number Awake time since watcher startup.
--- @param correction number Civil-clock step.
--- @param admitted boolean Whether the boot window has elapsed.
local function observe_boot_window(elapsed, correction, admitted)
	with_watchers(function(world)
		world.awake = world.awake + elapsed
		world.civil = world.civil + elapsed + correction
		edit_personal_toml(world)
		if admitted then
			settle_and_close_ui(world)
		else
			helpers.assert_nil(active_timer(world, 0.5),
				"a civil-clock correction must not spend the private awake boot window")
			helpers.assert_eq(world.reloads, 0)
			helpers.assert_nil(active_timer(world, 1))
		end
	end)
end


helpers.describe("personal file watchers measure their private boot window in awake time", function()
	helpers.it("suppresses a normal personal edit inside the five-second boot window", function()
		observe_boot_window(1, 0, false)
	end)

	helpers.it("admits a normal personal edit at the exact five-second boundary", function()
		observe_boot_window(5, 0, true)
	end)

	helpers.it("admits a personal edit after twenty awake seconds despite a civil rollback", function()
		observe_boot_window(20, -60, true)
	end)

	helpers.it("keeps the initial boot window when the civil clock advances early", function()
		observe_boot_window(1, 60, false)
	end)

	helpers.it("keeps a real personal-repository lock authoritative after boot", function()
		with_watchers(function(world)
			advance(world, 6)
			world.git_locked = true
			edit_personal_toml(world)
			local first = active_timer(world, 0.5)
			helpers.assert_not_nil(first)
			advance(world, 0.5)
			first:fire()
			helpers.assert_eq(world.reloads, 0)
			helpers.assert_nil(active_timer(world, 1), "a Git-held burst must not enter the UI queue")
			world.git_locked = false
			settle_and_close_ui(world)
		end)
	end)

	helpers.it("revokes pending personal-edit timers and retired native watcher callbacks on stop", function()
		with_watchers(function(world)
			advance(world, 6)
			edit_personal_toml(world)
			local pending = active_timer(world, 0.5)
			helpers.assert_not_nil(pending)
			helpers.assert_eq(world.owner:stop(), true)
			helpers.assert_eq(pending.active, false)
			helpers.assert_eq(pending.stop_calls, 1)
			local timer_count = #world.timers
			advance(world, 10)
			pending.fn()
			world.watchers[2].fn({ PERSONAL_TOML })
			helpers.assert_eq(#world.timers, timer_count, "retired callbacks must not reacquire a native timer")
			helpers.assert_eq(world.reloads, 0)
			helpers.assert_eq(world.notices, 0)
			helpers.assert_nil(active_timer(world, 1))
		end)
	end)
end)
