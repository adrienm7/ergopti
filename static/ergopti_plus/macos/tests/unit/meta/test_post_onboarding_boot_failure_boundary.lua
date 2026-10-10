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
local BODY_FATAL = "error(\"menu.start did not commit\")"

-- Required contracts, independently named rather than inferred from production counts.
local REQUIRED_FATAL_MESSAGES = {
	"input subsystem pre-start did not commit",
	"dependency bootstrap pause-owner registration did not commit",
	"hotstring override owner did not initialize",
	"dynamic_hotstrings.start did not commit",
	"canonical personal-info preference did not commit before eventtap startup",
	"canonical hotstring preferences did not commit before eventtap startup",
	"keymap.start did not commit",
	"karabiner.init did not commit",
	"menu.start did not commit",
	"file-watcher startup did not commit",
}


--- Masks strings and comments while preserving source offsets and newlines.
--- @param source string Source text.
--- @return string code Executable tokens at their original positions.
local function executable_source(source)
	local chunks, cursor = {}, 1
	while cursor <= #source do
		local start = cursor
		local comment = source:sub(cursor, cursor + 1) == "--"
		local bracket_at = comment and cursor + 2 or cursor
		local equals = source:match("^%[(=*)%[", bracket_at)
		local quote = source:sub(cursor, cursor)
		if equals then
			local close = "]" .. equals .. "]"
			local finish = source:find(close, bracket_at + #equals + 2, true)
			cursor = finish and finish + #close or #source + 1
		elseif comment then
			cursor = source:find("\n", cursor, true) or #source + 1
		elseif quote == '"' or quote == "'" then
			cursor = cursor + 1
			while cursor <= #source do
				local char = source:sub(cursor, cursor)
				cursor = cursor + 1
				if char == "\\" then cursor = cursor + 1
				elseif char == quote then break end
			end
		else
			chunks[#chunks + 1] = quote
			cursor = cursor + 1
		end
		if equals or comment or quote == '"' or quote == "'" then
			chunks[#chunks + 1] = source:sub(start, cursor - 1):gsub("[^\n]", " ")
		end
	end
	return table.concat(chunks)
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
	local count, messages, cursor = 0, {}, 1
	local code = executable_source(source)
	while true do
		local at, finish = code:find("error%s*%(", cursor)
		if not at then break end
		local previous = at > 1 and code:sub(at - 1, at - 1) or ""
		if previous == "" or not previous:match("[%w_%.:]") then
			count = count + 1
			local message = source:sub(finish + 1):match('^%s*"([^"\n]*)"%s*%)')
			if message then messages[message] = (messages[message] or 0) + 1 end
		end
		cursor = finish + 1
	end
	return count, messages
end


--- Reports whether a source fragment contains executable tokens.
--- @param source string Source fragment.
--- @return boolean present
local function has_executable_code(source)
	return executable_source(source):match("%S") ~= nil
end


--- Replaces one exact occurrence and proves the mutation precondition.
--- @param source string Original source.
--- @param needle string Exact text.
--- @param replacement string Replacement text.
--- @param start_at number|nil First allowed mutation offset.
--- @return string mutant
local function replace_plain(source, needle, replacement, start_at)
	local at = source:find(needle, start_at or 1, true)
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
	local fatal_count, messages = count_bare_error_calls(body)
	if messages["VS Code caret bridge setup did not commit"]
		or messages["infra.vscode_bridge.stop_server is unavailable"] then
		return false, fatal_count, "retired bridge cannot become a startup prerequisite"
	end
	local total_post_owner_fatals = root_owner_at
		and count_bare_error_calls(source:sub(root_owner_at)) or 0
	for _, message in ipairs(REQUIRED_FATAL_MESSAGES) do
		if messages[message] ~= 1 then
			return false, fatal_count, "required fatal gate missing or duplicated: " .. message
		end
	end
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
		helpers.assert_true(fatal_count >= #REQUIRED_FATAL_MESSAGES,
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
			"Logger.error(LOG, \"menu.start did not commit\")")
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
	for _, message in ipairs(REQUIRED_FATAL_MESSAGES) do
		helpers.it("rejects removal or log-only substitution of fatal gate: " .. message, function()
			local gate = 'error("' .. message .. '")'
			local boundary_at = assert(root_source:find(BOUNDARY_DECLARATION, 1, true))
			local removed = replace_plain(root_source, gate, "do end", boundary_at)
			local logged = replace_plain(root_source, gate, 'Logger.' .. gate, boundary_at)
			local commented = replace_plain(root_source, gate, "--[[ " .. gate .. " ]] do end", boundary_at)
			helpers.assert_eq(boundary_is_exact(removed), false, "required fatal gate was removed")
			helpers.assert_eq(boundary_is_exact(logged), false, "diagnostic is not a fatal gate")
			helpers.assert_eq(boundary_is_exact(commented), false, "comment is not a fatal gate")
		end)
	end


	helpers.it("rejects either retired bridge gate becoming a startup prerequisite", function()
		helpers.assert_true(boundary_is_exact(root_source))
		for _, message in ipairs({ "VS Code caret bridge setup did not commit",
			"infra.vscode_bridge.stop_server is unavailable" }) do
			local revived = replace_plain(root_source, BOUNDARY_END,
				'error("' .. message .. '")\n' .. BOUNDARY_END)
			helpers.assert_eq(boundary_is_exact(revived), false,
				"retired capability cannot restore a mandatory startup gate")
		end
	end)
	helpers.it("retains the exact loaded legacy bridge cleanup before current startup", function()
		local before = root_source:sub(1, assert(root_source:find(BOUNDARY_DECLARATION, 1, true)) - 1)
		local function cleanup_is_exact(source)
			local start = source:find('name = "vscode-bridge"', 1, true)
			local finish = start and source:find('\n\t\t},', start, true)
			if not finish or count_plain(source, 'name = "vscode-bridge"') ~= 1 then return false end
			source = source:sub(start, finish - 1)
			return count_plain(source, 'local module = package.loaded["infra.vscode_bridge"]') == 1
				and count_plain(source, 'error("infra.vscode_bridge.stop_server is unavailable")') == 1
				and source:find('if module == nil then return true end', 1, true) ~= nil
				and source:find('if type(module) ~= "table" or type(module.stop_server) ~= "function" then', 1, true) ~= nil
				and source:find('return module.stop_server()', 1, true) ~= nil
		end
		helpers.assert_true(cleanup_is_exact(before), "retirement must preserve the existing loaded-owner cleanup")
		for _, target in ipairs({ 'local module = package.loaded["infra.vscode_bridge"]',
			'error("infra.vscode_bridge.stop_server is unavailable")', 'return module.stop_server()',
			'if module == nil then return true end',
			'if type(module) ~= "table" or type(module.stop_server) ~= "function" then' }) do
			local start = assert(before:find('name = "vscode-bridge"', 1, true))
			helpers.assert_eq(cleanup_is_exact(replace_plain(before, target, "do end", start)), false,
				"withdrawing a loaded-owner cleanup obligation must refuse")
		end
	end)

	helpers.it("ignores diagnostics and quoted or commented fatal-looking text", function()
		local count = count_bare_error_calls([=[
Logger.error("diagnostic")
local text = 'error("quoted")'
local block = [[error("long quoted")]]
-- error("line comment")
--[[error("long comment")]]
error("real gate")
]=])
		helpers.assert_eq(count, 1, "only the bare executable call is fatal")
	end)

end)
