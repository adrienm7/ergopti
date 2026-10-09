--- tests/unit/ui/menu/test_gesture_scope.lua

local helpers = require("tests.helpers")
local Codec = require("toml_codec")
local Manifest = require("infra.manifest_reader")
local FileSystem = require("adapters.file_system")

local function fixture(source)
	package.loaded["adapters.file_system"] = FileSystem
	package.loaded["modules.gestures.engine"] = nil
	package.loaded["modules.gestures.conflicts"] = nil
	helpers.load_with_stubs("modules.gestures.actions")
	local gestures = helpers.load_with_stubs("modules.gestures")
	local controls, state, files = {}, { gestures = true }, {}
	local original = source or '[gestures]\nenabled = true\ntap_4 = "open_url"\nmodes = { swipe_3_horiz = "incremental", future = "keep" }\nsensitivities = { swipe_3_horiz = 9, future = 17 }\naction_parameters = { tap_4__open_url = "https://apple.com", keyboard__cmd_k__open_url = "https://example.com", future = { preserve = 7 } }\n[future]\nkeep = 42\n'
	files.config = original
	if source == false then files.config = nil end
	local enabled, writes = true, 0
	gestures.is_enabled = function() return enabled end
	gestures.enable_all = function()
		if controls.refuse_enable then return false end
		enabled = true
		return true
	end
	gestures.disable_all = function()
		if controls.refuse_disable then return false end
		enabled = false
		return true
	end
	gestures.set_action("tap_4", "open_url")
	gestures.set_mode("swipe_3_horiz", "incremental")
	gestures.set_sensitivity("swipe_3_horiz", 9)
	gestures.set_action_parameter("tap_4", "open_url", "https://apple.com")
	gestures.set_action_parameter("keyboard__cmd_k", "open_url", "https://example.com")
	local files_port = {
		read_with_status = function(path) return files[path], files[path] and "ok" or "absent" end,
		write = function() error("unguarded write") end,
		write_if_unchanged = function(path, value, expected)
			if controls.refuse_write and path == "config" then return false end
			if expected.status == "ok" and files[path] ~= expected.content then return false end
			if expected.status == "absent" and files[path] ~= nil then return false end
			if path == "config" and controls.during_write then controls.during_write() end
			files[path] = value
			writes = writes + 1
			return true
		end,
	}
	package.loaded["adapters.file_system"] = files_port
	local prefs = helpers.load_with_stubs("infra.preferences")
	prefs.load("config")
	local PT = require("ui.menu.preferences_transaction")
	local modules = { gestures = gestures }
	local demotions = require("ui.menu.session_demotions").new()
	controls.demotions = demotions
	local save, checkpoint = PT.bind(prefs, {
		path = "config", state = state, hotfiles = {}, core_modules = modules,
		initial_state = state, initial_preferences = prefs.snapshot(state, {}, modules),
		snapshot_view = demotions.persisted_view,
		restore_runtime = function(snapshot)
			gestures.set_action("tap_4", snapshot.gesture_actions.tap_4)
			return true
		end,
	})
	local owner = require("ui.menu.gesture_scope").new({
		path = "config", files = files_port, state = state, gestures = gestures,
		preferences = prefs, checkpoint = checkpoint,
		demotions = demotions,
		capture_preferences = function() return prefs.snapshot(state, {}, modules) end,
		backup_path = function() return "backup" end,
		paused = function() return controls.paused == true end,
		admission = function(_, callback) return callback() end,
	})
	return owner, gestures, files, state, controls, prefs, save, function() return writes end, original
end

local function menu_commands(owner, gestures, state)
	local original_renderer = package.loaded["infra.manifest_menu"]
	local original_menu = package.loaded["ui.menu.menu_gestures"]
	local commands
	package.loaded["infra.manifest_menu"] = { build = function(_, _, _, _, context)
		commands = context.commands
		return {}
	end }
	package.loaded["ui.menu.menu_gestures"] = nil
	local ok, detail = pcall(function()
		require("ui.menu.menu_gestures").build({ gestures = gestures, state = state, paused = false,
			apply_gesture_scope = owner.apply, save_prefs = function() error("scope must not use ordinary save") end,
			updateMenu = function() end })
	end)
	package.loaded["infra.manifest_menu"] = original_renderer
	package.loaded["ui.menu.menu_gestures"] = original_menu
	if not ok then error(detail) end
	return commands
end

