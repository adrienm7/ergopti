--- tests/unit/adapters/test_modifier_broker_reentrant.lua

--- Actual Writer/Reader/Hook inverse ACKs retain immutable prior consumer controls.
local h = require("tests.helpers")
local F = require("tests.support.modifier_broker_fixture")
local function broker(s) return require("adapters.modifier_broker").for_channel(s.writer) end
local function output(s)
	return h.load_module("modules.hotstrings.output_transaction").new(s.writer)
end

h.describe("original retirement inside acknowledged synthetic output", function()
	h.it("reconciles borrowed Shift after the chord key up and admits a settled successor", function()
		local fired = false
		F.with_session({ after_sync = function(s, code, value)
			if code == 30 and value == 1 and not fired then
				fired = true; s.queue("a", 42, 0, 2); s.pump()
			end
		end }, function(s)
			s.queue("a", 42, 1, 1); s.pump()
			local C = h.load_module("modules.gestures.combo_emitter")
			h.assert_true(C.press_codes({ 42 }, { 30 }, "queued original UP"))
			h.assert_true(fired)
			h.assert_eq(s.rows, { { 42, 1 }, { 30, 1 }, { 30, 0 }, { 42, 0 } })
			h.assert_eq(broker(s).view().busy, false); h.assert_eq(broker(s).has_debt(), false)
			h.assert_true(s.hook.isRunning())
			h.assert_true(C.press_codes({ 56 }, { 30 }, "successor"))
			h.assert_eq(s.view().down, {})
		end)
	end)

	h.it("never restores a suspended Shift after its actual original source releases", function()
		local fired = false
		F.with_session({ after_sync = function(s, code, value)
			if code == 45 and value == 1 and not fired then
				fired = true; s.queue("a", 42, 0, 2); s.pump()
			end
		end }, function(s)
			s.queue("a", 42, 1, 1); s.pump()
			local tx = output(s); h.assert_true(tx.neutralize({ 42 }))
			h.assert_true(tx.emit(45, 1)); h.assert_true(tx.emit(45, 0))
			local result = tx.finish()
			h.assert_true(fired); h.assert_true(result.ok); h.assert_true(result.cleanup_ok)
			h.assert_eq(s.rows, { { 42, 1 }, { 42, 0 }, { 45, 1 }, { 45, 0 } })
			h.assert_eq(s.view().down, {}); h.assert_eq(broker(s).view().busy, false)
			h.assert_eq(next(broker(s).view().owners), nil)
		end)
	end)

	h.it("restores only the remaining suspended source and acknowledges its final UP", function()
		local fired = false
		F.with_session({ after_sync = function(s, code, value)
			if code == 45 and value == 1 and not fired then
				fired = true; s.queue("a", 42, 0, 3); s.pump()
			end
		end }, function(s)
			s.queue("a", 42, 1, 1); s.queue("b", 42, 1, 2); s.pump()
			local tx = output(s); h.assert_true(tx.neutralize({ 42 }))
			h.assert_true(tx.emit(45, 1)); h.assert_true(tx.emit(45, 0)); h.assert_true(tx.finish().ok)
			h.assert_eq(s.rows, { { 42, 1 }, { 42, 0 }, { 45, 1 }, { 45, 0 }, { 42, 1 } })
			s.queue("b", 42, 0, 4); s.pump()
			h.assert_eq(s.view().down, {}); h.assert_eq(s.rows[#s.rows], { 42, 0 })
		end)
	end)

	h.it("a refused queued native UP aborts Combo and retires its exact channel", function()
		local fired = false
		F.with_session({ after_sync = function(s, code, value)
			if code == 30 and value == 1 and not fired then
				fired = true; s.queue("a", 42, 0, 2); s.pump()
			end
		end, fail_sync = function(code, value) return code == 42 and value == 0 end }, function(s)
			s.queue("a", 42, 1, 1); s.pump()
			local C = h.load_module("modules.gestures.combo_emitter")
			h.assert_eq(C.press_codes({ 42 }, { 30 }, "inverse ACK refused"), false)
			h.assert_true(fired); h.assert_true(broker(s).has_debt())
			h.assert_eq(s.hook.isRunning(), false); h.assert_eq(s.writer.is_open(), false)
			h.assert_eq(broker(s).begin(), nil)
		end)
	end)

	h.it("output sessions reject repeat values before any native or ownership mutation", function()
		F.with_session(nil, function(s)
			local session = assert(broker(s).begin()); h.assert_true(session.emit(30, 1))
			h.assert_eq(session.emit(30, 2), false)
			h.assert_eq(s.rows, { { 30, 1 } }); h.assert_eq(broker(s).view().down, { 30 })
			h.assert_true(session.emit(30, 0)); h.assert_true(session.finish())
			h.assert_eq(session.restore(42), false)
		end)
	end)

	h.it("unfinished synthetic custody reports retained busy state and debt", function()
		F.with_session(nil, function(s)
			local session = assert(broker(s).begin()); h.assert_true(session.emit(30, 1))
			h.assert_eq(session.finish(), false); h.assert_true(broker(s).has_debt())
			h.assert_eq(broker(s).view().busy, true); h.assert_eq(broker(s).begin(), nil)
			h.assert_true(broker(s).retire()); h.assert_eq(s.writer.is_open(), false)
		end)
	end)

	h.it("stale or refused initial output views return no custody instead of throwing", function()
		local Custody = require("input.modifier_custody")
		for _, view in ipairs({ function() return nil end, function() error("refused") end,
			function() return { down = { unexpected = true }, write_epoch = 0 } end }) do
			local ok, result = pcall(Custody.new, { output_view = view }, {})
			h.assert_true(ok); h.assert_eq(result, nil)
		end
	end)
end)
