--- tests/unit/adapters/test_file_system_delete_race.lua

--- ==============================================================================
--- MODULE: FileSystem Delete Race Regression
--- DESCRIPTION:
--- A concurrent remover can make the pathname disappear after delete() proves
--- it exists but before os.remove() executes. Errno 2 is then the committed
--- end state, while any other refusal must remain a visible failure.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ======================================
-- ======================================
-- ======= 1/ Delete Race Verdict =======
-- ======================================
-- ======================================

local function run_delete(remove_result)
	return helpers.with_fresh_modules({
		"infra.fs_dir",
		"infra.logger",
		"adapters.file_system",
	}, function()
		local errors = {}
		local logger = helpers.make_logger_stub()
		logger.error = function(_module_name, message, ...)
			local rendered_ok, rendered = pcall(string.format, message, ...)
			errors[#errors + 1] = rendered_ok and rendered or tostring(message)
		end
		package.loaded["infra.logger"] = logger
		package.loaded["infra.fs_dir"] = {}

		local exists_calls = 0
		local adapter = helpers.load_with_stubs("adapters.file_system", {
			fs = {
				attributes = function(path)
					exists_calls = exists_calls + 1
					helpers.assert_eq(path, "/tmp/hs024-race")
					return { mode = "file" }
				end,
			},
		})

		local remove_calls = 0
		local original_remove = os.remove
		os.remove = function(path)
			remove_calls = remove_calls + 1
			helpers.assert_eq(path, "/tmp/hs024-race")
			return remove_result()
		end
		local call_ok, result_or_err = xpcall(function()
			return adapter.delete("/tmp/hs024-race")
		end, debug.traceback)
		os.remove = original_remove
		if not call_ok then error(result_or_err) end

		return result_or_err, errors, exists_calls, remove_calls
	end)
end

helpers.describe("adapters.file_system — delete race verdict", function()
	helpers.it("accepts errno 2 after the existence probe", function()
		local deleted, errors, exists_calls, remove_calls = run_delete(function()
			return nil, "/tmp/hs024-race: No such file or directory", 2
		end)

		helpers.assert_eq(deleted, true,
			"a concurrent remover already achieved delete()'s requested end state")
		helpers.assert_eq(exists_calls, 1,
			"the regression must exercise the exists-to-remove race")
		helpers.assert_eq(remove_calls, 1,
			"delete() must still attempt the exact observed pathname")
		helpers.assert_eq(#errors, 0,
			"successful-by-race deletion must not emit a misleading failure")
	end)

	helpers.it("rejects a non-ENOENT removal refusal", function()
		local deleted, errors, exists_calls, remove_calls = run_delete(function()
			return nil, "/tmp/hs024-race: Permission denied", 13
		end)

		helpers.assert_eq(deleted, false,
			"only authoritative absence may convert a failed remove into success")
		helpers.assert_eq(exists_calls, 1)
		helpers.assert_eq(remove_calls, 1)
		helpers.assert_eq(#errors, 1,
			"an actual removal refusal must remain visible")
		helpers.assert_true(errors[1]:find("Permission denied", 1, true) ~= nil,
			"the native refusal detail must reach the diagnostic")
	end)
end)
