--- tests/unit/modules/keylogger/test_virtual_synthetic_telemetry.lua

--- ==============================================================================
--- MODULE: Virtual synthetic telemetry source regression tests
--- DESCRIPTION: Clipboard insertion has no per-character OS events. The
--- keylogger must therefore retain logical synthetic work for a post-eventtap
--- drain, then discard tagged physical echoes through exact event provenance.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture_module = require("tests.support.keylogger_provenance_fixture")


--- @param selector string
--- @return string source
local function read_unit(selector)
	local src, err = helpers.read_driver_unit(selector)
	helpers.assert_not_nil(src, err)
	return src
end


--- @param source string
--- @param declaration string
--- @param next_declaration string
--- @return string body
local function function_slice(source, declaration, next_declaration)
	local start_pos = source:find(declaration, 1, true)
	helpers.assert_not_nil(start_pos, declaration .. " must remain locatable")
	local end_pos = source:find(next_declaration, start_pos + #declaration, true)
	helpers.assert_not_nil(end_pos, declaration .. " must remain independently bounded")
	return source:sub(start_pos, end_pos - 1)
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


--- @param handle_key string
--- @return boolean valid
local function keylogger_uses_fenced_tag_ownership(handle_key)
	local code = handle_key:gsub("%-%-[^\n]*", "")
	if count_literal(code, "EventProvenance.classify_with_fence") ~= 1 then return false end
	local classify_at = code:find(
		'EventProvenance%.classify_with_fence%s*%(%s*event_obj%s*,%s*"keylogger"%s*%)')
	local reject_at = code:find("if provenance then", 1, true)
	local unreadable_at = code:find(
		"if provenance_status == EventProvenance.STATUS_UNREADABLE then", 1, true)
	local aggregate_at = code:find("if not CoreState.is_enabled then return end", 1, true)
	if not (classify_at and reject_at and unreadable_at and aggregate_at) then return false end
	if not (classify_at < reject_at and reject_at < unreadable_at
		and unreadable_at < aggregate_at) then
		return false
	end
	local owned_block = code:sub(reject_at, unreadable_at - 1)
	local unreadable_block = code:sub(unreadable_at, aggregate_at - 1)
	return owned_block:find("return", 1, true) ~= nil
		and unreadable_block:find("return", 1, true) ~= nil
end


--- @param classify_body string
--- @return boolean valid
local function adapter_tag_is_authoritative(classify_body)
	local code = classify_body:gsub("%-%-[^\n]*", "")
	local tag_at = code:find('read_property%(event, USER_DATA_PROPERTY, "user%-data"%)')
	local claim_at = code:find("SyntheticInput.claim_tag%(tag, consumer_id%)")
	local pid_at = code:find('read_property%(event, SOURCE_PID_PROPERTY, "PID"%)')
	local owned_at = code:find("return claimed, M.STATUS_OWNED", 1, true)
	if not (tag_at and claim_at and pid_at and owned_at) then return false end
	if not (tag_at < claim_at and claim_at < pid_at and pid_at < owned_at) then return false end
	return code:sub(pid_at, owned_at - 1):find("return nil", 1, true) == nil
end


helpers.describe("keylogger: virtual synthetic telemetry for clipboard output", function()
	local function source()
		return read_unit("function M.notify_synthetic")
	end

	helpers.it("records logical chars and rejects tagged OS echoes before aggregation", function()
		local fixture = fixture_module.load_keylogger()
		fixture.state.is_enabled = true
		fixture.keylogger.notify_synthetic("xy", "hotstring", 0, "case", "xy", false)
		helpers.assert_eq(#fixture.flushes, 0,
			"logical expansion must not run before the originating eventtap returns")
		fixture.drain()
		helpers.assert_eq(#fixture.flushes, 1)
		helpers.assert_eq(#fixture.flushes[1].events, 2)
		helpers.assert_eq(fixture.flushes[1].events[1][1], "x")
		helpers.assert_eq(fixture.flushes[1].events[2][1], "y")

		local keylogger_source = source()
		local handle_key = function_slice(keylogger_source, "local function handle_key(event_obj)",
			"\nfunction M.set_options")
		helpers.assert_true(keylogger_uses_fenced_tag_ownership(handle_key),
			"keylogger keyboard events must classify_with_fence exactly once, then reject "
				.. "owned and unreadable input before every normal aggregation gate")
		helpers.assert_true(keylogger_source:find("discard = true", 1, true) == nil,
			"mutable discard-queue telemetry must not regain synthetic authority")

		local classifier_mutant, replacements = handle_key:gsub(
			"EventProvenance%.classify_with_fence", "EventProvenance.classify", 1)
		helpers.assert_eq(replacements, 1,
			"the keylogger sensitivity mutation must replace the real fenced classifier")
		helpers.assert_true(not keylogger_uses_fenced_tag_ownership(classifier_mutant),
			"the keylogger guard must fail if the ordering fence is bypassed")

		local aggregation_mutant = "if not CoreState.is_enabled then return end\n" .. handle_key
		helpers.assert_true(not keylogger_uses_fenced_tag_ownership(aggregation_mutant),
			"the keylogger guard must fail if a sibling aggregation route precedes tag rejection")
	end)

	helpers.it("immutable user-data tags own telemetry; PID remains diagnostic", function()
		local provenance_source = read_unit("local function report_read_failure")
		local classify = function_slice(provenance_source, "function M.classify(",
			"\nfunction M.is_owned")
		helpers.assert_true(adapter_tag_is_authoritative(classify),
			"EventProvenance must claim the immutable user-data tag before reading PID, "
				.. "which may not downgrade STATUS_OWNED")

		local owned_return = "return claimed, M.STATUS_OWNED"
		local return_at = classify:find(owned_return, 1, true)
		helpers.assert_not_nil(return_at, "the PID-authority mutation needs the owned return")
		local pid_authority_mutant = classify:sub(1, return_at - 1)
			.. "if source_pid ~= CURRENT_PROCESS_ID then return nil, M.STATUS_FOREIGN end\n\t"
			.. classify:sub(return_at)
		helpers.assert_true(not adapter_tag_is_authoritative(pid_authority_mutant),
			"the telemetry guard must fail if PID becomes synthetic authority")
	end)

	helpers.it("drains a virtual paste without waiting for another key event", function()
		local fixture = fixture_module.load_keylogger()
		fixture.state.is_enabled = true
		fixture.keylogger.notify_synthetic("paste", "hotstring", 0, "case", "", false)
		helpers.assert_eq(#fixture.flushes, 0)
		fixture.drain()
		helpers.assert_eq(#fixture.flushes, 1,
			"the retained builder must make clipboard output independently drainable")
		helpers.assert_eq(#fixture.flushes[1].events, 5)
	end)

	helpers.it("does not add a second LLM manifest trigger", function()
		local text = source()
		helpers.assert_true(text:find("LogManager.increment_manifest_stat(target_app, \"llm_triggers\")", 1, true) == nil,
			"the synthetic typing burst must remain the sole llm_triggers source")
	end)
end)
