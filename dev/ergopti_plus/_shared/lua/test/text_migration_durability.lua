--- _shared/lua/test/text_migration_durability.lua
--- ==============================================================================
--- MODULE: Typed-Text Migration Durability Contract
--- DESCRIPTION:
--- Drives both driver consumers through acknowledged resume-point publication,
--- refusal and restart without replacing their migration state machine.
--- ==============================================================================

local M = {}
local Plan = require("keystats.text_migration")
local TextCrypto = require("keystats.text_crypto")

--- Registers the same durable-intent scenarios through each driver's module.
--- @param helpers table Driver assertion and registration helpers.
--- @param ports table Driver fixture lifecycle, actual loader and resume adapter.
function M.register(helpers, ports)
	local function scenario(name, body, empty)
		helpers.it(name .. " (migration-durable-intent)", function()
			local original_batch = Plan.DEFAULT_BATCH_SIZE
			local store = ports.make_store(empty and {} or {
				{ id = 1, text = "one", events_json = "[1]" },
				{ id = 2, text = "two", events_json = "[2]" },
			})
			local migration, cipher, logger, original_success
			local successes = 0
			local ok, failure = xpcall(function()
				ports.install()
				cipher, migration = ports.load(store)
				cipher.set_enabled(true)
				logger = ports.logger()
				original_success = logger.success
				logger.success = function(tag, ...)
					if tag == ports.log_tag then successes = successes + 1 end
					return original_success(tag, ...)
				end
				body(store, migration, cipher, function() return successes end)
			end, debug.traceback)
			if migration then migration.cancel() end
			if logger and original_success then logger.success = original_success end
			Plan.DEFAULT_BATCH_SIZE = original_batch
			ports.restore()
			if not ok then error(failure, 0) end
		end)
	end

	local function restart(store, migration)
		migration.cancel()
		migration._set_backend(store.backend)
		helpers.assert_true(ports.resume(migration, Plan.MODE_ENCRYPT), "durable intent must survive the old runner")
		ports.drain(migration)
	end

	local function assert_complete(store, cipher)
		for index, row in ipairs(store.rows) do
			helpers.assert_true(TextCrypto.is_encrypted(row.values.text))
			helpers.assert_eq(cipher.decrypt(row.values.text), index == 1 and "one" or "two")
		end
	end

	scenario("resumes an accepted request cancelled before its first slice", function(store, migration, cipher, successes)
		helpers.assert_true(migration.start(Plan.MODE_ENCRYPT, ports.device))
		helpers.assert_eq(store.cursor, Plan.MODE_ENCRYPT .. ":0")
		helpers.assert_eq(store.rows[1].values.text, "one", "acceptance must not convert on the calling stack")
		restart(store, migration)
		assert_complete(store, cipher)
		helpers.assert_eq(successes(), 1)
	end)

	for _, refusal in ipairs({ "false", "nil" }) do
		scenario("rejects an initial resume receipt returning " .. refusal, function(store, migration, cipher, successes)
			local write = store.backend.set_cursor
			store.backend.set_cursor = function() if refusal == "false" then return false end end
			helpers.assert_eq(migration.start(Plan.MODE_ENCRYPT, ports.device), false)
			helpers.assert_eq(migration.is_running(), false)
			helpers.assert_nil(store.cursor)
			helpers.assert_eq(store.rows[1].values.text, "one")
			helpers.assert_eq(successes(), 0)
			store.backend.set_cursor = write
			helpers.assert_true(migration.start(Plan.MODE_ENCRYPT, ports.device))
			ports.drain(migration)
			assert_complete(store, cipher)
			helpers.assert_eq(successes(), 1)
		end)

		scenario("retires work after a batch resume receipt returning " .. refusal, function(store, migration, cipher, successes)
			Plan.DEFAULT_BATCH_SIZE = 1
			helpers.assert_true(migration.start(Plan.MODE_ENCRYPT, ports.device))
			local write = store.backend.set_cursor
			store.backend.set_cursor = function() if refusal == "false" then return false end end
			helpers.assert_eq(migration.pump(), false, "a refused durable cursor must stop the pass")
			helpers.assert_eq(migration.is_running(), false)
			helpers.assert_eq(store.cursor, Plan.MODE_ENCRYPT .. ":0")
			helpers.assert_true(TextCrypto.is_encrypted(store.rows[1].values.text), "the acknowledged row commit remains valid")
			helpers.assert_eq(store.rows[2].values.text, "two")
			helpers.assert_eq(successes(), 0, "a refused resume point cannot announce completion")
			local committed = store.rows[1].values.text
			store.backend.set_cursor = write
			restart(store, migration)
			helpers.assert_eq(store.rows[1].values.text, committed, "replayed committed rows must never be wrapped twice")
			assert_complete(store, cipher)
			helpers.assert_eq(successes(), 1)
		end)

		scenario("does not announce completion after a final resume receipt returning " .. refusal, function(store, migration, _, successes)
			helpers.assert_true(migration.start(Plan.MODE_ENCRYPT, ports.device))
			local write = store.backend.set_cursor
			store.backend.set_cursor = function() if refusal == "false" then return false end end
			helpers.assert_eq(migration.pump(), false)
			helpers.assert_eq(migration.is_running(), false)
			helpers.assert_eq(successes(), 0, "a refused final write is not a successful finish")
			helpers.assert_eq(store.cursor, Plan.MODE_ENCRYPT .. ":0")
			store.backend.set_cursor = write
			restart(store, migration)
			helpers.assert_eq(successes(), 1)
		end, true)
	end

	scenario("cancels and resumes after a committed partial pass", function(store, migration, cipher, successes)
		Plan.DEFAULT_BATCH_SIZE = 1
		helpers.assert_true(migration.start(Plan.MODE_ENCRYPT, ports.device))
		helpers.assert_true(migration.pump())
		helpers.assert_eq(store.cursor, Plan.MODE_ENCRYPT .. ":1")
		local committed = store.rows[1].values.text
		restart(store, migration)
		helpers.assert_eq(store.rows[1].values.text, committed)
		assert_complete(store, cipher)
		helpers.assert_eq(successes(), 1)
	end)
end

return M
