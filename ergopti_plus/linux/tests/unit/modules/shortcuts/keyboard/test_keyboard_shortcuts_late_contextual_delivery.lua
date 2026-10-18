--- tests/unit/modules/shortcuts/keyboard/test_keyboard_shortcuts_late_contextual_delivery.lua

--- ==============================================================================
--- MODULE: The User\'s Own Modifier Chords
--- DESCRIPTION:
--- Configurable keyboard shortcuts on Linux: which chord matches which slot,
--- what survives a restart, and what the metrics record.
---
--- WHAT WAS MISSING:
--- `keyboard_slots` is a manifest row restricted to Windows and macOS, and the
--- reason written beside it was accurate: this driver had no chord capture and
--- nowhere to store an assignment. The hook reported every modified keystroke as
--- the bare string "shortcut" — enough to tell the engine the caret had moved,
--- and not enough to say WHICH shortcut. So there was nothing to match, and
--- `keylogger.record_shortcut` had no caller for the same reason: every action
--- that types no text was absent from the metrics.
---
--- THE MATCHING RULE THAT MATTERS:
--- A slot requires its modifiers EXACTLY, not at least. Ctrl+Shift+P is not
--- Ctrl+P with something extra held — matching a subset would make the first
--- binding a user creates swallow every longer chord that starts the same way,
--- and the symptom would be a shortcut that works until they add another one.
---
--- AltGr is excluded from the comparison on purpose. It selects a layout level
--- rather than forming a chord: on a French layout the user holds it to type
--- "@", and a shortcut that fired on that would be unusable.
--- ==============================================================================

package.loaded["tests.support.modules.shortcuts.keyboard.keyboard_shortcuts_fixture"] = nil
local Fixture = require("tests.support.modules.shortcuts.keyboard.keyboard_shortcuts_fixture")
local helpers, Sandbox, load_over_config, drop_config, chord =
	Fixture.helpers, Fixture.Sandbox, Fixture.load_over_config, Fixture.drop_config, Fixture.chord




