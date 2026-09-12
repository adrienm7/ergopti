--- tests/support/gesture_actions_fixture.lua

--- ==============================================================================
--- MODULE: Gesture Actions Fixture
--- DESCRIPTION:
--- Owns native doubles, direct injections and real transitive consumers across
--- construction, feature lifecycles and assertion failures.
--- ==============================================================================

local helpers = require("tests.helpers")
local M = {}
local OWNERS = {
	"_generated.gesture_emit_actions",
	"adapters.file_system",
	"adapters.hotkey_registrar",
	"adapters.key_state",
	"adapters.synthetic_input",
	"adapters.timer_scheduler",
	"infra.i18n",
	"infra.logger",
	"infra.manifest_reader",
	"infra.notifications",
	"infra.paths",
	"infra.startup_transaction",
	"infra.termination_coordinator",
	"infra.text_utils",
	"infra.timings",
	"infra.toml.reader",
	"modules.gestures",
	"modules.gestures.actions",
	"modules.gestures.actions_aux_owner",
	"modules.gestures.actions_click",
	"modules.gestures.conflicts",
	"modules.gestures.engine",
	"modules.gestures.sticky_modifiers",
	"modules.shortcuts",
	"modules.shortcuts.actions.screenshot_save",
	"modules.shortcuts.actions.system_mouse",
	"modules.shortcuts.actions.text",
	"modules.shortcuts.bindings",
	"modules.shortcuts.keyboard_shortcuts",
	"modules.shortcuts.script_control",
	"text_utils",
	"toml_codec.basic_string",
	"toml_codec.bom",
	"toml_codec.reader",
}

local function fresh_actions(options)
	local controls = options or {}
	for _, name in ipairs({
		"modules.gestures.actions",
		"infra.notifications",
		"adapters.timer_scheduler",
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
		system_key_posts = {},
		window_actions = {},
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
		errors = {},
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
			if controls.aux_pause_on_query == #calls.aux_queries then
				aux_paused[parent or "gestures"] = true
			end
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
		prepare_mouse_event = function(_, event_type, position)
			local event = _G.hs.eventtap.event.newMouseEvent(event_type, position)
			if event == nil or event == false then return nil, "constructor refused" end
			return { event = event, active = true, attempted = false }
		end,
		prepare_mouse_cleanup_event = function(_, event_type, position)
			local event = _G.hs.eventtap.event.newMouseEvent(event_type, position)
			if event == nil or event == false then return nil, "constructor refused" end
			return { event = event, active = true, attempted = false }
		end,
		post_mouse_event = function(owner)
			if type(owner) ~= "table" or owner.active ~= true then return false end
			owner.attempted = true
			local result = owner.event:post()
			if result == nil or result == false then return false end
			owner.active = false
			return true
		end,
		discard_mouse_event = function(owner)
			if type(owner) ~= "table" or owner.active ~= true or owner.attempted == true then
				return false
			end
			owner.active = false
			return true
		end,
		prepare_mouse_handoff = function(owners)
			local events = {}
			for index, owner in ipairs(owners) do
				if type(owner) ~= "table" or owner.active ~= true
					or owner.attempted == true then return nil, "unavailable" end
				events[index] = owner.event
			end
			return { owners = owners, events = events }
		end,
		commit_mouse_handoff = function(handoff)
			for _, owner in ipairs(handoff.owners) do owner.active = false end
			return handoff.events
		end,
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
	local logger = helpers.make_logger_stub()
	logger.error = function(module_name, message, ...)
		local ok, rendered = pcall(string.format, message, ...)
		calls.errors[#calls.errors + 1] = {
			module_name = module_name,
			message = ok and rendered or tostring(message),
		}
	end
	package.loaded["infra.logger"] = logger
	package.loaded["infra.i18n"] = { get = function(key) return key end }

	local event_types = { rightMouseDown = 1, rightMouseUp = 2 }
	local focused_window = {
		moveToUnit = function(_, unit)
			calls.window_actions[#calls.window_actions + 1] = { name = "move", unit = unit }
			return controlled_result(controls.window_action_mode, "window move exploded")
		end,
		maximize = function()
			calls.window_actions[#calls.window_actions + 1] = { name = "maximize" }
			return controlled_result(controls.window_action_mode, "window maximize exploded")
		end,
	}
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
				newSystemKeyEvent = function(key, is_down)
					return {
						post = function()
							calls.system_key_posts[#calls.system_key_posts + 1] = {
								key = key, is_down = is_down,
							}
							return controlled_result(
								controls.system_key_post_mode, "system key post exploded")
						end,
					}
				end,
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
		layout = {
			left50 = "left50",
			right50 = "right50",
		},
		window = {
			focusedWindow = function() return focused_window end,
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
		cancel_calls = 0,
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
		cancel_current_gesture = function()
			feature.cancel_calls = feature.cancel_calls + 1
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


--- Runs a complete scenario while its constructors and native state are owned.
--- @param callback function Receives fresh_actions and with_feature_lifecycles.
--- @return ... Callback results, preserving nil slots.
function M.with_fixture(callback)
	assert(type(callback) == "function", "gesture fixture callback must be a function")
	return helpers.with_stub_scope(OWNERS, function()
		local active = true
		local function owned(fn)
			return function(...)
				assert(active, "gesture fixture is no longer active")
				return fn(...)
			end
		end
		local result = table.pack(xpcall(callback, debug.traceback,
			owned(fresh_actions), owned(with_feature_lifecycles)))
		active = false
		if not result[1] then error(result[2], 0) end
		return table.unpack(result, 2, result.n)
	end)
end

--- Registers a scenario whose entire execution is owned by this fixture.
--- @param name string Test case name.
--- @param callback function Receives the scoped fixture constructors.
function M.it(name, callback)
	helpers.it(name, function()
		M.with_fixture(callback)
	end)
end

return M
