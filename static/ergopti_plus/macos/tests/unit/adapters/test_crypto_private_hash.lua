--- tests/unit/adapters/test_crypto_private_hash.lua

--- Tests actual native hash exceptions with scoped closed diagnostic receipts.
local helpers = require("tests.helpers")

local function with_crypto(callback)
	local saved_hs = _G.hs
	local ok, failure = xpcall(function()
		helpers.with_fresh_modules({ "adapters.crypto", "infra.logger" }, function()
			local logs = {}
			local logger = helpers.make_logger_stub()
			logger.error = function(_, template, ...) logs[#logs + 1] = string.format(template, ...) end
			package.loaded["infra.logger"] = logger
			_G.hs = { hash = { new = function() error("PRIVATE executable argv source bytes") end } }
			callback(require("adapters.crypto"), logs)
		end)
	end, debug.traceback)
	_G.hs = saved_hs
	if not ok then error(failure, 0) end
end

helpers.describe("private raw source hash diagnostics", function()
	helpers.it("routes an actual native hash throw through a fixed-category callback", function()
		with_crypto(function(crypto, logs)
			local categories = {}
			helpers.assert_eq(crypto.sha256_bytes("private raw config bytes", function(category)
				categories[#categories + 1] = category
			end), "")
			helpers.assert_eq(categories, { "native-hash-error" })
			helpers.assert_eq(#logs, 0)
		end)
	end)

	helpers.it("contains a private failure reporter exception without exposing either value", function()
		with_crypto(function(crypto, logs)
			helpers.assert_eq(crypto.sha256_bytes("private raw config bytes", function() error("PRIVATE reporter failure") end), "")
			helpers.assert_eq(#logs, 0)
		end)
	end)

	helpers.it("preserves ordinary native hash error diagnostics", function()
		with_crypto(function(crypto, logs)
			helpers.assert_eq(crypto.sha256_bytes("ordinary raw bytes"), "")
			helpers.assert_eq(#logs, 1)
			helpers.assert_true(logs[1]:find("PRIVATE executable argv source bytes", 1, true) ~= nil)
		end)
	end)
end)
