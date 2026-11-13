--- tests/unit/metrics/engine/storage/test_journal_sealing.lua

--- ==============================================================================
--- MODULE: Journal Sealing Regression Tests
--- DESCRIPTION:
--- "Encrypt logs on disk" sealed the SQLite text columns but wrote every typing
--- row to today.log in clear, where the typed text and per-key events stayed
--- readable until the day's rollover (audit WM-002, shared by macOS). These
--- cases append through the real Rotation into a real file, scan its bytes, then
--- read it back through the real tail reader.
---
--- The cipher is a reversible stand-in with the shared envelope format: the
--- property under test is which bytes reach the journal, not AES itself, which
--- test_text_cipher covers.
--- ==============================================================================

local helpers = require("tests.helpers")
local TextCrypto = require("metrics.engine.privacy.text_crypto")

local SLOTS = { "metrics.engine.journal.rotation", "metrics.engine.privacy.text_cipher", "core.logger.engine.logger", "hs.fs", "hs.json", "hs.sqlite3", "hs.timer" }

--- A reversible stand-in cipher with the shared envelope format.
--- @return table cipher With controllable `enabled` and `broken` flags.
local function fake_cipher()
	local cipher = { enabled = true, broken = false, unreadable = false, ivs = {} }
	function cipher.is_enabled() return cipher.enabled end
	function cipher.encrypt(_, event_id, plaintext)
		if not cipher.enabled then return plaintext end
		if cipher.broken then return nil end
		cipher.ivs[#cipher.ivs + 1] = event_id
		local hex = plaintext:gsub(".", function(c) return string.format("%02x", c:byte() ~ 0x5a) end)
		return TextCrypto.wrap(string.rep("0", 32), hex)
	end
	function cipher.decrypt(value)
		local _, payload = TextCrypto.unwrap(value)
		if not payload then return value end
		if cipher.unreadable then return "" end
		return (payload:gsub("%x%x", function(h) return string.char(tonumber(h, 16) ~ 0x5a) end))
	end
	return cipher
end

--- Loads a fresh Rotation on a fresh journal file with the stand-in cipher.
--- @return table fixture { rotation, cipher, path, disk(), restore() }
local function load_fixture()
	local saved = {}
	for _, name in ipairs(SLOTS) do saved[name] = package.loaded[name] end
	local cipher = fake_cipher()
	package.loaded["metrics.engine.journal.rotation"] = nil
	package.loaded["metrics.engine.privacy.text_cipher"] = cipher
	package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
	local hs_stub = _G.hs or require("tests.stubs.hs")
	for _, name in ipairs({ "fs", "json", "sqlite3", "timer" }) do
		package.loaded["hs." .. name] = hs_stub[name]
	end
	local path = string.format("%s/ergopti_journal_sealing_%d_%d.log",
		helpers.temp_dir(), os.time(), math.random(1, 1e9))
	os.remove(path)
	local rotation = require("metrics.engine.journal.rotation")
	rotation.init({ paths = { today_log_path = path }, state = {}, recovery_turn_bytes = 65536 })
	return {
		rotation = rotation, cipher = cipher, path = path,
		disk = function()
			local fh = io.open(path, "rb")
			if not fh then return "" end
			local bytes = fh:read("a")
			fh:close()
			return bytes
		end,
		restore = function()
			os.remove(path)
			for _, name in ipairs(SLOTS) do package.loaded[name] = saved[name] end
		end,
	}
end

local function with_fixture(body)
	local fixture = load_fixture()
	local ok, err = xpcall(body, debug.traceback, fixture)
	fixture.restore()
	if not ok then error(err, 0) end
end

local function typing_entry()
	return { type = "typing", timestamp = "2026-11-06 10:00:00", app = "Editor",
		text = "zq-sealed-marker", rich_text = "zq-sealed-marker",
		events = { { "z", 120, { k = "zq-per-key" } } }, mouse_clicks = 0 }
end





-- ===================================
-- ===================================
-- ======= 1/ Sealed Journal =========
-- ===================================
-- ===================================

helpers.describe("keystats journal sealing", function()
	helpers.it("seals typed text and per-key events in today.log and reads them back", function()
		with_fixture(function(fixture)
			local entry = typing_entry()
			helpers.assert_true(fixture.rotation.append_log(entry), "the sealed row must be journaled")
			local disk = fixture.disk()
			helpers.assert_true(disk ~= "", "the journal must hold the row")
			helpers.assert_true(not disk:find("zq-sealed-marker", 1, true), "typed text must not reach today.log in clear")
			helpers.assert_true(not disk:find("zq-per-key", 1, true), "per-key events must not reach today.log in clear")
			helpers.assert_true(disk:find(TextCrypto.MARKER, 1, true) ~= nil, "the literal fields must be envelopes")
			helpers.assert_eq(entry.text, "zq-sealed-marker", "the accepted entry stays in clear for SQLite")
			helpers.assert_eq(entry._sealed, nil, "sealing works on a copy")
			helpers.assert_eq(#fixture.cipher.ivs, 3, "text, rich_text and events are sealed")
			helpers.assert_true(fixture.cipher.ivs[1] ~= fixture.cipher.ivs[3], "each field has its own IV input")

			local items, _, status = fixture.rotation.read_new_entries()
			helpers.assert_eq(status, fixture.rotation.READ_STATUS_EOF)
			helpers.assert_eq(#items, 1)
			local back = items[1].entry
			helpers.assert_eq(back.text, "zq-sealed-marker")
			helpers.assert_eq(back.rich_text, "zq-sealed-marker")
			helpers.assert_eq(back.events[1][3].k, "zq-per-key", "per-key events must decode back")
			helpers.assert_eq(back._sealed, nil, "the reader returns the ordinary journal form")
		end)
	end)

	helpers.it("keeps the plain journal when encryption is off", function()
		with_fixture(function(fixture)
			fixture.cipher.enabled = false
			helpers.assert_true(fixture.rotation.append_log(typing_entry()))
			helpers.assert_true(fixture.disk():find("zq-sealed-marker", 1, true) ~= nil,
				"control: the byte scan sees the marker when nothing is sealed")
		end)
	end)

	helpers.it("refuses the append rather than writing plaintext when sealing fails", function()
		with_fixture(function(fixture)
			fixture.cipher.broken = true
			helpers.assert_eq(fixture.rotation.append_log(typing_entry()), false)
			helpers.assert_true(not fixture.disk():find("zq-sealed-marker", 1, true),
				"a failed seal never writes the plaintext")
		end)
	end)

	helpers.it("holds the checkpoint on a sealed row that cannot be opened", function()
		with_fixture(function(fixture)
			helpers.assert_true(fixture.rotation.append_log(typing_entry()))
			fixture.cipher.unreadable = true
			local items, offset, status = fixture.rotation.read_new_entries()
			helpers.assert_eq(status, fixture.rotation.READ_STATUS_FAILED)
			helpers.assert_eq(#items, 0)
			helpers.assert_eq(offset, 0, "the unreadable row is not acknowledged")
		end)
	end)
end)
