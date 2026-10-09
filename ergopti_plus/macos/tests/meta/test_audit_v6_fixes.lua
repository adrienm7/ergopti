--- tests/meta/test_audit_v6_fixes.lua

--- ==============================================================================
--- MODULE: Audit V6 Regression Guards
--- DESCRIPTION:
--- Structural class guards for the macOS V6 fixes after synthetic ownership
--- moved to immutable SyntheticInput tags. Backspace, Cmd+V, and character echoes
--- now share one early provenance gate; paste emitters execute inside the same
--- explicit replacement transaction as their deletes and text; clipboard save
--- and restore preserve every UTI rather than only plain text.
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
	"if flags.cmd or flags.ctrl then",
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


helpers.describe("keymap paste: Cmd+V inherits the replacement transaction (audit-v6-bug2)", function()
	helpers.it("the paste helper emits Cmd+V through SyntheticInput", function()
		local src = read_unit("local function invalidate_ignored_win_cache")
		local start_pos = src:find("local function perform_paste%(value%)")
		local next_pos = src:find("\nfunction M.emit_tokens", start_pos or 1, true)
		helpers.assert_not_nil(start_pos, "perform_paste must remain locatable")
		local body = src:sub(start_pos, next_pos or #src)
		local count = 0
		for _ in body:gmatch("SyntheticInput%.emit_key_stroke") do count = count + 1 end
		helpers.assert_eq(count, 1,
			"the paste path must produce exactly one explicitly tagged Cmd+V pair")
		helpers.assert_true(
			body:find('SyntheticInput%.emit_key_stroke%({ "cmd" }, "v", 0%)') ~= nil,
			"the tagged pair must be the actual paste shortcut")
	end)

	helpers.it("the replacement owns its emitter from begin through seal", function()
		local src = read_unit("function M.try_terminator_expand")
		local body = public_function_slice(src, "function M.perform_text_replacement(")
		local begin_pos = body:find("SyntheticInput.begin", 1, true)
		local scope_pos = body:find("SyntheticInput.with_transaction", 1, true)
		local emit_pos = body:find("return emit_action()", 1, true)
		local seal_pos = body:find("SyntheticInput.seal", 1, true)
		helpers.assert_true(begin_pos and scope_pos and emit_pos and seal_pos,
			"begin, transaction scope, real emitter, and seal must all remain present")
		helpers.assert_true(begin_pos < scope_pos and scope_pos < emit_pos and emit_pos < seal_pos,
			"delete, Cmd+V, and text metadata must belong to one ordered replacement")
	end)

	helpers.it("the expander never reconstructs ownership from paste metadata", function()
		local src = read_unit("function M.try_terminator_expand")
		helpers.assert_true(src:find("take_paste_ops", 1, true) == nil,
			"compatibility metadata must not become a second ownership channel")
	end)
end)


helpers.describe("modules/keymap/utils.lua: clipboard preserves non-text data (audit-v6-bug3)", function()
	helpers.it("clipboard save uses readAllData() instead of getContents()", function()
		local src = read_unit("local function invalidate_ignored_win_cache")
		helpers.assert_true(
			src:find("hs.pasteboard.readAllData()", 1, true) ~= nil,
			"paste must save images, RTF, files, and text")
	end)

	helpers.it("clipboard restore uses writeAllData() instead of setContents()", function()
		local src = read_unit("local function invalidate_ignored_win_cache")
		helpers.assert_true(
			src:find("hs.pasteboard.writeAllData", 1, true) ~= nil,
			"paste must restore every saved clipboard UTI")
	end)

	helpers.it("plain-text clipboard reads are absent from paste save paths", function()
		local src = read_unit("local function invalidate_ignored_win_cache")
		helpers.assert_true(
			src:find("_paste_saved_original = hs.pasteboard.getContents()", 1, true) == nil,
			"the original clipboard must never be truncated to plain text")
	end)

	helpers.it("the asynchronous restore retains writeAllData", function()
		local src = read_unit("local function invalidate_ignored_win_cache")
		local timer_pos = src:find("local function schedule_paste_restore", 1, true)
		local timer_end = timer_pos and src:find(
			"\n--- Retains autonomous recovery after a restore failure", timer_pos, true)
		helpers.assert_not_nil(timer_pos,
			"the clipboard restore scheduler transaction must remain present")
		helpers.assert_not_nil(timer_end,
			"the clipboard restore scheduler transaction must remain independently bounded")
		local restore = src:sub(timer_pos, timer_end - 1)
		helpers.assert_true(restore:find("TimerScheduler.after", 1, true) ~= nil,
			"the restore must use the retained scheduler owner, not an untracked native timer")
		helpers.assert_true(restore:find("timer_committed ~= true", 1, true) ~= nil,
			"an uncommitted restore timer must be rejected before publication")
		helpers.assert_true(
			restore:find("_paste_pending_timer = timer_or_error", 1, true) ~= nil,
			"the exact committed timer must remain retained until callback or cancellation")
		helpers.assert_true(restore:find("restore_owned_clipboard", 1, true) ~= nil,
			"the timer must delegate to the retained exact-restore helper")
		local helper_pos = src:find("local function restore_owned_clipboard", 1, true)
		local helper = helper_pos and src:sub(helper_pos, helper_pos + 900) or ""
		helpers.assert_true(helper:find("writeAllData", 1, true) ~= nil,
			"the shared restore helper must preserve every clipboard UTI")
		helpers.assert_true(helper:find("restore_result ~= true", 1, true) ~= nil,
			"a false/nil native restore must retain ownership for retry")
	end)
end)
