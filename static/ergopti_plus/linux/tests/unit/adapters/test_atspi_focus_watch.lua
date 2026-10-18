--- tests/unit/adapters/test_atspi_focus_watch.lua

--- ==============================================================================
--- MODULE: Resident Focus Watch Privacy Regression Tests
--- DESCRIPTION:
--- Exercises exact native receipt ownership, bounded fresh input admission and
--- physical retirement. Same-window transitions cannot borrow an old ordinary
--- field's verdict, including before delayed focus notifications are delivered.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Watch = require("adapters.atspi_focus_watch")
local Guard = require("modules.keylogger.focus_guard")

--- Requires a literal false admission result.
local function assert_false(value, message) helpers.assert_eq(value, false, message) end

--- Builds a deterministic private transport and separately settled child.
--- @return table fixture
local function fixture()
	local state = { now = 1000, sequence = 0, request = 0, queue = {}, changes = {},
		running = true, settled = false, closed = 0, removed = 0, started = 0, role = 61, path = "/field/one" }
	local transport = {}
	local operation = { started = true }
	function operation:is_running() return state.running end
	function operation:is_settled() return state.settled end
	function operation:on_settled(callback) state.on_settled = callback end
	function operation:cancel() state.running = false; state.cancelled = true; return state.settled end
	function transport.command() return "luajit", {} end
	function transport.close() state.closed = state.closed + 1; return true end
	function transport.cleanup()
		state.removed = state.removed + 1
		return state.cleanup_refused ~= true
	end
	function transport.read()
		if #state.queue > 0 then return table.remove(state.queue, 1) end
		return nil, state.eof and "eof" or "again"
	end
	function state.message(kind, fields)
		state.sequence = state.sequence + 1
		local message = { kind = kind, sequence = state.sequence, request = state.request, at_ms = state.now }
		if kind == "snapshot" then
			message.role, message.active_scope, message.bus, message.path = state.role, true, ":1.2", state.path
		end
		for key, value in pairs(fields or {}) do message[key] = value end
		state.queue[#state.queue + 1] = Json.encode(message) .. "\n"
	end
	function transport.request(request)
		state.request = request
		if state.answer then state.message("snapshot") end
		return state.write_refused ~= true
	end
	state.watch = Watch.new({ now_ms = function() return state.now end,
		create_transport = function() return transport end,
		start_process = function() state.started = state.started + 1; state.settled = false; return operation end,
		pause = function() state.now = state.now + 1; if state.on_pause then state.on_pause() end end,
	})
	function state.ready()
		helpers.assert_true(state.watch.start())
		state.message("ready")
		state.message("snapshot")
		helpers.assert_true(state.watch.pump())
	end
	function state.retire()
		state.settled = true
		if state.on_settled then state.on_settled() end
	end
	return state
end





-- ===========================================
-- ===========================================
-- ======= 1/ Native Receipt Authority =======
-- ===========================================
-- ===========================================

helpers.describe("AT-SPI focus watcher: current native authority", function()
	helpers.it("imports the native worker without changing the caller's JIT policy", function()
		local available, jit = pcall(require, "jit")
		local before = nil
		if available then before = jit.status() end
		local name = "adapters.atspi_focus_watch_worker"
		local previous = package.loaded[name]
		package.loaded[name] = nil
		local loaded, worker = pcall(require, name)
		package.loaded[name] = previous
		helpers.assert_true(loaded)
		helpers.assert_eq(type(worker.run), "function")
		if available then helpers.assert_eq(jit.status(), before) end
	end)

	helpers.it("publishes same-window ordinary/password/control changes without a keyboard navigation event", function()
		local state = fixture()
		state.watch.on_change(function(snapshot) state.changes[#state.changes + 1] = snapshot or false end)
		state.ready()
		state.message("unknown")
		state.role, state.path = 40, "/field/password"
		state.message("snapshot")
		helpers.assert_true(state.watch.pump())
		helpers.assert_eq(state.changes[2], false)
		helpers.assert_eq(state.watch.snapshot().role, 40)
		state.role, state.path = 61, "/field/two"
		state.message("snapshot")
		state.watch.pump()
		helpers.assert_eq(state.watch.snapshot().path, "/field/two")
		helpers.assert_eq(state.started, 1, "transitions reuse the exact resident child")
	end)

	helpers.it("keeps programmable destination ownership on the resident receipt and clears it on unknown", function()
		local state = fixture()
		state.ready()
		local destination = require("adapters.user_hotstring_destination")
		helpers.assert_eq(destination.capture().path, "/field/one")
		state.message("unknown")
		state.watch.pump()
		helpers.assert_nil(destination.capture(), "unknown must retire the shared programmable destination")
	end)

	helpers.it("rejects source-stale backlog instead of renewing it from receive time", function()
		local state = fixture()
		state.ready()
		state.message("heartbeat")
		state.now = state.now + 1001
		assert_false(state.watch.pump())
		helpers.assert_nil(state.watch.snapshot())
		helpers.assert_nil(state.cancelled, "stale authority cannot cancel a potentially healthy resident")
	end)

	helpers.it("discards aged backlog without killing a healthy resident's fresh admission", function()
		local state = fixture()
		state.ready()
		state.message("snapshot")
		state.now = state.now + 1500
		state.message("heartbeat")
		helpers.assert_true(state.watch.pump(), "the newest source heartbeat proves the resident remains available")
		helpers.assert_nil(state.watch.snapshot(), "a new heartbeat cannot renew an old field verdict")
		helpers.assert_nil(state.cancelled, "an aged queued answer must not terminate the live owner")
		state.answer = true
		helpers.assert_eq(state.watch.barrier().role, 61, "only a fresh matching request may reopen input")
	end)

	helpers.it("recovers from parent scheduling silence using a causally fresh resident response", function()
		local state = fixture()
		state.ready()
		state.now = state.now + 1500
		assert_false(state.watch.pump())
		helpers.assert_nil(state.watch.snapshot())
		helpers.assert_nil(state.cancelled)
		state.answer = true
		helpers.assert_eq(state.watch.barrier().role, 61)
		helpers.assert_eq(state.started, 1, "recovery must keep the same exact resident child")
	end)

	helpers.it("withholds an aged answer for the current request even when a fresh heartbeat follows", function()
		local state = fixture()
		state.ready()
		helpers.assert_nil(state.watch.barrier())
		local captured_at = state.now
		state.now = state.now + 1500
		state.message("snapshot", { at_ms = captured_at })
		state.message("heartbeat")
		helpers.assert_true(state.watch.pump())
		helpers.assert_nil(state.watch.snapshot(), "neither stale matching answers nor heartbeats admit input")
		helpers.assert_nil(state.cancelled)
		state.answer = true
		helpers.assert_eq(state.watch.barrier().role, 61)
	end)

	helpers.it("keeps malformed aged frames fatal instead of treating them as harmless stale data", function()
		local state = fixture()
		state.ready()
		state.message("snapshot", { role = "invalid" })
		state.now = state.now + 1500
		assert_false(state.watch.pump())
		helpers.assert_true(state.cancelled)
	end)

	for name, malformed in pairs({ rollback = { sequence = 1 }, future = { at_ms = 2000 },
		request = { request = 9 }, fractional = { role = 40.5 }, role_type = { role = "61" } }) do
		helpers.it("withholds invalid native " .. name .. " receipts", function()
			local state = fixture()
			state.ready()
			state.message("snapshot", malformed)
			assert_false(state.watch.pump())
			helpers.assert_nil(state.watch.snapshot())
		end)
	end

	helpers.it("does not admit a field without exact active native identity", function()
		local state = fixture()
		state.ready()
		state.message("snapshot", { active_scope = false })
		state.watch.pump()
		helpers.assert_nil(state.watch.snapshot())
		state.message("heartbeat")
		state.watch.pump()
		helpers.assert_nil(state.watch.snapshot(), "heartbeats cannot reopen an unknown focus")
	end)

	helpers.it("bounds malformed and overlong output without spinning", function()
		for _, value in ipairs({ "invalid-json\n", string.rep("x", 65537) }) do
			local state = fixture()
			state.ready()
			state.queue[#state.queue + 1] = value
			assert_false(state.watch.pump())
			helpers.assert_true(state.cancelled)
		end
	end)
end)





-- =========================================
-- =========================================
-- ======= 2/ Fresh Input Admission ========
-- =========================================
-- =========================================

helpers.describe("AT-SPI focus watcher: causal input barrier", function()
	helpers.it("reads a fresh role before collection even when no focus notification arrived", function()
		local state = fixture()
		state.ready()
		helpers.assert_eq(state.watch.snapshot().role, 61)
		state.answer, state.role, state.path = true, 40, "/field/password"
		local answer = state.watch.barrier()
		helpers.assert_eq(answer.role, 40, "admission cannot reuse the old ordinary snapshot")
		helpers.assert_eq(state.request, 1)
		helpers.assert_eq(state.started, 1, "freshness must not fork another helper")
	end)

	helpers.it("withholds on a short barrier timeout and refuses the previous request's delayed answer", function()
		local state = fixture()
		state.ready()
		helpers.assert_nil(state.watch.barrier())
		helpers.assert_true(state.now <= 1021, "input may not wait for the one-second probe deadline")
		state.message("snapshot")
		helpers.assert_nil(state.watch.barrier(), "a late earlier answer cannot authorize a later sample")
		helpers.assert_nil(state.watch.snapshot())
	end)

	helpers.it("admits an on-time native answer when the parent resumes after its deadline", function()
		local state = fixture()
		state.ready()
		state.on_pause = function()
			state.message("snapshot", { at_ms = 1005 })
			state.now = 1030
		end
		helpers.assert_eq(state.watch.barrier().role, 61)
		helpers.assert_eq(state.now, 1030, "the final drain must not wait again")
	end)

	helpers.it("refuses a matching native response emitted after the admission deadline", function()
		local state = fixture()
		state.ready()
		state.on_pause = function()
			state.message("snapshot", { at_ms = 1021.527 })
			state.now = 1030
		end
		helpers.assert_nil(state.watch.barrier())
		helpers.assert_nil(state.watch.snapshot())
	end)

	helpers.it("does not let a new heartbeat renew an expired on-time barrier answer", function()
		local state = fixture()
		state.ready()
		state.on_pause = function()
			state.message("snapshot", { at_ms = 1005 })
			state.now = 2500
			state.message("heartbeat")
		end
		helpers.assert_nil(state.watch.barrier())
		helpers.assert_nil(state.watch.snapshot())
	end)

	helpers.it("refuses an on-time queued answer after its native owner has exited", function()
		local state = fixture()
		state.ready()
		state.on_pause = function()
			state.message("snapshot", { at_ms = 1005 })
			state.now, state.running = 1030, false
		end
		helpers.assert_nil(state.watch.barrier())
		helpers.assert_true(state.cancelled)
	end)

	helpers.it("refuses an on-time queued answer when its native pipe ends before the final drain", function()
		local state = fixture()
		state.ready()
		state.on_pause = function()
			state.message("snapshot", { at_ms = 1005 })
			state.now, state.eof = 1030, true
		end
		helpers.assert_nil(state.watch.barrier())
		helpers.assert_true(state.cancelled)
	end)

	helpers.it("keeps a later malformed native frame fatal during the final bounded drain", function()
		local state = fixture()
		state.ready()
		state.on_pause = function()
			state.message("snapshot", { at_ms = 1005 })
			state.queue[#state.queue + 1] = "invalid-json\n"
			state.now = 1030
		end
		helpers.assert_nil(state.watch.barrier())
		helpers.assert_true(state.cancelled)
	end)

	helpers.it("retains a newer unknown verdict after an on-time queued ordinary answer", function()
		local state = fixture()
		state.ready()
		state.on_pause = function()
			state.message("snapshot", { at_ms = 1005 })
			state.now = 1030
			state.message("unknown")
		end
		helpers.assert_nil(state.watch.barrier())
		helpers.assert_nil(state.watch.snapshot())
	end)

	helpers.it("resets logical text and closes metrics on a same-window programmatic password", function()
		local state = fixture()
		local epoch, secure, resets = 0, true, 0
		local detector = {
			invalidateFocus = function() epoch = epoch + 1; secure = true; return epoch end,
			publishFocus = function(role, requested) if requested ~= epoch then return false end; secure = role == 40; return true end,
			isSecureField = function() return secure end,
		}
		local metric_secure = true
		local guard = Guard.new({ watch = state.watch, detector = detector,
			keylogger = { set_secure_field = function(value) metric_secure = value end },
			now_ms = function() return state.now end, reset_text = function() resets = resets + 1 end })
		state.ready()
		state.answer = true
		assert_false(guard.blocks_text())
		assert_false(metric_secure)
		local before = resets
		state.role, state.path = 40, "/field/password"
		helpers.assert_true(guard.blocks_text())
		helpers.assert_true(metric_secure)
		helpers.assert_true(resets > before)
		state.role, state.path = 61, "/field/two"
		assert_false(guard.blocks_text())
		assert_false(metric_secure)
	end)
end)





-- =======================================
-- =======================================
-- ======= 3/ Physical Retirement ========
-- =======================================
-- =======================================

helpers.describe("AT-SPI focus watcher: native lifecycle", function()
	helpers.it("distinguishes initial no-writer EOF from authority loss after a receipt", function()
		local state = fixture()
		state.eof = true
		helpers.assert_true(state.watch.start())
		assert_false(state.watch.pump())
		helpers.assert_nil(state.cancelled)
		state.eof = false
		state.message("ready")
		state.message("snapshot")
		state.watch.pump()
		state.eof = true
		assert_false(state.watch.pump())
		helpers.assert_true(state.cancelled)
	end)

	helpers.it("closes on startup stall or worker death without borrowing old insecure state", function()
		local state = fixture()
		state.watch.start()
		state.now = state.now + 1001
		assert_false(state.watch.pump())
		helpers.assert_nil(state.cancelled, "an unready but live listener may still complete startup")
		state.message("ready")
		state.message("snapshot")
		helpers.assert_true(state.watch.pump())
		local other = fixture()
		other.ready()
		other.running = false
		assert_false(other.watch.pump())
		helpers.assert_nil(other.watch.snapshot())
	end)

	helpers.it("retains process and endpoint cleanup debt until physical acknowledgment", function()
		local state = fixture()
		state.ready()
		assert_false(state.watch.stop())
		helpers.assert_eq(state.closed, 0, "a still-running child owns its endpoints")
		assert_false(state.watch.is_settled())
		assert_false(state.watch.start())
		state.cleanup_refused = true
		state.retire()
		assert_false(state.watch.is_settled())
		state.cleanup_refused = false
		helpers.assert_true(state.watch.is_settled(), "a transient unlink refusal is retryable")
		state.running = true
		helpers.assert_true(state.watch.start())
		helpers.assert_eq(state.started, 2)
	end)
end)
