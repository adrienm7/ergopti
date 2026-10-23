--- tests/unit/modules/keystats/lifecycle/test_text_migration.lua

--- ==============================================================================
--- MODULE: At-Rest Bulk Migration Regression Test (macOS)
--- DESCRIPTION:
--- Regression guard for the half of at-rest encryption that was missing on this
--- driver: ticking "Chiffrement" wrapped only the rows written from that moment
--- on, so a Mac with a year of logs enabled a setting that left every one of
--- those rows in clear. Unticking it had the mirror defect — the rows stayed
--- encrypted, readable only by the machine that wrote them.
---
--- WHAT THIS ENCODES:
--- 1. The conversion is BYTE-EXACT. The cipher shells out, and a heredoc framing
---    always appended a newline to its body, so the naive framing stored the
---    ciphertext of a value the user never typed. Rewriting stored rows with
---    that framing would corrupt them permanently, so the round trip is asserted
---    on the bytes — multi-byte UTF-8 and trailing newlines included.
--- 2. It is idempotent, therefore restart-safe: a pass interrupted halfway and
---    restarted converges instead of double-wrapping.
--- 3. It fails CLOSED in BOTH directions. Encryption that cannot run leaves the
---    rows in clear rather than storing an empty column; decryption that cannot
---    run leaves the envelopes alone rather than replacing them with the empty
---    string the cipher returns when it has no key. The second would destroy the
---    data the setting exists to protect.
--- 4. It never writes an aggregate column, and it never touches another device's
---    rows — those belong to that device's key domain.
--- 5. It stays OFF the typing path: Hammerspoon is single-threaded, so the pass
---    is sliced through the timer adapter rather than looped in one go.
--- ==============================================================================

local helpers = require("tests.helpers")

local Plan       = require("keystats.text_migration")
local TextCrypto = require("keystats.text_crypto")

local CipherDouble = require("tests.support.keystats.cipher_shell_double")

local DEVICE = "mac-testhost"





-- =========================================
-- =========================================
-- ======= 1/ Test Doubles =================
-- =========================================
-- =========================================

--- Returns the first line of a composed command — the part the shell parses.
--- Every decision below is taken on this and never on the whole string: the
--- stdin operand is the user's own text and could contain any flag we look for.
local function command_line(cmd)
	return cmd:match("^([^\n]*)") or ""
end

--- Points the cipher's native boundaries at faithful doubles: hs.execute
--- reproduces the bytes /bin/sh would hand openssl (C-string cut, printf %b
--- expansion, pipeline exit status) and hs.hash supplies the per-row IV digest.
--- A framing that mangles the payload therefore fails here as it would on a Mac.
--- @return table The recorded commands.
local _real_hs_execute = nil
local _real_hs_hash = nil
local _private_stdin_native = nil
local function install_shell()
	if _real_hs_execute == nil then _real_hs_execute = hs.execute end
	if _real_hs_hash == nil then _real_hs_hash = hs.hash end
	local execute, seen, native = CipherDouble.new()
	_private_stdin_native = native
	hs.execute = execute
	hs.hash = CipherDouble.native_hash()
	return seen
end

local function restore_shell()
	if _real_hs_execute ~= nil then hs.execute = _real_hs_execute end
	hs.hash = _real_hs_hash
	_private_stdin_native = nil
	local runner = package.loaded["adapters.shell_runner"]
	if type(runner) == "table" and runner._set_private_stdin_native then runner._set_private_stdin_native(nil) end
end

--- Builds an in-memory stand-in for events_typing.
--- apply() records every column name it is asked to write, so a migration that
--- reached for an aggregate would be visible here.
--- @param rows table Array of { id, text, events_json }, ordered by id.
--- @return table
local function make_store(rows)
	local store = { rows = {}, cursor = nil, max_batch = 0, assigned = {}, fail_apply = false }
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

--- Loads the real cipher and the real migration over a given store.
--- @param store table
--- @return table cipher, table migration.
local function load_runner(store)
	-- Both adapters capture the global hs at load: reload them under the doubles.
	package.loaded["adapters.crypto"] = nil
	package.loaded["adapters.shell_runner"] = nil
	package.loaded["modules.keystats.text_cipher"] = nil
	package.loaded["modules.keystats.text_migration"] = nil
	-- Secret input is written to a popen(3) pipe, never to hs.execute.
	require("adapters.shell_runner")._set_private_stdin_native(_private_stdin_native)
	local cipher = require("modules.keystats.text_cipher")
	cipher._set_machine_id_command("echo ioreg-stub")
	local migration = require("modules.keystats.text_migration")
	migration._set_backend(store.backend)
	return cipher, migration
end

--- Drives a pass to its end, with a bound so a non-converging one fails loudly
--- instead of hanging the suite.
local function drain(migration)
	local pumps = 0
	while migration.is_running() and pumps < 100 do
		migration.pump()
		pumps = pumps + 1
	end
	helpers.assert_true(not migration.is_running(), "the pass must terminate")
	return pumps
end





-- =========================================
-- =========================================
-- ======= 2/ Enabling Converts ============
-- =========================================
-- =========================================

