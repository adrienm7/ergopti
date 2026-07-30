--- tests/unit/modules/keylogger/test_text_migration.lua

--- ==============================================================================
--- MODULE: At-Rest Bulk Migration Regression Test (shared plan + Linux runner)
--- DESCRIPTION:
--- Regression guard for the half of at-rest encryption that was missing: turning
--- the setting on protected only the rows written from that moment on, so a user
--- with a year of logs ticked a box that left every one of those rows in clear.
--- Turning it off had the mirror defect — the rows stayed encrypted.
---
--- WHAT THIS ENCODES:
--- 1. The conversion must be BYTE-EXACT. The cipher shells out through a
---    heredoc, and a heredoc always appends a newline to its body, so the naive
---    framing stored the ciphertext of a value the user never typed. Rewriting
---    rows in place with that framing would have corrupted them permanently, so
---    the round trip is asserted on the bytes, not on "it looks encrypted".
--- 2. It must be idempotent. A pass interrupted halfway and restarted has to
---    converge: an envelope must not be wrapped twice, and text that was never
---    encrypted must not be "decrypted".
--- 3. It must fail CLOSED in BOTH directions. Encryption that cannot run must
---    leave the rows in clear rather than store an empty column, and decryption
---    that cannot run must leave the envelopes alone rather than replace them
---    with the empty string the cipher returns when it has no key. The second is
---    the one that would destroy data.
--- 4. It must never write an aggregate column. The dashboard computes over
---    n-grams, counters and WPM; an encrypted blob in one of those would break
---    every query while protecting nothing.
--- ==============================================================================

local helpers = require("tests.helpers")

local Plan       = require("keylogger.text_migration")
local TextCrypto = require("keylogger.text_crypto")

--- Resolves the shell adapter at CALL time, never once at file scope: another
--- test file reloads adapters.shell_runner, which replaces the cached instance.
local function Shell()
	return require("adapters.shell_runner")
end

--- A syntactically valid AES-256 key and IV, for the fake derivation.
local KEY = string.rep("ab", 32)
local IV  = string.rep("cd", 16)

local DEVICE = "linux-testhost"




-- =========================================
-- =========================================
-- ======= 1/ Test Doubles =================
-- =========================================
-- =========================================

--- Hex helpers standing in for the cipher's base64 payload. Hex is deliberate:
--- it contains no colon and no whitespace, so it survives the envelope's own
--- framing exactly as base64 does.
local function to_hex(s)
	return (s:gsub(".", function(c) return string.format("%02X", c:byte()) end))
end

local function from_hex(h)
	if h:match("^%x*$") == nil or #h % 2 ~= 0 then return "" end
	return (h:gsub("%x%x", function(b) return string.char(tonumber(b, 16)) end))
end

--- Returns the first line of a composed command — the part the shell parses.
--- Every decision below is taken on this and never on the whole string: the
--- heredoc body is the user's own text and could contain any flag we look for.
local function command_line(cmd)
	return cmd:match("^([^\n]*)") or ""
end

--- Reproduces the bytes the SHELL would hand the command's standard input.
--- This is the point of the whole double: the heredoc body plus the newline the
--- shell always appends, truncated by whatever `head -c` filter sits in front. A
--- framing that mangles the payload therefore fails here exactly as it would on
--- a real machine, instead of being hidden behind a canned answer.
--- @param cmd string The fully composed command.
--- @return string|nil The delivered bytes, or nil when there is no heredoc.
local function delivered_stdin(cmd)
	local token = command_line(cmd):match("<<'([%w_]+)'")
	if not token then return nil end
	local body = cmd:match("\n(.-)\n" .. token .. "\n$")
	if body == nil then return nil end
	local delivered = body .. "\n"
	local limit = tonumber(command_line(cmd):match("^head %-c (%d+) "))
	if limit then delivered = delivered:sub(1, limit) end
	return delivered
end

