--- tests/unit/modules/shortcuts/test_magic_editor_source_owner.lua

--- ==============================================================================
--- MODULE: Conditional Editor Shortcut Source Ownership
--- DESCRIPTION:
--- Exercises the real shared decision and native registrar around controlled
--- source receipts. Only a unique direct numeric source may acquire a chord;
--- stale callbacks, explicit choices and unfinished cleanup cannot deliver.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"hs", "infra.logger", "infra.paths", "infra.manifest_reader",
	"adapters.file_system", "adapters.input_source_broker", "adapters.keyboard_source_probe",
	"adapters.hotkey_registrar", "modules.keymap.magic_key_source", "modules.shortcuts.magic_editor",
	"adapters.keyboard_geometry", "shortcuts.magic_editor",
}

local function with_fixture(callback)
	return helpers.with_stub_scope(OWNED_MODULES, function()
		local native = dofile("tests/stubs/hs.lua")
		native.keycodes.map = { a = 0, c = 8, b = 11, j = 38 }
		_G.hs, package.loaded.hs = native, native
		package.loaded["adapters.keyboard_geometry"] = require("tests.support.keyboard_geometry_ports").new(native.eventtap.event.properties)
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.paths"] = { shared = function() return "physical-registry.json" end }
		package.loaded["infra.manifest_reader"] = {
			default_for = function() return "open_hotstrings_editor" end,
		}
		package.loaded["adapters.file_system"] = { read = function()
			return '{"keys":{"KeyA":{"kind":"key","hs":0},"KeyC":{"kind":"key","hs":8},"KeyB":{"kind":"key","hs":11},"KeyJ":{"kind":"key","hs":38},"Backquote":{"kind":"key","hs":50,"macos_iso":{"hs":10}},"IntlBackslash":{"kind":"key","hs":10,"macos_iso":{"hs":50}}}}'
		end }
		local state = {
			source_id = "source.first", trigger = "★", magic_source = "automatic",
			replace_active = false, paused = false, inhibited = false, current = true,
			requests = {}, actions = {}, cancel_refuses = false, projections = {}, remap_types = {},
		}
		package.loaded["modules.keymap.magic_key_source"] = {
			remaps = function(code, _, active, keyboard_type)
				state.remap_types[#state.remap_types + 1] = { code = code, keyboard_type = keyboard_type }
				return (state.remap_code == code or (state.remap_codes or {})[code] == true) and active() == true
			end,
		}
		package.loaded["adapters.input_source_broker"] = {
			subscribe = function(_, observer) state.source_changed = observer; return true end,
			unsubscribe = function() state.source_changed = nil; return true end,
		}
		package.loaded["adapters.keyboard_source_probe"] = {
			current_source_id = function() return state.source_id end,
			request = function(request, observer)
				local retained = { request = request, observer = observer, settled = false }
				retained.operation = {
					cancel = function()
						if state.cancel_refuses and not retained.settled then return false end
						retained.settled = true
						return true
					end,
					is_settled = function() return retained.settled end,
					on_settled = function(observer) retained.on_settled = observer; return true end,
				}
				state.requests[#state.requests + 1] = retained
				return retained.operation
			end,
		}
		local policy = require("shortcuts.magic_editor")
		package.loaded["shortcuts.magic_editor"] = setmetatable({ resolve = function(options)
			state.projections[#state.projections + 1] = options
			return policy.resolve(options)
		end }, { __index = policy })
		local registrar = require("adapters.hotkey_registrar")
		local subject = require("modules.shortcuts.magic_editor")
		local spec = {
			configuration_generation = 1,
			is_action = function(action)
				return action == "open_hotstrings_editor" or action == "script_pause_toggle" or action == "none"
			end,
			is_current = function() return state.current end,
			execute = function(action, binding)
				state.actions[#state.actions + 1] = { action = action, binding = binding }
				return true
			end,
			context = {
				trigger = function() return state.trigger end,
				magic_source = function() return state.magic_source end,
				replace_active = function() return state.replace_active end,
				paused = function() return state.paused end,
				inhibited = function() return state.inhibited end,
			},
		}
		local function respond(index, levels, keyboard_type)
			local retained = state.requests[index or #state.requests]
			retained.settled = true
			if retained.on_settled then retained.on_settled() end
			local selected = {}
			for _, level in ipairs(levels or {
				{ code = 0, text = "a", direct = true, dead = false },
				{ code = 8, text = state.trigger, direct = true, dead = false },
				{ code = 11, text = "b", direct = true, dead = false },
			}) do selected[level.code] = level end
			local ordered = {}
			for _, code in ipairs(retained.request.codes) do
				ordered[#ordered + 1] = selected[code] or { code = code, text = "", direct = false, dead = false }
			end
			retained.observer({
				version = 1, source_id = retained.request.source_id, keyboard_type = keyboard_type or 40,
				levels = ordered,
			})
		end
		callback(subject, registrar, native, state, spec, respond)
	end)
end

helpers.describe("conditional editor shortcut: native source and ordinary ownership", function()
	helpers.it("binds the numeric direct source and retargets after source and trigger changes", function()
		with_fixture(function(subject, registrar, native, state, spec, respond)
			helpers.assert_eq(subject.start(spec), true)
			respond()
			helpers.assert_eq(native.hotkey._bound[1].key, 8)
			helpers.assert_eq(native.hotkey._bound[1].mods, { "ctrl" })
			native.hotkey._bound[1].pressed_fn()
			helpers.assert_eq(state.actions, { { action = "open_hotstrings_editor", binding = "keyboard__magic_editor" } })
			state.source_id, state.trigger = "source.second", "ù"
			state.source_changed()
			helpers.assert_eq(registrar.live_count(), 0, "old physical owner must be released before new proof")
			respond(nil, { { code = 11, text = "ù", direct = true, dead = false } })
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

	helpers.it("uses only an acknowledged explicit replacement beside a native star", function()
		with_fixture(function(subject, _, native, state, spec, respond)
			state.magic_source, state.remap_code, state.replace_active = "KeyJ", 38, true
			helpers.assert_eq(subject.start(spec), true)
			respond()
			helpers.assert_eq(native.hotkey._bound[1].key, 38,
				"the selected active replacement must outrank an unrelated native star")
			native.hotkey._bound[1].pressed_fn()
			helpers.assert_eq(#state.actions, 1)
			state.replace_active = false
			native.hotkey._bound[1].pressed_fn()
			helpers.assert_eq(#state.actions, 1, "a replacement-gate change fences the captured source immediately")
			helpers.assert_eq(subject.refresh(), true)
			respond()
			helpers.assert_eq(native.hotkey._bound[1].key, 8, "an ineffective replacement returns to the actual native scan")
			helpers.assert_eq(subject.stop(), true)
		end)
	end)

	helpers.it("refuses raw fallback when explicit replacement ownership is unacknowledged", function()
		with_fixture(function(subject, registrar, _, state, spec, respond)
			state.magic_source, state.remap_code, state.replace_active = "KeyJ", 38, nil
			helpers.assert_eq(subject.start(spec), true)
			respond()
			helpers.assert_eq(registrar.live_count(), 0)
			helpers.assert_eq(subject.reason(), "source_unavailable")
			helpers.assert_eq(subject.stop(), true)
		end)
	end)

	helpers.it("refuses a collaborator's two ambiguous effective physical identities", function()
		with_fixture(function(subject, registrar, _, state, spec, respond)
			state.magic_source, state.replace_active = "Backquote", true
			state.remap_codes = { [10] = true, [50] = true }
			helpers.assert_eq(subject.start(spec), true)
			respond()
			helpers.assert_eq(registrar.live_count(), 0, "the primary resolver code cannot stand in for hardware proof")
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
				{ chord = "Ctrl+C", action = "none", binding_id = "keyboard__hs_ctrl_c" },
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

	helpers.it("fences stale proof and callbacks after trigger, pause or admission changes", function()
		with_fixture(function(subject, registrar, native, state, spec, respond)
			helpers.assert_eq(subject.start(spec), true)
			state.trigger = ";"
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
			state.source_id, state.trigger = "source.second", "ù"
			helpers.assert_eq(subject.refresh(), false)
			helpers.assert_eq(#state.requests, 1, "replacement cannot race the old task")
			respond(1)
			helpers.assert_eq(registrar.live_count(), 0, "settled stale proof remains fenced")
			helpers.assert_eq(#state.requests, 2, "acknowledged settlement resumes the latest intent")
			respond(2, { { code = 11, text = "ù", direct = true, dead = false } })
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
			local logger = package.loaded["infra.logger"]
			local error_log = logger.error
			logger.error = function(...) errors = errors + 1; return error_log(...) end
			spec.context.replace_active = function()
				reads = reads + 1
				stopped = subject.stop()
				return state.replace_active
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
			spec.context.replace_active = function()
				reads = reads + 1
				state.current = false
				return state.replace_active
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
			spec.context.replace_active = function()
				reads = reads + 1
				state.source_id = "source.second"
				return state.replace_active
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


	helpers.it("allocates no source query after construction context retires its owner", function()
		with_fixture(function(subject, registrar, _, state, spec)
			local stopped = nil
			spec.context.trigger = function()
				stopped = subject.stop()
				return state.trigger
			end
			local started = subject.start(spec)
			local requests = #state.requests
			helpers.assert_eq(subject.stop(), true)
			helpers.assert_eq(registrar.live_count(), 0)
			helpers.assert_eq(stopped, true, "the constructor read must actually settle its old owner")
			helpers.assert_eq(started, false, "a retired constructor must not acknowledge startup")
			helpers.assert_eq(requests, 0, "no new query owner may be allocated after retirement")
		end)
	end)
end)

helpers.describe("conditional editor shortcut: original signed-source issuer", function()
	for _, field in ipairs({ "current_source_id", "request" }) do
		helpers.it("refuses a replaced original " .. field .. " before constructor allocation", function()
			with_fixture(function(subject, registrar, _, state, spec)
				local probe = package.loaded["adapters.keyboard_source_probe"]
				local original, foreign_calls = probe[field], 0
				probe[field] = function(...)
					foreign_calls = foreign_calls + 1
					return original(...)
				end
				local started = subject.start(spec)
				local requests = #state.requests
				local subscribed = state.source_changed ~= nil
				probe[field] = original
				helpers.assert_eq(subject.stop(), true)
				helpers.assert_eq(started, false, "a replacement function is not the original signed-source issuer")
				helpers.assert_eq(foreign_calls, 0, "unknown source functions must not run")
				helpers.assert_eq(requests, 0, "unknown source ownership must allocate no query")
				helpers.assert_eq(subscribed, false, "unknown source ownership must allocate no native subscription")
				helpers.assert_eq(registrar.live_count(), 0)
			end)
		end)
	end

	helpers.it("rejoins the original request issuer after the native source read", function()
		with_fixture(function(subject, registrar, _, state, spec)
			local probe = package.loaded["adapters.keyboard_source_probe"]
			local request, reads, foreign_calls = probe.request, 0, 0
			local source = state.source_id
			state.source_id = nil
			setmetatable(state, { __index = function(_, key)
				if key ~= "source_id" then return nil end
				reads = reads + 1
				probe.request = function(...)
					foreign_calls = foreign_calls + 1
					return request(...)
				end
				return source
			end })
			local started = subject.start(spec)
			local requests = #state.requests
			probe.request = request
			setmetatable(state, nil)
			state.source_id = source
			helpers.assert_eq(subject.stop(), true)
			helpers.assert_eq(reads, 1, "the original source read executes the actual reentry")
			helpers.assert_eq(started, false)
			helpers.assert_eq(foreign_calls, 0)
			helpers.assert_eq(requests, 0, "the replaced request must not allocate after the original source read")
			helpers.assert_eq(registrar.live_count(), 0)
		end)
	end)

	helpers.it("rejoins the original request issuer after the final constructor context read", function()
		with_fixture(function(subject, registrar, _, state, spec)
			local probe = package.loaded["adapters.keyboard_source_probe"]
			local request, reads, foreign_calls = probe.request, 0, 0
			spec.context.replace_active = function()
				reads = reads + 1
				probe.request = function(...)
					foreign_calls = foreign_calls + 1
					return request(...)
				end
				return state.replace_active
			end
			local started = subject.start(spec)
			local requests = #state.requests
			probe.request = request
			helpers.assert_eq(subject.stop(), true)
			helpers.assert_eq(reads, 1, "the original late context read actually executes")
			helpers.assert_eq(started, false)
			helpers.assert_eq(foreign_calls, 0)
			helpers.assert_eq(requests, 0)
			helpers.assert_eq(registrar.live_count(), 0)
		end)
	end)

	helpers.it("retires the exact original query when request construction substitutes its issuer", function()
		with_fixture(function(subject, registrar, _, state, spec)
			local probe = package.loaded["adapters.keyboard_source_probe"]
			local request, entered = probe.request, 0
			setmetatable(state.requests, { __newindex = function(rows, index, retained)
				rawset(rows, index, retained)
				entered = entered + 1
				probe.request = function(...) return request(...) end
			end })
			local started = subject.start(spec)
			local retired = state.requests[1] and state.requests[1].settled
			probe.request = request
			setmetatable(state.requests, nil)
			helpers.assert_eq(subject.stop(), true)
			helpers.assert_eq(entered, 1, "the original query construction must execute the replacement premise")
			helpers.assert_eq(#state.requests, 1, "only the originally admitted query may exist")
			helpers.assert_eq(started, false)
			helpers.assert_eq(retired, true, "the same original operation must cancel before constructor refusal")
			helpers.assert_eq(registrar.live_count(), 0)
		end)
	end)

	for _, boundary in ipairs({ "request", "module", "metatable" }) do
		helpers.it("refuses an original asynchronous source reply after " .. boundary .. " substitution", function()
			with_fixture(function(subject, registrar, _, state, spec, respond)
				local probe = package.loaded["adapters.keyboard_source_probe"]
				local request = probe.request
				helpers.assert_eq(subject.start(spec), true)
				if boundary == "request" then probe.request = function(...) return request(...) end
				elseif boundary == "module" then
					package.loaded["adapters.keyboard_source_probe"] = { current_source_id = probe.current_source_id, request = request }
				else setmetatable(probe, {}) end
				respond()
				local live = registrar.live_count()
				package.loaded["adapters.keyboard_source_probe"] = probe
				probe.request = request
				setmetatable(probe, nil)
				helpers.assert_eq(subject.stop(), true)
				helpers.assert_eq(#state.requests, 1)
				helpers.assert_eq(live, 0, "an old callback cannot acquire through a replaced source issuer")
				helpers.assert_eq(registrar.live_count(), 0)
				helpers.assert_eq(state.actions, {})
			end)
		end)
	end

	helpers.it("retires the exact late native handle when registration changes the original source issuer", function()
		with_fixture(function(subject, registrar, native, state, spec, respond)
			local probe = package.loaded["adapters.keyboard_source_probe"]
			local request, native_bind, late_handle, binds = probe.request, native.hotkey.bind, nil, 0
			native.hotkey.bind = function(...)
				binds = binds + 1
				late_handle = native_bind(...)
				probe.request = function(...) return request(...) end
				return late_handle
			end
			helpers.assert_eq(subject.start(spec), true)
			respond()
			local live = registrar.live_count()
			local late_retired = { enabled = late_handle and late_handle.enabled, deleted = late_handle and late_handle.deleted }
			probe.request = request
			native.hotkey.bind = native_bind
			helpers.assert_eq(subject.stop(), true)
			helpers.assert_eq(binds, 1, "the original registrar actually acquired the late native handle")
			helpers.assert_eq(live, 0, "late acquisition must retire rather than publish source authority")
			helpers.assert_eq(late_retired, { enabled = false, deleted = true }, "the same original native handle must really retire")
			helpers.assert_eq(registrar.live_count(), 0)
			helpers.assert_eq(state.actions, {})
		end)
	end)

	for _, field in ipairs({ "current_source_id", "request" }) do
		helpers.it("executes no action after live delivery substitutes original " .. field, function()
			with_fixture(function(subject, registrar, native, state, spec, respond)
				local probe = package.loaded["adapters.keyboard_source_probe"]
				local original = probe[field]
				helpers.assert_eq(subject.start(spec), true)
				respond()
				local native_handle = native.hotkey._bound[1]
				helpers.assert_not_nil(native_handle)
				probe[field] = function(...) return original(...) end
				native_handle.pressed_fn()
				local actions = #state.actions
				probe[field] = original
				helpers.assert_eq(subject.stop(), true)
				helpers.assert_eq(actions, 0, "a replacement source function must not admit the original action")
				helpers.assert_eq(registrar.live_count(), 0)
				helpers.assert_eq({ enabled = native_handle.enabled, deleted = native_handle.deleted },
					{ enabled = false, deleted = true }, "the original delivery handle must retain exact cleanup")
			end)
		end)
	end

	helpers.it("rejects a revoked issuer before refresh reads the native source", function()
		with_fixture(function(subject, registrar, native, state, spec, respond)
			local probe = package.loaded["adapters.keyboard_source_probe"]
			local request, source, reads = probe.request, state.source_id, 0
			helpers.assert_eq(subject.start(spec), true)
			respond()
			local original_handle = native.hotkey._bound[1]
			probe.request = function(...) return request(...) end
			state.source_id = nil
			setmetatable(state, { __index = function(_, key)
				if key ~= "source_id" then return nil end
				reads = reads + 1
				return source
			end })
			local refreshed = subject.refresh()
			local requests = #state.requests
			probe.request = request
			setmetatable(state, nil)
			state.source_id = source
			helpers.assert_eq(subject.stop(), true)
			helpers.assert_eq(refreshed, false)
			helpers.assert_eq(reads, 0, "a revoked source issuer must not enter the original native getter")
			helpers.assert_eq(requests, 1)
			helpers.assert_eq(registrar.live_count(), 0)
			helpers.assert_eq({ enabled = original_handle.enabled, deleted = original_handle.deleted },
				{ enabled = false, deleted = true }, "refresh still retires the exact previous native handle")
		end)
	end)

	helpers.it("rejoins the source issuer after the actual asynchronous projection callback", function()
		with_fixture(function(subject, registrar, _, state, spec, respond)
			local probe = package.loaded["adapters.keyboard_source_probe"]
			local request, reads = probe.request, 0
			spec.context.paused = function()
				reads = reads + 1
				probe.request = function(...) return request(...) end
				return false
			end
			helpers.assert_eq(subject.start(spec), true)
			respond()
			local live = registrar.live_count()
			probe.request = request
			helpers.assert_eq(subject.stop(), true)
			helpers.assert_eq(reads, 1, "the original asynchronous projection callback must execute")
			helpers.assert_eq(live, 0, "the projection callback cannot replace source authority before acquisition")
			helpers.assert_eq(registrar.live_count(), 0)
			helpers.assert_eq(state.actions, {})
		end)
	end)

	helpers.it("retains the exact refused query cancellation after issuer revocation", function()
		with_fixture(function(subject, registrar, _, state, spec)
			local probe = package.loaded["adapters.keyboard_source_probe"]
			local request, entered = probe.request, 0
			state.cancel_refuses = true
			setmetatable(state.requests, { __newindex = function(rows, index, retained)
				rawset(rows, index, retained)
				entered = entered + 1
				probe.request = function(...) return request(...) end
			end })
			local started = subject.start(spec)
			local refused = subject.stop()
			local original_query = state.requests[1]
			local still_pending = not original_query.settled
			state.cancel_refuses = false
			helpers.assert_eq(subject.stop(), true, "cleanup retries the exact original query despite revoked exports")
			probe.request = request
			setmetatable(state.requests, nil)
			helpers.assert_eq(started, false)
			helpers.assert_eq(entered, 1)
			helpers.assert_eq(refused, false, "a refused original cancellation remains cleanup debt")
			helpers.assert_eq(still_pending, true)
			helpers.assert_eq(original_query.settled, true)
			helpers.assert_eq(#state.requests, 1)
			helpers.assert_eq(registrar.live_count(), 0)
		end)
	end)

	helpers.it("retains a failed late native delete under revoked source authority", function()
		with_fixture(function(subject, registrar, native, state, spec, respond)
			local probe = package.loaded["adapters.keyboard_source_probe"]
			local request, native_bind, late_handle, original_delete = probe.request, native.hotkey.bind
			native.hotkey.bind = function(...)
				late_handle = native_bind(...)
				original_delete = late_handle.delete
				late_handle.delete = function() error("original native deletion refused") end
				probe.request = function(...) return request(...) end
				return late_handle
			end
			helpers.assert_eq(subject.start(spec), true)
			respond()
			late_handle.pressed_fn()
			local actions = #state.actions
			local refused = subject.stop()
			local not_deleted = late_handle.deleted ~= true
			late_handle.delete = original_delete
			helpers.assert_eq(subject.stop(), true, "cleanup retries the exact retained native handle with revoked exports")
			probe.request = request
			native.hotkey.bind = native_bind
			helpers.assert_eq(actions, 0)
			helpers.assert_eq(refused, false, "failed deletion must remain cleanup debt")
			helpers.assert_eq(not_deleted, true)
			helpers.assert_eq(registrar.live_count(), 0)
			helpers.assert_eq({ enabled = late_handle.enabled, deleted = late_handle.deleted },
				{ enabled = false, deleted = true })
		end)
	end)

	for _, boundary in ipairs({ "reply", "delivery" }) do
		helpers.it("rejoins the request issuer after the original native getter during " .. boundary, function()
			with_fixture(function(subject, registrar, native, state, spec, respond)
				local probe = package.loaded["adapters.keyboard_source_probe"]
				local request, source, reads = probe.request, state.source_id, 0
				helpers.assert_eq(subject.start(spec), true)
				if boundary == "delivery" then respond() end
				local original_handle = native.hotkey._bound[1]
				state.source_id = nil
				setmetatable(state, { __index = function(_, key)
					if key ~= "source_id" then return nil end
					reads = reads + 1
					probe.request = function(...) return request(...) end
					return source
				end })
				if boundary == "reply" then respond() else original_handle.pressed_fn() end
				local live, actions = registrar.live_count(), #state.actions
				probe.request = request
				setmetatable(state, nil)
				state.source_id = source
				helpers.assert_eq(subject.stop(), true)
				helpers.assert_eq(reads, 1, "the original native getter must execute the substitution premise")
				helpers.assert_eq(actions, 0)
				if boundary == "reply" then helpers.assert_eq(live, 0, "source read reentry cannot acquire a native handle")
				else
					helpers.assert_eq({ enabled = original_handle.enabled, deleted = original_handle.deleted },
						{ enabled = false, deleted = true })
				end
				helpers.assert_eq(registrar.live_count(), 0)
			end)
		end)
	end

	helpers.it("retires the original query after settlement observer registration substitutes its issuer", function()
		with_fixture(function(subject, registrar, _, state, spec)
			local probe = package.loaded["adapters.keyboard_source_probe"]
			local request, registered = probe.request, 0
			setmetatable(state.requests, { __newindex = function(rows, index, retained)
				rawset(rows, index, retained)
				local original_registration = retained.operation.on_settled
				retained.operation.on_settled = function(observer)
					registered = registered + 1
					local admitted = original_registration(observer)
					probe.request = function(...) return request(...) end
					return admitted
				end
			end })
			local started = subject.start(spec)
			local original_query = state.requests[1]
			local retired = original_query.settled
			probe.request = request
			setmetatable(state.requests, nil)
			helpers.assert_eq(subject.stop(), true)
			helpers.assert_eq(registered, 1, "the same original query registers its actual settlement callback")
			helpers.assert_eq(started, false)
			helpers.assert_eq(retired, true, "that original query must cancel before startup returns")
			helpers.assert_eq(#state.requests, 1)
			helpers.assert_eq(registrar.live_count(), 0)
		end)
	end)
end)


helpers.describe("conditional editor shortcut: receipt-bound keyboard geometry", function()
	for _, row in ipairs({
		{ name = "ISO Backquote", model = 7002, native = 10, physical = "Backquote" },
		{ name = "ISO neighbor", model = 7002, native = 50, physical = "IntlBackslash" },
		{ name = "ANSI Backquote", model = 7001, native = 50, physical = "Backquote" },
	}) do
		helpers.it("projects " .. row.name .. " using the native translation receipt", function()
			with_fixture(function(subject, registrar, native, state, spec, respond)
				helpers.assert_eq(subject.start(spec), true)
				respond(nil, { { code = row.native, text = "★", direct = true, dead = false } }, row.model)
				helpers.assert_eq(registrar.live_count(), 1)
				helpers.assert_eq(native.hotkey._bound[1].key, row.native)
				local selected
				for _, candidate in ipairs(state.projections[1].source.candidates) do
					if candidate.native_code == row.native then selected = candidate end
				end
				helpers.assert_not_nil(selected)
				helpers.assert_eq(selected.code, row.physical, "the numeric chord alone must not hide a swapped canonical slot")
				for _, call in ipairs(state.remap_types) do
					helpers.assert_eq(call.keyboard_type, row.model, "replacement ownership must use this exact translation receipt")
				end
				native.hotkey._bound[1].pressed_fn()
				helpers.assert_eq(#state.actions, 1)
				helpers.assert_eq(subject.stop(), true)
				helpers.assert_eq(registrar.live_count(), 0)
			end)
		end)
	end
	helpers.it("does not acquire a JIS or unknown swapped receipt as its ANSI neighbor", function()
		for _, model in ipairs({ 7003, 7004 }) do
			with_fixture(function(subject, registrar, _, state, spec, respond)
				helpers.assert_eq(subject.start(spec), true)
				respond(nil, { { code = 10, text = "★", direct = true, dead = false } }, model)
				helpers.assert_eq(registrar.live_count(), 0)
				helpers.assert_eq(#state.actions, 0)
				helpers.assert_eq(subject.stop(), true)
			end)
		end
	end)
end)
