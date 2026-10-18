--- tests/unit/modules/keylogger/test_focus_guard_async.lua

--- Asynchronous context publication retains exact generations and native cleanup.
local helpers = require("tests.helpers")

--- Runs the actual guard with independently controlled native observations/ACKs.
--- @param body function Receives guard and owned operation controls.
local function fixture(body)
	local state = { now = 0, path = "/field/A", role = 61, epoch = 0, secure = true,
		starts = 0, publications = 0, pumps = 0, barriers = 0, operations = {}, protected = false }
	local listener, guard
	local function snapshot() return not state.unknown and { bus = ":1.7", path = state.path, role = state.role } or nil end
	local watch = {
		on_change = function(fn) listener = fn end,
		invalidate = function() listener(nil) end,
		pump = function()
			state.pumps = state.pumps + 1
			if state.changed then state.changed = false; listener(snapshot()) end
		end,
		barrier = function() state.barriers = state.barriers + 1; local field = snapshot(); listener(field); return field end,
	}
	guard = require("modules.keylogger.focus_guard").new({ watch = watch, retry_ms = 1000,
		detector = {
			invalidateFocus = function() state.epoch = state.epoch + 1; return state.epoch end,
			currentEpoch = function() return state.epoch end,
			publishFocus = function(_, epoch) return epoch == state.epoch end,
			isSecureField = function() return state.secure end,
		},
		keylogger = { set_secure_field = function(value) state.secure = value end,
			is_context_protected = function() return state.protected end },
		now_ms = function() return state.now end,
		capture_context_async = function(field, options, callback)
			state.starts = state.starts + 1
			local request = { field = field, options = options, callback = callback, settled = false, cancels = 0 }
			local operation = {
				is_settled = function() return request.settled end,
				cancel = function()
					request.cancels = request.cancels + 1
					if state.cancel_reentry then
						local pumps = state.pumps
						helpers.assert_eq(guard.refresh(true), false)
						helpers.assert_eq(state.pumps, pumps, "cancellation cannot repump native input")
					end
					return request.settled
				end,
			}
			request.operation = operation; state.operations[#state.operations + 1] = request
			if state.dispatch_reentry then
				local pumps = state.pumps
				helpers.assert_eq(guard.refresh(true), false)
				helpers.assert_eq(state.pumps, pumps, "dispatch cannot recursively query native focus")
			end
			if state.sync_failure then request.settled = true; callback(nil) end
			if state.cancel_during_dispatch then guard.invalidate() end
			return operation
		end,
		publish_context = function()
			helpers.assert_true(state.secure, "policy must publish before text release")
			state.publications = state.publications + 1
			if state.publish_reentry then guard.invalidate() end
			return true, state.protected
		end,
	})
	function state.complete(index, valid, settled)
		local request = state.operations[index]
		request.settled = settled == true
		request.callback(valid and { app_id = "editor", title = "Owned ordinary title", native_identity = "window:1" } or nil)
	end
	function state.change(path) state.path, state.changed = path, true end
	body(guard, state)
end

helpers.describe("asynchronous native privacy context", function()
	helpers.it("(context-async) completion stages RAM and waits physical ACK plus fresh field admission", function()
		fixture(function(guard, state)
			helpers.assert_eq(guard.prime(), false)
			helpers.assert_true(state.secure); helpers.assert_eq(state.starts, 1)
			local pumps, barriers = state.pumps, state.barriers
			state.complete(1, true, false)
			helpers.assert_eq(state.pumps, pumps); helpers.assert_eq(state.barriers, barriers)
			helpers.assert_eq(state.publications, 0)
			helpers.assert_eq(guard.refresh(true), false)
			helpers.assert_true(guard.blocks_text())
			state.operations[1].settled = true
			helpers.assert_true(guard.refresh(true))
			helpers.assert_eq(state.publications, 1); helpers.assert_eq(state.secure, false)
			helpers.assert_true(state.barriers > barriers)
			for _ = 1, 10 do guard.refresh(true) end
			helpers.assert_eq(state.starts, 1, "settled unchanged focus does not start per-character workers")
		end)
	end)

	helpers.it("(context-async) ABA and stale callbacks cannot replace unacknowledged cleanup", function()
		fixture(function(guard, state)
			guard.prime(); state.change("/field/B"); guard.refresh(true)
			helpers.assert_true(state.operations[1].cancels > 0)
			state.change("/field/A"); guard.refresh(true)
			helpers.assert_eq(state.starts, 1)
			state.complete(1, true, true); guard.refresh(true)
			helpers.assert_eq(state.publications, 0); helpers.assert_eq(state.starts, 2)
			state.complete(2, true, true); helpers.assert_true(guard.refresh(true))
			helpers.assert_eq(state.publications, 1)
		end)
	end)

	helpers.it("(context-async) failure retries unchanged field only after ACK and canonical interval", function()
		fixture(function(guard, state)
			guard.prime(); state.complete(1, false, false)
			state.now = 5000; guard.refresh(true)
			helpers.assert_eq(state.starts, 1, "elapsed time cannot replace physical retirement")
			state.operations[1].settled = true; guard.refresh(true)
			for offset = 1, 999 do state.now = 5000 + offset; guard.refresh(true) end
			helpers.assert_eq(state.starts, 1); helpers.assert_true(guard.blocks_text())
			state.now = 6000; guard.refresh(true)
			helpers.assert_eq(state.starts, 2)
			state.complete(2, true, true); helpers.assert_true(guard.refresh(true))
		end)
	end)

	helpers.it("(context-async) quick synchronous failures cannot spawn every periodic refresh", function()
		fixture(function(guard, state)
			state.sync_failure = true; guard.prime(); guard.refresh(true)
			for _ = 1, 100 do guard.refresh(true) end
			helpers.assert_eq(state.starts, 1)
			state.now = 999; guard.refresh(true); helpers.assert_eq(state.starts, 1)
			state.now = 1000; guard.refresh(true); helpers.assert_eq(state.starts, 2)
		end)
	end)

	helpers.it("(context-async) changed field starts fresh after cleanup without borrowing retry authority", function()
		fixture(function(guard, state)
			guard.prime(); state.complete(1, false, true); guard.refresh(true)
			state.change("/field/B"); guard.refresh(true)
			helpers.assert_eq(state.starts, 2)
		end)
	end)

	helpers.it("(context-async) shutdown and dispatch reentry fence before cancellation callbacks", function()
		fixture(function(guard, state)
			state.dispatch_reentry, state.cancel_reentry = true, true
			guard.prime(); state.change("/field/B"); guard.refresh(true)
			helpers.assert_eq(state.starts, 1)
			helpers.assert_eq(guard.stop(), false)
			state.complete(1, true, true)
			helpers.assert_true(guard.stop()); helpers.assert_eq(state.publications, 0)
			helpers.assert_eq(guard.refresh(true), false); helpers.assert_true(guard.blocks_text())
		end)
	end)

	helpers.it("(context-async) cancellation during dispatch retains the returned native obligation", function()
		fixture(function(guard, state)
			state.cancel_during_dispatch = true; guard.prime()
			helpers.assert_true(state.operations[1].cancels > 0)
			helpers.assert_eq(guard.stop(), false)
			state.operations[1].settled = true; helpers.assert_true(guard.stop())
		end)
	end)

	helpers.it("(context-async) password roles never start a context worker", function()
		fixture(function(guard, state)
			state.role = 40; guard.prime(); guard.refresh(true)
			helpers.assert_eq(state.starts, 0); helpers.assert_true(state.secure)
		end)
	end)

	helpers.it("(context-async) native path and role concatenation cannot collide", function()
		fixture(function(guard, state)
			state.path, state.role = "/field/a6", 1
			guard.prime(); state.complete(1, true, true); assert(guard.refresh(true))
			state.path, state.role, state.changed = "/field/a", 61, true
			assert(not guard.refresh(true))
			assert(state.secure and state.starts == 2, "distinct exact native receipts require a new join")
		end)
	end)

	helpers.it("(context-async) live policy and publication reentry remain closed", function()
		fixture(function(guard, state)
			guard.prime(); state.complete(1, true, true); state.protected = true
			helpers.assert_true(guard.refresh(true)); helpers.assert_true(guard.blocks_text())
			state.protected = false; helpers.assert_eq(guard.blocks_text(), false)
			state.change("/field/B"); guard.refresh(true); state.complete(2, true, true)
			state.publish_reentry = true
			helpers.assert_eq(guard.refresh(true), false); helpers.assert_true(state.secure)
		end)
	end)
end)