--- Installs a shell double that answers every command the cipher issues.
--- @param opts table|nil { fail_crypto = boolean } — simulates openssl refusing.
--- @return table The recorded commands.
local function install_shell(opts)
	opts = opts or {}
	local seen = {}
	Shell()._set_runner(function(cmd)
		seen[#seen + 1] = cmd
		local head = command_line(cmd)
		-- The one key derivation. Recognised by -pbkdf2, which no per-value
		-- command carries: re-deriving per value would cost half a second each.
		if head:find("pbkdf2", 1, true) then
			return "salt=00\nkey=" .. KEY .. "\niv=" .. IV .. "\n"
		end
		-- The per-row IV, which also goes through the shell.
		if head:find("dgst", 1, true) then
			local h = 0
			for i = 1, #cmd do h = (h * 33 + cmd:byte(i)) % 0xFFFFFFF end
			return (string.format("%07x", h):rep(10)):sub(1, 64)
		end
		if opts.fail_crypto then return "" end
		local payload = delivered_stdin(cmd)
		if payload == nil then return "" end
		if head:find("enc %-d ") then return from_hex(payload) end
		return to_hex(payload)
	end)
	return seen
end

--- Builds an in-memory stand-in for events_typing.
--- The rows carry only the two migratable columns, which is itself part of the
--- contract: apply() records every column name it is asked to write, so a
--- migration that reached for an aggregate would be visible here.
--- @param rows table Array of { id, text, events_json }, ordered by id.
--- @return table The store, exposing .backend and its recorded interactions.
local function make_store(rows)
	local store = {
		rows = {},
		cursor = nil,
		fetches = 0,
		max_batch = 0,
		assigned = {},
		fail_apply = false,
	}
	for _, row in ipairs(rows) do
		store.rows[#store.rows + 1] = {
			id = row.id,
			values = { text = row.text, events_json = row.events_json },
		}
	end

	store.backend = {
		available = function() return true end,
		count = function() return #store.rows end,
		fetch = function(_, after_id, limit)
			store.fetches = store.fetches + 1
			local out = {}
			for _, row in ipairs(store.rows) do
				if row.id > after_id and #out < limit then
					out[#out + 1] = {
						id = row.id,
						values = { text = row.values.text, events_json = row.values.events_json },
					}
				end
			end
			if #out > store.max_batch then store.max_batch = #out end
			return out
		end,
		apply = function(_, updates)
			if store.fail_apply then return false end
			for _, update in ipairs(updates) do
				for _, assignment in ipairs(update.assignments) do
					store.assigned[assignment.name] = (store.assigned[assignment.name] or 0) + 1
					for _, row in ipairs(store.rows) do
						if row.id == update.id then row.values[assignment.name] = assignment.value end
					end
				end
			end
			return true
		end,
		get_cursor = function() return store.cursor end,
		set_cursor = function(value) store.cursor = value; return true end,
	}
	return store
end

--- Loads the real cipher and the real migration runner over a given store.
--- @param store table From make_store.
--- @return table cipher, table migration.
local function load_runner(store)
	-- adapters/crypto captures the shell adapter at ITS load time; reload it so
	-- it binds to the instance currently cached, or sha256 runs a REAL command.
	helpers.load_module("adapters.crypto")
	local cipher = helpers.load_module("modules.keylogger.text_cipher")
	local dir  = os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"
	local path = (dir:gsub("[/\\]$", "")) .. "/ergopti_migration_machine_id_test"
	local fh = assert(io.open(path, "w"))
	fh:write("0123456789abcdef0123456789abcdef\n")
	fh:close()
	cipher._set_machine_id_path(path)
	local migration = helpers.load_module("modules.keylogger.text_migration")
	migration._set_backend(store.backend)
	return cipher, migration
end

--- Drives a pass to its end, with a bound so a non-converging one fails loudly
--- instead of hanging the suite.
--- @param migration table
--- @return number The number of pump() calls it took.
local function drain(migration)
	local pumps = 0
	while migration.is_running() and pumps < 100 do
		migration.pump()
		pumps = pumps + 1
	end
	helpers.assert_eq(migration.is_running(), false, "the pass must terminate")
	return pumps
end




-- =========================================
-- =========================================
-- ======= 2/ The Shared Plan ==============
-- =========================================
-- =========================================

helpers.describe("text_migration plan — what may be rewritten", function()
	helpers.it("names only the two columns that hold typed text", function()
		local sql = Plan.update_row_sql(DEVICE, 7, {
			{ name = "text", value = "a" }, { name = "events_json", value = "b" },
		})
		helpers.assert_contains(sql, "text = 'a'")
		helpers.assert_contains(sql, "events_json = 'b'")
		-- The aggregates the dashboard computes over must never appear: an
		-- encrypted blob in one of them breaks every query and protects nothing.
		for _, aggregate in ipairs({ "wpm", "app", "date", "mouse_clicks", "pause_before_ms" }) do
			helpers.assert_true(sql:find(aggregate .. " =", 1, true) == nil,
				"the migration must never assign the aggregate column " .. aggregate)
		end
	end)

	helpers.it("refuses a column that is not one of the two", function()
		helpers.assert_nil(Plan.update_row_sql(DEVICE, 7, { { name = "wpm", value = "x" } }),
			"a caller-supplied column name must not reach an UPDATE")
		helpers.assert_eq(Plan.is_migratable_column("ngram_chars"), false)
	end)

	helpers.it("scopes every statement to one device", function()
		-- A row imported from another machine belongs to that machine's key
		-- domain: this one could not decrypt it, and encrypting it would lock its
		-- owner out of its own data.
		helpers.assert_contains(Plan.count_sql(DEVICE), "device_id = '" .. DEVICE .. "'")
		helpers.assert_contains(Plan.select_batch_sql(DEVICE, 0, 10), "device_id = '" .. DEVICE .. "'")
		helpers.assert_contains(Plan.update_row_sql(DEVICE, 1, { { name = "text", value = "x" } }),
			"device_id = '" .. DEVICE .. "'")
	end)

	helpers.it("reads in bounded batches from an exclusive cursor", function()
		local sql = Plan.select_batch_sql(DEVICE, 42, 25)
		helpers.assert_contains(sql, "id > 42", "the cursor must exclude what is already done")
		helpers.assert_contains(sql, "LIMIT 25", "an unbounded read would load a year of keystrokes")
		helpers.assert_contains(sql, "ORDER BY id", "the cursor is only meaningful over an ordered read")
	end)

	helpers.it("derives the IV id exactly as the writers do", function()
		-- The IV is not stored; it is recomputed from the row identity. A suffix
		-- that drifts from sqlite_writer produces rows nothing can decrypt.
		helpers.assert_eq(Plan.iv_event_id(42, "text"), "42")
		helpers.assert_eq(Plan.iv_event_id(42, "events_json"), "42j")
		helpers.assert_nil(Plan.iv_event_id(42, "wpm"))
	end)

	helpers.it("escapes a quote instead of ending the literal", function()
		local sql = Plan.update_row_sql(DEVICE, 1, { { name = "text", value = "it's" } })
		helpers.assert_contains(sql, "text = 'it''s'")
	end)
end)


helpers.describe("text_migration plan — the idempotence rule", function()
	helpers.it("converts only what is not already in the target state", function()
		local envelope = TextCrypto.wrap(IV, "AABB")
		local plain    = "hello"
		helpers.assert_eq(Plan.needs_conversion(Plan.MODE_ENCRYPT, plain, TextCrypto.is_encrypted), true)
		helpers.assert_eq(Plan.needs_conversion(Plan.MODE_ENCRYPT, envelope, TextCrypto.is_encrypted), false,
			"re-encrypting an envelope would double-wrap it")
		helpers.assert_eq(Plan.needs_conversion(Plan.MODE_DECRYPT, envelope, TextCrypto.is_encrypted), true)
		helpers.assert_eq(Plan.needs_conversion(Plan.MODE_DECRYPT, plain, TextCrypto.is_encrypted), false,
			"'decrypting' text that was never encrypted would destroy it")
	end)

	helpers.it("leaves an empty value alone in both directions", function()
		helpers.assert_eq(Plan.needs_conversion(Plan.MODE_ENCRYPT, "", TextCrypto.is_encrypted), false)
		helpers.assert_eq(Plan.needs_conversion(Plan.MODE_DECRYPT, "", TextCrypto.is_encrypted), false)
	end)

	helpers.it("round-trips a row through hex without touching the bytes", function()
		local id, values = Plan.parse_hex_row("7|68C3A96C6C6F0A|5B5D")
		helpers.assert_eq(id, 7)
		helpers.assert_eq(values.text, "h\195\169llo\n",
			"the hex read path must not normalise a trailing newline away")
		helpers.assert_eq(values.events_json, "[]")
	end)
end)




-- =========================================
-- =========================================
-- ======= 3/ Enabling Converts ============
-- =========================================
-- =========================================

helpers.describe("text_migration — enabling encrypts the rows already stored", function()
	helpers.it("wraps every pre-existing row and round-trips it byte for byte", function()
		-- Multi-byte UTF-8, an embedded newline and a TRAILING newline: the last
		-- one is what the naive heredoc framing silently ate.
		local originals = {
			{ id = 1, text = "hello world",            events_json = "[1,2]" },
			{ id = 2, text = "h\195\169llo \226\130\172 monde", events_json = "[]" },
			{ id = 3, text = "line one\nline two\n",   events_json = "[3]" },
		}
		local store = make_store(originals)
		install_shell()
		local cipher, migration = load_runner(store)

		cipher.set_enabled(true)
		helpers.assert_true(migration.start(Plan.MODE_ENCRYPT, DEVICE))
		drain(migration)

		for index, row in ipairs(store.rows) do
			helpers.assert_true(TextCrypto.is_encrypted(row.values.text),
				"row " .. row.id .. " must be stored as an envelope")
			helpers.assert_true(row.values.text:find(originals[index].text, 1, true) == nil,
				"the typed text must not survive in the stored value")
			helpers.assert_eq(cipher.decrypt(row.values.text), originals[index].text,
				"the stored envelope must decrypt back to the original bytes")
			helpers.assert_eq(cipher.decrypt(row.values.events_json), originals[index].events_json)
		end
		Shell()._reset_runner()
	end)

	helpers.it("gives each row and each column its own IV", function()
		local store = make_store({
			{ id = 1, text = "same text", events_json = "same text" },
			{ id = 2, text = "same text", events_json = "same text" },
		})
		install_shell()
		local cipher, migration = load_runner(store)
		cipher.set_enabled(true)
		migration.start(Plan.MODE_ENCRYPT, DEVICE)
		drain(migration)
		Shell()._reset_runner()

		local seen = {}
		for _, row in ipairs(store.rows) do
			for _, column in ipairs({ "text", "events_json" }) do
				local value = row.values[column]
				helpers.assert_true(seen[value] == nil,
					"identical text must never produce identical envelopes — that leaks which rows match")
				seen[value] = true
			end
		end
	end)

	helpers.it("derives the key once for the whole migration", function()
		local rows = {}
		for id = 1, 12 do rows[id] = { id = id, text = "value " .. id, events_json = "[]" } end
		local store = make_store(rows)
		local seen = install_shell()
		local cipher, migration = load_runner(store)
		cipher.set_enabled(true)
		migration.start(Plan.MODE_ENCRYPT, DEVICE)
		drain(migration)
		Shell()._reset_runner()

		local derivations = 0
		for _, cmd in ipairs(seen) do
			if command_line(cmd):find("pbkdf2", 1, true) then derivations = derivations + 1 end
		end
		helpers.assert_eq(derivations, 1,
			"24 values must cost ONE derivation — per-value derivation is half a second each")
	end)

	helpers.it("never asks the store to write anything but the two text columns", function()
		local store = make_store({ { id = 1, text = "a", events_json = "[]" } })
		install_shell()
		local cipher, migration = load_runner(store)
		cipher.set_enabled(true)
		migration.start(Plan.MODE_ENCRYPT, DEVICE)
		drain(migration)
		Shell()._reset_runner()

		for column in pairs(store.assigned) do
			helpers.assert_true(Plan.is_migratable_column(column),
				"the migration wrote the non-text column " .. column)
		end
		helpers.assert_eq(store.assigned.text, 1)
		helpers.assert_eq(store.assigned.events_json, 1)
	end)
end)




-- =========================================
-- =========================================
-- ======= 4/ Disabling Reverts ============
-- =========================================
-- =========================================

helpers.describe("text_migration — disabling decrypts the rows in place", function()
	helpers.it("returns every row to the exact bytes it started from", function()
		local originals = {
			{ id = 1, text = "secret sentence",       events_json = "[1]" },
			{ id = 2, text = "accentu\195\169 \226\128\148 ok", events_json = "[2]" },
			{ id = 3, text = "trailing newline\n",    events_json = "[3]" },
		}
		local store = make_store(originals)
		install_shell()
		local cipher, migration = load_runner(store)

		cipher.set_enabled(true)
		migration.start(Plan.MODE_ENCRYPT, DEVICE)
		drain(migration)

		-- Now the user unticks the box. decrypt() does not consult the toggle, so
		-- the posture is flipped exactly as the keylogger flips it.
		cipher.set_enabled(false)
		helpers.assert_true(migration.start(Plan.MODE_DECRYPT, DEVICE))
		drain(migration)
		Shell()._reset_runner()

		for index, row in ipairs(store.rows) do
			helpers.assert_eq(row.values.text, originals[index].text,
				"the row must come back byte for byte, trailing newline included")
			helpers.assert_eq(row.values.events_json, originals[index].events_json)
			helpers.assert_eq(TextCrypto.is_encrypted(row.values.text), false)
		end
	end)
end)





-- ==========================================
-- ==========================================
-- ======= 5/ Restart And Idempotence =======
-- ==========================================
-- ==========================================

helpers.describe("text_migration — an interrupted pass converges", function()
	helpers.it("finishes a half-migrated table without double-wrapping", function()
		local store = make_store({
			{ id = 1, text = "one",   events_json = "[1]" },
			{ id = 2, text = "two",   events_json = "[2]" },
			{ id = 3, text = "three", events_json = "[3]" },
			{ id = 4, text = "four",  events_json = "[4]" },
		})
		install_shell()
		local cipher, migration = load_runner(store)
		cipher.set_enabled(true)

		-- Convert rows 1 and 2 only, then simulate the daemon being killed: the
		-- pass is dropped mid-flight and the cursor keeps whatever it committed.
		local original_batch = Plan.DEFAULT_BATCH_SIZE
		Plan.DEFAULT_BATCH_SIZE = 2
		migration.start(Plan.MODE_ENCRYPT, DEVICE)
		migration.pump()
		migration.cancel()
		Plan.DEFAULT_BATCH_SIZE = original_batch

		local half_migrated = { store.rows[1].values.text, store.rows[2].values.text }
		helpers.assert_true(TextCrypto.is_encrypted(half_migrated[1]))
		helpers.assert_eq(TextCrypto.is_encrypted(store.rows[3].values.text), false,
			"the interruption must have left rows 3 and 4 untouched")

		-- Restart. The stored cursor makes it resume, and the rows it never
		-- reached are converted now.
		helpers.assert_true(migration.resume(Plan.MODE_ENCRYPT, DEVICE),
			"a stored cursor for this direction must resume the pass")
		drain(migration)

		helpers.assert_eq(store.rows[1].values.text, half_migrated[1],
			"an already-converted row must be left exactly as it was — re-wrapping makes it undecryptable")
		helpers.assert_eq(store.rows[2].values.text, half_migrated[2])
		for _, row in ipairs(store.rows) do
			helpers.assert_true(TextCrypto.is_encrypted(row.values.text),
				"row " .. row.id .. " must end up encrypted whichever pass reached it")
			helpers.assert_eq(TextCrypto.is_encrypted(cipher.decrypt(row.values.text)), false,
				"a double-wrapped value would still look encrypted after one decryption")
		end
		-- Reset LAST: the assertions above decrypt through the cipher, and a
		-- cipher pointed back at the real shell answers "" to everything, which
		-- would make every one of them pass without proving anything.
		Shell()._reset_runner()
	end)

	helpers.it("re-running a finished pass converts nothing and loses nothing", function()
		local originals = { { id = 1, text = "already done", events_json = "[1]" } }
		local store = make_store(originals)
		install_shell()
		local cipher, migration = load_runner(store)
		cipher.set_enabled(true)
		migration.start(Plan.MODE_ENCRYPT, DEVICE)
		drain(migration)
		local after_first = store.rows[1].values.text

		-- A restart that re-scans from zero — the case where the cursor was lost.
		store.cursor = nil
		migration.start(Plan.MODE_ENCRYPT, DEVICE)
		drain(migration)

		helpers.assert_eq(store.rows[1].values.text, after_first,
			"a second pass over a converted table must be a no-op")
		helpers.assert_eq(migration.get_progress().converted, 0)
		helpers.assert_eq(cipher.decrypt(store.rows[1].values.text), originals[1].text)
		Shell()._reset_runner()
	end)

	helpers.it("resumes nothing when no pass was ever started in that direction", function()
		local store = make_store({ { id = 1, text = "a", events_json = "[]" } })
		install_shell()
		local _, migration = load_runner(store)
		helpers.assert_eq(migration.resume(Plan.MODE_ENCRYPT, DEVICE), false,
			"a full re-scan at every daemon start would read a year of history for nothing")
		Shell()._reset_runner()
	end)

	helpers.it("reads in bounded batches rather than the whole table", function()
		local rows = {}
		for id = 1, 7 do rows[id] = { id = id, text = "row " .. id, events_json = "[]" } end
		local store = make_store(rows)
		install_shell()
		local cipher, migration = load_runner(store)
		cipher.set_enabled(true)

		local original_batch = Plan.DEFAULT_BATCH_SIZE
		Plan.DEFAULT_BATCH_SIZE = 3
		migration.start(Plan.MODE_ENCRYPT, DEVICE)
		local pumps = drain(migration)
		Plan.DEFAULT_BATCH_SIZE = original_batch
		Shell()._reset_runner()

		helpers.assert_true(store.max_batch <= 3,
			"a batch must never exceed the configured size — memory is the whole point")
		helpers.assert_true(pumps >= 3,
			"7 rows in batches of 3 cannot be done in fewer than 3 slices")
		for _, row in ipairs(store.rows) do
			helpers.assert_true(TextCrypto.is_encrypted(row.values.text))
		end
	end)
end)




-- =========================================
-- =========================================
-- ======= 6/ Failure Loses Nothing ========
-- =========================================
-- =========================================

helpers.describe("text_migration — failure never leaves data behind", function()
	helpers.it("leaves the rows in clear when encryption cannot run", function()
		local originals = {
			{ id = 1, text = "still secret", events_json = "[1]" },
			{ id = 2, text = "also secret",  events_json = "[2]" },
		}
		local store = make_store(originals)
		install_shell({ fail_crypto = true })
		local cipher, migration = load_runner(store)
		cipher.set_enabled(true)

		migration.start(Plan.MODE_ENCRYPT, DEVICE)
		migration.pump()
		Shell()._reset_runner()

		helpers.assert_eq(migration.is_running(), false,
			"a failing pass must stop, not spin writing empty columns")
		for index, row in ipairs(store.rows) do
			helpers.assert_eq(row.values.text, originals[index].text,
				"a row that could not be encrypted must be left untouched, never emptied")
			helpers.assert_eq(row.values.events_json, originals[index].events_json)
		end
		helpers.assert_eq(next(store.assigned), nil,
			"nothing at all may be written when the batch could not be converted")
	end)

	helpers.it("leaves the envelopes intact when decryption cannot run", function()
		-- The dangerous direction: decrypt() returns the empty string when it has
		-- no key, and writing that would erase the row for good.
		local store = make_store({ { id = 1, text = "recoverable", events_json = "[1]" } })
		install_shell()
		local cipher, migration = load_runner(store)
		cipher.set_enabled(true)
		migration.start(Plan.MODE_ENCRYPT, DEVICE)
		drain(migration)
		local encrypted = store.rows[1].values.text

		-- openssl stops answering, exactly as it would on a machine that lost it.
		Shell()._reset_runner()
		install_shell({ fail_crypto = true })
		migration.start(Plan.MODE_DECRYPT, DEVICE)
		migration.pump()
		Shell()._reset_runner()

		helpers.assert_eq(migration.is_running(), false)
		helpers.assert_eq(store.rows[1].values.text, encrypted,
			"an undecryptable row must keep its envelope — an empty column is unrecoverable")
		helpers.assert_true(TextCrypto.is_encrypted(store.rows[1].values.text))
	end)

	helpers.it("stops rather than advancing the cursor past a batch it could not write", function()
		local store = make_store({
			{ id = 1, text = "one", events_json = "[1]" },
			{ id = 2, text = "two", events_json = "[2]" },
		})
		install_shell()
		local cipher, migration = load_runner(store)
		cipher.set_enabled(true)
		store.fail_apply = true

		migration.start(Plan.MODE_ENCRYPT, DEVICE)
		migration.pump()
		Shell()._reset_runner()

		helpers.assert_eq(migration.is_running(), false)
		helpers.assert_nil(store.cursor,
			"a cursor that claims ground the write never covered would skip those rows forever")
		helpers.assert_eq(store.rows[1].values.text, "one")
	end)
end)
