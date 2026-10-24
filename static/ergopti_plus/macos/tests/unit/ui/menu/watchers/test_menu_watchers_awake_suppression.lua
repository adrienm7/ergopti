--- tests/unit/ui/menu/watchers/test_menu_watchers_awake_suppression.lua

--- ==============================================================================
--- MODULE: Menu Watcher Awake Suppression Regression Tests
--- DESCRIPTION:
--- Boots the real menu controller and invokes its actual deferred shortcut extras.
--- The real config watcher, Scheduler, GitStatus and ReloadGate receive independent
--- civil and awake clocks. UI deferral and reload acceptance are explicit external
--- boundaries; no native FSEvents, full root boot or process reload is claimed.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"_generated.logger_sub_files",
	"adapters.application_notifier",
	"adapters.boot_journal",
	"adapters.file_system",
	"adapters.hotkey_registrar",
	"adapters.json_codec",
	"adapters.log_transport",
	"adapters.python_interpreter",
	"adapters.running_application",
	"adapters.shell_runner",
	"adapters.storage",
	"adapters.task_environment",
	"adapters.timer_scheduler",
	"adapters.tray_menu",
	"adapters.update_launcher",
	"app_dirs",
	"caps_word.auto_off",
	"compat.utf8",
	"config_binding_identity",
	"config_binding_publication",
	"config_defaults",
	"config_migrate",
	"diagnostics.operation_reporter",
	"diagnostics.redact",
	"diagnostics.runtime_log",
	"diagnostics.snapshot",
	"error_description",
	"hotstrings.personal_files",
	"hs",
	"infra.boot_profiler",
	"infra.capsword_auto_off",
	"infra.config_paths",
	"infra.deferred_work",
	"infra.diagnostic_snapshot",
	"infra.dialog_util",
	"infra.factory_reset_journal",
	"infra.fs_dir",
	"infra.git_status",
	"infra.i18n",
	"infra.launcher_environment",
	"infra.log_folders",
	"infra.logger",
	"infra.manifest_reader",
	"infra.notifications",
	"infra.paths",
	"infra.personal_shortcuts",
	"infra.preferences",
	"infra.reload_guard",
	"infra.script_chord_catalogue",
	"infra.termination_coordinator",
	"infra.text_utils",
	"infra.toml.codec",
	"infra.toml.reader",
	"infra.ui_restore",
	"json",
	"keymap.terminators_catalogue",
	"logger",
	"menu.click_intent",
	"menu.wrap_mutation",
	"module_source_directory",
	"module_source_identity",
	"modules.dynamic_hotstrings",
	"modules.gestures",
	"modules.keystats",
	"modules.keystats.text_cipher",
	"modules.llm",
	"modules.shortcuts",
	"modules.updater",
	"modules.updater.channel",
	"native_path",
	"number_policy",
	"reload_gate",
	"script_chords",
	"shortcuts.assignment",
	"shortcuts.physical_slots",
	"tap_hold.key_combinations",
	"tests.stubs.hs",
	"tests.support.menu_boot_fixture",
	"toml_codec",
	"toml_codec.basic_string",
	"toml_codec.bom",
	"toml_codec.codec",
	"toml_codec.key_path",
	"toml_codec.leaf_rows",
	"toml_codec.record_scanner",
	"toml_codec.reader",
	"toml_codec.source_open",
	"toml_codec.writer",
	"ui.hotstring_editor",
	"ui.log_openers",
	"ui.menu.base_delay_transaction",
	"ui.menu.builder",
	"ui.menu.click_gate",
	"ui.menu.global_actions_transaction",
	"ui.menu.hotstring_counter",
	"ui.menu.init",
	"ui.menu.keymap_lifecycle",
	"ui.menu.menu_about",
	"ui.menu.menu_apps",
	"ui.menu.menu_gestures",
	"ui.menu.menu_hotstrings",
	"ui.menu.menu_keyboard_layout",
	"ui.menu.menu_llm",
	"ui.menu.menu_metrics",
	"ui.menu.menu_paths",
	"ui.menu.menu_shortcuts",
	"ui.menu.menu_state",
	"ui.menu.menu_tap_holds",
	"ui.menu.menu_watchers",
	"ui.menu.preferences_transaction",
	"ui.menu.preview_transaction",
	"ui.menu.program_parameter_transaction",
	"ui.menu.recoverable_file_moves",
	"ui.menu.script_chords_transaction",
	"ui.menu.session_demotions",
	"window_titles",
}

