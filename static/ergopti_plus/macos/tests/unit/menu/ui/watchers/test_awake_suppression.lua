--- tests/unit/menu/ui/watchers/test_awake_suppression.lua

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
	"platform.focus.application_notifier",
	"core.logger.adapters.boot_journal",
	"core.fs.adapters.file_system",
	"platform.input.hotkey_registrar",
	"core.fs.adapters.json_codec",
	"core.logger.adapters.log_transport",
	"ai.adapters.python_interpreter",
	"platform.focus.running_application",
	"core.process.adapters.shell_runner",
	"core.fs.adapters.storage",
	"core.process.adapters.task_environment",
	"core.events.timer_scheduler",
	"tray.adapters.menu",
	"adapters.update_launcher",
	"core.fs.engine.app_dirs",
	"keyboard.engine.caps_word_auto_off",
	"core.lifecycle.engine.compat.utf8",
	"settings.engine.publication.binding_identity",
	"settings.engine.publication.binding_publication",
	"settings.engine.publication.defaults",
	"settings.engine.migration.migrate",
	"diagnostics.engine.operation_reporter",
	"diagnostics.engine.reports.redact",
	"diagnostics.engine.runtime_log",
	"diagnostics.engine.snapshot",
	"diagnostics.engine.reports.error_description",
	"hotstrings.engine.catalogue.personal_files",
	"hs",
	"core.logger.engine.boot_profiler",
	"keyboard.engine.capsword_auto_off",
	"settings.engine.paths",
	"core.timing.engine.deferred_work",
	"diagnostics.engine.reports.snapshot",
	"core.ui.engine.dialog_util",
	"settings.engine.factory_reset_journal",
	"core.fs.engine.dir",
	"diagnostics.engine.reports.git_status",
	"core.i18n.engine.i18n",
	"core.lifecycle.engine.launcher_environment",
	"core.logger.engine.log_folders",
	"core.logger.engine.logger",
	"menu.engine.manifest_reader",
	"core.ui.engine.notifications",
	"core.fs.engine.paths",
	"infra.personal_shortcuts",
	"settings.engine.preferences.preferences",
	"core.lifecycle.engine.reload.guard",
	"keyboard.engine.layers.script_chord_catalogue",
	"core.lifecycle.engine.shutdown.termination_coordinator",
	"core.text.engine.utils",
	"core.text.engine.toml.codec",
	"core.text.engine.toml.reader",
	"menu.engine.ui_restore",
	"core.text.engine.json",
	"layouts.engine.layers.terminators_catalogue",
	"core.logger.engine",
	"menu.engine.click_intent",
	"menu.engine.wrap_mutation",
	"core.fs.engine.module_source_directory",
	"core.fs.engine.module_source_identity",
	"hotstrings.engine.dynamic",
	"gestures.engine",
	"modules.keystats",
	"modules.keystats.text_cipher",
	"ai.engine",
	"modules.shortcuts",
	"modules.updater",
	"modules.updater.channel",
	"core.fs.engine.native_path",
	"core.text.engine.number_policy",
	"core.lifecycle.engine.reload.gate",
	"keyboard.engine.layers.script_chords",
	"shortcuts.engine.assignment",
	"shortcuts.engine.physical_slots",
	"tap_hold.engine.key_combinations",
	"tests.stubs.hs",
	"tests.support.menu_boot_fixture",
	"core.text.engine.toml_codec",
	"core.text.engine.toml_codec.basic_string",
	"core.text.engine.toml_codec.bom",
	"core.text.engine.toml_codec.codec",
	"core.text.engine.toml_codec.key_path",
	"core.text.engine.toml_codec.leaf_rows",
	"core.text.engine.toml_codec.record_scanner",
	"core.text.engine.toml_codec.reader",
	"core.text.engine.toml_codec.source_open",
	"core.text.engine.toml_codec.writer",
	"hotstrings.ui.hotstring_editor",
	"diagnostics.ui.log_openers",
	"menu.ui.keyboard.base_delay_transaction",
	"menu.ui.builder.builder",
	"menu.ui.builder.click_gate",
	"menu.ui.transactions.global_actions_transaction",
	"hotstrings.ui.menu.counter",
	"ui.menu.init",
	"menu.ui.keyboard.keymap_lifecycle",
	"ui.menu.menu_about",
	"apps.ui.menu.apps",
	"gestures.ui.menu.gestures",
	"hotstrings.ui.menu.hotstrings",
	"layouts.ui.menu.keyboard_layout",
	"ai.ui.menu",
	"ui.menu.menu_metrics",
	"settings.ui.menu.paths",
	"ui.menu.menu_shortcuts",
	"menu.ui.builder.state",
	"ui.menu.menu_tap_holds",
	"menu.ui.builder.watchers",
	"settings.ui.menu.preferences_transaction",
	"menu.ui.transactions.preview_transaction",
	"menu.ui.transactions.program_parameter_transaction",
	"menu.ui.transactions.recoverable_file_moves",
	"menu.ui.transactions.script_chords_transaction",
	"menu.ui.transactions.session_demotions",
	"core.ui.engine.window_titles",
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
					local initial_state = package.loaded["settings.engine.preferences.preferences"].build_initial_state()
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
					package.loaded["core.process.adapters.shell_runner"].open = function(path)
						assert(path == "/virtual/init.lua" or path == "/virtual/config.toml",
							"only the actual deferred file-open commands may cross this boundary")
						world.opened[#world.opened + 1] = path
						return world.launch_accepts ~= false
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
					local captured_watchers = package.loaded["menu.ui.builder.watchers"]
					package.loaded["menu.ui.builder.watchers"] = nil
					local Watchers = require("menu.ui.builder.watchers")
					-- The existing boot fixture's captured child table delegates this
					-- one operation to the genuine consumer, without replacing its getter.
					captured_watchers.start_config_watcher = Watchers.start_config_watcher
					local ui_restore = package.loaded["menu.engine.ui_restore"]
					ui_restore.defer_reload = function(callback)
						if not world.ui_open then return callback() end
						world.deferred_reload = callback
						return true
					end
					package.loaded["core.lifecycle.engine.shutdown.termination_coordinator"].request_reload = function(source)
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
			Scheduler = require("core.events.timer_scheduler")
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
		Scheduler = Scheduler or package.loaded["core.events.timer_scheduler"]
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
	helpers.it("opens menu files through the asynchronous launcher and propagates refusal", function()
		with_menu(function(world)
			local actions = world.fixture.global_actions()
			for _, name in ipairs({ "open_script_source", "open_personal_hotstrings", "open_personal_info", "open_config" }) do
				helpers.assert_true(actions[name]())
			end
			helpers.assert_eq(world.opened, { "/virtual/init.lua", "/virtual/config.toml",
				"/virtual/config.toml", "/virtual/config.toml" })
			world.launch_accepts = false
			helpers.assert_eq(actions.open_config(), false)
		end)
	end)
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
