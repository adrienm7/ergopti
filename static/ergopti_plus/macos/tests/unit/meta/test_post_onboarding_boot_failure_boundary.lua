--- tests/unit/meta/test_post_onboarding_boot_failure_boundary.lua

--- ==============================================================================
--- MODULE: Post-onboarding Boot Failure Boundary
--- DESCRIPTION:
--- Root init.lua cannot run in the unit harness. This mutation-sensitive source
--- guard proves that every synchronous fatal gate after the first input owner is
--- inside one xpcall whose failure requests the bounded controlled exit and then
--- returns from the root chunk. A bare top-level error in that interval otherwise
--- leaves a half-armed Hammerspoon process alive indefinitely.
--- ==============================================================================

local helpers = require("tests.helpers")

local ROOT_ANCHOR = "✅ Hammerspoon boot SUCCESSFUL."
local BOUNDARY_DECLARATION = "local function finish_boot_after_onboarding()"
local BOUNDARY_END = "end -- finish_boot_after_onboarding"
local FIRST_INPUT_OWNER = "local prestart_committed = StartupTransaction.run({"
local BOOT_SUCCESS = "✅ Hammerspoon boot SUCCESSFUL."
local BOUNDARY_CALL =
	"local post_onboarding_boot_ok, post_onboarding_boot_error = xpcall("
local FAILURE_GUARD = "if post_onboarding_boot_ok ~= true then"
local FAILURE_EXIT =
	"emergency_exit_after_runtime_failure(\"boot\", post_onboarding_boot_error)"
local BODY_FATAL = "error(\"VS Code caret bridge setup did not commit\")"


--- Removes quoted strings and line comments before executable-token scans.
--- @param line string Source line.
--- @return string code
local function executable_line(line)
	local code = line:gsub('"[^"\\]*(\\.[^"\\]*)*"', '""')
	code = code:gsub("'[^'\\]*(\\.[^'\\]*)*'", "''")
	return code:gsub("%-%-.*$", "")
end


--- Counts exact plain-text occurrences without pattern semantics.
--- @param source string Source string.
--- @param needle string Non-empty exact token.
--- @return number count
local function count_plain(source, needle)
	local count = 0
	local cursor = 1
	while true do
		local at = source:find(needle, cursor, true)
		if not at then return count end
		count = count + 1
		cursor = at + #needle
	end
end


--- Counts direct calls to the global error function in executable source.
--- Member calls such as Logger.error are diagnostics, not fatal gates.
--- @param source string Source string.
--- @return number count
local function count_bare_error_calls(source)
	local count = 0
	for line in (source .. "\n"):gmatch("([^\n]*)\n") do
		local code = executable_line(line)
		local cursor = 1
		while true do
			local at, finish = code:find("error%s*%(", cursor)
			if not at then break end
			local previous = at > 1 and code:sub(at - 1, at - 1) or ""
			if previous == "" or not previous:match("[%w_%.:]") then
				count = count + 1
			end
			cursor = finish + 1
		end
	end
	return count
end


--- Reports whether a source fragment contains executable tokens.
--- @param source string Source fragment.
--- @return boolean present
local function has_executable_code(source)
	for line in (source .. "\n"):gmatch("([^\n]*)\n") do
		if executable_line(line):match("%S") then return true end
	end
	return false
end


