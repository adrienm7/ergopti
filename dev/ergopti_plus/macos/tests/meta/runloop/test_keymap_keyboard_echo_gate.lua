--- tests/meta/runloop/test_keymap_keyboard_echo_gate.lua

--- ==============================================================================
--- MODULE: Keymap keyboard echo gate (meta)
--- DESCRIPTION:
--- One explicit-tag gate protects every keyboard echo before LLM, shortcut or Backspace handling.
--- Source-scan guard split out of the audit-named regression file it came from.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Reads the one production unit containing a unique symbol.
--- @param selector string
--- @return string source
local function read_unit(selector)
	local src, err = helpers.read_driver_unit(selector)
	helpers.assert_not_nil(src, err)
	return src
end


--- Returns source from a declaration through the next public function.
--- @param source string
--- @param declaration string
--- @return string body
local function public_function_slice(source, declaration)
	local start_pos = source:find(declaration, 1, true)
	helpers.assert_not_nil(start_pos, declaration .. " must remain locatable")
	local next_pos = source:find("\nfunction M.", start_pos + #declaration, true)
	return source:sub(start_pos, next_pos or #source)
end


--- @param source string
--- @return string code
local function strip_line_comments(source)
	return (source:gsub("%-%-[^\n]*", ""))
end


--- @param source string
--- @param needle string
--- @return integer count
local function count_literal(source, needle)
	local count, cursor = 0, 1
	while true do
		local found = source:find(needle, cursor, true)
		if not found then return count end
		count = count + 1
		cursor = found + #needle
	end
end


--- @param source string
--- @return string raw
--- @return string wrapper
local function keydown_slices(source)
	local raw_pos = source:find("local function onKeyDownRaw%(")
	local raw_end = raw_pos and source:find("\nlocal function merge_returned_events", raw_pos, true)
	local wrapper_pos = source:find("local function onKeyDown%(e%)")
	local wrapper_end = wrapper_pos and source:find(
		"\ntap = eventtap.new({ eventtap.event.types.keyDown }, onKeyDown)", wrapper_pos, true)
	helpers.assert_not_nil(raw_pos, "raw keyDown handler must remain locatable")
	helpers.assert_not_nil(raw_end, "raw keyDown handler must remain independently bounded")
	helpers.assert_not_nil(wrapper_pos, "keyDown wrapper must remain locatable")
	helpers.assert_not_nil(wrapper_end, "keyDown wrapper must end at its eventtap binding")
	return source:sub(raw_pos, raw_end - 1), source:sub(wrapper_pos, wrapper_end - 1)
end


local PROTECTED_KEYBOARD_ROUTES = {
	"e:getKeyCode()",
	"LLMBridge.handle_llm_keys",
	"pcall(interceptor",
	"if (flags.cmd or flags.ctrl) and not ARROW_KEYCODES[keyCode] then",
	"if ARROW_KEYCODES[keyCode] then",
	"if keyCode == Keycodes.BACKSPACE then",
	"e:getCharacters(false)",
	"CoreState.buffer = CoreState.buffer .. chars",
}


--- Proves the class invariant across every human-input route in onKeyDownRaw.
--- Ordinary owned echoes and unreadable events exit before all entries; only an
--- exact live loopback is allowed through for the F16 control edge.
--- @param raw string
--- @param wrapper string
--- @return boolean valid
local function keyboard_echo_contract(raw, wrapper)
	local raw_code = strip_line_comments(raw)
	local wrapper_code = strip_line_comments(wrapper)
	if count_literal(raw_code .. wrapper_code, "EventProvenance.classify") ~= 1 then
		return false
	end
	if count_literal(wrapper_code, "EventProvenance.classify_with_fence") ~= 1 then
		return false
	end
	if count_literal(wrapper_code, "onKeyDownRaw") ~= 1 then return false end
	local classify_at = wrapper_code:find(
		'pcall%s*%(%s*EventProvenance%.classify_with_fence%s*,%s*e%s*,%s*"keymap"%s*%)')
	local raw_call_at = wrapper_code:find(
		'pcall%s*%(%s*onKeyDownRaw%s*,%s*e%s*,%s*provenance%s*,%s*provenance_status%s*%)')
	if not (classify_at and raw_call_at and classify_at < raw_call_at) then return false end

	local unreadable_at = raw_code:find(
		"if provenance_status == EventProvenance.STATUS_UNREADABLE then", 1, true)
	local owned_at = raw_code:find(
		"if provenance and not internal_loopback then return false end", 1, true)
	local loopback_at = raw_code:find("if internal_loopback then", 1, true)
	if not (unreadable_at and owned_at and loopback_at) then
		return false
	end
	for _, route in ipairs(PROTECTED_KEYBOARD_ROUTES) do
		local route_at = raw_code:find(route, 1, true)
		if route_at == nil or route_at <= unreadable_at or route_at <= owned_at then
			return false
		end
	end
	return true
end


--- @param body string M.classify source.
--- @return boolean valid
local function immutable_tag_owns_before_pid(body)
	local code = strip_line_comments(body)
	local tag_at = code:find('read_property%(event, USER_DATA_PROPERTY, "user%-data"%)')
	local claim_at = code:find("SyntheticInput.claim_tag%(tag, consumer_id%)")
	local pid_at = code:find('read_property%(event, SOURCE_PID_PROPERTY, "PID"%)')
	local owned_at = code:find("return claimed, M.STATUS_OWNED", 1, true)
	if not (tag_at and claim_at and pid_at and owned_at) then return false end
	if not (tag_at < claim_at and claim_at < pid_at and pid_at < owned_at) then return false end
	return code:sub(pid_at, owned_at - 1):find("return nil", 1, true) == nil
end

helpers.describe("keymap: one explicit-tag gate protects every keyboard echo (audit-v6-bug1)", function()
	helpers.it("classifies once and filters before LLM, shortcut, or Backspace handling", function()
		local src = read_unit("local function invalidate_observed_context")
		local raw, wrapper = keydown_slices(src)
		helpers.assert_true(keyboard_echo_contract(raw, wrapper),
			"one fenced classification must feed the raw handler, where unreadable and "
				.. "ordinary owned events exit before every enumerated human-input route")

		local owned_gate = "if provenance and not internal_loopback then return false end"
		local gate_at = raw:find(owned_gate, 1, true)
		helpers.assert_not_nil(gate_at, "the owned-gate sensitivity mutation needs the real gate")
		for _, route in ipairs(PROTECTED_KEYBOARD_ROUTES) do
			local mutant = raw:sub(1, gate_at - 1) .. route .. "\n" .. raw:sub(gate_at)
			helpers.assert_true(not keyboard_echo_contract(mutant, wrapper),
				"the class guard must fail when a sibling route precedes provenance: " .. route)
		end

		local unreadable_gate =
			"if provenance_status == EventProvenance.STATUS_UNREADABLE then"
		local unreadable_at = raw:find(unreadable_gate, 1, true)
		helpers.assert_not_nil(unreadable_at,
			"the unreadable-gate sensitivity mutations need the real gate")
		for _, route in ipairs(PROTECTED_KEYBOARD_ROUTES) do
			local mutant = raw:sub(1, unreadable_at - 1)
				.. route .. "\n" .. raw:sub(unreadable_at)
			helpers.assert_true(not keyboard_echo_contract(mutant, wrapper),
				"the class guard must fail when unreadable input reaches a route: " .. route)
		end

		local duplicate_classifier_mutant = raw
			.. '\nlocal _ = EventProvenance.classify(e, "keymap")'
		helpers.assert_true(not keyboard_echo_contract(duplicate_classifier_mutant, wrapper),
			"the class guard must fail if the raw handler classifies the event twice")
	end)

	helpers.it("the shared adapter makes immutable user-data authoritative before PID diagnostics", function()
		local src = read_unit("local function report_read_failure")
		local body = public_function_slice(src, "function M.classify(")
		helpers.assert_true(immutable_tag_owns_before_pid(body),
			"tag membership must establish STATUS_OWNED before PID is read, and PID must "
				.. "have no path that downgrades ownership")

		local owned_return = "return claimed, M.STATUS_OWNED"
		local return_at = body:find(owned_return, 1, true)
		helpers.assert_not_nil(return_at, "the PID-authority mutation needs the owned return")
		local pid_authority_mutant = body:sub(1, return_at - 1)
			.. "if source_pid ~= CURRENT_PROCESS_ID then return nil, M.STATUS_FOREIGN end\n\t"
			.. body:sub(return_at)
		helpers.assert_true(not immutable_tag_owns_before_pid(pid_authority_mutant),
			"the adapter guard must fail if PID can override immutable tag ownership")
	end)

end)