helpers.describe("macOS complete gesture scope", function()
	helpers.it("clears every owned setting and parameter while preserving nested neighbors", function()
		local owner, gestures, files, state, _, prefs, save, writes, original = fixture()
		local committed, detail = menu_commands(owner, gestures, state).scope_clear()
		helpers.assert_eq(committed, true, detail)
		local decoded = Codec.decode(files.config)
		-- The clear once switched the Gestures off with the assignments
		-- (gestures-clear-keeps-switch).
		helpers.assert_eq(decoded.gestures.enabled, true, "the clear owns the assignments, not the switch")
		helpers.assert_eq(decoded.gestures.tap_4, nil)
		helpers.assert_eq(decoded.gestures.modes.swipe_3_horiz, nil)
		helpers.assert_eq(decoded.gestures.modes.future, "keep")
		helpers.assert_eq(decoded.gestures.sensitivities.swipe_3_horiz, nil)
		helpers.assert_eq(decoded.gestures.sensitivities.future, 17)
		helpers.assert_eq(decoded.gestures.action_parameters.tap_4__open_url, nil)
		helpers.assert_eq(decoded.gestures.action_parameters.future.preserve, 7)
		helpers.assert_eq(decoded.gestures.action_parameters.keyboard__cmd_k__open_url, "https://example.com")
		helpers.assert_eq(files.backup, original)
		helpers.assert_eq(writes(), 2)
		helpers.assert_eq(state.gestures, true)
		helpers.assert_eq(gestures.is_enabled(), true)
		for slot in pairs(gestures.DEFAULT_GESTURES) do helpers.assert_eq(gestures.get_action(slot), "none") end
		helpers.assert_eq(gestures.get_mode("swipe_3_horiz"), Manifest.default_for("gestures.modes.swipe_3_horiz"))
		helpers.assert_eq(gestures.get_sensitivity("swipe_3_horiz"), Manifest.default_for("gestures.sensitivities.swipe_3_horiz"))
		helpers.assert_eq(prefs.source_snapshot("config").content, files.config)
		helpers.assert_eq(save(), true, "the next real save must use the new baseline")
	end)
	helpers.it("restores recommendations and seeds the rollback snapshot used by a later failed save", function()
		local owner, gestures, files, state, controls, _, save = fixture()
		helpers.assert_eq(menu_commands(owner, gestures, state).scope_restore(), true)
		for slot, value in pairs(gestures.RECOMMENDED_GESTURES) do helpers.assert_eq(gestures.get_action(slot), value) end
		helpers.assert_eq(state.gestures, Manifest.recommended_for("gestures.enabled"))
		local committed = files.config
		controls.refuse_write = true
		gestures.set_action("tap_4", "open_url")
		helpers.assert_eq(save(), false)
		helpers.assert_eq(gestures.get_action("tap_4"), gestures.RECOMMENDED_GESTURES.tap_4)
		helpers.assert_eq(files.config, committed)
	end)
	helpers.it("a pause leaves every store untouched", function()
		for _, mode in ipairs({ "clear", "recommended" }) do
			local owner, gestures, files, _, controls, _, _, writes, original = fixture()
			controls.paused = true
			helpers.assert_eq(owner.apply(mode), false)
			helpers.assert_eq(writes(), 0)
			helpers.assert_eq(files.config, original)
			helpers.assert_eq(gestures.get_action("tap_4"), "open_url")
		end
	end)
	helpers.it("refused publication restores native state and both preference baselines", function()
		local owner, gestures, files, state, controls, prefs, save, _, original = fixture()
		controls.refuse_write = true
		helpers.assert_eq(owner.apply("clear"), false)
		helpers.assert_eq(files.config, original)
		helpers.assert_eq(state.gestures, true)
		helpers.assert_eq(gestures.is_enabled(), true)
		helpers.assert_eq(gestures.get_action("tap_4"), "open_url")
		helpers.assert_eq(gestures.get_action_parameter("tap_4", "open_url"), "https://apple.com")
		helpers.assert_eq(prefs.source_snapshot("config").content, original)
		helpers.assert_eq(owner.pending(), false)
		controls.refuse_write = false
		helpers.assert_eq(save(), true)
	end)
	helpers.it("refuses stale source before backup and retains failed native compensation", function()
		local owner, gestures, files, _, controls, _, _, writes = fixture()
		files.config = '[future]\nexternal = true\n'
		helpers.assert_eq(owner.apply("clear"), false)
		helpers.assert_eq(writes(), 0)
		helpers.assert_eq(gestures.get_action("tap_4"), "open_url")
		owner, gestures, files, _, controls = fixture()
		controls.refuse_write, controls.refuse_enable = true, true
		helpers.assert_eq(owner.apply("clear"), false)
		helpers.assert_eq(owner.pending(), true)
		controls.refuse_enable = false
		helpers.assert_eq(owner.retry_restore(), true)
		helpers.assert_eq(owner.pending(), false)
		helpers.assert_eq(gestures.is_enabled(), true)
	end)
	helpers.it("the next save preserves unknown parameter neighbors when the owned registry is empty", function()
		local owner, gestures, files, _, _, _, save = fixture(
			'[gestures]\naction_parameters = { tap_4__open_url = "https://apple.com", future = { preserve = 7 } }\n')
		gestures.replace_action_parameters({ tap_4__open_url = "https://apple.com" })
		helpers.assert_eq(owner.apply("clear"), true)
		helpers.assert_eq(next(gestures.get_all_action_parameters()), nil)
		helpers.assert_eq(save(), true)
		helpers.assert_eq(Codec.decode(files.config).gestures.action_parameters.future.preserve, 7)
	end)
	-- A demotion is the switch saved on and off for this session. A clear leaves
	-- the switch alone, so it leaves the demotion too; a restore publishes the
	-- switch and ends it (gestures-clear-keeps-switch).
	helpers.it("a clear keeps the gesture demotion and a restore ends only that one, with an inverse when publication fails", function()
		for _, mode in ipairs({ "clear", "recommended" }) do
			for _, refuse in ipairs({ false, true }) do
				local owner, gestures, files, state, controls, _, save = fixture()
				controls.demotions.record({ feature = "gestures", key = "gestures", persisted = true, demoted = false })
				controls.demotions.record({ feature = "llm", key = "llm_enabled", persisted = true, demoted = false })
				state.gestures = false
				gestures.disable_all()
				controls.refuse_write = refuse
				helpers.assert_eq(owner.apply(mode), not refuse)
				local ended = mode == "recommended" and not refuse
				helpers.assert_eq(#controls.demotions.list(), ended and 1 or 2, mode)
				if not refuse then
					if ended then helpers.assert_eq(controls.demotions.list()[1].feature, "llm") end
					if mode == "clear" then
						helpers.assert_eq(gestures.is_enabled(), false, "the session demotion still holds")
					end
					helpers.assert_eq(save(), true)
					helpers.assert_eq(Codec.decode(files.config).gestures.enabled, true, mode)
				end
			end
		end
	end)
	helpers.it("supports an absent source and refuses nonterminal native setters", function()
		local owner, _, files, _, _, prefs = fixture(false)
		helpers.assert_eq(owner.apply("clear"), true)
		helpers.assert_eq(files.backup, nil)
		helpers.assert_eq(prefs.source_snapshot("config").content, files.config)
		local gestures, controls, original
		owner, gestures, files, _, controls, prefs, _, _, original = fixture()
		local setter = gestures.set_action
		gestures.set_action = function(slot, value) setter(slot, value); return "accepted" end
		helpers.assert_eq(owner.apply("clear"), false)
		helpers.assert_eq(files.config, original)
		helpers.assert_eq(prefs.source_snapshot("config").content, original)
		helpers.assert_eq(owner.pending(), true)
		gestures.set_action = setter
		helpers.assert_eq(owner.retry_restore(), true)
	end)
end)

package.loaded["adapters.file_system"] = FileSystem
package.loaded["infra.preferences"] = nil





-- ========================================================
-- ========================================================
-- ======= 2/ Recommended Two-finger Swipe Emission =======
-- ========================================================
-- ========================================================

local function actual_frame_fixture(source)
	package.loaded["adapters.file_system"] = FileSystem
	package.loaded["modules.gestures.engine"] = nil
	package.loaded["modules.gestures.conflicts"] = nil
	local recording = require("tests.support.synthetic_action_fixture").load("modules.gestures.actions")
	local actions = recording.subject
	local core, initialize = nil, actions.init
	actions.init = function(candidate)
		core = candidate
		return initialize(candidate)
	end
	package.loaded["modules.gestures"] = nil
	package.loaded["modules.gestures.init"] = nil
	local loaded, gestures = xpcall(function() return require("modules.gestures") end, debug.traceback)
	actions.init = initialize
	if not loaded then error(gestures, 0) end
	assert(type(core) == "table", "the actual gesture constructor did not publish its CoreState")
	local engine = require("modules.gestures.engine")
	assert(engine.init(core, actions) == true, "the actual engine refused the constructor's exact dependencies")
	assert(gestures.enable_all() == true, "the actual gesture master did not enable")
	local controls, state, files = {}, { gestures = true }, {}
	local original = source or '[gestures]\nenabled = true\ntap_4 = "open_url"\nmodes = { swipe_3_horiz = "incremental", future = "keep" }\nsensitivities = { swipe_3_horiz = 9, future = 17 }\naction_parameters = { tap_4__open_url = "https://apple.com", keyboard__cmd_k__open_url = "https://example.com", future = { preserve = 7 } }\n[future]\nkeep = 42\n'
	files.config = original
	if source == false then files.config = nil end
	local writes, backup_generation = 0, 0
	gestures.set_action("tap_4", "open_url")
	gestures.set_mode("swipe_3_horiz", "incremental")
	gestures.set_sensitivity("swipe_3_horiz", 9)
	gestures.set_action_parameter("tap_4", "open_url", "https://apple.com")
	gestures.set_action_parameter("keyboard__cmd_k", "open_url", "https://example.com")
	local files_port = {
		read_with_status = function(path) return files[path], files[path] and "ok" or "absent" end,
		write = function() error("unguarded write") end,
		write_if_unchanged = function(path, value, expected)
			if controls.refuse_write and path == "config" then return false end
			if expected.status == "ok" and files[path] ~= expected.content then return false end
			if expected.status == "absent" and files[path] ~= nil then return false end
			if path == "config" and controls.during_write then controls.during_write() end
			files[path] = value
			writes = writes + 1
			return true
		end,
	}
	package.loaded["adapters.file_system"] = files_port
	local prefs = helpers.load_with_stubs("infra.preferences")
	prefs.load("config")
	local PT = require("ui.menu.preferences_transaction")
	local modules = { gestures = gestures }
	local demotions = require("ui.menu.session_demotions").new()
	controls.demotions = demotions
	local save, checkpoint = PT.bind(prefs, {
		path = "config", state = state, hotfiles = {}, core_modules = modules,
		initial_state = state, initial_preferences = prefs.snapshot(state, {}, modules),
		snapshot_view = demotions.persisted_view,
		restore_runtime = function(snapshot)
			gestures.set_action("tap_4", snapshot.gesture_actions.tap_4)
			return true
		end,
	})
	local owner = require("ui.menu.gesture_scope").new({
		path = "config", files = files_port, state = state, gestures = gestures,
		preferences = prefs, checkpoint = checkpoint,
		demotions = demotions,
		capture_preferences = function() return prefs.snapshot(state, {}, modules) end,
		backup_path = function()
			backup_generation = backup_generation + 1
			return "backup-" .. backup_generation
		end,
		paused = function() return controls.paused == true end,
		admission = function(_, callback) return callback() end,
	})
	return owner, gestures, files, state, recording, core, engine
end

--- Captures the actual menu provider while retaining its canonical templates.
--- @param owner table Actual scoped preference owner.
--- @param gestures table Actual gesture module.
--- @param state table Menu feature state.
--- @return table commands Menu commands.
--- @return table providers Menu data providers.
local function actual_menu_frame(owner, gestures, state)
	local renderer = require("infra.manifest_menu")
	local original_build, commands, providers = renderer.build, nil, nil
	renderer.build = function(_, _, _, _, context, dynamic)
		commands, providers = context.commands, dynamic
		return {}
	end
	local ok, detail = xpcall(function()
		require("ui.menu.menu_gestures").build({ gestures = gestures, state = state, paused = false,
			apply_gesture_scope = owner.apply,
			save_prefs = function() error("the scope must not use an ordinary save") end,
			updateMenu = function() end })
	end, debug.traceback)
	renderer.build = original_build
	if not ok then error(detail, 0) end
	return commands, providers
end

helpers.describe("macOS two-finger neutral recommendations", function()
	for _, restore in ipairs({ true, false }) do
		local title = restore and "clear then recommended leaves every two-contact gesture to the OS"
			or "an explicit custom two-contact binding remains unchanged and emits its tagged key"
		helpers.it(title, function()
			local previous_files = package.loaded["adapters.file_system"]
			helpers.with_stub_scope({
				"modules.gestures", "modules.gestures.init", "modules.gestures.engine",
				"modules.gestures.actions", "modules.gestures.conflicts", "modules.gestures.actions_click",
				"modules.gestures.actions_aux_owner", "modules.gestures.sticky_modifiers",
				"adapters.file_system",
				"adapters.synthetic_input", "adapters.event_provenance", "adapters.timer_scheduler",
				"infra.preferences", "ui.menu.gesture_scope", "ui.menu.scoped_preferences",
				"ui.menu.preferences_transaction", "ui.menu.menu_gestures", "infra.manifest_menu",
			}, function()
				local original = '[gestures]\nenabled = true\nswipe_2_left = "arrow_up"\n'
				local owner, gestures, files, state, recording, core, engine = actual_frame_fixture(original)
				helpers.assert_eq(gestures.set_action("swipe_2_left", "arrow_up"), true)
				local prior_first_frame = rawget(_G, "ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME")
				local ok, detail = xpcall(function()
					local commands = actual_menu_frame(owner, gestures, state)
					if restore then
						helpers.assert_eq(commands.scope_clear(), true)
						helpers.assert_eq(core.ga.swipe_2_left, "none")
						helpers.assert_eq(commands.scope_restore(), true)
						local decoded = Codec.decode(files.config)
						for _, slot in ipairs({ "tap_2", "swipe_2_left", "swipe_2_right", "swipe_2_up", "swipe_2_down",
							"swipe_2_left_up", "swipe_2_right_up", "swipe_2_left_down", "swipe_2_right_down" }) do
							helpers.assert_eq(gestures.get_action(slot), "none", slot)
							helpers.assert_eq(decoded.gestures[slot], nil, "the neutral default must not persist a custom binding: " .. slot)
						end
					else
						helpers.assert_eq(files.config, original, "new recommendations must not rewrite an authored file")
						helpers.assert_eq(core.ga.swipe_2_left, "arrow_up")
					end
					helpers.assert_eq(core.enabled, true)
					local _, providers = actual_menu_frame(owner, gestures, state)
					local expected_label = restore and "gesture.slots.swipe_2_left : sg_actions.none"
						or "gesture.slots.swipe_2_left : arrow_up"
					local found = 0
					for _, row in ipairs(providers.gesture_slots_2()) do
						if row.label == expected_label then found = found + 1 end
					end
					helpers.assert_eq(found, 1, "the actual UI must describe the same owner's effective binding")
					local scroll_tap
					for _, tap in ipairs(recording.hs.eventtap.__taps) do
						if tap.types and tap.types[1] == recording.hs.eventtap.event.types.scrollWheel then scroll_tap = tap end
					end
					helpers.assert_true(scroll_tap ~= nil and scroll_tap:isEnabled(), "the real engine tap must be live")
					local clock = 1000
					recording.hs.timer.secondsSinceEpoch = function() return clock end
					local before = recording.synthetic.stats()
					local function frame(x, y, lifted)
						local touches = lifted and {} or {
							{ absoluteVector = { position = { x = x, y = y } } },
							{ absoluteVector = { position = { x = x + 10, y = y } } },
						}
						helpers.assert_eq(engine.process_frame(touches), nil, "frame observation is not an input consume return")
						helpers.assert_eq(engine.is_blocking_scroll(), false)
						for _, event_type in ipairs({ recording.hs.eventtap.event.types.scrollWheel, recording.hs.eventtap.event.types.gesture }) do
							helpers.assert_eq(scroll_tap.fn({ getType = function() return event_type end }), false,
								"the actual scroll/gesture callback must preserve OS input")
						end
						clock = clock + 0.02
					end
					local movements = restore and { { -12, 0 }, { 12, 0 }, { 0, -12 }, { 0, 12 },
						{ -12, -12 }, { 12, -12 }, { -12, 12 }, { 12, 12 }, { 0, 0 } } or { { -12, 0 } }
					for _, movement in ipairs(movements) do
						for _ = 1, 8 do frame(100, 100) end
						frame(100 + movement[1], 100 + movement[2])
						frame(100 + movement[1], 100 + movement[2])
						frame(0, 0, true)
					end
					if restore then
						local after = recording.synthetic.stats()
						helpers.assert_eq(after.action_handoffs, before.action_handoffs, "none must not dispatch an action")
						helpers.assert_eq(after.pending, before.pending, "none must not enqueue a key")
					else
						local events, down, up = recording.drain("test.trackpad.custom")
						helpers.assert_eq(#events, 2)
						helpers.assert_eq(events[1].key, "up")
						helpers.assert_eq(events[2].key, "up")
						helpers.assert_eq(events[1].isDown, true)
						helpers.assert_eq(events[2].isDown, false)
						helpers.assert_eq(#events[1].mods, 0)
						helpers.assert_eq(#events[2].mods, 0)
						helpers.assert_eq(down.effect, "action")
						helpers.assert_eq(up.effect, "action")
					end
				end, debug.traceback)
				_G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME = prior_first_frame
				assert(engine.stop() == true, "the exact inert engine tap must retire")
				if not ok then error(detail, 0) end
			end)
			helpers.assert_true(rawequal(package.loaded["adapters.file_system"], previous_files),
				"the complete actual-owner case must restore the exact filesystem adapter")
		end)
	end
end)
