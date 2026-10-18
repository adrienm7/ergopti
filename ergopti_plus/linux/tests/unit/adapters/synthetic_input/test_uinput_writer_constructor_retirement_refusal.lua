--- tests/unit/adapters/synthetic_input/test_uinput_writer_constructor_retirement_refusal.lua

--- ==============================================================================
--- MODULE: uinput Writer Contract
--- DESCRIPTION:
--- Pins the non-forking emit channel: the exact bytes it puts on /dev/uinput,
--- the order it configures the device in, and the fact that emitting does not
--- spawn anything.
---
--- WHY BYTE-LEVEL:
--- This adapter's entire job is to hand the kernel a correctly-shaped
--- `struct input_event`. A wrong field offset does not raise — write() returns
--- the byte count either way — it just produces a key nobody pressed, or
--- nothing at all. There is no return value to assert and no exception to catch,
--- so the bytes ARE the contract. Checking "open() returned true" would pass on
--- an adapter that writes 24 zero bytes.
---
--- WHY IT NEEDS NO HARDWARE:
--- All syscalls go through a swappable backend. These tests bind a recorder, so
--- the encoding and the ioctl sequence are verified on any interpreter, with no
--- /dev/uinput and no LuaJIT. What still needs real hardware is only the last
--- link — that the kernel accepts the device — and that is precisely the part
--- these assertions make safe to attempt.
--- ==============================================================================

package.loaded["tests.support.adapters.synthetic_input.uinput_writer_fixture"] = nil
local Fixture = require("tests.support.adapters.synthetic_input.uinput_writer_fixture")
local helpers, recorder, le, owned_channel =
	Fixture.helpers, Fixture.recorder, Fixture.le, Fixture.owned_channel




