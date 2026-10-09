--- adapters/caps_word.lua

--- ==============================================================================
--- MODULE: CapsWord Native Semantic Owner
--- DESCRIPTION:
--- Joins original native layout/chord receipts. A Unicode conversion requests
--- text, never proves the current native key/modifier output. Unsupported AltGr
--- output chords refuse until the chord owner can represent them explicitly.
--- ==============================================================================

local M = {}
local Layout = require("adapters.keyboard_layout")
local Capture = require("adapters.xkb_capture")
local owners = setmetatable({}, { __mode = "k" })
local ports = { plan = Layout.plan, plan_current = Layout.plan_current,
	inverse = Capture.inverse_table, inverse_current = Capture.inverse_current,
	chords = Capture.chord_sources, view = Capture.chord_source_view,
	current = Capture.chord_source_current, caps = Capture.caps_locked,
	text = Capture.peek_text, output = Capture.capture_chord_output,
	output_current = Capture.chord_output_current, output_occurrence = Capture.with_chord_output }

local function exports_current()
	return package.loaded["adapters.keyboard_layout"] == Layout
		and package.loaded["adapters.xkb_capture"] == Capture
		and Layout.plan == ports.plan and Layout.plan_current == ports.plan_current
		and Capture.inverse_table == ports.inverse and Capture.inverse_current == ports.inverse_current
		and Capture.chord_sources == ports.chords and Capture.chord_source_view == ports.view
		and Capture.chord_source_current == ports.current and Capture.caps_locked == ports.caps
		and Capture.peek_text == ports.text
		and Capture.capture_chord_output == ports.output and Capture.chord_output_current == ports.output_current
		and Capture.with_chord_output == ports.output_occurrence
end

--- Captures only the genuine desktop-qualified original inverse source.
--- @return table|nil Opaque persistent semantic source owner.
function M.capture()
	if not exports_current() then return nil end
	local built, _, inverse = ports.inverse(true)
	if not built or not inverse or not ports.inverse_current(inverse)
		or not exports_current() then return nil end
	local authority = {}; owners[authority] = { inverse = inverse }
	return authority
end

--- Rejoins the persistent original before callbacks and native output.
--- @param authority table Original opaque owner.
--- @return boolean
function M.current(authority)
	local owner = owners[authority]
	if not owner or getmetatable(authority) ~= nil or next(authority) ~= nil
		or not exports_current() then return false end
	local ok, current = pcall(ports.inverse_current, owner.inverse)
	return ok and current == true and exports_current()
end

--- Selects observed native case, including CapsLock/Shift inversion, without guessing.
--- @param authority table Persistent original semantic owner.
--- @param text string Independently requested uppercase text.
--- @return table|nil Plan; unsupported or replaced sources refuse.
--- @return function|nil Original per-character plan/source guard.
--- @return function|nil Private synchronous output-occurrence wrapper; never output rights.
function M.plan(authority, text)
	if not M.current(authority) then return nil end
	local steps, _, plan_receipt = ports.plan(text)
	if not steps or not plan_receipt or not M.current(authority)
		or not ports.plan_current(plan_receipt) then return nil end
	local requests = {}
	for _, step in ipairs(steps) do
		for _, role in ipairs(step.mods) do
			if role ~= "shift" then return nil end
		end
		requests[#requests + 1] = { code = step.keycode, mods = { shift = false } }
		requests[#requests + 1] = { code = step.keycode, mods = { shift = true } }
	end
	local caps = ports.caps()
	if type(caps) ~= "boolean" then return nil end
	local receipt = ports.chords(requests)
	local view = receipt and ports.view(receipt)
	if not view or not M.current(authority) or not ports.plan_current(plan_receipt)
		or not ports.current(receipt) or ports.caps() ~= caps then return nil end
	local characters = {}
	for character in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		characters[#characters + 1] = character
	end
	if #characters ~= #steps then return nil end
	local plan = {}
	for index, character in ipairs(characters) do
		local chosen
		for offset = 1, 4 do
			local row = view.chords[(index - 1) * 4 + offset]
			if row and row.code == steps[index].keycode and row.caps == caps
				and not row.dead and row.identity == character then
				chosen = { keycode = row.code, mods = row.mods.shift and { "shift" } or {} }
				break
			end
		end
		if not chosen then return nil end
		plan[#plan + 1] = chosen
	end
	local output_owner
	if type(ports.output) == "function" and type(ports.output_current) == "function"
		and type(ports.output_occurrence) == "function" then
		output_owner = ports.output(receipt)
		if not output_owner then return nil end
	end
	local function current()
		return M.current(authority) and ports.plan_current(plan_receipt, true)
			and (output_owner and ports.output_current(output_owner) or not output_owner and ports.current(receipt))
			and ports.caps() == caps and exports_current()
	end
	if not current() then return nil end
	local function occurrence(code, value, dispatch, acknowledged)
		if not output_owner or not current() then return false end
		return ports.output_occurrence(output_owner, code, value, dispatch, function()
			return current() and acknowledged() == true and current()
		end) == true and current()
	end
	-- Lookup-only software providers still exercise their original assertions;
	-- they receive no output occurrence port or Hook emission admission.
	return plan, current, output_owner and occurrence or nil
end

return M
