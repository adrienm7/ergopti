--- tests/unit/modules/keystats/storage/test_rich_text_not_stored_encrypted.lua

--- ==============================================================================
--- MODULE: Formatted Typed Text Under At-Rest Encryption
--- DESCRIPTION:
--- `events_typing.rich_text` holds the typed text with its formatting and no
--- reader decrypts it, so an encrypted database must store nothing there. The
--- macOS writer used to store it in clear while `text` and `events_json` were
--- encrypted (AHK-005 / WM-002); Windows and Linux store it empty.
---
--- FEATURES & RATIONALE:
--- 1. Encryption on: the formatted copy never reaches the INSERT.
--- 2. Encryption off: it is still stored, so the first case cannot pass by
---    dropping the column for everyone.
--- 3. The encrypt pass clears the rows stored before, scoped to this device.
--- ==============================================================================

local helpers = require("tests.helpers")

local DEVICE_ID = "rich-text-device"
local SECRET = "ZZRICHSECRETZZ"





-- ===========================
-- ===========================
-- ======= 1/ Fixtures =======
-- ===========================
-- ===========================

--- Builds the typing INSERT with a cipher double in the given state.
--- @param enabled boolean Whether at-rest encryption is on.
--- @return string The single typing statement.
local function typing_insert(enabled)
	return helpers.with_stub_scope({ "infra.logger", "modules.keystats.sqlite_writer",
		"modules.keystats.text_cipher" }, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["modules.keystats.text_cipher"] = {
			is_enabled = function() return enabled end,
			encrypt = function(_, _, value)
				if not enabled then return value end
				return "ENVELOPE" .. #value
			end,
		}
		local writer = helpers.load_with_stubs("modules.keystats.sqlite_writer")
		writer.init({ paths = {}, device_obj = { name = "TestMac" }, device_id = DEVICE_ID })
		local statements = writer.build_inserts({
			type = "typing", timestamp = "2026-11-13 22:00:00.000", app = "Editor",
			text = "plain", rich_text = SECRET, events = {},
		})
		helpers.assert_eq(#statements, 1)
		return statements[1]
	end)
end





-- ========================
-- ========================
-- ======= 2/ Tests =======
-- ========================
-- ========================

helpers.describe("events_typing.rich_text under at-rest encryption", function()
	helpers.it("is not stored when encryption is on", function()
		local sql = typing_insert(true)
		helpers.assert_true(sql:find("INSERT OR IGNORE INTO events_typing", 1, true) ~= nil)
		helpers.assert_nil(sql:find(SECRET, 1, true), "the formatted typed text reached SQLite in clear")
	end)

	helpers.it("is still stored when encryption is off", function()
		helpers.assert_true(typing_insert(false):find(SECRET, 1, true) ~= nil)
	end)

	helpers.it("is cleared for the local device by the encrypt pass", function()
		helpers.with_stub_scope({ "infra.logger", "modules.keystats.sqlite_writer" }, function()
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			local executed = {}
			local writer = helpers.load_with_stubs("modules.keystats.sqlite_writer")
			for i = 1, math.huge do
				local name = debug.getupvalue(writer.get_db, i)
				helpers.assert_true(name ~= nil, "the writer keeps its handle in _db")
				if name == "_db" then
					debug.setupvalue(writer.get_db, i, {
						exec = function(_, sql) executed[#executed + 1] = sql; return 0 end,
						errmsg = function() return "fixture" end,
					})
					break
				end
			end
			helpers.assert_true(writer.clear_rich_text(DEVICE_ID))
			helpers.assert_eq(executed, { "UPDATE events_typing SET rich_text = NULL WHERE device_id = '"
				.. DEVICE_ID .. "' AND rich_text IS NOT NULL;" })
		end)
	end)
end)