helpers.describe("uinput_writer: constructor and retirement refusal boundaries", function()

	helpers.it("reserves both lazy FFI entry points before the module loader can acquire a nested channel", function()
		for _, mode in ipairs({ "open", "bind" }) do
			local writer = helpers.load_module("adapters.uinput_writer")
			local previous, preload = package.loaded.ffi, package.preload.ffi
			local opened, closed = 0, 0
			package.loaded.ffi = nil
			package.preload.ffi = function()
				helpers.assert_eq(writer.open(), false)
				helpers.assert_eq(writer.use_ffi_backend(), false)
				helpers.assert_eq(writer._set_backend(recorder().backend), false)
				helpers.assert_eq(writer.capture_output(), nil)
				return { cdef = function() end, cast = function(_, value) return value end,
					C = { open = function() opened = opened + 1; return 42 end,
						ioctl = function() return 0 end,
						write = function(_, _, count) return count end,
						close = function() closed = closed + 1; return 0 end } }
			end
			local ok, err = pcall(function()
				if mode == "bind" then helpers.assert_eq(writer.use_ffi_backend(), true) end
				helpers.assert_eq(writer.open(), true)
				local capability = writer.capture_output()
				helpers.assert_true(type(capability) == "table")
				helpers.assert_eq(writer.emit_owned(capability, 30, 1), true)
				helpers.assert_eq(writer.close_owned(capability), true)
				helpers.assert_eq(opened, 1)
				helpers.assert_eq(closed, 1)
			end)
			package.loaded.ffi, package.preload.ffi = previous, preload
			if not ok then error(err, 0) end
		end
	end)

	helpers.it("refuses a changed emission provider between constructor acknowledgement and capture", function()
		local writer = helpers.load_module("adapters.uinput_writer")
		local recorded = recorder()
		writer._set_backend(recorded.backend)
		helpers.assert_eq(writer.open(), true)
		recorded.backend.write = function() return true end
		helpers.assert_eq(writer.capture_output(), nil)
		writer.close()
	end)

	helpers.it("records exact constructor-close debt and never retries its potentially reused native fd", function()
		local writer = helpers.load_module("adapters.uinput_writer")
		local recorded = recorder({ fail_on = "ioctl", fail_req = writer.UI_DEV_SETUP })
		recorded.backend.close = function() recorded.closed = recorded.closed + 1; return false end
		writer._set_backend(recorded.backend)
		helpers.assert_eq(writer.open(), false)
		helpers.assert_eq(recorded.closed, 1)
		helpers.assert_eq(writer.has_output_debt(), true)
		helpers.assert_eq(writer.capture_output(), nil)
		helpers.assert_eq(writer.open(), false)
		helpers.assert_eq(writer._reset_backend(), false)
		helpers.assert_eq(recorded.closed, 1)
	end)

	helpers.it("retains a throwing write while retiring its exact known open channel", function()
		local writer = helpers.load_module("adapters.uinput_writer")
		local recorded = recorder()
		recorded.backend.write = function() error("native write refused") end
		recorded.backend.close = function() recorded.closed = recorded.closed + 1; return true end
		writer._set_backend(recorded.backend)
		helpers.assert_eq(writer.open(), true)
		local capability = writer.capture_output()
		helpers.assert_eq(writer.emit_owned(capability, 30, 1), false)
		helpers.assert_eq(writer.has_output_debt(), true)
		helpers.assert_eq(writer.close_owned(capability), true)
	end)

	helpers.it("does not turn nil native close into success or a retry", function()
		local writer = helpers.load_module("adapters.uinput_writer")
		local recorded = recorder()
		writer._set_backend(recorded.backend)
		helpers.assert_eq(writer.open(), true)
		local capability = writer.capture_output()
		helpers.assert_eq(writer.close_owned(capability), false)
		helpers.assert_eq(recorded.closed, 1)
		helpers.assert_eq(writer.close_owned(capability), false)
		helpers.assert_eq(recorded.closed, 1)
	end)

	helpers.it("does not retry close after a native close exception", function()
		local writer = helpers.load_module("adapters.uinput_writer")
		local recorded = recorder()
		recorded.backend.close = function() recorded.closed = recorded.closed + 1; error("native close refused") end
		writer._set_backend(recorded.backend)
		helpers.assert_eq(writer.open(), true)
		local capability = writer.capture_output()
		helpers.assert_eq(writer.close_owned(capability), false)
		helpers.assert_eq(writer.close_owned(capability), false)
		helpers.assert_eq(writer.has_output_debt(), true)
		helpers.assert_eq(recorded.closed, 1)
	end)

	helpers.it("refuses invalid native event scalars without issuing any wire attempt", function()
		local writer, recorded, capability = owned_channel()
		for _, event in ipairs({ { 0, 1 }, { -1, 1 }, { 1.5, 1 }, { 0x300, 1 }, { 30, 3 }, { "30", 1 } }) do
			helpers.assert_eq(writer.emit_owned(capability, event[1], event[2]), false)
		end
		helpers.assert_eq(#recorded.writes, 0)
		helpers.assert_eq(writer.output_view(capability).write_epoch, 0)
		helpers.assert_eq(writer.close_owned(capability), true)
	end)

end)




helpers.describe("uinput_writer: immutable native observation", function()

	helpers.it("never invokes a backend metatable while observing a private capability", function()
		local writer, recorded, capability = owned_channel()
		local calls = 0
		recorded.backend.write = nil
		setmetatable(recorded.backend, { __index = function()
			calls = calls + 1
			error("a pure capability query may not invoke a native provider")
		end })
		helpers.assert_eq(writer.output_current(capability), false)
		helpers.assert_eq(writer.output_view(capability), nil)
		helpers.assert_eq(writer.has_output_debt(), true)
		helpers.assert_eq(calls, 0)
	end)

	helpers.it("pins native syscall symbols before public ffi.C fields can change", function()
		local writer = helpers.load_module("adapters.uinput_writer")
		local previous, preload = package.loaded.ffi, package.preload.ffi
		local writes, closes = 0, 0
		local symbols = { open = function() return 42 end, ioctl = function() return 0 end,
			write = function(_, _, count) writes = writes + 1; return count end,
			close = function() closes = closes + 1; return 0 end }
		package.loaded.ffi = nil
		package.preload.ffi = function()
			return { cdef = function() end, cast = function(_, value) return value end, C = symbols }
		end
		local ok, err = pcall(function()
			helpers.assert_eq(writer.open(), true)
			local capability = writer.capture_output()
			symbols.write = function() error("foreign native write") end
			symbols.close = function() error("foreign native close") end
			helpers.assert_eq(writer.emit_owned(capability, 30, 1), true)
			helpers.assert_eq(writer.close_owned(capability), true)
			helpers.assert_eq(writes, 2)
			helpers.assert_eq(closes, 1)
		end)
		package.loaded.ffi, package.preload.ffi = previous, preload
		if not ok then error(err, 0) end
	end)

end)




helpers.describe("uinput_writer: acknowledged transaction roster", function()

	helpers.it("tracks every captured ordinary and owned write in one detached roster", function()
		local writer, _, cap = owned_channel()
		helpers.assert_eq(writer.emit(42, 1), true)
		helpers.assert_eq(writer.emit_owned(cap, 29, 1), true)
		helpers.assert_eq(writer.emit(42, 2), true)
		local view = writer.output_view(cap)
		helpers.assert_eq(table.concat(view.down, ","), "29,42")
		helpers.assert_eq(view.write_epoch, 3)
		helpers.assert_eq(view.roster_known, true)
		view.down[1] = 100
		helpers.assert_eq(table.concat(writer.output_view(cap).down, ","), "29,42")
		helpers.assert_eq(writer.emit(42, 0), true)
		helpers.assert_eq(table.concat(writer.output_view(cap).down, ","), "29")
		helpers.assert_eq(writer.close_owned(cap), true)
	end)

	helpers.it("does not infer a known down roster from an unmatched repeat", function()
		local writer, _, cap = owned_channel()
		helpers.assert_eq(writer.emit(42, 2), true)
		helpers.assert_eq(writer.output_view(cap).roster_known, false)
		helpers.assert_eq(writer.acquire_transaction(cap), nil)
		helpers.assert_eq(writer.emit(42, 0), true)
		helpers.assert_eq(writer.acquire_transaction(cap), nil)
		helpers.assert_eq(writer.close_owned(cap), true)
	end)

	helpers.it("reserves transport against all ordinary channel mutation and false aliases", function()
		local writer, recorded, cap = owned_channel()
		local token = writer.acquire_transaction(cap)
		helpers.assert_eq(type(token), "table")
		helpers.assert_eq(next(token), nil)
		helpers.assert_eq(writer.output_current(cap), false)
		helpers.assert_eq(writer.capture_output(), nil)
		helpers.assert_eq(writer.acquire_transaction(cap), nil)
		helpers.assert_eq(writer.emit(30, 1), false)
		helpers.assert_eq(writer.emit_owned(cap, 30, 1), false)
		helpers.assert_eq(writer.close_owned(cap), false)
		helpers.assert_eq(writer.close(), false)
		helpers.assert_eq(writer._reset_backend(), false)
		helpers.assert_eq(writer._set_backend({}), false)
		helpers.assert_eq(writer.transaction_current({}), false)
		local alias = setmetatable({}, { __eq = function() return true end })
		setmetatable(token, getmetatable(alias))
		helpers.assert_eq(writer.transaction_emit(alias, 30, 1), false)
		helpers.assert_eq(writer.release_transaction(alias), false)
		helpers.assert_eq(writer.retire_transaction(alias), false)
		helpers.assert_eq(#recorded.writes, 0)
		helpers.assert_eq(writer.release_transaction(token), true)
		helpers.assert_eq(writer.output_current(cap), true)
		helpers.assert_eq(writer.close_owned(cap), true)
	end)

	helpers.it("refuses premature publication and compensates only its acknowledged differences", function()
		local writer, recorded, cap = owned_channel()
		helpers.assert_eq(writer.emit(29, 1), true)
		helpers.assert_eq(writer.emit(42, 1), true)
		local token = writer.acquire_transaction(cap)
		helpers.assert_eq(writer.transaction_emit(token, 42, 0), true)
		helpers.assert_eq(writer.transaction_emit(token, 30, 1), true)
		helpers.assert_eq(writer.release_transaction(token), false)
		local view = writer.transaction_view(token)
		helpers.assert_eq(table.concat(view.down, ","), "29,30")
		helpers.assert_eq(table.concat(view.baseline, ","), "29,42")
		helpers.assert_eq(view.restored, false)
		view.baseline[1] = 30
		helpers.assert_eq(writer.restore_transaction(token), true)
		helpers.assert_eq(writer.transaction_view(token).restored, true)
		helpers.assert_eq(writer.transaction_view(token).write_epoch, 6)
		local events = {}
		for i = 1, #recorded.writes, 2 do
			local bytes = recorded.writes[i]
			events[#events + 1] = le(bytes, 19, 2) .. ":" .. le(bytes, 21, 4)
		end
		helpers.assert_eq(table.concat(events, " "), "29:1 42:1 42:0 30:1 30:0 42:1")
		helpers.assert_eq(writer.release_transaction(token), true)
		helpers.assert_eq(writer.transaction_current(token), false)
		helpers.assert_eq(table.concat(writer.output_view(cap).down, ","), "29,42")
		helpers.assert_eq(writer.close_owned(cap), true)
	end)

	helpers.it("rejects mismatched transaction rows before native IO", function()
		local writer, recorded, cap = owned_channel()
		local token = writer.acquire_transaction(cap)
		helpers.assert_eq(writer.transaction_emit(token, 42, 0), false)
		helpers.assert_eq(writer.transaction_emit(token, 42, 2), false)
		helpers.assert_eq(writer.transaction_emit(token, 42, 1), true)
		helpers.assert_eq(writer.transaction_emit(token, 42, 1), false)
		helpers.assert_eq(writer.transaction_emit(token, 42, 2), true)
		helpers.assert_eq(writer.transaction_emit(token, 42, 0), true)
		helpers.assert_eq(#recorded.writes, 6)
		helpers.assert_eq(writer.release_transaction(token), true)
		helpers.assert_eq(writer.close_owned(cap), true)
	end)

	helpers.it("never rewrites an unchanged baseline row during restoration", function()
		local writer, recorded, cap = owned_channel()
		helpers.assert_eq(writer.emit(29, 1), true)
		local token = writer.acquire_transaction(cap)
		helpers.assert_eq(writer.restore_transaction(token), true)
		helpers.assert_eq(#recorded.writes, 2)
		helpers.assert_eq(writer.release_transaction(token), true)
		helpers.assert_eq(writer.close_owned(cap), true)
	end)

	helpers.it("does not let a captured ordinary emitter interleave transaction output", function()
		local writer, recorded, cap = owned_channel()
		local ordinary = writer.emit
		local token = writer.acquire_transaction(cap)
		helpers.assert_eq(ordinary(29, 1), false)
		helpers.assert_eq(writer.transaction_emit(token, 30, 1), true)
		helpers.assert_eq(ordinary(30, 0), false)
		helpers.assert_eq(writer.restore_transaction(token), true)
		helpers.assert_eq(#recorded.writes, 4)
		helpers.assert_eq(writer.release_transaction(token), true)
		helpers.assert_eq(ordinary(29, 1), true)
		helpers.assert_eq(writer.output_view(cap).write_epoch, 3)
		helpers.assert_eq(writer.close_owned(cap), true)
	end)

	helpers.it("refuses transaction reentry while a KEY or SYN callback owns native IO", function()
		local writer = helpers.load_module("adapters.uinput_writer")
		local recorded = recorder()
		recorded.backend.close = function() recorded.closed = recorded.closed + 1; return true end
		local token, calls = nil, 0
		recorded.backend.write = function(_, bytes)
			calls = calls + 1
			helpers.assert_eq(writer.transaction_current(token), false)
			helpers.assert_eq(writer.transaction_emit(token, 31, 1), false)
			helpers.assert_eq(writer.restore_transaction(token), false)
			helpers.assert_eq(writer.release_transaction(token), false)
			helpers.assert_eq(writer.retire_transaction(token), false)
			recorded.writes[#recorded.writes + 1] = bytes
			return true
		end
		writer._set_backend(recorded.backend)
		helpers.assert_eq(writer.open(), true)
		local cap = writer.capture_output()
		token = writer.acquire_transaction(cap)
		helpers.assert_eq(writer.transaction_emit(token, 30, 1), true)
		helpers.assert_eq(writer.restore_transaction(token), true)
		helpers.assert_eq(calls, 4)
		helpers.assert_eq(writer.release_transaction(token), true)
		helpers.assert_eq(writer.close_owned(cap), true)
	end)

	for _, rejected in ipairs({ false, 1, "true", "throw" }) do
		helpers.it("retains exact reservation after unacknowledged compensation: " .. tostring(rejected), function()
			local writer = helpers.load_module("adapters.uinput_writer")
			local recorded = recorder()
			recorded.backend.close = function() recorded.closed = recorded.closed + 1; return true end
			local refuse = false
			recorded.backend.write = function(_, bytes)
				recorded.writes[#recorded.writes + 1] = bytes
				if refuse then
					if rejected == "throw" then error("controlled refusal") end
					return rejected
				end
				return true
			end
			writer._set_backend(recorded.backend)
			helpers.assert_eq(writer.open(), true)
			local cap = writer.capture_output()
			local token = writer.acquire_transaction(cap)
			helpers.assert_eq(writer.transaction_emit(token, 30, 1), true)
			refuse = true
			helpers.assert_eq(writer.restore_transaction(token), false)
			helpers.assert_eq(writer.release_transaction(token), false)
			helpers.assert_eq(writer.has_output_debt(), true)
			helpers.assert_eq(writer.capture_output(), nil)
			helpers.assert_eq(writer.transaction_current(token), false)
			local attempts = #recorded.writes
			refuse = false
			helpers.assert_eq(writer.restore_transaction(token), false)
			helpers.assert_eq(#recorded.writes, attempts)
			helpers.assert_eq(writer.close_owned(cap), false)
			helpers.assert_eq(writer.retire_transaction(token), true)
			helpers.assert_eq(recorded.closed, 1)
			helpers.assert_eq(writer.transaction_current(token), false)
			helpers.assert_eq(writer.has_output_debt(), false)
		end)
	end

	helpers.it("does not reopen delivery after uncertain retirement or retry a recycled fd", function()
		local writer = helpers.load_module("adapters.uinput_writer")
		local recorded = recorder()
		recorded.backend.close = function() recorded.closed = recorded.closed + 1; return false end
		writer._set_backend(recorded.backend)
		helpers.assert_eq(writer.open(), true)
		local token = writer.acquire_transaction(writer.capture_output())
		helpers.assert_eq(writer.retire_transaction(token), false)
		helpers.assert_eq(writer.retire_transaction(token), false)
		helpers.assert_eq(writer.release_transaction(token), false)
		helpers.assert_eq(writer.has_output_debt(), true)
		helpers.assert_eq(recorded.closed, 1)
	end)

end)