local EDIT_PATH = "/virtual/user-config/hotstrings_config.toml"


--- Boots the existing menu fixture with the real registered watcher consumer.
--- @param body function Scenario receiving actual callbacks and native observations.
local function with_menu(body)
	return helpers.with_stub_scope(OWNED_MODULES, function()
		local world = {
			awake = 10000, civil = 1700000000, timers = {}, watchers = {},
			opened = {}, reloads = 0, ui_open = true, git_locked = false,
			reload_accepts = true, deferred_reload = nil, extras = nil,
		}
		local function timer(delay, fn, repeating)
			local native = { delay = delay, fn = fn, repeating = repeating, active = false, stops = 0 }
			function native:start() self.active = true; return self end
			function native:stop() self.active = false; self.stops = self.stops + 1; return self end
			function native:running() return self.active end
			function native:fire()
				assert(self.active, "only an armed native timer may deliver")
				if not self.repeating then self.active = false end
				self.fn()
			end
			world.timers[#world.timers + 1] = native
			return native
		end
		local fixture, Menu, Scheduler
		local ok, failure = xpcall(function()
			fixture = require("tests.support.menu_boot_fixture").boot({
				before_start = function()
					-- The minimal boot fixture omits this declared healthy UI default.
					local initial_state = package.loaded["infra.preferences"].build_initial_state()
					initial_state.menubar_icon = "v1"
					local host = hs
					-- The existing boot fixture models this source-run update boundary.
					package.loaded["modules.updater"].is_local_source = function() return true end
					host.timer = {
						absoluteTime = function() return world.awake * 1e9 end,
						secondsSinceEpoch = function() return world.civil end,
						new = function(delay, fn) return timer(delay, fn, true) end,
						doAfter = function(delay, fn)
							local native = timer(delay, fn, false):start()
							native.source_settle = true
							return native
						end,
					}
					host.execute = function(command)
						assert(command == "open /virtual/init.lua" or command == "open /virtual/config.toml",
							"only the actual deferred file-open commands may cross this boundary")
						world.opened[#world.opened + 1] = command
						return "", true, "exit", 0
					end
					host.pathwatcher = { new = function(path, callback)
						local watcher = { path = path, fn = callback, active = false, stops = 0 }
						function watcher:start() self.active = true; return self end
						function watcher:stop() self.active = false; self.stops = self.stops + 1 end
						world.watchers[#world.watchers + 1] = watcher
						return watcher
					end }
					local attributes = host.fs.attributes
					host.fs.attributes = function(path, field)
						if path == "/virtual/.git/HEAD" or path == "/virtual/.git/index.lock" then
							local present = path == "/virtual/.git/HEAD" or world.git_locked
							if not present then return nil end
							local value = { mode = "file" }
							return field and value[field] or value
						end
						return attributes(path, field)
					end
					local captured_watchers = package.loaded["ui.menu.menu_watchers"]
					package.loaded["ui.menu.menu_watchers"] = nil
					local Watchers = require("ui.menu.menu_watchers")
					-- The existing boot fixture's captured child table delegates this
					-- one operation to the genuine consumer, without replacing its getter.
					captured_watchers.start_config_watcher = Watchers.start_config_watcher
					local ui_restore = package.loaded["infra.ui_restore"]
					ui_restore.defer_reload = function(callback)
						if not world.ui_open then return callback() end
						world.deferred_reload = callback
						return true
					end
					package.loaded["infra.termination_coordinator"].request_reload = function(source)
						helpers.assert_eq(source, "watcher", "the real menu must identify its source request")
						world.reloads = world.reloads + 1
						return world.reload_accepts
					end
					package.loaded["modules.shortcuts"].set_extras = function(extras)
						helpers.assert_nil(world.extras, "the real menu must publish one extras table")
						world.extras = extras
						return true
					end
				end,
			})
			Menu = require("ui.menu.init")
			Scheduler = require("adapters.timer_scheduler")
			helpers.assert_not_nil(fixture.menu, "the actual menu must boot")
			helpers.assert_eq(#world.watchers, 1, "the real config watcher must own one native stream")
			helpers.assert_eq(world.watchers[1].path, "/virtual/")
			helpers.assert_type(world.extras.open_init, "function")
			helpers.assert_type(world.extras.open_config, "function")
			fixture.flush_deferred()
			world.fixture = fixture
			body(world)
		end, debug.traceback)
		Menu = Menu or package.loaded["ui.menu.init"]
		Scheduler = Scheduler or package.loaded["adapters.timer_scheduler"]
		if Menu then helpers.assert_eq(Menu.stop_watchers(), true, "the exact menu watcher owner must retire") end
		if Scheduler then helpers.assert_eq(Scheduler.cancelAll(), true, "the menu's native timer owners must retire") end
		for _, watcher in ipairs(world.watchers) do
			helpers.assert_eq(watcher.active, false)
			helpers.assert_eq(watcher.stops, 1, "the exact native watcher must stop once")
		end
		for _, native in ipairs(world.timers) do helpers.assert_eq(native.active, false) end
		if fixture then
			local diagnostics = table.concat(fixture.logs.errors, "\n")
			if not ok then diagnostics = diagnostics .. "\nScenario also failed:\n" .. tostring(failure) end
			helpers.assert_eq(#fixture.logs.errors, 0,
				"a contained callback error must not forge a passing reload:\n" .. diagnostics)
		end
		if not ok then error(failure, 0) end
	end)
end


--- Advances clocks normally after the one deliberate civil correction.
--- @param world table Native observations.
--- @param seconds number Elapsed awake duration.
local function advance(world, seconds)
	world.awake = world.awake + seconds
	world.civil = world.civil + seconds
end


--- Returns the current native source-settle owner, excluding unrelated UI timers.
--- @param world table Native observations.
--- @return table|nil timer
local function pending_settle(world)
	local found
	for _, native in ipairs(world.timers) do
		if native.active and native.source_settle then
			helpers.assert_eq(native.delay, 0.5)
			helpers.assert_nil(found, "one source burst must retain one native settle timer")
			found = native
		end
	end
	return found
end


--- Invokes the actual registered pathwatcher callback for the real runtime TOML.
--- @param world table Native observations.
local function edit(world)
	helpers.assert_true(world.watchers[1].active)
	world.watchers[1].fn({ EDIT_PATH })
end


--- Settles one real burst, then delivers the controlled UI-close boundary.
--- @param world table Native observations.
local function settle_and_close(world)
	local native = pending_settle(world)
	helpers.assert_not_nil(native, "an expired menu window must retain the TOML change for normal settlement")
	advance(world, 0.5)
	native:fire()
	helpers.assert_eq(world.reloads, 0, "an open UI must hold the settled source request")
	helpers.assert_type(world.deferred_reload, "function")
	local reload = world.deferred_reload
	world.deferred_reload = nil
	world.ui_open = false
	reload()
	helpers.assert_eq(world.reloads, 1, "the real menu must request one reload after the UI-close boundary")
	helpers.assert_nil(pending_settle(world), "an accepted reload must leave no source retry")
end


--- Exercises each actual producer; no fixture getter calculates a deadline.
--- @param world table Native observations.
--- @param producer string boot, open_init or open_config.
local function select_producer(world, producer)
	if producer == "boot" then return end
	advance(world, 20)
	helpers.assert_eq(world.extras[producer](), true, "the actual shortcut must accept its deferred file open")
	helpers.assert_eq(#world.opened, 0, "opening must stay deferred")
	world.fixture.flush_deferred()
	helpers.assert_eq(#world.opened, 1, "the actual deferred extra must execute its file-open body")
end


--- Observes suppression before any unrelated epoch-debounce clock correction.
--- @param producer string Actual menu producer.
--- @param elapsed number Awake duration after its capture.
--- @param correction number One civil-clock step before the edit.
--- @param admitted boolean Expected source admission.
local function observe(producer, elapsed, correction, admitted)
	with_menu(function(world)
		select_producer(world, producer)
		advance(world, elapsed)
		world.civil = world.civil + correction
		edit(world)
		if admitted then
			settle_and_close(world)
		else
			helpers.assert_nil(pending_settle(world), "a civil correction must not spend the actual menu suppression window")
			helpers.assert_eq(world.reloads, 0)
			helpers.assert_nil(world.deferred_reload)
		end
	end)
end


helpers.describe("actual menu producers and watcher share one awake suppression domain", function()
	for _, producer in ipairs({ "boot", "open_init", "open_config" }) do
		local boundary = producer == "boot" and 5 or 8
		helpers.it(producer .. " suppresses an edit inside its healthy window", function()
			observe(producer, 1, 0, false)
		end)
		helpers.it(producer .. " admits an edit at its exact awake boundary", function()
			observe(producer, boundary, 0, true)
		end)
		helpers.it(producer .. " admits an expired edit despite a civil rollback", function()
			observe(producer, boundary + 15, -60, true)
		end)
		helpers.it(producer .. " preserves an early window despite a civil advance", function()
			observe(producer, 1, 60, false)
		end)
	end

	-- Policy controls operate after the normal boot window without a clock step.
	helpers.it("keeps a real Git lock authoritative before controlled UI-close delivery", function()
		with_menu(function(world)
			advance(world, 6)
			world.git_locked = true
			edit(world)
			local native = pending_settle(world)
			helpers.assert_not_nil(native)
			advance(world, 0.5)
			native:fire()
			helpers.assert_eq(world.reloads, 0)
			helpers.assert_nil(world.deferred_reload, "a live Git lock must precede UI admission")
			world.git_locked = false
			settle_and_close(world)
		end)
	end)

	helpers.it("retains an admitted burst when the actual menu reload request is refused", function()
		with_menu(function(world)
			advance(world, 6)
			world.ui_open = false
			world.reload_accepts = false
			edit(world)
			local native = pending_settle(world)
			helpers.assert_not_nil(native)
			advance(world, 0.5)
			native:fire()
			helpers.assert_eq(world.reloads, 1)
			local retry = pending_settle(world)
			helpers.assert_not_nil(retry, "a refused exclusive reload must retain the original source burst")
			world.reload_accepts = true
			advance(world, 0.5)
			retry:fire()
			helpers.assert_eq(world.reloads, 2)
			helpers.assert_nil(pending_settle(world))
		end)
	end)

	helpers.it("fences a queued UI-close request and native callback after owner stop", function()
		with_menu(function(world)
			advance(world, 6)
			edit(world)
			local native = pending_settle(world)
			helpers.assert_not_nil(native)
			advance(world, 0.5)
			native:fire()
			helpers.assert_type(world.deferred_reload, "function")
			local pending = world.deferred_reload
			helpers.assert_eq(require("ui.menu.init").stop_watchers(), true)
			world.ui_open = false
			pending()
			world.watchers[1].fn({ EDIT_PATH })
			helpers.assert_eq(world.reloads, 0)
			helpers.assert_nil(pending_settle(world))
		end)
	end)
end)
