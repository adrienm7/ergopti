--- tests/meta/test_menu_preference_calls_fail_closed.lua

--- ==============================================================================
--- MODULE: Menu Preference Call-Site Transaction Guard
--- DESCRIPTION:
--- Enumerates the full class of menu persistence calls. Every direct call must
--- test the exact true result before success-only effects. A protected call is
--- accepted only when it preserves and checks both pcall status and the writer's
--- exact result; discarding either value would turn false or a throw into success.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The executable projection retains line boundaries for the direct-call audit.
-- Literal contents cannot fabricate a save call, guard or helper import.
local function executable(source)
	local output, at = {}, 1
	local function mask(last, sentinel)
		local chunk = source:sub(at, last)
		output[#output + 1] = sentinel or chunk:gsub("[^\n]", " ")
		at = last + 1
	end
	while at <= #source do
		local char = source:sub(at, at)
		local comment = source:sub(at, at + 1) == "--"
		local start = comment and at + 2 or at
		local equals = source:sub(start, start) == "[" and source:sub(start):match("^%[(=*)%[") or nil
		if equals then
			local close, last = source:find("]" .. equals .. "]", start + #equals + 2, true)
			mask(last or #source)
		elseif comment then
			local newline = source:find("\n", at + 2, true)
			mask(newline and newline - 1 or #source)
		elseif char == '"' or char == "'" then
			local quote, last = char, at + 1
			while last <= #source do
				local char = source:sub(last, last)
				if char == "\\" then last = last + 2
				elseif char == quote then break
				else last = last + 1 end
			end
			local literal = source:sub(at + 1, last - 1)
			mask(math.min(last, #source), literal == "menu.wrap_mutation" and "__WRAP_MUTATION_MODULE__" or nil)
		else
			output[#output + 1] = source:sub(at, at)
			at = at + 1
		end
	end
	return table.concat(output)
end

local function compact(source) return source:gsub("%s+", "") end

-- Keep identifier boundaries when proving a declaration and its receiver.
-- Removing whitespace first would merge `local` with a longer alias and admit
-- an unbound real receiver despite a matching substring in that alias.
local function has_tokens(source, required)
	local function tokens(code)
		local values = {}
		for value in code:gsub("([^%w_%s])", " %1 "):gmatch("%S+") do values[#values + 1] = value end
		return values
	end
	local actual, expected = tokens(source), tokens(required)
	for at = 1, #actual - #expected + 1 do
		local matched = true
		for offset, value in ipairs(expected) do
			if actual[at + offset - 1] ~= value then matched = false; break end
		end
		if matched then return true end
	end
	return false
end

-- Extract one actual function or refusal block, balancing nested executable
-- function/if/do/repeat owners; comments and strings have already been masked.
local function block(source, prefix)
	local code = source:gsub("%s+", " ")
	local first, last = code:find(prefix, 1, true)
	helpers.assert_not_nil(first, "every menu preference writer: actual owner missing: " .. prefix)
	helpers.assert_nil(code:find(prefix, last + 1, true), "every menu preference writer: ambiguous owner: " .. prefix)
	local depth = 1
	for begin, word, finish in code:sub(last + 1):gmatch("()([%a_][%w_]*)()") do
		if word == "function" or word == "if" or word == "do" or word == "repeat" then depth = depth + 1
		elseif word == "end" or word == "until" then
			depth = depth - 1
			if depth == 0 then return code:sub(first, last + finish - 1), first, last + finish - 1 end
		end
	end
	error("every menu preference writer: unterminated owner: " .. prefix)
end

local file = assert(io.open(helpers.shared("lua/menu/wrap_mutation.lua"), "rb"))
local shared_wrap_source = file:read("*a")
file:close()

local function delegated_guards(source, helper_source, native_source)
	local native = executable(native_source)
	local _, references = source:gsub("mutate_wrap%s*%(", "")
	if references == 0 then return 0, 0 end
	local owner = block(native, "local function mutate_wrap(mutate)")
	local _, definition_count = source:gsub("local%s+function%s+mutate_wrap%s*%(", "")
	helpers.assert_eq(definition_count, 1, "every menu preference writer: one native delegation owner")
	local callbacks = references - definition_count
	local _, returned = source:gsub("return%s+mutate_wrap%s*%(%s*function%s*%(%s*candidate%s*%)", "")
	local valid = returned == callbacks
	valid = valid and has_tokens(native, "local WrapMutation = require(__WRAP_MUTATION_MODULE__)")
	local body = compact(owner)
	valid = valid and has_tokens(owner, "local committed, reason = WrapMutation.commit(state, mutate, ctx.save_prefs)")
	local refusal, first, last = block(owner, "if committed ~= true then")
	valid = valid and compact(refusal):match("returnfalseend$") ~= nil
	valid = valid and compact(refusal):find("returntrue", 1, true) == nil
	valid = valid and compact(refusal):find("ctx.updateMenu()", 1, true) == nil
	valid = valid and compact(owner:sub(1, first - 1)):find("ctx.updateMenu()", 1, true) == nil
	valid = valid and compact(owner:sub(last + 1)) == "ctx.updateMenu()returntrueend"
	local helper = block(executable(helper_source), "function M.commit(state, mutate, save)")
	local helper_body = compact(helper)
	local _, save_calls = helper_body:gsub("pcall%(save%)", "")
	local _, direct_save_calls = helper_body:gsub("save%(%)", "")
	valid = valid and save_calls == 1 and direct_save_calls == 0
	valid = valid and has_tokens(helper, "local saved, acknowledged = pcall(save)")
	local save_refusal = block(helper, "if not saved or acknowledged ~= true then")
	valid = valid and compact(save_refusal):find("returnfalse,savedand", 1, true) ~= nil
	valid = valid and compact(save_refusal):find("returntrue", 1, true) == nil
	return callbacks, valid and callbacks or 0
end

--- Checks every remaining persistence call and its exact refusal predicate.
--- @param source string Complete driver source containing save_prefs.
local function assert_guards(source, helper_source, native_source)
	helpers.assert_type(source, "string")
	if not native_source then
		local owner, owner_error = helpers.read_driver_unit("local function build_wrap_symbols_submenu")
		helpers.assert_not_nil(owner, owner_error)
		native_source = owner
	end
	local native_at = source:find(native_source, 1, true)
	helpers.assert_not_nil(native_at, "every menu preference writer: complete inventory must include the actual native delegation owner")
	helpers.assert_nil(source:find(native_source, native_at + 1, true), "every menu preference writer: native delegation owner is unique")
	source = executable(source)

	local calls, guarded = 0, 0
	local unguarded = {}
	local lines = {}
	for line in source:gmatch("[^\n]+") do lines[#lines + 1] = line end
	for index, line in ipairs(lines) do
		if line:match("x?pcall%s*%(%s*[%w_%.]*save_prefs") then
			calls = calls + 1
			local status_name, result_name = line:match(
				"local%s+([%w_]+)%s*,%s*([%w_]+)%s*=%s*x?pcall%s*%(%s*[%w_%.]*save_prefs")
			local guard = lines[index + 1] or ""
			if status_name and result_name
				and (guard:match("if%s+not%s+" .. status_name .. "%s+or%s+"
					.. result_name .. "%s*~=%s*true%s+then")
					or guard:match("if%s+" .. status_name .. "%s+and%s+"
						.. result_name .. "%s*==%s*true%s+then")) then
				guarded = guarded + 1
			else
				unguarded[#unguarded + 1] = line .. " || " .. guard
			end
		elseif line:match("[%w_%.]*save_prefs%s*%(%s*%)")
			and not line:match("local%s+function%s+save_prefs")
			and not line:match("return%s+transactional_save_prefs") then
			calls = calls + 1
			if line:match("save_prefs%s*%(%s*%)%s*~=%s*true%s+then") then
				guarded = guarded + 1
			elseif line:match("local%s+[%w_]+%s*=%s*[%w_%.]*save_prefs%s*%(%s*%)%s*==%s*true") then
				guarded = guarded + 1
			elseif line:match("^%s*return%s+[%w_%.]*save_prefs%s*%(%s*%)%s*==%s*true%s*$") then
				-- A journal publisher returns its exact acknowledgement to the
				-- native transaction owner; no truthy or appended fallback qualifies.
				guarded = guarded + 1
			elseif line:match("^%s*if%s+[%w_%.]*save_prefs%s*%(%s*%)%s*==%s*true%s+then%s+return%s+true%s+end%s*$") then
				-- A native journal may acknowledge only this exact conditional return.
				-- A truthy result, appended fallback or additional effect is rejected.
				guarded = guarded + 1
			else
				unguarded[#unguarded + 1] = line
			end
		end
	end

	-- Eight formerly direct Wrap calls now delegate through the actual strict
	-- shared transaction. Enumerate all eight callbacks and prove that route;
	-- the independent 61-operation census and all historical predicates remain.
	local delegated, delegated_guarded = delegated_guards(source, helper_source or shared_wrap_source, native_source)
	calls, guarded = calls + delegated, guarded + delegated_guarded

	-- The reviewed pre-retirement census had 59 calls. Exactly the one call in
	-- apply_metrics_shortcut and the one in apply_apps_time_shortcut left with
	-- those dedicated owners. The baseline delay transaction adds one protected
	-- call to those 57 sites. The extension selection transaction adds one
	-- strict returned acknowledgement, so all 59 predicates stay in this complete
	-- scan. Moving replacement out of Layout removed no writer: its old callback
	-- delegated to do_reload(). A missing call remains a failure, not new slack.
	-- Two independently reviewed publishers add exactly one call each: the
	-- additional-personal file gate and the programmable-source preference owner.
	-- Their separate remove/weaken/fallback mutations below keep both additions
	-- in the full inventory without granting another call a census exception.
	helpers.assert_eq(calls, 59 + 2,
		"the reviewed post-retirement census must enumerate every remaining save call")
	helpers.assert_eq(guarded, calls,
		"every menu preference writer must stop success-only effects on false, nil, or throw; unguarded: "
			.. table.concat(unguarded, " | "))
end

helpers.describe("menu preference call sites fail closed", function()
	helpers.it("guards every save_prefs call with exact success", function()
		assert_guards(helpers.read_driver_source("save_prefs"))
	end)

	helpers.it("rejects a missing remaining save call instead of accepting a sampled census", function()
		local source = helpers.read_driver_source("save_prefs")
		local changed, count = source:gsub("if save_prefs%(%) ~= true then", "if true then", 1)
		helpers.assert_eq(count, 1, "the negative control removes one real guarded call")
		local ok, err = pcall(assert_guards, changed)
		helpers.assert_eq(ok, false)
		helpers.assert_true(tostring(err):find("reviewed post-retirement census", 1, true) ~= nil)
	end)

	helpers.it("rejects weakening one remaining refusal predicate", function()
		local source = helpers.read_driver_source("save_prefs")
		local changed, count = source:gsub("if save_prefs%(%) ~= true then", "if save_prefs() then", 1)
		helpers.assert_eq(count, 1, "the negative control weakens one real predicate")
		local ok, err = pcall(assert_guards, changed)
		helpers.assert_eq(ok, false)
		helpers.assert_true(tostring(err):find("every menu preference writer", 1, true) ~= nil)
	end)

	for _, mutation in ipairs({
		{ name = "removing", before = "local called, committed = xpcall(options.save_prefs, debug.traceback)",
			after = "local called, committed = true, true", reason = "reviewed post-retirement census" },
		{ name = "weakening", before = "if not called or committed ~= true then",
			after = "if not called or not committed then", reason = "every menu preference writer" },
	}) do
		helpers.it("rejects " .. mutation.name .. " the baseline delay writer acknowledgement", function()
			local owner, owner_error = helpers.read_driver_unit("MODULE: Baseline Delay Mutation Owner")
			helpers.assert_not_nil(owner, owner_error)
			local first = owner:find(mutation.before, 1, true)
			helpers.assert_not_nil(first, "the mutation must reach the real baseline owner")
			helpers.assert_eq(owner:find(mutation.before, first + 1, true), nil)
			local altered_owner = owner:sub(1, first - 1) .. mutation.after
				.. owner:sub(first + #mutation.before)
			local source = helpers.read_driver_source("save_prefs")
			local owner_start = source:find(owner, 1, true)
			helpers.assert_not_nil(owner_start, "the complete census must include the baseline owner")
			helpers.assert_eq(source:find(owner, owner_start + 1, true), nil)
			local changed = source:sub(1, owner_start - 1) .. altered_owner
				.. source:sub(owner_start + #owner)
			local ok, err = pcall(assert_guards, changed)
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(err):find(mutation.reason, 1, true) ~= nil)
		end)
	end

	for _, owner_symbol in ipairs({ "set personal file gate", "MODULE: Programmable Hotstring Menu (macOS Native Ports)" }) do
		for _, mutation in ipairs({
			{ name = "removing", after = "return true", reason = "reviewed post-retirement census" },
			{ name = "weakening", after = "if ctx.save_prefs() then return true end", reason = "every menu preference writer" },
			{ name = "appending a truthy fallback to", after = "if ctx.save_prefs() == true or true then return true end",
				reason = "every menu preference writer" },
		}) do
			helpers.it("rejects " .. mutation.name .. " the " .. owner_symbol .. " acknowledgement", function()
				local owner, owner_error = helpers.read_driver_unit(owner_symbol)
				helpers.assert_not_nil(owner, owner_error)
				local before = "if ctx.save_prefs() == true then return true end"
				local first = owner:find(before, 1, true)
				helpers.assert_not_nil(first, "the mutation must reach the actual new publisher")
				helpers.assert_nil(owner:find(before, first + 1, true), "the new publisher acknowledgement is unique")
				local altered_owner = owner:sub(1, first - 1) .. mutation.after .. owner:sub(first + #before)
				local source = helpers.read_driver_source("save_prefs")
				local owner_start = source:find(owner, 1, true)
				helpers.assert_not_nil(owner_start, "the full census includes the newly reviewed publisher")
				helpers.assert_nil(source:find(owner, owner_start + 1, true))
				local changed = source:sub(1, owner_start - 1) .. altered_owner .. source:sub(owner_start + #owner)
				local ok, err = pcall(assert_guards, changed)
				helpers.assert_eq(ok, false)
				helpers.assert_true(tostring(err):find(mutation.reason, 1, true) ~= nil)
			end)
		end
	end

	for _, mutation in ipairs({
		{ name = "removing", after = "return true", reason = "reviewed post-retirement census" },
		{ name = "weakening", after = "return ctx.save_prefs()", reason = "every menu preference writer" },
		{ name = "appending a truthy fallback to", after = "return ctx.save_prefs() == true or true",
			reason = "every menu preference writer" },
	}) do
		helpers.it("rejects " .. mutation.name .. " the extension publisher acknowledgement", function()
			local owner, owner_error = helpers.read_driver_unit("function M.commit_extension_selection")
			helpers.assert_not_nil(owner, owner_error)
			local before = "return ctx.save_prefs() == true"
			local first = owner:find(before, 1, true)
			helpers.assert_not_nil(first, "the mutation must reach the actual extension publisher")
			helpers.assert_nil(owner:find(before, first + 1, true), "the publisher acknowledgement is unique")
			local altered_owner = owner:sub(1, first - 1) .. mutation.after .. owner:sub(first + #before)
			local source = helpers.read_driver_source("save_prefs")
			local owner_start = source:find(owner, 1, true)
			helpers.assert_not_nil(owner_start, "the complete census includes the extension transaction")
			helpers.assert_nil(source:find(owner, owner_start + 1, true))
			local changed = source:sub(1, owner_start - 1) .. altered_owner .. source:sub(owner_start + #owner)
			local ok, err = pcall(assert_guards, changed)
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(err):find(mutation.reason, 1, true) ~= nil)
		end)
	end

	helpers.it("restores core backend identity before keymap warmup setters", function()
		local source, err = helpers.read_driver_unit("Restore the backend/profile/model identity")
		helpers.assert_not_nil(source, err)
		local backend = source:find('fn = "set_backend"', 1, true)
		local keymap = source:find('"keymap.set_llm_model"', 1, true)
		helpers.assert_true(backend ~= nil and keymap ~= nil and backend < keymap,
			"rollback must restore the core backend before keymap setters can schedule warmup")
	end)
end)



-- The actual delegated route replaces eight physical native writes, not eight
-- validation obligations. Mutants below act on those current owning sources.
helpers.describe("shared Wrap preference delegation fails closed", function()
	local function replace_once(source, before, after)
		local first = source:find(before, 1, true)
		helpers.assert_not_nil(first, "actual mutation preimage: " .. before)
		return source:sub(1, first - 1) .. after .. source:sub(first + #before)
	end

	for _, mutation in ipairs({
		{ name = "removing one delegated callback", before = "return mutate_wrap(function(candidate)",
			after = "return (function(candidate)", reason = "reviewed post-retirement census" },
		{ name = "short-circuiting one delegated callback", before = "return mutate_wrap(function(candidate)",
			after = "return true or mutate_wrap(function(candidate)", reason = "every menu preference writer" },
		{ name = "changing the imported shared owner", before = 'require("menu.wrap_mutation")',
			after = 'require("menu.foreign_mutation")', reason = "every menu preference writer" },
		{ name = "changing the real helper receiver", before = "WrapMutation.commit(state, mutate, ctx.save_prefs)",
			after = "Foreign.commit(state, mutate, ctx.save_prefs)", reason = "every menu preference writer" },
		{ name = "forwarding a fabricated native save", before = "WrapMutation.commit(state, mutate, ctx.save_prefs)",
			after = "WrapMutation.commit(state, mutate, function() return true end)", reason = "every menu preference writer" },
		{ name = "weakening the native commit acknowledgement", before = "if committed ~= true then",
			after = "if not committed then", reason = "every menu preference writer" },
		{ name = "returning success from native refusal", before = "return false\n\t\tend\n\t\tctx.updateMenu()",
			after = "return false or true\n\t\tend\n\t\tctx.updateMenu()", reason = "every menu preference writer" },
		{ name = "refreshing the menu before acknowledgement", before = "local committed, reason = WrapMutation.commit(state, mutate, ctx.save_prefs)",
			after = "ctx.updateMenu()\n\t\tlocal committed, reason = WrapMutation.commit(state, mutate, ctx.save_prefs)", reason = "every menu preference writer" },
	}) do
		helpers.it("rejects " .. mutation.name .. "", function()
			local source = helpers.read_driver_source("save_prefs")
			local native, owner_error = helpers.read_driver_unit("local function build_wrap_symbols_submenu")
			helpers.assert_not_nil(native, owner_error)
			local altered_native = replace_once(native, mutation.before, mutation.after)
			-- A copy in a comment or literal cannot repair removed executable authority.
			altered_native = altered_native .. "\n--[=[" .. mutation.before .. "]=]\nlocal unowned = [=[" .. mutation.before .. "]=]"
			local changed = replace_once(source, native, altered_native)
			local ok, err = pcall(assert_guards, changed, shared_wrap_source, altered_native)
			helpers.assert_eq(ok, false)
			helpers.assert_contains(tostring(err), mutation.reason)
		end)
	end

	for _, mutation in ipairs({
		{ name = "removing the actual native writer call", before = "local saved, acknowledged = pcall(save)",
			after = "local saved, acknowledged = true, true" },
		{ name = "discarding its protected-call status", before = "if not saved or acknowledged ~= true then",
			after = "if acknowledged ~= true then" },
		{ name = "accepting a truthy save acknowledgement", before = "if not saved or acknowledged ~= true then",
			after = "if not saved or not acknowledged then" },
		{ name = "appending a fallback to save refusal", before = 'return false, saved and "preference save refused"',
			after = 'return false or true, saved and "preference save refused"' },
		{ name = "executing a second unguarded native save", before = "local saved, acknowledged = pcall(save)",
			after = "save()\n\tlocal saved, acknowledged = pcall(save)" },
	}) do
		helpers.it("rejects the shared helper " .. mutation.name, function()
			local changed = replace_once(shared_wrap_source, mutation.before, mutation.after)
			changed = changed .. "\n--[=[" .. mutation.before .. "]=]\nlocal unowned = [=[" .. mutation.before .. "]=]"
			local ok, err = pcall(assert_guards, helpers.read_driver_source("save_prefs"), changed)
			helpers.assert_eq(ok, false)
			helpers.assert_contains(tostring(err), "every menu preference writer")
		end)
	end
end)


helpers.describe("preference acknowledgement bindings retain identifier boundaries", function()
	for _, mutation in ipairs({
		{ name = "the actual native import", before = "local WrapMutation  = require",
			after = "local unrelated_localWrapMutation = require", target = "native" },
		{ name = "the native returned receipt", before = "local committed, reason = WrapMutation.commit",
			after = "local unrelated_localcommitted, reason = WrapMutation.commit", target = "native" },
		{ name = "the protected shared save status", before = "local saved, acknowledged = pcall(save)",
			after = "local unrelated_localsaved, acknowledged = pcall(save)", target = "shared" },
	}) do
		helpers.it("rejects a longer identifier alias for " .. mutation.name, function()
			local native, owner_error = helpers.read_driver_unit("local function build_wrap_symbols_submenu")
			helpers.assert_not_nil(native, owner_error)
			local source = helpers.read_driver_source("save_prefs")
			local original = mutation.target == "native" and native or shared_wrap_source
			local first = original:find(mutation.before, 1, true)
			helpers.assert_not_nil(first, "actual longer-identifier mutation preimage")
			helpers.assert_nil(original:find(mutation.before, first + 1, true), "actual declaration is unique")
			local altered = original:sub(1, first - 1) .. mutation.after .. original:sub(first + #mutation.before)
			altered = altered .. "\n--[=[" .. mutation.before .. "]=]\nlocal unowned = [=[" .. mutation.before .. "]=]"
			local helper = shared_wrap_source
			if mutation.target == "native" then
				local at = assert(source:find(native, 1, true))
				source = source:sub(1, at - 1) .. altered .. source:sub(at + #native)
				native = altered
			else helper = altered end
			local ok, err = pcall(assert_guards, source, helper, native)
			helpers.assert_eq(ok, false)
			helpers.assert_contains(tostring(err), "every menu preference writer")
		end)
	end
end)

return true
