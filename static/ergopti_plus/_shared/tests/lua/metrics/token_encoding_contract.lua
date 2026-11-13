--- _shared/tests/lua/metrics/token_encoding_contract.lua

--- ==============================================================================
--- MODULE: Keystats Token Encoding Contract
--- DESCRIPTION:
--- Replays _shared/tests/corpus/keystats/token_encoding_vectors.json on the
--- shared Lua rule, for both Lua drivers; the Windows walker and the dashboard
--- reader replay the same file. Also pins the migration statements: binary
--- literals, nothing for an unchanged key, and a whole-transaction refusal.
--- ==============================================================================

local M = {}

--- Registers the contract with a driver's test helpers.
--- @param helpers table Test helpers of the driver suite.
--- @param env table { vectors = decoded token_encoding_vectors.json }
function M.register(helpers, env)
	local Encoding = require("metrics.engine.privacy.token_encoding")
	local vectors = env.vectors

	helpers.describe("n-gram token encoding", function()
		helpers.it("runs the corpus version", function()
			helpers.assert_eq(Encoding.VERSION, vectors.version)
		end)

		helpers.it("encodes every event of the corpus", function()
			for _, vector in ipairs(vectors.event_tokens) do
				helpers.assert_eq(Encoding.event_token(vector.char), vector.token, vector.char)
			end
		end)

		helpers.it("reads every key of the corpus", function()
			for _, vector in ipairs(vectors.keys) do
				helpers.assert_eq(table.concat(Encoding.tokens(vector.key), "\1"),
					table.concat(vector.tokens, "\1"), vector.key)
			end
		end)

		helpers.it("migrates every old key of the corpus", function()
			for _, vector in ipairs(vectors.legacy_keys) do
				helpers.assert_eq(Encoding.migrate_key(vector.key, vector.count), vector.migrated, vector.key)
			end
		end)

		helpers.it("writes one update per changed key, in binary literals", function()
			local statements = Encoding.migration_statements({ ngram_chars = { "[", "[BS]" } })
			helpers.assert_eq(#statements, 1, "an unchanged key needs no statement")
			helpers.assert_eq(statements[1],
				"UPDATE OR ROLLBACK ngram_chars SET token=CAST(X'5B5B' AS TEXT) WHERE token=CAST(X'5B' AS TEXT);")
		end)
	end)
end

return M
