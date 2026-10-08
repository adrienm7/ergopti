--- tests/unit/adapters/test_caps_word_semantic_owner.lua

--- ==============================================================================
--- MODULE: CapsWord Semantic Join Software Tests
--- DESCRIPTION:
--- Controlled provider observations test original-receipt selection and rejection.
--- These adapters acquire no native source/output and grant no native qualification.
--- ==============================================================================

local h = require("tests.helpers")

local function session(body)
	local names = { "adapters.caps_word", "adapters.keyboard_layout", "adapters.xkb_capture" }
	local saved = {}; for _, name in ipairs(names) do saved[name] = { package.loaded[name] } end
	local s = { caps = false, source = true, plan_ok = true, chord_ok = true, calls = 0 }
	local inverse, plan, chord = {}, {}, {}
	local layout = {
		plan = function(text)
			s.calls = s.calls + 1
			if s.on_plan then s.on_plan(s) end
			return { { keycode = 30, mods = s.altgr and { "altgr" } or { "shift" } } }, nil, plan
		end,
		plan_current = function(receipt) return receipt == plan and s.plan_ok end }
	local capture = {
		inverse_table = function(native) assert(native == true); return {}, nil, inverse end,
		inverse_current = function(receipt) return receipt == inverse and s.source end,
		caps_locked = function() return s.caps end,
		peek_text = function() return "a" end,
		chord_sources = function(requests)
			h.assert_eq(#requests, 2, "each candidate is independently probed with and without Shift")
			h.assert_true(not requests[1].mods.shift and requests[2].mods.shift, "observed alternatives do not guess Caps inversion")
			if s.on_chords then s.on_chords(s) end
			return chord
		end,
		chord_source_current = function(receipt) return receipt == chord and s.chord_ok end,
		chord_source_view = function(receipt)
			assert(receipt == chord)
			return { chords = {
				{ code = 30, caps = false, mods = {}, identity = "a", dead = false },
				{ code = 30, caps = true, mods = {}, identity = "A", dead = false },
				{ code = 30, caps = false, mods = { shift = true }, identity = s.wrong_identity and "!" or "A", dead = s.dead == true },
				{ code = 30, caps = true, mods = { shift = true }, identity = "a", dead = false } } }
		end }
	s.layout, s.capture = layout, capture
	package.loaded["adapters.keyboard_layout"], package.loaded["adapters.xkb_capture"] = layout, capture
	package.loaded["adapters.caps_word"] = nil
	local ok, failure = pcall(function()
		s.adapter = require("adapters.caps_word")
		s.owner = assert(s.adapter.capture())
		body(s)
	end)
	for _, name in ipairs(names) do package.loaded[name] = saved[name][1] end
	if not ok then error(failure, 0) end
end

h.describe("CapsWord original native semantic join software controls", function()
	h.it("selects captured software-provider Shift for uppercase when CapsLock is off", function()
		session(function(s)
			local plan, current = s.adapter.plan(s.owner, "A")
			h.assert_eq(plan, { { keycode = 30, mods = { "shift" } } }, "handwritten Caps-off observed expectation")
			h.assert_true(current(), "original software provider receipt remains current")
		end)
	end)
	h.it("selects captured software-provider no-Shift under CapsLock", function()
		session(function(s)
			s.caps = true
			local plan = s.adapter.plan(s.owner, "A")
			h.assert_eq(plan, { { keycode = 30, mods = {} } }, "handwritten Caps-on expectation avoids inversion")
		end)
	end)
	for _, fault in ipairs({ "source", "plan_ok", "chord_ok" }) do
		h.it("rejects original " .. fault .. " withdrawal", function()
			session(function(s) s[fault] = false; h.assert_nil(s.adapter.plan(s.owner, "A"), "withdrawal cannot return a semantic plan") end)
		end)
	end
	for _, fault in ipairs({ "altgr", "wrong_identity", "dead" }) do
		h.it("refuses " .. fault .. " without inferred uppercase", function()
			session(function(s) s[fault] = true; h.assert_nil(s.adapter.plan(s.owner, "A"), "unqualified chord refuses") end)
		end)
	end
	h.it("rejects CapsLock change during the original chord observation", function()
		session(function(s)
			s.on_chords = function(state) state.caps = true end
			h.assert_nil(s.adapter.plan(s.owner, "A"), "lock source changed before publication")
		end)
	end)
	for _, member in ipairs({ "plan", "plan_current" }) do
		h.it("rejects A-to-B replacement of original layout " .. member, function()
			session(function(s)
				s.layout[member] = function() error("replacement cannot supply semantics") end
				h.assert_nil(s.adapter.plan(s.owner, "A"), "original exported provider changed")
				h.assert_eq(s.calls, 0, "replaced getter was not called")
			end)
		end)
	end
	for _, member in ipairs({ "inverse_table", "inverse_current", "chord_sources", "chord_source_view", "chord_source_current", "caps_locked", "peek_text" }) do
		h.it("rejects A-to-B replacement of original capture " .. member, function()
			session(function(s)
				s.capture[member] = function() error("replacement cannot supply semantics") end
				h.assert_nil(s.adapter.plan(s.owner, "A"), "original capture provider changed")
				h.assert_eq(s.calls, 0, "capture replacement grants no lookup")
			end)
		end)
	end
	h.it("rejects planner replacement inside the original semantic callback", function()
		session(function(s)
			s.on_plan = function(state) state.layout.plan = function() return {} end end
			h.assert_nil(s.adapter.plan(s.owner, "A"), "callback replacement refuses before chord or output")
		end)
	end)
	h.it("a complete plan loses currency on captured source withdrawal", function()
		session(function(s)
			local plan, current = s.adapter.plan(s.owner, "A"); h.assert_not_nil(plan)
			s.source = false; h.assert_true(not current(), "original source loss fences native delivery")
		end)
	end)
	h.it("copied semantic owner cannot join a genuine receipt", function()
		session(function(s) h.assert_nil(s.adapter.plan({}, "A"), "detached tables have no receipt") end)
	end)
end)

return true
