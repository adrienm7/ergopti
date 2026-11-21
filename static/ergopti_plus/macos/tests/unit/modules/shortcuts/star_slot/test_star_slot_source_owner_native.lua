--- tests/unit/modules/shortcuts/star_slot/test_star_slot_source_owner_native.lua

--- ==============================================================================
--- MODULE: The ★ Key Slot's Source Ownership
--- DESCRIPTION:
--- Exercises the real shared decision and native registrar around controlled
--- source receipts. Only a unique key typing ★ at its base level may acquire
--- Ctrl+★; stale callbacks, explicit choices and unfinished cleanup cannot
--- deliver.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.modules.shortcuts.star_slot.star_slot_source_owner_fixture"] = nil
local Fixture = require("tests.support.modules.shortcuts.star_slot.star_slot_source_owner_fixture")
local with_fixture = Fixture.with_fixture





helpers.describe("★ key slot: native source and ordinary ownership", function()
	helpers.it("binds the key typing ★ and retargets after a source change", function()
		with_fixture(function(subject, registrar, native, state, spec, respond)
			helpers.assert_eq(subject.start(spec), true)
			respond()
			helpers.assert_eq(native.hotkey._bound[1].key, 8)
			helpers.assert_eq(native.hotkey._bound[1].mods, { "ctrl" })
			native.hotkey._bound[1].pressed_fn()
			helpers.assert_eq(state.actions, { { action = "open_hotstrings_editor", binding = "keyboard__secondary_star" } })
			state.source_id = "source.second"
			state.source_changed()
			helpers.assert_eq(registrar.live_count(), 0, "old physical owner must be released before new proof")
			respond(nil, { { code = 11, text = "★", direct = true, dead = false } })
			helpers.assert_eq(native.hotkey._bound[1].key, 11)
			helpers.assert_eq(subject.stop(), true)
			helpers.assert_eq(registrar.live_count(), 0)
		end)
	end)

	helpers.it("refuses ambiguous, dead and modifier-only sources", function()
		for _, levels in ipairs({
			{ { code = 0, text = "★", direct = true, dead = false }, { code = 8, text = "★", direct = true, dead = false } },
			{ { code = 8, text = "★", direct = false, dead = true } },
			{ { code = 8, text = "★", direct = false, dead = false } },
		}) do
			with_fixture(function(subject, registrar, _, _, spec, respond)
				helpers.assert_eq(subject.start(spec), true)
				respond(nil, levels)
				helpers.assert_eq(registrar.live_count(), 0)
				helpers.assert_eq(subject.stop(), true)
			end)
		end
	end)

	-- Regression of the 2026-11-21 decision: the slot followed the configured
	-- magic key, so ù moved Ctrl+★ onto the ù key and an AZERTY layout without
	-- ★ still shipped the editor shortcut.
	helpers.it("binds the real ★ key, never the key of the configured magic key", function()
		with_fixture(function(subject, registrar, native, _, spec, respond)
			helpers.assert_eq(subject.start(spec), true)
			respond(nil, { { code = 11, text = "ù", direct = true, dead = false },
				{ code = 8, text = "★", direct = true, dead = false } })
			helpers.assert_eq(native.hotkey._bound[1].key, 8)
			helpers.assert_eq(registrar.live_count(), 1)
			helpers.assert_eq(subject.stop(), true)
		end)
	end)

	helpers.it("ships no default on a layout without a ★ key", function()
		with_fixture(function(subject, registrar, _, _, spec, respond)
			helpers.assert_eq(subject.start(spec), true)
			respond(nil, { { code = 11, text = "ù", direct = true, dead = false },
				{ code = 0, text = "a", direct = true, dead = false } })
			helpers.assert_eq(registrar.live_count(), 0)
			helpers.assert_eq(subject.reason(), "source_missing")
			helpers.assert_eq(subject.stop(), true)
		end)
	end)

	helpers.it("respects explicit none and custom actions in the same ordinary slot", function()
		for _, action in ipairs({ "none", "script_pause_toggle" }) do
			with_fixture(function(subject, registrar, native, state, spec, respond)
				spec.action = action
				helpers.assert_eq(subject.start(spec), true)
				if action == "none" then
					helpers.assert_eq(#state.requests, 0, "a disabled logical slot owns no native probe")
					helpers.assert_eq(registrar.live_count(), 0)
					helpers.assert_eq(subject.reason(), "shortcut_disabled")
				else
					respond()
					native.hotkey._bound[1].pressed_fn()
					helpers.assert_eq(state.actions[1].action, action)
				end
				helpers.assert_eq(subject.stop(), true)
			end)
		end
	end)

	helpers.it("preserves an explicit physical none claim from another ordinary slot", function()
		with_fixture(function(subject, registrar, _, _, spec, respond)
			registrar.replace_physical_claims("ordinary", {
				{ chord = "Ctrl+C", action = "none", binding_id = "keyboard__secondary_c" },
			})
			helpers.assert_eq(subject.start(spec), true)
			respond()
			helpers.assert_eq(registrar.live_count(), 0)
			helpers.assert_eq(subject.stop(), true)
		end)
	end)

	helpers.it("lets a later explicit native owner win without delivering the conditional callback", function()
		with_fixture(function(subject, registrar, native, state, spec, respond)
			helpers.assert_eq(subject.start(spec), true)
			respond()
			local conditional = native.hotkey._bound[1]
			local explicit = registrar.bind("Ctrl+C", function() return true end)
			helpers.assert_not_nil(explicit)
			helpers.assert_eq(conditional.enabled, false)
			conditional.pressed_fn()
			helpers.assert_eq(#state.actions, 0)
			helpers.assert_eq(subject.stop(), true)
			helpers.assert_eq(registrar.live_count(), 1, "the unrelated explicit owner must remain live")
			helpers.assert_eq(registrar.unbind(explicit), true)
		end)
	end)

	helpers.it("fences stale proof and callbacks after source, pause or admission changes", function()
		with_fixture(function(subject, registrar, native, state, spec, respond)
			helpers.assert_eq(subject.start(spec), true)
			state.source_id = "source.second"
			respond()
			helpers.assert_eq(registrar.live_count(), 0)
			helpers.assert_eq(subject.refresh(), true)
			respond()
			local callback = native.hotkey._bound[1].pressed_fn
			state.paused = true
			callback()
			state.paused, state.inhibited = false, true
			callback()
			state.inhibited, state.current = false, false
			callback()
			helpers.assert_eq(#state.actions, 0)
			helpers.assert_eq(subject.stop(), true)
		end)
	end)

	helpers.it("joins refused native probe cleanup before accepting a replacement", function()
		with_fixture(function(subject, registrar, _, state, spec, respond)
			helpers.assert_eq(subject.start(spec), true)
			state.cancel_refuses = true
			helpers.assert_eq(subject.stop(), false)
			respond(1)
			helpers.assert_eq(registrar.live_count(), 0, "a cancelled but retained callback cannot acquire")
			state.cancel_refuses = false
			helpers.assert_eq(subject.stop(), true)
			helpers.assert_eq(subject.start(spec), true)
			respond()
			helpers.assert_eq(registrar.live_count(), 1)
			helpers.assert_eq(subject.stop(), true)
		end)
	end)

	helpers.it("retargets the latest source after asynchronous cancellation settles", function()
		with_fixture(function(subject, registrar, native, state, spec, respond)
			helpers.assert_eq(subject.start(spec), true)
			state.cancel_refuses = true
			state.source_id = "source.second"
			-- Accepted and deferred: the fenced proof's settlement retargets, so a
			-- caller must not report it as cleanup debt (stop() still does, above).
			helpers.assert_eq(subject.refresh(), true)
			helpers.assert_eq(#state.requests, 1, "replacement cannot race the old task")
			respond(1)
			helpers.assert_eq(registrar.live_count(), 0, "settled stale proof remains fenced")
			helpers.assert_eq(#state.requests, 2, "acknowledged settlement resumes the latest intent")
			respond(2, { { code = 11, text = "★", direct = true, dead = false } })
			helpers.assert_eq(native.hotkey._bound[1].key, 11)
			helpers.assert_eq(subject.stop(), true)
		end)
	end)

	helpers.it("retains a failed native delete for exact cleanup retry", function()
		with_fixture(function(subject, registrar, native, _, spec, respond)
			helpers.assert_eq(subject.start(spec), true)
			respond()
			local binding = native.hotkey._bound[1]
			local delete = binding.delete
			binding.delete = function() error("native delete refusal") end
			helpers.assert_eq(subject.stop(), false)
			helpers.assert_eq(registrar.live_count(), 1)
			helpers.assert_eq(binding.enabled, false)
			binding.delete = delete
			helpers.assert_eq(subject.stop(), true)
			helpers.assert_eq(registrar.live_count(), 0)
		end)
	end)

	helpers.it("reports acquisition debt during a reentrant pause and releases its late candidate", function()
		with_fixture(function(subject, registrar, native, _, spec, respond)
			local native_bind = native.hotkey.bind
			local pause_receipt = nil
			native.hotkey.bind = function(...)
				pause_receipt = subject.stop()
				return native_bind(...)
			end
			helpers.assert_eq(subject.start(spec), true)
			respond()
			helpers.assert_eq(pause_receipt, false, "an in-flight acquisition cannot acknowledge complete shutdown")
			helpers.assert_eq(registrar.live_count(), 0)
			helpers.assert_eq(subject.stop(), true)
		end)
	end)

	helpers.it("does not replace an unsupported explicit logical assignment with the default", function()
		with_fixture(function(subject, registrar, _, state, spec)
			spec.context.assignment_unavailable = true
			helpers.assert_eq(subject.start(spec), true)
			helpers.assert_eq(#state.requests, 0)
			helpers.assert_eq(registrar.live_count(), 0)
			helpers.assert_eq(subject.reason(), "explicit_assignment")
			helpers.assert_eq(subject.stop(), true)
		end)
	end)

	helpers.it("keeps every present legacy choice outside conditional acquisition", function()
		for _, legacy in ipairs({ false, { mods = { "ctrl", "fn" }, key = "ù" } }) do
			with_fixture(function(subject, registrar, _, state, spec)
				spec.context.legacy_present = legacy ~= nil
				helpers.assert_eq(subject.start(spec), true)
				helpers.assert_eq(#state.requests, 0)
				helpers.assert_eq(registrar.live_count(), 0)
				helpers.assert_eq(subject.stop(), true)
			end)
		end
	end)


	helpers.it("fences delivery when the final context callback retires its exact owner", function()
		with_fixture(function(subject, registrar, native, state, spec, respond)
			helpers.assert_eq(subject.start(spec), true)
			respond()
			local native_handle = native.hotkey._bound[1]
			local callback = native_handle.pressed_fn
			local stopped, reads, errors = nil, 0, 0
			local logger = package.loaded["core.logger.engine.logger"]
			local error_log = logger.error
			logger.error = function(...) errors = errors + 1; return error_log(...) end
			spec.context.inhibited = function()
				reads = reads + 1
				stopped = subject.stop()
				return state.inhibited
			end
			callback()
			helpers.assert_eq(stopped, true, "exact native and probe owners must actually retire")
			helpers.assert_eq(reads, 1, "the terminal context callback must execute")
			helpers.assert_eq(registrar.live_count(), 0, "retired native owner must remain absent")
			helpers.assert_eq(#state.actions, 0, "retired owner may execute no action")
			helpers.assert_eq(subject.stop(), true)
			helpers.assert_eq({ enabled = native_handle.enabled, deleted = native_handle.deleted },
				{ enabled = false, deleted = true }, "the same original native handle must be disabled and deleted")
			helpers.assert_eq(errors, 0, "the real registrar must not swallow a callback exception after retirement")
		end)
	end)

	helpers.it("rechecks parent admission after the final context callback", function()
		with_fixture(function(subject, registrar, native, state, spec, respond)
			helpers.assert_eq(subject.start(spec), true)
			respond()
			local reads = 0
			spec.context.inhibited = function()
				reads = reads + 1
				state.current = false
				return state.inhibited
			end
			native.hotkey._bound[1].pressed_fn()
			local actions = #state.actions
			helpers.assert_eq(subject.stop(), true)
			helpers.assert_eq(registrar.live_count(), 0)
			helpers.assert_eq(reads, 1, "the late parent revocation premise must occur")
			helpers.assert_eq(actions, 0, "a revoked parent must not execute the captured action")
		end)
	end)

	helpers.it("rechecks native source after the final context callback", function()
		with_fixture(function(subject, registrar, native, state, spec, respond)
			helpers.assert_eq(subject.start(spec), true)
			respond()
			local reads = 0
			spec.context.inhibited = function()
				reads = reads + 1
				state.source_id = "source.second"
				return state.inhibited
			end
			native.hotkey._bound[1].pressed_fn()
			local actions = #state.actions
			helpers.assert_eq(subject.stop(), true)
			helpers.assert_eq(registrar.live_count(), 0)
			helpers.assert_eq(reads, 1, "the actual probe port must change source during the terminal callback")
			helpers.assert_eq(actions, 0, "a changed native source must not execute the captured action")
		end)
	end)


	for _, boundary in ipairs({ "retired", "parent", "source" }) do
		helpers.it("refuses native acquisition after project callbacks revoke " .. boundary, function()
			with_fixture(function(subject, registrar, native, state, spec, respond)
				local native_bind, binds, reads, stopped = native.hotkey.bind, 0, 0, nil
				native.hotkey.bind = function(...)
					binds = binds + 1
					return native_bind(...)
				end
				spec.context.paused = function()
					reads = reads + 1
					if boundary == "retired" then stopped = subject.stop()
					elseif boundary == "parent" then state.current = false
					else state.source_id = "source.second" end
					return false
				end
				helpers.assert_eq(subject.start(spec), true)
				respond()
				local captured_binds = binds
				helpers.assert_eq(subject.stop(), true)
				helpers.assert_eq(registrar.live_count(), 0, "the actual native owner must settle before assertion")
				helpers.assert_eq(reads, 1, "the actual project admission callback must run")
				if boundary == "retired" then helpers.assert_eq(stopped, true) end
				helpers.assert_eq(#state.actions, 0)
				helpers.assert_eq(captured_binds, 0, "revoked projected receipt must never start a native acquisition")
			end)
		end)
	end
end)
