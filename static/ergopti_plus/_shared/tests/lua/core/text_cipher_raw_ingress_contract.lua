--- _shared/tests/lua/core/text_cipher_raw_ingress_contract.lua

--- ==============================================================================
--- MODULE: Typed-Text Cipher Raw Ingress Contract
--- DESCRIPTION:
--- Pins the provenance rule of the shared typed-text cipher on both Lua
--- drivers: encrypt() receives raw typed text, so every nonempty value is
--- sealed even when its bytes begin with the envelope marker, look like a
--- complete envelope, or copy a genuine one. Not double-wrapping a stored
--- envelope belongs to the migration, which reads stored values; the real
--- runner is driven here over an in-memory table to keep that idempotence and
--- to prove a decryption pass restores such literals exactly (WCR-001,
--- MCR-003, LCR-001).
--- ==============================================================================

local M = {}

--- Registers the contract cases.
--- @param helpers table The driver's test helpers.
function M.register(helpers)
	local Cipher = require("metrics.engine.privacy.text_cipher_core")
	local TextCrypto = require("metrics.engine.privacy.text_crypto")
	local Runner = require("metrics.engine.privacy.text_migration_runner")
	local Plan = require("metrics.engine.privacy.text_migration_core")

	local DEVICE = "local-device"
	local CANARY = "SYNTHETIC_CLEAR_CANARY"

	--- Hex image of a byte string, so the scripted payload never shows the canary.
	local function to_hex(text)
		return (text:gsub(".", function(byte) return string.format("%02x", byte:byte()) end))
	end

	local function from_hex(hex)
		if #hex % 2 ~= 0 or hex:find("[^0-9a-f]") then return nil end
		return (hex:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end))
	end

	--- The real shared cipher over a reversible scripted primitive.
	local function build()
		local calls = { encrypt = 0, decrypt = 0 }
		local logger = {}
		for _, level in ipairs({ "start", "success", "info", "debug", "warn", "error" }) do
			logger[level] = function() end
		end
		local cipher = Cipher.new({
			logger = logger, log = "test.cipher.ingress",
			sha256 = function(text) return string.rep("0", 56) .. string.format("%08x", #text) end,
			derive_key = function() return string.rep("ab", 32) end,
			ready = function() return true end,
			encrypt = function(_, _, plaintext)
				calls.encrypt = calls.encrypt + 1
				return "P" .. to_hex(plaintext)
			end,
			decrypt = function(_, _, payload)
				calls.decrypt = calls.decrypt + 1
				if payload:sub(1, 1) ~= "P" then return nil end
				return from_hex(payload:sub(2))
			end,
		})
		return cipher, calls
	end

	local function raw_literals(cipher)
		local genuine = cipher.encrypt(DEVICE, 99, CANARY)
		return {
			{ name = "a malformed marker prefix", text = TextCrypto.MARKER .. TextCrypto.SEPARATOR .. CANARY },
			{ name = "a valid-IV envelope lookalike", text = TextCrypto.wrap(string.rep("0", 32), CANARY) },
			{ name = "a byte copy of a genuine envelope", text = genuine },
			{ name = "a bare marker", text = TextCrypto.MARKER .. TextCrypto.SEPARATOR },
			{ name = "quotes, newline, NUL and non-ASCII after the marker",
				text = TextCrypto.MARKER .. TextCrypto.SEPARATOR .. "'\"\n\0\xC3\xA9" .. CANARY },
		}
	end

	--- An in-memory events_typing table behind the runner's backend port.
	local function backend(rows)
		local store = { rows = rows }
		store.port = {
			available = function() return true end,
			count = function() return #rows end,
			clear_rich_text = function() return true end,
			get_cursor = function() return store.cursor end,
			set_cursor = function(value) store.cursor = value; return true end,
			fetch = function(_, after, limit)
				local out = {}
				for _, row in ipairs(rows) do
					if row.id > after and #out < limit then out[#out + 1] = row end
				end
				return out
			end,
			apply = function(_, updates)
				for _, update in ipairs(updates) do
					for _, row in ipairs(rows) do
						if row.id == update.id then
							for _, assignment in ipairs(update.assignments) do
								row.values[assignment.name] = assignment.value
							end
						end
					end
				end
				return true
			end,
		}
		return store
	end

	local function run_pass(cipher, store, mode)
		local logger = {}
		for _, level in ipairs({ "start", "success", "info", "debug", "warn", "error" }) do
			logger[level] = function() end
		end
		local runner = Runner.new({ logger = logger, log_tag = "TEST", cipher = cipher, backend = store.port })
		local started = runner.start(mode, DEVICE)
		local pumps = 0
		while runner.pump() do
			pumps = pumps + 1
			assert(pumps < 50, "the pass never finished")
		end
		return started, runner
	end

	helpers.describe("typed-text cipher raw ingress (cipher-raw-ingress)", function()
		helpers.it("(cipher-raw-ingress) seals raw text that looks like an envelope and reads it back exactly", function()
			local cipher, calls = build()
			cipher.set_enabled(true)
			for index, case in ipairs(raw_literals(cipher)) do
				local before = calls.encrypt
				local stored = cipher.encrypt(DEVICE, index, case.text)
				helpers.assert_eq(calls.encrypt, before + 1, case.name .. " must reach the AES primitive")
				helpers.assert_true(stored ~= case.text, case.name .. " must not be stored as typed")
				helpers.assert_true(TextCrypto.is_encrypted(stored), case.name .. " must be stored as an envelope")
				helpers.assert_true(stored:find(CANARY, 1, true) == nil, case.name .. " must not expose the canary")
				helpers.assert_eq(cipher.decrypt(stored), case.text, case.name .. " must read back as typed")
			end
		end)

		helpers.it("(cipher-raw-ingress) keeps disabled encryption a passthrough for marker-prefixed text", function()
			local cipher, calls = build()
			local literal = TextCrypto.wrap(string.rep("0", 32), CANARY)
			helpers.assert_eq(cipher.encrypt(DEVICE, 1, literal), literal)
			helpers.assert_eq(calls.encrypt, 0, "disabled encryption starts nothing")
		end)

		helpers.it("(cipher-raw-ingress) the encryption pass still leaves genuine stored envelopes untouched", function()
			local cipher, calls = build()
			cipher.set_enabled(true)
			local stored = cipher.encrypt(DEVICE, 1, "already protected")
			local rows = {
				{ id = 1, values = { text = stored, events_json = "" } },
				{ id = 2, values = { text = "clear", events_json = "" } },
			}
			local before = calls.encrypt
			helpers.assert_true((run_pass(cipher, backend(rows), Plan.MODE_ENCRYPT)))
			helpers.assert_eq(rows[1].values.text, stored, "a stored envelope is never wrapped twice")
			helpers.assert_eq(calls.encrypt, before + 1, "only the clear row is encrypted")
			helpers.assert_eq(cipher.decrypt(rows[1].values.text), "already protected")
			helpers.assert_eq(cipher.decrypt(rows[2].values.text), "clear")
		end)

		helpers.it("(cipher-raw-ingress) a decryption pass restores marker-prefixed literals exactly", function()
			local cipher = build()
			cipher.set_enabled(true)
			local rows, expected = {}, {}
			for index, case in ipairs(raw_literals(cipher)) do
				rows[index] = { id = index, values = {
					text = cipher.encrypt(DEVICE, Plan.iv_event_id(index, "text"), case.text),
					events_json = cipher.encrypt(DEVICE, Plan.iv_event_id(index, "events_json"), "[]"),
				} }
				expected[index] = case.text
			end
			local started, runner = run_pass(cipher, backend(rows), Plan.MODE_DECRYPT)
			helpers.assert_true(started)
			helpers.assert_eq(runner.get_progress().converted, #rows, "the pass must complete over every row")
			for index, row in ipairs(rows) do
				helpers.assert_eq(row.values.text, expected[index], "the literal typed text is restored")
				helpers.assert_eq(row.values.events_json, "[]")
			end
		end)
	end)
end

return M