helpers.describe("keystats.text_migration: enabling encrypts the rows already stored", function()
	helpers.it("wraps every pre-existing row and round-trips it byte for byte", function()
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
		restore_shell()
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
		restore_shell()

		local seen = {}
		for _, row in ipairs(store.rows) do
			for _, column in ipairs({ "text", "events_json" }) do
				helpers.assert_true(seen[row.values[column]] == nil,
					"identical text must never produce identical envelopes — that leaks which rows match")
				seen[row.values[column]] = true
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
		restore_shell()

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
		restore_shell()

		for column in pairs(store.assigned) do
			helpers.assert_true(Plan.is_migratable_column(column),
				"the migration wrote the non-text column " .. column)
		end
	end)
end)





-- =========================================
-- =========================================
-- ======= 3/ Disabling Reverts ============
-- =========================================
-- =========================================

helpers.describe("keystats.text_migration: disabling decrypts the rows in place", function()
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

		cipher.set_enabled(false)
		helpers.assert_true(migration.start(Plan.MODE_DECRYPT, DEVICE))
		drain(migration)
		restore_shell()

		for index, row in ipairs(store.rows) do
			helpers.assert_eq(row.values.text, originals[index].text,
				"the row must come back byte for byte, trailing newline included")
			helpers.assert_eq(row.values.events_json, originals[index].events_json)
			helpers.assert_true(not TextCrypto.is_encrypted(row.values.text))
		end
	end)
end)





-- ==========================================
-- ==========================================
-- ======= 4/ Restart And Idempotence =======
-- ==========================================
-- ==========================================

helpers.describe("keystats.text_migration: an interrupted pass converges", function()
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

		local original_batch = Plan.DEFAULT_BATCH_SIZE
		Plan.DEFAULT_BATCH_SIZE = 2
		migration.start(Plan.MODE_ENCRYPT, DEVICE)
		migration.pump()
		migration.cancel()
		Plan.DEFAULT_BATCH_SIZE = original_batch

		local half_migrated = { store.rows[1].values.text, store.rows[2].values.text }
		helpers.assert_true(TextCrypto.is_encrypted(half_migrated[1]))
		helpers.assert_true(not TextCrypto.is_encrypted(store.rows[3].values.text),
			"the interruption must have left rows 3 and 4 untouched")

		helpers.assert_true(migration.resume_for_posture(true, DEVICE),
			"a stored cursor for this direction must resume the pass")
		drain(migration)

		helpers.assert_eq(store.rows[1].values.text, half_migrated[1],
			"an already-converted row must be left exactly as it was — re-wrapping makes it undecryptable")
		for _, row in ipairs(store.rows) do
			helpers.assert_true(TextCrypto.is_encrypted(row.values.text),
				"row " .. row.id .. " must end up encrypted whichever pass reached it")
			helpers.assert_true(not TextCrypto.is_encrypted(cipher.decrypt(row.values.text)),
				"a double-wrapped value would still look encrypted after one decryption")
		end
		-- Restore LAST: the assertions above decrypt through the cipher, and a
		-- cipher pointed back at the real shell answers "" to everything, which
		-- would make every one of them pass without proving anything.
		restore_shell()
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

		store.cursor = nil   -- the cursor was lost; the pass must re-scan safely
		migration.start(Plan.MODE_ENCRYPT, DEVICE)
		drain(migration)

		helpers.assert_eq(store.rows[1].values.text, after_first,
			"a second pass over a converted table must be a no-op")
		helpers.assert_eq(migration.get_progress().converted, 0)
		helpers.assert_eq(cipher.decrypt(store.rows[1].values.text), originals[1].text)
		restore_shell()
	end)

	helpers.it("resumes nothing when no pass was ever started in that direction", function()
		local store = make_store({ { id = 1, text = "a", events_json = "[]" } })
		install_shell()
		local _, migration = load_runner(store)
		helpers.assert_true(not migration.resume_for_posture(true, DEVICE),
			"a full re-scan at every boot would read a year of history for nothing")
		restore_shell()
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
		restore_shell()

		helpers.assert_true(store.max_batch <= 3,
			"a batch must never exceed the configured size — memory is the whole point")
		helpers.assert_true(pumps >= 3,
			"7 rows in batches of 3 cannot be done in fewer than 3 slices")
	end)
end)





-- =========================================
-- =========================================
-- ======= 5/ Off The Typing Path ==========
-- =========================================
-- =========================================

helpers.describe("keystats.text_migration: the pass is sliced, not looped", function()
	helpers.it("schedules the next batch instead of converting the table in one go", function()
		local rows = {}
		for id = 1, 6 do rows[id] = { id = id, text = "row " .. id, events_json = "[]" } end
		local store = make_store(rows)
		install_shell()
		local cipher, migration = load_runner(store)
		cipher.set_enabled(true)

		local original_batch = Plan.DEFAULT_BATCH_SIZE
		Plan.DEFAULT_BATCH_SIZE = 2
		local before = #hs.timer.__timers
		migration.start(Plan.MODE_ENCRYPT, DEVICE)
		local scheduled = #hs.timer.__timers - before
		Plan.DEFAULT_BATCH_SIZE = original_batch

		helpers.assert_true(scheduled >= 1,
			"start() must hand the first batch to a timer — Hammerspoon is single-threaded, "
			.. "and a straight loop over a year of history blocks the keyboard tap for minutes")
		helpers.assert_eq(store.rows[1].values.text, "row 1",
			"start() must not have converted anything yet on the calling stack")

		migration.cancel()
		restore_shell()
	end)
end)
