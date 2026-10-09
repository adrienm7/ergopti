--- tests/unit/modules/llm/test_api_remote_timeout_wiring.lua

--- ==============================================================================
--- MODULE: Remote API timeout registry wiring regression test
--- DESCRIPTION:
--- Proves that every remote semantic HTTP owner receives the shared timeout
--- value instead of silently inheriting the adapter's default.
--- ==============================================================================

local helpers = require("tests.helpers")


helpers.describe("HS-098 remote request timeout wiring", function()
	helpers.it("passes the shared millisecond value to all three HTTP owners", function()
		local module_names = {
			"modules.llm.api_remote",
			"adapters.http_client",
			"infra.timings",
		}
		local saved = {}
		for _, name in ipairs(module_names) do saved[name] = package.loaded[name] end

		local cancelled = {}
		local timings_calls = 0
		package.loaded["infra.timings"] = {
			sec = function() return 10 end,
			ms = function(section, key)
				timings_calls = timings_calls + 1
				helpers.assert_eq(section, "llm")
				helpers.assert_eq(key, "request_timeout_ms")
				return 60000
			end,
		}
		package.loaded["adapters.http_client"] = {
			new = function(options)
				local client = {
					timeout_ms = type(options) == "table" and options.timeout_ms or nil,
					get = function() return true end,
					post = function() return true end,
				}
				client.cancel = function()
					cancelled[#cancelled + 1] = client
					return true
				end
				return client
			end,
			encodeForQuery = function(value) return tostring(value) end,
		}
		package.loaded["modules.llm.api_remote"] = nil

		local ok, err = xpcall(function()
			local api = require("modules.llm.api_remote")
			helpers.assert_true(timings_calls > 0,
				"the remote backend must resolve the shared request timeout")
			api.set_entries({})
			helpers.assert_eq(#cancelled, 3,
				"the active inference, availability, and warmup owners must all cancel")
			for index, client in ipairs(cancelled) do
				helpers.assert_eq(client.timeout_ms, 60000,
					"remote client " .. tostring(index) .. " must use the registry value")
			end
		end, debug.traceback)

		for _, name in ipairs(module_names) do package.loaded[name] = saved[name] end
		if not ok then error(err, 0) end
	end)
end)
