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

--- Checks every remaining persistence call and its exact refusal predicate.
--- @param source string Complete driver source containing save_prefs.
local function assert_guards(source)
	helpers.assert_type(source, "string")
	source = source:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", "")

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
			else
				unguarded[#unguarded + 1] = line
			end
		end
	end

	-- The reviewed pre-retirement census had 59 calls. Exactly the one call in
	-- apply_metrics_shortcut and the one in apply_apps_time_shortcut left with
	-- those dedicated owners. The baseline delay transaction adds one protected
	-- call to those 57 sites. The extension selection transaction adds one
	-- strict returned acknowledgement, so all 59 predicates stay in this complete
	-- scan. Moving replacement out of Layout removed no writer: its old callback
	-- delegated to do_reload(). A missing call remains a failure, not new slack.
	helpers.assert_eq(calls, 59,
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

return true
