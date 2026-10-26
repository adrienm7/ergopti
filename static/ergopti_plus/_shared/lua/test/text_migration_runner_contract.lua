--- _shared/lua/test/text_migration_runner_contract.lua

--- ==============================================================================
--- MODULE: Typed-Text Migration Runner Contract
--- DESCRIPTION:
--- Drives keystats/text_migration_runner over an in-memory backend, the way its
--- header says a test can. The runner decides where the resume cursor may
--- advance, what counts as a converted value and when to stop instead of
--- writing, on behalf of both Lua drivers, so the fail-closed rules are pinned
--- here once rather than only through each driver's database wrapper.
--- ==============================================================================

local M = {}

--- Registers the contract cases.
--- @param helpers table The driver's test helpers.
function M.register(helpers)
	local Runner = require("keystats.text_migration_runner")
	local Plan = require("keystats.text_migration")
	local TextCrypto = require("keystats.text_crypto")

	local IV = string.rep("a", TextCrypto.IV_HEX_LENGTH or 32)
	local DEVICE = "local-device"

	local function envelope(plain)
		return TextCrypto.wrap(IV, "wrapped:" .. plain)
	end

	--- A cipher that wraps on encrypt and unwraps on decrypt.
	--- @param behaviour table|nil { passthrough = true } returns plaintext; { empty = true } decrypts to "".
	local function cipher(behaviour)
		behaviour = behaviour or {}
		local seen = { encrypt = 0, decrypt = 0 }
		return {
			seen = seen,
			encrypt = function(_, _, value)
				seen.encrypt = seen.encrypt + 1
				if behaviour.passthrough then return value end
				return envelope(value)
			end,
			decrypt = function(value)
				seen.decrypt = seen.decrypt + 1
				if behaviour.empty then return "" end
				return (value:gsub("^.*wrapped:", ""))
			end,
		}
	end

	--- A logger recording the level of every line.
	local function logger()
		local lines = {}
		local function level(name)
			return function(_, fmt, ...) lines[#lines + 1] = { level = name, text = string.format(fmt, ...) } end
		end
		return { lines = lines, error = level("error"), warn = level("warn"), info = level("info"),
			start = level("start"), success = level("success") }
	end

	--- An in-memory events_typing table behind the runner's backend port.
	local function backend(rows, options)
		options = options or {}
		local store = { rows = rows, applied = {}, cursor = options.cursor, order = {}, sets = {} }
		store.port = {
			available = function() return options.available ~= false end,
			count = function() return #rows end,
			get_cursor = function() return store.cursor end,
			-- Both real backends acknowledge committed cursor writes explicitly.
			set_cursor = function(value)
				store.order[#store.order + 1] = "cursor"
				store.cursor = value
				store.sets[#store.sets + 1] = value
				return true
			end,
			fetch = function(_, after, limit)
				if options.fetch_fails then return nil end
				local out = {}
				for _, row in ipairs(rows) do
					if row.id > after and #out < limit then out[#out + 1] = row end
				end
				return out
			end,
			apply = function(_, updates)
				store.order[#store.order + 1] = "apply"
				if options.apply_fails then return false end
				for _, update in ipairs(updates) do
					store.applied[#store.applied + 1] = update
					for _, row in ipairs(rows) do
						if row.id == update.id then
							for _, assignment in ipairs(update.assignments) do row.values[assignment.name] = assignment.value end
						end
					end
				end
				return true
			end,
		}
		return store
	end

	local function new_runner(store, cipher_double)
		local log = logger()
		local runner = Runner.new({ logger = log, log_tag = "TEST", cipher = cipher_double or cipher(), backend = store.port })
		return runner, log
	end

	--- Pumps until the pass ends, with a bound so a broken runner cannot hang.
	local function drain(runner)
		local pumps = 0
		while runner.pump() do
			pumps = pumps + 1
			assert(pumps < 50, "the pass never finished")
		end
		return pumps
	end

	local function plain_rows(count)
		local rows = {}
		for id = 1, count do rows[id] = { id = id, values = { text = "t" .. id, events_json = "[" .. id .. "]" } } end
		return rows
	end

	helpers.describe("typed-text migration runner (text-migration-runner-contract)", function()
		helpers.it("(text-migration-runner-contract) is built only from a complete set of ports", function()
			local store = backend({})
			helpers.assert_nil(Runner.new(nil))
			helpers.assert_nil(Runner.new({ log_tag = "T", cipher = cipher(), backend = store.port }))
			helpers.assert_nil(Runner.new({ logger = logger(), cipher = cipher(), backend = store.port }))
			helpers.assert_nil(Runner.new({ logger = logger(), log_tag = "T", backend = store.port }))
			helpers.assert_nil(Runner.new({ logger = logger(), log_tag = "T", cipher = cipher() }))
		end)

		helpers.it("(text-migration-runner-contract) refuses to start for an unknown mode, no device or no database", function()
			local runner, log = new_runner(backend(plain_rows(1)))
			helpers.assert_eq(runner.start("rot13", DEVICE), false)
			helpers.assert_eq(runner.start(Plan.MODE_ENCRYPT, ""), false)
			helpers.assert_eq(runner.start(Plan.MODE_ENCRYPT, nil), false, "a pass over every device's rows is never allowed")
			helpers.assert_eq(runner.is_running(), false)
			helpers.assert_eq(log.lines[1].level, "error")
			local closed, closed_log = new_runner(backend(plain_rows(1), { available = false }))
			helpers.assert_eq(closed.start(Plan.MODE_ENCRYPT, DEVICE), false)
			helpers.assert_eq(closed_log.lines[1].level, "warn")
			helpers.assert_eq(closed.is_running(), false)
		end)

		helpers.it("(text-migration-runner-contract) encrypts every column of every row and only then advances the cursor", function()
			local rows = plain_rows(3)
			local store = backend(rows)
			local runner = new_runner(store)
			helpers.assert_true(runner.start(Plan.MODE_ENCRYPT, DEVICE))
			helpers.assert_eq(drain(runner), 0, "a short first batch finishes the pass at once")
			helpers.assert_eq(runner.is_running(), false)
			for _, row in ipairs(rows) do
				helpers.assert_true(TextCrypto.is_encrypted(row.values.text))
				helpers.assert_true(TextCrypto.is_encrypted(row.values.events_json))
			end
			helpers.assert_eq(store.order, { "cursor", "apply", "cursor", "cursor" },
				"initial durable intent precedes work; only committed batches advance progress")
			helpers.assert_eq(store.sets, { "encrypt:0", "encrypt:3", "encrypt:3" })
			local progress = runner.get_progress()
			helpers.assert_eq(progress.converted, 3)
			helpers.assert_eq(progress.scanned, 3)
			helpers.assert_eq(progress.running, false)
		end)

		helpers.it("(text-migration-runner-contract) round-trips back to the exact original values", function()
			local rows = plain_rows(2)
			rows[1].values.text = "h\xC3\xA9llo\n"
			local original = { rows[1].values.text, rows[1].values.events_json, rows[2].values.text }
			local store = backend(rows)
			local runner = new_runner(store)
			helpers.assert_true(runner.start(Plan.MODE_ENCRYPT, DEVICE)); drain(runner)
			for _, row in ipairs(rows) do
				for _, spec in ipairs(Plan.COLUMNS) do
					helpers.assert_true(TextCrypto.is_encrypted(row.values[spec.name]), "the round trip must convert before restoring")
				end
			end
			store.cursor = nil
			helpers.assert_true(runner.start(Plan.MODE_DECRYPT, DEVICE)); drain(runner)
			helpers.assert_eq(rows[1].values.text, original[1])
			helpers.assert_eq(rows[1].values.events_json, original[2])
			helpers.assert_eq(rows[2].values.text, original[3])
		end)

		helpers.it("(text-migration-runner-contract) walks full batches before the short one and keeps the pass in flight between them", function()
			local rows = plain_rows(Plan.DEFAULT_BATCH_SIZE + 1)
			local store = backend(rows)
			local runner = new_runner(store)
			helpers.assert_true(runner.start(Plan.MODE_ENCRYPT, DEVICE))
			helpers.assert_eq(runner.pump(), true, "a full batch means more rows may follow")
			helpers.assert_eq(store.cursor, "encrypt:" .. Plan.DEFAULT_BATCH_SIZE)
			helpers.assert_eq(runner.is_running(), true)
			helpers.assert_eq(runner.pump(), false)
			helpers.assert_eq(runner.get_progress().converted, Plan.DEFAULT_BATCH_SIZE + 1)
		end)

		helpers.it("(text-migration-runner-contract) skips values already in the target state so a restart converges", function()
			local rows = { { id = 1, values = { text = envelope("a"), events_json = "[1]" } } }
			local double = cipher()
			local runner = new_runner(backend(rows), double)
			helpers.assert_true(runner.start(Plan.MODE_ENCRYPT, DEVICE)); drain(runner)
			helpers.assert_eq(double.seen.encrypt, 1, "only the clear column is encrypted")
			helpers.assert_eq(rows[1].values.text, envelope("a"), "an envelope is never wrapped twice")
		end)

		helpers.it("(text-migration-runner-contract) fails closed when encryption hands back plaintext", function()
			local rows = plain_rows(2)
			local store = backend(rows)
			local runner, log = new_runner(store, cipher({ passthrough = true }))
			helpers.assert_true(runner.start(Plan.MODE_ENCRYPT, DEVICE))
			helpers.assert_eq(runner.pump(), false)
			helpers.assert_eq(store.order, { "cursor" }, "only initial intent is durable; refused conversion cannot advance it")
			helpers.assert_eq(store.cursor, "encrypt:0")
			helpers.assert_eq(rows[1].values.text, "t1")
			helpers.assert_eq(runner.is_running(), false)
			helpers.assert_eq(log.lines[#log.lines].level, "error")
		end)

		helpers.it("(text-migration-runner-contract) fails closed when decryption hands back the empty string", function()
			local rows = { { id = 1, values = { text = envelope("a"), events_json = envelope("[1]") } } }
			local store = backend(rows)
			local runner = new_runner(store, cipher({ empty = true }))
			helpers.assert_true(runner.start(Plan.MODE_DECRYPT, DEVICE))
			helpers.assert_eq(runner.pump(), false)
			helpers.assert_eq(store.order, { "cursor" })
			helpers.assert_eq(store.cursor, "decrypt:0", "failed conversion cannot advance the initial intent")
			helpers.assert_eq(rows[1].values.text, envelope("a"), "the envelope is not replaced by an empty value")
		end)

		helpers.it("(text-migration-runner-contract) stops without moving the cursor when a batch cannot be read or written", function()
			local failing_write = backend(plain_rows(2), { apply_fails = true })
			local runner = new_runner(failing_write)
			helpers.assert_true(runner.start(Plan.MODE_ENCRYPT, DEVICE))
			helpers.assert_eq(runner.pump(), false)
			helpers.assert_eq(failing_write.order, { "cursor", "apply" }, "an unwritten batch cannot advance the initial intent")
			helpers.assert_eq(failing_write.cursor, "encrypt:0")
			helpers.assert_eq(runner.is_running(), false)
			local failing_read = backend(plain_rows(2), { fetch_fails = true })
			runner = new_runner(failing_read)
			helpers.assert_true(runner.start(Plan.MODE_ENCRYPT, DEVICE))
			helpers.assert_eq(runner.pump(), false)
			helpers.assert_eq(failing_read.order, { "cursor" })
			helpers.assert_eq(failing_read.cursor, "encrypt:0")
		end)

		helpers.it("(text-migration-runner-contract) resumes after a stored cursor of the same direction only", function()
			local store = backend(plain_rows(5), { cursor = "encrypt:3" })
			local runner = new_runner(store)
			helpers.assert_true(runner.start(Plan.MODE_ENCRYPT, DEVICE))
			helpers.assert_eq(runner.get_progress().cursor, 3)
			runner.pump()
			helpers.assert_eq(store.applied[1].id, 4, "rows at or below the cursor are not reread")
			local other = backend(plain_rows(5), { cursor = "decrypt:3" })
			runner = new_runner(other)
			helpers.assert_true(runner.start(Plan.MODE_ENCRYPT, DEVICE))
			helpers.assert_eq(runner.get_progress().cursor, 0, "the other direction's cursor says nothing here")
		end)

		helpers.it("(text-migration-runner-contract) resumes at start-up only a pass that was left unfinished", function()
			local runner = new_runner(backend(plain_rows(2)))
			helpers.assert_eq(runner.resume(Plan.MODE_ENCRYPT, DEVICE), false, "no stored cursor means nothing to resume")
			runner = new_runner(backend(plain_rows(2), { cursor = "decrypt:1" }))
			helpers.assert_eq(runner.resume(Plan.MODE_ENCRYPT, DEVICE), false)
			runner = new_runner(backend(plain_rows(2), { cursor = "encrypt:1" }))
			helpers.assert_eq(runner.resume(Plan.MODE_ENCRYPT, DEVICE), true)
			helpers.assert_eq(runner.is_running(), true)
			runner = new_runner(backend(plain_rows(2), { cursor = "encrypt:1", available = false }))
			helpers.assert_eq(runner.resume(Plan.MODE_ENCRYPT, DEVICE), false)
		end)

		helpers.it("(text-migration-runner-contract) is a pause when cancelled, never a revert", function()
			local rows = plain_rows(Plan.DEFAULT_BATCH_SIZE + 1)
			local store = backend(rows)
			local runner = new_runner(store)
			helpers.assert_true(runner.start(Plan.MODE_ENCRYPT, DEVICE))
			runner.pump()
			runner.cancel()
			helpers.assert_eq(runner.is_running(), false)
			helpers.assert_eq(runner.pump(), false, "a cancelled pass does no more work")
			helpers.assert_true(TextCrypto.is_encrypted(rows[1].values.text), "converted rows stay converted")
			helpers.assert_eq(store.cursor, "encrypt:" .. Plan.DEFAULT_BATCH_SIZE, "the cursor lets a later call resume")
			runner.cancel()
		end)
	end)
end

return M