helpers.describe("keyboard shortcuts: late contextual delivery custody", function()
	local function with_editor(initial, body, writes_fail)
		local saved_source = package.loaded["modules.hotstrings.magic_key_source"]
		local saved_magic = package.loaded["modules.hotstrings.magic_key"]
		local saved_builder = package.loaded["ui.menu.menu_builder"]
		local gestures = require("modules.gestures.manager")
		local saved_execute = gestures.execute_action
		local state = { trigger = "★", generation = 1, master = true, paused = false, inhibited = false,
			rows = { { code = "KeyJ", native_code = 36, identity = "evdev:36", text = "★", native_text = "j", direct = true, dead = false } },
			queue = {}, fired = {} }
		package.loaded["modules.hotstrings.magic_key_source"] = {
			editor_source = function() return { generation = state.generation, status = "ready", candidates = state.rows } end,
			known_codes = function() return { KeyJ = true, KeyC = true, Quote = true, Semicolon = true } end,
		}
		package.loaded["modules.hotstrings.magic_key"] = { get = function() return state.trigger end, is_customised = function() return false end }
		gestures.execute_action = function(action, binding) state.fired[#state.fired + 1] = { action, binding } return true end
		local ok, err = pcall(function()
			local shortcuts, config = load_over_config(initial, writes_fail)
			state.options = {
				defer = function(callback) state.queue[#state.queue + 1] = callback return true end,
				admission = function() return { master = state.master, paused = state.paused, inhibited = state.inhibited } end,
			}
			state.detail = { key = "j", code = 36, physical = true, mods = { meta = true } }
			body(shortcuts, config, state)
		end)
		gestures.execute_action = saved_execute
		package.loaded["modules.hotstrings.magic_key_source"] = saved_source
		package.loaded["modules.hotstrings.magic_key"] = saved_magic
		package.loaded["ui.menu.menu_builder"] = saved_builder
		drop_config()
		if not ok then error(err, 0) end
	end

	local function with_actual_logger(body)
		local saved_core, saved_shim = package.loaded["logger"], package.loaded["logger.shim"]
		package.loaded["logger"], package.loaded["logger.shim"] = nil, nil
		local logger = require("logger.shim")
		local ok, err = pcall(function()
			logger.set_level("debug")
			body(logger)
		end)
		logger.set_sink(nil)
		package.loaded["logger"], package.loaded["logger.shim"] = saved_core, saved_shim
		if not ok then error(err, 0) end
	end

	helpers.it("(contextual-late-custody) preserves actual logger callback and unchanged editor action", function()
		with_actual_logger(function(logger)
			with_editor(nil, function(shortcuts, _, state)
				local observed = 0
				logger.set_sink(function(line)
					if line:find("Keyboard shortcut fired:", 1, true) then observed = observed + 1 end
				end)
				helpers.assert_true(shortcuts.consume(state.detail, state.options))
				state.queue[1]()
				helpers.assert_eq(observed, 1, "The real configured logger sink must run before the executor")
				helpers.assert_eq(state.fired, { { "open_hotstrings_editor", "keyboard__magic_editor" } })
			end)
		end)
	end)

	for _, gate in ipairs({ "master", "paused", "inhibited", "source", "rebind", "owner" }) do
		helpers.it("(contextual-late-custody) refuses original queued action after logger changes " .. gate, function()
			with_actual_logger(function(logger)
				with_editor(nil, function(shortcuts, _, state)
					local observed = 0
					logger.set_sink(function(line)
						if not line:find("Keyboard shortcut fired:", 1, true) then return end
						observed = observed + 1
						if gate == "master" then state.master = false
						elseif gate == "paused" then state.paused = true
						elseif gate == "inhibited" then state.inhibited = true
						elseif gate == "source" then state.generation = state.generation + 1
						elseif gate == "rebind" then helpers.assert_true(shortcuts.set_action("magic_editor", "enter"))
						else
							local token = {}
							helpers.assert_true(shortcuts.acquire_configuration(token))
							helpers.assert_true(shortcuts.release_configuration(token))
						end
					end)
					helpers.assert_true(shortcuts.consume(state.detail, state.options))
					helpers.assert_eq(state.fired, {}, "The original physical-source decision has not executed inside capture")
					state.queue[1]()
					helpers.assert_eq(observed, 1, "Cancellation must observe the real logger callback, not remove logging")
					helpers.assert_eq(state.fired, {}, "An action captured before a changed live owner must not escape after logging")
				end)
			end)
		end)
	end

	for _, gate in ipairs({ "master", "paused", "inhibited" }) do
		helpers.it("(contextual-late-custody) rereads live " .. gate .. " after source callback reentry", function()
			with_actual_logger(function(logger)
				with_editor(nil, function(shortcuts, _, state)
					local source = require("modules.hotstrings.magic_key_source")
					local original = source.editor_source
					local armed, observed = false, 0
					logger.set_sink(function(line)
						if line:find("Keyboard shortcut fired:", 1, true) then armed = true end
					end)
					source.editor_source = function()
						local facts = original()
						if armed then
							armed, observed = false, observed + 1
							if gate == "master" then state.master = false
							elseif gate == "paused" then state.paused = true
							else state.inhibited = true end
						end
						return facts
					end
					helpers.assert_true(shortcuts.consume(state.detail, state.options))
					state.queue[1]()
					helpers.assert_eq(observed, 1, "The same source getter callback runs after the logger boundary")
					helpers.assert_eq(state.generation, 1, "Changing admission alone does not change the native layout epoch")
					helpers.assert_eq(state.fired, {}, "The earlier admission snapshot cannot survive a live source callback")
				end)
			end)
		end)
	end

	for _, boundary in ipairs({ "admission", "source", "final admission" }) do
		helpers.it("(contextual-late-custody) closes configuration owner reentry in late " .. boundary, function()
			with_actual_logger(function(logger)
				with_editor(nil, function(shortcuts, _, state)
					local source = require("modules.hotstrings.magic_key_source")
					local original_admission, original_source = state.options.admission, source.editor_source
					local armed, observed, reads = false, 0, 0
					logger.set_sink(function(line)
						if line:find("Keyboard shortcut fired:", 1, true) then armed = true end
					end)
					local function retire()
						observed, armed = observed + 1, false
						local token = {}
						helpers.assert_true(shortcuts.acquire_configuration(token))
						helpers.assert_true(shortcuts.release_configuration(token))
					end
					state.options.admission = function()
						local facts = original_admission()
						if armed then
							reads = reads + 1
							if boundary == "admission" or (boundary == "final admission" and reads == 2) then retire() end
						end
						return facts
					end
					source.editor_source = function()
						local facts = original_source()
						if armed and boundary == "source" then retire() end
						return facts
					end
					helpers.assert_true(shortcuts.consume(state.detail, state.options))
					state.queue[1]()
					helpers.assert_eq(observed, 1, "The real original getter phase must observe one owner transition")
					helpers.assert_eq(state.fired, {}, "Closing and releasing ownership does not revive the queued decision")
				end)
			end)
		end)
	end

	helpers.it("(contextual-late-custody) refuses failed source callback after logging without invoking executor", function()
		with_actual_logger(function(logger)
			with_editor(nil, function(shortcuts, _, state)
				local source = require("modules.hotstrings.magic_key_source")
				local original = source.editor_source
				local armed, observed = false, 0
				logger.set_sink(function(line)
					if line:find("Keyboard shortcut fired:", 1, true) then armed = true end
				end)
				source.editor_source = function()
					if armed then observed = observed + 1; error("original selected-source callback unavailable") end
					return original()
				end
				helpers.assert_true(shortcuts.consume(state.detail, state.options))
				local completed, observed_failures, executed_actions = pcall(function()
					state.queue[1]()
					return observed, #state.fired
				end)
				helpers.assert_true(completed, "Unavailable source must close delivery rather than escape")
				helpers.assert_eq(observed_failures, 1, "The protected result must observe the actual failed source callback")
				helpers.assert_eq(executed_actions, 0, "The protected result must observe no executor call")
				helpers.assert_eq(observed, 1)
				helpers.assert_eq(state.fired, {})
			end)
		end)
	end)

	helpers.it("(contextual-late-custody) refuses source read after original admission retires configuration owner", function()
		with_actual_logger(function(logger)
			with_editor(nil, function(shortcuts, _, state)
				local source = require("modules.hotstrings.magic_key_source")
				local admission, original = state.options.admission, source.editor_source
				local armed, retired, observed, source_after_loss = false, false, 0, 0
				logger.set_sink(function(line)
					if line:find("Keyboard shortcut fired:", 1, true) then armed = true end
				end)
				state.options.admission = function()
					local facts = admission()
					if armed then
						armed, retired, observed = false, true, observed + 1
						local token = {}
						helpers.assert_true(shortcuts.acquire_configuration(token))
						helpers.assert_true(shortcuts.release_configuration(token))
					end
					return facts
				end
				source.editor_source = function()
					if retired then source_after_loss = source_after_loss + 1 end
					return original()
				end
				helpers.assert_true(shortcuts.consume(state.detail, state.options))
				state.queue[1]()
				helpers.assert_eq(observed, 1)
				helpers.assert_eq(source_after_loss, 0, "Known lost dispatch ownership closes before another source query")
				helpers.assert_eq(state.fired, {})
			end)
		end)
	end)

	for _, owner in ipairs({ "admission", "decision" }) do
		helpers.it("(contextual-late-custody) refuses a replacement " .. owner .. " owner after logger without invoking it", function()
			with_actual_logger(function(logger)
				with_editor(nil, function(shortcuts, _, state)
					local original = shortcuts.magic_editor_decision
					local captured = original(state.options.admission())
					local foreign_calls, observed = 0, 0
					logger.set_sink(function(line)
						if not line:find("Keyboard shortcut fired:", 1, true) then return end
						observed = observed + 1
						if owner == "admission" then
							state.options.admission = function()
								foreign_calls = foreign_calls + 1
								return { master = true, paused = false, inhibited = false }
							end
						else
							shortcuts.magic_editor_decision = function()
								foreign_calls = foreign_calls + 1
								return captured
							end
						end
					end)
					local ok, err = pcall(function()
						helpers.assert_true(shortcuts.consume(state.detail, state.options))
						state.queue[1]()
						helpers.assert_eq(observed, 1)
						helpers.assert_eq(foreign_calls, 0, "Replacement functions cannot issue the original queued decision")
						helpers.assert_eq(state.fired, {})
					end)
					shortcuts.magic_editor_decision = original
					if not ok then error(err, 0) end
				end)
			end)
		end)
	end

	helpers.it("(contextual-late-custody) refuses admission issuer replacement during original getter before source callback", function()
		with_actual_logger(function(logger)
			with_editor(nil, function(shortcuts, _, state)
				local source = require("modules.hotstrings.magic_key_source")
				local admission, original = state.options.admission, source.editor_source
				local armed, replaced, observed, source_after_loss, foreign_calls = false, false, 0, 0, 0
				logger.set_sink(function(line)
					if line:find("Keyboard shortcut fired:", 1, true) then armed = true end
				end)
				state.options.admission = function()
					local facts = admission()
					if armed then
						armed, replaced, observed = false, true, observed + 1
						state.options.admission = function()
							foreign_calls = foreign_calls + 1
							return { master = true, paused = false, inhibited = false }
						end
					end
					return facts
				end
				source.editor_source = function()
					if replaced then source_after_loss = source_after_loss + 1 end
					return original()
				end
				helpers.assert_true(shortcuts.consume(state.detail, state.options))
				state.queue[1]()
				helpers.assert_eq(observed, 1)
				helpers.assert_eq(source_after_loss, 0)
				helpers.assert_eq(foreign_calls, 0)
				helpers.assert_eq(state.fired, {})
			end)
		end)
	end)

	helpers.it("(contextual-late-custody) refuses final admission read after source retires dispatch owner", function()
		with_actual_logger(function(logger)
			with_editor(nil, function(shortcuts, _, state)
				local source = require("modules.hotstrings.magic_key_source")
				local admission, original = state.options.admission, source.editor_source
				local armed, retired, observed, admission_after_loss = false, false, 0, 0
				logger.set_sink(function(line)
					if line:find("Keyboard shortcut fired:", 1, true) then armed = true end
				end)
				state.options.admission = function()
					if retired then admission_after_loss = admission_after_loss + 1 end
					return admission()
				end
				source.editor_source = function()
					local facts = original()
					if armed then
						armed, retired, observed = false, true, observed + 1
						local token = {}
						helpers.assert_true(shortcuts.acquire_configuration(token))
						helpers.assert_true(shortcuts.release_configuration(token))
					end
					return facts
				end
				helpers.assert_true(shortcuts.consume(state.detail, state.options))
				state.queue[1]()
				helpers.assert_eq(observed, 1)
				helpers.assert_eq(admission_after_loss, 0, "A known retired source decision closes before querying another owner")
				helpers.assert_eq(state.fired, {})
			end)
		end)
	end)

	helpers.it("(contextual-late-custody) closes issuer replacement inside final original admission read", function()
		with_actual_logger(function(logger)
			with_editor(nil, function(shortcuts, _, state)
				local admission = state.options.admission
				local armed, reads, observed, foreign_calls = false, 0, 0, 0
				logger.set_sink(function(line)
					if line:find("Keyboard shortcut fired:", 1, true) then armed = true end
				end)
				state.options.admission = function()
					local facts = admission()
					if armed then
						reads = reads + 1
						if reads == 2 then
							observed, armed = observed + 1, false
							state.options.admission = function()
								foreign_calls = foreign_calls + 1
								return facts
							end
						end
					end
					return facts
				end
				helpers.assert_true(shortcuts.consume(state.detail, state.options))
				state.queue[1]()
				helpers.assert_eq(observed, 1)
				helpers.assert_eq(foreign_calls, 0)
				helpers.assert_eq(state.fired, {}, "Last callback owner loss cannot be hidden by its returned old gate snapshot")
			end)
		end)
	end)
end)




helpers.describe("Keyboard consumption queue acknowledgement", function()
	for _, scenario in ipairs({ "inline true", "inline false", "inline throw",
		"retained false", "retained nil", "retained unknown", "retained throw" }) do
		helpers.it("(consume-queue-ack) refuses " .. scenario .. " before any action", function()
			local shortcuts = load_over_config({ ["shortcuts.keyboard.ctrl_j"] = "select_line" })
			local gestures = require("modules.gestures.manager")
			local execute, pending, fired, before_ack = gestures.execute_action, nil, {}, nil
			gestures.execute_action = function(action) fired[#fired + 1] = action end
			local checked, failure = pcall(function()
				local called, consumed, slot = pcall(shortcuts.consume, chord("j", { ctrl = true }), {
					defer = function(callback)
						pending = callback
						if scenario:match("^inline") then callback() end
						before_ack = #fired
						if scenario:match("throw$") then error("controlled queue refusal", 0) end
						if scenario == "inline true" then return true end
						if scenario == "retained nil" then return nil end
						if scenario == "retained unknown" then return "accepted" end
						return false
					end,
				})
				helpers.assert_eq(called, true, "A queue refusal returns through the existing consume contract")
				helpers.assert_eq(consumed, false, "The original key remains available for normal forwarding")
				helpers.assert_eq(slot, nil)
				helpers.assert_eq(before_ack, 0, "No configured action runs before the queue resolves")
				helpers.assert_eq(fired, {})
				helpers.assert_eq(type(pending), "function", "The actual consumer supplied its original callback")
				pending()
				pending()
				helpers.assert_eq(fired, {}, "A refused or early callback cannot gain rights after return")
			end)
			gestures.execute_action = execute
			drop_config()
			if not checked then error(failure, 0) end
		end)
	end

	for _, scenario in ipairs({ "duplicate delivery", "reentrant delivery" }) do
		helpers.it("(consume-queue-ack) acknowledges one action under " .. scenario, function()
			local shortcuts = load_over_config({ ["shortcuts.keyboard.ctrl_j"] = "select_line" })
			local gestures = require("modules.gestures.manager")
			local execute, pending, fired, reentered = gestures.execute_action, nil, {}, false
			gestures.execute_action = function(action)
				fired[#fired + 1] = action
				if scenario == "reentrant delivery" and not reentered then reentered = true; pending() end
			end
			local checked, failure = pcall(function()
				local consumed, slot = shortcuts.consume(chord("j", { ctrl = true }), {
					defer = function(callback)
						pending = callback
						helpers.assert_eq(fired, {}, "The original positive ACK precedes execution")
						return true
					end,
				})
				helpers.assert_eq(consumed, true)
				helpers.assert_eq(slot, "ctrl_j")
				helpers.assert_eq(fired, {})
				pending()
				pending()
				helpers.assert_eq(fired, { "select_line" }, "Only the first post-ACK callback may execute this press")
			end)
			gestures.execute_action = execute
			drop_config()
			if not checked then error(failure, 0) end
		end)
	end
end)




helpers.describe("keyboard collision claim source", function()
	helpers.it("retains explicit native reservations and refuses source divergence", function()
		local keyboard, storage = load_over_config({ ctrl_j = "none", magic_editor = "none" })
		local ok, why = pcall(function()
			local frame = assert(keyboard.capture_collision_inventory())
			helpers.assert_true(frame.current())
			local found = false
			for _, claim in ipairs(frame.claims) do
				if claim.binding == "keyboard__ctrl_j" then found = claim.key == "j" and claim.mods.ctrl == true end
			end
			helpers.assert_true(found, "None is a retained ordinary native-behavior reservation")
			Sandbox.write_bytes(storage.path, '[shortcuts.keyboard]\nctrl_j = "copy"\nmagic_editor = "none"\n')
			helpers.assert_eq(frame.current(), false)
			helpers.assert_nil(keyboard.capture_collision_inventory())
		end)
		drop_config(); if not ok then error(why, 0) end
	end)
	helpers.it("configuration acquisition and its release cannot revive an old collision frame", function()
		local keyboard = load_over_config({ ctrl_j = "none", magic_editor = "none" })
		local ok, why = pcall(function()
			local frame = assert(keyboard.capture_collision_inventory()); local token = {}
			helpers.assert_true(keyboard.acquire_configuration(token))
			helpers.assert_nil(keyboard.capture_collision_inventory()); helpers.assert_eq(frame.current(), false)
			helpers.assert_true(keyboard.release_configuration(token)); helpers.assert_eq(frame.current(), false)
			helpers.assert_true(keyboard.capture_collision_inventory().current())
		end)
		drop_config(); if not ok then error(why, 0) end
	end)
end)




helpers.describe("keyboard shortcuts: live deferred admission", function()
	for _, gate in ipairs({ "master", "paused", "inhibited", "reader failure", "reader replacement" }) do
		helpers.it("(ordinary-live-admission) cancels an ordinary action after " .. gate, function()
			local shortcuts = load_over_config({ ["shortcuts.keyboard.ctrl_j"] = "select_line" })
			local gestures = require("modules.gestures.manager")
			local execute = gestures.execute_action
			local pending, fired, refuse = nil, 0, false
			local admission = { master = true, paused = false, inhibited = false }
			local options = {
				defer = function(callback) pending = callback; return true end,
				admission = function()
					if refuse then error("admission reader unavailable") end
					return admission
				end,
			}
			gestures.execute_action = function() fired = fired + 1 end
			local checked, failure = pcall(function()
				local detail = chord("j", { ctrl = true })
				helpers.assert_true(shortcuts.consume(detail, options))
				pending()
				helpers.assert_eq(fired, 1, "an admitted ordinary chord still executes")
				helpers.assert_true(shortcuts.consume(detail, options))
				if gate == "master" then admission.master = false
				elseif gate == "paused" then admission.paused = true
				elseif gate == "inhibited" then admission.inhibited = true
				elseif gate == "reader failure" then refuse = true
				else options.admission = function() return admission end end
				pending()
				pending()
				helpers.assert_eq(fired, 1, "pending input cannot outlive its live admission")
			end)
			gestures.execute_action = execute
			drop_config()
			if not checked then error(failure, 0) end
		end)
	end

	for _, gate in ipairs({ "master", "paused" }) do
		helpers.it("(ordinary-live-admission) keeps script control available through " .. gate, function()
			local shortcuts = load_over_config({ ["shortcuts.keyboard.ctrl_j"] = "script_pause_toggle" })
			local gestures = require("modules.gestures.manager")
			local execute, pending, fired = gestures.execute_action, nil, 0
			local admission = { master = true, paused = false, inhibited = false }
			gestures.execute_action = function() fired = fired + 1 end
			local checked, failure = pcall(function()
				helpers.assert_true(shortcuts.consume(chord("j", { ctrl = true }), {
					defer = function(callback) pending = callback; return true end,
					admission = function() return admission end,
				}))
				admission[gate] = gate == "paused"
				pending()
				helpers.assert_eq(fired, 1, "script control remains the user's way back from pause")
			end)
			gestures.execute_action = execute
			drop_config()
			if not checked then error(failure, 0) end
		end)
	end
end)




helpers.describe("keyboard shortcuts: admission callback boundaries", function()
	for _, phase in ipairs({ "capture", "queue acknowledgement", "execution log" }) do
		helpers.it("(ordinary-live-admission) rechecks pause at " .. phase, function()
			local shortcuts = load_over_config({ ["shortcuts.keyboard.ctrl_j"] = "select_line" })
			local gestures, logger = require("modules.gestures.manager"), require("logger.shim")
			local execute, debug_log = gestures.execute_action, logger.debug
			local pending, fired, queued = nil, 0, 0
			local admission = { master = true, paused = phase == "capture", inhibited = false }
			gestures.execute_action = function() fired = fired + 1 end
			logger.debug = function(tag, message, ...)
				if phase == "execution log" and message:find("Keyboard shortcut fired", 1, true) then admission.paused = true end
				return debug_log(tag, message, ...)
			end
			local checked, failure = pcall(function()
				local consumed = shortcuts.consume(chord("j", { ctrl = true }), {
					defer = function(callback)
						pending, queued = callback, queued + 1
						if phase == "queue acknowledgement" then admission.paused = true end
						return true
					end,
					admission = function() return admission end,
				})
				helpers.assert_eq(consumed, phase == "execution log", "a pause before queue admission keeps the key native")
				helpers.assert_eq(queued, phase == "capture" and 0 or 1)
				if pending then pending() end
				helpers.assert_eq(fired, 0, "no callback may deliver an ordinary action through a pause")
			end)
			gestures.execute_action, logger.debug = execute, debug_log
			drop_config()
			if not checked then error(failure, 0) end
		end)
	end
end)

