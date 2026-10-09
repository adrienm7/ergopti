--- tests/unit/adapters/test_caps_word_output_custody.lua

--- Actual XKB receipt consumer with explicitly modeled backend and ACK callbacks.
--- No desktop, kernel, output or physical authority is acquired by this suite.
local h = require("tests.helpers")

local function fixture(body)
	local saved = package.loaded["adapters.xkb_capture"]
	local capture = h.load_module("adapters.xkb_capture")
	local s = { observed = true }
	local backend = {
		create = function() return { identity = "controlled-output-map", groups = 1 } end,
		destroy = function() end, key_sym = function() return nil end, key_utf8 = function() return nil end,
		compose_feed = function() end, compose_status = function() return "nothing" end,
		capture_group = function() return 0 end,
		source_group = function() return 0, 1, function() return s.observed end end,
		update_key = function() if s.on_update then s.on_update() end end,
		chord_source_identity = function() return { group = 0, generation = 1, locked_mods = 0,
			locked_generation = 0, input_generation = 0, mods = 0, base_mods = 0, latched_mods = 0,
			observed_current = function() return s.observed end } end,
		chord_sources = function(_, requests)
			local rows = {}
			for _, request in ipairs(requests) do for _, caps in ipairs({ false, true }) do
				rows[#rows + 1] = { code = request.code, mods = request.mods, caps = caps, identity = "A", dead = false }
			end end
			return rows
		end }
	capture._set_backend(backend); assert(capture.load("controlled-output-map"))
	local physical = assert(capture.chord_sources({ { code = 30, mods = { shift = true } } }))
	local owner = assert(capture.capture_chord_output(physical))
	local ok, failure = pcall(body, capture, s, owner, physical)
	capture._reset_backend(); package.loaded["adapters.xkb_capture"] = saved
	if not ok then error(failure, 0) end
end

h.describe("CapsWord output occurrence custody software controls", function()
	h.it("advances only a distinct output owner across original synchronized captures", function()
		fixture(function(c, _, owner, physical)
			for _, row in ipairs({ { 42, 1 }, { 30, 1 }, { 30, 0 }, { 42, 0 } }) do
				h.assert_true(c.with_chord_output(owner, row[1], row[2], function(process)
					local _, _, reason = process(row[1], row[2]); h.assert_nil(reason)
					h.assert_true(c.chord_output_current(owner), "provisional own occurrence is current")
				end, function() return true end), "modeled ACK closes exact occurrence")
			end
			h.assert_true(c.chord_output_current(owner))
			h.assert_true(not c.chord_source_current(physical), "physical receipt retains its original epoch")
		end)
	end)
	h.it("no-capture aggregation advances no epoch and preserves original physical receipt", function()
		fixture(function(c, _, owner, physical)
			h.assert_true(c.with_chord_output(owner, 42, 1, function() end, function() return true end))
			h.assert_true(c.chord_source_current(physical))
		end)
	end)
	for _, fault in ipairs({ "foreign-before", "foreign-during", "foreign-ack", "wrong-code", "wrong-value", "duplicate", "dispatch-error", "ack-false", "ack-error", "ack-reentry", "source", "session", "process-export", "capture-reentry" }) do
		h.it("refuses " .. fault .. " without borrowing physical currency", function()
			fixture(function(c, s, owner)
				if fault == "foreign-before" then c.process(31, 1) end
				if fault == "process-export" then c.process = function() end end
				if fault == "capture-reentry" then s.on_update = function() s.on_update = nil; c.process(31, 1) end end
				local accepted = c.with_chord_output(owner, 42, 1, function(process)
					if fault == "dispatch-error" then error("modeled dispatch failure") end
					process(fault == "wrong-code" and 31 or 42, fault == "wrong-value" and 0 or 1)
					if fault == "foreign-during" then c.process(31, 1) end
					if fault == "duplicate" then process(42, 1) end
					if fault == "source" then s.observed = false end
					if fault == "session" then c.reset_state() end
				end, function()
					if fault == "foreign-ack" then c.process(31, 1) end
					if fault == "ack-error" then error("modeled ACK error") end
					if fault == "ack-reentry" then
						h.assert_true(not c.with_chord_output(owner, 30, 1, function() error("nested dispatch forbidden") end, function() return true end))
					end
					return fault ~= "ack-false"
				end)
				h.assert_true(not accepted, "foreign or failed occurrence cannot advance original output owner")
				h.assert_true(not c.chord_output_current(owner), "refused owner supplies no following output currency")
			end)
		end)
	end
	h.it("copied receipts and absent native original cannot invoke dispatch", function()
		fixture(function(c)
			h.assert_nil(c.capture_chord_output({}))
			h.assert_true(not c.with_chord_output({}, 42, 1, function() error("unowned dispatch") end, function() return true end))
		end)
	end)
	h.it("retained process callback cannot borrow a completed occurrence", function()
		fixture(function(c, _, owner)
			local retained
			h.assert_true(c.with_chord_output(owner, 42, 1, function(process)
				retained = process; process(42, 1)
			end, function() return true end))
			local _, _, reason = retained(42, 1)
			h.assert_eq(reason, "owned-output-capture-refused")
			h.assert_true(c.chord_output_current(owner), "stale rejected callback emitted no transition")
		end)
	end)
end)
return true
