--- tests/unit/core/network/adapters/test_http_header_policy_native.lua

--- ==============================================================================
--- MODULE: Native HTTP Header Policy Tests
--- DESCRIPTION:
--- Verifies canonical forbidden bytes and native ASCII admission.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("macOS native HTTP header policy", function()
	local function with_policy(source, scenario)
		helpers.with_stub_scope({ "core.network.engine.http_header_policy", "core.fs.engine.paths", "core.fs.adapters.file_system" }, function()
			package.loaded["core.fs.engine.paths"] = { shared = function(path)
				helpers.assert_eq(path, "core/network/data/http/header_policy.json"); return "fixture-policy"
			end }
			package.loaded["core.fs.adapters.file_system"] = { read_bounded = function(path, limit)
				helpers.assert_eq(path, "fixture-policy"); helpers.assert_eq(limit, 4096)
				return source, source and "ok" or "error"
			end }
			scenario(require("core.network.engine.http_header_policy"))
		end)
	end
	helpers.it("accepts ASCII and a tab but refuses every shared forbidden byte", function()
		with_policy('{"forbidden_bytes":[0,10,13]}', function(policy)
			helpers.assert_true(policy.validate("Accept", "text/plain\tvalue"))
			for _, byte in ipairs({ "\0", "\n", "\r" }) do
				helpers.assert_eq(policy.validate("X-Test", "prefix" .. byte .. "suffix"), false)
				helpers.assert_eq(policy.validate("X" .. byte .. "Test", "value"), false)
			end
			helpers.assert_eq(policy.validate("X-Test", "clé"), false)
		end)
	end)
	helpers.it("refuses missing or malformed shared policy", function()
		for _, source in ipairs({ false, '{}', '{"forbidden_bytes":[0,0]}' }) do
			with_policy(source or nil, function(policy) helpers.assert_eq(policy.validate("Accept", "text/plain"), false) end)
		end
	end)
end)
