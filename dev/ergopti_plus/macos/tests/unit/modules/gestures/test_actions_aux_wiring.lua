--- tests/unit/modules/gestures/test_actions_aux_wiring.lua

--- ==============================================================================
--- MODULE: Gesture Auxiliary Owner Wiring
--- DESCRIPTION:
--- Calls the real Actions registry through representative timer, shell and
--- screenshot entries. This mutation-sensitive slice prevents a false green in
--- which the exact owners exist but production registrations still use raw APIs.
--- ==============================================================================

local helpers = require("tests.helpers")


local function fresh_actions(options)
	local controls = options or {}
	for _, name in ipairs({
		"modules.gestures.actions",
		"modules.gestures.actions_aux_owner",
		"modules.gestures.actions_click",
		"modules.gestures.sticky_modifiers",
		"modules.shortcuts.actions.screenshot_save",
		"modules.shortcuts.actions.text",
		"modules.shortcuts.actions.system_mouse",
		"adapters.file_system",
		"adapters.key_state",
		"adapters.synthetic_input",
		"infra.termination_coordinator",
		"infra.logger",
		"infra.paths",
		"infra.timings",
		"infra.i18n",
	}) do package.loaded[name] = nil end

	local calls = {
		after = {},
		open = {},
		applescript = {},
		capture = {},
		save = {},
		pause = 0,
		resume = 0,
		commit = 0,
		rollback = 0,
		reload = 0,
		keys = {},
		mouse_posts = {},
		mouse_post_attempts = {},
		opened_urls = {},
		screenshot_pause = {},
		screenshot_resume = {},
		action_parents = {},
		text_actions = {},
		mouse_actions = {},
		text_lifecycle = {},
		mouse_lifecycle = {},
		text_queries = {},
		mouse_queries = {},
		aux_queries = {},
		screenshot_queries = {},
		click_force_parents = {},
		click_release_parents = {},
		sticky_clear_parents = {},
		reentrant_results = {},
		search_cleanup_results = {},
		clipboard_restore_calls = 0,
		lookup_cleanup_results = {},
	}
	calls.controls = controls
	local clipboard_data = { ["public.utf8-plain-text"] = "original" }
	local function clone_clipboard(data)
		local copy = {}
		for key, value in pairs(data or {}) do copy[key] = value end
		return copy
	end
	local screenshot_claims = {}
	local text_paused = {}
	local mouse_paused = {}
	local aux_paused = { gestures = controls.aux_paused == true }
	local next_token = 0
	local function controlled_result(mode, message)
		if mode == "false" then return false end
		if mode == "nil" then return nil end
		if mode == "throw" then error(message) end
		return true
	end
	controls.resume_entered = {}
	local function controlled_query(owner, edge, actual)
		local mode = controls[owner .. "_" .. edge .. "_query_mode"]
		if controls.query_fault_phase == "resume"
			and controls.resume_entered[owner] ~= true then
			mode = nil
		end
		if mode == "nil" then return nil end
		if mode == "throw" then
			error(owner .. " " .. edge .. " query exploded")
		end
		if mode == "false" then return false end
		if mode == "true" then return true end
		return actual
	end
	local actions
	local function reenter_during_resume(kind, parent)
		if controls.reenter_during_resume ~= kind then return end
		local binding = parent == "shortcut_bindings"
			and "keyboard__cmd_1" or "tap_3"
		calls.reentrant_results[#calls.reentrant_results + 1] =
			actions.execute_single("open_config", binding)
	end
	local function prepare_after(delay, label, callback, parent)
		parent = parent or "gestures"
		local accepted = controlled_result(
			controls.prepare_mode, "auxiliary timer acquisition exploded")
		if accepted ~= true then return accepted, nil end
		if aux_paused[parent] == true then return false, nil end
		next_token = next_token + 1
		local token = { id = next_token, callback = callback, active = true }
		token.parent = parent
		calls.after[#calls.after + 1] = {
			delay = delay,
			label = label,
			callback = callback,
			token = token,
			parent = parent,
		}
		return true, token
	end
	package.loaded["modules.gestures.actions_aux_owner"] = {
		after = function(delay, label, callback, parent)
			local prepared, token = prepare_after(delay, label, callback, parent)
			if prepared ~= true then return prepared end
			calls.commit = calls.commit + 1
			token.committed = true
			return true, token
		end,
		prepare_after = prepare_after,
		commit_after = function(token)
			calls.commit = calls.commit + 1
			local accepted = controlled_result(
				controls.commit_mode, "auxiliary timer commit exploded")
			if accepted ~= true then return accepted end
			if type(token) ~= "table" or token.active ~= true
				or aux_paused[token.parent or "gestures"] == true then return false end
			token.committed = true
			return true
		end,
		rollback_after = function(token)
			calls.rollback = calls.rollback + 1
			local accepted = controlled_result(
				controls.rollback_mode, "auxiliary timer rollback exploded")
			if accepted == true and type(token) == "table" then token.active = false end
			return accepted
		end,
		open = function(target, label, _, parent)
			calls.open[#calls.open + 1] = {
				target = target, label = label, parent = parent,
			}
			return true
		end,
		applescript = function(script, label, _, parent)
			calls.applescript[#calls.applescript + 1] = {
				script = script, label = label, parent = parent,
			}
			return true
		end,
		pause = function(parent)
			calls.pause = calls.pause + 1
			calls.action_parents[#calls.action_parents + 1] = parent
			local pause_mode = controls.aux_pause_mode
			if controls.rollback_pause_armed == true
				and controls.rollback_pause_kind == "auxiliary" then
				pause_mode = controls.rollback_pause_mode
			end
			local accepted = controlled_result(pause_mode, "auxiliary pause exploded")
			if accepted == true then
				local scope_id = parent or "gestures"
				aux_paused[scope_id] = true
				for _, entry in ipairs(calls.after) do
					if entry.token.parent == scope_id then entry.token.active = false end
				end
			end
			return accepted
		end,
		resume = function(parent)
			calls.resume = calls.resume + 1
			calls.action_parents[#calls.action_parents + 1] = parent
			controls.resume_entered.aux = true
			if controls.rollback_pause_kind == "auxiliary" then
				controls.rollback_pause_armed = true
			end
			local accepted = controlled_result(controls.aux_resume_mode, "auxiliary resume exploded")
			if accepted == true then aux_paused[parent or "gestures"] = false end
			return accepted
		end,
		is_paused = function(parent)
			calls.aux_queries[#calls.aux_queries + 1] = {
				edge = "paused", parent = parent,
			}
			return controlled_query("aux", "paused",
				aux_paused[parent or "gestures"] == true)
		end,
		has_pending = function(parent)
			calls.aux_queries[#calls.aux_queries + 1] = {
				edge = "pending", parent = parent,
			}
			return controlled_query("aux", "pending", false)
		end,
	}
	package.loaded["modules.shortcuts.actions.screenshot_save"] = {
		capture = function(flags, parent)
			parent = parent or "shortcut_bindings"
			if screenshot_claims[parent] == true then return false end
			calls.capture[#calls.capture + 1] = flags
			calls.action_parents[#calls.action_parents + 1] = parent
			return true
		end,
		save = function(flags, prefix, parent)
			parent = parent or "shortcut_bindings"
			if screenshot_claims[parent] == true then return false end
			calls.save[#calls.save + 1] = { flags = flags, prefix = prefix, parent = parent }
			return true
		end,
		pause_screenshot_actions = function(parent)
			parent = parent or "shortcut_bindings"
			calls.screenshot_pause[#calls.screenshot_pause + 1] = parent
			local accepted = true
			if controls.rollback_pause_armed == true
				and controls.rollback_pause_kind == "screenshot" then
				accepted = controlled_result(controls.rollback_pause_mode,
					"screenshot rollback pause exploded")
			end
			if accepted == true then screenshot_claims[parent] = true end
			return accepted
		end,
		resume_screenshot_actions = function(parent)
			parent = parent or "shortcut_bindings"
			calls.screenshot_resume[#calls.screenshot_resume + 1] = parent
			controls.resume_entered.screenshot = true
			reenter_during_resume("screenshot", parent)
			if controls.rollback_pause_kind == "screenshot" then
				controls.rollback_pause_armed = true
			end
			local accepted = controlled_result(
				controls.screenshot_resume_mode, "screenshot resume exploded")
			if controls.screenshot_resume_mutates == true or accepted == true then
				screenshot_claims[parent] = nil
			end
			if controls.pause_during_screenshot_resume == true then
				aux_paused[parent or "gestures"] = true
			end
			return accepted
		end,
		has_screenshot_pause_claim = function(parent)
			calls.screenshot_queries[#calls.screenshot_queries + 1] = {
				edge = "paused", parent = parent,
			}
			return controlled_query("screenshot", "paused",
				screenshot_claims[parent] == true)
		end,
		has_pending_screenshot_action = function(parent)
			calls.screenshot_queries[#calls.screenshot_queries + 1] = {
				edge = "pending", parent = parent,
			}
			return controlled_query("screenshot", "pending", false)
		end,
	}
	local function scoped_child(paused, kind)
		local lifecycle_calls = calls[kind .. "_lifecycle"]
		local query_calls = calls[kind .. "_queries"]
		local function lifecycle(edge, parent)
			lifecycle_calls[#lifecycle_calls + 1] = { edge = edge, parent = parent }
		end
		local function query(edge, parent)
			query_calls[#query_calls + 1] = { edge = edge, parent = parent }
		end
		local child = {
			pause_text_actions = function(parent)
				lifecycle("pause", parent)
				local accepted = true
				if controls.rollback_pause_armed == true
					and controls.rollback_pause_kind == kind then
					accepted = controlled_result(controls.rollback_pause_mode,
						kind .. " rollback pause exploded")
				end
				if accepted == true then paused[parent] = true end
				return accepted
			end,
			resume_text_actions = function(parent)
				lifecycle("resume", parent)
				controls.resume_entered[kind] = true
				reenter_during_resume(kind, parent)
				if controls.rollback_pause_kind == kind then
					controls.rollback_pause_armed = true
				end
				local accepted = controlled_result(
					controls[kind .. "_resume_mode"], kind .. " resume exploded")
				if controls[kind .. "_resume_mutates"] == true or accepted == true then
					paused[parent] = false
				end
				return accepted
			end,
			is_text_actions_paused = function(parent)
				query("paused", parent)
				return controlled_query(kind, "paused", paused[parent] == true)
			end,
			has_pending_text_action = function(parent)
				query("pending", parent)
				return controlled_query(kind, "pending", false)
			end,
			pause_mouse_actions = function(parent)
				lifecycle("pause", parent)
				local accepted = true
				if controls.rollback_pause_armed == true
					and controls.rollback_pause_kind == kind then
					accepted = controlled_result(controls.rollback_pause_mode,
						kind .. " rollback pause exploded")
				end
				if accepted == true then paused[parent] = true end
				return accepted
			end,
			resume_mouse_actions = function(parent)
				lifecycle("resume", parent)
				controls.resume_entered[kind] = true
				reenter_during_resume(kind, parent)
				if controls.rollback_pause_kind == kind then
					controls.rollback_pause_armed = true
				end
				local accepted = controlled_result(
					controls[kind .. "_resume_mode"], kind .. " resume exploded")
				if controls[kind .. "_resume_mutates"] == true or accepted == true then
					paused[parent] = false
				end
				return accepted
			end,
			is_mouse_actions_paused = function(parent)
				query("paused", parent)
				return controlled_query(kind, "paused", paused[parent] == true)
			end,
			has_pending_mouse_action = function(parent)
				query("pending", parent)
				return controlled_query(kind, "pending", false)
			end,
		}
		if kind == "text" then
			child.select_line = function(parent)
				parent = parent or "shortcut_bindings"
				if paused[parent] == true then return false end
				calls.text_actions[#calls.text_actions + 1] = {
					name = "select_line", parent = parent,
				}
				return true
			end
		else
			child.teleport_mouse = function(parent)
				parent = parent or "shortcut_bindings"
				if paused[parent] == true then return false end
				calls.mouse_actions[#calls.mouse_actions + 1] = {
					name = "teleport_mouse", parent = parent,
				}
				return true
			end
			child.lock_screen = function(parent)
				parent = parent or "shortcut_bindings"
				if paused[parent] == true then return false end
				calls.mouse_actions[#calls.mouse_actions + 1] = {
					name = "lock_screen", parent = parent,
				}
				return true
			end
			child.spotlight_mouse = function(_, parent)
				parent = parent or "shortcut_bindings"
				if paused[parent] == true then return false end
				calls.mouse_actions[#calls.mouse_actions + 1] = {
					name = "spotlight_mouse", parent = parent,
				}
				return true
			end
		end
		return child
	end
	package.loaded["modules.shortcuts.actions.text"] = scoped_child(text_paused, "text")
	package.loaded["modules.shortcuts.actions.system_mouse"] = scoped_child(mouse_paused, "mouse")
	package.loaded["modules.gestures.actions_click"] = setmetatable({
		force_cleanup = function(parent)
			calls.click_force_parents[#calls.click_force_parents + 1] = parent
			return true
		end,
		release_held_for_tap = function(_, parent)
			calls.click_release_parents[#calls.click_release_parents + 1] = parent
			if controls.axis_during_release == true then
				controls.axis_during_release = false
				calls.nested_axis_result = actions.execute_axis("lines", true)
			end
			local accepted = controlled_result(
				controls.release_mode, "held-click release exploded")
			if controls.pause_on_release == true then aux_paused.gestures = true end
			return accepted
		end,
	}, { __index = function() return function() return true end end })
	package.loaded["modules.gestures.sticky_modifiers"] = setmetatable({
		clear = function(parent)
			calls.sticky_clear_parents[#calls.sticky_clear_parents + 1] = parent
			return true
		end,
	}, { __index = function() return function() return true end end })
	package.loaded["adapters.file_system"] = {
		read = function() return nil end,
		read_file = function() return nil end,
	}
	package.loaded["adapters.key_state"] = setmetatable({}, {
		__index = function() return function() return false end end,
	})
	package.loaded["adapters.synthetic_input"] = setmetatable({
		emit_key_stroke = function(mods, key)
			if controls.search_reenter == "emit" and key == "c" then
				controls.search_reenter = nil
				calls.search_cleanup_results[#calls.search_cleanup_results + 1] =
					actions.force_cleanup(controls.search_parent or "gestures")
			end
			local accepted = controlled_result(
				controls.key_post_mode, "synthetic key post exploded")
			if accepted == true then
				if key == "c" then
					-- Model the native copy mutation after the re-entrant lifecycle
					-- callback returns, which is the hostile ordering production must own.
					clipboard_data = {
						["public.utf8-plain-text"] = "selected words",
					}
				end
				calls.keys[#calls.keys + 1] = { mods = mods, key = key }
			end
			if controls.pause_on_key == true then aux_paused.gestures = true end
			return accepted
		end,
	}, { __index = function() return function() return true end end })
	package.loaded["infra.termination_coordinator"] = { request_exit = function() return true end }
	package.loaded["infra.paths"] = { shared = function() return "Z:/missing" end }
	package.loaded["infra.timings"] = { sec = function() return 0.2 end }
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.i18n"] = { get = function(key) return key end }

	local event_types = { rightMouseDown = 1, rightMouseUp = 2 }
	actions = helpers.load_with_stubs("modules.gestures.actions", {
		configdir = "/tmp/ergopti",
		reload = function() calls.reload = calls.reload + 1; return true end,
		mouse = {
			absolutePosition = function()
				local accepted = controlled_result(
					controls.mouse_read_mode, "mouse position read exploded")
				if accepted ~= true then return accepted end
				if controls.pause_on_mouse_read == true then aux_paused.gestures = true end
				return { x = 1, y = 2 }
			end,
		},
		eventtap = {
			event = {
				types = event_types,
				newMouseEvent = function(event_type)
					local construct_mode = event_type == event_types.rightMouseDown
						and controls.down_construct_mode or controls.up_construct_mode
					local accepted = controlled_result(
						construct_mode, "mouse event construction exploded")
					if accepted ~= true then return accepted end
					local event = { event_type = event_type }
					function event:post()
						calls.mouse_post_attempts[#calls.mouse_post_attempts + 1] = self
						local post_mode
						if self.event_type == event_types.rightMouseDown then
							post_mode = controls.down_post_mode
						else
							post_mode = controls.up_post_mode
						end
						local posted = controlled_result(post_mode, "mouse event post exploded")
						if posted == true then
							calls.mouse_posts[#calls.mouse_posts + 1] = self.event_type
						end
						if controls.pause_on_post == self.event_type then
							controls.pause_on_post = nil
							calls.lookup_cleanup_results[#calls.lookup_cleanup_results + 1] =
								actions.force_cleanup(controls.pause_parent or "gestures")
						end
						return posted == true and self or posted
					end
					return event
				end,
			},
		},
		pasteboard = {
			readAllData = function()
				return clone_clipboard(clipboard_data)
			end,
			clearContents = function()
				if controls.search_reenter == "clear" then
					controls.search_reenter = nil
					calls.search_cleanup_results[#calls.search_cleanup_results + 1] =
						actions.force_cleanup(controls.search_parent or "gestures")
				end
				-- The native mutation occurs after the re-entrant cleanup returns.
				clipboard_data = {}
				return true
			end,
			getContents = function()
				return clipboard_data["public.utf8-plain-text"]
			end,
			writeAllData = function(data)
				calls.clipboard_restore_calls = calls.clipboard_restore_calls + 1
				if controls.search_reenter == "restore" then
					controls.search_reenter = nil
					calls.search_cleanup_results[#calls.search_cleanup_results + 1] =
						actions.force_cleanup(controls.search_parent or "gestures")
				end
				local accepted = controlled_result(
					controls.search_restore_mode, "clipboard restore exploded")
				if accepted == true then clipboard_data = clone_clipboard(data) end
				return accepted
			end,
		},
		urlevent = {
			openURL = function(url)
				calls.opened_urls[#calls.opened_urls + 1] = url
				return true
			end,
		},
	})
	calls.hs = _G.hs
	if controls.search_reenter == "timer" then
		local original_do_after = calls.hs.timer.doAfter
		calls.hs.timer.doAfter = function(delay, callback)
			controls.search_reenter = nil
			calls.search_cleanup_results[#calls.search_cleanup_results + 1] =
				actions.force_cleanup(controls.search_parent or "gestures")
			return original_do_after(delay, callback)
		end
	end
	calls.aux_is_paused = function(parent)
		return aux_paused[parent or "gestures"] == true
	end
	calls.text_is_paused = function(parent) return text_paused[parent] == true end
	calls.mouse_is_paused = function(parent) return mouse_paused[parent] == true end
	calls.screenshot_is_paused = function(parent)
		return screenshot_claims[parent] == true
	end
	calls.clipboard_text = function()
		return clipboard_data["public.utf8-plain-text"]
	end
	calls.fire = function(token)
		if type(token) ~= "table" or token.active ~= true or token.committed ~= true then
			return false
		end
		token.active = false
		token.callback()
		return true
	end
	calls.static_screenshot = function()
		return package.loaded["modules.shortcuts.actions.screenshot_save"]
			.capture({ "-cw" }, "shortcut_bindings")
	end
	return actions, calls
end

--- Loads the real Shortcuts/Gestures feature lifecycle shells around one real
--- Actions registry. Only their native-heavy children are replaced; the parent
--- claim and scope orchestration under test remains production code.
--- @param actions table Real modules.gestures.actions instance.
--- @param calls table Owner recorder returned by fresh_actions().
--- @param body function Receives Shortcuts, Gestures, and feature recorder.
local function with_feature_lifecycles(actions, calls, body)
	local module_names = {
		"modules.shortcuts",
		"modules.shortcuts.bindings",
		"modules.shortcuts.script_control",
		"modules.shortcuts.keyboard_shortcuts",
		"adapters.hotkey_registrar",
		"infra.startup_transaction",
		"modules.gestures",
		"modules.gestures.engine",
		"modules.gestures.conflicts",
		"infra.manifest_reader",
	}
	local saved = {}
	for _, name in ipairs(module_names) do saved[name] = package.loaded[name] end

	local feature = {
		bindings_started = false,
		keyboard_started = false,
		unblock_calls = 0,
	}
	package.loaded["modules.shortcuts.bindings"] = {
		DEFAULT_CHATGPT_URL = "",
		start = function() feature.bindings_started = true; return true end,
		stop = function() feature.bindings_started = false; return true end,
		pause = function() feature.bindings_started = false; return true end,
		resume_after_pause = function()
			feature.bindings_started = true
			return true
		end,
		is_started = function() return feature.bindings_started end,
		has_pause_debt = function() return false end,
	}
	package.loaded["modules.shortcuts.script_control"] = {
		ACTIONS = {}, ACTION_LABELS = {}, PAUSE_OWNER_IDS = {},
		start = function() return true end,
		stop = function() return true end,
		is_paused = function() return false end,
	}
	package.loaded["modules.shortcuts.keyboard_shortcuts"] = {
		SLOT_GROUPS = {},
		start = function() feature.keyboard_started = true; return true end,
		stop = function() feature.keyboard_started = false; return true end,
	}
	package.loaded["adapters.hotkey_registrar"] = {
		set_delivery_guard = function() return true end,
	}
	package.loaded["infra.startup_transaction"] = {
		run = function(steps)
			local applied = {}
			for _, step in ipairs(steps) do
				local ok, result = xpcall(step.start, debug.traceback)
				if not ok or result ~= true then
					for index = #applied, 1, -1 do
						xpcall(applied[index].stop, debug.traceback)
					end
					return false
				end
				applied[#applied + 1] = step
			end
			return true
		end,
	}
	package.loaded["modules.gestures.engine"] = setmetatable({
		init = function() return true end,
		unblock_scroll = function()
			feature.unblock_calls = feature.unblock_calls + 1
			return true
		end,
	}, { __index = function() return function() return true end end })
	package.loaded["modules.gestures.conflicts"] = setmetatable({}, {
		__index = function() return function() return true end end,
	})
	package.loaded["infra.manifest_reader"] = {
		default_for = function() return true end,
	}
	package.loaded["modules.gestures.actions"] = actions
	package.loaded["modules.shortcuts"] = nil
	package.loaded["modules.gestures"] = nil

	feature.keyboard_execute = function(action)
		if feature.keyboard_started ~= true then return false end
		return actions.execute_single(action, "keyboard__cmd_1")
	end
	feature.static_screenshot = function()
		if feature.bindings_started ~= true then return false end
		return calls.static_screenshot()
	end

	local ok, err = xpcall(function()
		body(require("modules.shortcuts"), require("modules.gestures"), feature)
	end, debug.traceback)
	for _, name in ipairs(module_names) do package.loaded[name] = saved[name] end
	package.loaded["modules.gestures.actions"] = actions
	if not ok then error(err, 0) end
end


helpers.describe("gesture Actions exact-owner wiring", function()
	helpers.it("routes representative async actions and lifecycle boundaries", function()
		local actions, calls = fresh_actions()
		helpers.assert_eq(actions.trigger_lookup(), true)
		helpers.assert_eq(actions.execute_axis("lines", true), true)
		helpers.assert_eq(actions.execute_single("script_save_reload"), true)
		helpers.assert_eq(#calls.after, 3)
		helpers.assert_eq(calls.after[1].label, "dictionary lookup")
		helpers.assert_eq(calls.after[2].label, "line down")
		helpers.assert_eq(calls.after[3].label, "script save reload")

		helpers.assert_eq(actions.execute_single("notification_center"), true)
		helpers.assert_eq(actions.execute_single("open_config"), true)
		helpers.assert_eq(#calls.applescript, 1)
		helpers.assert_eq(#calls.open, 1)
		helpers.assert_eq(calls.open[1].target, "/tmp/ergopti/config.toml")

		helpers.assert_eq(actions.execute_single("screenshot_region_clipboard"), true)
		helpers.assert_eq(actions.execute_single("screenshot_window_save"), true)
		helpers.assert_eq(calls.capture[1], { "-ci" })
		helpers.assert_eq(calls.save[1].prefix, "win")

		helpers.assert_eq(actions.force_cleanup(), true)
		helpers.assert_eq(calls.pause, 1)
		helpers.assert_eq(calls.screenshot_pause, { "gestures" })
		helpers.assert_eq(actions.execute_single("open_config"), false,
			"the shared auxiliary fence must block registry delivery")
		helpers.assert_eq(#calls.open, 1)
		helpers.assert_eq(actions.resume_after_cleanup(), true)
		helpers.assert_eq(calls.resume, 1)
		helpers.assert_eq(calls.pause, 2,
			"resume preflight must rejoin cleanup before reopening")
		helpers.assert_eq(calls.screenshot_pause, { "gestures", "gestures" })
		helpers.assert_eq(calls.screenshot_resume, { "gestures" })
		helpers.assert_eq(actions.execute_single("open_config"), true)
		helpers.assert_eq(#calls.open, 2)
	end)

	helpers.it("pins nested axis dispatch to the gesture parent", function()
		local actions, calls = fresh_actions({ axis_during_release = true })
		helpers.assert_eq(actions.execute_single(
			"open_config", "keyboard__cmd_1"), true)
		helpers.assert_eq(calls.nested_axis_result, true)
		helpers.assert_eq(#calls.after, 1)
		helpers.assert_eq(calls.after[1].label, "line down")
		helpers.assert_eq(calls.after[1].parent, "gestures",
			"a nested keyboard dispatch must not lend its shortcut parent to an axis")
	end)

	helpers.it("routes catalogue lock_screen through the scoped mouse owner", function()
		local actions, calls = fresh_actions()
		helpers.assert_eq(actions.execute_single(
			"lock_screen", "keyboard__cmd_1"), true)
		helpers.assert_eq(calls.mouse_actions[#calls.mouse_actions], {
			name = "lock_screen", parent = "shortcut_bindings",
		})
		helpers.assert_eq(actions.execute_single("lock_screen", "tap_3"), true)
		helpers.assert_eq(calls.mouse_actions[#calls.mouse_actions], {
			name = "lock_screen", parent = "gestures",
		})
	end)
end)


helpers.describe("gesture Actions feature isolation", function()
	helpers.it("keeps keyboard actions live when gestures are off and vice versa", function()
		local actions, calls = fresh_actions()
		helpers.assert_eq(actions.force_cleanup("gestures"), true)
		helpers.assert_eq(actions.execute_single("open_config"), false)
		helpers.assert_eq(
			actions.execute_single("open_config", "keyboard__cmd_1"), true)
		helpers.assert_eq(calls.open[1].parent, "shortcut_bindings")
		helpers.assert_eq(actions.execute_single(
			"screenshot_region_clipboard", "keyboard__cmd_1"), true)
		helpers.assert_eq(calls.action_parents[#calls.action_parents],
			"shortcut_bindings")

		helpers.assert_eq(actions.force_cleanup("shortcut_bindings"), true)
		helpers.assert_eq(actions.resume_after_cleanup("gestures"), true)
		helpers.assert_eq(actions.execute_single("open_config"), true)
		helpers.assert_eq(calls.open[#calls.open].parent, "gestures")
		helpers.assert_eq(
			actions.execute_single("open_config", "keyboard__cmd_1"), false)
	end)

	helpers.it("keeps a sibling search timer authorized and published in both directions", function()
		local actions, calls = fresh_actions()
		actions.init({ action_params = {} })
		helpers.assert_eq(actions.set_action_parameter(
			"keyboard__cmd_1", "search_web", "https://example.test/?q=%s"), true)
		helpers.assert_eq(actions.execute_single(
			"search_web", "keyboard__cmd_1"), true)
		local shortcut_timer = calls.hs.timer.__timers[#calls.hs.timer.__timers]
		helpers.assert_not_nil(shortcut_timer)
		helpers.assert_eq(actions.force_cleanup("gestures"), true)
		helpers.assert_eq(shortcut_timer.running, true,
			"gesture cleanup must not stop a shortcut-owned search timer")
		shortcut_timer:fire()
		helpers.assert_eq(#calls.opened_urls, 1,
			"the surviving shortcut capture must still publish its browser URL")

		helpers.assert_eq(actions.resume_after_cleanup("gestures"), true)
		helpers.assert_eq(actions.set_action_parameter(
			"tap_3", "search_web", "https://example.test/?q=%s"), true)
		helpers.assert_eq(actions.execute_single("search_web", "tap_3"), true)
		local gesture_timer = calls.hs.timer.__timers[#calls.hs.timer.__timers]
		helpers.assert_true(gesture_timer ~= shortcut_timer)
		helpers.assert_eq(actions.force_cleanup("shortcut_bindings"), true)
		helpers.assert_eq(gesture_timer.running, true,
			"shortcut cleanup must not stop a gesture-owned search timer")
		gesture_timer:fire()
		helpers.assert_eq(#calls.opened_urls, 2,
			"the surviving gesture capture must still publish its browser URL")
	end)

	helpers.it("keeps both feature directions isolated and preserves global pause claims", function()
		local actions, calls = fresh_actions()
		with_feature_lifecycles(actions, calls, function(Shortcuts, Gestures, feature)
			helpers.assert_eq(Shortcuts.start(), true)
			helpers.assert_eq(Gestures.enable_all(), true)
			helpers.assert_eq(feature.bindings_started, true)
			helpers.assert_eq(feature.keyboard_started, true)

			-- `feature_toggle` fences only static/configurable shortcuts. Gesture
			-- actions must still cross every formerly shared owner non-vacuously.
			helpers.assert_eq(Shortcuts.pause_bindings("feature_toggle"), true)
			helpers.assert_eq(feature.bindings_started, false)
			helpers.assert_eq(feature.keyboard_started, false)
			helpers.assert_eq(feature.keyboard_execute("open_config"), false)
			helpers.assert_eq(actions.execute_single("select_line"), true)
			helpers.assert_eq(actions.execute_single("teleport_mouse"), true)
			helpers.assert_eq(actions.execute_single("spotlight_mouse"), true)
			helpers.assert_eq(actions.execute_single(
				"screenshot_region_clipboard"), true)
			helpers.assert_eq(calls.text_actions[#calls.text_actions].parent, "gestures")
			helpers.assert_eq(calls.mouse_actions[#calls.mouse_actions].parent, "gestures")

			-- Reverse the feature split. Static screenshot and a configurable SG
			-- shortcut remain live while direct gesture dispatch is fenced.
			helpers.assert_eq(Shortcuts.resume_bindings("feature_toggle"), true)
			helpers.assert_eq(Gestures.disable_all(), true)
			helpers.assert_eq(feature.static_screenshot(), true)
			helpers.assert_eq(feature.keyboard_execute("open_config"), true)
			helpers.assert_eq(calls.open[#calls.open].parent, "shortcut_bindings")
			helpers.assert_eq(actions.execute_single("open_config"), false)

			-- The global ScriptControl claim joins both ON scopes. Feature changes
			-- made behind that fence survive its release: neither OFF feature is
			-- reopened by the global resume transaction.
			helpers.assert_eq(Gestures.enable_all(), true)
			helpers.assert_eq(Shortcuts.pause_bindings("script_control"), true)
			helpers.assert_eq(Gestures.suspend(), true)
			helpers.assert_eq(feature.static_screenshot(), false)
			helpers.assert_eq(feature.keyboard_execute("open_config"), false)
			helpers.assert_eq(actions.execute_single("open_config"), false)

			helpers.assert_eq(Shortcuts.pause_bindings("feature_toggle"), true)
			helpers.assert_eq(Gestures.disable_all(), true)
			helpers.assert_eq(Shortcuts.resume_bindings("script_control"), true)
			helpers.assert_eq(Gestures.resume(), true)
			helpers.assert_eq(feature.bindings_started, false)
			helpers.assert_eq(feature.keyboard_started, false)
			helpers.assert_eq(actions.execute_single("open_config"), false)

			helpers.assert_eq(Shortcuts.resume_bindings("feature_toggle"), true)
			helpers.assert_eq(feature.static_screenshot(), true)
			helpers.assert_eq(feature.keyboard_execute("open_config"), true)
			helpers.assert_eq(actions.execute_single("open_config"), false,
				"gesture OFF intent must survive global resume and shortcut reopen")
			helpers.assert_eq(Gestures.enable_all(), true)
			helpers.assert_eq(actions.execute_single("open_config"), true)
		end)
	end)
end)

helpers.describe("gesture Actions search acquisition epoch", function()
	for _, boundary in ipairs({ "clear", "timer", "emit" }) do
		helpers.it("fences search when " .. boundary .. " reenters cleanup", function()
			local actions, calls = fresh_actions({ search_reenter = boundary })
			actions.init({ action_params = {} })
			helpers.assert_eq(actions.set_action_parameter(
				"tap_3", "search_web", "https://example.test/?q=%s"), true)
			helpers.assert_eq(actions.execute_single("search_web", "tap_3"), false)
			helpers.assert_eq(calls.clipboard_text(), "original",
				"cleanup must restore the exact clipboard snapshot after " .. boundary)
			if boundary == "timer" then
				helpers.assert_eq(calls.search_cleanup_results, { true },
					"timer construction has no native mutation outstanding")
			else
				helpers.assert_eq(calls.search_cleanup_results, { false },
					"clipboard mutation boundaries must remain pending until return")
			end
			if boundary ~= "emit" then
				helpers.assert_eq(#calls.keys, 0,
					"no copy key may cross an earlier lifecycle fence")
			end
			for _, timer in ipairs(calls.hs.timer.__timers or {}) do
				if timer.running then timer:fire() end
			end
			helpers.assert_eq(#calls.opened_urls, 0,
				"a stale search callback may never publish a URL")
			helpers.assert_eq(actions.force_cleanup("gestures"), true)
		end)
	end

	helpers.it("keeps clipboard restore visible until its native boundary returns", function()
		local actions, calls = fresh_actions({ search_reenter = "restore" })
		actions.init({ action_params = {} })
		helpers.assert_eq(actions.set_action_parameter(
			"tap_3", "search_web", "https://example.test/?q=%s"), true)
		helpers.assert_eq(actions.execute_single("search_web", "tap_3"), true)
		helpers.assert_eq(calls.clipboard_text(), "selected words")
		calls.hs.timer.__timers[1]:fire()
		helpers.assert_eq(calls.search_cleanup_results, { false })
		helpers.assert_eq(calls.clipboard_text(), "original")
		helpers.assert_eq(#calls.opened_urls, 0)
		helpers.assert_eq(actions.force_cleanup("gestures"), true)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains restore-boundary debt after inverse " .. mode, function()
			local controls = {
				search_reenter = "restore",
				search_restore_mode = mode,
			}
			local actions, calls = fresh_actions(controls)
			actions.init({ action_params = {} })
			helpers.assert_eq(actions.set_action_parameter(
				"tap_3", "search_web", "https://example.test/?q=%s"), true)
			helpers.assert_eq(actions.execute_single("search_web", "tap_3"), true)
			calls.hs.timer.__timers[1]:fire()
			helpers.assert_eq(calls.search_cleanup_results, { false })
			helpers.assert_eq(calls.clipboard_text(), "selected words")
			local restore_calls = calls.clipboard_restore_calls
			helpers.assert_eq(actions.force_cleanup("shortcut_bindings"), true)
			helpers.assert_eq(calls.clipboard_restore_calls, restore_calls)
			controls.search_restore_mode = nil
			helpers.assert_eq(actions.force_cleanup("gestures"), true)
			helpers.assert_eq(calls.clipboard_text(), "original")
			helpers.assert_eq(#calls.opened_urls, 0)
		end)
	end

	for _, boundary in ipairs({ "clear", "emit" }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("retains exact " .. boundary .. " clipboard debt when restore "
				.. mode, function()
				local controls = {
					search_reenter = boundary,
					search_restore_mode = mode,
				}
				local actions, calls = fresh_actions(controls)
				actions.init({ action_params = {} })
				helpers.assert_eq(actions.set_action_parameter(
					"tap_3", "search_web", "https://example.test/?q=%s"), true)
				helpers.assert_eq(actions.execute_single("search_web", "tap_3"), false)
				helpers.assert_eq(calls.search_cleanup_results, { false },
					"re-entrant cleanup may not claim settlement before mutation returns")
				helpers.assert_eq(calls.clipboard_text(),
					boundary == "emit" and "selected words" or nil,
					"a refused restore must leave the exact native mutation observable")

				helpers.assert_eq(actions.force_cleanup("shortcut_bindings"), true,
					"a sibling parent may not consume gesture clipboard recovery debt")
				helpers.assert_eq(calls.clipboard_text(),
					boundary == "emit" and "selected words" or nil)

				controls.search_restore_mode = nil
				helpers.assert_eq(actions.force_cleanup("gestures"), true,
					"the matching parent must retry the retained snapshot exactly")
				helpers.assert_eq(calls.clipboard_text(), "original")
				for _, timer in ipairs(calls.hs.timer.__timers or {}) do
					if timer.running then timer:fire() end
				end
				helpers.assert_eq(#calls.opened_urls, 0,
					"a stale capture/recovery callback may never publish a URL")
			end)
		end
	end

	helpers.it("does not let a shortcut sibling consume gesture clipboard recovery debt", function()
		local controls = {
			search_reenter = "emit",
			search_restore_mode = "false",
		}
		local actions, calls = fresh_actions(controls)
		actions.init({ action_params = {} })
		helpers.assert_eq(actions.set_action_parameter(
			"tap_3", "search_web", "https://example.test/?q=%s"), true)
		helpers.assert_eq(actions.set_action_parameter(
			"keyboard__cmd_1", "search_web", "https://example.test/?q=%s"), true)
		helpers.assert_eq(actions.execute_single("search_web", "tap_3"), false)
		local restore_calls = calls.clipboard_restore_calls
		helpers.assert_eq(calls.clipboard_text(), "selected words")

		controls.search_restore_mode = nil
		helpers.assert_eq(actions.execute_single(
			"search_web", "keyboard__cmd_1"), true,
			"the registered sibling action remains owned when foreign debt refuses its work")
		helpers.assert_eq(calls.clipboard_restore_calls, restore_calls,
			"a sibling action may observe but never settle foreign recovery debt")
		helpers.assert_eq(calls.clipboard_text(), "selected words")
		helpers.assert_eq(actions.force_cleanup("gestures"), true)
		helpers.assert_eq(calls.clipboard_restore_calls, restore_calls + 1)
		helpers.assert_eq(calls.clipboard_text(), "original")
	end)
end)


helpers.describe("gesture Actions lookup transaction", function()
	for _, case in ipairs({
		{ binding = "tap_3", parent = "gestures", sibling = "shortcut_bindings" },
		{ binding = "keyboard__cmd_1", parent = "shortcut_bindings", sibling = "gestures" },
	}) do
		helpers.it("normalizes lookup binding provenance to " .. case.parent, function()
			local actions, calls = fresh_actions()
			helpers.assert_eq(actions.execute_single("lookup", case.binding), true)
			helpers.assert_eq(calls.after[1].parent, case.parent)
			helpers.assert_eq(actions.force_cleanup(case.sibling), true)
			helpers.assert_eq(calls.fire(calls.after[1].token), true,
				"a sibling lifecycle must not consume the lookup timer")

			local actions2, calls2 = fresh_actions()
			helpers.assert_eq(actions2.execute_single("lookup", case.binding), true)
			helpers.assert_eq(actions2.force_cleanup(case.parent), true)
			helpers.assert_eq(calls2.fire(calls2.after[1].token), false,
				"the matching feature parent must join the lookup timer")
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("does not click when timer acquisition returns " .. mode, function()
			local actions, calls = fresh_actions({ prepare_mode = mode })
			helpers.assert_eq(actions.trigger_lookup(), false)
			helpers.assert_eq(#calls.mouse_posts, 0)
			helpers.assert_eq(#calls.keys, 0)
		end)

		helpers.it("rolls back the timer when mouse position read returns " .. mode, function()
			local actions, calls = fresh_actions({ mouse_read_mode = mode })
			helpers.assert_eq(actions.trigger_lookup(), false)
			helpers.assert_eq(calls.rollback, 1)
			helpers.assert_eq(#calls.mouse_posts, 0)
			helpers.assert_eq(calls.fire(calls.after[1].token), false)
			helpers.assert_eq(#calls.keys, 0)
		end)

		for _, boundary in ipairs({ "down_construct", "up_construct", "down_post", "up_post" }) do
			helpers.it("rolls back the timer when " .. boundary .. " returns " .. mode, function()
				local actions, calls = fresh_actions({ [boundary .. "_mode"] = mode })
				helpers.assert_eq(actions.trigger_lookup(), false)
				helpers.assert_eq(calls.rollback, 1)
				helpers.assert_eq(calls.fire(calls.after[1].token), false,
					"a rolled-back lookup timer must remain permanently inert")
				helpers.assert_eq(#calls.keys, 0)
			end)
		end
	end

	helpers.it("retains PAUSE when position read reenters the lifecycle", function()
		local actions, calls = fresh_actions({ pause_on_mouse_read = true })
		helpers.assert_eq(actions.trigger_lookup(), false)
		helpers.assert_eq(calls.aux_is_paused(), true)
		helpers.assert_eq(calls.rollback, 1)
		helpers.assert_eq(#calls.mouse_posts, 0)
	end)

	helpers.it("posts only cleanup mouse-up work when mouse-down reenters PAUSE", function()
		local actions, calls = fresh_actions({ pause_on_post = 1 })
		helpers.assert_eq(actions.trigger_lookup(), false)
		helpers.assert_eq(calls.lookup_cleanup_results, { false },
			"the real composite PAUSE cannot settle inside mouse-down post")
		helpers.assert_eq(calls.aux_is_paused(), true)
		helpers.assert_eq(calls.mouse_posts, { 1, 2 })
		helpers.assert_eq(calls.rollback, 1)
		helpers.assert_eq(#calls.keys, 0)
		helpers.assert_eq(actions.force_cleanup("gestures"), true)
	end)

	for _, parent in ipairs({ "gestures", "shortcut_bindings" }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("retains " .. parent .. " lookup mouse-up debt after " .. mode,
				function()
					local sibling = parent == "gestures"
						and "shortcut_bindings" or "gestures"
					local actions, calls = fresh_actions({
						pause_on_post = 1,
						pause_parent = parent,
						up_post_mode = mode,
					})
					helpers.assert_eq(actions.trigger_lookup(parent), false)
					helpers.assert_eq(calls.lookup_cleanup_results, { false })
					helpers.assert_eq(#calls.mouse_post_attempts, 2,
						"the failed emergency mouse-up must be attempted once")
					local exact_up = calls.mouse_post_attempts[2]
					helpers.assert_eq(actions.force_cleanup(sibling), true,
						"a sibling PAUSE cannot consume foreign release debt")
					helpers.assert_eq(#calls.mouse_post_attempts, 2)
					helpers.assert_eq(actions.force_cleanup(parent), false)
					helpers.assert_eq(calls.mouse_post_attempts[3] == exact_up, true,
						"matching retry must retain the exact mouse-up identity")
					calls.controls.up_post_mode = "success"
					helpers.assert_eq(actions.force_cleanup(parent), true)
					helpers.assert_eq(calls.mouse_post_attempts[4] == exact_up, true)
					helpers.assert_eq(calls.mouse_posts, { 1, 2 })
					helpers.assert_eq(calls.fire(calls.after[1].token), false)
					helpers.assert_eq(#calls.keys, 0)
				end)
		end
	end
end)


helpers.describe("gesture Actions save/reload transaction", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("posts no save when reload timer acquisition returns " .. mode, function()
			local actions, calls = fresh_actions({ prepare_mode = mode })
			helpers.assert_eq(actions.execute_single("script_save_reload"), true,
				"the registered save action remains owned after its continuation refuses")
			helpers.assert_eq(#calls.keys, 0,
				"save must not post unless its exact reload continuation is already owned")
			helpers.assert_eq(calls.reload, 0)
		end)

		helpers.it("rolls back reload when save dispatch returns " .. mode, function()
			local actions, calls = fresh_actions({ key_post_mode = mode })
			helpers.assert_eq(actions.execute_single("script_save_reload"), true,
				"the registered save action remains owned after its native dispatch refuses")
			helpers.assert_eq(calls.rollback, 1)
			helpers.assert_eq(#calls.keys, 0)
			helpers.assert_eq(calls.fire(calls.after[1].token), false)
			helpers.assert_eq(calls.reload, 0)
		end)
	end

	helpers.it("commits reload only after save dispatch succeeds", function()
		local actions, calls = fresh_actions()
		helpers.assert_eq(actions.execute_single("script_save_reload"), true)
		helpers.assert_eq(#calls.keys, 1)
		helpers.assert_eq(calls.keys[1].key, "s")
		helpers.assert_eq(calls.reload, 0)
		helpers.assert_eq(calls.fire(calls.after[1].token), true)
		helpers.assert_eq(calls.reload, 1)
	end)
end)


helpers.describe("gesture Actions dispatch fences", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("refuses the action when held-click release returns " .. mode, function()
			local actions, calls = fresh_actions({ release_mode = mode })
			helpers.assert_eq(actions.execute_single("mission_control"), false)
			helpers.assert_eq(#calls.keys, 0)
		end)
	end

	helpers.it("revalidates PAUSE after held-click release before dispatch", function()
		local actions, calls = fresh_actions({ pause_on_release = true })
		helpers.assert_eq(actions.execute_single("mission_control"), false)
		helpers.assert_eq(calls.aux_is_paused(), true)
		helpers.assert_eq(#calls.keys, 0)
	end)

	helpers.it("keeps only dedicated script-control lifecycle actions live behind PAUSE", function()
		local actions, calls = fresh_actions()
		helpers.assert_eq(actions.force_cleanup("gestures"), true)
		helpers.assert_eq(actions.execute_single(
			"open_config", "script__escape"), false,
			"an arbitrary action assigned to the dedicated tap remains fenced")
		helpers.assert_eq(actions.execute_single(
			"script_reload", "script__backspace"), true)
		helpers.assert_eq(calls.reload, 1)
		helpers.assert_eq(actions.execute_single(
			"script_quit", "script__escape"), true)
	end)
end)


helpers.describe("gesture Actions composite resume", function()
	for _, child in ipairs({ "text", "mouse", "screenshot" }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("keeps aggregate admission closed during " .. child
				.. " resume " .. mode, function()
				local options = { reenter_during_resume = child }
				options[child .. "_resume_mode"] = mode
				local actions, calls = fresh_actions(options)
				helpers.assert_eq(actions.force_cleanup("gestures"), true)
				helpers.assert_eq(actions.resume_after_cleanup("gestures"), false)
				helpers.assert_eq(calls.reentrant_results, { false },
					"a child resume callback must observe the composite fence")
				helpers.assert_eq(#calls.open, 0,
					"Aux side effects may not escape before every child commits")
				helpers.assert_eq(calls.aux_is_paused("gestures"), true)
				helpers.assert_eq(calls.text_is_paused("gestures"), true)
				helpers.assert_eq(calls.mouse_is_paused("gestures"), true)
				helpers.assert_eq(calls.screenshot_is_paused("gestures"), true)
			end)
		end
	end

	for _, child in ipairs({ "text", "mouse", "screenshot" }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("retains the composite fence when " .. child
				.. " rollback pause returns " .. mode, function()
				local options = {
					rollback_pause_kind = child,
					rollback_pause_mode = mode,
				}
				options[child .. "_resume_mode"] = "false"
				options[child .. "_resume_mutates"] = true
				local actions, calls = fresh_actions(options)
				helpers.assert_eq(actions.force_cleanup("gestures"), true)
				helpers.assert_eq(actions.resume_after_cleanup("gestures"), false)
				helpers.assert_eq(actions.execute_single("open_config"), false)
				helpers.assert_eq(#calls.open, 0)
				local paused
				if child == "text" then
					paused = calls.text_is_paused("gestures")
				elseif child == "mouse" then
					paused = calls.mouse_is_paused("gestures")
				else
					paused = calls.screenshot_is_paused("gestures")
				end
				helpers.assert_eq(paused, false,
					"the mutated child must remain observable as exact rollback debt")
				helpers.assert_eq(actions.force_cleanup("gestures"), false,
					"matching cleanup must retry rather than hide the refused inverse")
				calls.controls.rollback_pause_mode = "success"
				helpers.assert_eq(actions.force_cleanup("gestures"), true)
				calls.controls[child .. "_resume_mode"] = "success"
				calls.controls[child .. "_resume_mutates"] = false
				helpers.assert_eq(actions.resume_after_cleanup("gestures"), true)
				helpers.assert_eq(actions.execute_single("open_config"), true)
			end)
		end
	end

	for _, phase in ipairs({ "cleanup", "resume" }) do
		for _, owner in ipairs({ "aux", "text", "mouse", "screenshot" }) do
			for _, edge in ipairs({ "paused", "pending" }) do
				for _, mode in ipairs({ "nil", "throw" }) do
					helpers.it("fails closed on " .. phase .. " " .. owner .. " "
						.. edge .. " query " .. mode, function()
						local options = {}
						options[owner .. "_" .. edge .. "_query_mode"] = mode
						if phase == "resume" then options.query_fault_phase = "resume" end
						local actions, calls = fresh_actions(options)
						if phase == "resume" then
							helpers.assert_eq(actions.force_cleanup("gestures"), true)
							helpers.assert_eq(actions.resume_after_cleanup("gestures"), false)
						else
							helpers.assert_eq(actions.force_cleanup("gestures"), false)
						end
						helpers.assert_eq(actions.execute_single("open_config"), false)
						helpers.assert_eq(#calls.open, 0,
							"an ambiguous query may never open aggregate admission")
						helpers.assert_true(calls.pause > 0)
						helpers.assert_true(#calls.text_lifecycle > 0)
						helpers.assert_true(#calls.mouse_lifecycle > 0)
						helpers.assert_true(#calls.screenshot_pause > 0,
							"cleanup must continue through every sibling owner")

						calls.controls[owner .. "_" .. edge .. "_query_mode"] = nil
						calls.controls.query_fault_phase = nil
						helpers.assert_eq(actions.force_cleanup("gestures"), true)
						helpers.assert_eq(actions.resume_after_cleanup("gestures"), true)
						helpers.assert_eq(actions.execute_single("open_config"), true)
					end)
				end
			end
		end
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains composite debt when auxiliary rollback pause returns " .. mode,
			function()
				local actions, calls = fresh_actions({
					rollback_pause_kind = "auxiliary",
					rollback_pause_mode = mode,
					text_resume_mode = "false",
					text_resume_mutates = true,
				})
				helpers.assert_eq(actions.force_cleanup("gestures"), true)
				helpers.assert_eq(actions.resume_after_cleanup("gestures"), false)
				helpers.assert_eq(calls.aux_is_paused("gestures"), false,
					"the opened Aux child remains observable behind the composite fence")
				helpers.assert_eq(actions.execute_single("open_config"), false)
				helpers.assert_eq(#calls.open, 0)
				helpers.assert_eq(actions.force_cleanup("gestures"), false,
					"matching cleanup retries the exact refused Aux inverse")
				calls.controls.rollback_pause_mode = "success"
				helpers.assert_eq(actions.force_cleanup("gestures"), true)
				calls.controls.text_resume_mode = "success"
				calls.controls.text_resume_mutates = false
				helpers.assert_eq(actions.resume_after_cleanup("gestures"), true)
				helpers.assert_eq(actions.execute_single("open_config"), true)
			end)
	end

	helpers.it("passes the exact parent through every composite owner and query", function()
		local actions, calls = fresh_actions()
		helpers.assert_eq(actions.force_cleanup("shortcut_bindings"), true)
		helpers.assert_eq(actions.resume_after_cleanup("shortcut_bindings"), true)
		helpers.assert_eq(actions.execute_single(
			"open_config", "keyboard__cmd_1"), true)

		helpers.assert_true(#calls.click_force_parents > 0)
		helpers.assert_true(#calls.click_release_parents > 0)
		helpers.assert_true(#calls.sticky_clear_parents > 0)
		for _, parent in ipairs(calls.click_force_parents) do
			helpers.assert_eq(parent, "shortcut_bindings")
		end
		for _, parent in ipairs(calls.click_release_parents) do
			helpers.assert_eq(parent, "shortcut_bindings")
		end
		for _, parent in ipairs(calls.sticky_clear_parents) do
			helpers.assert_eq(parent, "shortcut_bindings")
		end
		for _, calls_for_owner in ipairs({
			calls.text_lifecycle, calls.mouse_lifecycle,
			calls.aux_queries, calls.text_queries,
			calls.mouse_queries, calls.screenshot_queries,
		}) do
			helpers.assert_true(#calls_for_owner > 0,
				"each shared lifecycle/query recorder must be exercised")
			for _, call in ipairs(calls_for_owner) do
				helpers.assert_eq(call.parent, "shortcut_bindings",
					"omitting or substituting the owner parent must fail this recorder")
			end
		end
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("compensates auxiliary resume when screenshot resume returns " .. mode, function()
			local actions, calls = fresh_actions({ screenshot_resume_mode = mode })
			helpers.assert_eq(actions.force_cleanup(), true)
			helpers.assert_eq(calls.aux_is_paused(), true)
			helpers.assert_eq(actions.resume_after_cleanup(), false)
			helpers.assert_eq(calls.resume, 1)
			helpers.assert_eq(calls.pause, 3,
				"preflight cleanup and reverse compensation must both retain ownership")
			helpers.assert_eq(calls.screenshot_pause,
				{ "gestures", "gestures", "gestures" },
				"the screenshot claim must also be restored after a hostile resume refusal")
			helpers.assert_eq(calls.aux_is_paused(), true)
			helpers.assert_eq(actions.execute_single("open_config"), false)
			helpers.assert_eq(#calls.open, 0)
		end)
	end

	helpers.it("rolls both owners back when screenshot resume reenters auxiliary PAUSE", function()
		local actions, calls = fresh_actions({ pause_during_screenshot_resume = true })
		helpers.assert_eq(actions.force_cleanup(), true)
		helpers.assert_eq(actions.resume_after_cleanup(), false)
		helpers.assert_eq(calls.aux_is_paused(), true)
		helpers.assert_eq(calls.pause, 3)
		helpers.assert_eq(calls.screenshot_pause,
			{ "gestures", "gestures", "gestures" })
	end)
end)