--- Replaces one exact occurrence and proves the mutation precondition.
--- @param source string Original source.
--- @param needle string Exact text.
--- @param replacement string Replacement text.
--- @return string mutant
local function replace_plain(source, needle, replacement)
	local at = source:find(needle, 1, true)
	helpers.assert_true(at ~= nil, "mutation precondition missing: " .. needle)
	return source:sub(1, at - 1) .. replacement .. source:sub(at + #needle)
end


--- Validates the complete post-onboarding fatal boundary.
--- @param source string Root source or a synthetic mutant.
--- @return boolean valid
--- @return number fatal_count
--- @return string|nil reason
local function boundary_is_exact(source)
	local declaration_at = source:find(BOUNDARY_DECLARATION, 1, true)
	if count_plain(source, BOUNDARY_DECLARATION) ~= 1 then
		return false, 0, "boundary declaration must be unique"
	end
	if count_plain(source, BOUNDARY_END) ~= 1 then
		return false, 0, "boundary end marker must be unique"
	end
	local boundary_end = source:find(BOUNDARY_END, declaration_at, true)
	if not boundary_end then return false, 0, "boundary end precedes declaration" end

	local body = source:sub(declaration_at, boundary_end - 1)
	local first_owner_at = body:find(FIRST_INPUT_OWNER, 1, true)
	local success_at = body:find(BOOT_SUCCESS, 1, true)
	if not first_owner_at or not success_at or first_owner_at >= success_at then
		return false, 0, "owner or success escaped the function"
	end

	local root_owner_at = source:find(FIRST_INPUT_OWNER, 1, true)
	local fatal_count = count_bare_error_calls(body)
	local total_post_owner_fatals = root_owner_at
		and count_bare_error_calls(source:sub(root_owner_at)) or 0
	if fatal_count < 8 then return false, fatal_count, "fatal inventory below floor" end
	if fatal_count ~= total_post_owner_fatals then
		return false, fatal_count, "a post-owner fatal gate escaped the boundary"
	end

	local call_absolute = source:find(BOUNDARY_CALL,
		boundary_end + #BOUNDARY_END, true)
	if not call_absolute then return false, fatal_count, "terminal xpcall missing" end
	local gap = source:sub(boundary_end + #BOUNDARY_END, call_absolute - 1)
	if has_executable_code(gap) then
		return false, fatal_count, "executable code escaped before the xpcall"
	end
	local tail = source:sub(call_absolute)
	local call_at = tail:find(BOUNDARY_CALL, 1, true)
	local fn_arg_at = call_at and tail:find("finish_boot_after_onboarding,", call_at, true)
	local traceback_at = fn_arg_at and tail:find("debug.traceback", fn_arg_at, true)
	local guard_at = traceback_at and tail:find(FAILURE_GUARD, traceback_at, true)
	local exit_at = guard_at and tail:find(FAILURE_EXIT, guard_at, true)
	local return_at = exit_at and tail:find("\n\treturn\nend", exit_at, true)
	local valid = call_at ~= nil
		and fn_arg_at ~= nil
		and traceback_at ~= nil
		and guard_at ~= nil
		and exit_at ~= nil
		and return_at ~= nil
	return valid, fatal_count, valid and nil or "terminal xpcall contract incomplete"
end


helpers.describe("root boot has one bounded post-onboarding failure boundary", function()
	local root_source, root_error = helpers.read_driver_unit(ROOT_ANCHOR)

	helpers.it("contains every fatal gate and success publication inside the boundary", function()
		helpers.assert_nil(root_error)
		helpers.assert_true(type(root_source) == "string" and root_source ~= "")
		local valid, fatal_count, reason = boundary_is_exact(root_source)
		helpers.assert_true(valid,
			"post-onboarding input startup through boot success must be one xpcall-owned unit: "
				.. tostring(reason))
		helpers.assert_true(fatal_count >= 8,
			"the guard must cover the complete non-vacuous fatal-gate inventory")
	end)

	helpers.it("rejects an unprotected, log-only, or fall-through failure mutant", function()
		helpers.assert_true(boundary_is_exact(root_source))
		local unprotected = replace_plain(root_source, BOUNDARY_CALL,
			"local post_onboarding_boot_ok, post_onboarding_boot_error = pcall(")
		local log_only = replace_plain(root_source, FAILURE_EXIT,
			"Logger.error(LOG, \"post-onboarding boot failed\")")
		local fall_through = replace_plain(root_source,
			FAILURE_EXIT .. "\n\treturn\nend",
			FAILURE_EXIT .. "\nend")
		local non_fatal_gate = replace_plain(root_source, BODY_FATAL,
			"Logger.error(LOG, \"VS Code caret bridge setup did not commit\")")
		local moved_gate = replace_plain(root_source, BODY_FATAL, "do end")
		moved_gate = replace_plain(moved_gate, BOUNDARY_END,
			BOUNDARY_END .. "\n" .. BODY_FATAL)
		local escaped_statement = replace_plain(root_source, BOUNDARY_END,
			BOUNDARY_END .. "\nlocal boot_escape = true")
		helpers.assert_eq(boundary_is_exact(unprotected), false)
		helpers.assert_eq(boundary_is_exact(log_only), false)
		helpers.assert_eq(boundary_is_exact(fall_through), false)
		helpers.assert_eq(boundary_is_exact(non_fatal_gate), false)
		helpers.assert_eq(boundary_is_exact(moved_gate), false)
		helpers.assert_eq(boundary_is_exact(escaped_statement), false)
	end)
end)
