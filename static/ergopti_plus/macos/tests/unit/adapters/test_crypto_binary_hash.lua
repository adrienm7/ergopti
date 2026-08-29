--- tests/unit/adapters/test_crypto_binary_hash.lua
---
--- ============================================================================
--- MODULE: Crypto Binary SHA-256 Regression Tests
--- DESCRIPTION:
--- Proves the self-update hash boundary consumes arbitrary binary bytes through
--- Hammerspoon's native hash API instead of shell interpolation.
--- ============================================================================

local helpers = require("tests.helpers")


helpers.describe("adapters.crypto: native binary SHA-256", function()
	helpers.it("hashes the exact binary payload including NUL bytes", function()
		local expected = string.rep("a", 64)
		local payload = "zip\0payload\255"
		local observed = { execute_calls = 0 }
		local hash_context = {}

		function hash_context:append(data)
			observed.payload = data
			return self
		end

		function hash_context:finish()
			observed.finished = true
			return self
		end

		function hash_context:value()
			return expected
		end

		local Crypto = helpers.load_with_stubs("adapters.crypto", {
			execute = function()
				observed.execute_calls = observed.execute_calls + 1
				return ""
			end,
			hash = {
				new = function(algorithm)
					observed.algorithm = algorithm
					return hash_context
				end,
			},
		})

		helpers.assert_eq(Crypto.sha256_bytes(payload), expected)
		helpers.assert_eq(observed.algorithm, "SHA256")
		helpers.assert_eq(observed.payload, payload)
		helpers.assert_eq(observed.finished, true)
		helpers.assert_eq(observed.execute_calls, 0,
			"binary hashing must never interpolate archive bytes into a shell command")
	end)
end)
