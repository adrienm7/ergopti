--- tests/unit/lib/test_toml_output_fixture_cleanup.lua

--- ==============================================================================
--- MODULE: TOML Output Fixture Cleanup Regressions
--- DESCRIPTION:
--- Exercises real publication and observes artifacts before rescue cleanup.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.toml_output_fixture")

--- Exercises a terminal boundary without leaving artifacts on a failing test.
--- @param mode string Callback or cleanup failure mode.
local function check_cleanup(mode)
	return helpers.with_stub_scope({
		"infra.toml.writer", "adapters.file_system", "infra.fs_dir", "infra.logger",
	}, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		local writer = helpers.load_with_stubs("infra.toml.writer")
		local open, remove = io.open, os.remove
		local path, lock_path, observed_content, observed_lock
		local marker = "toml-fixture-" .. mode
		local cleanup_marker = "injected cleanup refusal"
		local refused_path
		os.remove = function(candidate)
			if candidate == refused_path then return nil, cleanup_marker end
			return remove(candidate)
		end
		local outcome = table.pack(pcall(fixture.with_output, function(output, lock)
			path, lock_path = output, lock
			if mode == "early" then error(marker) end
			assert(writer.write(path, { meta = { description = "owned fixture" } }))
			local handle = assert(open(path, "rb"))
			observed_content = handle:read("*a")
			assert(handle:close())
			local lock_handle = assert(open(lock_path, "rb"))
			observed_lock = true
			assert(lock_handle:close())
			if mode == "remove_output" then refused_path = path end
			if mode == "remove_lock" or mode == "callback_remove" then refused_path = lock_path end
			if mode == "callback" or mode == "callback_remove" then error(marker) end
			return "first", nil, "third"
		end))
		os.remove = remove
		local remaining = {}
		-- Observe both real files first; rescue cannot turn a cleanup failure green.
		for _, owned_path in ipairs({ path, lock_path }) do
			local handle, reason, code = open(owned_path, "rb")
			remaining[owned_path] = handle ~= nil
			if handle then
				assert(handle:close())
				assert(remove(owned_path))
			else
				assert(code == 2, "unexpected artifact inspection failure: " .. tostring(reason))
			end
		end
		helpers.assert_type(path, "string", "fixture callback must receive an allocated path")
		helpers.assert_eq(outcome[1], mode == "success", "unexpected result: " .. tostring(outcome[2]))
		if mode == "success" then
			helpers.assert_eq(outcome.n, 4, "callback nil return slots must survive")
			helpers.assert_eq(outcome[2], "first")
			helpers.assert_eq(outcome[4], "third")
		end
		if mode == "callback" or mode == "callback_remove" or mode == "early" then
			helpers.assert_true(tostring(outcome[2]):find(marker, 1, true) ~= nil, "original error must survive cleanup")
		end
		if refused_path then
			helpers.assert_true(tostring(outcome[2]):find(cleanup_marker, 1, true) ~= nil, "cleanup refusal must be visible")
		end
		if mode ~= "early" then
			helpers.assert_true(observed_content:find("owned fixture", 1, true) ~= nil, "real serializer must publish content")
			helpers.assert_eq(observed_lock, true, "the real writer must leave its stable lock until fixture teardown")
		end
		helpers.assert_eq(remaining[path], refused_path == path, "output must be removed unless its removal refused")
		helpers.assert_eq(remaining[lock_path], refused_path == lock_path, "lock must be removed unless its removal refused")
	end)
end

helpers.describe("TOML fixture artifact ownership", function()
	for _, mode in ipairs({ "success", "callback", "early", "remove_output", "remove_lock", "callback_remove" }) do
		helpers.it("(toml-fixture-cleanup) cleans after " .. mode, function()
			check_cleanup(mode)
		end)
	end
end)
