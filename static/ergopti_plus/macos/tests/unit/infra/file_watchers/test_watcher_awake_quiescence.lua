--- tests/unit/infra/file_watchers/test_watcher_awake_quiescence.lua

--- ==============================================================================
--- MODULE: Watcher Awake Quiescence Regression Tests
--- DESCRIPTION:
--- Composes both real reload watchers with ReloadGate, GitStatus, UIRestore and
--- TimerScheduler. Civil corrections occur after a source edit is admitted, so
--- this exercises quiet-time decisions independently of either boot deadline.
--- Native callback delivery is controlled; its physical cadence is not modeled.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"infra.file_watchers", "ui.menu.menu_watchers", "infra.ui_restore", "infra.git_status", "infra.fs_dir",
	"infra.logger", "infra.i18n", "infra.notifications", "reload_gate", "native_path",
	"diagnostics.runtime_log", "adapters.timer_scheduler", "error_description", "number_policy",
	"adapters.storage", "infra.timings", "adapters.file_system",
	"ui.metrics_typing", "ui.metrics_apps", "ui.metrics_apps.init", "ui.hotstring_editor",
}

local BASE_ROOT = "/Users/test/Ergopti"
local PERSONAL_ROOT = "/Users/test/PersonalHotstrings"


--- Owns real controllers and queue state across setup, body and teardown errors.
--- @param kind string File watcher or menu watcher.
--- @param callback function Receives the composed world and cleanup owners.
local function with_watchers(kind, callback)
	local previous_roots = rawget(_G, "script_watchers")
	local ok, failure = xpcall(function()
		helpers.with_stub_scope(OWNED_MODULES, function()
			local world = {
				awake = 10000, civil = 1700000000, ui_open = true, git_locked = false,
				watchers = {}, timers = {}, reloads = 0, notices = 0, errors = {}, kind = kind,
			}
			world.source_root = kind == "file watcher" and PERSONAL_ROOT or BASE_ROOT
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
						or (world.git_locked and path == world.source_root .. "/.git/index.lock")
				end,
				read = function() return nil end,
			}
			package.loaded["ui.hotstring_editor"] = { is_open = function() return world.ui_open end }
			local Restore = require("infra.ui_restore")
			local Scheduler = require("adapters.timer_scheduler")
			_G.script_watchers = nil
			local body_ok, body_failure = xpcall(function()
				if kind == "file watcher" then
					local Watchers = require("infra.file_watchers")
					helpers.assert_eq(Watchers.start({
						hotstrings_dir = BASE_ROOT .. "/hotstrings", base_dir = BASE_ROOT,
						personal_hotstrings_dir = PERSONAL_ROOT, git_roots = { BASE_ROOT, PERSONAL_ROOT },
					}), true, "all healthy native roots must commit")
					helpers.assert_eq(#world.watchers, 3)
					world.native = world.watchers[2]
					helpers.assert_eq(world.native.path, PERSONAL_ROOT)
					helpers.assert_eq(#_G.script_watchers, 1)
					world.owner = _G.script_watchers[1]
				else
					helpers.assert_eq(kind, "menu watcher")
					local Watchers = require("ui.menu.menu_watchers")
					world.owner = Watchers.start_config_watcher(BASE_ROOT, hs.reload,
						function() return 0 end, Restore, {}, {})
					helpers.assert_not_nil(world.owner, "the healthy native menu root must commit")
					helpers.assert_eq(#world.watchers, 1)
					world.native = world.watchers[1]
					helpers.assert_eq(world.native.path, BASE_ROOT)
				end
				-- All boot/suppression admission is over before any test clock step.
				world.awake = world.awake + 20
				world.civil = world.civil + 20
				callback(world, Restore, Scheduler)
			end, debug.traceback)
			if world.owner then helpers.assert_eq(world.owner:stop(), true, "the exact watcher owner must retire") end
			helpers.assert_eq(Restore.stop(), true, "the real UI queue must retire")
			helpers.assert_eq(Scheduler.cancelAll(), true)
			helpers.assert_eq(Scheduler.activeCount(), 0)
			for _, watcher in ipairs(world.watchers) do
				helpers.assert_eq(watcher.active, false)
				helpers.assert_eq(watcher.stop_calls, 1, "each exact native watcher must stop once")
			end
			for _, timer in ipairs(world.timers) do helpers.assert_eq(timer.active, false) end
			helpers.assert_eq(#world.errors, 0,
				"guarded callback errors must not hide a failed reload:\n"
					.. table.concat(world.errors, "\n")
					.. (not body_ok and ("\nbody failure: " .. tostring(body_failure)) or ""))
			if not body_ok then error(body_failure, 0) end
		end)
	end, debug.traceback)
	rawset(_G, "script_watchers", previous_roots)
	if not ok then error(failure, 0) end
end


--- Advances both clocks normally after a single independent civil correction.
local function advance(world, seconds)
	world.awake = world.awake + seconds
	world.civil = world.civil + seconds
end


--- Returns the exact native timer for one known owner interval.
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


--- Delivers relevant ordinary TOML edits through the committed root callback.
local function edit(world, count)
	local paths = {}
	for i = 1, count do paths[i] = world.source_root .. "/notes/user" .. i .. ".toml" end
	helpers.assert_eq(world.native.active, true)
	world.native.fn(paths)
	helpers.assert_not_nil(active_timer(world, 0.5), "an admitted source edit must own a settle timer")
end


--- Delivers one retained native poll after its nominal half-second interval.
--- This is a controlled callback decision, not a native NSTimer cadence proof.
local function poll(world)
	local timer = active_timer(world, 0.5)
	helpers.assert_not_nil(timer, "the source burst must retain its exact retry timer")
	advance(world, 0.5)
	timer:fire()
end


--- Holds the reload in the real UI queue, then closes the registered UI.
local function close_ui_and_accept(world)
	helpers.assert_eq(world.reloads, 0, "the real registered open UI must hold the settled reload")
	local ui_poll = active_timer(world, 1)
	helpers.assert_not_nil(ui_poll,
		"an admitted edit that is quiet in awake time must reach the real UI deferral")
	helpers.assert_nil(active_timer(world, 0.5), "a settled burst must leave its source poller")
	world.ui_open = false
	advance(world, 1)
	ui_poll:fire()
	helpers.assert_eq(world.reloads, 1, "the UI closure must accept exactly one reload")
	helpers.assert_eq(ui_poll.active, false)
	helpers.assert_eq(ui_poll.stop_calls, 1)
	helpers.assert_nil(active_timer(world, 0.5), "an accepted reload must leave no retry")
end


local CASES = {
	{
		name = "a normal single edit settles on its first half-second poll",
		run = function(world)
			edit(world, 1)
			poll(world)
			close_ui_and_accept(world)
		end,
	},
	{
		name = "a normal bulk burst waits for three seconds of quiet",
		run = function(world)
			edit(world, 4)
			for _ = 1, 5 do
				poll(world)
				helpers.assert_nil(active_timer(world, 1), "a healthy bulk burst must retain its quiet-time hold")
				helpers.assert_eq(world.reloads, 0)
			end
			poll(world)
			close_ui_and_accept(world)
		end,
	},
	{
		name = "an admitted single edit settles after a civil rollback",
		run = function(world)
			edit(world, 1)
			world.civil = world.civil - 60
			poll(world)
			close_ui_and_accept(world)
		end,
	},
	{
		name = "an admitted bulk burst stays held after a civil advance",
		run = function(world)
			edit(world, 4)
			world.civil = world.civil + 60
			for _ = 1, 5 do
				poll(world)
				helpers.assert_nil(active_timer(world, 1),
					"a civil correction must not spend the bulk quiescence window")
				helpers.assert_eq(world.reloads, 0)
			end
			poll(world)
			close_ui_and_accept(world)
		end,
	},
	{
		name = "new bulk activity resets the quiet period and revokes its superseded timer",
		run = function(world)
			edit(world, 4)
			local superseded = active_timer(world, 0.5)
			advance(world, 2)
			edit(world, 1)
			helpers.assert_eq(superseded.active, false)
			helpers.assert_eq(superseded.stop_calls, 1)
			local current = active_timer(world, 0.5)
			superseded.fn()
			helpers.assert_eq(active_timer(world, 0.5), current, "a superseded native callback must stay inert")
			for _ = 1, 5 do
				poll(world)
				helpers.assert_nil(active_timer(world, 1), "the latest activity must restart the bulk quiet period")
			end
			poll(world)
			close_ui_and_accept(world)
		end,
	},
	{
		name = "a real Git lock stays authoritative after the quiet period",
		run = function(world)
			world.git_locked = true
			edit(world, 1)
			poll(world)
			helpers.assert_nil(active_timer(world, 1), "the real GitStatus lock probe must hold the UI queue")
			helpers.assert_eq(world.reloads, 0)
			world.git_locked = false
			poll(world)
			close_ui_and_accept(world)
		end,
	},
	{
		name = "stop fences retained native watcher and timer callbacks",
		run = function(world)
			edit(world, 1)
			local retired = active_timer(world, 0.5)
			helpers.assert_eq(world.owner:stop(), true)
			helpers.assert_eq(retired.active, false)
			local timer_count = #world.timers
			advance(world, 1)
			world.civil = world.civil - 60
			retired.fn()
			world.native.fn({ world.source_root .. "/notes/retired.toml" })
			helpers.assert_eq(#world.timers, timer_count, "retired capabilities must not re-arm work")
			helpers.assert_nil(active_timer(world, 1))
			helpers.assert_nil(active_timer(world, 0.5))
			helpers.assert_eq(world.reloads, 0)
		end,
	},
}


helpers.describe("reload watchers measure source quiescence in awake time", function()
	for _, kind in ipairs({ "file watcher", "menu watcher" }) do
		local selected_kind = kind
		for _, scenario in ipairs(CASES) do
			local selected = scenario
			helpers.it(selected_kind .. " " .. selected.name, function()
				with_watchers(selected_kind, selected.run)
			end)
		end
	end
end)
