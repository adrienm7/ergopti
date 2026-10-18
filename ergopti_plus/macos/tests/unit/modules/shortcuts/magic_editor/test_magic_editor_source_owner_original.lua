--- tests/unit/modules/shortcuts/magic_editor/test_magic_editor_source_owner_original.lua

--- ==============================================================================
--- MODULE: Conditional Editor Shortcut Source Ownership
--- DESCRIPTION:
--- Exercises the real shared decision and native registrar around controlled
--- source receipts. Only a unique direct numeric source may acquire a chord;
--- stale callbacks, explicit choices and unfinished cleanup cannot deliver.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.modules.shortcuts.magic_editor.magic_editor_source_owner_fixture"] = nil
local Fixture = require("tests.support.modules.shortcuts.magic_editor.magic_editor_source_owner_fixture")
local with_fixture = Fixture.with_fixture





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

helpers.describe("conditional editor shortcut: parent executor source rejoin", function()
	for _, field in ipairs({ "source_id", "trigger", "magic_source", "replace_active", "paused", "inhibited", "current" }) do
		helpers.it("fences " .. field .. " changes before parent executor entry", function()
			with_fixture(function(subject, registrar, native, state, spec, respond)
				local entered, rejoined, accepted = 0, 0, nil
				spec.execute = function(_, _, delivery_current)
					entered = entered + 1
					if field == "source_id" then state.source_id = "source.second"
					elseif field == "trigger" then state.trigger = ";"
					elseif field == "magic_source" then state.magic_source = "KeyJ"
					elseif field == "replace_active" then state.replace_active = true
					elseif field == "current" then state.current = false
					else state[field] = true end
					if type(delivery_current) ~= "function" then
						accepted = true
						return true
					end
					rejoined = rejoined + 1
					accepted = delivery_current()
					return accepted
				end
				helpers.assert_eq(subject.start(spec), true)
				respond()
				local callback = native.hotkey._bound[1].pressed_fn
				callback()
				helpers.assert_eq(subject.stop(), true)
				helpers.assert_eq(entered, 1, "the original callback reaches its parent's handoff boundary")
				helpers.assert_eq(rejoined, 1, "the real owner supplies its retained source-decision rejoin")
				helpers.assert_eq(accepted, false, "a changed effective source must refuse the old action")
				helpers.assert_eq(registrar.live_count(), 0)
			end)
		end)
	end

	helpers.it("allows the unchanged decision at parent executor entry", function()
		with_fixture(function(subject, registrar, native, _, spec, respond)
			local rejoined, accepted = 0, false
			spec.execute = function(_, _, delivery_current)
				if type(delivery_current) ~= "function" then return false end
				rejoined = rejoined + 1
				accepted = delivery_current()
				return accepted
			end
			helpers.assert_eq(subject.start(spec), true)
			respond()
			native.hotkey._bound[1].pressed_fn()
			helpers.assert_eq(subject.stop(), true)
			helpers.assert_eq(rejoined, 1)
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(registrar.live_count(), 0)
		end)
	end)
end)
